import AppKit
import Testing
import TaskforceKit
@testable import Taskforce

/// 설정 사이드바 (U1 PR5a): 저장된 예전 탭 값 → 페이지, 검색칸 거르기, ↑↓ 한 칸
struct MacSettingsTabTests {
    @Test func signedInBetaAccountSeesUsageWithoutExecutionCredits() {
        #expect(MacSettingsTab.sidebar(executionAvailable: false, signedIn: true).contains { $0.tab == .usage })
        #expect(MacSettingsTab.page(stored: "usage", execution: .unavailable, signedIn: true) == .usage)
    }

    @Test(arguments: [
        // Account remains an inline page; the legacy Shortcut value maps to Keyboard Shortcuts.
        ("account", MacSettingsTab.account),
        ("shortcut", .keyboardShortcuts),
        ("connections", .connections),
        ("ai", .ai),
        // 지금 값
        ("keyboardShortcuts", .keyboardShortcuts),
        ("taskList", .taskList),
        ("about", .about),
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
        #expect(MacSettingsTab.sidebar.map(\.title) == ["Keyboard Shortcuts", "Task List", "Account", "About", "Connections", "Privacy & AI Data"])
        #expect(MacSettingsTab.sidebar.map(\.group) == [.personal, .personal, .personal, .personal, .work, .work])
        #expect(MacSettingsTab.page(stored: "account", signedIn: false) == .account)
    }

    @Test func aboutIsSearchablePersistedAndAvailableWhileSignedOut() {
        let signedOutItems = MacSettingsTab.sidebar(executionAvailable: false, signedIn: false)
        #expect(signedOutItems.contains { $0.tab == .about })
        #expect(MacSettingsTab.sidebar(matching: "about", signedIn: false).map(\.tab) == [.about])
        #expect(MacSettingsTab.page(stored: MacSettingsTab.about.rawValue, signedIn: false) == .about)
    }

    @Test(arguments: [
        ("", ["Keyboard Shortcuts", "Task List", "Account", "About", "Connections", "Privacy & AI Data"]),
        ("   ", ["Keyboard Shortcuts", "Task List", "Account", "About", "Connections", "Privacy & AI Data"]),
        ("conn", ["Connections"]),
        ("CONNECTIONS", ["Connections"]),
        ("shortcut", ["Keyboard Shortcuts"]),
        ("task list", ["Task List"]),
        ("task", ["Task List"]),
        ("ai", ["Privacy & AI Data"]),
        ("privacy data", ["Privacy & AI Data"]),
        ("acc", ["Account"]),
        ("o", ["Keyboard Shortcuts", "Account", "About", "Connections"]),
        ("about", ["About"]),
        ("launcher", []),
    ])
    func searchFiltersItemNames(query: String, titles: [String]) {
        #expect(MacSettingsTab.sidebar(matching: query).map(\.title) == titles)
    }

    @Test func arrowsMoveOneItemAndStopAtTheEnds() {
        let all = MacSettingsTab.sidebar
        #expect(MacSettingsTab.step(from: .keyboardShortcuts, by: 1, in: all) == .taskList)
        #expect(MacSettingsTab.step(from: .taskList, by: 1, in: all) == .account)
        #expect(MacSettingsTab.step(from: .account, by: 1, in: all) == .about)
        #expect(MacSettingsTab.step(from: .about, by: 1, in: all) == .connections)
        #expect(MacSettingsTab.step(from: .ai, by: 1, in: all) == .ai)
        #expect(MacSettingsTab.step(from: .keyboardShortcuts, by: -1, in: all) == .keyboardShortcuts)
        #expect(MacSettingsTab.step(from: .connections, by: -1, in: all) == .about)
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
            == ["Keyboard Shortcuts", "Task List", "Usage & Credits", "Account", "About", "Connections", "Privacy & AI Data"])
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
        #expect(MacSettingsTab.page(stored: "taskList", execution: execution) == .taskList)
        #expect(MacSettingsTab.page(stored: "about", execution: execution) == .about)
        #expect(MacSettingsTab.page(stored: "account", execution: execution) == .account)
        #expect(MacSettingsTab.page(stored: nil, execution: execution) == .connections)
    }

    @Test(arguments: [
        ("credits", true, ["Usage & Credits"]),
        ("usage", true, ["Usage & Credits"]),
        ("USAGE credits", true, ["Usage & Credits"]),
        ("credits", false, []),
        ("o", true, ["Keyboard Shortcuts", "Account", "About", "Connections"]),
        ("a", true, ["Keyboard Shortcuts", "Task List", "Usage & Credits", "Account", "About", "Privacy & AI Data"]),
    ])
    func searchFindsUsageOnlyWhenShown(query: String, executionAvailable: Bool, titles: [String]) {
        #expect(MacSettingsTab.sidebar(matching: query, executionAvailable: executionAvailable).map(\.title) == titles)
    }

