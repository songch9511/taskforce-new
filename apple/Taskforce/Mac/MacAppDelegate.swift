#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

/// Mac 에이전트 앱의 시작: 로그인 상태 · 런처 패널 · 전역 단축키
@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    /// SwiftUI의 NSApplicationDelegateAdaptor가 만든 인스턴스 (메뉴 · 설정에서 런처와 단축키를 부른다)
    private(set) static weak var shared: MacAppDelegate?

    private(set) var launcher: LauncherPanelController?
    let hotKeys = HotKeyCenter()

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 알림을 눌러 앱이 열린 경우도 받을 수 있게 가장 먼저
        PushCenter.shared.install()
        let model: LauncherModel
        switch AppRuntime.startup {
        case .ready(let session, let services):
            session.start()
            model = LauncherModel(
                session: session, services: services, account: AppRuntime.account(services: services), saved: AppRuntime.savedNow,
                runs: AppRuntime.runs(services: services), connectivity: Connectivity.updates()
            )
        case .misconfigured(let message):
            model = LauncherModel(configurationError: message)
        }
        let launcher = LauncherPanelController(model: model)
        self.launcher = launcher
        // 런처가 숨어 있어도 로그아웃 · 계정 전환을 따라간다 (전 사용자의 목록 · 연결 · 동의를 지운다)
        if case .ready(let session, _) = AppRuntime.startup {
            follow(session, model: model)
        }
        // 누른 알림: 런처를 열고 그 할 일을 고른다
        PushCenter.shared.onOpen = { [weak self] target in self?.openNotification(target) }
        if let target = PushCenter.shared.take() { openNotification(target) }

        hotKeys.onPress = { [weak launcher] in launcher?.toggle() }
        hotKeys.install()
        hotKeys.register(HotKeyShortcut.load())

        // 스크린샷 · 수동 확인용: 실행하자마자 런처를 연다
        if ProcessInfo.processInfo.arguments.contains("--show-launcher") {
            launcher.show()
            #if DEBUG
            launcher.snapshotIfRequested()
            #endif
        }
        #if DEBUG
        // 설정 창 확인용: `--show-settings` (`-TFSnapshot <폴더>`면 항목마다 PNG를 남기고 끝낸다)
        SettingsSnapshot.runIfRequested()
        #endif
    }

    /// `taskforce://connections/…` · Google 로그인 콜백 (ASWebAuthenticationSession이 주소를 바로 돌려주지만, 앱 밖에서 열린 경우를 위해).
    /// 초안 링크 `taskforce://artifacts/<id>`는 런처를 열고 그 초안 (U2 Mac)
    func application(_ application: NSApplication, open urls: [URL]) {
        guard case .ready(_, let services) = AppRuntime.startup else { return }
        let account = AppRuntime.account(services: services)
        for url in urls where !GoogleSignInFlow.handle(url) {
            if let id = ArtifactLink.parse(url), let launcher {
                launcher.show()
                launcher.model.openDraft(id: id)
                continue
            }
            Task { await account.handleCallback(url) }
        }
    }

    private func follow(_ session: SessionStore, model: LauncherModel) {
        withObservationTracking {
            _ = session.state
        } onChange: { [weak self, weak model] in
            Task { @MainActor in
                guard let self, let model else { return }
                model.sessionChanged()
                // 알림: 허용돼 있으면 로그인한 사용자로 기기 토큰을 보낸다
                PushCenter.shared.follow(userID: model.signedInUserID, services: model.services)
                // 로그아웃 · 세션 만료 · 계정 삭제 모두: 이 기기의 Google 로그인도 지운다 (다음 계정이 전 계정의 Google 토큰을 쓰지 않게)
                if session.state == .signedOut { GoogleSignInFlow.signOut() }
                self.follow(session, model: model)
            }
        }
    }

    // MARK: 알림

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushCenter.shared.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // 알림 기능이 없는 서명 (App ID에 Push Notifications가 꺼져 있음 등): 알림 없이 쓴다
    }

    private func openNotification(_ target: NotificationTarget) {
        // 재연결 알림: 설정의 연결 탭 (런처의 할 일이 아니다)
        if target.kind == .reconnect {
            SettingsOpener.open(.connections)
            return
        }
        guard let launcher else { return }
        launcher.show()
        if let id = target.actionID { launcher.model.focus(actionID: id) }
    }

    /// 설정에서 단축키를 바꿀 때. 다른 앱이 쓰는 조합이면 false.
    func changeHotKey(to shortcut: HotKeyShortcut) -> Bool {
        guard hotKeys.register(shortcut) else { return false }
        shortcut.save()
        return true
    }

    func resetHotKey() {
        HotKeyShortcut.reset()
        hotKeys.register(.default)
    }
}

