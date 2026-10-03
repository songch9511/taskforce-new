import Testing
@testable import Taskforce

/// 설정 사이드바 (U1 PR5a): 저장된 예전 탭 값 → 페이지, 검색칸 거르기, ↑↓ 한 칸
struct MacSettingsTabTests {
    @Test(arguments: [
        // 예전 TabView 값: Account 탭은 이제 시트라 첫 페이지, Shortcut 탭은 Keyboard Shortcuts
        ("account", MacSettingsTab.keyboardShortcuts),
        ("shortcut", .keyboardShortcuts),
        ("connections", .connections),
        ("ai", .ai),
        // 지금 값
        ("keyboardShortcuts", .keyboardShortcuts),
        // 아직 숨긴 항목 · 모르는 값 · 빈 값
        ("general", .keyboardShortcuts),
        ("", .keyboardShortcuts),
    ])
    func storedValueMapsToAVisiblePage(stored: String, page: MacSettingsTab) {
        #expect(MacSettingsTab.page(stored: stored) == page)
    }

    @Test func nothingStoredOpensTheFirstPage() {
        #expect(MacSettingsTab.page(stored: nil) == .keyboardShortcuts)
        #expect(MacSettingsTab.page(stored: nil) == MacSettingsTab.sidebar.first?.tab)
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
}
