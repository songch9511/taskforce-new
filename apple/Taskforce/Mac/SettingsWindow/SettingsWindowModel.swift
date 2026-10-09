#if os(macOS)
import Foundation
import Observation
import TaskforceKit
import TaskforceUI

// 0.2.0 설정 창 (S1, 디자인 SSOT `SettingsWindow` · `SettingsPage`)의 순수 규칙: 탭 · 저장값 옮기기 · 창 제목 · 보이는 주제 · 연결 줄.
// `TF_EDGE_SHELL`이 켜진 격리 Debug 실행에서만 보인다. 꺼져 있으면(기본 · Release 전부) 기존 `MacSettingsView` 그대로다.

/// Settings 장면의 뿌리가 무엇을 보일지: 플래그가 꺼져 있으면 기존 사이드바 창, 켜져 있으면 0.2.0 탭 창
enum MacSettingsRootKind: Equatable {
    case legacy, window

    init(edgeShell: Bool) {
        self = edgeShell ? .window : .legacy
    }

    /// 앱 실행의 값 (launch argument `-TF_EDGE_SHELL YES`, Debug만)
    static var current: MacSettingsRootKind { MacSettingsRootKind(edgeShell: EdgeShellFlag.isEnabled()) }
}

/// 설정 창의 탭, 디자인 순서 그대로 (Account · Connections · Execution · Reports · Shortcuts). 상세는 탭을 더하지 않는다
enum SettingsWindowTab: String, CaseIterable, Identifiable {
    case account, connections, execution, reports, shortcuts

    var id: Self { self }

    var title: String {
        switch self {
        case .account: "Account"
        case .connections: "Connections"
        case .execution: "Execution"
        case .reports: "Reports"
        case .shortcuts: "Shortcuts"
        }
    }

    /// 탭 아이콘 (Lucide: circle-user · plug · shield-check · bell · keyboard)
    var icon: TFIcon {
        switch self {
        case .account: .account
        case .connections: .connections
        case .execution: .execution
        case .reports: .reports
        case .shortcuts: .shortcuts
        }
    }

    /// `settings.tab`(`SettingsOpener.tabKey`)에 적는 값. 기존 사이드바가 아는 값(`account` · `connections` · `keyboardShortcuts`)은
    /// 그 값을 써서 플래그를 꺼도 같은 페이지가 열린다. Execution · Reports는 기존 창에 없어 그 창은 Connections를 연다
    var storedValue: String {
        self == .shortcuts ? MacSettingsTab.keyboardShortcuts.rawValue : rawValue
    }

    /// 저장값 → 탭. 기존 사이드바 값도 받는다 (`SettingsOpener.open(.account)` · `.connections` · 알림의 `.connections` 포함).
    /// 저장값 없음 · 모르는 값 · 이 창에 자리가 없는 페이지(Task List)는 첫 탭 Account
    static func tab(stored: String?) -> SettingsWindowTab {
        guard let stored else { return .account }
        if let tab = SettingsWindowTab(rawValue: stored) { return tab }
        let legacy = stored == "shortcut" ? .keyboardShortcuts : MacSettingsTab(rawValue: stored)
        switch legacy {
        // Usage & Credits는 G2(Plan & usage, Account)까지 숨김, About은 Account 안으로
        case .account?, .about?, .usage?: return .account
        // Privacy & AI Data는 Connections의 AI processing으로
        case .connections?, .ai?: return .connections
        case .keyboardShortcuts?: return .shortcuts
        case .taskList?, nil: return .account
        }
    }
}

/// 탭 안에서 연 상세. 창 제목이 상세 이름이 되고 Back이 생긴다 (탭은 더하지 않는다)
enum SettingsWindowDetail: Hashable {
    /// Connections › Privacy & AI Data: 외부 AI 처리 동의 내용 (5.1.2(i) 공개, `ConsentDetails`)
    case privacy
    /// Connections › 서비스 하나: Sync Now · Disconnect
    case connection(ConnectionProvider)

    var title: String {
        switch self {
        case .privacy: "Privacy & AI Data"
        case .connection(let provider): SettingsConnectionLine.name(provider)
        }
    }

    var tab: SettingsWindowTab { .connections }
}

/// 트레이 안에서 확인 중인 지우기 (`ConfirmRow`). 한 번에 하나, 탭 · 상세를 옮기면 닫힌다
enum SettingsWindowConfirm: Hashable {
    case deleteAccount
    case withdrawConsent
    case disconnect(ConnectionProvider)
}

/// 창의 상세 · 확인 상태. 탭은 `settings.tab`에 저장되고(마지막 탭을 기억), 상세 · 확인은 창 밖에서 열면 지운다.
/// 설정 창은 닫아도 남아 있어 하나만 둔다 (`shared`)
@MainActor
@Observable
final class SettingsWindowModel {
    static let shared = SettingsWindowModel()

