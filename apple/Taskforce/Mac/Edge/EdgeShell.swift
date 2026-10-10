#if os(macOS)
import AppKit
import Carbon.HIToolbox
import Observation
import TaskforceKit
import TaskforceUI

/// Edge 셸의 창 · 이벤트 (`TF_EDGE_SHELL`이 켜진 격리 Debug 실행에서만 만든다, `MacAppDelegate`).
/// - 레일 창은 늘 떠 있고, 패널 창은 `EdgeShellModel.panelOpen`을 따라 열고 닫는다
/// - ⌥ Space(`HotKeyCenter`, 손쉬운 사용 권한 불필요)는 패널을 토글한다
/// - 패널 · 레일 밖 클릭은 패널을 접고, 클릭은 누른 곳으로 그대로 간다(마우스 모니터는 이벤트를 먹지 않는다. 키 모니터는 쓰지 않는다)
/// - Esc · ⌘2 · ⌘3은 패널이 키를 가졌을 때만
/// - 데이터는 런처와 같은 `NowStore` · `RunStore`를 읽는다(서버 호출을 늘리지 않는다)
@MainActor
final class EdgeShellController: NSObject, NSWindowDelegate {
    let shell: EdgeShellModel
    let rail: EdgeRailPanelController
    let panel: EdgePanelController
    private let launcher: LauncherModel
    private var clickMonitors: [Any] = []
    private var keyMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var wasSignedIn = false
    #if DEBUG
    /// 디자인 비교 스냅샷이 견본 데이터를 줄일 때 (`EdgeSnapshot`). 바꾸면 바로 다시 읽는다
    var workOverride: ((EdgeWorkSnapshot) -> EdgeWorkSnapshot)? {
        didSet { shell.update(snapshot()) }
    }
    #endif

    init(launcher: LauncherModel) {
        self.launcher = launcher
        shell = EdgeShellModel(reduceMotion: Self.systemReduceMotion, pinStore: Self.pinStore())
        rail = EdgeRailPanelController(shell: shell)
        panel = EdgePanelController(shell: shell)
        super.init()
        panel.panel.delegate = self
        shell.onConnect = { [weak self] in self?.rail.onConnections() }
        shell.onRetry = { [weak self] in self?.load() }
    }

    /// All work 고정의 저장: 앱 설정과 다른 전용 suite(계정별 할 일 id만). 견본은 메모리만 (디스크에 쓰지 않는다)
    private static func pinStore() -> WorkPinStore {
        #if DEBUG
        if SampleData.isEnabled { return WorkPinStore(defaults: nil) }
        #endif
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.taskforcelabs.taskforce"
        return WorkPinStore(defaults: UserDefaults(suiteName: WorkPinStore.suiteName(bundleID: bundleID)))
    }

