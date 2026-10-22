import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftUI
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// 폴이 돌려줄 살아 있는 데스크톱 세션 (시험이 정한다)
final class DeskScript: @unchecked Sendable {
    private let lock = NSLock()
    private var _sessions: [ClaudeAppSession] = []

    var sessions: [ClaudeAppSession] {
        get { lock.withLock { _sessions } }
        set { lock.withLock { _sessions = newValue } }
    }

    func poll() -> ClaudeAppStatusPoller.Poll {
        ClaudeAppStatusPoller.Poll(sessions: sessions, doubled: [], source: .registry, mismatch: false, verified: true, registryUnavailable: false)
    }
}

/// 기록 읽기를 대신하는 가짜: 연 세션을 세고, 기본은 짧은 대화를 준다 (실제 `~/.claude`를 읽지 않는다)
final class TranscriptFake: ClaudeAppTranscriptSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _opened: [String] = []
    private var _tails = 0
    var unreadable = false
    var earlier = false

    var opened: [String] { lock.withLock { _opened } }
    var tails: Int { lock.withLock { _tails } }

    func open(sessionID: String, cwd: String?) -> ClaudeAppTranscriptLoad {
        lock.withLock { _opened.append(sessionID) }
        if unreadable { return .unreadable }
        let turns = [
            ClaudeAppTurn(id: "t1", kind: .user("Fix the launcher focus")),
            ClaudeAppTurn(id: "t2", kind: .assistant("Looking at the wake handler.")),
            ClaudeAppTurn(id: "t3", kind: .tool(name: "Read", description: nil)),
        ]
        return .page(ClaudeAppTranscriptPage(turns: turns, cursor: ClaudeAppTranscriptCursor(sessionID: sessionID), hasEarlier: earlier, skippedLines: 0))
    }

    func earlier(_ cursor: ClaudeAppTranscriptCursor) -> ClaudeAppTranscriptLoad { .unreadable }

    func newer(_ cursor: ClaudeAppTranscriptCursor) -> ClaudeAppTranscriptUpdate {
        lock.withLock { _tails += 1 }
        return .turns([], cursor: cursor, hasMore: false)
    }
}

final class SendCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    func hit() { lock.withLock { _count += 1 } }
}

/// Sessions 버튼 · Sessions 패널 · Claude 데스크톱 세션 링 · 읽기 전용 세션 보기의 Mac 쪽 (OA PR-D2).
/// 이 Mac의 실제 Claude 기록 · 프로세스 · 서버를 읽지 않는다: 폴 · 기록 · 앱 열기 · 지표 보내기는 모두 가짜, 저장은 메모리, 계정은 견본 계정이다
@MainActor
struct EdgeSessionsTests {
    typealias X = EdgeExternalSessionsTests
    typealias Fx = IssueSnapshotData
    static func id(_ n: Int) -> String { X.uuid(n) }

    static func live(_ n: Int, _ state: ClaudeAppSessionState, cwd: String? = "/Users/tester/proj") -> ClaudeAppSession {
        ClaudeAppSession(id: id(n), pid: Int32(9000 + n), cwd: cwd, procStart: nil, state: state, statusUpdatedAt: Date())
    }

    /// 이 Mac 목록의 줄: Claude 데스크톱 앱이 쥔 세션 (제목은 "Session n")
    static func heldRow(_ n: Int) -> ExternalSessionRow {
        X.row(n, status: .held(.claudeApp), group: "/Users/tester/proj\(n)", client: .claudeDesktop)
    }

    @MainActor
    struct Rig {
        let base: X.Rig
        let script: DeskScript
        let desktop: ClaudeAppSessionsModel
        let doneStore: InMemoryClaudeAppDoneStore
        let railDone: InMemoryRailDoneStore
        let sent: SendCounter
        let transcript: TranscriptFake
        let time: EdgeShellModelTests.ManualTime

        var shell: EdgeShellModel { base.shell }

        /// 폴을 한 번 돌려 그 결과를 레일에 올린다 (컨트롤러가 관찰해서 하는 일)
        func poll(_ sessions: [ClaudeAppSession]) async {
            script.sessions = sessions
            await desktop.pollOnce()
            shell.desktopChanged()
        }
    }