/// 메뉴 막대 아이콘의 메뉴: Open Launcher · Settings · Quit
struct MenuBarMenu: View {
    var body: some View {
        Button("Open Launcher") { MacAppDelegate.shared?.launcher?.show() }
        Button("Settings…") { SettingsOpener.open() }
            .keyboardShortcut(",")
        Divider()
        Button("Quit Taskforce") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// 메뉴 막대 아이콘: 로고 마크 (단색 template)
struct MenuBarLabel: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if let image = TFImage.logoMarkTemplate(height: 12) {
                Image(nsImage: image)
            } else {
                Image(systemName: "checklist")
            }
        }
        .accessibilityLabel("Taskforce")
        // 런처(AppKit 패널)에서도 설정 창을 열 수 있게 장면의 openSettings를 넘겨 둔다
        .onAppear { SettingsOpener.action = openSettings }
    }
}

/// 설정 사이드바 항목 (Figma S1 239:1614). 페이지의 rawValue는 마지막에 본 페이지로 저장된다 (`SettingsOpener.tabKey`).
enum MacSettingsTab: String, CaseIterable {
    case keyboardShortcuts
    /// Beta USD usage for signed-in accounts; execution credits are separately gated.
    case usage
    /// 페이지가 아니라 계정 시트 (↗)
    case account
    case connections
    /// Privacy & AI Data (저장값은 예전 AI data 탭과 같은 `ai`)
    case ai

    enum Group: String {
        case personal = "Personal"
        case work = "Work"
    }

    struct Item: Identifiable, Equatable {
        let tab: MacSettingsTab
        let title: String
        let systemImage: String
        let group: Group

        var id: MacSettingsTab { tab }
    }

    /// 실행(U2)을 쓸 수 있는지 (`RunStore.credits`): 모름(앱을 막 열어 아직 읽지 않음) · 쓸 수 있음(200) · 쓸 수 없음(404 · 로그아웃)
    enum Execution: Equatable {
        case unknown, available, unavailable
    }

    /// 사이드바의 모든 항목, 순서대로. 아직 내용이 없는 항목은 숨기고 그 단위가 한 줄씩 넣는다:
    /// Personal — General(맨 위) · Notifications(U8b) / Work — Automation(U6b, Connections 아래)
    static let all: [Item] = [
        Item(tab: .keyboardShortcuts, title: "Keyboard Shortcuts", systemImage: "keyboard", group: .personal),
        Item(tab: .usage, title: "Usage & Credits", systemImage: "gauge.open.with.lines.needle.33percent", group: .personal),
        Item(tab: .account, title: "Account", systemImage: "person", group: .personal),
        Item(tab: .connections, title: "Connections", systemImage: "link", group: .work),
        Item(tab: .ai, title: "Privacy & AI Data", systemImage: "shield", group: .work),
    ]

    /// Signed-in accounts see beta usage even when execution credits are unavailable.
    static func sidebar(executionAvailable: Bool, signedIn: Bool = false) -> [Item] {
        (executionAvailable || signedIn) ? all : all.filter { $0.tab != .usage }
    }

    /// 실행을 쓸 수 없는 계정의 사이드바 (U1 항목)
    static var sidebar: [Item] { sidebar(executionAvailable: false) }

    var opensSheet: Bool { self == .account }

