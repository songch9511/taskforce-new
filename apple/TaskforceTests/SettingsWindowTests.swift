import Foundation
import Testing
import TaskforceKit
import TaskforceUI
@testable import Taskforce

/// 0.2.0 설정 창 (S1): 플래그 경계 · 탭 · 저장값 옮기기 · 창 제목 · 보이는 주제 · 연결 줄 · 패널 키
@MainActor
struct SettingsWindowFlagTests {
    /// 플래그가 꺼져 있으면(테스트 실행 · Release 전부) Settings 장면은 기존 사이드바 창이다
    @Test func flagOffSelectsTheExistingSettingsView() {
        #expect(!EdgeShellFlag.isEnabled())
        #expect(MacSettingsRootKind.current == .legacy)
        #expect(MacSettingsRoot().kind == .legacy)
        #expect(MacSettingsRootKind(edgeShell: false) == .legacy)
    }

    /// 격리된 suite에서 켤 때만 새 탭 창
    @Test func flagOnSelectsTheTabbedWindow() throws {
        let name = "dev.taskforcelabs.tests.settings-window.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(MacSettingsRootKind(edgeShell: EdgeShellFlag.isEnabled(defaults)) == .legacy)
        defaults.set(true, forKey: EdgeShellFlag.key)
        #expect(MacSettingsRootKind(edgeShell: EdgeShellFlag.isEnabled(defaults)) == .window)
        #expect(MacSettingsRoot(kind: .window).kind == .window)
    }
}

struct SettingsWindowTabTests {
    /// 디자인 순서 그대로: Account · Connections · Execution · Reports · Shortcuts, Lucide 아이콘
    @Test func tabsFollowTheDesignOrder() {
        #expect(SettingsWindowTab.allCases.map(\.title) == ["Account", "Connections", "Execution", "Reports", "Shortcuts"])
        #expect(SettingsWindowTab.allCases.map(\.icon.rawValue) == ["circle-user", "plug", "shield-check", "bell", "keyboard"])
    }

    /// 기존 사이드바가 저장한 값도 받는다 (`settings.tab`). 없음 · 모르는 값 · 자리가 없는 페이지는 첫 탭
    @Test(arguments: [
        (nil, SettingsWindowTab.account),
        ("account", .account),
        ("about", .account),
        ("usage", .account),
        ("taskList", .account),
        ("connections", .connections),
        ("ai", .connections),
        ("keyboardShortcuts", .shortcuts),
        ("shortcut", .shortcuts),
        ("execution", .execution),
        ("reports", .reports),
        ("shortcuts", .shortcuts),
        ("general", .account),
        ("unknown", .account),
        ("", .account),
    ] as [(String?, SettingsWindowTab)])
    func storedValueMapsToATab(stored: String?, tab: SettingsWindowTab) {
        #expect(SettingsWindowTab.tab(stored: stored) == tab)
    }

    /// 탭이 적는 값은 다시 같은 탭으로, 기존 창이 읽어도 깨지지 않는다 (아는 값은 같은 페이지, 새 탭은 기존 기본 Connections)
    @Test func storedValuesRoundTripAndStayReadableByTheOldWindow() {
        for tab in SettingsWindowTab.allCases {
            #expect(SettingsWindowTab.tab(stored: tab.storedValue) == tab)
        }
        #expect(MacSettingsTab.page(stored: SettingsWindowTab.account.storedValue) == .account)
        #expect(MacSettingsTab.page(stored: SettingsWindowTab.connections.storedValue) == .connections)
        #expect(MacSettingsTab.page(stored: SettingsWindowTab.shortcuts.storedValue) == .keyboardShortcuts)
        #expect(MacSettingsTab.page(stored: SettingsWindowTab.execution.storedValue) == .connections)
        #expect(MacSettingsTab.page(stored: SettingsWindowTab.reports.storedValue) == .connections)
    }

    /// `SettingsOpener.open(_:)`은 기존 탭 값을 적는다: More › Settings → Account, More › Connections · 재연결 알림 → Connections
    @Test func openerValuesLandOnTheRightTab() {
        #expect(SettingsWindowTab.tab(stored: MacSettingsTab.account.rawValue) == .account)
        #expect(SettingsWindowTab.tab(stored: MacSettingsTab.connections.rawValue) == .connections)
        for tab in MacSettingsTab.allCases {
            // 어떤 기존 값도 이 창의 탭 하나로 간다 (깨지지 않는다)
            #expect(SettingsWindowTab.allCases.contains(SettingsWindowTab.tab(stored: tab.rawValue)))
        }
    }
}