    /// - rows: 이 Mac 목록의 줄 번호 (Claude 앱이 쥔 줄). live: 처음 폴이 주는 살아 있는 세션
    func rig(sessions: IssueSampleGateway.SessionScenario = .none, rows: [Int] = [], live: [ClaudeAppSession] = []) async -> Rig {
        let script = DeskScript()
        script.sessions = live
        let scope = AccountScope(currentAccount: { SampleData.userID })
        let doneStore = InMemoryClaudeAppDoneStore()
        let desktop = ClaudeAppSessionsModel(poll: { script.poll() }, scope: scope, done: doneStore)
        let sent = SendCounter()
        let metric = ClaudeAppOpenedMetric(send: { sent.hit(); return true }, scope: scope)
        let railDone = InMemoryRailDoneStore()
        let time = EdgeShellModelTests.ManualTime()
        let base = X().make(sessions: sessions, desktop: desktop, railDone: railDone, opened: metric, scope: scope, time: time)
        base.counter.set(rows.map(Self.heldRow))
        await base.store.refresh()
        await base.issues.sessions.refresh()
        // Taskforce 세션이 있을 때만 이슈의 일(링의 재료)을 준다: 데스크톱 링만 보는 시험은 레일에 다른 링이 없다
        if sessions != .none { base.shell.update(Fx.snapshot(seeds: Fx.seeds)) }
        let transcript = TranscriptFake()
        base.shell.makeConversation = { id, cwd in ClaudeAppConversation(sessionID: id, cwd: cwd, source: transcript) }
        let rig = Rig(base: base, script: script, desktop: desktop, doneStore: doneStore, railDone: railDone, sent: sent, transcript: transcript, time: time)
        await rig.poll(live)
        return rig
    }

    func until(_ condition: () -> Bool) async -> Bool { await X().until(condition) }

    private func desktopEntry(_ shell: EdgeShellModel, _ n: Int) -> RailEntry? {
        shell.slots.first { $0.source == .claudeApp(sessionID: Self.id(n)) }
    }

    // MARK: 게이트

    @Test func desktopRingsNeedTheListTheIssueScreensAndAnAccountAndTheModelIsOnlyHeldThen() async {
        let on = await rig(rows: [1], live: [Self.live(1, .busy)])
        #expect(on.shell.desktop != nil && desktopEntry(on.shell, 1) != nil)
        let script = DeskScript()
        script.sessions = [Self.live(1, .busy)]
        let model = ClaudeAppSessionsModel(poll: { script.poll() }, done: InMemoryClaudeAppDoneStore())
        await model.pollOnce()
        for off in [X().make(store: false, desktop: model), X().make(gated: false, desktop: model), X().make(signedIn: false, desktop: model)] {
            off.shell.desktopChanged()
            #expect(!off.shell.slots.contains { if case .claudeApp = $0.source { true } else { false } }, "목록 · 새 Issues 화면 · 로그인이 없으면 데스크톱 링이 없다")
        }
        #expect(X().make(store: false, desktop: model).shell.desktop == nil && X().make(gated: false, desktop: model).shell.desktop == nil, "게이트가 꺼진 셸은 모델을 아예 들지 않는다")
    }

    // MARK: 링: 이름 · 말 · 순서 · 용량

    @Test func aLiveDesktopSessionIsARingNamedByTheListWithTheApprovedWordsAndNoWorkState() async {
        let r = await rig(rows: [1, 9, 10], live: [Self.live(1, .busy), Self.live(9, .waiting(.approval)), Self.live(10, .waiting(.answer))])
        let one = desktopEntry(r.shell, 1), nine = desktopEntry(r.shell, 9), ten = desktopEntry(r.shell, 10)
        #expect(one?.title == "Session 1" && one?.kind == .running && one?.activity == "Running in Claude")
        #expect(nine?.kind == .needsYou && nine?.activity == "Needs approval in Claude")
        #expect(ten?.kind == .needsYou && ten?.activity == "Needs your answer in Claude")
        #expect([one, nine, ten].allSatisfy { $0?.state == nil }, "Taskforce 업무 상태가 없다")
        #expect(one?.accessibilityLabel == "Session 1 · Running in Claude", "이름은 \"제목 · 활동\"")
        let kinds = r.shell.slots.map(\.kind)
        #expect(kinds == [.needsYou, .needsYou, .running], "주황이 먼저")
    }

    @Test func aSessionTheListDoesNotKnowYetIsNamedByTheAgentAndTheTooltipHasNoWorkState() async {
        let r = await rig(rows: [], live: [Self.live(3, .busy)])
        let entry = try? #require(desktopEntry(r.shell, 3))
        #expect(entry?.title == "Claude Code", "목록에 아직 없으면 에이전트 이름")
        r.shell.pointer(inside: true)
        r.time.advance(TFMotion.railHoverDelay + 0.01)
        r.shell.hover(item: entry?.id)
        #expect(r.shell.tooltip?.title == "Claude Code" && r.shell.tooltip?.detail == "· Running in Claude", "업무 상태 없이 \"제목 · 활동\"")
    }

    @Test func desktopAndTaskforceRingsShareTheCapsuleWithTheSameOrderAndTheSameCapacity() async {
        let live = [Self.live(1, .busy), Self.live(9, .waiting(.approval)), Self.live(10, .waiting(.answer)), Self.live(11, .busy), Self.live(12, .busy)]
        let r = await rig(sessions: .basic, rows: [1, 9, 10, 11, 12], live: live)
        r.shell.sessionsChanged()
        #expect(r.shell.slots.count == RailOrdering.capacity && r.shell.notch.count == RailOrdering.notchCapacity)
        let ranks = r.shell.slots.map { RailOrdering.priority($0.kind) }
        #expect(ranks == ranks.sorted(), "needs-you → running → done 순서는 두 출처가 같다")
        #expect(r.shell.slots.contains { $0.source == .issue } && r.shell.slots.contains { if case .claudeApp = $0.source { true } else { false } }, "둘이 한 캡슐을 나눠 쓴다")
        #expect(r.shell.notch.allSatisfy { RailOrdering.isLead($0.kind) })
    }

