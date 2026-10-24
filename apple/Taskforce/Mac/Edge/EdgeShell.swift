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
    let launcher: LauncherModel
    /// Chats · Remembered (B3). 앱 시작 때 세션에 붙은 것을 받는다
    let chat: ChatRuntime?
    /// Assistant 창들 (OA U1). `EdgeSurfaces.assistantWindows`가 꺼져 있으면(Release · 창이 없는 구성) nil이고 Chats는 지금처럼 패널의 한 화면이다
    let assistant: AssistantWindowManager?
    /// 세션 패널 창 (OA U2): 이슈 패널 왼쪽의 두 번째 창. 새 Issues 화면이 꺼져 있으면 nil
    let sessionPanel: EdgeSessionPanelController?
    /// Claude 데스크톱 세션 보기 창 (OA PR-D2, 읽기 전용): Sessions 왼쪽 또는 레일 옆 한 패널. 목록(`BridgeFlag` · 새 Issues 화면)이 없으면 nil
    let claudePanel: EdgeClaudeAppPanelController?
    let codexPanel: EdgeClaudeAppPanelController?
    /// 저장된 대화 읽기 패널 창 (OA D3v-m, 읽기 전용): Sessions 왼쪽. 저장소(`BridgeFlag` · 새 Issues 화면)가 없으면 nil
    let savedChatPanel: EdgeSavedChatPanelController?
    /// 범용 메뉴 창 (OA U2): 이슈 패널의 메뉴 창을 "밖"으로 치지 않으려고 컨트롤러가 알아본다 (`ownsIssueWindow`)
    let menu = EdgeContextMenu()
    /// 지금의 키 창 (키를 잃을 때 새 키 창이 Assistant 창인지 본다. 시험은 이 값을 바꾼다)
    var keyWindow: () -> NSWindow? = { NSApp.keyWindow }
    private var clickMonitors: [Any] = []
    #if DEBUG
    /// 무인 합성 조작 · 스냅샷 실행(`-TFEdgeInteract*` · `-TFEdgeSnapshot*`)은 사용자 · 다른 앱이 같은 화면을 쓰는 중에도 돈다. 다른 앱의 클릭 · 활성화가 패널을 접으면(제품 동작) 그 실행의 결과가
    /// 하네스가 아니라 환경에 좌우된다(글자 인식 · 클릭 · 키가 접힌 패널에 간다). 그래서 그런 실행에서만 **밖 클릭 · 키를 잃음으로 접기를 걸지 않는다**
    /// (Esc · 명령 키 · 안쪽 클릭 · 하네스가 직접 부르는 `dismiss()`는 그대로). 시험은 이 값을 직접 바꾼다. Release 빌드에는 이 값이 없다 — 늘 접는다
    var ignoresExternalDismissal = ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("-TFEdgeInteract") || $0.hasPrefix("-TFEdgeSnapshot") }
    #endif
    private var keyMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var wasSignedIn = false
    /// 패널이 보이는 동안 동기화 중인 연결을 따라 읽는 작업 (`AccountStore.followSync`)
    private let syncFollower = EdgeSyncFollower()
    /// 앱을 연 뒤 로그인 상태를 처음 알게 되면 한 번: 지금 계정이 아닌 고정을 지운다 (`SavedNowStore.prune`과 같다)
    private var prunedPins = false
    private let pinStore: WorkPinStore
    /// 로컬 날짜 · 시간대 · 시스템 시계가 바뀌거나 Mac이 깨어나면 All work의 "오늘"을 다시 계산하게 셸 모델에 알린다 (서버 호출 없음)
    private var timeWatcher: EdgeTimeWatcher?
    #if DEBUG
    /// 디자인 비교 스냅샷이 견본 데이터를 줄일 때 (`EdgeSnapshot`). 바꾸면 바로 다시 읽는다
    var workOverride: ((EdgeWorkSnapshot) -> EdgeWorkSnapshot)? {
        didSet { shell.update(snapshot()) }
    }
    #endif

    /// - review: Review 페이지의 답을 보내는 곳 (S4). nil이면 S4 gate가 꺼진 것이다: Review 페이지 · ⌘1 · ← → · 1 · 2 연결이 없다 (`AppRuntime.reviewDesk`)
    /// - summary: 복귀 요약(C3)을 읽고 Clear하는 곳. nil이면 C3 gate가 꺼진 것이다: All work 위 카드도 서버 읽기도 없다 (`AppRuntime.returnSummary`)
    /// - assistantWindows: Assistant 창이 있는 구성인가 (`EdgeSurfaces.current.assistantWindows`: Debug는 셸이 켜지면, Release는 늘 꺼짐. Debug의 `-TFPanelChats YES`는 옛 패널 Chats). 켜지면 레일 Chats · ⌘3 · ⌘N이 패널의 Chats 화면 대신 창을 연다
    /// - positionStore: 창 위치를 기억할 곳 (앱 설정 도메인, 시험은 격리 suite를 넘긴다)
    /// - injectedExternalSessions · injectedDesktop: 시험이 넘기는 가짜 목록 · 데스크톱 세션 (실제 `~/.claude` · 서버를 읽지 않는다). 없으면 이 실행의 게이트가 만든다
    init(
        launcher: LauncherModel, chat: ChatRuntime? = nil, review: ReviewDesk? = nil, summary: ReturnSummaryStore? = nil,
        assistantWindows: Bool = EdgeSurfaces.assistantWindowsForThisRun, positionStore: AssistantWindowPositionStore? = nil,
        injectedExternalSessions: ExternalSessionsStore? = nil, injectedDesktop: ClaudeAppRuntime.Made? = nil, injectedSavedChats: SavedChatsStore? = nil,
        injectedAttach: ExternalSessionAttachModel? = nil
    ) {
        self.launcher = launcher
        self.chat = chat
        let pinStore = Self.pinStore()
        self.pinStore = pinStore
        let windows = chat != nil && assistantWindows
        // 레일 On this Mac (OA 외부 세션 PR1): 새 Issues 화면 ∧ BridgeFlag ∧ 로그인일 때만. 아니면 nil이라 칸도 훑기도 서버 보고도 없다
        let externalSessions: ExternalSessionsStore?
        if let injectedExternalSessions {
            externalSessions = injectedExternalSessions
        } else {
            #if DEBUG
            // 견본 하네스(`-TFEdgeSnapshotExternalSessions`)는 가짜 훑기를 쓴다 (이 Mac의 실제 Claude 기록을 읽지 않는다)
            externalSessions = ExternalSessionSnapshot.isEnabled && chat?.issues != nil
                ? ExternalSessionSnapshot.sampleStore(scope: chat?.scope)
                : ExternalSessionsRuntime.make(services: launcher.services, scope: chat?.scope, issueScreens: chat?.issues != nil, session: launcher.session)
            #else
            externalSessions = ExternalSessionsRuntime.make(services: launcher.services, scope: chat?.scope, issueScreens: chat?.issues != nil, session: launcher.session)
            #endif
        }
        // 데스크톱 세션(레일 링 · Sessions의 살아 있는 줄 · 세션 보기)은 목록과 같은 게이트다. 끝난 링은 열어 볼 때까지 남는다 (안 연 끝남 표시, 새 Issues 화면)
        // 저장소는 앱 생성 경로가 런타임에 실어 둔 것이다 (`AppRuntime.doneStores`: 실사용 앱은 영속, 시험 호스트 · 견본은 메모리). 여기서 따로 고르지 않는다
        let doneStores = chat?.doneStores ?? .inMemory()
        let desktop: ClaudeAppRuntime.Made?
        if let injectedDesktop {
            desktop = injectedDesktop
        } else {
            #if DEBUG
            desktop = ExternalSessionSnapshot.isEnabled && externalSessions != nil
                ? ExternalSessionSnapshot.sampleDesktop(scope: chat?.scope)
                : ClaudeAppRuntime.make(services: launcher.services, scope: chat?.scope, externalSessions: externalSessions, done: doneStores.claudeApp)
            #else
            desktop = ClaudeAppRuntime.make(services: launcher.services, scope: chat?.scope, externalSessions: externalSessions, done: doneStores.claudeApp)
            #endif
        }
        // 저장된 대화 (OA D3v-m): 목록과 같은 게이트 (새 Issues 화면 ∧ BridgeFlag ∧ 서비스 · 계정 경계). 읽기 전용이라 중계 게이트와 상관없다
        let savedChats = injectedSavedChats ?? SavedChatsRuntime.make(services: launcher.services, scope: chat?.scope, issueScreens: chat?.issues != nil)
        // 이어받기 "Resume here" (OA 외부 세션 PR2m): 목록과 같은 게이트 + 서버가 열었을 때만 (`ExternalSessionAttachModel.gate`)
        let attach = injectedAttach ?? ExternalSessionAttachRuntime.make(services: launcher.services, scope: chat?.scope, externalSessions: externalSessions, targets: chat?.targets)
        shell = EdgeShellModel(
            reduceMotion: Self.systemReduceMotion, pinStore: pinStore, contexts: chat?.contexts, review: review, summary: summary, chatsEnabled: chat != nil,
            windowsEnabled: windows, issues: chat?.issues, externalSessions: externalSessions, desktopSessions: desktop?.sessions,
            railDone: chat?.issues != nil ? doneStores.rail : nil, claudeAppOpened: desktop?.opened, desktopChat: desktop?.chat, savedChats: savedChats, attach: attach
        )
        // 세션 보기가 이 Mac에 두는 것(열어 본 시각 저장본 · 일 목록 판)은 계정과 함께 간다 (보안 P3-1): 로그인이 바뀔 때 셸이, 계정이 기기를 떠날 때(로그아웃 · 세션 만료 · 계정 삭제) 계정 경계가 비운다
        let backgroundSessions = BackgroundTaskAccount(openStore: doneStores.backgroundOpen, board: chat?.backgroundBoard ?? .shared)
        shell.backgroundSessions = backgroundSessions
        chat?.scope.onLeft {
            backgroundSessions.leave()
            SessionMarkdownCache.shared.removeAll()
        }
        rail = EdgeRailPanelController(shell: shell)
        panel = EdgePanelController(shell: shell, chat: chat)
        claudePanel = shell.desktop != nil ? EdgeClaudeAppPanelController(shell: shell, backgroundOpen: doneStores.backgroundOpen) : nil
        codexPanel = shell.externalSessions != nil ? EdgeClaudeAppPanelController(shell: shell, backgroundOpen: doneStores.backgroundOpen, isCodex: true) : nil
        savedChatPanel = shell.savedChats != nil ? EdgeSavedChatPanelController(shell: shell) : nil
        // 새 Issues 화면이 켜진 구성만 세션 패널 창이 있다 (꺼지면 창도 읽기도 없다)
        if let chat, chat.issues != nil {
            sessionPanel = EdgeSessionPanelController(shell: shell, runtime: chat)
        } else {
            sessionPanel = nil
        }
        if windows, let chat {
            assistant = AssistantWindowManager(
                runtime: chat, shell: shell, store: positionStore ?? Self.defaultPositionStore(),
                environment: .live(panel: panel, shell: shell, sessionPanel: sessionPanel), reduceMotion: { Self.systemReduceMotion }
            )
        } else {
            assistant = nil
        }
        super.init()
        // Settings › Shortcuts가 이 셸이 듣는 키만 보인다
        SettingsWindowModel.shared.panelKeysShell = shell
        panel.panel.delegate = self
        sessionPanel?.panel.delegate = self
        // 메인 패널이 세로 가운데로 움직이는 동안에도 세션 패널은 그 패널이 닿을 자리의 왼쪽 · 위 맞춤에 선다
        sessionPanel?.issuePanelFrame = { [weak panel] in panel.flatMap { $0.isVisible ? $0.targetFrame() : nil } }
        // 레일이 여는 패널은 레일 전체의 세로 가운데에 선다 (OA PR-D2): 레일 창의 실제 자리에서 잰다
        panel.railCenterY = { [weak rail] in rail?.centerLineY }
        claudePanel?.panel.delegate = self
        codexPanel?.panel.delegate = self
        // 데스크톱 링으로 연 Claude 세션 패널도 레일 전체의 세로 가운데에 선다 (사용자 결정 2026-10-22)
        claudePanel?.railCenterY = { [weak rail] in rail?.centerLineY }
        // Sessions 왼쪽에 설 때의 기준은 메인 패널이 닿을 자리다 (여는 움직임 중에 밀리지 않게)
        claudePanel?.mainPanelFrame = { [weak panel] in panel.flatMap { $0.isVisible ? $0.targetFrame() : nil } }
        codexPanel?.mainPanelFrame = { [weak panel] in panel.flatMap { $0.isVisible ? $0.targetFrame() : nil } }
        // 저장된 대화 읽기 패널도 Sessions가 닿을 자리의 왼쪽에 선다 (OA D3v-m). Settings › Account의 Saved chats도 같은 저장소를 읽는다
        savedChatPanel?.panel.delegate = self
        savedChatPanel?.mainPanelFrame = { [weak panel] in panel.flatMap { $0.isVisible ? $0.targetFrame() : nil } }
        SettingsWindowModel.shared.savedChats = shell.savedChats
        shell.onConnect = { [weak self] in self?.rail.onConnections() }
        if let assistant {
            shell.onChats = { [weak assistant] in assistant?.showChats() }
            shell.onNewWindow = { [weak assistant] in assistant?.openNewWindow() }
            assistant.onOpenConnections = { [weak self] in self?.rail.onConnections() }
        } else if let chat {
            shell.onChatsOpened = { chat.chat.openChats() }
            shell.onNewChat = { _ = chat.chat.newChat() }
            shell.onChatEscape = { chat.chat.escapeInner() }
        }
        // Try again은 읽는 중이어도 새로 읽는다 (읽기가 취소돼 "읽는 중"이 남아도 버튼이 무반응이 되지 않게)
        shell.onRetry = { [weak self] in self?.load(.retry) }
        wireIssues()
        wireQuestions()
    }

    /// 새 Issues 화면(OA U2)의 동작: Ask 알약 · New session `+`. 앞 Assistant 창이 있으면 그 창에 칩을 더하고, 없으면 새 창 (창이 없는 구성에서는 아무 일도 없다)
    private func wireIssues() {
        guard shell.issueScreensEnabled else { return }
        shell.onAsk = { [weak self] item in self?.assistant?.ask(about: item) }
        shell.onNewSession = { [weak self] scope in self?.assistant?.openNewSession(scope: scope) }
        // 세션 패널의 대화: id로 직접 읽고(History 100개 목록에 기대지 않는다), 보이는 동안은 온라인 복귀 · 목록 새로 읽기의 공통 갱신 집합에 든다
        if let chat {
            let store = chat.chat
            shell.onLoadSessionConversation = { [weak store] id in store?.loadConversation(id) }
            store.panelConversations = { [weak shell] in
                guard let shell, shell.sessionPanelShown, let id = shell.openSessionItem?.conversationID else { return [] }
                return [id]
            }
        }
    }

    /// 창 위치를 기억할 곳: 앱 설정 도메인. 견본(`-TFSampleData`)은 메모리뿐이다 (격리 실행도 설정 도메인을 만들지 않는다)
    private static func defaultPositionStore() -> AssistantWindowPositionStore {
        #if DEBUG
        if SampleData.isEnabled { return AssistantWindowPositionStore(defaults: nil) }
        #endif
        return AssistantWindowPositionStore(defaults: .standard)
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
        assistant?.start()
        // 계정이 떠나면(로그아웃 · 만료 · 계정 삭제 · 전환) 이 Mac의 고정을 모두 지운다 (이 기기 저장본 `SavedNowStore`와 같은 정리)
        Self.removePinsWhenAccountLeaves(launcher.session, store: pinStore)
        followWork()
        followPanel()
        followSessionPanel()
        followClaudePanel()
        followCodexPanel()
        followSavedChatPanel()
        followDesktop()
        followIssues()
        followTaskforce()
        followSync()
        followSyncFinished()
        // 시작할 때 세션은 아직 읽는 중이다: 로그인이 확인되면 그때 목록 · run을 읽는다 (런처는 열 때마다 읽는다)
        followSession()
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.shell.reduceMotion = Self.systemReduceMotion }
        })
        // 잠자기: 자는 동안 세션 5초 읽기가 멈추고 깨면 한 번 읽는다 (OA U2-35)
        if let sessions = shell.issues?.sessions {
            let center = NSWorkspace.shared.notificationCenter
            observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { sessions.setAsleep(true) }
            })
            observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    sessions.setAsleep(false)
                    // 깨면 Taskforce 요청도 한 번 읽는다 (잔 사이 다른 기기에서 바뀌었을 수 있다, OA U3-20)
                    self?.shell.taskforceWoke()
                }
            })
        }
        // 종료가 정해지면 데스크톱 세션과 대화하는 중계 `claude`를 끝낸다 (OA PR-D3, 최대 2초. 대화를 쓰지 않은 실행 · 게이트가 꺼진 빌드는 할 일이 없다)
        if let chat = shell.desktopChat {
            observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                chat.stopRelayForQuit()
            })
        }
        // 해상도 · 화면 구성이 바뀌면 레일을 다시 화면 모서리에 붙이고, 열린 패널도 그 옆으로
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rail.show()
                self?.panel.fitToContent()
            }
        })
        // 자정 · 시간대 변경 · 시계 조정 · 깨어남을 열린 채 지나도 All work의 "오늘"(지난 Done today · Today 표기)을 다시 계산한다 (`start`가 겹쳐 불려도 구독은 하나)
        let timeWatcher = timeWatcher ?? EdgeTimeWatcher { [weak shell] in shell?.timeChanged() }
        self.timeWatcher = timeWatcher
        timeWatcher.start()
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
        if signedIn, !wasSignedIn {
            load()
            // 로그인이 확인됐을 때 Chats가 열려 있으면 그 계정의 대화를 읽는다 (패널을 다시 열 때마다도 읽는다)
            if shell.panelOpen, shell.view == .chats { chat?.chat.openChats() }
        }
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

    /// 목록 · run을 읽는 까닭
    enum LoadReason {
        /// 로그인 · 패널 열기: 이미 읽는 중이면 겹쳐 부르지 않는다 (그 응답이 곧 온다)
        case refresh
        /// 사용자가 누른 Try again: 늘 새로 읽는다
        case retry
    }

    /// 목록(`/now`)을 새로 읽을지
    static func readsList(_ reason: LoadReason, isLoading: Bool) -> Bool {
        reason == .retry || !isLoading
    }

    private func load(_ reason: LoadReason = .refresh) {
        guard launcher.isSignedIn else { return }
        // 범위 멤버십도 같이 읽는다 (RLS 두 번, 서버 쓰기 없음). 마지막에 시작한 읽기만 반영된다
        if let contexts = chat?.contexts { Task { await contexts.refresh() } }
        // 복귀 요약(C3)도 같이 읽는다 (서버 읽기 한 번, 읽음 처리 없음). 마지막에 시작한 읽기만 반영된다. C3가 꺼져 있으면 읽지 않는다
        if let summary = shell.summary { Task { await summary.refresh() } }
        // 새 Issues 화면(OA U2): 화면을 열 때 · 로그인 · Try again마다 세션도 다시 읽는다 (RLS select 다섯, 쓰기 없음)
        if let issues = shell.issues { Task { await issues.sessions.refresh() } }
        // Taskforce 대화(OA U3): 로그인 · 패널 열기 · Try again마다 v2 Review를 읽는다. 정해진 주기 읽기는 없다 (이 GET은 제안 노출 표시를 한다)
        if shell.taskforceEnabled { shell.refreshTaskforce() }
        if let now = launcher.now, Self.readsList(reason, isLoading: now.refresh.isLoading) { Task { await now.load() } }
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
        if work != shell.work {
            shell.update(work)
            // 새 Issues 화면(OA U2): `actions` 변경 신호에 세션도 다시 읽고, 새 이슈의 번호를 한 번에 읽는다
            if let issues = shell.issues {
                let ids = work.review.map(\.id) + work.open.map(\.id) + work.doneToday.map(\.id)
                Task {
                    await issues.numbers.ensure(ids)
                    await issues.sessions.refresh()
                }
            }
        }
        // 포인터 아래 칸이 사라지면 툴팁도 내린다
        if shell.tooltip == nil { rail.hideTooltip() }
    }

    // MARK: 패널

    /// (시험이 직접 부른다: `start()`는 레일 창 · 알림 구독까지 올린다)
    func followPanel() {
        let (open, mainWanted) = withObservationTracking {
            _ = panel.presentation.bodyHeight
            _ = panel.presentation.footerHeight
            // 레일 옆 한 패널(`.claudeApp`, Claude 세션 보기)이 열려 있으면 메인 패널 창은 뜨지 않는다
            return (shell.panelOpen, shell.view != .claudeApp)
        } onChange: { [weak self] in
            Task { @MainActor in self?.followPanel() }
        }
        if open, mainWanted {
            if panel.presentation.shown, panel.isVisible {
                panel.fitToContent()
            } else if panel.show() {
                rail.hideTooltip()
                installMonitors()
                load()
            }
        } else if open {
            // Claude 세션 보기 하나만: 메인 패널 창을 내리고 키 · 클릭 모니터는 그대로 둔다 (Esc · 바깥 클릭이 이 창에서도 같게 닿는다)
            if panel.presentation.shown || panel.isVisible {
                panel.hide()
                sessionPanel?.hide()
            }
            if !hasMonitors {
                rail.hideTooltip()
                installMonitors()
                load()
            }
        } else if panel.presentation.shown || hasMonitors {
            panel.hide()
            sessionPanel?.hide()
            claudePanel?.hide()
            codexPanel?.hide()
            removeMonitors()
        }
    }

    func followCodexPanel() {
        guard let codexPanel else { return }
        let wanted = withObservationTracking {
            _ = codexPanel.presentation.contentHeight
            _ = codexPanel.presentation.pane.windowExtra
            _ = codexPanel.presentation.pane.hasAgentTree
            _ = panel.presentation.bodyHeight
            _ = panel.presentation.footerHeight
            _ = panel.presentation.shown
            return shell.codexPanelShown
        } onChange: { [weak self] in
            Task { @MainActor in self?.followCodexPanel() }
        }
        if wanted {
            if codexPanel.presentation.shown, codexPanel.isVisible { codexPanel.fit() }
            else { codexPanel.show() }
        } else if codexPanel.presentation.shown { codexPanel.hide() }
    }

    /// Claude 세션 보기 창 (OA PR-D2): 열어 둔 세션이 보일 때만 뜬다. Sessions 옆이면 메인 패널 왼쪽, 레일 옆 한 패널이면 메인 패널 자리. 높이 · 메인 패널 자리가 바뀌면 위를 맞춘 채 맞춘다
    func followClaudePanel() {
        guard let claudePanel else { return }
        let wanted = withObservationTracking {
            _ = claudePanel.presentation.contentHeight
            _ = claudePanel.presentation.pane.windowExtra
            _ = claudePanel.presentation.pane.hasAgentTree
            _ = panel.presentation.bodyHeight
            _ = panel.presentation.footerHeight
            _ = panel.presentation.shown
            _ = shell.view
            return shell.desktopPanelShown
        } onChange: { [weak self] in
            Task { @MainActor in self?.followClaudePanel() }
        }
        if wanted {
            if claudePanel.presentation.shown, claudePanel.isVisible {
                claudePanel.fit()
            } else {
                claudePanel.show()
            }
        } else if claudePanel.presentation.shown {
            claudePanel.hide()
        }
    }

    /// 저장된 대화 읽기 패널 창 (OA D3v-m): Sessions가 열려 있고 열어 둔 대화가 있을 때만 보인다. 높이 · Sessions 자리가 바뀌면 위를 맞춘 채 맞춘다
    func followSavedChatPanel() {
        guard let savedChatPanel else { return }
        let wanted = withObservationTracking {
            _ = savedChatPanel.presentation.contentHeight
            _ = panel.presentation.bodyHeight
            _ = panel.presentation.footerHeight
            _ = panel.presentation.shown
            _ = shell.view
            return shell.savedChatPanelShown
        } onChange: { [weak self] in
            Task { @MainActor in self?.followSavedChatPanel() }
        }
        if wanted {
            if savedChatPanel.presentation.shown, savedChatPanel.isVisible {
                savedChatPanel.fit()
            } else {
                savedChatPanel.show()
            }
        } else if savedChatPanel.presentation.shown {
            savedChatPanel.hide()
        }
    }

    /// 데스크톱 세션 (OA PR-D2): 목록이 보이는 동안만 등록 폴더를 1초마다 읽는다 (보이지 않으면 멈춘다). 세션 상태나 이 Mac 목록(제목)이 바뀌면 레일의 링을 다시 정한다
    func followDesktop() {
        guard let desktop = shell.desktop else { return }
        let visible = withObservationTracking {
            _ = desktop.rail
            _ = desktop.sessions
            _ = shell.externalSessions?.rows
            return shell.externalSessionsVisible
        } onChange: { [weak self] in
            Task { @MainActor in self?.followDesktop() }
        }
        if visible { desktop.start() } else { desktop.stop() }
        shell.desktopChanged()
    }

    /// 세션 패널 창: 이슈 패널이 이슈 상세로 열려 있고 세션 패널이 열려 있을 때만 보인다. 높이 · 이슈 패널 자리가 바뀌면 위를 맞춘 채 맞춘다
    private func followSessionPanel() {
        guard let sessionPanel else { return }
        let wanted = withObservationTracking {
            _ = sessionPanel.presentation.contentHeight
            _ = sessionPanel.presentation.pane.windowExtra
            _ = sessionPanel.presentation.pane.hasAgentTree
            _ = panel.presentation.bodyHeight
            _ = panel.presentation.footerHeight
            return shell.sessionPanelShown
        } onChange: { [weak self] in
            Task { @MainActor in self?.followSessionPanel() }
        }
        if wanted {
            if sessionPanel.presentation.shown, sessionPanel.isVisible {
                sessionPanel.fit()
            } else if panel.isVisible {
                sessionPanel.show()
            }
        } else if sessionPanel.presentation.shown {
            sessionPanel.hide()
        }
    }

    /// 새 Issues 화면(OA U2): 세션 · 번호 · 프로젝트가 바뀌면 레일의 링 · 열어 둔 화면을 다시 맞춘다
    private func followIssues() {
        guard let issues = shell.issues else { return }
        withObservationTracking {
            _ = issues.sessions.items
            _ = issues.numbers.numbers
            _ = shell.contexts?.hasRead
            _ = shell.contexts?.contexts
        } onChange: { [weak self] in
            Task { @MainActor in self?.followIssues() }
        }
        shell.sessionsChanged()
    }

    /// Taskforce 대화(OA U3): v2 응답 · 충돌 상세 · 답 기록이 바뀌면 보던 요청을 맞추고(보던 것이 빠지면 그 뒤를 이은 요청) 기준점을 확인한다. 읽기는 하지 않는다
    private func followTaskforce() {
        guard let store = shell.taskforceStore else { return }
        withObservationTracking {
            _ = store.readSerial
            _ = store.response
            _ = store.conflicts
            _ = store.answers
        } onChange: { [weak self] in
            Task { @MainActor in self?.followTaskforce() }
        }
        shell.taskforceChanged()
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

    var hasMonitors: Bool { !clickMonitors.isEmpty || keyMonitor != nil }

    private func installMonitors() {
        guard !hasMonitors else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // 다른 앱을 누름 (전역 마우스 모니터는 손쉬운 사용 권한이 필요 없다)
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.externalInteraction() }
        }) {
            clickMonitors.append(global)
        }
        // 이 앱의 다른 창을 누름 (레일 · 툴팁은 빼고)
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Assistant 창(과 그 대상 메뉴)을 누르는 것은 패널 밖 클릭이 아니다: 창과 패널이 함께 보인다
                if event.window !== self.panel.panel, event.window !== self.rail.panel, !self.ownsAssistantWindow(event.window), !self.ownsIssueWindow(event.window) {
                    self.externalInteraction()
                }
            }
            return event
        }) {
            clickMonitors.append(local)
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                // 키 창은 마지막으로 누른 패널 하나다: 이슈 패널 · 세션 패널 · Claude 세션 패널이 키일 때만 (그 밖의 창으로 온 키는 지나간다)
                guard let self, event.window === self.panel.panel || event.window === self.sessionPanel?.panel || event.window === self.claudePanel?.panel || event.window === self.codexPanel?.panel
                    || event.window === self.savedChatPanel?.panel else { return false }
                return self.handleKey(event)
            }
            return handled ? nil : event
        }
    }

    /// 패널 밖(다른 앱 · 이 앱의 다른 창)을 눌렀거나 키를 잃었다: 패널을 접는다 (무인 실행의 `ignoresExternalDismissal`이 아니면)
    func externalInteraction() {
        #if DEBUG
        if ignoresExternalDismissal { return }
        #endif
        shell.dismiss()
    }

    private func removeMonitors() {
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors = []
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// 패널의 키: Esc 접기 · ⌘1 가장 새 Review(S4) · ⌘2 All work · ⌘3 Chats(노치 레일만) · ⌘4 Sessions · ⌘N New chat (⌘2 · ⌘4는 이미 열려 있으면 닫는다: 토글), 그리고 Review 페이지가 보일 때 ← → 단계 · 1 · 2 답 (S4, 텍스트 편집 밖에서만).
    /// 처리했으면 true
    func handleKey(_ event: NSEvent) -> Bool {
        // 질문 카드가 Esc를 먼저 본다 (열린 Other 칸 · 보류 중인 답): OA D4b-m-1
        if handleQuestionKey(event) { return true }
        guard let command = EdgeKeyCommand.of(keyCode: Int(event.keyCode), flags: event.modifierFlags) else { return handleReviewKey(event) }
        // Chats가 없는 셸(Release)의 ⌘3 · ⌘N은 연결이 없다: 지나간다
        guard shell.listens(to: command) else { return false }
        switch command {
        case .escape:
            // 안쪽 것(열린 필터 카드 · Chats의 대화 목록)을 먼저 닫고, 그다음 패널을 접는다
            shell.escape()
        case .review:
            // S4 gate가 꺼져 있으면 이 키는 연결이 없다: 지금처럼 지나간다. ⌘1도 텍스트 편집(입력칸 · IME 조합) · 메뉴 · 시트 밖에서만 듣는다 (⌘2 · ⌘3 · ⌘N은 그대로).
            // Taskforce 대화가 켜진 구성은 늘 대화를 연다: 서버 순서 첫 요청 (OA U3-40)
            guard reviewKeysAllowed else { return false }
            shell.openNewestReview()
        case .allWork:
            // 그 패널이 이미 열려 있으면 닫는다 (계약 24장 토글: 레일 버튼과 같다)
            shell.toggleAllWork()
        case .chats:
            shell.openChats()
        case .sessions:
            shell.toggleSessions()
        case .newChat:
            shell.newChat()
        }
        return true
    }

    /// Review 키(⌘1 · ← → · 1 · 2)를 받아도 되는가: S4가 켜져 있고, 메뉴 · 시트가 떠 있지 않고, 글을 편집하는 중(입력칸 · 검색 · IME 조합)이 아닐 때
    private var reviewKeysAllowed: Bool {
        shell.review != nil && !shell.menuOpen && panel.panel.attachedSheet == nil && !EdgeReviewKeys.isTextEditing(panel.panel.firstResponder)
    }

    /// Review 페이지의 키 (S4): ← → 단계, 1 · 2 답. 텍스트를 편집하는 중이거나(Chats 입력칸 · 검색 · IME 조합) 시트 · 메뉴가 떠 있으면 지나간다.
    /// 번호 키는 사용자가 지금 본 항목의 id에만 간다. 누르고 있어 반복된 키는 먹기만 하고 다시 보내지 않는다 (한 번의 선택은 한 번의 요청)
    private func handleReviewKey(_ event: NSEvent) -> Bool {
        guard reviewKeysAllowed, shell.view == .review, shell.panelOpen,
              let key = EdgeReviewKeys.of(keyCode: Int(event.keyCode), characters: event.characters, flags: event.modifierFlags) else { return false }
        switch key {
        case .previous:
            shell.stepReview(-1)
        case .next:
            shell.stepReview(1)
        case .answer(let answer):
            if shell.taskforceEnabled { return shell.taskforceAnswerKey(answer, repeated: event.isARepeat) }
            if !event.isARepeat, let id = shell.shownReview?.id { shell.answer(answer, for: id) }
        }
        return true
    }


    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // ⌘Tab 등으로 키를 잃으면 접는다 (More 메뉴를 연 동안은 빼고)
        guard shell.panelOpen, !shell.menuOpen else { return }
        guard assistant != nil || sessionPanel != nil || claudePanel != nil || codexPanel != nil || savedChatPanel != nil else {
            externalInteraction()
            return
        }
        // 키가 이 앱의 Assistant 창 · 세션 패널 · 이슈 패널로 옮겨 가는 것은 패널을 잃은 것이 아니다: 한 틱 뒤 새 키 창을 보고 정한다
        Task { @MainActor [weak self] in
            guard let self, self.shell.panelOpen, !self.shell.menuOpen else { return }
            let key = self.keyWindow()
            guard !self.ownsAssistantWindow(key), !self.ownsIssueWindow(key) else { return }
            self.externalInteraction()
        }
    }

    private func ownsAssistantWindow(_ window: NSWindow?) -> Bool {
        assistant?.owns(window) ?? false
    }

    /// 이슈 패널 · 세션 패널 · Claude 세션 패널 · 저장된 대화 패널 · 그 메뉴 창 (OA U2-47): 서로를 눌러도 다른 쪽이 접히지 않는다. 바깥 클릭은 함께 접는다
    private func ownsIssueWindow(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window === panel.panel || window === sessionPanel?.panel || window === claudePanel?.panel || window === codexPanel?.panel || window === savedChatPanel?.panel || window === menu.window
    }
}

