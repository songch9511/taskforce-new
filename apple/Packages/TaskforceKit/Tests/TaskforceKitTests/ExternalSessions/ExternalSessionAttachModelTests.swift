#if os(macOS) && DEBUG
import Foundation
import Synchronization
import Testing
@testable import TaskforceKit

/// 이어받기 흐름 (OA 외부 세션 PR2m, 계약 6.1 · 8.3 · 12.3 · 20장 2): 준비 → 서버 → (서버 행 읽기) → 확정, 제자리 확인의 상태, 거절 한 줄, 게이트.
/// 이 Mac의 런타임 · 서버는 가짜다 (실제 `claude` · 네트워크 · Keychain 0)
@MainActor
struct ExternalSessionAttachModelTests {
    typealias F = ExternalSessionFixture
    nonisolated static let claudeID = F.uuid(11)
    nonisolated static let folder = "/Users/tester/proj"

    final class Runtime: ExternalSessionAttaching, @unchecked Sendable {
        private let lock = NSLock()
        var prepare: Result<AttachPlan, AttachRefusal>
        var commit: AttachRefusal?
        private(set) var calls: [String] = []
        private(set) var committed: [(plan: AttachPlan, session: UUID, facts: AttachServerFacts)] = []
        private(set) var prepared: [(id: String, folder: String)] = []

        init(bridge: UUID) {
            prepare = .success(AttachPlan.forTest(sessionID: ExternalSessionAttachModelTests.claudeID, folder: ExternalSessionAttachModelTests.folder, ref: "ws_" + UUID().uuidString.lowercased(), bridgeID: bridge, adapter: "agent:claude-code"))
        }

        func prepareAttach(sessionID: String, folder: String) async -> Result<AttachPlan, AttachRefusal> {
            lock.withLock {
                calls.append("prepare")
                prepared.append((sessionID, folder))
                return prepare
            }
        }

        func commitAttach(_ plan: AttachPlan, agentSessionID: UUID, server: AttachServerFacts) async -> AttachRefusal? {
            lock.withLock {
                calls.append("commit")
                committed.append((plan, agentSessionID, server))
                return commit
            }
        }

        func cancelAttach(_ plan: AttachPlan) async { lock.withLock { calls.append("cancel") } }
    }

    final class Server: @unchecked Sendable {
        private let lock = NSLock()
        let bridge = UUID()
        let connection = UUID()
        let session = UUID()
        var availability = AgentAttachAvailability.enabled
        var target: ExternalSessionAttachTarget?
        var attachResult: Result<AttachAgentSessionResponse.Status, Error> = .success(.created)
        /// 서버가 행에 적은 값 (RLS 읽기): nil이면 읽지 못한다
        var rowConnection: UUID??
        var rowExternal: String??
        var responseConnection: UUID?
        var responseWorkspaceRef: String?
        let gate = OrderGate()
        var holdAttach = false
        private(set) var availabilityCalls = 0
        private(set) var targetCalls = 0
        private(set) var attachCalls: [(bridge: UUID, adapter: String, id: String, ref: String)] = []

        init() { target = ExternalSessionAttachTarget(connectionID: connection, word: nil) }

        var built: ExternalSessionAttachServer {
            ExternalSessionAttachServer(
                bridgeID: { [self] in bridge },
                availability: { [self] in
                    lock.withLock { availabilityCalls += 1 }
                    return availability
                },
                target: { [self] _ in
                    lock.withLock { targetCalls += 1 }
                    return target
                },
                attach: { [self] bridge, adapter, id, ref in
                    lock.withLock { attachCalls.append((bridge, adapter, id, ref)) }
                    if holdAttach { await gate.wait() }
                    switch attachResult {
                    case .failure(let error): throw error
                    case .success(let status):
                        return AttachAgentSessionResponse(
                            status: status, conversationID: UUID(), workspaceRef: responseWorkspaceRef ?? ref,
                            session: AgentSessionRow(id: session, connectionID: responseConnection ?? connection, displayName: "", status: .bound, lastTurnSeq: 0, updatedAt: Date())
                        )
                    }
                },
                readSession: { [self] id in
                    guard id == session else { return nil }
                    let connection = rowConnection ?? self.connection
                    let external = rowExternal ?? ExternalSessionAttachModelTests.claudeID
                    guard let connection, let external else { return nil }
                    return (connection, external)
                }
            )
        }
    }