    @Test func arrowsStepThroughUsage() {
        let shown = MacSettingsTab.sidebar(executionAvailable: true)
        #expect(MacSettingsTab.step(from: .keyboardShortcuts, by: 1, in: shown) == .taskList)
        #expect(MacSettingsTab.step(from: .taskList, by: 1, in: shown) == .usage)
        #expect(MacSettingsTab.step(from: .usage, by: 1, in: shown) == .account)
        #expect(MacSettingsTab.step(from: .account, by: 1, in: shown) == .about)
        #expect(MacSettingsTab.step(from: .about, by: -1, in: shown) == .account)
        // 항목이 숨은 뒤 그 페이지에서 ↓: 보이는 목록의 처음
        #expect(MacSettingsTab.step(from: .usage, by: 1, in: MacSettingsTab.sidebar) == .keyboardShortcuts)
    }
}

@Suite(.serialized)
@MainActor
struct AboutBuildInfoTests {
    @Test func localBuildMetadataHasExplicitFallbacks() {
        let info = AboutBuildInfo(infoDictionary: [
            AboutBuildInfo.releaseChannelKey: "$(TF_RELEASE_CHANNEL)",
            AboutBuildInfo.sourceCommitKey: "",
            AboutBuildInfo.buildTimeUTCKey: "$(TF_BUILD_TIME_UTC)",
        ])

        #expect(info.version == "Not available")
        #expect(info.build == "Not available")
        #expect(info.releaseChannel == "Development")
        #expect(info.sourceCommit == "Not available")
        #expect(info.buildTimeUTC == "Not available")
    }

    @Test func builtDebugBundleUsesDevelopmentFallbackMetadata() {
        let info = AboutBuildInfo.current

        #expect(info.releaseChannel == "Development")
        #expect(info.sourceCommit == "Not available")
        #expect(info.buildTimeUTC == "Not available")
    }

    @Test func releaseBuildInfoFormatsAndCopiesOnlyTheUsefulContext() {
        let info = AboutBuildInfo(infoDictionary: [
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "23",
            AboutBuildInfo.releaseChannelKey: "Beta",
            AboutBuildInfo.sourceCommitKey: "0123456789abcdef0123456789abcdef01234567",
            AboutBuildInfo.buildTimeUTCKey: "2026-10-07T01:23:45Z",
        ])
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("AboutBuildInfoTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        info.copy(to: pasteboard)

        let expected = """
        Taskforce
        Version: 0.1.0
        Build: 23
        Release channel: Beta
        Source commit: 0123456789abcdef0123456789abcdef01234567
        Built (UTC): 2026-10-07T01:23:45Z
        """
        #expect(info.copyText == expected)
        #expect(pasteboard.string(forType: .string) == expected)
    }
}

@MainActor
struct UsageSettingsDisplayTests {
    private func budget(cap: Double, confirmed: Double, reserved: Double) throws -> TaskforceKit.AiSpendSummary {
        let data = try JSONSerialization.data(withJSONObject: [
            "cap_usd": cap, "confirmed_usd": confirmed, "reserved_usd": reserved,
            "pending_count": 1, "remaining_usd": max(0, cap - confirmed - reserved), "status": "available",
        ])
        return try JSONDecoder().decode(TaskforceKit.AiSpendSummary.self, from: data)
    }

    @Test func progressIncludesReservationsAndClampsToTheAllowance() throws {
        #expect(UsageCreditsPane.allowanceFraction(try budget(cap: 10, confirmed: 2, reserved: 3)) == 0.5)
        #expect(UsageCreditsPane.allowanceFraction(try budget(cap: 10, confirmed: 9, reserved: 3)) == 1)
        #expect(UsageCreditsPane.allowanceFraction(try budget(cap: 0, confirmed: 0, reserved: 0)) == 0)
    }

    @Test func resetUsesServerDateAndDoesNotInventBetaOrTrialRenewals() throws {
        func billing(_ status: String, reset: String? = nil) throws -> TaskforceKit.BillingSummary {
            var json: [String: Any] = ["status": status, "can_use_ai": true, "can_checkout": false]
            if let reset { json["allowance_resets_at"] = reset }
            return try JSONDecoder().decode(TaskforceKit.BillingSummary.self, from: JSONSerialization.data(withJSONObject: json))
        }
        #expect(UsageCreditsPane.resetDescription(try billing("active", reset: "2026-11-01T00:00:00Z")) == "Resets 2026-11-01 (UTC)")
        #expect(UsageCreditsPane.resetDescription(try billing("legacy_beta")) == "Cumulative beta allowance · no scheduled reset")
        #expect(UsageCreditsPane.resetDescription(try billing("trialing")) == "Total trial allowance · no recurring reset")
        #expect(UsageCreditsPane.resetDescription(try billing("active")) == "No scheduled reset available")
    }
}