    // MARK: 끝난 링은 열어 볼 때까지 남는다

    @Test func aFinishedDesktopRingStaysUntilItIsOpenedWithNoTimerAndSurvivesInTheStore() async {
        let r = await rig(rows: [10], live: [Self.live(10, .busy)])
        await r.poll([Self.live(10, .idle)])
        let done = desktopEntry(r.shell, 10)
        #expect(done?.kind == .done && done?.activity == "Done", "\"Done just now\"는 링이 몇 시간 남으면 거짓이다")
        r.time.advance(3 * 3600)
        r.shell.expireDone()
        #expect(desktopEntry(r.shell, 10)?.kind == .done, "시간이 지나도 남는다")
        #expect(r.doneStore.load()[Self.id(10)] != nil, "다시 켠 뒤에도 남도록 저장한다")
        r.shell.openRailEntry(done!)
        r.shell.desktopChanged()
        #expect(r.doneStore.load().isEmpty && desktopEntry(r.shell, 10) == nil, "열어 보면 내려간다")
        #expect(r.desktop.rail.isEmpty)
        r.shell.dismiss()
    }

    @Test func aFinishedTaskforceRingStaysUntilTheSessionIsOpenedFromSessions() async {
        let r = await rig(sessions: .basic)
        r.base.gateway.sessions = .finished
        await r.base.issues.sessions.refresh()
        r.shell.sessionsChanged()
        let ring = r.shell.slots.first { $0.id == Fx.issue(139) }
        #expect(ring?.kind == .done && ring?.activity == "Done")
        #expect(r.railDone.load().sessions[Fx.session(1)] != nil)
        r.time.advance(3 * 3600)
        r.shell.expireDone()
        #expect(r.shell.slots.contains { $0.id == Fx.issue(139) && $0.kind == .done }, "3초 뒤에도 남는다")
        r.shell.openSessions()
        r.shell.openSessionRow(Fx.session(1))
        r.shell.sessionsChanged()
        #expect(!r.shell.slots.contains { $0.id == Fx.issue(139) && $0.kind == .done }, "세션을 열어 보면 내려간다")
        #expect(r.railDone.load().sessions.isEmpty)
    }

    @Test func aShellWithoutADoneStoreKeepsTheOldTimedDoneAndItsWords() async {
        let time = EdgeShellModelTests.ManualTime()
        let base = X().make(sessions: .basic, time: time)
        await base.issues.sessions.refresh()
        base.shell.update(Fx.snapshot(seeds: Fx.seeds))
        base.gateway.sessions = .finished
        await base.issues.sessions.refresh()
        base.shell.sessionsChanged()
        #expect(base.shell.slots.first { $0.id == Fx.issue(139) }?.activity == "Done just now", "저장소가 없는 셸(Assistant 쪽)은 지금 그대로 \"Done just now\" · 3초")
        #expect(base.issues.sessions.items.first { $0.id == Fx.session(1) }?.line == "Done just now")
    }

    // MARK: 열기

    @Test func clickingADesktopRingOpensOneReadOnlyPanelBesideTheRailAndCountsTheDayOnce() async {
        let r = await rig(rows: [1, 9], live: [Self.live(1, .busy), Self.live(9, .waiting(.approval))])
        let entry = desktopEntry(r.shell, 1)!
        r.shell.openRailEntry(entry)
        #expect(r.shell.panelOpen && r.shell.view == .claudeApp && r.shell.desktopPanelID == Self.id(1) && r.shell.desktopPanelShown)
        #expect(r.shell.sessionPanelID == nil && r.shell.openItem == nil, "이슈 패널 없이 한 패널")
        #expect(await until { r.sent.count == 1 })
        let conversation = r.shell.desktopConversation
        #expect(conversation?.sessionID == Self.id(1))
        #expect(await until { conversation?.phase == .ready && r.transcript.opened == [Self.id(1)] })
        r.shell.openRailEntry(desktopEntry(r.shell, 9)!)
        #expect(r.shell.desktopPanelID == Self.id(9) && r.shell.desktopConversation?.sessionID == Self.id(9), "다른 링을 누르면 그 세션으로 바뀐다")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(r.sent.count == 1, "지표는 하루 한 번만 (종류만 — 어느 세션인지는 보내지 않는다)")
        r.shell.dismiss()
    }

