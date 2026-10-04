import Testing
@testable import Taskforce

/// 설정 사이드바 (U1 PR5a): 저장된 예전 탭 값 → 페이지, 검색칸 거르기, ↑↓ 한 칸
struct MacSettingsTabTests {
    @Test(arguments: [
        // 예전 TabView 값: Account 탭은 이제 시트라 Connections, Shortcut 탭은 Keyboard Shortcuts
        ("account", MacSettingsTab.connections),
        ("shortcut", .keyboardShortcuts),
        ("connections", .connections),
        ("ai", .ai),
        // 지금 값
        ("keyboardShortcuts", .keyboardShortcuts),
        // 아직 숨긴 항목 · 모르는 값 · 빈 값
        ("general", .connections),
        ("unknown", .connections),
        ("", .connections),
    ])
    func storedValueMapsToAVisiblePage(stored: String, page: MacSettingsTab) {
        #expect(MacSettingsTab.page(stored: stored) == page)
    }

    @Test func nothingStoredOpensConnections() {
        #expect(MacSettingsTab.page(stored: nil) == .connections)
    }

    @Test func sidebarShowsTheU1ItemsInFigmaOrder() {
        #expect(MacSettingsTab.sidebar.map(\.title) == ["Keyboard Shortcuts", "Account", "Connections", "Privacy & AI Data"])
        #expect(MacSettingsTab.sidebar.map(\.group) == [.personal, .personal, .work, .work])
        #expect(MacSettingsTab.sidebar.filter(\.tab.opensSheet).map(\.tab) == [.account])
    }

    @Test(arguments: [
        ("", ["Keyboard Shortcuts", "Account", "Connections", "Privacy & AI Data"]),
        ("   ", ["Keyboard Shortcuts", "Account", "Connections", "Privacy & AI Data"]),
        ("conn", ["Connections"]),
        ("CONNECTIONS", ["Connections"]),
        ("shortcut", ["Keyboard Shortcuts"]),
        ("ai", ["Privacy & AI Data"]),
        ("privacy data", ["Privacy & AI Data"]),
        ("acc", ["Account"]),
        ("o", ["Keyboard Shortcuts", "Account", "Connections"]),
        ("launcher", []),
    ])
    func searchFiltersItemNames(query: String, titles: [String]) {
        #expect(MacSettingsTab.sidebar(matching: query).map(\.title) == titles)
    }

    @Test func arrowsMoveOneItemAndStopAtTheEnds() {
        let all = MacSettingsTab.sidebar
        #expect(MacSettingsTab.step(from: .keyboardShortcuts, by: 1, in: all) == .account)
        #expect(MacSettingsTab.step(from: .account, by: 1, in: all) == .connections)
        #expect(MacSettingsTab.step(from: .ai, by: 1, in: all) == .ai)
        #expect(MacSettingsTab.step(from: .keyboardShortcuts, by: -1, in: all) == .keyboardShortcuts)
        #expect(MacSettingsTab.step(from: .connections, by: -1, in: all) == .account)
    }

    @Test func arrowsEnterAFilteredListFromItsEnds() {
        let filtered = MacSettingsTab.sidebar(matching: "o")
        #expect(MacSettingsTab.step(from: .ai, by: 1, in: filtered) == .keyboardShortcuts)
        #expect(MacSettingsTab.step(from: .ai, by: -1, in: filtered) == .connections)
        #expect(MacSettingsTab.step(from: .ai, by: 1, in: []) == nil)
    }

    // MARK: Usage & Credits (U2 Mac PR4): 실행을 쓸 수 있을 때만

    @Test func usageAppearsAboveAccountOnlyWhenExecutionIsAvailable() {
        #expect(MacSettingsTab.sidebar(executionAvailable: true).map(\.title)
            == ["Keyboard Shortcuts", "Usage & Credits", "Account", "Connections", "Privacy & AI Data"])
        #expect(MacSettingsTab.sidebar(executionAvailable: true).first { $0.tab == .usage }?.group == .personal)
        #expect(!MacSettingsTab.sidebar(executionAvailable: false).contains { $0.tab == .usage })
        #expect(MacSettingsTab.sidebar.map(\.tab) == MacSettingsTab.sidebar(executionAvailable: false).map(\.tab))
    }

    /// 저장된 `usage`: 쓸 수 있으면 그 페이지, 쓸 수 없으면(404 · 로그아웃) Connections, 아직 모르면(credits를 읽는 중) 떨어뜨리지 않는다
    @Test(arguments: [
        (MacSettingsTab.Execution.available, MacSettingsTab.usage),
        (.unknown, .usage),
        (.unavailable, .connections),
    ])
    func storedUsagePageFollowsExecution(_ execution: MacSettingsTab.Execution, _ page: MacSettingsTab) {
        #expect(MacSettingsTab.page(stored: "usage", execution: execution) == page)
    }

    /// 다른 페이지는 실행 여부와 상관없이 그대로
    @Test(arguments: [MacSettingsTab.Execution.available, .unknown, .unavailable])
    func otherStoredPagesIgnoreExecution(_ execution: MacSettingsTab.Execution) {
        #expect(MacSettingsTab.page(stored: "ai", execution: execution) == .ai)
        #expect(MacSettingsTab.page(stored: "keyboardShortcuts", execution: execution) == .keyboardShortcuts)
        #expect(MacSettingsTab.page(stored: "account", execution: execution) == .connections)
        #expect(MacSettingsTab.page(stored: nil, execution: execution) == .connections)
    }

    @Test(arguments: [
        ("credits", true, ["Usage & Credits"]),
        ("usage", true, ["Usage & Credits"]),
        ("USAGE credits", true, ["Usage & Credits"]),
        ("credits", false, []),
        ("o", true, ["Keyboard Shortcuts", "Account", "Connections"]),
        ("a", true, ["Keyboard Shortcuts", "Usage & Credits", "Account", "Privacy & AI Data"]),
    ])
    func searchFindsUsageOnlyWhenShown(query: String, executionAvailable: Bool, titles: [String]) {
        #expect(MacSettingsTab.sidebar(matching: query, executionAvailable: executionAvailable).map(\.title) == titles)
    }

    @Test func arrowsStepThroughUsage() {
        let shown = MacSettingsTab.sidebar(executionAvailable: true)
        #expect(MacSettingsTab.step(from: .keyboardShortcuts, by: 1, in: shown) == .usage)
        #expect(MacSettingsTab.step(from: .usage, by: 1, in: shown) == .account)
        #expect(MacSettingsTab.step(from: .account, by: -1, in: shown) == .usage)
        // 항목이 숨은 뒤 그 페이지에서 ↓: 보이는 목록의 처음
        #expect(MacSettingsTab.step(from: .usage, by: 1, in: MacSettingsTab.sidebar) == .keyboardShortcuts)
    }
}
