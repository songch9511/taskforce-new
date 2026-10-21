import AppKit
import Foundation
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
        private(set) var opened = 0
        var installed = true

        func openClaudeApp() -> Bool {
            opened += 1
            return installed
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

    struct Rig {
        let shell: EdgeShellModel
        let store: ExternalSessionsStore
        let counter: Counter
        let seen: InMemoryExternalSessionSeenStore
        let app: FakeClaudeApp
        let scope: AccountScope
    }

    static func row(_ n: Int, status: ExternalSessionStatus = .available, group: String = "/Users/tester/proj", created: Date = Date()) -> ExternalSessionRow {
        ExternalSessionRow(
            id: Self.uuid(n), ref: String(repeating: "c", count: 64), title: "Session \(n)", folderPath: group, groupPath: group, lastActivity: Date().addingTimeInterval(-3600),
            created: created, client: .terminal, status: status
        )
    }

    func make(gated: Bool = true, store: Bool = true, signedIn: Bool = true) -> Rig {
        let counter = Counter()
        let scope = AccountScope(currentAccount: { SampleData.userID })
        let seen = InMemoryExternalSessionSeenStore(Date(timeIntervalSinceNow: -10_000))
        let external = ExternalSessionsStore(scope: scope, scan: { counter.scan() }, seen: seen, pollInterval: 3600)
        let issues = IssueRuntime(gateway: IssueSampleGateway(), scope: scope)
        let contexts = WorkContextStore(gateway: IssueSampleContextGateway(), scope: scope)
        let shell = EdgeShellModel(
            schedule: { _, _ in EdgeTimer() }, clock: { Date() }, contexts: contexts, chatsEnabled: true, windowsEnabled: true, issues: gated ? issues : nil, externalSessions: store ? external : nil
        )
        let app = FakeClaudeApp()
        shell.claudeApp = app
        if signedIn { shell.accountChanged(SampleData.userID) }
        return Rig(shell: shell, store: external, counter: counter, seen: seen, app: app, scope: scope)
    }

    func until(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // MARK: 게이트 · 레일 칸

    @Test func theRailHasNoOnThisMacUnlessTheStoreExistsTheIssueScreensAreOnAndSomeoneIsSignedIn() {
        let base: [EdgeShellModel.Control] = [.allWork, .chats, .more]
        #expect(make(store: false).shell.controls == base, "목록이 없으면(BridgeFlag 꺼짐) 칸도 없다")
        #expect(make(gated: false).shell.controls == base, "새 Issues 화면이 꺼진 셸은 지금 그대로")
        #expect(make(signedIn: false).shell.controls == base, "로그인하지 않았으면 없다")
        #expect(make().shell.controls == [.allWork, .chats, .onThisMac, .more], "More 앞에 든다")
        #expect(make(gated: false).shell.externalSessions == nil, "게이트가 꺼진 셸은 목록을 아예 들지 않는다")
        #expect(EdgeShellModel.Control.allCases == base, "기본 칸 목록은 그대로다")
    }

    @Test func theControlNamesItsIconAndTooltipWithoutAShortcut() {
        let time = EdgeShellModelTests.ManualTime()
        let scope = AccountScope(currentAccount: { SampleData.userID })
        let external = ExternalSessionsStore(scope: scope, scan: { ExternalSessionScan(rows: []) }, seen: InMemoryExternalSessionSeenStore(), pollInterval: 3600)
        let shell = EdgeShellModel(
            schedule: time.schedule, clock: time.clock, chatsEnabled: true, windowsEnabled: true, issues: IssueRuntime(gateway: IssueSampleGateway(), scope: scope), externalSessions: external
        )
        shell.accountChanged(SampleData.userID)
        #expect(shell.label(for: .onThisMac) == "On this Mac")
        #expect(shell.railIcon(for: .onThisMac) == .laptop && TFIcon.laptop.rawValue == "laptop")
        #expect(EdgeShellModel.Control.onThisMac.shortcut == nil)
        shell.pointer(inside: true)
        time.advance(TFMotion.railHoverDelay + 0.01)
        shell.hover(control: .onThisMac)
        #expect(shell.tooltip?.title == "On this Mac" && shell.tooltip?.detail == "")
        shell.hover(control: .more)
        #expect(shell.tooltip == nil, "More는 지금처럼 툴팁이 없다")
    }

    @Test func theThirdCapsuleGrowsToFourControlsAndHidesWhenTheRailIsCollapsed() {
        let rig = make()
        let expanded = EdgeRailCapsuleLayout(mode: .expanded, bell: false, compactRingCount: 0, ringCount: 0, controls: rig.shell.controls)
        #expect(expanded.thirdCapsuleDrawn?.height == 146)
        #expect(rig.shell.controls.allSatisfy { expanded.controlDrawn($0) != nil })
        let order = rig.shell.controls.compactMap { expanded.controlDrawn($0)?.minY }
        #expect(order == order.sorted(), "위에서부터 Projects · Chats · On this Mac · More")
        let compact = EdgeRailCapsuleLayout(mode: .compact, bell: true, compactRingCount: 2, ringCount: 2, controls: rig.shell.controls)
        #expect(compact.thirdCapsuleDrawn == nil && compact.controlDrawn(.onThisMac) == nil, "접힌 레일에서는 셋째 캡슐째 보이지 않는다")
        let rest = EdgeRailCapsuleLayout(mode: .rest, bell: false, compactRingCount: 0, ringCount: 0, controls: rig.shell.controls)
        #expect(rest.thirdCapsuleDrawn == nil)
        #expect(expanded.controlFrame(.onThisMac).map { expanded.hitsRail(CGPoint(x: $0.midX, y: $0.midY)) } == true)
    }

    @Test func theWindowAlwaysHoldsTheBiggestColumn() {
        let tall = EdgeRailCapsuleLayout(mode: .expanded, bell: true, compactRingCount: 3, ringCount: 4, controls: [.allWork, .chats, .onThisMac, .more])
        let bottom = tall.thirdCapsuleDrawn?.maxY ?? .infinity
        #expect(bottom + EdgeRailCapsuleLayout.room <= EdgeRailCapsuleLayout.windowHeight + 0.001)
        #expect(tall.columnHeight == EdgeRailCapsuleLayout.maxColumnHeight)
    }

    // MARK: 패널 열기 · 훑기

    @Test func openingOnThisMacShowsThePanelAndStartsScanningAndLeavingStopsIt() async {
        let rig = make()
        rig.counter.set([Self.row(1)])
        rig.shell.openOnThisMac()
        #expect(rig.shell.panelOpen && rig.shell.view == .onThisMac && rig.store.isOpen)
        #expect(rig.shell.view.title == "On this Mac")
        #expect(await until { rig.store.phase == .ready })
        #expect(rig.shell.railControlHighlighted(.onThisMac) && !rig.shell.railControlHighlighted(.allWork) && !rig.shell.railControlHighlighted(.chats))
        rig.shell.openAllWork()
        #expect(!rig.store.isOpen, "다른 화면으로 가면 훑기를 멈춘다")
        rig.shell.openOnThisMac()
        #expect(rig.store.isOpen)
        rig.shell.dismiss()
        #expect(!rig.store.isOpen && !rig.shell.panelOpen, "패널을 접어도 멈춘다")
    }

    @Test func aShellWithoutTheStoreIgnoresTheOpen() {
        let rig = make(store: false)
        rig.shell.openOnThisMac()
        #expect(!rig.shell.panelOpen && rig.shell.view == .allWork)
        rig.shell.openPanel(.onThisMac)
        #expect(!rig.shell.panelOpen, "어느 길로도 열리지 않는다")
        let signedOut = make(signedIn: false)
        signedOut.shell.openOnThisMac()
        #expect(!signedOut.shell.panelOpen)
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
        shell.openOnThisMac()
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
        rig.shell.openOnThisMac()
        #expect(!rig.store.hasNew)
        rig.shell.dismiss()
    }

    @Test func theAccountLeavingClosesTheListAndGoesBackToAllWork() async {
        let rig = make()
        rig.shell.openOnThisMac()
        #expect(rig.shell.view == .onThisMac)
        rig.shell.accountChanged(nil)
        #expect(rig.shell.view == .allWork && !rig.store.isOpen)
        #expect(!rig.shell.externalSessionsVisible && rig.shell.controls == [.allWork, .chats, .more])
    }

    @Test func theLastViewReopenedByTheShortcutIsTheListWhenItWasOpenAndItIsNotAnOpenItem() {
        let rig = make()
        rig.shell.openOnThisMac()
        #expect(rig.shell.openItem == nil, "Assistant 칩이 따라갈 항목이 아니다")
        rig.shell.dismiss()
        rig.shell.togglePanel()
        #expect(rig.shell.panelOpen && rig.shell.view == .onThisMac)
    }

    // MARK: Open in Claude (가짜 1회)

    @Test func openInClaudeOpensTheAppOnceWithoutAnyArgumentsOrSession() {
        let rig = make()
        rig.shell.openInClaude()
        #expect(rig.app.opened == 1)
        #expect(LiveClaudeAppOpener.bundleID == "com.anthropic.claudefordesktop")
        rig.app.installed = false
        rig.shell.openInClaude()
        #expect(rig.app.opened == 2, "설치돼 있지 않아도 터지지 않는다")
    }

    // MARK: 묶음 머리의 프로젝트 이름

    @Test func aGroupFolderThatIsATaskforceProjectFolderUsesTheProjectName() async {
        let gateway = IssueSampleContextGateway()
        gateway.seeds = IssueSnapshotData.seeds
        let scope = AccountScope(currentAccount: { SampleData.userID })
        let contexts = WorkContextStore(gateway: gateway, scope: scope)
        await contexts.refresh()
        let shell = EdgeShellModel(schedule: { _, _ in EdgeTimer() }, clock: { Date() }, contexts: contexts, chatsEnabled: true, windowsEnabled: true)
        let name = contexts.contexts[Fx.taskforce]?.name
        #expect(name != nil)
        shell.projectFolders = { [Fx.taskforce: "/Users/tester/taskforce-app"] }
        #expect(shell.externalProjectName(forFolder: "/Users/tester/taskforce-app") == name)
        #expect(shell.externalProjectName(forFolder: "/Users/tester/other") == nil)
        shell.projectFolders = { [:] }
        #expect(shell.externalProjectName(forFolder: "/Users/tester/taskforce-app") == nil)
        shell.projectFolders = { [UUID(): "/Users/tester/taskforce-app"] }
        #expect(shell.externalProjectName(forFolder: "/Users/tester/taskforce-app") == nil, "모르는 프로젝트 id")
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