    @Test func clickingARowOpensTheSessionBesideSessionsAndTheSameRowClosesIt() async {
        let r = await rig(rows: [1], live: [Self.live(1, .busy)])
        r.shell.openSessions()
        r.shell.openDesktopSession(Self.id(1), from: .list)
        #expect(r.shell.view == .sessions && r.shell.desktopPanelID == Self.id(1) && r.shell.desktopPanelShown, "Sessions는 그대로 두고 그 왼쪽에 선다")
        r.shell.openDesktopSession(Self.id(1), from: .list)
        #expect(r.shell.desktopPanelID == nil && r.shell.view == .sessions && r.shell.panelOpen, "같은 줄을 다시 누르면 닫는다")
        r.shell.dismiss()
    }

    @Test func theLeftPanelIsOneAtATimeATaskforceRowAndADesktopRowReplaceEachOther() async {
        let r = await rig(sessions: .basic, rows: [1], live: [Self.live(1, .busy)])
        r.shell.openSessions()
        r.shell.openSessionRow(Fx.session(1))
        #expect(r.shell.sessionPanelID == Fx.session(1) && r.shell.desktopPanelID == nil)
        r.shell.openDesktopSession(Self.id(1), from: .list)
        #expect(r.shell.desktopPanelID == Self.id(1) && r.shell.sessionPanelID == nil, "왼쪽 패널은 하나")
        r.shell.openSessionRow(Fx.session(2))
        #expect(r.shell.sessionPanelID == Fx.session(2) && r.shell.desktopPanelID == nil)
        r.shell.openSessionRow(Fx.session(2))
        #expect(r.shell.sessionPanelID == nil, "같은 줄을 다시 누르면 닫는다")
        r.shell.dismiss()
    }

    @Test func aShellWithoutADesktopModelOrSessionsIgnoresTheDesktopOpens() async {
        let noModel = X().make()
        noModel.shell.openSessions()
        noModel.shell.openDesktopSession(Self.id(1), from: .list)
        #expect(noModel.shell.desktopPanelID == nil && noModel.shell.desktopConversation == nil)
        let signedOut = X().make(signedIn: false)
        signedOut.shell.openDesktopSession(Self.id(1), from: .rail)
        #expect(!signedOut.shell.panelOpen)
        let r = await rig(rows: [1], live: [Self.live(1, .busy)])
        r.shell.openPanel(.claudeApp)
        #expect(r.shell.view == .sessions && r.shell.desktopPanelID == nil, "열어 둔 세션이 없는 .claudeApp은 Sessions로 연다 (⌥ Space의 마지막 화면)")
    }

    @Test func escClosesTheLeftPanelFirstBesideSessionsAndTheWholePanelForTheOneBesideTheRail() async {
        let r = await rig(rows: [1], live: [Self.live(1, .busy)])
        r.shell.openRailEntry(desktopEntry(r.shell, 1)!)
        #expect(r.shell.view == .claudeApp)
        r.shell.escape()
        #expect(!r.shell.panelOpen, "레일 옆 한 패널은 Esc가 패널째 접는다")
        r.shell.openSessions()
        #expect(r.shell.desktopPanelID == Self.id(1), "열어 둔 세션은 마지막 화면으로 남아 Sessions를 열면 그 왼쪽에 다시 선다")
        r.shell.escape()
        #expect(r.shell.panelOpen && r.shell.view == .sessions && r.shell.desktopPanelID == nil, "먼저 왼쪽 패널만")
        r.shell.escape()
        #expect(!r.shell.panelOpen)
    }

    @Test func movingBetweenScreensKeepsTheViewedSessionOnlyAcrossSessionsAndTheOneBesideTheRail() async {
        let r = await rig(rows: [1], live: [Self.live(1, .busy)])
        r.shell.openRailEntry(desktopEntry(r.shell, 1)!)
        r.shell.openSessions()
        #expect(r.shell.view == .sessions && r.shell.desktopPanelID == Self.id(1), "Sessions로 가면 그 왼쪽에 그대로")
        r.shell.openAllWork()
        #expect(r.shell.desktopPanelID == nil && r.shell.desktopConversation == nil, "다른 화면으로 가면 닫고 읽기를 멈춘다")
        r.shell.dismiss()
        r.shell.openRailEntry(desktopEntry(r.shell, 1)!)
        r.shell.dismiss()
        r.shell.togglePanel()
        #expect(r.shell.panelOpen && r.shell.view == .claudeApp && r.shell.desktopPanelID == Self.id(1), "⌥ Space는 마지막 화면 그대로")
        r.shell.dismiss()
    }

    @Test func theAccountLeavingClosesTheViewAndGoesBackToAllWork() async {
        let r = await rig(rows: [1], live: [Self.live(1, .busy)])
        r.shell.openRailEntry(desktopEntry(r.shell, 1)!)
        r.shell.accountChanged(nil)
        #expect(r.shell.view == .allWork && r.shell.desktopPanelID == nil && !r.shell.desktopPanelShown && !r.shell.sessionsVisible)
    }

    // MARK: 읽기 전용 세션 보기의 대화 · 상태