    @MainActor
    final class Rig {
        let runtime: Runtime
        let server = Server()
        let scope: AccountScope
        let log = RecordingLog()
        let model: ExternalSessionAttachModel
        let clock = ClockBox()
        private(set) var attached: [UUID] = []

        init(ready: Bool = true) {
            runtime = Runtime(bridge: server.bridge)
            let account = UUID()
            scope = AccountScope(currentAccount: { account })
            let box = AttachedBox()
            self.box = box
            let clock = self.clock
            model = ExternalSessionAttachModel(
                scope: scope, runtime: runtime, server: server.built, now: { clock.now }, log: log, onAttached: { id in box.ids.append(id) }
            )
            if !ready { server.target = ExternalSessionAttachTarget(connectionID: server.connection, word: "Not connected") }
        }

        final class AttachedBox: @unchecked Sendable { var ids: [UUID] = [] }
        let box: AttachedBox
        var attachedIDs: [UUID] { box.ids }

        func row(status: ExternalSessionStatus = .available, folder: String? = ExternalSessionAttachModelTests.folder, id: String = ExternalSessionAttachModelTests.claudeID) -> ExternalSessionRow {
            ExternalSessionRow(
                id: id, ref: String(repeating: "a", count: 64), title: "Title", folderPath: folder, groupPath: folder, lastActivity: Date(timeIntervalSince1970: 1_799_990_000),
                created: Date(timeIntervalSince1970: 1_799_900_000), client: .terminal, status: status
            )
        }

        func openGate() async { await model.refreshGate(force: true) }

        func advance(_ seconds: TimeInterval) { clock.advance(seconds) }
    }

