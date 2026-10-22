import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// 레일 On this Mac의 Mac 쪽 (OA 외부 세션 PR1): 게이트 · 레일 칸 · 패널 열기 · 훑기 시점 · 점 · 프로젝트 이름 · Open in Claude(가짜 1회) · 이 Mac의 값.
/// 이 Mac의 실제 Claude 기록 · 프로세스 · 서버를 읽지 않는다: 스캔 결과는 가짜 클로저, Claude 앱 열기는 가짜, 계정은 견본 계정이다
@MainActor
struct EdgeExternalSessionsTests {
    typealias Fx = IssueSnapshotData
    /// 가짜 Claude 세션 id (소문자 정규 UUID)
    static func uuid(_ n: Int) -> String { String(format: "5e5e5e5e-0000-4000-8000-%012x", n) }

    final class FakeClaudeApp: ClaudeAppOpening {
        struct Open: Equatable {
            var id: String
            var folder: String?
        }

        /// 앱만 앞으로 가져온 횟수
        private(set) var opened = 0
        var installed = true
        /// 세션을 열라고 한 요청 (id · 폴더)
        private(set) var sessions: [Open] = []
        /// `openSession`의 답. `holds`가 켜져 있으면 `release()`까지 기다린다 (열기 중인 상태를 보려고)
        var answer = ClaudeDesktopOpenResult.opened
        var holds = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func release() {
            holds = false
            let pending = waiting
            waiting = []
            for continuation in pending { continuation.resume() }
        }

        /// 기다리는 것 중 가장 먼저 온 하나만 놓는다
        func releaseFirst() {
            guard !waiting.isEmpty else { return }
            waiting.removeFirst().resume()
        }

        func openClaudeApp() -> Bool {
            opened += 1
            return installed
        }

        func openSession(id: String, folder: String?) async -> ClaudeDesktopOpenResult {
            sessions.append(Open(id: id, folder: folder))
            if holds { await withCheckedContinuation { waiting.append($0) } }
            return answer
        }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        private var rows: [ExternalSessionRow] = []
        var scans: Int { lock.withLock { value } }
        func scan() -> ExternalSessionScan {
            lock.withLock {
                value += 1
                return ExternalSessionScan(rows: rows)
            }
        }
        func set(_ new: [ExternalSessionRow]) { lock.withLock { rows = new } }
    }

    /// 훑기를 붙잡는다: `holdNext`면 다음 훑기는 **시작할 때의 목록**을 들고 `release()`까지 기다린다 (그 사이 세상이 바뀌면 그 훑기는 옛 값을 돌려준다)
    final class ScanGate: @unchecked Sendable {
        private let lock = NSLock()
        private var hold = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        var holdNext: Bool {
            get { lock.withLock { hold } }
            set { lock.withLock { hold = newValue } }
        }

        func scan(_ counter: Counter) async -> ExternalSessionScan {
            let held = lock.withLock { () -> Bool in
                defer { hold = false }
                return hold
            }
            let result = counter.scan()
            if held { await withCheckedContinuation { continuation in lock.withLock { waiting.append(continuation) } } }
            return result
        }