    /// 움직임 줄이기: 시스템 설정. Debug 스냅샷은 `-TFReduceMotion YES`(인자 영역)로 시스템 설정을 바꾸지 않고 켠다
    static var systemReduceMotion: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "TFReduceMotion") { return true }
        #endif
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func start() {
        rail.show()
        followWork()
        followPanel()
        // 시작할 때 세션은 아직 읽는 중이다: 로그인이 확인되면 그때 목록 · run을 읽는다 (런처는 열 때마다 읽는다)
        followSession()
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.shell.reduceMotion = Self.systemReduceMotion }
        })
        // 해상도 · 화면 구성이 바뀌면 레일을 다시 화면 모서리에 붙이고, 열린 패널도 그 옆으로
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rail.show()
                self?.panel.fitToContent()
            }
        })
    }

    private func followSession() {
        let (signedIn, account) = withObservationTracking {
            (launcher.isSignedIn, launcher.signedInUserID)
        } onChange: { [weak self] in
            Task { @MainActor in self?.followSession() }
        }
        // 계정이 바뀌면 All work의 검색어 · 필터 · 고정을 그 계정 것으로 (전 계정 것을 보이지 않는다)
        shell.accountChanged(Self.workAccount(account))
        if signedIn, !wasSignedIn { load() }
        wasSignedIn = signedIn
    }

    /// 고정을 둘 계정. 견본은 로그인 없이 견본 계정 (메모리 저장)
    private static func workAccount(_ account: UUID?) -> UUID? {
        #if DEBUG
        if SampleData.isEnabled { return SampleData.userID }
        #endif
        return account
    }

    /// ⌥ Space
    func togglePanel() {
        shell.togglePanel()
    }

    // MARK: 데이터

    private func load() {
        guard launcher.isSignedIn else { return }
        if let now = launcher.now { Task { await now.load() } }
        if let runs = launcher.runs {
            Task {
                await runs.loadCredits()
                await runs.refreshActive()
            }
        }
    }

    private func snapshot() -> EdgeWorkSnapshot {
        guard let now = launcher.now else { return .empty }
        let runs = launcher.runs
        let active = runs?.active ?? []
        let stopping = (runs?.stopping ?? []).union(active.filter { $0.isOpen && $0.stoppedAt != nil }.map(\.actionID))
        // 받은 목록이 없으면(읽는 중 · 오프라인 · 실패) 할 일이 없다고 하지 않는다 (`WorkLoad`). 저장본은 이번 실행의 목록이 아니다
        let work = EdgeWorkSnapshot(
            sections: now.sections, working: runs?.workingActionIDs ?? [], stopping: stopping,
            load: WorkLoad.from(refresh: now.refreshState, hasList: now.response != nil),
            doneSince: now.doneTodaySince,
            canConnect: !(launcher.account?.connections.contains { $0.status == .active } ?? false)
        )
        #if DEBUG
        if let workOverride { return workOverride(work) }
        #endif
        return work
    }

    /// 목록 · run이 바뀔 때마다 레일 · 패널에 옮긴다
    private func followWork() {
        let work = withObservationTracking {
            snapshot()
        } onChange: { [weak self] in
            Task { @MainActor in self?.followWork() }
        }
        if work != shell.work { shell.update(work) }
        // 포인터 아래 칸이 사라지면 툴팁도 내린다
        if shell.tooltip == nil { rail.hideTooltip() }
    }

    // MARK: 패널

    private func followPanel() {
        let open = withObservationTracking {
            _ = panel.presentation.bodyHeight
            return shell.panelOpen
        } onChange: { [weak self] in
            Task { @MainActor in self?.followPanel() }
        }
        if open {
            if panel.presentation.shown, panel.isVisible {
                panel.fitToContent()
            } else if panel.show() {
                rail.hideTooltip()
                installMonitors()
                load()
            }
        } else if panel.presentation.shown || hasMonitors {
            panel.hide()
            removeMonitors()
        }
    }

    private var hasMonitors: Bool { !clickMonitors.isEmpty || keyMonitor != nil }

    private func installMonitors() {
        guard !hasMonitors else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // 다른 앱을 누름 (전역 마우스 모니터는 손쉬운 사용 권한이 필요 없다)
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.shell.dismiss() }
        }) {
            clickMonitors.append(global)
        }
        // 이 앱의 다른 창을 누름 (레일 · 툴팁은 빼고)
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if event.window !== self.panel.panel, event.window !== self.rail.panel {
                    self.shell.dismiss()
                }
            }
            return event
        }) {
            clickMonitors.append(local)
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, event.window === self.panel.panel else { return false }
                return self.handleKey(event)
            }
            return handled ? nil : event
        }
    }

    private func removeMonitors() {
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors = []
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// 패널의 키: Esc 접기 · ⌘2 All work · ⌘3 Chats. 처리했으면 true
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch Int(event.keyCode) {
        case kVK_Escape:
            // 열린 필터 카드를 먼저 닫고, 그다음 패널을 접는다
            shell.escape()
            return true
        case kVK_ANSI_2 where flags == .command:
            shell.openAllWork()
            return true
        case kVK_ANSI_3 where flags == .command:
            shell.openChats()
            return true
        default:
            return false
        }
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // ⌘Tab 등으로 키를 잃으면 접는다 (More 메뉴를 연 동안은 빼고)
        guard shell.panelOpen, !shell.menuOpen else { return }
        shell.dismiss()
    }
}
#endif
