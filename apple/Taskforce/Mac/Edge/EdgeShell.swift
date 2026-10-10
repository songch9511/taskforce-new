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
/// - 데이터는 런처와 같은 `NowStore` · `RunStore` · `AccountStore`를 읽는다. Edge가 더하는 서버 호출은 둘뿐이다:
///   패널이 보이는 동안 동기화 중이면 연결 다시 읽기(6초마다, 구 런처가 떠 있을 때 하는 것과 같다)와 동기화가 끝난 뒤 `/now` 한 번.
///   목록 읽기는 이미 읽는 중이거나(숨은 구 런처 화면이 먼저 읽음) 끝난 뒤 받은 목록이 있으면 겹쳐 부르지 않는다
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
    /// 패널이 보이는 동안 동기화 중인 연결을 따라 읽는 작업 (`AccountStore.followSync`)
    private let syncFollower = EdgeSyncFollower()
    /// 앱을 연 뒤 로그인 상태를 처음 알게 되면 한 번: 지금 계정이 아닌 고정을 지운다 (`SavedNowStore.prune`과 같다)
    private var prunedPins = false
    private let pinStore: WorkPinStore
    #if DEBUG
    /// 디자인 비교 스냅샷이 견본 데이터를 줄일 때 (`EdgeSnapshot`). 바꾸면 바로 다시 읽는다
    var workOverride: ((EdgeWorkSnapshot) -> EdgeWorkSnapshot)? {
        didSet { shell.update(snapshot()) }
    }
    #endif

    init(launcher: LauncherModel) {
        self.launcher = launcher
        let pinStore = Self.pinStore()
        self.pinStore = pinStore
        shell = EdgeShellModel(reduceMotion: Self.systemReduceMotion, pinStore: pinStore)
        rail = EdgeRailPanelController(shell: shell)
        panel = EdgePanelController(shell: shell)
        super.init()
        panel.panel.delegate = self
        shell.onConnect = { [weak self] in self?.rail.onConnections() }
        shell.onRetry = { [weak self] in self?.load() }
    }

    /// All work 고정의 저장: 앱 설정과 다른 전용 suite(계정별 할 일 id만). 견본 · 번들 id를 모를 때는 메모리만 (디스크에 쓰지 않는다,
    /// 실사용 앱의 id로 대신 쓰지 않는다)
    private static func pinStore() -> WorkPinStore {
        #if DEBUG
        if SampleData.isEnabled { return WorkPinStore(defaults: nil) }
        #endif
        guard let bundleID = Bundle.main.bundleIdentifier else { return WorkPinStore(defaults: nil) }
        return WorkPinStore(defaults: UserDefaults(suiteName: WorkPinStore.suiteName(bundleID: bundleID)))
    }

    /// 계정이 떠나면(로그아웃 · 만료 · 계정 삭제 · 전환) 이 Mac의 고정을 모두 지운다 (`SessionStore.onSignedOut`, 저장본과 같은 정리)
    static func removePinsWhenAccountLeaves(_ session: SessionStore?, store: WorkPinStore) {
        session?.onSignedOut { [store] _ in store.removeAll() }
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
        // 계정이 떠나면(로그아웃 · 만료 · 계정 삭제 · 전환) 이 Mac의 고정을 모두 지운다 (이 기기 저장본 `SavedNowStore`와 같은 정리)
        Self.removePinsWhenAccountLeaves(launcher.session, store: pinStore)
        followWork()
        followPanel()
        followSync()
        followSyncFinished()
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
        // 앱이 돌지 않는 동안 떠난 계정의 고정은 `onSignedOut`에 오지 않는다: 로그인 상태를 처음 알면 지금 계정 것만 남긴다
        if !prunedPins, let keep = Self.knownAccount(launcher.session?.state) {
            prunedPins = true
            pinStore.prune(keeping: keep)
        }
        // 계정이 바뀌면 All work의 검색어 · 필터 · 고정을 그 계정 것으로 (전 계정 것을 보이지 않는다)
        shell.accountChanged(Self.workAccount(account))
        if signedIn, !wasSignedIn { load() }
        wasSignedIn = signedIn
    }

    /// 로그인 상태를 알면 그 계정(로그아웃이면 `.some(nil)`), 아직 읽는 중 · 세션 없음이면 nil (첫 `prune`을 미룬다)
    static func knownAccount(_ state: SessionStore.State?) -> UUID?? {
        switch state {
        case nil, .loading?: nil
        case .signedIn(let userID, _)?: .some(userID)
        case .signedOut?: .some(nil)
        }
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
        // 이미 읽는 중이면 겹쳐 부르지 않는다 (그 응답이 곧 온다)
        if let now = launcher.now, !now.refresh.isLoading { Task { await now.load() } }
        if let runs = launcher.runs {
            Task {
                await runs.loadCredits()
                await runs.refreshActive()
            }
        }
    }

    private func snapshot() -> EdgeWorkSnapshot {
        let work = Self.snapshot(now: launcher.now, runs: launcher.runs, account: launcher.account)
        #if DEBUG
        if let workOverride { return workOverride(work) }
        #endif
        return work
    }

    /// 레일 · 패널이 읽을 지금의 일 (목록 · run · 연결 상태에서)
    static func snapshot(now: NowStore?, runs: RunStore?, account: AccountStore?) -> EdgeWorkSnapshot {
        guard let now else { return .empty }
        let active = runs?.active ?? []
        let stopping = (runs?.stopping ?? []).union(active.filter { $0.isOpen && $0.stoppedAt != nil }.map(\.actionID))
        // 받은 목록이 없으면(읽는 중 · 오프라인 · 실패) 할 일이 없다고 하지 않는다 (`WorkLoad`). 저장본은 이번 실행의 목록이 아니다
        return EdgeWorkSnapshot(
            sections: now.sections, working: runs?.workingActionIDs ?? [], stopping: stopping,
            load: WorkLoad.from(refresh: now.refreshState, hasList: now.response != nil),
            doneSince: now.doneTodaySince,
            // 연결을 아직 못 읽었으면 "연결 없음"으로 보지 않는다 (연결된 사용자에게 Connect a source를 잠깐 보이지 않게)
            canConnect: account.map { EdgeWorkSnapshot.canConnect(connectionsLoaded: $0.connectionsLoaded, connections: $0.connections) } ?? false,
            syncing: account?.anySyncing == true
        )
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

    // MARK: 동기화

    /// 패널이 실제로 보이는 동안 동기화 중인 연결을 몇 초마다 다시 읽는다 (구 런처는 자기가 떠 있는 동안만 `followSync`를 돌려 Edge 모드에서는 돌지 않는다).
    /// `start()`에서 한 번 걸면 패널이 보이는지(`presentation.shown`: 창을 띄우지 못하면 거짓) · 동기화 중인지를 계속 지켜보고,
    /// 둘 중 하나가 거짓이 되면 스스로 멈춘다
    private func followSync() {
        let follow = withObservationTracking {
            launcher.account?.anySyncing == true && panel.presentation.shown
        } onChange: { [weak self] in
            Task { @MainActor in self?.followSync() }
        }
        let account = launcher.account
        syncFollower.update(shouldFollow: follow && account != nil) {
            guard let account else { return }
            // 패널을 열 때 연결 상태가 오래됐으면 바로 한 번 읽는다 (끝난 동기화를 6초 기다리지 않게)
            if Date().timeIntervalSince(account.connectionsReadAt) >= 3 { await account.reloadConnections() }
            await account.followSync()
        }
    }

    /// 동기화가 끝나면 지금 할 일을 다시 불러온다 (구 런처의 `syncFinished` 처리와 같다).
    /// 숨은 구 런처 화면의 `.onChange(of: syncFinished)`가 먼저 읽기 시작했거나 끝냈으면 겹쳐 부르지 않는다 (`needsReloadAfterSync`)
    private func followSyncFinished() {
        let finished = withObservationTracking {
            launcher.account?.syncFinished
        } onChange: { [weak self] in
            let finishedAt = Date()
            Task { @MainActor in
                guard let self else { return }
                self.followSyncFinished()
                // 같은 변화를 받은 숨은 구 런처 화면이 먼저 읽기 시작할 틈
                try? await Task.sleep(for: .milliseconds(300))
                guard let now = self.launcher.now, self.launcher.isSignedIn,
                      Self.needsReloadAfterSync(now.refresh, finishedAt: finishedAt) else { return }
                await now.load()
            }
        }
        _ = finished
    }

    /// 동기화가 끝난 뒤 Edge가 `/now`를 다시 읽을지: 이미 읽는 중이거나 끝난 뒤 받은 목록이 있으면 읽지 않는다
    static func needsReloadAfterSync(_ refresh: RefreshTracker, finishedAt: Date) -> Bool {
        if refresh.isLoading { return false }
        if refresh.isLive, let shown = refresh.shownAt, shown >= finishedAt { return false }
        return true
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
/// 패널이 보이는 동안 동기화를 따라 읽는 작업 하나: 켜면 하나만 돌고, 꺼지면(`shouldFollow` 거짓) 스스로 취소한다
@MainActor
final class EdgeSyncFollower {
    private var task: Task<Void, Never>?
    private var generation = 0

    var isFollowing: Bool { task != nil }

    func update(shouldFollow: Bool, follow: @escaping @MainActor () async -> Void) {
        guard shouldFollow else {
            stop()
            return
        }
        guard task == nil else { return }
        generation += 1
        let current = generation
        task = Task { [weak self] in
            await follow()
            guard let self, self.generation == current else { return }
            self.task = nil
        }
    }

    func stop() {
        generation += 1
        task?.cancel()
        task = nil
    }
}
#endif