    final class ClockBox: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.withLock { date } }
        func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
    }

    private func eventually(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: 게이트

    @Test func theGateIsReadyOnlyWhenTheServerIsOpenAndThisMacsTargetIsReady() async {
        let r = Rig()
        await r.openGate()
        #expect(r.model.gate == .ready)
        let off = Rig()
        off.server.availability = .disabled
        await off.openGate()
        #expect(off.model.gate == .unavailable, "서버 플래그가 꺼져 있다: 화면이 없다")
        let unknown = Rig()
        unknown.server.availability = .unknown
        await unknown.openGate()
        #expect(unknown.model.gate == .unavailable, "알 수 없으면 보이지 않는다")
    }

    @Test func aTargetThatIsNotReadyShowsItsWordAndNeverAnAction() async {
        let r = Rig(ready: false)
        await r.openGate()
        #expect(r.model.gate == .notReady(word: "Not connected"))
        #expect(!r.model.canResume(r.row()))
        let none = Rig()
        none.server.target = ExternalSessionAttachTarget(connectionID: nil, word: "Not connected")
        await none.openGate()
        #expect(none.model.gate == .notReady(word: AssistantTargetRules.notConnected), "이 Mac에 Claude Code 연결이 없다")
        let unread = Rig()
        unread.server.target = nil
        await unread.openGate()
        #expect(unread.model.gate == .unavailable, "대상 목록을 읽지 못했다: 모르면 보이지 않는다")
    }

    @Test func aMissingBridgeMeansNoAction() async {
        let r = Rig()
        let server = ExternalSessionAttachServer(
            bridgeID: { nil }, availability: { .enabled }, target: { _ in nil }, attach: { _, _, _, _ in throw URLError(.badURL) }, readSession: { _ in nil }
        )
        let model = ExternalSessionAttachModel(scope: r.scope, runtime: r.runtime, server: server)
        await model.refreshGate(force: true)
        #expect(model.gate == .unavailable)
    }

    @Test func theFlagIsAskedOncePerHourButTheTargetEveryTime() async {
        let r = Rig()
        await r.model.refreshGate()
        await r.model.refreshGate()
        #expect(r.server.availabilityCalls == 1 && r.server.targetCalls == 2)
        r.advance(3599)
        await r.model.refreshGate()
        #expect(r.server.availabilityCalls == 1)
        r.advance(2)
        await r.model.refreshGate()
        #expect(r.server.availabilityCalls == 2, "한 시간 뒤 다시 묻는다")
        await r.model.refreshGate(force: true)
        #expect(r.server.availabilityCalls == 3)
    }

    @Test func anUnknownAnswerIsAskedAgainAfterAMinute() async {
        let r = Rig()
        r.server.availability = .unknown
        await r.model.refreshGate()
        await r.model.refreshGate()
        #expect(r.server.availabilityCalls == 1, "방금 모른다고 했다")
        r.advance(61)
        r.server.availability = .enabled
        await r.model.refreshGate()
        #expect(r.model.gate == .ready)
    }

    @Test func leavingTheAccountClosesTheGateAndEveryConfirmation() async {
        let r = Rig()
        await r.openGate()
        r.model.request(r.row())
        #expect(!r.model.phases.isEmpty)
        r.scope.accountLeft()
        #expect(r.model.gate == .unavailable && r.model.phases.isEmpty)
    }

    // MARK: 줄 · 확인의 상태

    @Test func onlyAnIdleRowWithAFolderCanBeResumedAndOnlyWhenTheGateIsReady() async {
        let r = Rig()
        #expect(!r.model.canResume(r.row()), "게이트가 열리기 전")
        await r.openGate()
        #expect(r.model.canResume(r.row()))
        for status in [ExternalSessionStatus.inTaskforce, .held(.claudeApp), .held(.terminal), .held(.unknown), .couldNotCheck, .cannotResume(.worktree), .cannotResume(.folderNotAllowed), .cannotResume(.updateClaudeCode)] {
            #expect(!r.model.canResume(r.row(status: status)), "\(status)")
        }
        #expect(!r.model.canResume(r.row(folder: nil)), "폴더를 모르는 줄")
        #expect(!r.model.canResume(r.row(id: F.uuid(11).uppercased())), "소문자 정규 UUID가 아닌 줄")
    }

    @Test func requestShowsTheConfirmationAndCancelRemovesItAndNothingIsCalled() async {
        let r = Rig()
        await r.openGate()
        let row = r.row()
        r.model.request(row)
        #expect(r.model.phases[row.id] == .confirming(note: nil))
        r.model.cancel(row.id)
        #expect(r.model.phases.isEmpty)
        #expect(r.runtime.calls.isEmpty && r.server.attachCalls.isEmpty, "확인 전에는 아무것도 하지 않는다")
    }

    @Test func aRowThatCannotBeResumedGetsNoConfirmation() async {
        let r = Rig()
        r.model.request(r.row())
        #expect(r.model.phases.isEmpty, "게이트가 닫혀 있다")
        await r.openGate()
        r.model.request(r.row(status: .held(.claudeApp)))
        #expect(r.model.phases.isEmpty)
    }

    @Test func onlyOneConfirmationStandsAtATime() async {
        let r = Rig()
        await r.openGate()
        let a = r.row()
        let b = r.row(id: F.uuid(12))
        r.model.request(a)
        r.model.request(b)
        #expect(r.model.phases == [b.id: .confirming(note: nil)])
    }

    @Test func aRowThatIsWorkingCannotBeCancelledOrConfirmedAgain() async {
        let r = Rig()
        await r.openGate()
        r.server.holdAttach = true
        let row = r.row()
        r.model.request(row)
        let first = Task { await r.model.confirm(row) }
        await eventually { r.server.attachCalls.count == 1 }
        #expect(r.model.phases[row.id] == .working)
        r.model.cancel(row.id)
        #expect(r.model.phases[row.id] == .working, "도는 중에는 취소로 지우지 않는다")
        #expect(await r.model.confirm(row) == .ignored, "같은 id에 대한 Resume here 두 번은 하나만 (9.2)")
        r.server.gate.open()
        #expect(await first.value == .attached(r.server.session))
        #expect(r.server.attachCalls.count == 1 && r.runtime.calls.filter { $0 == "prepare" }.count == 1)
    }

    // MARK: 확인 → 준비 → 서버 → 확정

    @Test func aConfirmationRunsPrepareThenTheServerThenTheCommitWithTheServersFacts() async throws {
        let r = Rig()
        await r.openGate()
        let row = r.row()
        r.model.request(row)
        let outcome = await r.model.confirm(row)
        #expect(outcome == .attached(r.server.session))
        #expect(r.runtime.calls == ["prepare", "commit"])
        #expect(r.runtime.prepared.first?.id == Self.claudeID && r.runtime.prepared.first?.folder == Self.folder, "확인 순간 그 줄의 로컬 값으로 다시 판정한다")
        let plan = try #require(r.runtime.committed.first?.plan)
        let call = try #require(r.server.attachCalls.first)
        #expect(call.bridge == r.server.bridge && call.adapter == "agent:claude-code" && call.id == Self.claudeID && call.ref == plan.workspaceRef, "서버에는 로컬 id · 가상 루트만")
        #expect(!call.ref.contains(Self.folder))
        let committed = try #require(r.runtime.committed.first)
        #expect(committed.session == r.server.session)
        #expect(committed.facts == AttachServerFacts(externalSessionID: Self.claudeID, workspaceRef: plan.workspaceRef, connectionID: r.server.connection, thisMacConnectionID: r.server.connection))
        #expect(r.model.phases.isEmpty, "성공하면 줄에서 확인이 사라진다")
        #expect(r.box.ids == [r.server.session], "세션 패널을 여는 쪽에 알린다")
    }

    @Test func existingIsTheSameAsCreatedBecauseTheCommitIsIdempotent() async {
        let r = Rig()
        await r.openGate()
        r.server.attachResult = .success(.existing)
        let row = r.row()
        r.model.request(row)
        #expect(await r.model.confirm(row) == .attached(r.server.session))
        #expect(r.runtime.calls == ["prepare", "commit"])
    }

    @Test func aRowWithoutAPendingConfirmationCannotBeConfirmed() async {
        let r = Rig()
        await r.openGate()
        #expect(await r.model.confirm(r.row()) == .ignored)
        #expect(r.runtime.calls.isEmpty && r.server.attachCalls.isEmpty, "보이는 확인이 없는 줄에는 아무것도 하지 않는다")
    }

    @Test func aClosedGateStopsAConfirmationThatWasAlreadyUp() async {
        let r = Rig()
        await r.openGate()
        let row = r.row()
        r.model.request(row)
        r.server.availability = .disabled
        await r.openGate()
        #expect(await r.model.confirm(row) == .ignored)
        #expect(r.runtime.calls.isEmpty && r.server.attachCalls.isEmpty)
    }

    // MARK: 거절: 한 줄 (회색)

    @Test func everyLocalRefusalComesBackAsTheApprovedOneLineAndTheServerIsNeverCalled() async {
        let cases: [(AttachRefusal, String)] = [
            (.held(.claudeApp), "Close it in Claude first"), (.held(.terminal), "Close the terminal session first"), (.held(.background), "Running elsewhere"),
            (.held(.unknown), "Running elsewhere"), (.couldNotCheck, "Couldn't check"), (.folder, "Folder isn't allowed"), (.unreadable, "Unreadable"),
            (.version, "Update Claude Code"), (.notReady, "Not connected"), (.inUse, "Running elsewhere"), (.server, "Session didn't start"),
        ]
        for (refusal, note) in cases {
            let r = Rig()
            await r.openGate()
            r.runtime.prepare = .failure(refusal)
            let row = r.row()
            r.model.request(row)
            #expect(await r.model.confirm(row) == .refused(refusal), "\(refusal)")
            #expect(r.model.phases[row.id] == .confirming(note: note), "\(refusal): 확인 줄 안에 한 줄, 확인은 그대로 남아 닫고 다시 누를 수 있다")
            #expect(r.server.attachCalls.isEmpty && r.runtime.calls == ["prepare"], "\(refusal)")
        }
    }

    @Test func aRefusalLineGoesAwayWhenTheUserCancelsAndComesBackFresh() async {
        let r = Rig()
        await r.openGate()
        r.runtime.prepare = .failure(.held(.claudeApp))
        let row = r.row()
        r.model.request(row)
        _ = await r.model.confirm(row)
        r.model.cancel(row.id)
        r.model.request(row)
        #expect(r.model.phases[row.id] == .confirming(note: nil))
    }

    @Test func theServerErrorsFoldIntoTheRightRefusalAndTheRuntimePlanIsReleased() async {
        let cases: [(Error, AttachRefusal)] = [
            (APIError.server(status: 404, code: .notFound, message: ""), .server), (APIError.server(status: 409, code: .conflict, message: ""), .inUse),
            (APIError.server(status: 409, code: .busyRetry, message: ""), .server), (APIError.server(status: 403, code: .internalError, message: ""), .server),
            (APIError.server(status: 429, code: .rateLimited, message: ""), .server), (APIError.server(status: 500, code: .internalError, message: ""), .server),
            (APIError.transport("x"), .server), (APIError.decoding("x"), .server), (APIError.notSignedIn, .server), (AgentSessionRequestError.invalidAttach, .server),
        ]
        for (error, refusal) in cases {
            let r = Rig()
            await r.openGate()
            r.server.attachResult = .failure(error)
            let row = r.row()
            r.model.request(row)
            #expect(await r.model.confirm(row) == .refused(refusal), "\(error)")
            #expect(r.runtime.calls == ["prepare", "cancel"], "\(error): 서버가 실패하면 확정하지 않고 계획을 거둔다")
            if case .confirming = r.model.phases[row.id] {} else { Issue.record("\(error): 확인으로 돌아간다") }
        }
    }

    @Test func aCancelledServerCallEndsQuietly() async {
        let r = Rig()
        await r.openGate()
        r.server.attachResult = .failure(CancellationError())
        let row = r.row()
        r.model.request(row)
        #expect(await r.model.confirm(row) == .ignored)
        #expect(r.runtime.calls == ["prepare", "cancel"] && r.model.phases[row.id] == .confirming(note: nil))
    }

    // MARK: 서버 답 대조 (20장 2)

    @Test func aServerRowThatCannotBeReadOrDisagreesStopsBeforeTheCommit() async {
        // 행을 읽지 못했다 · 응답 세션의 연결과 읽은 행의 연결이 다르다
        let unreadable: (Rig) -> Void = { $0.server.rowConnection = .some(nil) }
        let differentConnection: (Rig) -> Void = { $0.server.responseConnection = UUID() }
        for make in [unreadable, differentConnection] {
            let r = Rig()
            await r.openGate()
            make(r)
            let row = r.row()
            r.model.request(row)
            #expect(await r.model.confirm(row) == .refused(.server))
            #expect(r.runtime.calls == ["prepare", "cancel"], "확정하지 않는다: 핀도 상태도 쓰지 않는다")
        }
    }

    @Test func theFactsHandedToTheCommitAreWhatTheServerSaidNotWhatWeSent() async throws {
        let r = Rig()
        await r.openGate()
        r.server.rowExternal = .some(F.uuid(12))
        r.server.responseWorkspaceRef = "/taskforce/ws_" + UUID().uuidString.lowercased()
        r.runtime.commit = .server
        let row = r.row()
        r.model.request(row)
        #expect(await r.model.confirm(row) == .refused(.server))
        let committed = try #require(r.runtime.committed.first)
        #expect(committed.facts.externalSessionID != Self.claudeID && committed.facts.workspaceRef != committed.plan.workspaceRef, "서버가 다르게 말한 값이 그대로 간다 (런타임이 거절한다)")
    }

    @Test func aMacWhoseTargetDisappearedAfterTheConfirmationWentUpCannotConfirm() async throws {
        let r = Rig()
        await r.openGate()
        let row = r.row()
        r.model.request(row)
        r.server.target = ExternalSessionAttachTarget(connectionID: nil, word: "Not connected")
        await r.openGate()
        #expect(r.model.gate == .notReady(word: "Not connected"))
        #expect(await r.model.confirm(row) == .ignored)
        #expect(r.runtime.calls.isEmpty && r.server.attachCalls.isEmpty)
    }

    @Test func aTargetThatWentAwayWhileTheServerWasAnsweringCommitsWithoutAConnection() async throws {
        let r = Rig()
        await r.openGate()
        r.server.holdAttach = true
        r.runtime.commit = .server
        let row = r.row()
        r.model.request(row)
        let flow = Task { await r.model.confirm(row) }
        await eventually { r.server.attachCalls.count == 1 }
        r.server.target = ExternalSessionAttachTarget(connectionID: nil, word: "Not connected")
        r.server.gate.open()
        _ = await flow.value
        #expect(r.runtime.committed.first?.facts.thisMacConnectionID == nil, "이 Mac의 연결을 모르면 런타임이 거절하도록 nil로 넘긴다")
    }

    @Test func aCommitRefusalAfterTheServerAnsweredShowsTheLineAndALaterPressCompletesIt() async {
        let r = Rig()
        await r.openGate()
        r.runtime.commit = .held(.claudeApp)
        let row = r.row()
        r.model.request(row)
        #expect(await r.model.confirm(row) == .refused(.held(.claudeApp)))
        #expect(r.model.phases[row.id] == .confirming(note: "Close it in Claude first"), "서버 행은 만들어졌지만 이 Mac은 핀 · 상태를 쓰지 않았다")
        // 닫고 다시 누른다: 서버는 같은 행을 돌려준다 (멱등)
        r.runtime.commit = nil
        r.server.attachResult = .success(.existing)
        #expect(await r.model.confirm(row) == .attached(r.server.session))
        #expect(r.model.phases.isEmpty)
        #expect(r.runtime.calls == ["prepare", "commit", "prepare", "commit"])
    }

    // MARK: 계정이 떠남

    @Test func ifTheAccountLeavesWhileTheServerIsAnsweringNothingIsCommitted() async {
        let r = Rig()
        await r.openGate()
        r.server.holdAttach = true
        let row = r.row()
        r.model.request(row)
        let flow = Task { await r.model.confirm(row) }
        await eventually { r.server.attachCalls.count == 1 }
        r.scope.accountLeft()
        r.server.gate.open()
        #expect(await flow.value == .ignored)
        #expect(!r.runtime.calls.contains("commit"), "다른 계정의 확정이 새 계정의 핀 · 상태를 쓰지 않는다")
        #expect(r.runtime.calls.contains("cancel") && r.box.ids.isEmpty && r.model.phases.isEmpty)
    }

    // MARK: 로그 · 거절 기록

    @Test func theLogHoldsOnlyCodesNeverTheIdTheFolderOrTheTitle() async {
        let r = Rig()
        await r.openGate()
        r.runtime.prepare = .failure(.held(.claudeApp))
        let row = r.row()
        r.model.request(row)
        _ = await r.model.confirm(row)
        let lines = r.log.events.map { event in event.event + " " + event.fields.map { "\($0.key)=\($0.value)" }.joined(separator: " ") }
        #expect(lines.contains { $0.contains("attach_refused") && $0.contains("running_elsewhere") })
        for line in lines {
            #expect(!line.contains(Self.claudeID) && !line.contains(Self.folder) && !line.contains("Title") && !line.contains(r.server.session.uuidString), "\(line)")
        }
    }

    @Test func theRefusalDetailsMatchTheContractsMetricWords() {
        let cases: [(AttachRefusal, String)] = [
            (.held(.claudeApp), "running_elsewhere"), (.held(.terminal), "running_elsewhere"), (.held(.background), "running_elsewhere"), (.held(.unknown), "running_elsewhere"),
            (.inUse, "running_elsewhere"), (.couldNotCheck, "unreadable"), (.folder, "folder"), (.unreadable, "unreadable"), (.version, "version"), (.notReady, "not_ready"), (.server, "server"),
        ]
        for (refusal, detail) in cases { #expect(ExternalSessionAttachCopy.detail(for: refusal) == detail, "\(refusal)") }
    }

    @Test func theBlockedSessionPanelLineReusesTheRowStatusWords() {
        #expect(ExternalSessionAttachCopy.holdLine(for: .held(.claudeApp)) == "Running in Claude")
        #expect(ExternalSessionAttachCopy.holdLine(for: .held(.terminal)) == "Running in Terminal")
        #expect(ExternalSessionAttachCopy.holdLine(for: .held(.background)) == "Running elsewhere")
        #expect(ExternalSessionAttachCopy.holdLine(for: .held(.unknown)) == "Running elsewhere")
        #expect(ExternalSessionAttachCopy.holdLine(for: .unknown) == "Couldn't check")
    }

    @Test func theApprovedStringsAreExactlyTheContractsAndTheAlreadyApprovedOnes() {
        #expect(ExternalSessionAttachCopy.resumeHere == "Resume here")
        #expect(ExternalSessionAttachCopy.confirmTitle == "Resume this session in Taskforce?")
        #expect(ExternalSessionAttachCopy.confirmDetail == "Don't open it in Claude while Taskforce is working.", "계약 17장이 고친 S14")
        #expect(ExternalSessionAttachCopy.closeInClaudeFirst == "Close it in Claude first")
        #expect(ExternalSessionAttachCopy.closeTerminalFirst == "Close the terminal session first")
        #expect(ExternalSessionAttachCopy.resumeHere == AgentCopy.resumeConfirm && ExternalSessionAttachCopy.closeTerminalFirst == AgentCopy.closeTerminalFirst, "이미 승인된 말을 그대로 쓴다")
    }
}
#endif