    private(set) var detail: SettingsWindowDetail?
    var confirming: SettingsWindowConfirm?
    /// 연결을 시작하라는 요청 (줄 · 상세의 Connect · Reconnect). Connections 탭의 `ConnectionFlow`가 받아 시작한다
    var connectRequest: ConnectionProvider?

    /// 창 제목: 연 상세, 없으면 탭 이름 (그 탭의 상세만)
    func title(on tab: SettingsWindowTab) -> String {
        detail(on: tab)?.title ?? tab.title
    }

    /// 이 탭에서 연 상세 (다른 탭의 상세는 보이지 않는다)
    func detail(on tab: SettingsWindowTab) -> SettingsWindowDetail? {
        detail?.tab == tab ? detail : nil
    }

    func open(_ detail: SettingsWindowDetail) {
        self.detail = detail
        confirming = nil
    }

    /// Back · 탭 바꾸기 · 창 밖에서 열기 (More 메뉴 · 메뉴 막대 · 알림)
    func close() {
        detail = nil
        confirming = nil
    }
}

/// 탭의 주제. 제목이 없는 것은 앞 주제에 12로 이어지는 트레이 · 링크 줄
enum SettingsWindowSection: String, CaseIterable, Identifiable {
    case profile, signIn, deleteAccount, about, legal
    case aiProcessing, sources, moreServices
    case runWithAI
    case notifications
    case launcher, panelKeys
    /// 로그인이 필요한 탭에서 로그아웃 상태: 로그인 화면
    case signInRequired

    var id: Self { self }

    var title: String? {
        switch self {
        case .profile: "Profile"
        case .signIn: "Sign-in"
        case .about: "About"
        case .aiProcessing: "AI processing"
        case .sources: "Sources"
        case .runWithAI: "Run with AI"
        case .notifications: "Notifications"
        case .launcher: "Launcher"
        case .panelKeys: "In the panel"
        case .deleteAccount, .legal, .moreServices, .signInRequired: nil
        }
    }
}

/// 로그인 상태 (견본 `-TFSampleData`는 로그인한 것으로 본다)
enum SettingsWindowAccess: Equatable {
    case signedIn, signedOut, loading
}

extension SettingsWindowTab {
    /// 탭의 주제, 위에서부터. 아직 연결되지 않은 것(`SettingsWindowHidden`)은 넣지 않는다
    func sections(_ access: SettingsWindowAccess) -> [SettingsWindowSection] {
        switch (self, access) {
        case (.account, .signedIn): [.profile, .signIn, .deleteAccount, .about, .legal]
        // 로그아웃: 로그인 화면, 그 아래 About · 링크는 그대로 (읽는 중이면 로그인 자리에 진행 표시)
        case (.account, _): [.signIn, .about, .legal]
        case (.connections, .signedIn): [.aiProcessing, .sources, .moreServices]
        case (.execution, .signedIn): [.runWithAI]
        case (.connections, _), (.execution, _): [.signInRequired]
        case (.reports, _): [.notifications]
        case (.shortcuts, _): [.launcher, .panelKeys]
        }
    }
}

/// 디자인에는 있지만 이 창에 아직 넣지 않는 것과 이유 (소유자 규칙: 연결되지 않은 것을 되는 것처럼 보이지 않는다).
/// 그 단위가 진짜 데이터 · 서버를 붙일 때 주제를 더하고 여기서 뺀다
enum SettingsWindowHidden: String, CaseIterable {
    case planAndUsage = "Plan & usage"
    case usageAndCredits = "Usage & Credits"
    case subscription = "Subscription"
    case remembered = "Remembered"
    case yourAgents = "Your agents"
    case policyDefault = "Default for new work"
    case policyOverrides = "Overrides"
    case externalCosts = "Spending outside Taskforce"
    case reportsDelivery = "Delivery"
    case taskList = "Task List"

    var tab: SettingsWindowTab {
        switch self {
        case .planAndUsage, .usageAndCredits, .subscription, .remembered, .taskList: .account
        case .yourAgents: .connections
        case .policyDefault, .policyOverrides, .externalCosts: .execution
        case .reportsDelivery: .reports
        }
    }

    /// 숨긴 이유 (구현 계획의 단위)
    var reason: String {
        switch self {
        case .planAndUsage, .usageAndCredits, .subscription, .externalCosts:
            "G2: 10-09 가격(Lemon Squeezy v2)이 $9.99 구독 · credits를 대신한다. UsageCreditsPane · 구독은 기존 창에 남는다"
        case .remembered: "B3: memory_items 읽기 · RememberedDetail"
        case .yourAgents: "D4: 에이전트 adapter gate가 꺼져 있다"
        case .policyDefault, .policyOverrides: "실행 정책 데이터 · API가 아직 없다"
        case .reportsDelivery: "H2: 보고 설정을 아직 저장 · 보내지 않는다"
        case .taskList: "런처 전용 구역 수 제한. Edge 패널은 쓰지 않는다 (기존 창에 남는다)"
        }
    }
}