/// 패널이 키를 가졌을 때 듣는 키 (디자인 Focus and keys): Esc · ⌘1(S4) · ⌘2 · ⌘3 · ⌘4 Sessions(OA PR-D2) · ⌘N. 이 밖의 키는 지나간다.
/// Assistant 창도 같은 목록을 읽는다 (`AssistantWindowManager.KeyIntent`): ⌘4는 어느 창이 키 창이어도 Sessions를 연다 (Sessions 버튼이 있는 셸만)
/// (Review 페이지의 ← → · 1 · 2는 텍스트 편집 상태를 봐야 해서 `EdgeReviewKeys`가 따로 듣는다)
enum EdgeKeyCommand: Equatable {
    case escape, review, allWork, chats, sessions, newChat

    static func of(keyCode: Int, flags: NSEvent.ModifierFlags) -> EdgeKeyCommand? {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        switch keyCode {
        case kVK_Escape: return .escape
        case kVK_ANSI_1 where flags == .command: return .review
        case kVK_ANSI_2 where flags == .command: return .allWork
        case kVK_ANSI_3 where flags == .command: return .chats
        case kVK_ANSI_4 where flags == .command: return .sessions
        case kVK_ANSI_N where flags == .command: return .newChat
        default: return nil
        }
    }
}

/// 로컬 날짜 · 시간대 · 시스템 시계가 바뀌거나 Mac이 깨어나면 알린다 (All work의 "오늘"이 바뀌었을 수 있다: 열린 채 기다리는 패널의 지난 Done today · Today 표기).
/// 알리기만 한다: 서버 호출 · 목록 읽기 · 폴링 · 타이머가 없다. 구독은 `start`로 한 번만 걸리고(겹쳐 불려도 한 번), `stop` · 해제 때 모두 걷힌다.
/// 알림 센터 · 큐 · 시간대 캐시 비우기는 시험이 가짜로 바꾼다 (실제 시스템 시계 · 시간대는 바꾸지 않는다)
@MainActor
final class EdgeTimeWatcher {
    private let center: NotificationCenter
    private let workspaceCenter: NotificationCenter
    private let queue: OperationQueue?
    private let resetTimeZone: () -> Void
    private let onChange: @MainActor () -> Void
    private var registrations: Registrations?