@MainActor
struct SettingsWindowModelTests {
    @Test func titleIsTheTabOrTheOpenDetail() {
        let model = SettingsWindowModel()
        #expect(model.title(on: .connections) == "Connections")
        model.open(.privacy)
        #expect(model.title(on: .connections) == "Privacy & AI Data")
        // 다른 탭에는 이 상세가 보이지 않는다 (상세는 탭을 더하지 않는다)
        #expect(model.title(on: .account) == "Account")
        #expect(model.detail(on: .account) == nil)
        model.open(.connection(.google))
        #expect(model.title(on: .connections) == "Google")
        model.open(.connection(.gmail))
        #expect(model.title(on: .connections) == "Gmail")
        model.close()
        #expect(model.title(on: .connections) == "Connections")
    }

    /// 확인은 한 번에 하나: 상세를 열거나 닫으면(Back · 탭 바꾸기 · 창 밖에서 열기) 닫힌다
    @Test func navigationClosesAnOpenConfirmation() {
        let model = SettingsWindowModel()
        model.confirming = .deleteAccount
        model.open(.connection(.slack))
        #expect(model.confirming == nil)
        model.confirming = .disconnect(.slack)
        model.close()
        #expect(model.confirming == nil)
        #expect(model.detail == nil)
    }
}

struct SettingsProfileFieldTests {
    static let profile = Profile(displayName: "Alex Kim", aliases: ["Alex", "AK"], emails: ["alex@example.com"], aiConsentAt: nil, reportsConsent: false)

    /// 저장할 때와 같은 다듬기로 비교한다: 공백 · 같은 별칭은 바뀐 것이 아니다 (손대지 않은 칸은 새 프로필을 따라간다)
    @Test func untouchedFieldsMatchTheirProfile() {
        #expect(SettingsProfileSection.fieldsMatch(name: "Alex Kim", aliases: "Alex, AK", profile: Self.profile))
        #expect(SettingsProfileSection.fieldsMatch(name: "  Alex Kim ", aliases: "Alex,AK, ", profile: Self.profile))
        #expect(SettingsProfileSection.fieldsMatch(name: "Alex Kim", aliases: "Alex, AK, Alex Kim", profile: Self.profile))
    }

    /// 이름 · 별칭을 바꾸거나 지우면 저장할 것이 있다
    @Test func editedFieldsDiffer() {
        #expect(!SettingsProfileSection.fieldsMatch(name: "Alex", aliases: "Alex, AK", profile: Self.profile))
        #expect(!SettingsProfileSection.fieldsMatch(name: "Alex Kim", aliases: "Alex", profile: Self.profile))
        #expect(!SettingsProfileSection.fieldsMatch(name: "", aliases: "Alex, AK", profile: Self.profile))
    }
}

struct SettingsWindowSectionTests {
    @Test func accountShowsProfileSignInDeleteAboutAndLinks() {
        #expect(SettingsWindowTab.account.sections(.signedIn) == [.profile, .signIn, .deleteAccount, .about, .legal])
        // 로그아웃 · 읽는 중: 로그인 자리 · About · 링크 (프로필 · 삭제는 없다)
        #expect(SettingsWindowTab.account.sections(.signedOut) == [.signIn, .about, .legal])
        #expect(SettingsWindowTab.account.sections(.loading) == [.signIn, .about, .legal])
    }

    @Test func connectionsOpensWithAIProcessingThenSources() {
        #expect(SettingsWindowTab.connections.sections(.signedIn) == [.aiProcessing, .sources, .moreServices])
        #expect(SettingsWindowTab.connections.sections(.signedOut) == [.signInRequired])
        #expect(SettingsWindowTab.execution.sections(.signedIn) == [.runWithAI])
        #expect(SettingsWindowTab.execution.sections(.loading) == [.signInRequired])
    }

    @Test func reportsAndShortcutsDoNotNeedSignIn() {
        for access in [SettingsWindowAccess.signedIn, .signedOut, .loading] {
            #expect(SettingsWindowTab.reports.sections(access) == [.notifications])
            #expect(SettingsWindowTab.shortcuts.sections(access) == [.launcher, .panelKeys])
        }
    }