    /// 설정 창이 보일 페이지. 저장값은 예전 탭 값(`account` · `connections` · `ai` · `shortcut`)도 받는다:
    /// `shortcut`은 Keyboard Shortcuts, 저장값 없음 · `account`(이제 시트) · 모르는 값 · 사이드바에 없는 항목은 Connections (사용자 결정 2026-10-03).
    /// 저장된 `usage`는 실행을 쓸 수 없으면 Connections, 아직 모르면(앱을 막 열어 credits를 읽는 중) 그대로 둔다: 읽는 동안 Connections로 떨어지지 않게
    static func page(stored: String?, execution: Execution = .unavailable, signedIn: Bool = false) -> MacSettingsTab {
        let tab = stored.flatMap { $0 == "shortcut" ? .keyboardShortcuts : MacSettingsTab(rawValue: $0) }
        if tab == .usage { return execution == .unavailable && !signedIn ? .connections : .usage }
        if let tab, !tab.opensSheet, all.contains(where: { $0.tab == tab }) { return tab }
        return .connections
    }

    /// 사이드바 검색칸: 이름에 낱말이 모두 든 항목만 (대소문자 · 악센트 무시). 빈 칸이면 전부
    static func sidebar(matching query: String, executionAvailable: Bool = false, signedIn: Bool = false) -> [Item] {
        let words = query.split(whereSeparator: \.isWhitespace)
        return sidebar(executionAvailable: executionAvailable, signedIn: signedIn).filter { item in words.allSatisfy { item.title.localizedStandardContains($0) } }
    }

    /// ↑↓: 보이는 항목 안에서 한 칸 (끝에서 멈춘다). 지금 항목이 목록에 없으면 ↓는 처음, ↑는 끝으로
    static func step(from current: MacSettingsTab, by offset: Int, in items: [Item]) -> MacSettingsTab? {
        guard let index = items.firstIndex(where: { $0.tab == current }) else {
            return (offset > 0 ? items.first : items.last)?.tab
        }
        return items[min(max(index + offset, 0), items.count - 1)].tab
    }
}

/// 설정 창 위 시트. 사이드바와 창 밖(런처 · 메뉴)이 같이 쓴다: 창이 없을 때 요청해도 창이 뜨면서 띄운다
@MainActor
@Observable
final class SettingsRoute {
    static let shared = SettingsRoute()

    /// Account 시트 (사이드바 Account ↗ · `SettingsOpener.open(.account)`)
    var showsAccount = false
    /// 창 밖에서 연 횟수 (`SettingsOpener.open`). 창이 지난 검색어 · 키보드 자리를 지운다
    private(set) var openCount = 0

    func opened() {
        openCount += 1
    }
}

/// 설정 창 열기. 에이전트 앱은 먼저 앞으로 나와야 창이 다른 앱 뒤에 숨지 않는다.
@MainActor
enum SettingsOpener {
    static var action: OpenSettingsAction?
    static let tabKey = "settings.tab"

    /// Settings 장면의 openSettings를 아직 받지 못했을 때 쓰는 같은 내용의 창
    private static var fallbackWindow: NSWindow?

    /// `tab`이 없으면 마지막에 본 페이지. Account는 창 위에 시트로 연다
    static func open(_ tab: MacSettingsTab? = nil) {
        SettingsRoute.shared.opened()
        if let tab, tab.opensSheet {
            SettingsRoute.shared.showsAccount = true
        } else if let tab {
            UserDefaults.standard.set(tab.rawValue, forKey: tabKey)
        }
        NSApplication.shared.activate()
        guard let action else {
            showFallbackWindow()
            return
        }
        action()
        Task { @MainActor in
            NSApplication.shared.windows
                .first { $0.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true }?
                .makeKeyAndOrderFront(nil)
        }
    }

    private static func showFallbackWindow() {
        if let fallbackWindow {
            fallbackWindow.makeKeyAndOrderFront(nil)
            return
        }
        guard case .ready(let session, let services) = AppRuntime.startup else { return }
        let root = MacSettingsView()
            .environment(session)
            .environment(\.services, services)
            .environment(AppRuntime.account(services: services))
            .environment(AppRuntime.runs(services: services))
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "Settings"
        // 장면 창과 같은 틀 (`MacSettingsView`의 `SettingsWindowChrome`이 넣는 것을 지우지 않게)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.center()
        fallbackWindow = window
        window.makeKeyAndOrderFront(nil)
    }
}
#endif
