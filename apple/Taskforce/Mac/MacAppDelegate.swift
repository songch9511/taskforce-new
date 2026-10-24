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

    private(set) var launcherModel: LauncherModel?
    private var changesTask: Task<Void, Never>?
    private var changesUserID: UUID?
    private var pendingActionID: UUID?
    /// Current Mac shell. Feature flags still gate its optional server-backed surfaces.
    private(set) var edge: EdgeShellController?
    /// 대화 · 기억 상태 (`TF_EDGE_SHELL`이 켜졌을 때만)
    private(set) var chatRuntime: ChatRuntime?
    /// S4 · C3의 계정 경계를 포함한 Edge 기초 (`EdgeSurfaces.current`대로)
    private var edgeFoundation = AppRuntime.EdgeFoundation(chat: nil, scope: nil)
    /// Mac bridge 연결 (OA D2b). `BRIDGE_ENABLED`가 꺼져 있고 원장에 할 일도 없으면 아무것도 만들지 않는다 (기본)
    private(set) var bridge: BridgeHost?
    let hotKeys = HotKeyCenter()
    let settingsHotKeys = HotKeyCenter(id: 2)

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosted unit tests construct their own sessions and stores. Do not start the real
        // account, cache pruning, notifications, or global shortcuts in the test host.
        #if DEBUG
        guard !TestHost.isTestHost() else { return }
        #endif
        // 알림을 눌러 앱이 열린 경우도 받을 수 있게 가장 먼저
        PushCenter.shared.install()
        let model: LauncherModel
        switch AppRuntime.startup {
        case .ready(let session, let services):
            // 설정 창 프로필 칸은 화면과 상관없이 세션을 따라간다 (계정이 떠나면 쓰던 칸 · 남은 저장을 지운다)
            SettingsWindowModel.shared.profile.bind(to: session)
            // Edge 셸이 쓰는 기초(Chats 런타임 · S4/C3 계정 경계)도 세션이 시작되기 전에 붙어 처음 로그인부터 계정 경계를 지킨다.
            // 어느 표면이 켜지는지는 `EdgeSurfaces.current`가 정한다: Release는 셸 + All work + S4 + C3뿐(Chats 런타임 없음), 격리 Debug는 launch argument
            edgeFoundation = AppRuntime.edgeFoundation(session: session, services: services)
            chatRuntime = edgeFoundation.chat
            session.start()
            // bridge는 연결만 한다 (핵심은 TaskforceKit `BridgeRuntime`). 계정이 정해진 뒤 `syncAccount`가 런타임을 올리거나 올리지 않는다
            bridge = BridgeHost.live(session: session, services: services)
            bridge?.start()
            model = LauncherModel(
                session: session, services: services, account: AppRuntime.account(services: services), saved: AppRuntime.savedNow,
                runs: AppRuntime.runs(services: services), connectivity: Connectivity.updates()
            )
        case .misconfigured(let message):
            model = LauncherModel(configurationError: message)
        }
        launcherModel = model
        // 런처가 숨어 있어도 로그아웃 · 계정 전환을 따라간다 (전 사용자의 목록 · 연결 · 동의를 지운다)
        if case .ready(let session, _) = AppRuntime.startup {
            follow(session, model: model)
        }
        followChanges(model)
        // Notifications open the current shell.
        PushCenter.shared.onOpen = { [weak self] target in self?.openNotification(target) }

        do {
            // Review 페이지(S4) · 복귀 요약(C3)은 각자의 표면 값(`S4Flag` · `C3Flag`)이 켜졌을 때만 연결된다 (nil이면 지금 그대로). 계정 경계는 Chats 것이 아니라 Edge 기초의 것
            let features = AppRuntime.edgeFeatures(foundation: edgeFoundation, now: model.now, services: model.services)
            let edge = EdgeShellController(launcher: model, chat: chatRuntime, review: features.review, summary: features.summary)
            self.edge = edge
            edge.start()
            #if DEBUG
            // 견본(`-TFSampleData`)에서 Review 답은 서버 없이 가짜 서버(`SampleReviewServer`)가 받는다
            if SampleData.isEnabled, edge.shell.review != nil { model.now?.installSampleReview(SampleReviewServer()) }
            #endif
            hotKeys.onPress = { [weak self] in self?.toggleTaskforce() }
        }
        if let target = PushCenter.shared.take() { openNotification(target) }
        hotKeys.install()
        hotKeys.register(HotKeyShortcut.load())
        settingsHotKeys.onPress = { SettingsOpener.open() }
        settingsHotKeys.install()
        if let shortcut = HotKeyShortcut.load(for: .settings),
           !shortcut.matches(HotKeyShortcut.load()) {
            settingsHotKeys.register(shortcut)
        }

        // 자동 업데이트(Sparkle): 피드 주소나 공개 키가 비어 있거나 Debug이면 시작하지 않는다 (`AppUpdater` · `UpdateConfiguration`)
        AppUpdater.shared.start()

        // Keep the existing launch argument as an alias for the current shell.
        if ProcessInfo.processInfo.arguments.contains("--show-launcher") {
            openTaskforce()
        }
        #if DEBUG
        // 설정 창 확인용: `--show-settings` (`-TFSnapshot <폴더>`면 항목마다 PNG를 남기고 끝낸다)
        SettingsSnapshot.runIfRequested()
        // Edge 셸 확인용: `-TF_EDGE_SHELL YES -TFEdgeSnapshot <폴더>`
        if let edge { EdgeSnapshot.runIfRequested(edge) }
        // Edge 셸 합성 조작 확인용: `-TF_EDGE_SHELL YES -TFSampleData -TFEdgeInteract <로그 파일>`
        if let edge { EdgeInteraction.runIfRequested(edge) }
        if let edge { AgentTreeSample.runIfRequested(edge) }
        #endif
    }

    /// 종료: 실행 중인 에이전트 턴이 있으면 확인 창 (Quit → 중단 · outbox 비우기 뒤 종료, Cancel → 변화 0). 아니면 바로 종료
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.terminationReply(
            questions: chatRuntime?.questions, bridgeReply: { [weak self] in self?.bridge?.terminationReply() ?? .terminateNow },
            reply: { NSApp.reply(toApplicationShouldTerminate: $0) }
        )
    }

    /// 종료 (OA D4b-m-1, D4bm-22): 보류 중인 답이 있으면 **먼저** 비밀값이 아닌 답을 곧바로 보내고 (끝나거나 3초가 지날 때까지) 비밀값 답은 보내지 않고 값을 버린 뒤, bridge의 종료 응답으로 넘긴다.
    /// 보류가 없으면 지금 그대로 bridge 응답이다. `bridgeReply`가 `terminateLater`면 bridge가 따로 응답한다 (확인 창)
    static func terminationReply(
        questions: AgentQuestionStore?, bridgeReply: @escaping () -> NSApplication.TerminateReply, reply: @escaping (Bool) -> Void
    ) -> NSApplication.TerminateReply {
        guard let questions, questions.hasHeldAnswers else { return bridgeReply() }
        Task { @MainActor in
            await questions.flushForQuit()
            switch bridgeReply() {
            case .terminateNow: reply(true)
            case .terminateCancel: reply(false)
            case .terminateLater: break
            @unknown default: reply(true)
            }
        }
        return .terminateLater
    }

    /// `taskforce://connections/…` · Google 로그인 콜백 (ASWebAuthenticationSession이 주소를 바로 돌려주지만, 앱 밖에서 열린 경우를 위해).
    /// 초안 링크 `taskforce://artifacts/<id>`는 런처를 열고 그 초안 (U2 Mac).
    /// Apple 웹 로그인 주소 `taskforce://auth/apple…`은 버린다 (`routeOpenedURLs`)
    func application(_ application: NSApplication, open urls: [URL]) {
        guard case .ready(_, let services) = AppRuntime.startup else { return }
        let account = AppRuntime.account(services: services)
        Self.routeOpenedURLs(
            urls,
            google: GoogleSignInFlow.handle,
            artifact: { _ in
                // The current shell has no standalone artifact viewer. Consume this
                // recognized URL without sending it to the connection callback.
                self.openTaskforce()
                return true
            },
            connection: { url in Task { await account.handleCallback(url) } }
        )
    }

    /// 앱 밖에서 열린 주소를 어디로 보낼지. Apple 웹 로그인 주소(`taskforce://auth/apple…`)는 아무 데도 보내지 않는다:
    /// 그 주소는 앱이 띄운 ASWebAuthenticationSession만 받고(자기가 만든 state일 때만), 앱 밖에서 열린 것은 토큰을 쓰지 않으며 연결 콜백으로도 넘기지 않는다.
    static func routeOpenedURLs(
        _ urls: [URL], google: (URL) -> Bool, artifact: (UUID) -> Bool, connection: (URL) -> Void
    ) {
        for url in urls {
            if AppleSignInFlow.isAppleCallback(url) { continue }
            if google(url) { continue }
            if let id = ArtifactLink.parse(url), artifact(id) { continue }
            connection(url)
        }
    }

    private func syncChangesAccount(_ model: LauncherModel) {
        let userID = model.signedInUserID
        if changesUserID != userID {
            changesTask?.cancel()
            changesUserID = userID
            if let userID, let services = model.services {
                changesTask = Task { await model.changes.follow(services: services, userID: userID) }
            }
        }
    }

    private func followChanges(_ model: LauncherModel) {
        syncChangesAccount(model)
        withObservationTracking { _ = model.changes.revision } onChange: { [weak self, weak model] in
            Task { @MainActor in
                guard let self, let model else { return }
                await model.now?.load()
                await model.runs?.actionsChanged()
                self.followChanges(model)
            }
        }
    }

    private func follow(_ session: SessionStore, model: LauncherModel) {
        withObservationTracking {
            _ = session.state
        } onChange: { [weak self, weak model] in
            Task { @MainActor in
                guard let self, let model else { return }
                model.sessionChanged()
                self.syncChangesAccount(model)
                if model.isSignedIn, self.pendingActionID != nil { self.openTaskforce() }
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
        // 에이전트 질문 알림 (OA D4b-m-1, D4bm-63): 그 세션의 카드로 간다. 질문이 없어진 뒤 눌러도 그 세션을 열 뿐이다. 게이트가 꺼져 있으면 앱만 연다
        if target.kind == .question {
            guard let sessionID = target.sessionID, let edge else { return }
            NSApp.activate()
            edge.openQuestion(sessionID: sessionID)
            return
        }
        pendingActionID = target.actionID
        openTaskforce()
    }

    /// The current shell is the only app entrypoint. Account recovery stays available
    /// without constructing the retired Search tasks window.
    func openTaskforce() {
        NSApp.activate()
        guard let model = launcherModel else { return }
        if model.configurationError != nil || !model.isSignedIn {
            SettingsOpener.open(.account)
        } else if let id = pendingActionID, let edge {
            pendingActionID = nil
            edge.shell.open(itemID: id)
        } else {
            edge?.shell.openAllWork()
        }
    }

    private func toggleTaskforce() {
        guard launcherModel?.isSignedIn == true else { openTaskforce(); return }
        edge?.togglePanel()
    }

    /// Stored preferences change only after successful registration.
    func changeHotKey(to shortcut: HotKeyShortcut) -> Bool {
        changeHotKey(to: shortcut, for: .launcher)
    }

    func changeHotKey(to shortcut: HotKeyShortcut, for action: HotKeyShortcut.Action) -> Bool {
        let other = HotKeyShortcut.load(for: action == .launcher ? .settings : .launcher)
        guard other?.matches(shortcut) != true else { return false }
        let center = action == .launcher ? hotKeys : settingsHotKeys
        guard center.register(shortcut) else { return false }
        shortcut.save(for: action)
        return true
    }

    @discardableResult
    func resetHotKey() -> Bool {
        guard changeHotKey(to: .default) else { return false }
        HotKeyShortcut.reset()
        return true
    }

    func removeSettingsHotKey() {
        settingsHotKeys.remove()
        HotKeyShortcut.reset(for: .settings)
    }

    func isHotKeyRegistered(for action: HotKeyShortcut.Action) -> Bool {
        let center = action == .launcher ? hotKeys : settingsHotKeys
        guard let saved = HotKeyShortcut.load(for: action),
              let current = center.current else { return false }
        return center.isRegistered && current.matches(saved)
    }

    func suspendHotKeys() {
        hotKeys.suspend()
        settingsHotKeys.suspend()
    }

    @discardableResult
    func resumeHotKeys() -> Bool {
        let launcherRestored = hotKeys.resume()
        let settingsRestored = settingsHotKeys.resume()
        return launcherRestored && settingsRestored
    }

}

/// 메뉴 막대 아이콘의 메뉴: Open Taskforce · Check for Updates… · Settings · Quit
struct MenuBarMenu: View {
    var body: some View {
        Button("Open Taskforce") { MacAppDelegate.shared?.openTaskforce() }
        CheckForUpdatesButton()
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
    case taskList
    /// Beta USD usage for signed-in accounts; execution credits are separately gated.
    case usage
    case account
    case about
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
        Item(tab: .taskList, title: "Task List", systemImage: "list.bullet", group: .personal),
        Item(tab: .usage, title: "Usage & Credits", systemImage: "gauge.open.with.lines.needle.33percent", group: .personal),
        Item(tab: .account, title: "Account", systemImage: "person", group: .personal),
        Item(tab: .about, title: "About", systemImage: "info.circle", group: .personal),
        Item(tab: .connections, title: "Connections", systemImage: "link", group: .work),
        Item(tab: .ai, title: "Privacy & AI Data", systemImage: "shield", group: .work),
    ]

    /// Signed-in accounts see beta usage even when execution credits are unavailable.
    static func sidebar(executionAvailable: Bool, signedIn: Bool = false) -> [Item] {
        (executionAvailable || signedIn) ? all : all.filter { $0.tab != .usage }
    }

    /// 실행을 쓸 수 없는 계정의 사이드바 (U1 항목)
    static var sidebar: [Item] { sidebar(executionAvailable: false) }

    /// 설정 창이 보일 페이지. 저장값은 예전 탭 값(`account` · `connections` · `ai` · `shortcut`)도 받는다:
    /// `shortcut`은 Keyboard Shortcuts, 저장값 없음 · 모르는 값 · 사이드바에 없는 항목은 Connections (사용자 결정 2026-10-03).
    /// 저장된 `usage`는 실행을 쓸 수 없으면 Connections, 아직 모르면(앱을 막 열어 credits를 읽는 중) 그대로 둔다: 읽는 동안 Connections로 떨어지지 않게
    static func page(stored: String?, execution: Execution = .unavailable, signedIn: Bool = false) -> MacSettingsTab {
        let tab = stored.flatMap { $0 == "shortcut" ? .keyboardShortcuts : MacSettingsTab(rawValue: $0) }
        if tab == .usage { return execution == .unavailable && !signedIn ? .connections : .usage }
        if let tab, all.contains(where: { $0.tab == tab }) { return tab }
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

/// 설정 창을 다시 열 때 검색과 데이터를 갱신하는 공유 신호.
@MainActor
@Observable
final class SettingsRoute {
    static let shared = SettingsRoute()

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

    /// `tab`이 없으면 마지막에 본 페이지.
    static func open(_ tab: MacSettingsTab? = nil) {
        SettingsRoute.shared.opened()
        if let tab {
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
        let root = MacSettingsRoot()
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