    /// 연결되지 않은 것은 보이지 않는다 (소유자 규칙): 어느 탭 · 로그인 상태에서도 숨긴 주제의 제목이 없다
    @Test func gatedTopicsStayHidden() {
        let hidden = Set(SettingsWindowHidden.allCases.map(\.rawValue))
        #expect(hidden.isSuperset(of: [
            "Plan & usage", "Usage & Credits", "Subscription", "Remembered", "Your agents", "Default for new work",
            "Spending outside Taskforce", "Delivery", "Task List",
        ]))
        for tab in SettingsWindowTab.allCases {
            for access in [SettingsWindowAccess.signedIn, .signedOut, .loading] {
                let titles = Set(tab.sections(access).compactMap(\.title))
                #expect(titles.isDisjoint(with: hidden), "\(tab) \(access)")
            }
        }
        #expect(SettingsWindowHidden.yourAgents.tab == .connections)
        #expect(SettingsWindowHidden.planAndUsage.tab == .account)
        #expect(SettingsWindowHidden.externalCosts.tab == .execution)
        #expect(SettingsWindowHidden.reportsDelivery.tab == .reports)
        #expect(SettingsWindowHidden.allCases.allSatisfy { !$0.reason.isEmpty })
    }

    /// 제목 없는 주제는 앞 주제에 이어진다 (삭제는 Sign-in 아래, More services는 Sources 아래, 링크는 About 아래)
    @Test func untitledTopicsFollowATitledOne() {
        for tab in SettingsWindowTab.allCases {
            let sections = tab.sections(.signedIn)
            for (index, section) in sections.enumerated() where section.title == nil && section != .signInRequired {
                #expect(index > 0, "\(section)")
            }
        }
    }
}

@MainActor
struct SettingsConnectionLineTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func record(_ provider: ConnectionProvider, name: String? = nil, status: ConnectionStatus = .active, synced: Date? = nil) -> ConnectionRecord {
        ConnectionRecord(id: UUID(), provider: provider.rawValue, displayName: name, status: status, lastSyncedAt: synced, lastError: nil)
    }

    static func line(
        _ provider: ConnectionProvider, _ state: ConnectionState, syncing: Bool = false, comingSoon: Bool = false, connecting: Bool = false
    ) -> SettingsConnectionLine {
        SettingsConnectionLine.make(provider: provider, state: state, syncing: syncing, comingSoon: comingSoon, connecting: connecting, now: now)
    }

    @Test func notConnectedServicesOfferConnect() {
        let notion = Self.line(.notion, .notConnected)
        #expect(notion.name == "Notion")
        #expect(notion.aside == nil)
        #expect(notion.detail == "Not connected")
        #expect(notion.action == .connect)
        #expect(!notion.attention && !notion.opens)
        // Google은 이름 + 범위, Gmail은 Beta 안내
        let google = Self.line(.google, .notConnected)
        #expect(google.name == "Google" && google.aside == "Calendar · Meet")
        #expect(Self.line(.gmail, .notConnected).detail == "Not connected · Beta · Reconnect every 7 days")
        #expect(Self.line(.slack, .notConnected).name == "Slack")
    }

    @Test func connectedServicesShowTheAccountAndLastSync() {
        let synced = Self.now.addingTimeInterval(-600)
        let notion = Self.line(.notion, .connected(Self.record(.notion, name: "Acme", synced: synced)))
        #expect(notion.aside == "Acme")
        #expect(notion.detail == "Synced 10 min ago")
        #expect(notion.action == nil && notion.opens && !notion.attention)
        #expect(Self.line(.notion, .connected(Self.record(.notion))).detail == "Connected")
        // Google 계정은 범위 대신 상태 뒤에
        let google = Self.line(.google, .connected(Self.record(.google, name: "alex@example.com", synced: synced)))
        #expect(google.aside == "Calendar · Meet")
        #expect(google.detail == "Synced 10 min ago · alex@example.com")
        #expect(Self.line(.notion, .connected(Self.record(.notion)), syncing: true).detail == "Syncing…")
    }

    /// 사용자가 할 일이 있는 상태는 굵게, Reconnect는 잉크 버튼 (색은 더하지 않는다)
    @Test func attentionStatesAreWordsAndOneAction() {
        let reconnect = Self.line(.gmail, .needsReconnect(Self.record(.gmail, status: .reauth)))
        #expect(reconnect.detail == "Reconnect to keep syncing · Beta · Reconnect every 7 days")
        #expect(reconnect.attention && reconnect.action == .reconnect && reconnect.opens)
        let failed = Self.line(.slack, .syncFailed(Self.record(.slack, status: .error)))
        #expect(failed.detail == "Last sync failed")
        #expect(failed.attention && failed.action == nil && failed.opens)
        // 실패했어도 다시 동기화 중이면 진행 중이라고 쓴다
        let retrying = Self.line(.slack, .syncFailed(Self.record(.slack, status: .error)), syncing: true)
        #expect(retrying.detail == "Syncing…" && !retrying.attention)
    }

    @Test func connectingAndComingSoon() {
        let waiting = Self.line(.notion, .notConnected, connecting: true)
        #expect(waiting.detail == "Waiting for Notion…" && waiting.busy && waiting.action == .connect)
        let soon = Self.line(.slack, .notConnected, comingSoon: true)
        #expect(soon.detail == "Coming soon" && soon.action == nil)
    }

    /// Disconnect 확인은 무엇이 멈추고 무엇이 남는지 말한다 (Slack은 원문도 지운다)
    @Test func disconnectSaysWhatStays() {
        #expect(SettingsConnectionLine.disconnectDetail(.gmail) == "Taskforce stops reading Gmail. Tasks already found stay.")
        #expect(SettingsConnectionLine.disconnectDetail(.slack) == "Taskforce stops reading Slack. Slack messages are removed from Taskforce. Tasks stay.")
        #expect(SettingsConnectionLine.disconnectDetail(.google) == "Taskforce stops reading Google. Tasks already found stay.")
    }

    @Test func moreServicesNamesWhatComesLater() {
        #expect(SettingsConnectionLine.comingLater == "Coming later: Microsoft 365, Zoom, GitHub, Linear and Jira.")
    }

    /// Sync Now는 연결이 살아 있을 때만 (다시 연결이 필요하면 Reconnect · Disconnect만)
    @Test func syncNeedsALiveConnection() {
        #expect(SettingsConnectionDetail.canSync(.connected(Self.record(.notion))))
        #expect(SettingsConnectionDetail.canSync(.syncFailed(Self.record(.notion, status: .error))))
        #expect(!SettingsConnectionDetail.canSync(.needsReconnect(Self.record(.notion, status: .revoked))))
        #expect(!SettingsConnectionDetail.canSync(.notConnected))
    }
}

