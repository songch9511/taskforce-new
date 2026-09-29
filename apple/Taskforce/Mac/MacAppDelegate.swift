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
            model = LauncherModel(session: session, services: services, account: AppRuntime.account(services: services))
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
    }

    /// `taskforce://connections/…` (ASWebAuthenticationSession이 주소를 바로 돌려주지만, 앱 밖에서 열린 경우를 위해)
    func application(_ application: NSApplication, open urls: [URL]) {
        guard case .ready(_, let services) = AppRuntime.startup else { return }
        let account = AppRuntime.account(services: services)
        for url in urls {
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
        Button("Settings…") { SettingsOpener.open(.account) }
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

enum MacSettingsTab: String, CaseIterable {
    case account, connections, ai, shortcut
}

/// 설정 창 열기. 에이전트 앱은 먼저 앞으로 나와야 창이 다른 앱 뒤에 숨지 않는다.
@MainActor
enum SettingsOpener {
    static var action: OpenSettingsAction?
    static let tabKey = "settings.tab"

    /// Settings 장면의 openSettings를 아직 받지 못했을 때 쓰는 같은 내용의 창
    private static var fallbackWindow: NSWindow?

    static func open(_ tab: MacSettingsTab) {
        UserDefaults.standard.set(tab.rawValue, forKey: tabKey)
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
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        fallbackWindow = window
        window.makeKeyAndOrderFront(nil)
    }
}
#endif
