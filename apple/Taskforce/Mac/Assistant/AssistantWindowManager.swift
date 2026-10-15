#if os(macOS)
import AppKit
import Carbon.HIToolbox
import Observation
import TaskforceKit
import TaskforceUI

/// Assistant 창들 (OA U1): 여러 개 동시에, 창 하나 = 대화 하나, 최대 8개. 레일 Chats(⌘3)는 가장 앞 창을 앞으로 가져오고(없으면 연다), ⌘N은 새 창을 연다.
/// 어느 창이 어느 대화를 보이는지 · 상한 · 위치 기억은 Kit의 순수 규칙(`AssistantWindowRegistry` · `AssistantWindowGeometry` · `AssistantWindowPositions`)이 정하고,
/// 이 관리자는 그 결정을 AppKit 창에 옮긴다.
/// - 창은 스스로 키 창이 되지 않는다: 클릭 · ⌘3 · ⌘N에서만. 키 창(이 창 또는 패널)만 키를 받는다
/// - Esc(키 창일 때)는 숨긴다 (초안 · 칩 · 위치 유지, 일은 멈추지 않는다). ⌘W는 닫는다 (대화는 Chat history에 남는다). 바깥 클릭으로는 사라지지 않는다
/// - 열린 패널을 눌러도 접히지 않고 창을 눌러도 패널이 접히지 않는다: 둘이 함께 보인다 (컨트롤러가 이 관리자의 창을 "밖"으로 치지 않는다)
@MainActor
final class AssistantWindowManager {
    /// 화면 · 패널 · 레일의 자리 (시험은 고정된 값을 넣는다)
    struct Environment {
        var visibleFrame: @MainActor () -> CGRect
        /// 펼친 레일의 자리 (화면 좌표): 위 가장자리와 왼쪽 가장자리만 쓴다
        var railFrame: @MainActor () -> CGRect
        /// 열려 있는 패널의 창 (없으면 nil)
        var panelFrame: @MainActor () -> CGRect?
        /// 위치를 기억하는 화면의 키
        var display: @MainActor () -> String
        var railWidth: CGFloat = EdgeRailLayout.railWidth
        /// 레일 화면(`visibleFrame` · `display`)이 아닌 다른 화면들 (창은 자기가 있는 화면 기준으로 저장 · 배치된다). 시험은 두 화면 모형을 넣는다
        var extraScreens: @MainActor () -> [AssistantScreen] = { [] }

        /// 레일이 붙는 화면
        @MainActor var railScreen: AssistantScreen { AssistantScreen(id: display(), visible: visibleFrame()) }

        /// 이 자리의 창이 있는 화면 (가장 많이 덮는 화면, 어디에도 없으면 가장 가까운 화면)
        @MainActor func screen(for frame: CGRect) -> AssistantScreen {
            AssistantWindowGeometry.screen(containing: frame, in: [railScreen] + extraScreens(), fallback: railScreen)
        }

        /// 화면 키로 찾는다 (기억한 위치를 읽은 화면)
        @MainActor func screen(id: String) -> AssistantScreen? {
            ([railScreen] + extraScreens()).first { $0.id == id }
        }

        /// 레일은 주 화면(레일 화면)에만 있다: 다른 화면은 오른쪽 끝까지 쓴다
        @MainActor func reservedRailWidth(on screen: AssistantScreen) -> CGFloat {
            screen.id == display() ? railWidth : 0
        }