    @Test func theConversationIsReadOnlyWhileTheViewIsShownAndTheViewedSessionIsToldToThePoller() async {
        let r = await rig(rows: [1], live: [Self.live(1, .busy)])
        r.shell.openRailEntry(desktopEntry(r.shell, 1)!)
        let conversation = r.shell.desktopConversation
        #expect(await until { conversation?.phase == .ready })
        #expect(conversation?.turns.count == 3 && conversation?.hasEarlier == false)
        // 보는 동안 Claude에서 닫으면(세 번 연달아 사라짐) 상태 말이 "Closed in Claude"가 된다
        for _ in 0..<5 { await r.poll([]) }
        #expect(r.desktop.viewingClosed && r.desktop.liveStatus(for: Self.id(1)) == nil)
        #expect(ClaudeAppSessionPanelView.statusLine(status: nil, closed: true, folder: "proj") == "Closed in Claude · proj")
        r.shell.dismiss()
        #expect(!r.desktop.viewingClosed, "패널을 접으면 보고 있는 세션이 없다")
    }

    @Test func anUnreadableTranscriptShowsTheFailedPhaseAndTryAgainReadsItAgain() async {
        let r = await rig(rows: [1], live: [Self.live(1, .busy)])
        r.transcript.unreadable = true
        r.shell.openRailEntry(desktopEntry(r.shell, 1)!)
        let conversation = r.shell.desktopConversation
        #expect(await until { conversation?.phase == .failed })
        r.transcript.unreadable = false
        conversation?.retry()
        #expect(await until { conversation?.phase == .ready })
        r.shell.dismiss()
    }

    @Test func aDesktopHeaderSaysTheStatusAndTheFolderNameNeverThePath() async {
        let r = await rig(rows: [1], live: [Self.live(1, .busy, cwd: "/Users/tester/secret-project")])
        #expect(r.shell.desktopFolderName(Self.id(1)) == "proj1", "목록의 줄이 있으면 그 폴더 이름 (경로가 아니다)")
        let bare = await rig(rows: [], live: [Self.live(4, .busy, cwd: "/Users/tester/secret-project")])
        #expect(bare.shell.desktopFolderName(Self.id(4)) == "secret-project", "목록에 없으면 등록 파일의 작업 폴더 이름")
        let none = await rig(rows: [], live: [Self.live(5, .busy, cwd: nil)])
        #expect(none.shell.desktopFolderName(Self.id(5)) == nil)
        let status = ClaudeAppSessionPanelView.statusLine
        #expect(status(.running, false, "proj") == "Running in Claude · proj")
        #expect(status(.needsApproval, false, "proj") == "Needs approval in Claude · proj")
        #expect(status(.needsAnswer, false, nil) == "Needs your answer in Claude")
        #expect(status(.idle, false, "proj") == "Idle · proj" && status(.done, false, "proj") == "Done · proj")
        #expect(status(nil, false, "proj") == "proj", "아직 상태를 모르면 폴더 이름만")
        #expect(status(nil, false, nil) == nil)
        #expect(status(.running, true, "proj") == "Closed in Claude · proj", "닫혔으면 상태 말이 닫힘")
    }

    @Test func theTranscriptLinesAreDrawnFromTheTurnsAndTheToolLineIsNameAndDescriptionOnly() {
        #expect(ClaudeAppTurnView.toolLine(name: "Bash", description: "Run the copy lint") == "Bash · Run the copy lint")
        #expect(ClaudeAppTurnView.toolLine(name: "Read", description: nil) == "Read" && ClaudeAppTurnView.toolLine(name: "Read", description: "") == "Read")
        #expect(ClaudeAppTurnView.shown("a long reply", truncated: true) == "a long reply…" && ClaudeAppTurnView.shown("short", truncated: false) == "short")
    }