    var isWatching: Bool { registrations != nil }

    /// - center: 날짜 · 시간대 · 시계 알림이 오는 곳 (앱은 `.default`)
    /// - workspaceCenter: 깨어남 알림이 오는 곳 (앱은 `NSWorkspace.shared.notificationCenter`)
    /// - resetTimeZone: 시간대가 바뀌면 알리기 전에 먼저 부른다. Foundation이 캐시한 시스템 시간대(`Calendar.current`가 쓴다)를 비워, 알림을 받은 쪽이 새 시간대로 읽게 한다
    init(
        center: NotificationCenter = .default, workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        queue: OperationQueue? = .main, resetTimeZone: @escaping () -> Void = { NSTimeZone.resetSystemTimeZone() },
        onChange: @escaping @MainActor () -> Void
    ) {
        self.center = center
        self.workspaceCenter = workspaceCenter
        self.queue = queue
        self.resetTimeZone = resetTimeZone
        self.onChange = onChange
    }

    func start() {
        guard registrations == nil else { return }
        let registrations = Registrations()
        func observe(_ center: NotificationCenter, _ name: Notification.Name, resetsTimeZone: Bool = false) {
            let token = center.addObserver(forName: name, object: nil, queue: queue) { [weak self] _ in
                MainActor.assumeIsolated { self?.changed(resetsTimeZone: resetsTimeZone) }
            }
            registrations.add(center, token)
        }
        observe(center, .NSCalendarDayChanged)
        observe(center, .NSSystemTimeZoneDidChange, resetsTimeZone: true)
        observe(center, .NSSystemClockDidChange)
        observe(workspaceCenter, NSWorkspace.didWakeNotification)
        self.registrations = registrations
    }

    func stop() {
        registrations?.removeAll()
        registrations = nil
    }

    private func changed(resetsTimeZone: Bool) {
        if resetsTimeZone { resetTimeZone() }
        onChange()
    }

    /// 건 구독들: 비우거나 해제되면 알림 센터에서 걷는다 (해제는 격리 밖에서 불리므로 격리가 없는 작은 객체가 맡는다)
    private final class Registrations: @unchecked Sendable {
        private var entries: [(center: NotificationCenter, token: NSObjectProtocol)] = []

        func add(_ center: NotificationCenter, _ token: NSObjectProtocol) {
            entries.append((center, token))
        }

        func removeAll() {
            for entry in entries { entry.center.removeObserver(entry.token) }
            entries = []
        }

        deinit { removeAll() }
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