@MainActor
struct SettingsWindowReadOnlyValueTests {
    /// Edge 패널에서 지금 동작하는 키만 (⌘2 All work · ⌘3 Chats). ⌘1 · ⌘N · 1–3은 그 화면이 생길 때
    @Test func panelKeysAreOnlyTheOnesThatWork() {
        let rows = SettingsPanelKeys.rows
        #expect(rows.map(\.label) == ["All work", "Chats"])
        #expect(rows.map(\.keys) == [["⌘", "2"], ["⌘", "3"]])
        #expect(SettingsPanelKeys.keyCaps("⌥Space") == ["⌥", "Space"])
        #expect(SettingsPanelKeys.keyCaps("⇧⌘K") == ["⇧", "⌘", "K"])
    }

    /// Run with AI: 모름은 모름으로 (읽는 중 · 읽기 실패를 "Not available"로 쓰지 않는다)
    @Test func runWithAIAvailabilityStatesUncertaintyExactly() {
        let summary = CreditsSummary(available: 0, reserved: 0, rateVersion: "c3-v1")
        #expect(SettingsRunWithAISection.availability(.available(summary, checkedAt: Date()), failed: false) == "Available")
        #expect(SettingsRunWithAISection.availability(.unavailable, failed: false) == "Not available")
        #expect(SettingsRunWithAISection.availability(.unknown, failed: false) == "Checking…")
        #expect(SettingsRunWithAISection.availability(.unknown, failed: true) == "Couldn't check")
    }

    @Test func notificationPermissionIsWords() {
        #expect(SettingsNotificationsSection.permission(nil) == "Checking…")
        #expect(SettingsNotificationsSection.permission(.allowed) == "Allowed")
        #expect(SettingsNotificationsSection.permission(.denied) == "Off")
        #expect(SettingsNotificationsSection.permission(.notDetermined) == "Not asked yet")
    }
}