        func release() {
            let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                defer { waiting = [] }
                return waiting
            }
            for continuation in pending { continuation.resume() }
        }
    }

    /// 열기 직전의 다시 확인 (`ExternalSessionsStore.recheck`)의 가짜: 기본은 "쥔 곳 없음"
    final class Recheck: @unchecked Sendable {
        private let lock = NSLock()
        private var _answer: ExternalSessionStatus? = .available
        private var _asked: [String] = []
        var answer: ExternalSessionStatus? {
            get { lock.withLock { _answer } }
            set { lock.withLock { _answer = newValue } }
        }
        var asked: [String] { lock.withLock { _asked } }
        func ask(_ id: String) -> ExternalSessionStatus? {
            lock.withLock {
                _asked.append(id)
                return _answer
            }
        }
    }

    struct Rig {
        let shell: EdgeShellModel
        let store: ExternalSessionsStore
        let counter: Counter
        let seen: InMemoryExternalSessionSeenStore
        let app: FakeClaudeApp
        let scope: AccountScope
        let recheck: Recheck
        let gate: ScanGate
        let gateway: IssueSampleGateway
        let issues: IssueRuntime
    }

    static func row(
        _ n: Int, status: ExternalSessionStatus = .available, group: String = "/Users/tester/proj", created: Date = Date(), client: ExternalSessionClient? = .terminal
    ) -> ExternalSessionRow {
        ExternalSessionRow(
            id: Self.uuid(n), ref: String(repeating: "c", count: 64), title: "Session \(n)", folderPath: group, groupPath: group, lastActivity: Date().addingTimeInterval(-3600),
            created: created, client: client, status: status
        )
    }

    /// - sessions: 가짜 서버의 Taskforce 세션 (기본은 없음: On this Mac 시험이 Taskforce 줄에 가려지지 않게)
    /// - desktop · railDone · opened: 데스크톱 세션 모델 · 안 연 끝남 저장소 · 지표 (`EdgeSessionsTests`가 채운다)
    /// - scope: 데스크톱 모델 · 지표와 같은 계정 경계를 쓰려면 넘긴다. time: 손으로 돌리는 시계 (호버 · 끝남 표시를 시간으로 본다)
    func make(
        gated: Bool = true, store: Bool = true, signedIn: Bool = true, sessions: IssueSampleGateway.SessionScenario = .none,
        desktop: ClaudeAppSessionsModel? = nil, railDone: (any RailDoneStore)? = nil, opened: ClaudeAppOpenedMetric? = nil,
        scope givenScope: AccountScope? = nil, time: EdgeShellModelTests.ManualTime? = nil
    ) -> Rig {
        let counter = Counter()
        let gate = ScanGate()
        let recheck = Recheck()
        let scope = givenScope ?? AccountScope(currentAccount: { SampleData.userID })
        let seen = InMemoryExternalSessionSeenStore(Date(timeIntervalSinceNow: -10_000))
        let external = ExternalSessionsStore(scope: scope, scan: { await gate.scan(counter) }, recheck: { recheck.ask($0) }, seen: seen, pollInterval: 3600)
        let gateway = IssueSampleGateway()
        gateway.sessions = sessions
        let issues = IssueRuntime(gateway: gateway, scope: scope)
        let contexts = WorkContextStore(gateway: IssueSampleContextGateway(), scope: scope)
        let schedule: EdgeSchedule
        if let time { schedule = time.schedule } else { schedule = { _, _ in EdgeTimer() } }
        let shell = EdgeShellModel(
            schedule: schedule, clock: time?.clock ?? { Date() }, contexts: contexts, chatsEnabled: true, windowsEnabled: true,
            issues: gated ? issues : nil, externalSessions: store ? external : nil, desktopSessions: desktop, railDone: railDone, claudeAppOpened: opened
        )
        let app = FakeClaudeApp()
        shell.claudeApp = app
        if signedIn { shell.accountChanged(SampleData.userID) }
        return Rig(shell: shell, store: external, counter: counter, seen: seen, app: app, scope: scope, recheck: recheck, gate: gate, gateway: gateway, issues: issues)
    }

    func until(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // MARK: 게이트 · 레일 칸

    @Test func theSessionsButtonNeedsTheIssueScreensAndASignedInAccountAndTheMacListAlsoNeedsTheStore() {
        let base: [EdgeShellModel.Control] = [.allWork, .chats, .more]
        #expect(make().shell.controls == base, "Sessions는 셋째 캡슐의 칸이 아니다: 첫 캡슐(링 · +)의 맨 위 버튼이다")
        #expect(make().shell.sessionsVisible && make(store: false).shell.sessionsVisible, "목록(BridgeFlag)이 없어도 Taskforce 세션은 Sessions에서 본다")
        #expect(!make(gated: false).shell.sessionsVisible, "새 Issues 화면이 꺼진 셸은 지금 그대로: 버튼이 없다")
        #expect(!make(signedIn: false).shell.sessionsVisible, "로그인하지 않았으면 없다")
        #expect(make().shell.externalSessionsVisible && !make(store: false).shell.externalSessionsVisible, "On this Mac 절은 목록이 있을 때만")
        #expect(make(gated: false).shell.externalSessions == nil, "게이트가 꺼진 셸은 목록을 아예 들지 않는다")
        #expect(make().shell.capsuleLayout.sessionsButton && !make(gated: false).shell.capsuleLayout.sessionsButton)
        #expect(EdgeShellModel.Control.defaultControls == base, "기본 칸 목록은 그대로다")
    }

    @Test func allCasesIsTheCompleteListAndTheDefaultColumnIsSeparate() {
        #expect(EdgeShellModel.Control.allCases == [.allWork, .chats, .sessions, .more], "allCases는 빠짐없이: 새 칸이 생겨도 allCases를 믿는 코드가 조용히 틀리지 않는다")
        #expect(EdgeShellModel.Control.defaultControls == [.allWork, .chats, .more], "셋째 캡슐의 칸")
        #expect(EdgeRailLayout(notchCount: 2, restCount: 1, expanded: true, idle: false).controls == EdgeShellModel.Control.defaultControls)
        #expect(EdgeRailCapsuleLayout(mode: .expanded, bell: false, compactRingCount: 0, ringCount: 0).controls == EdgeShellModel.Control.defaultControls)
        #expect(SettingsPanelKeys.rows.map(\.label).prefix(2) == ["All work", "Chats"], "Settings의 단축키 목록: Sessions ⌘4는 아직 나열하지 않는다 (후속)")
    }

    @Test func theSessionsButtonNamesItsIconAndTooltipWithItsShortcut() {
        let time = EdgeShellModelTests.ManualTime()
        let scope = AccountScope(currentAccount: { SampleData.userID })
        let shell = EdgeShellModel(
            schedule: time.schedule, clock: time.clock, chatsEnabled: true, windowsEnabled: true, issues: IssueRuntime(gateway: IssueSampleGateway(), scope: scope)
        )
        shell.accountChanged(SampleData.userID)
        #expect(shell.label(for: .sessions) == "Sessions" && SessionsPanelCopy.title == "Sessions")
        #expect(shell.railIcon(for: .sessions) == .sessions && TFIcon.sessions.rawValue == "layers")
        #expect(EdgeShellModel.Control.sessions.shortcut == "⌘4" && SessionsPanelCopy.shortcut == "⌘4")
        shell.pointer(inside: true)
        time.advance(TFMotion.railHoverDelay + 0.01)
        shell.hover(control: .sessions)
        #expect(shell.tooltip?.title == "Sessions" && shell.tooltip?.detail == "⌘4")
        shell.hover(control: .more)
        #expect(shell.tooltip == nil, "More는 지금처럼 툴팁이 없다")
    }

    @Test func theThirdCapsuleStaysAtThreeControlsAndHidesWhenTheRailIsCollapsed() {
        let rig = make()
        let expanded = EdgeRailCapsuleLayout(mode: .expanded, bell: false, compactRingCount: 0, ringCount: 0, controls: rig.shell.controls, sessionsButton: true)
        #expect(expanded.thirdCapsuleDrawn?.height == 112)
        #expect(rig.shell.controls.allSatisfy { expanded.controlDrawn($0) != nil })
        let order = rig.shell.controls.compactMap { expanded.controlDrawn($0)?.minY }
        #expect(order == order.sorted(), "위에서부터 Projects · Chats · More")
        #expect(expanded.controlDrawn(.sessions) == nil, "Sessions는 셋째 캡슐에 없다")
        let compact = EdgeRailCapsuleLayout(mode: .compact, bell: true, compactRingCount: 2, ringCount: 2, controls: rig.shell.controls, sessionsButton: true)
        #expect(compact.thirdCapsuleDrawn == nil && compact.controlDrawn(.more) == nil && compact.sessionsButtonDrawn == nil, "접힌 레일에서는 셋째 캡슐째 보이지 않고 Sessions · +도 접힌다")
        let rest = EdgeRailCapsuleLayout(mode: .rest, bell: false, compactRingCount: 0, ringCount: 0, controls: rig.shell.controls)
        #expect(rest.thirdCapsuleDrawn == nil)
        #expect(expanded.sessionsButtonFrame.map { expanded.hitsRail(CGPoint(x: $0.midX, y: $0.midY)) } == true)
    }

    @Test func theWindowAlwaysHoldsTheBiggestColumn() {
        let tall = EdgeRailCapsuleLayout(mode: .expanded, bell: true, compactRingCount: 3, ringCount: 4, controls: [.allWork, .chats, .more], sessionsButton: true)
        let bottom = tall.thirdCapsuleDrawn?.maxY ?? .infinity
        #expect(bottom + EdgeRailCapsuleLayout.room <= EdgeRailCapsuleLayout.windowHeight + 0.001)
        #expect(tall.columnHeight == EdgeRailCapsuleLayout.maxColumnHeight)
    }

    // MARK: 패널 열기 · 훑기

    @Test func openingSessionsShowsThePanelAndStartsScanningTheMacAndLeavingStopsIt() async {
        let rig = make()
        rig.counter.set([Self.row(1)])
        rig.shell.openSessions()
        #expect(rig.shell.panelOpen && rig.shell.view == .sessions && rig.store.isOpen)
        #expect(rig.shell.view.title == "Sessions")
        #expect(await until { rig.store.phase == .ready })
        #expect(rig.shell.railControlHighlighted(.sessions) && !rig.shell.railControlHighlighted(.allWork) && !rig.shell.railControlHighlighted(.chats))
        rig.shell.openAllWork()
        #expect(!rig.store.isOpen, "다른 화면으로 가면 훑기를 멈춘다")
        rig.shell.openSessions()
        #expect(rig.store.isOpen)
        rig.shell.dismiss()
        #expect(!rig.store.isOpen && !rig.shell.panelOpen, "패널을 접어도 멈춘다")
    }

    @Test func aShellWithoutTheIssueScreensOrAnAccountIgnoresTheOpenButOneWithoutTheStoreStillOpensSessions() {
        let ungated = make(gated: false)
        ungated.shell.openSessions()
        #expect(!ungated.shell.panelOpen && ungated.shell.view == .allWork)
        ungated.shell.openPanel(.sessions)
        #expect(!ungated.shell.panelOpen, "어느 길로도 열리지 않는다")
        let signedOut = make(signedIn: false)
        signedOut.shell.openSessions()
        #expect(!signedOut.shell.panelOpen)
        let noStore = make(store: false)
        noStore.shell.openSessions()
        #expect(noStore.shell.panelOpen && noStore.shell.view == .sessions, "목록이 없어도 Taskforce 세션은 본다")
    }

    @Test func theRailExpandingScansOnceForTheDotAndTheOpenListDoesNotScanAgain() async {
        let time = EdgeShellModelTests.ManualTime()
        let counter = Counter()
        let scope = AccountScope(currentAccount: { SampleData.userID })
        let external = ExternalSessionsStore(scope: scope, scan: { counter.scan() }, seen: InMemoryExternalSessionSeenStore(Date(timeIntervalSinceNow: -10_000)), pollInterval: 3600)
        let shell = EdgeShellModel(
            schedule: time.schedule, clock: time.clock, chatsEnabled: true, windowsEnabled: true, issues: IssueRuntime(gateway: IssueSampleGateway(), scope: scope), externalSessions: external
        )
        shell.accountChanged(SampleData.userID)
        shell.pointer(inside: true)
        time.advance(TFMotion.railHoverDelay + 0.01)
        #expect(shell.railHovered)
        #expect(await until { counter.scans == 1 }, "레일이 펼쳐질 때 한 번 훑는다")
        shell.openSessions()
        #expect(await until { counter.scans == 2 }, "목록을 열 때 한 번 더")
        shell.pointer(inside: false)
        time.advance(1)
        shell.pointer(inside: true)
        time.advance(TFMotion.railHoverDelay + 0.01)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(counter.scans == 2, "목록이 열려 있는 동안 레일이 다시 펼쳐져도 따로 훑지 않는다")
    }

    @Test func aNewSessionMakesTheDotAndOpeningTheListClearsIt() async {
        let rig = make()
        rig.counter.set([Self.row(1, created: Date(timeIntervalSinceNow: -50_000))])
        await rig.store.refresh()
        #expect(!rig.store.hasNew)
        rig.counter.set([Self.row(1, created: Date(timeIntervalSinceNow: -50_000)), Self.row(2, created: Date(timeIntervalSinceNow: -60))])
        await rig.store.refresh()
        #expect(rig.store.hasNew)
        rig.shell.openSessions()
        #expect(!rig.store.hasNew)
        rig.shell.dismiss()
    }

    @Test func theAccountLeavingClosesTheListAndGoesBackToAllWork() async {
        let rig = make()
        rig.shell.openSessions()
        #expect(rig.shell.view == .sessions)
        rig.shell.accountChanged(nil)
        #expect(rig.shell.view == .allWork && !rig.store.isOpen)
        #expect(!rig.shell.externalSessionsVisible && !rig.shell.sessionsVisible && rig.shell.controls == [.allWork, .chats, .more])
    }

    @Test func theLastViewReopenedByTheShortcutIsSessionsWhenItWasOpenAndItIsNotAnOpenItem() {
        let rig = make()
        rig.shell.openSessions()
        #expect(rig.shell.openItem == nil, "Assistant 칩이 따라갈 항목이 아니다")
        rig.shell.dismiss()
        rig.shell.togglePanel()
        #expect(rig.shell.panelOpen && rig.shell.view == .sessions)
    }

    // MARK: Open in Claude (F4: 그 세션을 데스크톱 앱에서 연다, 가짜 실행기)

    private func desktopRow(_ n: Int = 1, status: ExternalSessionStatus = .available) -> ExternalSessionRow {
        Self.row(n, status: status, group: "/Users/tester/proj\(n)", client: .claudeDesktop)
    }

    @Test func openInClaudeOpensThatSessionWithItsIDAndFolderAndLeavesTheAppToTheCLI() async {
        let rig = make()
        let row = desktopRow(3)
        await rig.shell.openInClaude(row).value
        #expect(rig.app.sessions == [.init(id: Self.uuid(3), folder: "/Users/tester/proj3")], "그 줄의 세션 id와 검증된 폴더")
        #expect(rig.app.opened == 0, "열었으면 앱 앞으로 가져오기는 CLI가 한다")
        #expect(rig.shell.openNoticeSessionID == nil)
        #expect(LiveClaudeAppOpener.bundleID == "com.anthropic.claudefordesktop")
    }

    @Test func aRowWithoutAFolderStillAsksAndTheOpenerFallsBack() async {
        let rig = make()
        var row = desktopRow(4)
        row.folderPath = nil
        await rig.shell.openInClaude(row).value
        #expect(rig.app.sessions == [.init(id: Self.uuid(4), folder: nil)], "폴더가 없으면 nil을 넘긴다 (열기는 폴더 없이 하지 않는다)")
    }

    /// 실측 (2026-10-22): 이미 데스크톱 앱이 쥔 세션에 `--desktop --resume`을 하면 CLI가 "open in another terminal"로 거절하고 1로 끝난다
    @Test func aRunningInClaudeRowOnlyActivatesTheAppAndNeverRunsTheCLIAndKeepsItsButton() async {
        let rig = make()
        for client in [ExternalSessionClient.claudeDesktop, .terminal] {
            let row = Self.row(5, status: .held(.claudeApp), group: "/Users/tester/proj5", client: client)
            #expect(ExternalSessionLineText.make(row, now: Date()).action == .openInClaude, "버튼은 그대로 있다")
            let before = rig.app.opened
            await rig.shell.openInClaude(row).value
            #expect(rig.app.opened == before + 1, "앱만 앞으로: 출처가 \(String(describing: client))인 줄도")
        }
        #expect(rig.app.sessions.isEmpty, "Claude 앱이 쥔 세션에는 CLI를 돌리지 않는다")
        #expect(rig.shell.openNoticeSessionID == nil, "거절 줄도 없다")
        rig.app.installed = false
        await rig.shell.openInClaude(Self.row(5, status: .held(.claudeApp), client: .claudeDesktop)).value
        #expect(rig.app.sessions.isEmpty, "설치돼 있지 않아도 터지지 않는다")
    }

    @Test func aRunningRowIsNotHeldUpByAnotherSessionStillOpening() async {
        let rig = make()
        rig.app.holds = true
        let idle = rig.shell.openInClaude(desktopRow(1))
        #expect(await until { rig.app.sessions.count == 1 })
        let running = rig.shell.openInClaude(Self.row(2, status: .held(.claudeApp), client: .claudeDesktop))
        #expect(await until { rig.app.opened == 1 }, "다른 줄을 여는 중이어도 Running in Claude 줄은 곧바로 앱을 앞으로")
        rig.app.release()
        await idle.value
        await running.value
        #expect(rig.app.sessions.map(\.id) == [Self.uuid(1)])
    }

    // MARK: Open in Claude: 모델의 가드 · 즉시 피드백 · 열기 직전 확인 · 열고 난 뒤 (보안 검토 P2-1 · P3, 사용자 보고 "느리다 · 어떤 줄은 안 열린다")

    /// CLI는 쉬는 데스크톱 줄에만 닿는다. 그 밖은 줄을 그리는 쪽이 어떻게 하든 모델이 앱만 앞으로 가져온다
    @Test func onlyAnIdleDesktopRowReachesTheCLIEverythingElseJustActivatesTheApp() async {
        let rig = make()
        let others: [(String, ExternalSessionRow)] = [
            ("Idle · 터미널 출처", Self.row(1, status: .available, client: .terminal)),
            ("Idle · 그 밖 출처", Self.row(2, status: .available, client: .other)),
            ("Idle · 출처 모름", Self.row(3, status: .available, client: nil)),
            ("터미널이 쥠", Self.row(4, status: .held(.terminal), client: .claudeDesktop)),
            ("백그라운드가 쥠", Self.row(5, status: .held(.background), client: .claudeDesktop)),
            ("모르는 곳이 쥠", Self.row(6, status: .held(.unknown), client: .claudeDesktop)),
            ("확인 못 함", Self.row(7, status: .couldNotCheck, client: .claudeDesktop)),
            ("이어받을 수 없음", Self.row(8, status: .cannotResume(.worktree), client: .claudeDesktop)),
            ("Taskforce에 이어받음", Self.row(9, status: .inTaskforce, client: .claudeDesktop)),
            ("Claude 앱이 쥠", Self.row(10, status: .held(.claudeApp), client: .claudeDesktop)),
            ("Claude 앱이 쥠 · 터미널 출처", Self.row(11, status: .held(.claudeApp), client: .terminal)),
        ]
        for (index, (name, row)) in others.enumerated() {
            await rig.shell.openInClaude(row).value
            #expect(rig.app.opened == index + 1, Comment(rawValue: "앱만 앞으로: \(name)"))
        }
        #expect(rig.app.sessions.isEmpty, "CLI는 한 번도 닿지 않았다")
        #expect(rig.recheck.asked.isEmpty && rig.counter.scans == 0, "다시 확인 · 다시 훑기도 없다")
        await rig.shell.openInClaude(desktopRow(20)).value
        #expect(rig.app.sessions.map(\.id) == [Self.uuid(20)], "쉬는 데스크톱 줄만 CLI에 닿는다")
    }

    /// 사용자 보고 "느리다": 누르는 순간 버튼이 "Opening…"(비활성)이 되고 줄의 둘째 줄은 그대로다, 결과가 오면 풀린다
    @Test func aClickShowsOpeningAtOnceAndItEndsWithTheResult() async {
        let rig = make()
        rig.app.holds = true
        let row = desktopRow(1)
        let now = Date()
        #expect(!rig.shell.externalLine(row, now: now).isBusy)
        let plain = rig.shell.externalLine(row, now: now)
        #expect(plain.actionTitle == "Open in Claude")
        let task = rig.shell.openInClaude(row)
        // 아직 한 번도 양보하지 않았다: 누른 호출 안에서 바뀌어 있다
        let busy = rig.shell.externalLine(row, now: now)
        #expect(busy.isBusy && busy.actionTitle == ExternalSessionCopy.opening && busy.action == .openInClaude, "누르는 즉시 버튼이 Opening…")
        #expect(busy.metaText == plain.metaText && busy.statusIsEmphasis == plain.statusIsEmphasis, "둘째 줄은 그대로")
        #expect(rig.shell.externalLine(desktopRow(2), now: now) == ExternalSessionLineText.make(desktopRow(2), now: now), "다른 줄은 그대로")
        #expect(await until { rig.app.sessions.count == 1 })
        #expect(rig.shell.externalLine(row, now: now).isBusy, "결과가 올 때까지 계속")
        rig.app.release()
        await task.value
        #expect(!rig.shell.externalLine(row, now: now).isBusy, "결과가 오면 풀린다")
        #expect(rig.shell.openingSessionIDs.isEmpty)
    }

    @Test func busyEndsOnEveryOutcomeIncludingTheRefusalRescan() async {
        let rig = make()
        let row = desktopRow(1)
        for answer in [ClaudeDesktopOpenResult.opened, .unavailable, .openInAnotherTerminal] {
            rig.app.answer = answer
            await rig.shell.openInClaude(row).value
            #expect(!rig.shell.externalLine(row, now: Date()).isBusy, Comment(rawValue: "\(answer)"))
        }
        rig.recheck.answer = .held(.terminal)
        await rig.shell.openInClaude(row).value
        #expect(!rig.shell.externalLine(row, now: Date()).isBusy, "다시 확인에서 막혀도")
        rig.recheck.answer = nil
        await rig.shell.openInClaude(row).value
        #expect(!rig.shell.externalLine(row, now: Date()).isBusy, "다시 확인을 못 해도")
    }

    /// 열기 직전에 그 세션의 쥠을 다시 본다: 쥔 곳이 있으면(또는 모르면) CLI를 띄우지 않는다
    @Test func theHoldIsCheckedAgainRightBeforeSpawningAndNothingIsSpawnedUnlessItIsFree() async {
        let rig = make()
        let row = desktopRow(1)
        await rig.shell.openInClaude(row).value
        #expect(rig.recheck.asked == [row.id] && rig.app.sessions.map(\.id) == [row.id], "비어 있으면 띄운다")

        // 터미널이 훑은 뒤에 쥐었다: 띄우지 않고, 그 줄에 승인된 "Running in Terminal"을 보이고, 다시 훑는다
        #expect(await until { rig.counter.scans == 1 }, "열린 뒤의 다시 훑기(뒤에서)를 기다린다")
        let before = rig.app.sessions.count
        let scansBefore = rig.counter.scans
        rig.recheck.answer = .held(.terminal)
        await rig.shell.openInClaude(row).value
        #expect(rig.app.sessions.count == before && rig.app.opened == 0, "쥔 세션은 띄우지 않고 앱도 건드리지 않는다")
        #expect(rig.counter.scans == scansBefore + 1, "목록을 다시 훑는다")
        #expect(rig.shell.externalLine(row, now: Date()).metaText == "Running in Terminal")

        // 데스크톱이 쥐었다: 앱만 앞으로 (거절 줄 없음)
        let rig2 = make()
        rig2.recheck.answer = .held(.claudeApp)
        await rig2.shell.openInClaude(row).value
        #expect(rig2.app.sessions.isEmpty && rig2.app.opened == 1 && rig2.shell.openNoticeSessionID == nil)

        // 다른 쥠 · 확인 못 함 · 이미 이어받음: 띄우지 않고 다시 훑을 뿐 거절 줄은 없다 (줄이 제 상태로 바뀐다)
        for answer in [ExternalSessionStatus.held(.background), .held(.unknown), .couldNotCheck, .inTaskforce, .cannotResume(.unreadable)] {
            let r = make()
            r.recheck.answer = answer
            await r.shell.openInClaude(row).value
            #expect(r.app.sessions.isEmpty && r.app.opened == 0 && r.shell.openNoticeSessionID == nil && r.counter.scans == 1, Comment(rawValue: "\(answer)"))
        }

        // 확인할 길이 없다(nil): 막는다 — 옛 동작(앱만 앞으로)으로 물러난다
        let rig3 = make()
        rig3.recheck.answer = nil
        await rig3.shell.openInClaude(row).value
        #expect(rig3.app.sessions.isEmpty && rig3.app.opened == 1 && rig3.shell.openNoticeSessionID == nil, "모르면 띄우지 않는다")
    }

    /// 거절(P2-1): 다시 훑고 **고친 줄**로 정한다. 데스크톱이 쥐었으면 앱만 앞으로, 아니면 "Running in Terminal"
    @Test func afterARefusalTheRefreshedRowDecidesAppOnlyIfClaudeNowHoldsItOtherwiseRunningInTerminal() async {
        for (after, expectApp) in [
            (ExternalSessionStatus.held(.claudeApp), true), (.held(.terminal), false), (.available, false), (.held(.unknown), false), (.couldNotCheck, false),
        ] {
            let rig = make()
            let row = desktopRow(1)
            rig.counter.set([Self.row(1, status: after, group: "/Users/tester/proj1", client: .claudeDesktop)])
            rig.app.answer = .openInAnotherTerminal
            await rig.shell.openInClaude(row).value
            #expect(rig.app.opened == (expectApp ? 1 : 0), Comment(rawValue: "다시 훑은 줄이 \(after): 앱 \(expectApp)"))
            #expect((rig.shell.openNoticeSessionID == row.id) == !expectApp, Comment(rawValue: "다시 훑은 줄이 \(after): 거절 줄"))
            if !expectApp { #expect(rig.shell.externalLine(row, now: Date()).metaText == "Running in Terminal", "승인된 말 한 줄") }
        }
    }

    /// 거절 뒤 훑기는 **클릭 뒤에 시작한** 훑기여야 한다 (P2-1): 클릭 전에 시작해 아직 도는 훑기는 옛 줄을 들고 있다
    @Test func theRescanAfterARefusalWaitsForAScanThatStartsAfterTheClick() async {
        let rig = make()
        let row = desktopRow(1)
        rig.counter.set([row])
        await rig.store.refresh()
        #expect(rig.counter.scans == 1)
        // 클릭 전에 시작한 훑기(옛 줄 · Idle)가 붙잡혀 있다
        rig.gate.holdNext = true
        let early = Task { await rig.store.refresh() }
        #expect(await until { rig.counter.scans == 2 })
        // 그 사이 데스크톱이 그 세션을 열었다
        rig.counter.set([Self.row(1, status: .held(.claudeApp), group: "/Users/tester/proj1", client: .claudeDesktop)])
        rig.app.answer = .openInAnotherTerminal
        let click = rig.shell.openInClaude(row)
        try? await Task.sleep(for: .milliseconds(60))
        #expect(rig.counter.scans == 2 && rig.app.opened == 0 && rig.shell.openNoticeSessionID == nil, "먼저 시작한 훑기가 끝나기 전에는 결정하지 않는다")
        #expect(rig.shell.externalLine(row, now: Date()).isBusy, "그동안은 Opening…")
        rig.gate.release()
        await early.value
        await click.value
        #expect(rig.counter.scans == 3, "클릭 뒤에 시작한 훑기가 하나 더 돌았다")
        #expect(rig.app.opened == 1 && rig.shell.openNoticeSessionID == nil, "그 훑기가 본 줄(데스크톱이 쥠)로 정한다: 앱만 앞으로, 거절 줄 없음")
    }

    /// 열린 뒤에도 다시 훑는다 (P2-1): 줄이 곧 실제 상태(Running in Claude)로 바뀐다.
    /// 그 훑기가 끝날 때까지 줄은 계속 바쁘다 (보안 재검토 P3): 빠른 두 번째 클릭이 `claude`를 또 띄우지 않는다
    @Test func afterTheSessionOpenedTheRowStaysBusyUntilThePostOpenRescanFinishesSoASecondClickIsIgnored() async {
        let rig = make()
        let row = desktopRow(1)
        rig.counter.set([Self.row(1, status: .held(.claudeApp), group: "/Users/tester/proj1", client: .claudeDesktop)])
        rig.gate.holdNext = true
        let scansBefore = rig.counter.scans
        let first = rig.shell.openInClaude(row)
        #expect(await until { rig.counter.scans == scansBefore + 1 }, "열린 뒤 다시 훑는다 (붙잡혀 있다)")
        #expect(rig.app.sessions.count == 1)
        #expect(rig.shell.externalLine(row, now: Date()).isBusy && rig.shell.openingSessionIDs == [row.id], "열었다는 답이 왔어도 훑기가 끝나기 전에는 계속 바쁘다")
        let second = rig.shell.openInClaude(row)
        try? await Task.sleep(for: .milliseconds(40))
        #expect(rig.app.sessions.count == 1 && rig.recheck.asked.count == 1, "빠른 두 번째 클릭은 아무것도 띄우지 않는다")
        rig.gate.release()
        await first.value
        await second.value
        #expect(!rig.shell.externalLine(row, now: Date()).isBusy && rig.shell.openingSessionIDs.isEmpty, "훑기가 끝나면 풀린다")
        #expect(rig.store.rows.first?.status == .held(.claudeApp))
        #expect(rig.shell.openNoticeSessionID == nil && rig.app.opened == 0)
        await rig.shell.openInClaude(row).value
        #expect(rig.app.sessions.count == 2, "풀린 뒤에는 다시 누를 수 있다")
    }

    /// 훑기가 멈춰도 줄이 영영 바쁘지 않다 (보안 재검토 P3): 한도(`busyWaitCapSeconds`)에서 바쁨을 풀고 훑기가 끝나면 줄이 스스로 바뀐다.
    /// 시간은 가짜 시계로 흘린다
    struct Timed {
        let shell: EdgeShellModel
        let store: ExternalSessionsStore
        let app: FakeClaudeApp
        let counter: Counter
        let gate: ScanGate
        let time: EdgeShellModelTests.ManualTime
    }

    func makeTimed() -> Timed {
        let time = EdgeShellModelTests.ManualTime()
        let counter = Counter()
        let gate = ScanGate()
        let scope = AccountScope(currentAccount: { SampleData.userID })
        let external = ExternalSessionsStore(
            scope: scope, scan: { await gate.scan(counter) }, recheck: { _ in .available }, seen: InMemoryExternalSessionSeenStore(), pollInterval: 3600
        )
        let shell = EdgeShellModel(
            schedule: time.schedule, clock: time.clock, chatsEnabled: true, windowsEnabled: true, issues: IssueRuntime(gateway: IssueSampleGateway(), scope: scope), externalSessions: external
        )
        let app = FakeClaudeApp()
        shell.claudeApp = app
        return Timed(shell: shell, store: external, app: app, counter: counter, gate: gate, time: time)
    }

    @Test func aStuckRescanNeverKeepsTheRowBusyPastTheCapAfterARefusal() async {
        let t = makeTimed()
        let row = desktopRow(1)
        t.counter.set([row])
        t.app.answer = .openInAnotherTerminal
        t.gate.holdNext = true
        let task = t.shell.openInClaude(row)
        #expect(await until { t.counter.scans == 1 }, "거절 뒤 훑기가 붙잡혀 있다")
        #expect(t.shell.externalLine(row, now: Date()).isBusy)
        t.time.advance(EdgeShellModel.busyWaitCapSeconds - 0.5)
        try? await Task.sleep(for: .milliseconds(40))
        #expect(t.shell.externalLine(row, now: Date()).isBusy, "한도 전에는 기다린다")
        t.time.advance(1)
        let released = await until { !t.shell.externalLine(row, now: Date()).isBusy }
        #expect(released, "한도에 바쁨이 풀린다")
        #expect(t.shell.openNoticeSessionID == row.id && t.app.opened == 0, "터미널이 쥐었다는 것은 이미 안다: 거절 줄은 보인다 (훑기 결과는 기다리지 않는다)")
        #expect(t.counter.scans == 1, "훑기는 아직 도는 중이다")
        t.gate.release()
        await task.value
        #expect(await until { t.store.rows.first?.id == row.id }, "훑기가 끝나면 목록은 스스로 바뀐다")
    }

    @Test func aStuckRescanNeverKeepsTheRowBusyPastTheCapAfterTheSessionOpened() async {
        let t = makeTimed()
        let row = desktopRow(1)
        t.counter.set([row])
        t.app.answer = .opened
        t.gate.holdNext = true
        let task = t.shell.openInClaude(row)
        #expect(await until { t.counter.scans == 1 }, "열린 뒤 훑기가 붙잡혀 있다")
        #expect(t.shell.externalLine(row, now: Date()).isBusy)
        t.time.advance(EdgeShellModel.busyWaitCapSeconds + 0.1)
        let released = await until { !t.shell.externalLine(row, now: Date()).isBusy }
        #expect(released, "한도에 바쁨이 풀린다")
        #expect(t.shell.openNoticeSessionID == nil && t.app.opened == 0)
        t.gate.release()
        await task.value
    }

    @Test func aRescanThatFinishesInTimeReleasesTheRowAtOnceAndLeavesNoCapTimerToFire() async {
        let t = makeTimed()
        let row = desktopRow(1)
        t.counter.set([row])
        t.app.answer = .opened
        await t.shell.openInClaude(row).value
        #expect(!t.shell.externalLine(row, now: Date()).isBusy, "훑기가 끝나면 한도를 기다리지 않고 푼다")
        // 한도가 지나도 아무 일도 없다 (취소된 타이머)
        t.time.advance(EdgeShellModel.busyWaitCapSeconds + 1)
        #expect(!t.shell.externalLine(row, now: Date()).isBusy && t.app.opened == 0)
    }

    @Test func anUnavailableAnswerFallsBackToActivatingTheAppOnceWithoutAnyNotice() async {
        let rig = make()
        rig.app.answer = .unavailable
        await rig.shell.openInClaude(desktopRow()).value
        #expect(rig.app.opened == 1, "CLI가 없거나 거절하면 앱만 앞으로")
        #expect(rig.shell.openNoticeSessionID == nil)
        rig.app.installed = false
        await rig.shell.openInClaude(desktopRow()).value
        #expect(rig.app.opened == 2, "설치돼 있지 않아도 터지지 않는다")
    }

    @Test func theAnotherTerminalRefusalShowsOneGrayLineOnThatRowOnlyAndDoesNotActivateTheApp() async {
        let rig = make()
        rig.app.answer = .openInAnotherTerminal
        let asked = desktopRow(1), other = desktopRow(2)
        let scansBefore = rig.counter.scans
        await rig.shell.openInClaude(asked).value
        #expect(rig.app.opened == 0, "다른 터미널이 쥔 세션이라 앱은 보여 줄 것이 없다")
        #expect(rig.counter.scans == scansBefore + 1, "스캔과 클릭 사이에 쥐어졌다: 목록을 다시 훑는다")
        let now = Date()
        let line = rig.shell.externalLine(asked, now: now)
        #expect(line.metaText == "Running in Terminal" && !line.statusIsEmphasis && line.action == .openInClaude, "이미 승인된 말을 회색 한 줄로, 버튼은 그대로")
        #expect(rig.shell.externalLine(other, now: now) == ExternalSessionLineText.make(other, now: now), "다른 줄은 그대로")
        #expect(rig.shell.externalLine(asked, now: now) != ExternalSessionLineText.make(asked, now: now))
    }

    @Test func theRefusalLineGoesAwayAfterItsTimeAndWhenTheSessionIsAskedAgain() async {
        let time = EdgeShellModelTests.ManualTime()
        let scope = AccountScope(currentAccount: { SampleData.userID })
        let external = ExternalSessionsStore(scope: scope, scan: { ExternalSessionScan(rows: []) }, recheck: { _ in .available }, seen: InMemoryExternalSessionSeenStore(), pollInterval: 3600)
        let shell = EdgeShellModel(
            schedule: time.schedule, clock: time.clock, chatsEnabled: true, windowsEnabled: true, issues: IssueRuntime(gateway: IssueSampleGateway(), scope: scope), externalSessions: external
        )
        let app = FakeClaudeApp()
        shell.claudeApp = app
        app.answer = .openInAnotherTerminal
        let row = desktopRow(1)
        await shell.openInClaude(row).value
        #expect(shell.openNoticeSessionID == row.id)
        time.advance(EdgeShellModel.openNoticeSeconds - 0.5)
        #expect(shell.openNoticeSessionID == row.id, "아직 보인다")
        time.advance(1)
        #expect(shell.openNoticeSessionID == nil, "\(EdgeShellModel.openNoticeSeconds)초 뒤 사라진다")
        #expect(EdgeShellModel.openNoticeSeconds >= 3 && EdgeShellModel.openNoticeSeconds <= 15)

        // 다시 누르면 먼저 지우고, 이번에 열렸으면 그대로 없다
        await shell.openInClaude(row).value
        #expect(shell.openNoticeSessionID == row.id)
        app.answer = .opened
        await shell.openInClaude(row).value
        #expect(shell.openNoticeSessionID == nil, "다시 눌러 열렸으면 거절 줄은 없다")
        // 오래된 타이머가 새 줄을 지우지 않는다
        app.answer = .openInAnotherTerminal
        await shell.openInClaude(row).value
        time.advance(EdgeShellModel.openNoticeSeconds - 1)
        await shell.openInClaude(row).value
        time.advance(2)
        #expect(shell.openNoticeSessionID == row.id, "두 번째 거절의 시간은 두 번째부터 센다")
    }

    @Test func anEarlierRefusalsTimerNeverClearsALaterRefusalOnAnotherRow() async {
        let time = EdgeShellModelTests.ManualTime()
        let scope = AccountScope(currentAccount: { SampleData.userID })
        let external = ExternalSessionsStore(scope: scope, scan: { ExternalSessionScan(rows: []) }, recheck: { _ in .available }, seen: InMemoryExternalSessionSeenStore(), pollInterval: 3600)
        let shell = EdgeShellModel(
            schedule: time.schedule, clock: time.clock, chatsEnabled: true, windowsEnabled: true, issues: IssueRuntime(gateway: IssueSampleGateway(), scope: scope), externalSessions: external
        )
        let app = FakeClaudeApp()
        shell.claudeApp = app
        app.answer = .openInAnotherTerminal
        app.holds = true
        let (first, second) = (desktopRow(1), desktopRow(2))
        let firstTask = shell.openInClaude(first)
        let secondTask = shell.openInClaude(second)
        #expect(await until { app.sessions.count == 2 })
        app.releaseFirst()
        await firstTask.value
        #expect(shell.openNoticeSessionID == first.id)
        time.advance(5)
        app.releaseFirst()
        await secondTask.value
        #expect(shell.openNoticeSessionID == second.id, "한 줄만 보인다: 나중 거절이 앞 줄의 거절을 대신한다")
        time.advance(EdgeShellModel.openNoticeSeconds - 1)
        #expect(shell.openNoticeSessionID == second.id, "앞 거절의 타이머가 나중 거절을 지우지 않는다")
        time.advance(2)
        #expect(shell.openNoticeSessionID == nil)
    }

    @Test func aSecondClickOnTheSameSessionWhileItIsStillOpeningIsIgnored() async {
        let rig = make()
        rig.app.holds = true
        let row = desktopRow(1)
        let first = rig.shell.openInClaude(row)
        let second = rig.shell.openInClaude(row)
        let otherSession = rig.shell.openInClaude(desktopRow(2))
        #expect(await until { rig.app.sessions.count == 2 }, "다른 세션은 따로 열린다")
        rig.app.release()
        await first.value
        await second.value
        await otherSession.value
        #expect(rig.app.sessions.map(\.id).sorted() == [Self.uuid(1), Self.uuid(2)], "같은 세션은 한 번만")
        await rig.shell.openInClaude(row).value
        #expect(rig.app.sessions.count == 3, "끝난 뒤에는 다시 누를 수 있다")
    }

    @Test func theLiveOpenerHandsTheSessionAndFolderToTheCLIOpenerAndNeverActivatesTheAppItself() async {
        final class Seen: @unchecked Sendable {
            private let lock = NSLock()
            private var value: [[String]] = []
            var calls: [[String]] { lock.withLock { value } }
            func add(_ arguments: [String], _ cwd: String) { lock.withLock { value.append(arguments + [cwd]) } }
        }
        let seen = Seen()
        let home = NSTemporaryDirectory() + "tf-open-\(UUID().uuidString.lowercased())"
        let folder = home + "/proj"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let real = GateFileSystem.realpath(folder) ?? folder
        let live = LiveClaudeAppOpener(makeOpener: {
            ClaudeDesktopSessionOpener(
                locator: ClaudeCodeLocator(candidates: ["/usr/bin/true"]), folderRules: WorkspaceFolderRules(home: GateFileSystem.realpath(home) ?? home, systemRoots: []),
                desktopInstalled: { true },
                run: { _, arguments, _, cwd, timeout in
                    seen.add(arguments, cwd)
                    return timeout == 15 ? .openInAnotherTerminal : .unavailable
                }
            )
        })
        #expect(await live.openSession(id: Self.uuid(9), folder: folder) == .openInAnotherTerminal)
        #expect(seen.calls == [["--desktop", "--resume", Self.uuid(9), real]])
        #expect(await live.openSession(id: "nope", folder: folder) == .unavailable, "나쁜 id는 띄우지 않는다")
        #expect(seen.calls.count == 1)
    }

    // MARK: 클릭이 눌린다 (비활성 패널)

    /// 줄 하나를 실제 패널과 같은 스타일(`EdgeKeyPanel`: borderless · nonactivating)의 380pt 폭에 올린다 (바깥 여백 8)
    /// - disabled: 줄 그림 밖에서 건 `.disabled` (그림이 스스로 비활성이 되는 것과 견주려고)
    private func panelWithRow(
        _ content: ExternalSessionLineContent, onAction: @escaping () -> Void, key: Bool, disabled: Bool = false
    ) -> (panel: EdgeKeyPanel, hosting: NSHostingView<AnyView>) {
        // Open in Claude는 포인터를 올리거나 포커스가 있을 때만 보인다 (DZ 승인 2026-10-22): 합성 클릭은 포인터를 올리지 않으니 호버한 것으로 그린다 (Debug 시험 자리)
        ExternalSessionLineSnapshot.hoveredTitles.insert(content.title)
        let hosting = NSHostingView(rootView: AnyView(
            ExternalSessionLineView(content: content, onAction: { _ in onAction() }).disabled(disabled).frame(width: 380).padding(8).background(TFColor.bgPanel)
        ))
        hosting.frame = NSRect(x: 0, y: 0, width: 396, height: 80)
        let panel = EdgeKeyPanel(contentRect: hosting.frame, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.contentView = hosting
        if key { panel.makeKeyAndOrderFront(nil) } else { panel.orderFront(nil) }
        hosting.layoutSubtreeIfNeeded()
        return (panel, hosting)
    }

    private func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    /// 실제 마우스 이벤트(눌림 · 뗌)를 창에 보낸다. 점은 호스팅 뷰 좌표(왼쪽 위가 원점)
    private func click(_ panel: NSWindow, _ hosting: NSView, at point: CGPoint) {
        let location = hosting.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ) { panel.sendEvent(event) }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }

    /// 사용자가 "버튼이 아무 일도 안 한다"고 알렸다 (2026-10-21): 비활성 패널에서 첫 클릭이 먹히지 않거나 버튼 영역 일부가 눌리지 않는 문제가 아니다.
    /// 버튼 캡슐 안은 어디를 눌러도 한 번 눌리고(글자 밖 여백 포함), 줄의 다른 곳은 눌리지 않으며, 창이 키가 아니어도 첫 클릭이 먹힌다
    @Test func theOpenInClaudeButtonTakesAFirstClickAnywhereInItsCapsuleAndNothingElseInTheRow() {
        let content = ExternalSessionLineText.make(desktopRow(), now: Date())
        #expect(content.action == .openInClaude)
        // 호스팅 뷰 좌표: 380pt 줄 + 바깥 여백 8 → 버튼 캡슐은 x ≈ 265–376, y ≈ 19–43 (실측 스윕)
        let inside: [CGPoint] = [CGPoint(x: 320, y: 31), CGPoint(x: 272, y: 31), CGPoint(x: 368, y: 31), CGPoint(x: 320, y: 24), CGPoint(x: 320, y: 38)]
        let outside: [CGPoint] = [CGPoint(x: 60, y: 31), CGPoint(x: 150, y: 28), CGPoint(x: 320, y: 8), CGPoint(x: 320, y: 62), CGPoint(x: 390, y: 31)]
        for key in [true, false] {
            for point in inside {
                var fired = 0
                let (panel, hosting) = panelWithRow(content, onAction: { fired += 1 }, key: key)
                defer { panel.orderOut(nil) }
                click(panel, hosting, at: point)
                #expect(fired == 1, Comment(rawValue: "캡슐 안 \(point) key=\(key): 한 번 눌린다 (\(fired))"))
            }
            for point in outside {
                var fired = 0
                let (panel, hosting) = panelWithRow(content, onAction: { fired += 1 }, key: key)
                defer { panel.orderOut(nil) }
                click(panel, hosting, at: point)
                #expect(fired == 0, Comment(rawValue: "줄의 다른 곳 \(point) key=\(key): 눌리지 않는다 (\(fired))"))
            }
        }
    }

    /// 줄 그림 자체가 `isBusy`를 따른다 (부르는 쪽이 따로 `.disabled`를 걸지 않아도): 여는 동안 버튼은 눌리지 않고 글자("Opening…")와 흐림으로 그림이 달라진다
    @Test func theLineViewDisablesItsOwnButtonWhileBusyWithoutHelpFromTheCaller() throws {
        let row = desktopRow()
        let idle = ExternalSessionLineText.make(row, now: Date())
        let busy = ExternalSessionLineText.make(row, now: Date(), busy: true)
        #expect(busy.isBusy && !idle.isBusy)
        func picture(_ hosting: NSHostingView<AnyView>) throws -> Data {
            let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            return try #require(rep.representation(using: .png, properties: [:]))
        }
        var idleFired = 0, busyFired = 0
        let (idlePanel, idleHosting) = panelWithRow(idle, onAction: { idleFired += 1 }, key: true)
        let (busyPanel, busyHosting) = panelWithRow(busy, onAction: { busyFired += 1 }, key: true)
        defer {
            idlePanel.orderOut(nil)
            busyPanel.orderOut(nil)
        }
        spin(0.2)
        let idlePicture = try picture(idleHosting)
        let busyPicture = try picture(busyHosting)
        click(idlePanel, idleHosting, at: CGPoint(x: 320, y: 31))
        click(busyPanel, busyHosting, at: CGPoint(x: 320, y: 31))
        #expect(idleFired == 1, "쉬는 줄의 버튼은 눌린다")
        #expect(busyFired == 0, "여는 동안의 버튼은 눌리지 않는다")
        #expect(Self.regionDiffers(idlePicture, busyPicture, x: 262...376, y: 19...43, width: 396), "버튼 글자 · 흐림이 달라 보인다")
        // 글자가 정말 바뀌었다: 같은 비활성 모양의 "Open in Claude" 버튼(밖에서 `.disabled`)과도 그림이 다르다 — 흐림만이 아니라 글자(와 너비)가 다르다
        let (dimmedPanel, dimmedHosting) = panelWithRow(idle, onAction: {}, key: true, disabled: true)
        defer { dimmedPanel.orderOut(nil) }
        spin(0.2)
        let dimmedPicture = try picture(dimmedHosting)
        #expect(Self.regionDiffers(dimmedPicture, busyPicture, x: 262...376, y: 19...43, width: 396), "버튼 글자가 Opening…이다")
    }

    /// 실제 패널(`EdgePanelView`: 머리 · 스크롤 · TimelineView · 줄)에 올린 Open in Claude 버튼을 실제 마우스 이벤트로 눌러 본다.
    /// 줄 하나를 따로 올린 위 시험과 달리 스크롤 · 겹친 뷰가 클릭을 가로채지 않는지 본다: 두 줄(쉬는 데스크톱 줄 · Running in Claude 줄)의 버튼 캡슐을 훑어 둘 다 눌리고(앞은 그 세션을 열고 뒤는 앱만 앞으로), 눌린 세로 범위가 버튼 높이만큼이고 가로 끝도 눌린다.
    /// 패널이 키가 아닐 때(`orderFront`만)도 같다: 비활성 패널의 첫 클릭이 먹히지 않는 문제가 아니다
    @Test func inTheRealPanelBothButtonsAreClickableAndEachDoesItsOwnThing() async {
        for key in [true, false] {
            let rig = make()
            rig.counter.set([
                Self.row(1, status: .available, group: "/Users/tester/proj1", client: .claudeDesktop),
                Self.row(2, status: .held(.claudeApp), group: "/Users/tester/proj2", client: .claudeDesktop),
            ])
            await rig.store.refresh()
            ExternalSessionLineSnapshot.hoveredTitles.formUnion(["Session 1", "Session 2"])
            rig.shell.openSessions()
            let presentation = EdgePanelPresentation()
            presentation.shown = true
            let hosting = NSHostingView(rootView: EdgePanelView(shell: rig.shell, presentation: presentation, chat: nil))
            hosting.frame = NSRect(x: 0, y: 0, width: 380, height: 520)
            let panel = EdgeKeyPanel(contentRect: hosting.frame, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.contentView = hosting
            if key { panel.makeKeyAndOrderFront(nil) } else { panel.orderFront(nil) }
            defer { panel.orderOut(nil) }
            hosting.layoutSubtreeIfNeeded()
            spin(0.4)
            var hits: [(x: Int, y: Int, id: String)] = []
            for x in [262, 306, 356] {
                for y in stride(from: 70, to: 260, by: 5) {
                    let (sessionsBefore, openedBefore) = (rig.app.sessions.count, rig.app.opened)
                    click(panel, hosting, at: CGPoint(x: x, y: y))
                    // 줄의 클릭은 Task로 가서 한 번 양보해야 닿는다
                    try? await Task.sleep(for: .milliseconds(15))
                    if rig.app.sessions.count > sessionsBefore, let last = rig.app.sessions.last {
                        hits.append((x, y, last.id))
                    } else if rig.app.opened > openedBefore {
                        hits.append((x, y, "app"))
                    }
                }
            }
            // 쉬는 줄은 그 세션을 열고, 이미 Claude 앱이 쥔 줄은 앱만 앞으로 가져온다
            #expect(Set(hits.map(\.id)) == [Self.uuid(1), "app"], Comment(rawValue: "key=\(key): 두 줄의 버튼이 각자 눌린다"))
            #expect(!rig.app.sessions.contains { $0.id == Self.uuid(2) }, "쥔 세션에는 CLI를 돌리지 않는다")
            for id in [Self.uuid(1), "app"] {
                let ys = hits.filter { $0.id == id }.map(\.y)
                #expect((ys.max() ?? 0) - (ys.min() ?? 0) >= 12, Comment(rawValue: "key=\(key) \(id): 버튼 높이만큼 눌린다 (\(ys.min() ?? -1)–\(ys.max() ?? -1))"))
                #expect(Set(hits.filter { $0.id == id }.map(\.x)) == [262, 306, 356], Comment(rawValue: "key=\(key) \(id): 캡슐의 왼쪽 · 가운데 · 오른쪽 모두"))
            }
            #expect(rig.app.opened == hits.filter { $0.id == "app" }.count, "앱을 앞으로 가져온 것은 쥔 줄의 클릭뿐")
        }
    }

    /// 거절 줄이 실제 패널에 그려지는지: 모델의 값이 바뀌면 TimelineView 안의 줄이 다시 그려져야 한다 (그림 바이트로 본다).
    /// 열렸을 때(`.opened`)는 아무것도 바뀌지 않고, 거절당했을 때만 그림이 달라진다
    @Test func theRefusalLineIsDrawnInTheRealPanelOnlyWhenTheCLIRefuses() async throws {
        let rig = make()
        rig.counter.set([Self.row(1, status: .available, group: "/Users/tester/proj1", client: .claudeDesktop)])
        await rig.store.refresh()
        ExternalSessionLineSnapshot.hoveredTitles.insert("Session 1")
        rig.shell.openSessions()
        let presentation = EdgePanelPresentation()
        presentation.shown = true
        let hosting = NSHostingView(rootView: EdgePanelView(shell: rig.shell, presentation: presentation, chat: nil))
        hosting.frame = NSRect(x: 0, y: 0, width: 380, height: 300)
        let panel = EdgeKeyPanel(contentRect: hosting.frame, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.contentView = hosting
        panel.makeKeyAndOrderFront(nil)
        defer { panel.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        spin(0.4)
        func picture() throws -> Data {
            let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            return try #require(rep.representation(using: .png, properties: [:]))
        }
        let before = try picture()
        // 버튼 자리를 찾는다 (열렸다고 답하는 가짜로 한 번 눌리는 곳)
        rig.app.answer = .opened
        var buttonY: Int?
        for y in stride(from: 70, to: 200, by: 4) {
            click(panel, hosting, at: CGPoint(x: 306, y: y))
            try? await Task.sleep(for: .milliseconds(15))
            if !rig.app.sessions.isEmpty {
                buttonY = y
                break
            }
        }
        let y = try #require(buttonY, "버튼을 찾았다")
        spin(0.3)
        #expect(try picture() == before, "열렸을 때는 줄이 그대로다")
        rig.app.answer = .openInAnotherTerminal
        click(panel, hosting, at: CGPoint(x: 306, y: y))
        try? await Task.sleep(for: .milliseconds(30))
        spin(0.3)
        #expect(rig.shell.openNoticeSessionID == Self.uuid(1))
        #expect(try picture() != before, "거절당하면 둘째 줄이 회색 한 줄로 다시 그려진다")
    }

    /// 두 그림(PNG)의 같은 점 영역(pt)에서 색이 눈에 띄게 다른 점이 있나
    static func regionDiffers(_ a: Data, _ b: Data, x: ClosedRange<Int>, y: ClosedRange<Int>, width: CGFloat = 380) -> Bool {
        guard let first = NSBitmapImageRep(data: a), let second = NSBitmapImageRep(data: b), first.pixelsWide == second.pixelsWide, first.pixelsHigh == second.pixelsHigh else { return true }
        let scale = CGFloat(first.pixelsWide) / width
        var differing = 0
        for py in stride(from: Int(CGFloat(y.lowerBound) * scale), to: min(first.pixelsHigh, Int(CGFloat(y.upperBound) * scale)), by: 1) {
            for px in stride(from: Int(CGFloat(x.lowerBound) * scale), to: min(first.pixelsWide, Int(CGFloat(x.upperBound) * scale)), by: 1) {
                guard let c1 = first.colorAt(x: px, y: py)?.usingColorSpace(.sRGB), let c2 = second.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { continue }
                if abs(c1.redComponent - c2.redComponent) + abs(c1.greenComponent - c2.greenComponent) + abs(c1.blueComponent - c2.blueComponent) > 0.06 { differing += 1 }
            }
        }
        return differing > 20
    }

    /// 누른 바로 그 순간의 피드백이 실제 패널에 그려지는지 (그림 바이트): 여는 동안 줄이 달라지고 버튼은 눌리지 않으며, 결과가 오면 처음 모습으로 돌아온다
    @Test func theOpeningLineIsDrawnInTheRealPanelWhileTheOpenIsPendingAndTheButtonDoesNotTakeASecondClick() async throws {
        let rig = make()
        rig.counter.set([Self.row(1, status: .available, group: "/Users/tester/proj1", client: .claudeDesktop)])
        await rig.store.refresh()
        ExternalSessionLineSnapshot.hoveredTitles.insert("Session 1")
        rig.shell.openSessions()
        let presentation = EdgePanelPresentation()
        presentation.shown = true
        let hosting = NSHostingView(rootView: EdgePanelView(shell: rig.shell, presentation: presentation, chat: nil))
        hosting.frame = NSRect(x: 0, y: 0, width: 380, height: 300)
        let panel = EdgeKeyPanel(contentRect: hosting.frame, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.contentView = hosting
        panel.makeKeyAndOrderFront(nil)
        defer { panel.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        spin(0.4)
        func picture() throws -> Data {
            let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            return try #require(rep.representation(using: .png, properties: [:]))
        }
        let before = try picture()
        // 버튼 자리를 찾는다 (열렸다고 답하는 가짜로 한 번 눌리는 곳)
        var buttonY: Int?
        for y in stride(from: 70, to: 200, by: 4) {
            click(panel, hosting, at: CGPoint(x: 306, y: y))
            try? await Task.sleep(for: .milliseconds(15))
            if !rig.app.sessions.isEmpty {
                buttonY = y
                break
            }
        }
        let y = try #require(buttonY, "버튼을 찾았다")
        #expect(await until { rig.counter.scans >= 2 }, "열린 뒤의 다시 훑기")
        try? await Task.sleep(for: .milliseconds(50))
        spin(0.3)
        #expect(try picture() == before, "열렸다는 답이 온 뒤에는 줄이 그대로다")
        // 이번에는 결과를 붙잡는다
        rig.app.holds = true
        let sessionsBefore = rig.app.sessions.count
        click(panel, hosting, at: CGPoint(x: 306, y: y))
        #expect(await until { rig.app.sessions.count == sessionsBefore + 1 })
        spin(0.3)
        #expect(rig.shell.openingSessionIDs == [Self.uuid(1)])
        let pending = try picture()
        #expect(pending != before, "여는 동안 줄이 달라 보인다 (Opening… · 비활성 버튼)")
        // 버튼 캡슐 자리(x 262–356pt, 클릭한 y 둘레)의 그림이 달라진다: 비활성 버튼은 흐려진다 (글자가 안 바뀌어도 눈에 보인다)
        #expect(Self.regionDiffers(before, pending, x: 262...356, y: (y - 10)...(y + 10)), "비활성이라 버튼이 흐려 보인다")
        click(panel, hosting, at: CGPoint(x: 306, y: y))
        try? await Task.sleep(for: .milliseconds(40))
        #expect(rig.app.sessions.count == sessionsBefore + 1, "여는 동안 같은 줄의 두 번째 클릭은 아무 일도 하지 않는다")
        rig.app.release()
        #expect(await until { rig.shell.openingSessionIDs.isEmpty })
        try? await Task.sleep(for: .milliseconds(50))
        spin(0.3)
        #expect(try picture() == before, "결과가 오면 처음 모습으로 돌아온다")
    }

    @Test func aLiveOpenerWithoutAnOpenerFailsClosedAndTheStandardOneNeedsABridgeHost() async {
        let live = LiveClaudeAppOpener(makeOpener: { nil })
        #expect(await live.openSession(id: Self.uuid(9), folder: NSHomeDirectory()) == .unavailable, "보호 폴더 목록을 모르면(opener가 없으면) 열지 않는다")
        if BridgeHost.shared == nil {
            #expect(LiveClaudeAppOpener.standardOpener() == nil, "이 계정의 bridge가 없으면 폴더 규칙을 세울 수 없다: 열지 않는다")
        }
    }

    @Test func recheckWithoutABridgeHostOrAScanIsUnknown() async {
        let environment = ExternalSessionsEnvironment(host: { nil })
        #expect(await environment.recheck(Self.uuid(1)) == nil)
    }

    // MARK: 이 Mac의 값

    @Test func theRuntimeIsOnlyMadeWhenEveryGateIsOn() {
        let scope = AccountScope(currentAccount: { SampleData.userID })
        #expect(ExternalSessionsRuntime.make(services: nil, scope: scope, issueScreens: true, bridgeEnabled: true) == nil, "서비스(로그인 연결)가 없다")
        #expect(ExternalSessionsRuntime.make(services: nil, scope: nil, issueScreens: true, bridgeEnabled: true) == nil)
        #expect(ExternalSessionsRuntime.make(services: Self.services, scope: scope, issueScreens: false, bridgeEnabled: true) == nil, "새 Issues 화면이 꺼짐")
        #expect(ExternalSessionsRuntime.make(services: Self.services, scope: scope, issueScreens: true, bridgeEnabled: false) == nil, "BridgeFlag가 꺼짐")
        #expect(ExternalSessionsRuntime.make(services: Self.services, scope: nil, issueScreens: true, bridgeEnabled: true) == nil, "계정 경계가 없다")
        #expect(ExternalSessionsRuntime.make(services: Self.services, scope: scope, issueScreens: true, bridgeEnabled: true, host: { nil }, seen: InMemoryExternalSessionSeenStore()) != nil)
    }

    static var services: AppServices {
        let config = AppConfig(supabaseURL: URL(string: "https://project.invalid")!, supabaseKey: "sb_publishable_test", appGroupID: "group.invalid", apiBaseURL: URL(string: "https://api.invalid")!)
        return AppServices(config: config, supabase: TaskforceClient.makeSupabase(config: config))
    }

    @Test func withoutABridgeHostTheScanReportsItCouldNotReadAndNothingIsInstalledKnown() async {
        let environment = ExternalSessionsEnvironment(host: { nil }, home: "/nonexistent")
        #expect(await environment.isInstalled() == nil)
        let scan = await environment.scan()
        #expect(scan.rows.isEmpty && scan.failure == .unreadable)
    }

    // MARK: 계정 · 로그아웃

    @Test func theRuntimeRegistersTheSignOutClearOnlyWhenItGetsASessionStore() {
        let scope = AccountScope(currentAccount: { SampleData.userID })
        let withSession = SessionStore(auth: Self.services.supabase.auth)
        #expect(withSession.signingOutHandlerCount == 0)
        #expect(ExternalSessionsRuntime.make(services: Self.services, scope: scope, issueScreens: true, bridgeEnabled: true, host: { nil }, session: withSession, seen: InMemoryExternalSessionSeenStore()) != nil)
        #expect(withSession.signingOutHandlerCount == 1, "로그아웃을 누르면 세션을 지우기 전에 서버 목록을 비운다")
        let without = SessionStore(auth: Self.services.supabase.auth)
        #expect(ExternalSessionsRuntime.make(services: Self.services, scope: scope, issueScreens: true, bridgeEnabled: true, host: { nil }, seen: InMemoryExternalSessionSeenStore()) != nil)
        #expect(without.signingOutHandlerCount == 0)
        #expect(ExternalSessionsRuntime.make(services: Self.services, scope: scope, issueScreens: false, bridgeEnabled: true, session: without) == nil)
        #expect(without.signingOutHandlerCount == 0, "목록이 없는 구성은 아무것도 등록하지 않는다")
    }

    final class Sends: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [UUID] = []
        func add(_ id: UUID) { lock.withLock { items.append(id) } }
        var all: [UUID] { lock.withLock { items } }
    }

    @Test func aReportWhoseOriginIsNotTheCurrentOneIsDropped() async {
        let environment = ExternalSessionsEnvironment(host: { nil }, home: "/nonexistent")
        let sends = Sends()
        let reporter = ExternalSessionReporter(send: { bridge, _ in sends.add(bridge) })
        let scanned = ExternalSessionOrigin(partition: "account-a", bridgeID: UUID())
        await environment.report([Self.row(1)], origin: scanned, via: reporter)
        #expect(sends.all.isEmpty, "지금은 계정 · bridge가 없다(로그아웃 · 다른 계정): 스캔할 때의 것으로 보내지 않는다")
        await environment.report([Self.row(1)], origin: nil, via: reporter)
        #expect(sends.all.isEmpty, "bridge가 없던 스캔은 알리지 않는다")
    }

    @Test func signingOutWithoutAnyBridgeOrKeyDoesNothingAndDoesNotHang() async {
        let environment = ExternalSessionsEnvironment(host: { nil }, home: "/nonexistent")
        let sends = Sends()
        await environment.signingOut(via: ExternalSessionReporter(send: { bridge, _ in sends.add(bridge) }))
        #expect(sends.all.isEmpty)
    }

    @Test func theTaskforceSessionIDsComeFromTheSessionFolderStates() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tf-ext-app-\(UUID().uuidString.lowercased())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("claude-code", isDirectory: true)
        for (name, id) in [("s1", Self.uuid(1)), ("s2", Self.uuid(2).uppercased()), ("s3", nil)] as [(String, String?)] {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var state = ClaudeSessionState()
            state.providerSessionID = id
            try state.save(in: folder)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("lineage", isDirectory: true), withIntermediateDirectories: true)
        try "x".write(to: root.appendingPathComponent("stray.txt"), atomically: false, encoding: .utf8)
        #expect(ExternalSessionsEnvironment.taskforceSessionIDs(sessionsRoot: root) == [Self.uuid(1), Self.uuid(2)])
        #expect(ExternalSessionsEnvironment.taskforceSessionIDs(sessionsRoot: base.appendingPathComponent("missing")).isEmpty)
    }
}