/// Connections › Sources의 한 줄: 서비스 이름 · 계정 · 상태 말 · 동작 하나 (디자인 `ConnectionRow`).
/// 상태 말: Connected · Synced {relative} · Syncing… · Reconnect to keep syncing · Last sync failed · Not connected
struct SettingsConnectionLine: Equatable {
    enum Action: Equatable {
        case connect, reconnect

        var title: String {
            switch self {
            case .connect: "Connect"
            case .reconnect: "Reconnect"
            }
        }
    }

    let provider: ConnectionProvider
    let name: String
    /// 이름 뒤 회색: Google은 범위(Calendar · Meet), 나머지는 연결된 계정 · 워크스페이스
    let aside: String?
    let detail: String
    /// 사용자가 할 일이 있다: 상태를 굵게, Reconnect는 잉크 버튼 (색은 더하지 않는다)
    let attention: Bool
    let action: Action?
    /// 연결 기록이 있어 상세(Sync Now · Disconnect)를 연다
    let opens: Bool
    /// 연결하는 중 (브라우저를 기다림)
    let busy: Bool

    /// 디자인의 짧은 이름 (기존 목록의 "Google Calendar & Meet"는 이름 + 범위로 나눈다)
    static func name(_ provider: ConnectionProvider) -> String {
        provider == .google ? "Google" : provider.displayName
    }

    /// Google · Gmail의 고정 안내
    static func scope(_ provider: ConnectionProvider) -> String? {
        provider == .google ? "Calendar · Meet" : nil
    }

    static func meta(_ provider: ConnectionProvider) -> String? {
        provider == .gmail ? "Beta · Reconnect every 7 days" : nil
    }

    static func make(
        provider: ConnectionProvider, state: ConnectionState, syncing: Bool, comingSoon: Bool, connecting: Bool, now: Date = Date()
    ) -> SettingsConnectionLine {
        let name = name(provider)
        let record = state.record
        let status: String
        var attention = false
        if connecting {
            status = "Waiting for \(name)…"
        } else if comingSoon, !state.isConnected {
            status = "Coming soon"
        } else {
            switch state {
            case .notConnected:
                status = "Not connected"
            case .needsReconnect:
                status = "Reconnect to keep syncing"
                attention = true
            case .connected where syncing, .syncFailed where syncing:
                status = ConnectionSync.label
            case .syncFailed:
                status = "Last sync failed"
                attention = true
            case .connected(let record):
                status = record.lastSyncedAt.map { "Synced \(WhenText.relative($0, now: now))" } ?? "Connected"
            }
        }
        // Google은 이름 뒤가 범위라 계정은 상태 뒤에
        let account = provider == .google ? record?.displayName : nil
        let detail = [status, account, meta(provider)].compactMap { $0 }.joined(separator: " · ")
        let action: Action? = switch state {
        case .notConnected: comingSoon ? nil : .connect
        case .needsReconnect: .reconnect
        case .connected, .syncFailed: nil
        }
        return SettingsConnectionLine(
            provider: provider, name: name, aside: scope(provider) ?? record?.displayName, detail: detail, attention: attention,
            action: action, opens: state.isConnected, busy: connecting
        )
    }

    /// Disconnect 확인의 보조 줄: 무엇이 멈추고 무엇이 남는지 (Slack은 원문도 지운다)
    static func disconnectDetail(_ provider: ConnectionProvider) -> String {
        "Taskforce stops reading \(name(provider)). \(provider.disconnectNote)"
    }

    /// More services 각주: 나중에 올 서비스 (마크는 그리지 않는다)
    static var comingLater: String {
        let names = ConnectionProvider.stageTwo.map(\.displayName)
        guard let last = names.last else { return "" }
        return "Coming later: \(names.dropLast().joined(separator: ", ")) and \(last)."
    }
}

/// Shortcuts › In the panel: Edge 패널에서 지금 실제로 동작하는 키만 (`EdgeShellModel.Control.shortcut` · `EdgeShellController.handleKey`).
/// 디자인의 ⌘1 Review · ⌘N New chat · 1–3 답하기는 그 화면이 생길 때(S3 · B3) 더한다
enum SettingsPanelKeys {
    static var rows: [(label: String, keys: [String])] {
        EdgeShellModel.Control.allCases.compactMap { control in
            control.shortcut.map { (control.label, keyCaps($0)) }
        }
    }

    /// "⌘2" → ["⌘", "2"] (수식키는 하나씩, 나머지는 키 하나)
    static func keyCaps(_ shortcut: String) -> [String] {
        let modifiers: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
        let mods = shortcut.prefix { modifiers.contains($0) }.map(String.init)
        let key = String(shortcut.drop { modifiers.contains($0) })
        return key.isEmpty ? mods : mods + [key]
    }
}
#endif