        /// 실제 화면: 레일이 붙는 화면, 열린 패널의 창. 패널의 자리는 **열린 패널들의 합**이다: 이슈 패널 창(SessionTab 띠 포함)과 세션 패널 (OA U2-44)
        static func live(panel: EdgePanelController, shell: EdgeShellModel, sessionPanel: EdgeSessionPanelController? = nil) -> Environment {
            Environment(
                visibleFrame: { (EdgeRailPanelController.screen ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 875) },
                railFrame: {
                    guard let screen = EdgeRailPanelController.screen ?? NSScreen.main else { return CGRect(x: 1396, y: 400, width: 44, height: 320) }
                    let top = EdgeRailPanelController.railTop(on: screen)
                    let height = EdgeRailLayout.windowHeight(plus: shell.issueScreensEnabled) - 2 * EdgeRailLayout.fillet
                    return CGRect(x: screen.frame.maxX - EdgeRailLayout.railWidth, y: top - height, width: EdgeRailLayout.railWidth, height: height)
                },
                panelFrame: {
                    guard shell.panelOpen, panel.isVisible else { return nil }
                    let frames = [panel.panel.frame] + ((sessionPanel?.isVisible ?? false) ? [sessionPanel?.panel.frame].compactMap { $0 } : [])
                    return AssistantWindowGeometry.panelsFrame(frames)
                },
                display: { Self.displayKey(EdgeRailPanelController.screen ?? NSScreen.main) },
                extraScreens: {
                    let rail = EdgeRailPanelController.screen ?? NSScreen.main
                    return NSScreen.screens.filter { $0 !== rail }.map { AssistantScreen(id: Self.displayKey($0), visible: $0.visibleFrame) }
                }
            )
        }

        @MainActor
        static func displayKey(_ screen: NSScreen?) -> String {
            let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return number.map { String($0.uint32Value) } ?? "main"
        }
    }

    let runtime: ChatRuntime
    let shell: EdgeShellModel
    private let store: AssistantWindowPositionStore
    private let environment: Environment
    private let reduceMotion: () -> Bool
    private(set) var registry = AssistantWindowRegistry()
    private(set) var controllers: [UUID: AssistantWindowController] = [:]
    private var positions: AssistantWindowPositions
    private var keyMonitor: Any?
    private var following = false
    /// 창을 실제 화면에 올리는가 (시험은 끈다)
    var presents = true
    var onOpenConnections: () -> Void = {}

    init(
        runtime: ChatRuntime, shell: EdgeShellModel, store: AssistantWindowPositionStore, environment: Environment, reduceMotion: @escaping () -> Bool = { false }
    ) {
        self.runtime = runtime
        self.shell = shell
        self.store = store
        self.environment = environment
        self.reduceMotion = reduceMotion
        positions = store.load()
        // ⌘3 · 온라인 복귀 · Try again의 목록 읽기가 공유 `currentID`뿐 아니라 창들이 보이는 대화도 다시 읽는다
        runtime.chat.viewedConversations = { [weak self] in self?.openConversations(except: nil) ?? [] }
    }

