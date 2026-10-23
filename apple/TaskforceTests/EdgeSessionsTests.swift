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
    /// - chat: 데스크톱 세션과 대화하는 흐름 (OA PR-D3, 없으면 읽기 전용 그대로)
    func rig(sessions: IssueSampleGateway.SessionScenario = .none, rows: [Int] = [], live: [ClaudeAppSession] = [], chat: ClaudeAppChatService? = nil) async -> Rig {
        let script = DeskScript()
        script.sessions = live
        let scope = AccountScope(currentAccount: { SampleData.userID })
        let doneStore = InMemoryClaudeAppDoneStore()
        let desktop = ClaudeAppSessionsModel(poll: { script.poll() }, scope: scope, done: doneStore)
        let sent = SendCounter()
        let metric = ClaudeAppOpenedMetric(send: { sent.hit(); return true }, scope: scope)
        let railDone = InMemoryRailDoneStore()
        let time = EdgeShellModelTests.ManualTime()
        let base = X().make(sessions: sessions, desktop: desktop, railDone: railDone, opened: metric, scope: scope, time: time, desktopChat: chat)
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

    // MARK: 이슈의 끝남은 자정이 지나도 · 다시 켜도 열 때까지 남는다 (코드 검토 P3)

    private static let finishedIssue = Fx.Seed(number: 141, title: "Wire EdgeRail rings to live session state", state: .done, dueOffset: nil, projects: [Fx.taskforce])
    private static let reopenedIssue = Fx.Seed(number: 141, title: "Wire EdgeRail rings to live session state", state: .inProgress, dueOffset: nil, projects: [Fx.taskforce])
    /// 141이 어느 목록에도 없는 날의 스냅샷 (자정이 지나 오늘 끝난 일이 비었다)
    private static var nextDay: EdgeWorkSnapshot { Fx.snapshot(seeds: Fx.seeds.filter { $0.number != 141 && $0.state != .done }) }

    private func issueRing(_ shell: EdgeShellModel) -> RailEntry? { shell.slots.first { $0.id == Fx.issue(141) } }

    @Test func aFinishedIssueRingSurvivesTheDoneTodayWindowRollingOverAndALaterRelaunchUntilItIsOpened() async {
        let railDone = InMemoryRailDoneStore()
        let base = X().make(railDone: railDone)
        base.shell.update(Fx.snapshot(seeds: Fx.seeds))
        #expect(issueRing(base.shell)?.kind == .running, "141은 일하는 중이다")
        base.shell.update(Fx.snapshot(seeds: Fx.seeds.filter { $0.number != 141 } + [Self.finishedIssue]))
        #expect(issueRing(base.shell)?.kind == .done && railDone.load().issues[Fx.issue(141)] != nil, "끝났다: 초록 링 + 저장")
        // 자정이 지났다: 141은 오늘 끝난 일에서 빠졌다 (열린 일도 아니다)
        base.shell.update(Self.nextDay)
        #expect(issueRing(base.shell)?.kind == .done && issueRing(base.shell)?.activity == "Done", "오늘 끝난 일에서 빠져도 열어 보기 전에는 링이 남는다")
        #expect(railDone.load().issues[Fx.issue(141)] != nil, "표시도 지우지 않는다")
        // 다음 날 앱을 다시 켰다: 같은 저장소를 새 셸이 읽는다. 목록을 읽어도 표시를 지우지 않는다
        let relaunched = X().make(railDone: railDone)
        relaunched.shell.lookupFinishedIssue = { _ in .unknown }
        relaunched.shell.update(Self.nextDay)
        #expect(railDone.load().issues[Fx.issue(141)] != nil, "다시 켠 뒤 목록을 읽어도 (이슈를 id로 읽지 못하면) 표시는 남는다")
        // 열어 보면 내려가고 저장도 지워진다
        base.shell.markIssueOpened(Fx.issue(141))
        #expect(issueRing(base.shell) == nil && railDone.load().issues.isEmpty)
    }

    @Test func anIssueThatIsOpenAgainLosesItsDoneMarkBecauseItIsNotFinishedAnymore() async {
        let railDone = InMemoryRailDoneStore()
        let base = X().make(railDone: railDone)
        base.shell.update(Fx.snapshot(seeds: Fx.seeds))
        base.shell.update(Fx.snapshot(seeds: Fx.seeds.filter { $0.number != 141 } + [Self.finishedIssue]))
        #expect(railDone.load().issues[Fx.issue(141)] != nil)
        // 다시 열렸다 (To Do · In Progress, 일하지는 않는다)
        base.shell.update(Fx.snapshot(seeds: Fx.seeds.filter { $0.number != 141 } + [Self.reopenedIssue]))
        #expect(railDone.load().issues.isEmpty && issueRing(base.shell)?.kind != .done, "더는 끝난 일이 아니다")
    }

    // MARK: 다시 켠 뒤 표시만 남은 이슈: id로 읽어 링을 되살린다

    /// 138("Privacy policy beta 1.4")은 끝난 이슈다. 이 스냅샷에는 오늘 끝난 일 · 열린 일 어디에도 없다 (다음 날 다시 켰다)
    private static var todayWithout138: EdgeWorkSnapshot { Fx.snapshot(seeds: Fx.seeds.filter { $0.number != 138 && $0.state != .done }) }

    private func ring138(_ shell: EdgeShellModel) -> RailEntry? { shell.slots.first { $0.id == Fx.issue(138) } }

    /// 읽기를 열 때까지 붙잡아 두는 문 · 읽기를 센다
    private final class Gate: @unchecked Sendable {
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func open() { continuation?.resume(); continuation = nil }
    }

    private final class Asked: @unchecked Sendable {
        let lock = NSLock()
        var ids: [UUID] = []
        func record(_ id: UUID) { lock.withLock { ids.append(id) } }
        var count: Int { lock.withLock { ids.count } }
    }

    /// 기존 RLS 읽기(`issueDetail`)로: 샘플 서버는 138을 끝난 이슈(done)로 돌려준다
    @Test func aMarkedIssueThatIsNotInTodaysListIsReadByIdAndItsRingComesBackWithItsTitle() async throws {
        let railDone = InMemoryRailDoneStore()
        railDone.save(RailDoneMarks(issues: [Fx.issue(138): Date()], owner: SampleData.userID))
        let base = X().make(railDone: railDone)
        #expect(ring138(base.shell) == nil, "아직 읽기 전: 제목을 모르니 링이 없다")
        base.shell.update(Self.todayWithout138)
        #expect(await until { ring138(base.shell) != nil })
        let ring = try #require(ring138(base.shell))
        #expect(ring.kind == .done && ring.title == "Privacy policy beta 1.4" && ring.activity == "Done", "끝난 링이 제목과 함께 돌아온다")
        #expect(railDone.load().issues[Fx.issue(138)] != nil, "표시는 그대로")
        let saved = String(decoding: try JSONEncoder().encode(railDone.load()), as: UTF8.self)
        #expect(!saved.contains("Privacy"), "제목은 어디에도 저장하지 않는다")
        // 열어 보면 내려가고 저장도 지워진다
        base.shell.markIssueOpened(Fx.issue(138))
        #expect(ring138(base.shell) == nil && railDone.load().issues.isEmpty)
    }

    /// 다시 열린 이슈(139는 열린 일): 끝남 표시를 버린다
    @Test func aMarkedIssueThatWasReopenedLosesItsMarkAfterItIsReadById() async {
        let railDone = InMemoryRailDoneStore()
        railDone.save(RailDoneMarks(issues: [Fx.issue(139): Date()], owner: SampleData.userID))
        let base = X().make(railDone: railDone)
        base.shell.update(Fx.snapshot(seeds: Fx.seeds.filter { $0.number != 139 && $0.state != .done }))
        #expect(await until { railDone.load().issues.isEmpty })
        #expect(base.shell.slots.first { $0.id == Fx.issue(139) } == nil)
    }

    @Test func aMarkedIssueThatIsGoneOrCancelledLosesItsMarkAndAnUnreadableOneKeepsItAndIsAskedAgainLater() async {
        let railDone = InMemoryRailDoneStore()
        railDone.save(RailDoneMarks(issues: [Fx.issue(138): Date(), Fx.issue(154): Date()], owner: SampleData.userID))
        let time = EdgeShellModelTests.ManualTime()
        defer { withExtendedLifetime(time) {} }
        let base = X().make(railDone: railDone, time: time)
        let asked = Asked()
        base.shell.lookupFinishedIssue = { id in
            asked.record(id)
            // 138은 지워졌거나 취소했다, 154는 읽지 못했다
            return id == Fx.issue(138) ? .gone : .unknown
        }
        let snapshot = Fx.snapshot(seeds: Fx.seeds.filter { $0.number != 138 && $0.number != 154 && $0.state != .done })
        base.shell.update(snapshot)
        #expect(await until { railDone.load().issues[Fx.issue(138)] == nil })
        #expect(railDone.load().issues[Fx.issue(154)] != nil && asked.count == 2, "읽지 못한 이슈의 표시는 그대로다")
        // 곧 다시 알려도 다시 읽지 않는다 (읽지 못했을 때의 재시도 간격)
        base.shell.update(snapshot)
        try? await Task.sleep(for: .milliseconds(40))
        #expect(asked.count == 2, "간격 안에서는 다시 읽지 않는다")
        time.advance(EdgeShellModel.orphanRetryInterval + 1)
        base.shell.update(snapshot)
        #expect(await until { asked.count == 3 })
        #expect(railDone.load().issues[Fx.issue(154)] != nil, "여전히 읽지 못하면 표시는 그대로")
    }

    @Test func aLookupThatFinishesAfterTheAccountChangedIsIgnored() async {
        let railDone = InMemoryRailDoneStore()
        railDone.save(RailDoneMarks(issues: [Fx.issue(138): Date()], owner: SampleData.userID))
        let base = X().make(railDone: railDone)
        let gate = Gate()
        let summary = Fx.action(Fx.seeds.first { $0.number == 138 }!)
        base.shell.lookupFinishedIssue = { _ in
            await gate.wait()
            return .finished(summary)
        }
        base.shell.update(Self.todayWithout138)
        try? await Task.sleep(for: .milliseconds(30))
        base.shell.accountChanged(UUID())
        gate.open()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(ring138(base.shell) == nil, "읽는 사이 계정이 바뀌었으면 그 결과(다른 계정의 이슈)를 링으로 그리지 않는다")
    }

    /// 링이 돌아온 이슈(마지막으로 본 모습이 메모리에 있다)는 재시도 간격이 지나도 다시 읽지 않는다
    @Test func aRingThatCameBackIsNotReadAgainEvenAfterTheRetryInterval() async {
        let railDone = InMemoryRailDoneStore()
        railDone.save(RailDoneMarks(issues: [Fx.issue(138): Date()], owner: SampleData.userID))
        let time = EdgeShellModelTests.ManualTime()
        defer { withExtendedLifetime(time) {} }
        let base = X().make(railDone: railDone, time: time)
        let asked = Asked()
        let summary = Fx.action(Fx.seeds.first { $0.number == 138 }!)
        base.shell.lookupFinishedIssue = { id in
            asked.record(id)
            return .finished(summary)
        }
        base.shell.update(Self.todayWithout138)
        #expect(await until { ring138(base.shell) != nil })
        time.advance(EdgeShellModel.orphanRetryInterval + 1)
        base.shell.update(Self.todayWithout138)
        try? await Task.sleep(for: .milliseconds(40))
        #expect(asked.count == 1, "이미 모습을 아는 이슈는 다시 읽지 않는다")
    }

    /// 읽기가 아직 돌고 있으면 (재시도 간격이 지났어도) 같은 이슈를 또 읽기 시작하지 않는다
    @Test func aReadThatIsStillRunningIsNotStartedAgain() async {
        let railDone = InMemoryRailDoneStore()
        railDone.save(RailDoneMarks(issues: [Fx.issue(138): Date()], owner: SampleData.userID))
        let time = EdgeShellModelTests.ManualTime()
        defer { withExtendedLifetime(time) {} }
        let base = X().make(railDone: railDone, time: time)
        let asked = Asked()
        let gate = Gate()
        base.shell.lookupFinishedIssue = { id in
            asked.record(id)
            await gate.wait()
            return .unknown
        }
        base.shell.update(Self.todayWithout138)
        #expect(await until { asked.count == 1 })
        time.advance(EdgeShellModel.orphanRetryInterval + 1)
        base.shell.update(Self.todayWithout138)
        try? await Task.sleep(for: .milliseconds(40))
        #expect(asked.count == 1, "돌고 있는 읽기가 끝나기 전에는 또 시작하지 않는다")
        gate.open()
    }

    /// 새 계정이 같은 이슈 id의 끝남 표시를 이미 가진 경우에도(표시 검사만으로는 못 거른다) 이전 계정에서 읽던 결과가 새 계정의 링을 덮지 않는다
    @Test func aLateResultOfThePreviousAccountNeverOverwritesTheNewAccountsRing() async {
        let railDone = InMemoryRailDoneStore()
        railDone.save(RailDoneMarks(issues: [Fx.issue(141): Date()], owner: SampleData.userID))
        let base = X().make(railDone: railDone)
        let gate = Gate()
        let other = Fx.action(Fx.Seed(number: 141, title: "The previous account's issue", state: .done, dueOffset: nil, projects: [Fx.taskforce]))
        base.shell.lookupFinishedIssue = { _ in
            await gate.wait()
            return .finished(other)
        }
        base.shell.update(Self.nextDay)
        try? await Task.sleep(for: .milliseconds(30))
        // 계정이 B로 바뀌고, B도 141이 끝났다 (오늘 끝난 일에서는 곧 빠진다)
        base.shell.accountChanged(UUID())
        base.shell.update(Fx.snapshot(seeds: Fx.seeds))
        base.shell.update(Fx.snapshot(seeds: Fx.seeds.filter { $0.number != 141 } + [Self.finishedIssue]))
        base.shell.update(Self.nextDay)
        #expect(issueRing(base.shell)?.title == Self.finishedIssue.title, "B의 링은 B가 본 모습이다")
        gate.open()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(issueRing(base.shell)?.title == Self.finishedIssue.title, "이전 계정에서 읽던 결과가 늦게 와도 B의 링을 덮지 않는다")
    }

    /// 목록이 아직 없으면(읽는 중 · 오프라인 · 실패) 모든 표시가 목록에 없어 보인다: 그때는 읽지 않는다 (불필요한 읽기 · 요청 폭주를 막는다)
    @Test func noMarkIsReadWhileThereIsNoListYet() async {
        let railDone = InMemoryRailDoneStore()
        railDone.save(RailDoneMarks(issues: [Fx.issue(138): Date()], owner: SampleData.userID))
        let base = X().make(railDone: railDone)
        let asked = Asked()
        base.shell.lookupFinishedIssue = { id in
            asked.record(id)
            return .unknown
        }
        for load in [WorkLoad.loading, .offline, .failed] { base.shell.update(Fx.snapshot(seeds: [], load: load)) }
        try? await Task.sleep(for: .milliseconds(40))
        #expect(asked.count == 0 && railDone.load().issues[Fx.issue(138)] != nil)
        // 목록이 오면 그때 읽는다
        base.shell.update(Self.todayWithout138)
        #expect(await until { asked.count == 1 })
    }

    @Test func aMarkIsReadOnlyWhenTheShellKeepsMarksUntilOpened() async {
        // 새 Issues 화면이 없는 셸(노치 레일)은 표시를 열 때까지 두지 않는다 (3초): 목록에서 빠진 표시를 이슈로 읽지 않는다
        let shell = EdgeShellModel(schedule: { _, _ in EdgeTimer() }, chatsEnabled: true, windowsEnabled: true)
        var asked = 0
        shell.lookupFinishedIssue = { _ in
            asked += 1
            return .unknown
        }
        shell.update(Fx.snapshot(seeds: Fx.seeds))
        shell.update(Fx.snapshot(seeds: Fx.seeds.filter { $0.number != 141 } + [Self.finishedIssue]))
        #expect(issueRing(shell)?.kind == .done, "3초 모드에서도 방금 끝난 링은 있다 (표시가 쌓여 있다)")
        // 그 표시가 아직 안 지워졌는데 이슈가 어느 목록에도 없다
        shell.update(Self.nextDay)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(asked == 0)
    }

    // MARK: 끝남 표시의 주인 계정 (보안 P3-1)

    @Test func marksOfAnotherAccountAreForgottenWhenTheShellLearnsTheAccountAndThisAccountBecomesTheOwner() async {
        let railDone = InMemoryRailDoneStore()
        railDone.save(RailDoneMarks(sessions: [Fx.session(1): Date()], issues: [Fx.issue(141): Date()], owner: UUID()))
        let base = X().make(signedIn: false, sessions: .finished, railDone: railDone)
        await base.issues.sessions.refresh()
        base.shell.sessionsChanged()
        #expect(base.issues.sessions.items.contains { $0.ring == .done }, "아직 계정을 모른다: 저장해 둔 표시가 되살아나 있다")
        base.shell.accountChanged(SampleData.userID)
        base.shell.sessionsChanged()
        #expect(!base.issues.sessions.items.contains { $0.ring == .done }, "주인이 다른 세션 표시는 버린다")
        #expect(railDone.load() == RailDoneMarks(owner: SampleData.userID), "저장본도 비우고 이 계정을 주인으로 적는다")
        base.shell.update(Fx.snapshot(seeds: Fx.seeds.filter { $0.number != 141 } + [Self.finishedIssue]))
        #expect(issueRing(base.shell) == nil, "이슈 표시도 버렸다: 레일에 없던 일이 끝났다고 초록을 띄우지 않는다")
    }

    /// 계정이 곧바로 A에서 B로 바뀐다 (로그아웃 없이): "떠남"(저장본 비움)과 "계정을 앎"(주인 적기)이 어느 순서로 와도 B의 표시에는 B의 도장이 찍힌다
    /// (도장이 늦게 온 떠남에 지워져 다음에 켰을 때 B의 표시가 통째로 버려지는 일이 없다)
    @Test func aDirectAccountSwitchStampsTheNewOwnerWhicheverOrderTheLeaveAndTheChangeArrive() async {
        final class Who: @unchecked Sendable { var id = SampleData.userID }
        for leaveFirst in [true, false] {
            let who = Who()
            let b = UUID()
            let railDone = InMemoryRailDoneStore()
            let doneStore = InMemoryClaudeAppDoneStore()
            let script = DeskScript()
            let scope = AccountScope(currentAccount: { who.id })
            let desktop = ClaudeAppSessionsModel(poll: { script.poll() }, scope: scope, done: doneStore)
            let base = X().make(sessions: .basic, desktop: desktop, railDone: railDone, scope: scope)
            let name = "leaveFirst \(leaveFirst)"
            // A의 표시: 데스크톱 · Taskforce 세션 · 이슈
            script.sessions = [Self.live(10, .busy)]
            await desktop.pollOnce()
            script.sessions = [Self.live(10, .idle)]
            await desktop.pollOnce()
            base.shell.update(Fx.snapshot(seeds: Fx.seeds))
            base.shell.update(Fx.snapshot(seeds: Fx.seeds.filter { $0.number != 141 } + [Self.finishedIssue]))
            #expect(railDone.load().owner == SampleData.userID && doneStore.owner == SampleData.userID, Comment(rawValue: name))
            // 곧바로 B로 바뀐다
            who.id = b
            if leaveFirst {
                scope.accountLeft()
                base.shell.accountChanged(b)
            } else {
                base.shell.accountChanged(b)
                scope.accountLeft()
            }
            #expect(railDone.load().issues.isEmpty && doneStore.load().isEmpty, Comment(rawValue: "\(name): A의 표시는 B에게 남지 않는다"))
            // B의 표시: 이슈 · Taskforce 세션 · 데스크톱
            base.shell.update(Fx.snapshot(seeds: Fx.seeds))
            base.shell.update(Fx.snapshot(seeds: Fx.seeds.filter { $0.number != 141 } + [Self.finishedIssue]))
            #expect(railDone.load().issues[Fx.issue(141)] != nil && railDone.load().owner == b, Comment(rawValue: "\(name): 이슈 표시를 쓰자마자 B의 도장이 있다 (세션 표시가 대신 찍어 주기 전에)"))
            base.gateway.sessions = .basic
            await base.issues.sessions.refresh()
            base.gateway.sessions = .finished
            await base.issues.sessions.refresh()
            script.sessions = [Self.live(10, .busy)]
            await desktop.pollOnce()
            script.sessions = [Self.live(10, .idle)]
            await desktop.pollOnce()
            #expect(railDone.load().issues[Fx.issue(141)] != nil && railDone.load().sessions[Fx.session(1)] != nil && doneStore.load()[Self.id(10)] != nil, Comment(rawValue: "\(name): B의 표시가 저장됐다"))
            #expect(railDone.load().owner == b && doneStore.owner == b, Comment(rawValue: "\(name): 모두 B의 도장이 찍혀 있다"))
            // 다시 켠다: B로 로그인하면 B의 표시는 남는다
            let relaunched = X().make(signedIn: false, railDone: railDone)
            relaunched.shell.accountChanged(b)
            #expect(railDone.load().issues[Fx.issue(141)] != nil && railDone.load().sessions[Fx.session(1)] != nil, Comment(rawValue: "\(name): 다시 켜도 남는다"))
        }
    }

    @Test func marksOfThisAccountSurviveALaterLaunchOfTheShell() async {
        let railDone = InMemoryRailDoneStore()
        railDone.save(RailDoneMarks(issues: [Fx.issue(141): Date()], owner: SampleData.userID))
        let base = X().make(railDone: railDone)
        #expect(railDone.load().issues[Fx.issue(141)] != nil && railDone.load().owner == SampleData.userID, "같은 계정이면 지우지 않는다")
        withExtendedLifetime(base) {}
    }

    @Test func aStoreWithAnUnknownOwnerIsNotTrustedEither() async {
        let railDone = InMemoryRailDoneStore()
        railDone.save(RailDoneMarks(issues: [Fx.issue(141): Date()]))
        let base = X().make(railDone: railDone)
        #expect(railDone.load() == RailDoneMarks(owner: SampleData.userID))
        withExtendedLifetime(base) {}
    }

    /// 저장해 둔 마지막 표시의 사본을 계정이 바뀔 때 비운다: 남기면 새 계정이 같은 표시를 만들었을 때 "바뀌지 않았다"며 저장하지 않는다
    @Test func theLastSavedCopyIsForgottenWhenTheAccountChangesSoTheNewAccountsSameMarkIsSaved() async {
        let railDone = InMemoryRailDoneStore()
        // 시계는 멈춰 둔다: 같은 일이 "같은 때"에 끝나야 두 표시가 같다 (시계 객체는 시험이 끝날 때까지 붙든다: 셸의 시계는 그 객체를 약하게 본다)
        let time = EdgeShellModelTests.ManualTime()
        defer { withExtendedLifetime(time) {} }
        let base = X().make(railDone: railDone, time: time)
        base.shell.update(Fx.snapshot(seeds: Fx.seeds))
        base.shell.update(Fx.snapshot(seeds: Fx.seeds.filter { $0.number != 141 } + [Self.finishedIssue]))
        #expect(railDone.load().issues[Fx.issue(141)] != nil)
        // 다른 계정으로 바뀌었다 (저장본은 비워진다)
        base.shell.accountChanged(UUID())
        #expect(railDone.load().issues.isEmpty)
        // 새 계정에서 같은 일이 같은 때에 끝났다: 같은 표시도 저장된다
        base.shell.update(Fx.snapshot(seeds: Fx.seeds))
        base.shell.update(Fx.snapshot(seeds: Fx.seeds.filter { $0.number != 141 } + [Self.finishedIssue]))
        #expect(railDone.load().issues[Fx.issue(141)] != nil, "이전 계정의 사본이 남아 있으면 저장을 건너뛴다")
    }

    @Test func theDesktopModelAdoptsTheAccountWhenTheShellLearnsIt() async {
        let r = await rig(rows: [10], live: [Self.live(10, .busy)])
        await r.poll([Self.live(10, .idle)])
        #expect(r.doneStore.load()[Self.id(10)] != nil && r.doneStore.owner == SampleData.userID, "이 계정을 주인으로 적었다")
        // 다른 계정의 표시가 저장돼 있는 채로 이 계정이 알려졌다
        let doneStore = InMemoryClaudeAppDoneStore()
        doneStore.save([Self.id(10): ClaudeAppDoneMark(pid: 9010, at: Date())])
        doneStore.setOwner(UUID())
        let script = DeskScript()
        let desktop = ClaudeAppSessionsModel(poll: { script.poll() }, done: doneStore)
        let base = X().make(signedIn: false, desktop: desktop, railDone: InMemoryRailDoneStore())
        base.shell.accountChanged(SampleData.userID)
        #expect(doneStore.load().isEmpty && doneStore.owner == SampleData.userID, "셸이 계정을 알면 폴을 기다리지 않고 다른 계정의 표시를 비운다")
    }

    // MARK: 레일 버튼 · 키 토글 (계약 24장)

    @Test func pressingARailButtonWhoseWindowIsAlreadyOpenClosesItAndAnotherButtonSwitchesToItsOwn() async {
        let r = await rig(sessions: .basic)
        let shell = r.shell
        shell.pressControl(.sessions)
        #expect(shell.panelOpen && shell.view == .sessions)
        shell.pressControl(.sessions)
        #expect(!shell.panelOpen, "열려 있는 Sessions를 다시 누르면 닫힌다")
        shell.pressControl(.sessions)
        #expect(shell.panelOpen && shell.view == .sessions, "닫힌 뒤에는 다시 열린다")
        shell.pressControl(.allWork)
        #expect(shell.panelOpen && shell.view == .allWork, "다른 칸의 패널이 열려 있으면 닫지 않고 그 칸의 패널로 간다")
        shell.pressControl(.allWork)
        #expect(!shell.panelOpen, "열려 있는 Projects를 다시 누르면 닫힌다")
        // 쌓인 화면(이슈 상세)에서 Projects 칸은 닫지 않고 Projects 첫 화면으로 간다 (그 칸이 가리키는 화면이 아니다)
        shell.openAllWork()
        shell.openIssue(Fx.issue(139))
        #expect(shell.nav.detailID == Fx.issue(139))
        shell.pressControl(.allWork)
        #expect(shell.panelOpen && shell.view == .allWork && shell.nav.detailID == nil)
        shell.pressControl(.allWork)
        #expect(!shell.panelOpen)
        // More는 레일 컨트롤러가 카드로 연다: 이 눌림은 아무 일도 하지 않는다
        shell.pressControl(.more)
        #expect(!shell.panelOpen)
    }

    @Test func theSessionsButtonDoesNothingWithoutAnAccountAndTheToggleNeedsOne() async {
        let base = X().make(signedIn: false)
        base.shell.pressControl(.sessions)
        base.shell.toggleSessions()
        #expect(!base.shell.panelOpen, "Sessions 버튼이 없는 셸은 아무 일도 없다")
    }

    @Test func theOldNotchRailTogglesProjectsToo() {
        let shell = EdgeShellModel(schedule: { _, _ in EdgeTimer() }, chatsEnabled: true, windowsEnabled: true)
        shell.pressControl(.allWork)
        #expect(shell.panelOpen && shell.view == .allWork)
        shell.pressControl(.allWork)
        #expect(!shell.panelOpen)
        var chats = 0
        shell.onChats = { chats += 1 }
        shell.pressControl(.chats)
        #expect(chats == 1 && shell.controls == [.allWork, .chats, .more], "노치 레일의 Chats는 지금 그대로다")
    }

    /// 노치 레일의 Projects(All work) 칸은 목록이 그대로일 때만 닫는다: 고른 행 · 검색어 · 필터가 있으면 옛 동작대로 그것을 비우고 목록을 보인다
    @Test func theOldNotchRailClosesProjectsOnlyWhenNoRowIsSelectedAndNoSearchOrFilterIsActive() {
        let shell = EdgeShellModel(schedule: { _, _ in EdgeTimer() }, chatsEnabled: true, windowsEnabled: true)
        // 고른 행이 있다
        shell.open(itemID: UUID())
        #expect(shell.panelOpen && shell.currentID != nil)
        shell.pressControl(.allWork)
        #expect(shell.panelOpen && shell.view == .allWork && shell.currentID == nil, "고른 행을 비우고 목록을 보인다 (닫지 않는다)")
        shell.pressControl(.allWork)
        #expect(!shell.panelOpen, "목록이 그대로이면 닫는다")
        // 검색어가 있다
        shell.openAllWork()
        shell.setFilter(WorkFilter(query: "deck"))
        shell.pressControl(.allWork)
        #expect(shell.panelOpen && shell.workFilter == WorkFilter(), "검색어를 비우고 목록을 보인다")
        shell.pressControl(.allWork)
        #expect(!shell.panelOpen)
        // 필터가 있다
        shell.openAllWork()
        shell.setFilter(WorkFilter(project: .ungrouped, status: .waiting))
        shell.pressControl(.allWork)
        #expect(shell.panelOpen && shell.workFilter == WorkFilter(), "필터를 비우고 목록을 보인다")
        // 필터 카드가 열려 있다 (필터는 비었다): 목록이 그대로가 아니다 — 카드를 닫고 목록을 보인다
        shell.setFiltersOpen(true)
        shell.pressControl(.allWork)
        #expect(shell.panelOpen && !shell.filtersOpen, "열린 필터 카드를 닫고 목록을 보인다")
        shell.pressControl(.allWork)
        #expect(!shell.panelOpen)
    }

    @Test func thePanelKeysToggleTheirPanelTooAndCommandThreeIsGone() async throws {
        let w = try await windows(live: [])
        defer {
            w.shell.dismiss()
            w.controller.followPanel()
        }
        #expect(w.controller.handleKey(try key(kVK_ANSI_4)) && w.shell.panelOpen && w.shell.view == .sessions)
        #expect(w.controller.handleKey(try key(kVK_ANSI_4)) && !w.shell.panelOpen, "⌘4를 다시 누르면 Sessions가 닫힌다")
        #expect(w.controller.handleKey(try key(kVK_ANSI_2)) && w.shell.panelOpen && w.shell.view == .allWork)
        #expect(w.controller.handleKey(try key(kVK_ANSI_2)) && !w.shell.panelOpen, "⌘2를 다시 누르면 Projects가 닫힌다")
        #expect(!w.controller.handleKey(try key(kVK_ANSI_3)) && !w.shell.panelOpen, "Chats 키(⌘3)는 없다: 지나간다")
    }

    // MARK: Chats 칸 없음 · + 는 새 세션

    @Test func theCapsuleRailHasNoChatsButtonOrKeyAndPlusOpensANewSessionDirectly() async {
        let r = await rig()
        let shell = r.shell
        #expect(!shell.controls.contains(.chats) && !shell.listens(to: .chats) && shell.listens(to: .newChat))
        var chats = 0, news: [AssistantOpenItem?] = [], windows = 0
        shell.onChats = { chats += 1 }
        shell.onNewSession = { news.append($0) }
        shell.onNewWindow = { windows += 1 }
        shell.openChats()
        shell.pressControl(.chats)
        #expect(chats == 0 && !shell.panelOpen, "Chats 칸 · 키가 없어 눌러도 아무 일도 없다")
        shell.newSession(from: .rail)
        #expect(news.count == 1, "`+`는 새 세션(새 대화 창)을 직접 연다")
        shell.newChat()
        #expect(windows == 1, "⌘N도 새 대화 창을 연다")
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

    /// 사용자 결정(2026-10-22): 링으로 연 Claude 세션 패널은 실제 레일 창의 중심선에 가운데로 선다 — 컨트롤러가 레일의 중심선을 이 패널에 이어 주고, 레일이 옮겨지면 따라간다
    @Test func theClaudePanelOpenedFromARingStandsOnTheMidlineOfTheRealRailWindow() async throws {
        let screen = try #require(EdgeRailPanelController.screen, "화면이 있어야 창 자리를 잰다")
        let w = try await windows(live: [Self.live(1, .busy)])
        w.controller.rail.show()
        defer {
            w.shell.dismiss()
            w.controller.followPanel()
            w.controller.rail.hide()
        }
        w.shell.openRailEntry(w.shell.slots.first { $0.source == .claudeApp(sessionID: Self.id(1)) }!)
        #expect(await until { w.claude.isVisible && w.claude.presentation.shown })
        func expectedMinY(_ height: CGFloat, _ center: CGFloat) -> CGFloat {
            EdgePanelMetrics.centeredOriginY(height: height, centerY: center, visible: screen.visibleFrame)
        }
        let home = w.controller.rail.panel.frame
        let center = try #require(w.controller.rail.centerLineY)
        let target = try #require(w.claude.targetFrame())
        #expect(abs(target.minY - expectedMinY(target.height, center)) < 0.001, "레일 창의 중심선에 가운데 (화면 위 120에 붙지 않는다)")
        #expect(await until { abs(w.claude.panel.frame.minY - target.minY) < 1 }, "열린 창도 그 자리에 선다")
        // 레일을 아래로 옮기면: 중심선이 내려가고 패널의 목표 자리도 따라 내려간다
        w.controller.rail.panel.setFrame(home.offsetBy(dx: 0, dy: -120), display: true)
        let lowCenter = try #require(w.controller.rail.centerLineY)
        let low = try #require(w.claude.targetFrame())
        #expect(abs(lowCenter - center + 120) < 1)
        #expect(abs(low.minY - expectedMinY(low.height, lowCenter)) < 0.001 && low.minY < target.minY - 1, "레일을 따라 내려간다")
        // 레일 창이 안 떠 있으면 화면 가운데다
        w.controller.rail.hide()
        let fallback = try #require(w.claude.targetFrame())
        #expect(abs(fallback.minY - expectedMinY(fallback.height, screen.frame.midY)) < 0.001)
    }

    @Test func commandFourOpensSessionsOnlyInAShellThatHasTheSessionsButton() async throws {
        let w = try await windows(live: [])
        defer {
            w.shell.dismiss()
            w.controller.followPanel()
        }
        // ⌘4는 ⌘1–3 · ⌘N처럼 `EdgeKeyCommand`의 하나다 (Assistant 창의 키 해석이 같은 목록을 읽는다)
        #expect(EdgeKeyCommand.of(keyCode: kVK_ANSI_4, flags: .command) == .sessions)
        #expect(EdgeKeyCommand.of(keyCode: kVK_ANSI_4, flags: []) == nil && EdgeKeyCommand.of(keyCode: kVK_ANSI_4, flags: [.command, .shift]) == nil)
        #expect(EdgeKeyCommand.of(keyCode: kVK_ANSI_4, flags: [.command, .option]) == nil && EdgeKeyCommand.of(keyCode: kVK_ANSI_4, flags: [.command, .control]) == nil)
        #expect(w.shell.listens(to: .sessions), "Sessions 버튼이 있는 셸은 듣는다")
        #expect(w.controller.handleKey(try key(kVK_ANSI_4)))
        #expect(w.shell.panelOpen && w.shell.view == .sessions)
        w.shell.dismiss()
        let account = try AppChatAccount.make()
        let plain = EdgeShellController(launcher: LauncherModel(configurationError: "test"), chat: ChatRuntime(gateway: IssueSampleGateway(), contextGateway: IssueSampleContextGateway(), scope: account.scope, now: { Date() }, issueScreens: false), assistantWindows: false)
        #expect(!plain.shell.listens(to: .sessions), "Sessions 버튼이 없는 셸은 듣지 않는다")
        #expect(!plain.handleKey(try key(kVK_ANSI_4)) && !plain.shell.panelOpen, "Sessions 버튼이 없는 셸은 ⌘4가 지나간다")
    }

    /// 로그인 전(계정 없음)에는 Sessions 버튼이 없다: ⌘4는 지나가고 패널이 열리지 않는다
    @Test func commandFourPassesWhileSignedOutBecauseThereIsNoSessionsButton() throws {
        let account = try AppChatAccount.make()
        let runtime = ChatRuntime(gateway: IssueSampleGateway(), contextGateway: IssueSampleContextGateway(), scope: account.scope, now: { Date() }, issueScreens: true)
        let controller = EdgeShellController(launcher: LauncherModel(configurationError: "test"), chat: runtime, assistantWindows: false)
        #expect(!controller.shell.sessionsVisible && !controller.shell.listens(to: .sessions))
        #expect(!controller.handleKey(try key(kVK_ANSI_4)) && !controller.shell.panelOpen)
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
