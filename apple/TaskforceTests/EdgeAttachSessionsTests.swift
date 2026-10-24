import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// Sessions의 "Resume here" (OA 외부 세션 PR2m, 계약 6 · 8.3 · 12.3 · 17장)의 Mac 쪽: 게이트 · 제자리 확인 흐름 · 거절 한 줄 · 성공하면 세션 패널 · 막힌 세션 패널의 상태 줄.
/// 이 Mac의 실제 `claude` · Keychain · 서버 · Claude 기록을 건드리지 않는다: 런타임 · 서버 면은 가짜, 스캔은 가짜 클로저, 계정은 견본 계정이다
@MainActor
struct EdgeAttachSessionsTests {
    typealias Base = EdgeExternalSessionsTests
    nonisolated static let claudeID = String(format: "5e5e5e5e-0000-4000-8000-%012x", 21)
    nonisolated static let folder = "/Users/tester/proj"

    final class Runtime: ExternalSessionAttaching, @unchecked Sendable {
        private let lock = NSLock()
        let bridge = UUID()
        var prepare: Result<AttachPlan, AttachRefusal>?
        var commit: AttachRefusal?
        private(set) var calls: [String] = []
        /// 켜면 `prepareAttach`는 `release()`까지 기다린다 (도는 중의 Cancel을 보려고)
        var holdPrepare = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func release() {
            let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                holdPrepare = false
                defer { waiting = [] }
                return waiting
            }
            for continuation in pending { continuation.resume() }
        }

        func prepareAttach(sessionID: String, folder: String) async -> Result<AttachPlan, AttachRefusal> {
            let hold = lock.withLock { () -> Bool in
                calls.append("prepare")
                return holdPrepare
            }
            if hold { await withCheckedContinuation { continuation in lock.withLock { waiting.append(continuation) } } }
            return lock.withLock {
                prepare ?? .success(AttachPlan(sessionID: sessionID, folder: folder, ref: "ws_" + UUID().uuidString.lowercased(), bridgeID: bridge, adapter: "agent:claude-code", nonce: UUID(), issuedAt: Date()))
            }
        }

        func commitAttach(_ plan: AttachPlan, agentSessionID: UUID, server: AttachServerFacts) async -> AttachRefusal? {
            lock.withLock {
                calls.append("commit")
                return commit
            }
        }