    /// 머리의 Open in Claude는 띠가 같은 단추를 가져가면 빠진다 (한 화면에 같은 단추 하나): 머리 오른쪽 자리의 그림으로 본다
    @Test func theHeaderOpenInClaudeButtonIsGoneWhileTheApprovalBandHasItsOwn() async throws {
        func render(_ state: ClaudeAppSessionState) async throws -> (picture: Data, presentation: EdgeClaudeAppPanelPresentation) {
            let r = await rig(rows: [1], live: [Self.live(1, state)])
            r.shell.openRailEntry(desktopEntry(r.shell, 1)!)
            let presentation = EdgeClaudeAppPanelPresentation()
            presentation.shown = true
            let hosting = NSHostingView(rootView: ClaudeAppSessionPanelView(shell: r.shell, presentation: presentation))
            hosting.frame = NSRect(x: 0, y: 0, width: 380, height: 520)
            let panel = EdgeKeyPanel(contentRect: hosting.frame, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
            panel.contentView = hosting
            panel.orderFront(nil)
            defer { panel.orderOut(nil) }
            hosting.layoutSubtreeIfNeeded()
            _ = await until { presentation.headHeight > 0 && r.shell.desktopConversation?.phase == .ready }
            try? await Task.sleep(for: .milliseconds(200))
            let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            r.shell.dismiss()
            return (try #require(rep.representation(using: .png, properties: [:])), presentation)
        }
        let running = try await render(.busy)
        let approval = try await render(.waiting(.approval))
        #expect(running.presentation.headHeight - approval.presentation.headHeight == 4, "머리의 높이는 알약(24) 때문에 4 더 크다: 알약이 빠지면 제목 줄(20)만큼 (\(running.presentation.headHeight) · \(approval.presentation.headHeight))")
        #expect(running.presentation.footerHeight == TFSpace.sm, "띠가 없으면 입력창 자리에 아래 여백뿐 (입력창 없음)")
        #expect(approval.presentation.footerHeight > 60, "승인을 기다리면 띠가 선다")
        #expect(X.regionDiffers(running.picture, approval.picture, x: 270...372, y: 8...32), "머리 오른쪽의 알약이 띠가 설 때만 빠진다")
    }

    // MARK: Sessions 패널이 보이는 것 (순수 판단)

    private func taskforceRow() -> SessionsTaskforceRow {
        SessionsTaskforceRow(id: UUID(), name: "Pricing", agent: .claudeCode, ring: .running, isClosed: false, metaText: "Running · now", accessibilityName: "Pricing")
    }

    private func macRow() -> SessionsMacRow {
        SessionsMacRow(id: Self.id(1), row: Self.heldRow(1), line: ExternalSessionLineText.make(Self.heldRow(1), now: Date()), ring: nil, opensSession: false)
    }

    @Test func theSessionsPanelPlanShowsNoSessionsOnlyOnceBothSectionsAreReadAndEmpty() {
        typealias Body = SessionsPanelBody
        let noTaskforce = SessionsSection<SessionsTaskforceRow>(rows: [], hiddenCount: 0, togglesFold: false, expanded: false)
        let noMac = SessionsSection<SessionsMacRow>(rows: [], hiddenCount: 0, togglesFold: false, expanded: false)
        let someTaskforce = SessionsSection(rows: [taskforceRow()], hiddenCount: 0, togglesFold: false, expanded: false)
        let someMac = SessionsSection(rows: [macRow()], hiddenCount: 0, togglesFold: false, expanded: false)
        func plan(_ t: SessionsSection<SessionsTaskforceRow>, _ m: SessionsSection<SessionsMacRow>, _ phase: ExternalSessionsStore.Phase?, read: Bool = true) -> Body.Plan {
            Body.plan(taskforce: t, mac: m, phase: phase, taskforceRead: read)
        }
        #expect(plan(noTaskforce, noMac, .ready) == .init(noSessions: true, taskforce: false, mac: .absent))
        #expect(plan(noTaskforce, noMac, .empty) == .init(noSessions: true, taskforce: false, mac: .absent), "최근 세션이 없는 것도 읽은 뒤의 빈 상태")
        #expect(plan(noTaskforce, noMac, nil) == .init(noSessions: true, taskforce: false, mac: .absent), "목록이 없는 셸도 Taskforce가 비면 No sessions")
        #expect(!plan(noTaskforce, noMac, .ready, read: false).noSessions, "Taskforce 세션을 아직 읽지 않았으면 비었다고 하지 않는다")
        #expect(plan(noTaskforce, noMac, .checking) == .init(noSessions: false, taskforce: false, mac: .checking), "읽는 중은 그 절 안의 한 줄")
        #expect(plan(noTaskforce, noMac, .idle).mac == .checking)
        #expect(plan(noTaskforce, noMac, .failed) == .init(noSessions: false, taskforce: false, mac: .failed))
        #expect(plan(noTaskforce, noMac, .notInstalled) == .init(noSessions: false, taskforce: false, mac: .notInstalled))
        #expect(plan(someTaskforce, noMac, .failed) == .init(noSessions: false, taskforce: true, mac: .failed), "못 읽어도 Taskforce 세션은 그대로 보인다")
        #expect(plan(someTaskforce, noMac, .checking).taskforce)
        #expect(plan(someTaskforce, noMac, .ready) == .init(noSessions: false, taskforce: true, mac: .absent), "빈 절은 머리째 없다")
        #expect(plan(noTaskforce, someMac, .ready) == .init(noSessions: false, taskforce: false, mac: .rows))
        #expect(plan(someTaskforce, someMac, .ready) == .init(noSessions: false, taskforce: true, mac: .rows))
    }

    // MARK: 실제 패널의 클릭

    /// 실제 패널(`EdgePanelView`)에서 살아 있는 데스크톱 줄: 줄을 누르면 Claude 세션 보기가 열리고, 줄 끝의 Open in Claude는 앱만 앞으로 가져온다 (CLI를 돌리지 않는다)
    @Test func inTheRealSessionsPanelALiveRowOpensTheViewAndItsButtonOnlyActivatesTheApp() async {
        ExternalSessionLineSnapshot.hoveredTitles.insert("Session 1")
        let r = await rig(rows: [1], live: [Self.live(1, .busy)])
        r.shell.openSessions()
        let presentation = EdgePanelPresentation()
        presentation.shown = true
        let hosting = NSHostingView(rootView: EdgePanelView(shell: r.shell, presentation: presentation, chat: nil))
        hosting.frame = NSRect(x: 0, y: 0, width: 380, height: 520)
        let panel = EdgeKeyPanel(contentRect: hosting.frame, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.contentView = hosting
        panel.makeKeyAndOrderFront(nil)
        defer { panel.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(400))
        func click(_ point: CGPoint) async {
            let location = hosting.convert(point, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
                ) { panel.sendEvent(event) }
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        // 버튼: 줄 끝 (x 306). 앱만 앞으로, 세션 보기는 열리지 않는다
        var buttonY: Int?
        for y in stride(from: 60, to: 200, by: 4) {
            let before = r.base.app.opened
            await click(CGPoint(x: 306, y: y))
            if r.base.app.opened > before {
                buttonY = y
                break
            }
        }
        #expect(buttonY != nil, "줄 끝의 Open in Claude가 눌린다")
        #expect(r.base.app.sessions.isEmpty && r.shell.desktopPanelID == nil, "Claude 앱이 쥔 세션이라 앱만 앞으로: CLI를 돌리지 않고 세션 보기도 열지 않는다")
        // 줄 본문 (x 100): 세션 보기가 열린다
        var rowY: Int?
        for y in stride(from: 60, to: 200, by: 4) {
            await click(CGPoint(x: 100, y: y))
            if r.shell.desktopPanelID != nil {
                rowY = y
                break
            }
        }
        #expect(rowY != nil && r.shell.desktopPanelID == Self.id(1), "줄을 누르면 Claude 세션 보기가 Sessions 왼쪽에 열린다")
        #expect(r.shell.view == .sessions)
        r.shell.dismiss()
    }

    // MARK: 컨트롤러: 창

    private func key(_ code: Int, flags: NSEvent.ModifierFlags = .command) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: "4", charactersIgnoringModifiers: "4",
            isARepeat: false, keyCode: UInt16(code)
        ))
    }

    @MainActor
    private struct Windows {
        let controller: EdgeShellController
        let script: DeskScript
        let desktop: ClaudeAppSessionsModel
        let store: ExternalSessionsStore
        var shell: EdgeShellModel { controller.shell }
        var claude: EdgeClaudeAppPanelController { controller.claudePanel! }
    }

    private func windows(live: [ClaudeAppSession]) async throws -> Windows {
        let account = try AppChatAccount.make()
        let runtime = ChatRuntime(gateway: IssueSampleGateway(), contextGateway: IssueSampleContextGateway(), scope: account.scope, now: { Date() }, issueScreens: true)
        let script = DeskScript()
        script.sessions = live
        let counter = X.Counter()
        counter.set(live.enumerated().map { Self.heldRow($0.offset + 1) })
        let store = ExternalSessionsStore(scope: account.scope, scan: { counter.scan() }, seen: InMemoryExternalSessionSeenStore(Date(timeIntervalSinceNow: -10_000)), pollInterval: 3600)
        let desktop = ClaudeAppSessionsModel(poll: { script.poll() }, scope: account.scope, done: InMemoryClaudeAppDoneStore())
        let made = ClaudeAppRuntime.Made(sessions: desktop, opened: ClaudeAppOpenedMetric(send: { true }, scope: account.scope))
        let controller = EdgeShellController(
            launcher: LauncherModel(configurationError: "test"), chat: runtime, assistantWindows: false, injectedExternalSessions: store, injectedDesktop: made
        )
        controller.ignoresExternalDismissal = false
        // 다른 시험이 만든 키 창이 이 패널의 "키를 잃음"을 부를 수 있다(시험은 한 프로세스에서 나란히 돈다): 키 창은 늘 이 컨트롤러의 창이라고 답해 그 알림이 패널을 접지 못하게 한다.
        // 키를 잃어 접히는 길 자체는 마지막 시험이 이 값을 직접 바꿔 확인한다
        controller.keyWindow = { [weak controller] in
            guard let controller else { return nil }
            return controller.claudePanel?.isVisible == true ? controller.claudePanel?.panel : controller.panel.panel
        }
        controller.shell.accountChanged(SampleData.userID)
        controller.shell.makeConversation = { id, cwd in ClaudeAppConversation(sessionID: id, cwd: cwd, source: TranscriptFake()) }
        await store.refresh()
        await desktop.pollOnce()
        controller.shell.update(Fx.snapshot(seeds: Fx.seeds))
        controller.shell.desktopChanged()
        controller.followPanel()
        controller.followClaudePanel()
        return Windows(controller: controller, script: script, desktop: desktop, store: store)
    }

    @Test func theClaudePanelWindowStandsAloneForARingAndBesideSessionsForARowAndFollowsTheShell() async throws {
        _ = try #require(EdgeRailPanelController.screen, "화면이 있어야 창 자리를 잰다")
        let w = try await windows(live: [Self.live(1, .busy)])
        defer {
            w.shell.dismiss()
            w.controller.followPanel()
        }
        #expect(w.controller.claudePanel != nil && w.shell.desktop != nil)
        // 레일의 링: 메인 패널 창은 뜨지 않고 Claude 세션 패널 하나가 레일 옆에 선다
        w.shell.openRailEntry(w.shell.slots.first { $0.source == .claudeApp(sessionID: Self.id(1)) }!)
        #expect(await until { w.claude.isVisible && w.claude.presentation.shown })
        #expect(!w.controller.panel.isVisible, "메인 패널 창은 한 패널일 때 뜨지 않는다")
        #expect(w.controller.hasMonitors, "바깥 클릭 · 키 모니터는 이 창에서도 있다")
        let rightEdge = EdgePanelMetrics.rightEdge(screenMaxX: EdgeRailPanelController.screen!.frame.maxX, capsule: true)
        #expect(await until { abs(w.claude.panel.frame.maxX - rightEdge) < 1 }, "여는 움직임이 끝나면 메인 패널 자리")
        // Sessions를 열면 메인 패널이 뜨고 Claude 패널은 그 왼쪽으로 옮겨 선다
        w.shell.openSessions()
        #expect(await until { w.controller.panel.isVisible && w.controller.panel.targetFrame() != nil })
        let main = try #require(w.controller.panel.targetFrame())
        #expect(await until { abs(w.claude.panel.frame.maxX - (main.minX - 40)) < 1 && abs(w.claude.panel.frame.maxY - main.maxY) < 1 }, "메인 패널 왼쪽 40, 위 맞춤")
        // Esc: 왼쪽 패널만 접힌다
        _ = try #require(w.controller.handleKeyForTest(code: kVK_Escape, flags: []))
        #expect(await until { !w.claude.presentation.shown })
        #expect(w.shell.panelOpen && w.controller.panel.isVisible)
        // 패널을 접으면 모두 내려간다
        w.shell.dismiss()
        w.controller.followPanel()
        #expect(await until { !w.controller.panel.presentation.shown && !w.controller.hasMonitors })
    }

    @Test func commandFourOpensSessionsOnlyInAShellThatHasTheSessionsButton() async throws {
        let w = try await windows(live: [])
        defer {
            w.shell.dismiss()
            w.controller.followPanel()
        }
        #expect(EdgeSessionsKey.matches(keyCode: kVK_ANSI_4, flags: .command) && !EdgeSessionsKey.matches(keyCode: kVK_ANSI_4, flags: []) && !EdgeSessionsKey.matches(keyCode: kVK_ANSI_4, flags: [.command, .shift]))
        #expect(w.controller.handleKey(try key(kVK_ANSI_4)))
        #expect(w.shell.panelOpen && w.shell.view == .sessions)
        w.shell.dismiss()
        let account = try AppChatAccount.make()
        let plain = EdgeShellController(launcher: LauncherModel(configurationError: "test"), chat: ChatRuntime(gateway: IssueSampleGateway(), contextGateway: IssueSampleContextGateway(), scope: account.scope, now: { Date() }, issueScreens: false), assistantWindows: false)
        #expect(!plain.handleKey(try key(kVK_ANSI_4)) && !plain.shell.panelOpen, "Sessions 버튼이 없는 셸은 ⌘4가 지나간다")
        #expect(EdgeKeyCommand.of(keyCode: kVK_ANSI_4, flags: .command) == nil, "Assistant 창의 키 해석은 그대로다")
    }

    @Test func theClaudePanelCountsAsAnIssueWindowSoFocusMovingToItDoesNotFoldThePanel() async throws {
        _ = try #require(EdgeRailPanelController.screen)
        let w = try await windows(live: [Self.live(1, .busy)])
        defer {
            w.shell.dismiss()
            w.controller.followPanel()
        }
        w.shell.openSessions()
        w.shell.openDesktopSession(Self.id(1), from: .list)
        w.controller.followPanel()
        w.controller.followClaudePanel()
        #expect(await until { w.claude.isVisible })
        w.controller.keyWindow = { w.claude.panel }
        w.controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(w.shell.panelOpen, "키가 Claude 세션 패널로 옮겨 간 것은 패널을 잃은 것이 아니다")
        w.controller.keyWindow = { nil }
        w.controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        #expect(await until { !w.shell.panelOpen }, "그 밖의 창으로 가면 접는다")
    }
}

extension EdgeShellController {
    /// 시험용: 키 코드 하나를 `handleKey`에 보낸다
    func handleKeyForTest(code: Int, flags: NSEvent.ModifierFlags) -> Bool? {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: UInt16(code)
        ) else { return nil }
        return handleKey(event)
    }
}