    /// 앱 시작 뒤 한 번: 열린 항목 따라가기 · 키 모니터 · 계정이 떠나면 창을 모두 닫는다
    func start() {
        guard !following else { return }
        following = true
        runtime.scope.onLeft { [weak self] in self?.closeAll() }
        followOpenItem()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return handled ? nil : event
        }
    }

    /// 키 모니터를 걷는다 (앱은 끝까지 두고, 시험이 정리한다)
    func stop() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        following = false
    }

    // MARK: 열기

    /// 레일 Chats · ⌘3: 앞 창을 앞으로, 앞 창이 없으면 가장 최근에 쓴 창을 다시 보이고, 창이 없으면 연다 (마지막 대화로, 없으면 새 대화)
    @discardableResult
    func showChats() -> UUID? {
        runtime.chat.refreshInBackground()
        Task { await runtime.targets.refresh() }
        if let id = registry.windowToBringForward {
            bringForward(id)
            return id
        }
        let chat = runtime.chat
        let restored = chat.lastConversationID
        let conversation = restored ?? chat.reserveNewChat(target: .taskforce, excluding: [])
        guard let id = openWindow(for: conversation) else { return nil }
        // 목록을 아직 읽기 전이었다면: 읽은 뒤에도 손대지 않은 새 창이면 마지막 대화로 되살린다 (패널 Chats가 하던 일)
        if restored == nil {
            Task { @MainActor [weak self] in
                await chat.refresh()
                guard let model = self?.controllers[id]?.model, model.isPristine, let last = chat.lastConversationID else { return }
                model.openConversation(last)
            }
        }
        return id
    }

    /// ⌘N: 새 창. 다른 창이 쥐지 않은 빈 대화가 있으면 그것을 다시 쓴다
    @discardableResult
    func openNewWindow() -> UUID? {
        let conversation = runtime.chat.reserveNewChat(target: .taskforce, excluding: openConversations(except: nil))
        return openWindow(for: conversation)
    }

    /// 대화를 보이는 창을 연다. 이미 보이는 창이 있으면 그 창을 앞으로, 상한이면 가장 오래 쓰지 않은 창을 앞으로 가져온다
    @discardableResult
    func openWindow(for conversationID: UUID) -> UUID? {
        let windowID = UUID()
        // 자리는 새 창을 등록하기 전에 정한다 (등록하면 새 창이 가장 앞 창이 되어 겹쳐 열 기준이 사라진다)
        let initial = initialPlacement(for: conversationID)
        switch registry.open(conversation: conversationID, windowID: windowID) {
        case .reused(let id), .atCapacity(let id):
            bringForward(id)
            return id
        case .opened(let id):
            let model = AssistantWindowModel(
                id: id, conversationID: conversationID, chat: runtime.chat, targets: runtime.targets,
                openElsewhere: { [weak self] in self?.openConversations(except: id) ?? [] },
                rebind: { [weak self] new in self?.rebind(id, to: new) ?? .rebound }
            )
            // 열 때 패널에 열린 항목이 있으면 그것이 auto 칩이다
            model.followOpenItem(shell.openItem.map(Self.chip(for:)))
            let controller = AssistantWindowController(
                model: model, runtime: runtime, topLeft: initial.topLeft, screenID: initial.screenID, environment: environment, reduceMotion: reduceMotion()
            )
            controller.presents = presents
            controller.onMoved = { [weak self] topLeft in self?.remember(topLeft, windowID: id) }
            controller.onBecameKey = { [weak self] in self?.registry.touch(id) }
            controller.onOpenConnections = { [weak self] in self?.onOpenConnections() }
            controllers[id] = controller
            closeTargetMenus(except: id)
            controller.show(makeKey: true)
            refreshFront()
            return id
        }
    }

    /// 창을 앞으로: 숨었으면 다시 보이고, 사용자가 부른 것이라 키 창이 된다
    func bringForward(_ windowID: UUID) {
        registry.touch(windowID)
        registry.setHidden(false, windowID)
        closeTargetMenus(except: windowID)
        controllers[windowID]?.show(makeKey: true)
        refreshFront()
    }

    /// 다른 창이 앞으로 오면 열려 있던 대상 메뉴는 닫는다 (남은 메뉴가 새 창의 Return을 가로채지 않게)
    private func closeTargetMenus(except windowID: UUID) {
        for (id, controller) in controllers where id != windowID { controller.closeTargetMenu() }
    }

    // MARK: 숨기기 · 닫기

    /// Esc: 숨긴다. 초안 · 칩 · 위치 · 일은 그대로, ⌘3이 다시 보인다
    func hide(_ windowID: UUID) {
        registry.setHidden(true, windowID)
        controllers[windowID]?.hide()
        refreshFront()
    }

    /// ⌘W: 닫는다. 대화는 Chat history에 남는다
    func close(_ windowID: UUID) {
        controllers[windowID]?.close()
        controllers[windowID] = nil
        registry.close(windowID)
        refreshFront()
    }

    /// 계정이 이 기기를 떠남: 창을 모두 닫고 위치 기억도 지운다 (대화 id는 그 계정의 것이다)
    func closeAll() {
        for controller in controllers.values { controller.close() }
        controllers = [:]
        registry = AssistantWindowRegistry()
        positions = AssistantWindowPositions()
        store.clear()
        refreshFront()
    }

    // MARK: 창 ↔ 셸

    /// 이 창이 우리 창(또는 그 대상 메뉴)인가: 패널 밖 클릭으로 세지 않는다
    func owns(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return controllers.values.contains { $0.panel === window || $0.targetMenu.window === window }
    }

    func windowID(for window: NSWindow?) -> UUID? {
        guard let window else { return nil }
        return controllers.first { $0.value.panel === window || $0.value.targetMenu.window === window }?.key
    }

    /// 앞 창이 있다 (레일 Chats 칸이 칠해진다). 보이는 창이 하나라도 있으면
    private func refreshFront() {
        shell.assistantWindowFront = registry.frontmost != nil
    }

    // MARK: 키

    /// Assistant 창이 키 창일 때 듣는 키
    enum KeyIntent: Equatable {
        case escape, close, review, allWork, chats, newChat

        /// Esc · ⌘W · ⌘1 · ⌘2 · ⌘3 · ⌘N. 그 밖의 키는 지나간다
        static func of(keyCode: Int, flags: NSEvent.ModifierFlags) -> KeyIntent? {
            let flags = flags.intersection(.deviceIndependentFlagsMask)
            if keyCode == kVK_ANSI_W { return flags == .command ? .close : nil }
            switch EdgeKeyCommand.of(keyCode: keyCode, flags: flags) {
            case .escape?: return .escape
            case .review?: return .review
            case .allWork?: return .allWork
            case .chats?: return .chats
            case .newChat?: return .newChat
            case nil: return nil
            }
        }
    }

    /// 키 창이 이 창이면 그 키를 처리한다: Esc(History → 숨김) · ⌘W 닫기 · ⌘1 Review · ⌘2 All work · ⌘3 Chats · ⌘N 새 창. 처리했으면 true
    func handleKey(_ event: NSEvent) -> Bool {
        guard let window = event.window, let id = windowID(for: window), let intent = KeyIntent.of(keyCode: Int(event.keyCode), flags: event.modifierFlags) else { return false }
        return perform(intent, in: id)
    }

    /// Esc가 하는 일의 차례: 대상 메뉴가 열려 있으면 메뉴만 닫고, IME 조합 중이면 조합을 취소하는 Esc라 지나가고,
    /// History 같은 안쪽 화면이면 대화로 돌아가고(`leaveInner`가 true), 그 밖에는 창을 숨긴다. 앞 단계가 처리하면 뒤 단계는 보지도 않는다
    enum EscapeStep: Equatable {
        case closeMenu, passThrough, leftInner, hide
    }

    nonisolated static func escapeStep(menuOpen: Bool, composing: Bool, leaveInner: () -> Bool) -> EscapeStep {
        if menuOpen { return .closeMenu }
        if composing { return .passThrough }
        if leaveInner() { return .leftInner }
        return .hide
    }

    /// IME 조합 중인 Esc는 조합을 취소하는 것이라 지나간다. 대상 메뉴가 열려 있으면 Esc는 메뉴만 닫는다
    func perform(_ intent: KeyIntent, in id: UUID) -> Bool {
        guard let controller = controllers[id] else { return false }
        switch intent {
        case .close:
            close(id)
        case .escape:
            let composing = (controller.panel.firstResponder as? NSTextView)?.hasMarkedText() == true
            switch Self.escapeStep(menuOpen: controller.targetMenu.isOpen, composing: composing, leaveInner: { controller.model.escapeInner() }) {
            case .closeMenu:
                controller.targetMenu.dismiss()
                return true
            case .passThrough:
                return false
            case .leftInner:
                return true
            case .hide:
                hide(id)
            }
        case .review:
            guard shell.review != nil else { return false }
            shell.openNewestReview()
        case .allWork:
            shell.openAllWork()
        case .chats:
            shell.openChats()
        case .newChat:
            shell.newChat()
        }
        return true
    }

    // MARK: 자리

    private func openConversations(except windowID: UUID?) -> Set<UUID> {
        Set(registry.windowIDs.filter { $0 != windowID }.compactMap { registry.conversationID(of: $0) })
    }

    /// 새 창의 왼쪽 위: 그 대화의 기억된 위치(이 화면), 없으면 앞 창에서 24pt 아래 · 왼쪽, 보이는 창이 없으면 첫 창의 자리 (열린 패널 12pt 왼쪽 · 없으면 레일 12pt 왼쪽).
    /// 기억한 위치는 그 위치를 읽은 화면(`screenID`)에 놓는다
    private func initialPlacement(for conversationID: UUID) -> (topLeft: CGPoint, screenID: String?) {
        // 기억은 앞 창이 있는 화면, 없으면 레일 화면에서 찾는다
        let displays = [registry.frontmost.flatMap { controllers[$0]?.currentScreenID }, environment.display()].compactMap { $0 }
        for display in displays {
            if let remembered = positions.position(conversation: conversationID, display: display) { return (remembered, display) }
        }
        if let front = registry.frontmost, let controller = controllers[front] {
            return (AssistantWindowGeometry.cascaded(from: controller.topLeft), nil)
        }
        return (AssistantWindowGeometry.firstTopLeft(panelFrame: environment.panelFrame(), railFrame: environment.railFrame()), nil)
    }

    private func remember(_ topLeft: CGPoint, windowID: UUID) {
        guard let conversation = registry.conversationID(of: windowID) else { return }
        // 그 창이 있는 화면의 키로 기억한다 (보조 화면의 창을 레일 화면 키로 저장하지 않는다)
        let display = controllers[windowID]?.currentScreenID ?? environment.display()
        positions.remember(topLeft, conversation: conversation, display: display)
        store.save(positions)
    }

    private func rebind(_ windowID: UUID, to conversationID: UUID) -> AssistantWindowRegistry.RebindOutcome {
        let outcome = registry.rebind(windowID, to: conversationID)
        switch outcome {
        case .showsElsewhere(let other):
            bringForward(other)
        case .rebound:
            // 그 대화의 저장 위치가 있으면 그리로 간다 (History로 대화를 바꾸면 위치도 그 대화의 것이다)
            // 저장 위치를 읽은 화면(이 창이 있는 화면)에 놓는다: 앞 대화의 높이로 다른 화면을 고르지 않는다
            if let controller = controllers[windowID] {
                let display = controller.currentScreenID
                if let remembered = positions.position(conversation: conversationID, display: display) {
                    controller.place(topLeft: remembered, onScreen: display)
                }
            }
        }
        return outcome
    }

    // MARK: 열린 항목 (auto 칩)

    nonisolated static func chip(for item: (id: UUID, title: String)) -> AssistantChip {
        AssistantChip(kind: .action, itemID: item.id, origin: .auto, title: item.title)
    }

    /// 패널에서 열린 항목의 auto 칩: 종류(이슈 · 프로젝트 · 세션)와 이슈 번호를 싣는다 (OA U2-45)
    nonisolated static func chip(for item: AssistantOpenItem) -> AssistantChip {
        AssistantChip(open: item)
    }

    // MARK: Ask · New session (OA U2)

    /// Ask 알약: 앞 Assistant 창에 그 항목의 칩을 더한다. 앞 창이 없으면 숨은 가장 최근 창을 앞으로, 창이 하나도 없으면 새 창을 연다
    @discardableResult
    func ask(about item: AssistantOpenItem) -> UUID? {
        guard let id = registry.frontmost ?? showChats() else { return nil }
        controllers[id]?.model.addChip(AssistantChip(open: item))
        return id
    }

    /// New session `+`: 새 Assistant 창을 열고 범위 칩을 단 채 대상 메뉴를 열어 둔다 (U1 ⌘N 길). 세션은 첫 전달 때 서버가 만든다
    @discardableResult
    func openNewSession(scope: AssistantOpenItem?) -> UUID? {
        guard let id = openNewWindow() else { return nil }
        if let scope { controllers[id]?.model.addChip(AssistantChip(open: scope)) }
        controllers[id]?.toggleTargetMenu()
        return id
    }

    /// 패널에서 열린 항목을 앞 창의 auto 칩이 따라간다 (뒤 창들은 자기 칩을 지킨다). 열린 항목이 없어졌다고 칩을 지우지 않는다
    private func followOpenItem() {
        let item = withObservationTracking {
            shell.openItem
        } onChange: { [weak self] in
            Task { @MainActor in self?.followOpenItem() }
        }
        guard let item, let front = registry.frontmost else { return }
        controllers[front]?.model.followOpenItem(Self.chip(for: item))
    }
}
#endif