        func cancelAttach(_ plan: AttachPlan) async { lock.withLock { calls.append("cancel") } }
    }

    final class Server: @unchecked Sendable {
        private let lock = NSLock()
        let connection = UUID()
        let session = UUID()
        var availability = AgentAttachAvailability.enabled
        private(set) var availabilityCalls = 0
        private(set) var attachCalls: [(String, String)] = []

        func built(_ bridge: UUID) -> ExternalSessionAttachServer {
            ExternalSessionAttachServer(
                bridgeID: { bridge },
                availability: { [self] in
                    lock.withLock { availabilityCalls += 1 }
                    return availability
                },
                target: { [self] _ in ExternalSessionAttachTarget(connectionID: connection, word: nil) },
                attach: { [self] _, _, id, ref in
                    lock.withLock { attachCalls.append((id, ref)) }
                    return AttachAgentSessionResponse(
                        status: .created, conversationID: UUID(), workspaceRef: ref,
                        session: AgentSessionRow(id: session, connectionID: connection, displayName: "", status: .bound, lastTurnSeq: 0, updatedAt: Date())
                    )
                },
                readSession: { [self] id in (id == session) ? (connection, EdgeAttachSessionsTests.claudeID) : nil }
            )
        }
    }

    struct World {
        let rig: EdgeExternalSessionsTests.Rig
        let attach: ExternalSessionAttachModel
        let runtime: Runtime
        let server: Server
        let scope: AccountScope
    }

    func world(server: Server = Server(), runtime: Runtime = Runtime()) -> World {
        let scope = AccountScope(currentAccount: { SampleData.userID })
        let attach = ExternalSessionAttachModel(scope: scope, runtime: runtime, server: server.built(runtime.bridge))
        let rig = Base().make(scope: scope, attach: attach)
        return World(rig: rig, attach: attach, runtime: runtime, server: server, scope: scope)
    }

    func row(_ n: Int = 21, status: ExternalSessionStatus = .available) -> ExternalSessionRow {
        ExternalSessionRow(
            id: Base.uuid(n), ref: String(repeating: "c", count: 64), title: "Session \(n)", folderPath: Self.folder, groupPath: Self.folder, lastActivity: Date().addingTimeInterval(-3600),
            created: Date(), client: .terminal, status: status
        )
    }

    private func until(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // MARK: 게이트

    @Test func theShellHasNoAttachFlowWithoutTheListOrTheIssueScreens() {
        let scope = AccountScope(currentAccount: { SampleData.userID })
        let runtime = Runtime()
        let attach = ExternalSessionAttachModel(scope: scope, runtime: runtime, server: Server().built(runtime.bridge))
        #expect(Base().make(store: false, scope: scope, attach: attach).shell.attach == nil, "목록이 없으면 이어받기도 없다")
        #expect(Base().make(gated: false, scope: scope, attach: attach).shell.attach == nil, "새 Issues 화면이 꺼진 셸에도 없다")
        let off = Base().make(attach: nil).shell
        #expect(off.attachPresentation == .off)
        off.resumeHere(row())
        #expect(off.attach == nil, "아무 일도 없다")
    }

    @Test func openingSessionsAsksTheServerAndOpensTheGateOnlyWhenItIsOnAndThisMacIsReady() async {
        let w = world()
        w.rig.counter.set([row()])
        w.rig.shell.openSessions()
        #expect(await until { w.attach.gate == .ready })
        let plan = SessionsPanelRules.onThisMac(w.rig.store.rows.isEmpty ? [row()] : w.rig.store.rows, live: { _ in nil }, now: Date(), expanded: true, attach: w.rig.shell.attachPresentation)
        #expect(plan.rows.first?.line.action == .resumeHere && plan.rows.first?.line.actionTitle == "Resume here")
        // 서버가 닫았다: 단추가 없다
        let closed = world(server: { let server = Server(); server.availability = .disabled; return server }())
        closed.rig.shell.openSessions()
        #expect(await until { closed.server.availabilityCalls > 0 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(closed.attach.gate == .unavailable && closed.rig.shell.attachPresentation.gate == .unavailable)
        let rows = SessionsPanelRules.onThisMac([row()], live: { _ in nil }, now: Date(), expanded: true, attach: closed.rig.shell.attachPresentation).rows
        #expect(rows.first?.line.action == nil)
    }

    @Test func leavingSessionsDoesNotAskTheServerAgainWithinTheHour() async {
        let w = world()
        w.rig.shell.openSessions()
        #expect(await until { w.attach.gate == .ready })
        w.rig.shell.openAllWork()
        w.rig.shell.openSessions()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(w.server.availabilityCalls == 1, "플래그는 한 시간에 한 번만 묻는다")
    }

    // MARK: 흐름

    @Test func resumeHereStandsAConfirmationAndNothingElseHappens() async {
        let w = world()
        w.rig.shell.openSessions()
        #expect(await until { w.attach.gate == .ready })
        let target = row()
        w.rig.shell.resumeHere(target)
        #expect(w.rig.shell.attachPresentation.phases == [target.id: .confirming(note: nil)])
        #expect(w.runtime.calls.isEmpty && w.server.attachCalls.isEmpty, "확인 전에는 서버 · 런타임을 부르지 않는다")
        w.rig.shell.cancelResume(target.id)
        #expect(w.rig.shell.attachPresentation.phases.isEmpty)
    }

    @Test func confirmingAttachesThroughTheLocalRuntimeAndOpensTheNewSessionPanel() async {
        let w = world()
        w.rig.counter.set([row()])
        w.rig.shell.openSessions()
        #expect(await until { w.attach.gate == .ready && w.rig.store.phase == .ready })
        let scansBefore = w.rig.counter.scans
        let target = row()
        w.rig.shell.resumeHere(target)
        let task = w.rig.shell.confirmResume(target)
        await task.value
        #expect(w.runtime.calls == ["prepare", "commit"], "이 순간 다시 판정하고(준비) 서버가 맞은 뒤 쓴다(확정)")
        #expect(w.server.attachCalls.count == 1 && w.server.attachCalls[0].0 == Self.claudeID && w.server.attachCalls[0].1.hasPrefix("/taskforce/ws_"), "서버에는 로컬 id와 가상 루트만")
        #expect(!w.server.attachCalls[0].1.contains(Self.folder))
        #expect(w.rig.shell.attachPresentation.phases.isEmpty)
        #expect(await until { w.rig.shell.sessionPanelID == w.server.session }, "성공하면 그 세션 패널이 열린다")
        #expect(w.rig.counter.scans > scansBefore, "이 Mac 목록을 다시 훑는다 (그 줄은 In Taskforce가 되어 Taskforce 절로 간다)")
    }

    @Test func aRefusalLeavesTheConfirmationUpWithTheApprovedOneLine() async {
        let runtime = Runtime()
        runtime.prepare = .failure(.held(.claudeApp))
        let w = world(runtime: runtime)
        w.rig.shell.openSessions()
        #expect(await until { w.attach.gate == .ready })
        let target = row()
        w.rig.shell.resumeHere(target)
        await w.rig.shell.confirmResume(target).value
        #expect(w.rig.shell.attachPresentation.phases == [target.id: .confirming(note: "Close it in Claude first")])
        #expect(w.server.attachCalls.isEmpty && w.rig.shell.sessionPanelID == nil, "서버를 부르지 않았고 세션 패널도 열리지 않았다")
        // 터미널이 쥐었다
        runtime.prepare = .failure(.held(.terminal))
        await w.rig.shell.confirmResume(target).value
        #expect(w.rig.shell.attachPresentation.phases[target.id]?.note == "Close the terminal session first")
    }

    /// 코드 검토: 도는 중에 Cancel · Esc(같은 `onCancel`)를 누르면 흐름이 멈추고 확인이 닫힌다 — 서버에는 가지 않는다
    @Test func cancelWhileWorkingStopsTheFlowBeforeTheServerAndClosesTheConfirmation() async {
        let runtime = Runtime()
        runtime.holdPrepare = true
        let w = world(runtime: runtime)
        w.rig.shell.openSessions()
        #expect(await until { w.attach.gate == .ready })
        let target = row()
        w.rig.shell.resumeHere(target)
        let task = w.rig.shell.confirmResume(target)
        #expect(await until { runtime.calls == ["prepare"] })
        #expect(w.rig.shell.attachPresentation.phases == [target.id: .working], "준비에서 멈춰 있다")
        w.rig.shell.cancelResume(target.id)
        runtime.release()
        await task.value
        #expect(w.server.attachCalls.isEmpty && runtime.calls == ["prepare", "cancel"], "서버를 부르지 않고 계획을 거둔다")
        #expect(w.rig.shell.attachPresentation.phases.isEmpty && w.rig.shell.sessionPanelID == nil, "확인이 닫히고 세션 패널은 열리지 않는다")
    }

    @Test func leavingTheAccountClearsEveryConfirmation() async {
        let w = world()
        w.rig.shell.openSessions()
        #expect(await until { w.attach.gate == .ready })
        w.rig.shell.resumeHere(row())
        #expect(!w.rig.shell.attachPresentation.phases.isEmpty)
        w.scope.accountLeft()
        #expect(w.rig.shell.attachPresentation == .off || w.rig.shell.attachPresentation.phases.isEmpty)
        #expect(w.attach.gate == .unavailable)
    }

    // MARK: 막힌 세션 패널 (DZ-8)

    @Test func aBlockedAttachedSessionPanelSaysWhoHoldsItUnderTheHeader() {
        let session = AgentSessionItem(
            id: UUID(), name: "Pricing", agent: .claudeCode, agentName: "Claude Code", connectionID: UUID(), status: .bound, ring: nil, line: "", createdAt: Date(), updatedAt: Date(),
            issueIDs: [], currentIssueID: nil, conversationID: UUID(), hasOpenTask: false, pill: nil
        )
        let stop = AgentStopRules.Presentation(showsStop: false, line: nil)
        #expect(SessionPanelView.statusLine(for: session, stop: stop, hold: .held(.claudeApp)) == "Running in Claude")
        #expect(SessionPanelView.statusLine(for: session, stop: stop, hold: .held(.terminal)) == "Running in Terminal")
        #expect(SessionPanelView.statusLine(for: session, stop: stop, hold: .held(.background)) == "Running elsewhere")
        #expect(SessionPanelView.statusLine(for: session, stop: stop, hold: .held(.unknown)) == "Running elsewhere")
        #expect(SessionPanelView.statusLine(for: session, stop: stop, hold: .unknown) == "Couldn't check")
        #expect(SessionPanelView.statusLine(for: session, stop: stop, hold: nil) == SessionPanelView.statusLine(for: session, stop: stop), "막히지 않았으면 기존 상태 줄 그대로")
        let closed = AgentSessionItem(
            id: UUID(), name: "Old", agent: .claudeCode, agentName: "Claude Code", connectionID: UUID(), status: .closed, ring: nil, line: "", createdAt: Date(), updatedAt: Date(),
            issueIDs: [], currentIssueID: nil, conversationID: UUID(), hasOpenTask: false, pill: nil
        )
        #expect(SessionPanelView.statusLine(for: closed, stop: stop, hold: .held(.claudeApp)) == nil, "끝난 세션은 상태 말이 없다")
    }
}
