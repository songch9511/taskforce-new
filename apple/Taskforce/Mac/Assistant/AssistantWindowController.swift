#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

/// Assistant 창: 키를 받을 수 있지만 **스스로 키 창이 되지 않는다** (클릭 · ⌘3 · ⌘N에서만). 패널(EdgePanel)이 아니라 다른 앱 위에 떠 있는 창이다.
final class AssistantPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 창 하나의 NSPanel · 자리 · 크기. 어느 대화를 보이는지는 `AssistantWindowModel`, 창 개수 · 위치 · 크기 기억은 `AssistantWindowManager`가 정한다.
/// - 기본은 380pt 폭, 높이는 내용에 맞춰 560까지 (빈 대화는 440 아래로 줄지 않는다). 높이가 변해도 **위 가장자리**가 움직이지 않는다
/// - 크기는 사용자가 가장자리 · 모서리를 끌어 바꾼다 (`preferredSize`: 폭만 바꾸면 높이는 계속 내용에 맞추고, 높이를 바꾸면 그 높이). 두 번 누르면 기본으로
/// - 핸들 · 머리의 빈 곳을 누르면 `performDrag`로 끌고, 핸들에 포커스를 두고 화살표 키로 8pt씩 옮기고 ⌥ + 화살표로 16pt씩 크기를 바꾼다
/// - 열고 닫는 움직임은 불투명도뿐이다 (DS가 창의 움직임을 말하지 않는다. 움직임 줄이기와 같은 모양)
@MainActor
final class AssistantWindowController: NSObject, NSWindowDelegate {
    let model: AssistantWindowModel
    let panel: AssistantPanel
    let presentation = AssistantWindowPresentation()
    let targetMenu = AssistantTargetMenu()
    private let hosting: NSHostingView<AssistantWindowView>
    private let container: AssistantWindowContentView
    private let runtime: ChatRuntime
    private let environment: AssistantWindowManager.Environment
    private(set) var topLeft: CGPoint
    /// 바라는 자리: 사용자가 옮겼거나 기억에서 가져온 자리. 높이가 변해 보정이 창을 밀어도 이 자리가 원본이라, 높이가 다시 줄면 돌아온다
    /// (History로 대화를 바꿀 때 앞 대화의 높이로 밀린 자리가 굳지 않게)
    private(set) var desiredTopLeft: CGPoint
    /// 사용자가 정한 크기: 폭, 높이(nil이면 내용에 맞춘다). 화면이 작아 줄어 보여도 이 값은 그대로다 (큰 화면으로 돌아오면 다시 이 크기)
    private(set) var preferredSize: AssistantWindowSize
    /// 크기 조절 끌기 하나의 시작 상태 (끌기 시작 때의 창 · 화면 · 한도). 있는 동안은 내용 높이 맞춤이 창을 건드리지 않는다
    private var resizeSession: ResizeSession?
    /// 우리가 옮기는 중(프로그램): `windowDidMove`가 사용자의 이동으로 기억하지 않게
    private var programmatic = false
    /// 창을 올리고(`show`) 내리는(`hide` · `close`) 요청이 올 때마다 오른다 (늦은 숨김이 새 요청을 되돌리지 못하게 · 시험은 화면 없이 `show`가 불렸는지 본다)
    private(set) var generation = 0
    private var observing = false
    private var settleTask: Task<Void, Never>?
    /// 끌기가 멈췄다고 보기까지 움직임이 없어야 하는 시간 (시험은 줄인다)
    var moveSettleDelay: Duration = .milliseconds(120)
    /// 마우스 왼쪽 버튼이 눌려 있나 (끌기 도중에는 보정하지 않는다. 시험은 바꾼다)
    var mouseIsDown: () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }
    var onMoved: (CGPoint) -> Void = { _ in }
    /// 사용자가 크기를 정했다 (끌기를 놓았을 때 · 키보드 · 기본으로 되돌림)
    var onResized: (AssistantWindowSize) -> Void = { _ in }
    var onBecameKey: () -> Void = {}
    var onResignedKey: () -> Void = {}
    var onOpenConnections: () -> Void = {}
    /// 창을 실제 화면에 올리는가 (시험은 끈다: 창을 만들고 자리만 잡는다)
    var presents = true

    /// - screenID: 기억한 위치를 읽은 화면. 그 위치는 그 화면에 놓는다 (처음 높이로 어느 화면과 더 많이 겹치는지 따지지 않는다)
    /// - size: 그 화면에서 사용자가 정한 크기 (없으면 기본)
    init(
        model: AssistantWindowModel, runtime: ChatRuntime, topLeft: CGPoint, screenID: String? = nil, size: AssistantWindowSize = .standard,
        environment: AssistantWindowManager.Environment, reduceMotion: Bool
    ) {
        self.model = model
        self.runtime = runtime
        self.topLeft = topLeft
        desiredTopLeft = topLeft
        preferredSize = size
        self.environment = environment
        panel = AssistantPanel(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height ?? AssistantWindowGeometry.emptyHeight),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        hosting = NSHostingView(rootView: AssistantWindowView(model: model, runtime: runtime, presentation: AssistantWindowPresentation(), reduceMotion: reduceMotion))
        container = AssistantWindowContentView(content: hosting)
        super.init()
        hosting.rootView = AssistantWindowView(
            model: model, runtime: runtime, presentation: presentation, reduceMotion: reduceMotion,
            actions: AssistantWindowActions(
                toggleTargetMenu: { [weak self] in self?.toggleTargetMenu() },
                move: { [weak self] direction in self?.move(by: direction) },
                resize: { [weak self] direction in self?.resize(by: direction) },
                openConnections: { [weak self] in self?.onOpenConnections() }
            )
        )
        container.handlers = AssistantResizeHandlers(
            begin: { [weak self] edge in self?.beginResize(edge) },
            drag: { [weak self] delta in self?.resize(by: delta) },
            end: { [weak self] in self?.endResize() },
            reset: { [weak self] in self?.resetSize() }
        )
        hosting.sizingOptions = []
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // `shadow-float`: macOS가 창 모양(둥근 모서리)을 따라 그린다
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = true
        // 배경 끌기는 끈다: 본문 어디서나 끌리면 글을 고르다 창이 움직인다. 핸들 · 머리의 빈 곳만 `performDrag`로 끈다
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = container
        panel.delegate = self
        panel.setAccessibilityLabel("Assistant")
        panel.title = "Assistant"
        applyFrame(.placement, screenID: screenID)
        followLayout()
    }

    // MARK: 자리 · 크기

    /// 사용자가 정한 값과 지금 내용으로 바라는 크기 (화면 한도로 줄이기 전). 화면을 고르는 데 쓴다
    private var wantedSize: CGSize {
        CGSize(
            width: preferredSize.width,
            height: preferredSize.height ?? AssistantWindowGeometry.height(content: presentation.contentHeight, isEmpty: model.isEmptyConversation)
        )
    }

    /// 이 화면에 놓을 크기: 사용자가 정한 값 · 지금 내용 · 화면의 한도(보이는 영역 − 레일)
    private func size(on screen: AssistantScreen) -> CGSize {
        AssistantWindowGeometry.size(
            preferredSize, contentHeight: presentation.contentHeight, isEmpty: model.isEmptyConversation,
            head: presentation.headHeight, footer: presentation.footerHeight, visible: screen.visible, railWidth: environment.reservedRailWidth(on: screen)
        )
    }

    /// 창을 놓는 두 경우: 실제로 옮기거나 처음 놓을 때(`placement`)는 목적지의 화면을 따르고,
    /// 높이만 변할 때(`heightChange`)는 변하기 전에 창이 있던 화면에서 보정한다 (세로로 쌓인 화면에서 커진 창이 더 많이 겹친 다른 화면으로 가지 않게)
    enum Change {
        case placement, heightChange
    }

    /// 위 가장자리를 둔 채 크기를 맞춘다. 보이는 영역 · 레일 밖으로 넣는다. 보정은 늘 **바라는 자리**에서 시작한다.
    /// 크기 조절 끌기 중에는 아무것도 하지 않는다 (끌기가 창을 정한다. 놓으면 `endResize`가 맞춘다)
    /// - screenID: 놓을 화면을 정해 준다 (`placement`일 때만). 기억한 위치를 읽은 화면이다: 지금 높이로 다른 화면을 고르면 새 높이가 반영돼도 돌아오지 못한다
    func applyFrame(_ change: Change = .heightChange, screenID: String? = nil) {
        guard resizeSession == nil else { return }
        // 창이 있는 화면 기준으로 보정한다 (레일은 레일 화면에만 있다)
        let reference = change == .placement ? Self.rect(topLeft: desiredTopLeft, size: wantedSize) : panel.frame
        let screen = (change == .placement ? screenID.flatMap { environment.screen(id: $0) } : nil) ?? environment.screen(for: reference)
        let size = size(on: screen)
        topLeft = AssistantWindowGeometry.clamped(topLeft: desiredTopLeft, size: size, visible: screen.visible, railWidth: environment.reservedRailWidth(on: screen))
        let frame = NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
        guard frame != panel.frame else { return }
        programmatic = true
        panel.setFrame(frame, display: true)
        programmatic = false
        panel.invalidateShadow()
    }

    private static func rect(topLeft: CGPoint, size: CGSize) -> CGRect {
        CGRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
    }

    /// 이 창이 지금 있는 화면의 키 (위치를 기억하는 키)
    var currentScreenID: String {
        environment.screen(for: panel.frame).id
    }

    /// 내용 높이 · 빈 대화 여부가 바뀔 때마다 높이를 맞춘다 (관찰이 끝나면 다시 건다)
    private func followLayout() {
        guard !observing else { return }
        observing = true
        track()
    }

    private func track() {
        withObservationTracking {
            _ = presentation.contentHeight
            _ = model.isEmptyConversation
            _ = model.conversationID
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applyFrame()
                self.track()
            }
        }
    }

    /// 핸들의 화살표 키: 8pt씩
    func move(by direction: AssistantWindowGeometry.Direction) {
        desiredTopLeft = AssistantWindowGeometry.moved(topLeft, by: direction)
        applyFrame(.placement)
        desiredTopLeft = topLeft
        onMoved(topLeft)
    }

    /// 지금의 위치를 알려 준 위치로 (관리자가 기억한 위치 · 겹쳐 열기). 바라는 자리로 남아, 이어지는 높이 변화가 그 자리에서 다시 보정한다
    /// - screenID: 그 위치를 읽은 화면 (기억한 위치를 적용할 때). 없으면 놓을 영역이 가장 많이 겹치는 화면
    func place(topLeft: CGPoint, onScreen screenID: String? = nil) {
        desiredTopLeft = topLeft
        applyFrame(.placement, screenID: screenID)
    }

    // MARK: 크기 조절

    /// 크기 조절 끌기 하나: 시작 때의 창과 한도. 끄는 동안 이 값에 마우스가 움직인 만큼을 더해 창을 정한다
    private struct ResizeSession {
        let edge: AssistantWindowGeometry.ResizeEdge
        let frame: NSRect
        let bounds: CGRect
        let minimum: CGSize
        let maximum: CGSize
    }

    /// 크기 조절 끌기를 시작한다 (가장자리 · 모서리를 누름). 이동의 정착 보정이 끼어들지 않게 하고, 열려 있는 메뉴는 닫는다. 키 창은 바꾸지 않는다
    func beginResize(_ edge: AssistantWindowGeometry.ResizeEdge) {
        settleTask?.cancel()
        settleTask = nil
        closeTargetMenu()
        let screen = environment.screen(for: panel.frame)
        let railWidth = environment.reservedRailWidth(on: screen)
        resizeSession = ResizeSession(
            edge: edge, frame: panel.frame,
            bounds: AssistantWindowGeometry.resizeBounds(visible: screen.visible, railWidth: railWidth),
            minimum: CGSize(
                width: AssistantWindowGeometry.minWidth,
                height: AssistantWindowGeometry.minimumHeight(head: presentation.headHeight, footer: presentation.footerHeight)
            ),
            maximum: AssistantWindowGeometry.maxSize(visible: screen.visible, railWidth: railWidth)
        )
    }

    /// 끌기 시작 때 마우스가 있던 곳에서 `delta`(화면 좌표, 위로 끌면 +)만큼 움직였다: 창이 따라온다
    func resize(by delta: CGPoint) {
        guard let session = resizeSession else { return }
        let frame = AssistantWindowGeometry.resized(
            session.frame, edge: session.edge, by: delta, within: session.bounds, min: session.minimum, max: session.maximum
        )
        guard frame != panel.frame else { return }
        programmatic = true
        panel.setFrame(frame, display: true)
        programmatic = false
        panel.invalidateShadow()
    }

    /// 마우스를 놓았다: 이 크기를 사용자가 정한 크기로 삼는다. 높이를 바꾸지 않았으면 높이는 계속 내용에 맞춘다.
    /// 자리도 함께 기억한다 (위 · 왼쪽 가장자리를 끌면 자리가 바뀌고, 아니어도 크기와 짝으로 다시 열린다)
    func endResize() {
        guard let session = resizeSession else { return }
        resizeSession = nil
        let frame = panel.frame
        guard frame != session.frame else { return }
        let changedHeight = session.edge.changesHeight && frame.height != session.frame.height
        preferredSize = AssistantWindowSize(width: frame.width, height: changedHeight ? frame.height : preferredSize.height)
        topLeft = CGPoint(x: frame.minX, y: frame.maxY)
        desiredTopLeft = topLeft
        onResized(preferredSize)
        onMoved(topLeft)
        // 자동 높이는 새 폭의 내용에 다시 맞춘다
        applyFrame()
    }

    /// 핸들에 포커스를 두고 ⌥ + 화살표: 오른쪽 아래 모서리를 16pt씩 옮긴다 (왼쪽 위는 그대로)
    func resize(by direction: AssistantWindowGeometry.Direction) {
        beginResize(.bottomRight)
        resize(by: AssistantWindowGeometry.keyboardResizeDelta(direction))
        endResize()
    }

    /// 가장자리를 두 번 눌렀다: 기본 크기(380 폭, 높이는 내용에 맞춘다)로. 왼쪽 위는 그대로
    func resetSize() {
        guard preferredSize != .standard else { return }
        preferredSize = .standard
        applyFrame()
        onResized(.standard)
        onMoved(topLeft)
    }

    // MARK: 보이기 · 숨기기

    var isVisible: Bool { panel.isVisible }

    /// 창을 올린다. `makeKey`는 사용자가 부른 때(클릭 · ⌘3 · ⌘N)만: 스스로 키 창이 되지 않는다
    func show(makeKey: Bool) {
        generation += 1
        guard presents else { return }
        hosting.layoutSubtreeIfNeeded()
        applyFrame()
        let wasVisible = panel.isVisible
        if !wasVisible { panel.alphaValue = 0 }
        if makeKey { panel.makeKeyAndOrderFront(nil) } else { panel.orderFrontRegardless() }
        presentation.targetMenuOpen = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = TFMotion.panelFade
            context.timingFunction = Self.timing
            panel.animator().alphaValue = 1
        }
        if makeKey { model.requestFocus() }
    }

    /// Esc: 숨긴다. 초안 · 칩 · 위치는 그대로, 일은 멈추지 않는다
    func hide() {
        targetMenu.dismiss(notify: false)
        presentation.targetMenuOpen = false
        generation += 1
        let current = generation
        guard presents, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = TFMotion.panelFade
            context.timingFunction = Self.timing
            panel.animator().alphaValue = 0
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(TFMotion.panelFade))
            guard let self, self.generation == current else { return }
            self.panel.orderOut(nil)
        }
    }

    /// ⌘W · 계정이 떠남: 창을 닫는다 (대화는 Chat history에 남는다)
    func close() {
        settleTask?.cancel()
        // 끌던 중에 닫히면(계정이 떠남) 놓았을 때 크기를 다시 기억하지 않는다
        resizeSession = nil
        targetMenu.dismiss(notify: false)
        generation += 1
        panel.delegate = nil
        panel.orderOut(nil)
        panel.close()
    }

    // MARK: 대상 메뉴

    /// 대상 알약 위의 메뉴를 열고 닫는다. 목록은 그때 새로 읽는다 (열려 있는 동안은 지금 가진 목록으로)
    func toggleTargetMenu() {
        if targetMenu.isOpen {
            targetMenu.dismiss()
            return
        }
        let targets = runtime.targets
        Task { await targets.refresh() }
        // 메뉴는 저장소를 지켜본다: 읽기가 끝나기 전에 열어도 끝난 뒤 에이전트 행이 나타나고, 실패하면 다시 시도가 나온다
        let menuModel = TargetMenuModel(
            store: targets, pick: { [weak self] in self?.model.pick ?? .taskforce },
            onPick: { [weak self] option in
                guard let self else { return }
                self.targetMenu.dismiss()
                self.model.chooseTarget(option)
            },
            onRetry: { Task { await targets.refresh() } }
        )
        presentation.targetMenuOpen = true
        targetMenu.shows = presents
        targetMenu.present(model: menuModel, pill: pillFrameOnScreen, over: panel) { [weak self] in
            self?.presentation.targetMenuOpen = false
            self?.model.requestFocus()
        }
    }

    /// 다른 창이 앞으로 와서 이 창의 메뉴를 닫는다 (포커스를 되돌려 달라고 하지 않는다: 키는 새 창이 가져간다)
    func closeTargetMenu() {
        guard targetMenu.isOpen else { return }
        targetMenu.dismiss(notify: false)
        presentation.targetMenuOpen = false
    }

    /// 대상 알약의 자리 (화면 좌표, 아래가 0). 알약의 창 좌표는 위가 0이다
    var pillFrameOnScreen: CGRect {
        let pill = presentation.pillFrame
        let frame = panel.frame
        return CGRect(x: frame.minX + pill.minX, y: frame.maxY - pill.maxY, width: pill.width, height: pill.height)
    }

    // MARK: NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        guard !programmatic else { return }
        topLeft = CGPoint(x: panel.frame.minX, y: panel.frame.maxY)
        desiredTopLeft = topLeft
        scheduleMoveSettle()
    }

    /// 끌기가 멈추면(움직임이 잦아들고 마우스를 놓았을 때) 한 번 보정하고 기억한다. 끄는 도중에는 창을 되돌리지 않는다
    private func scheduleMoveSettle() {
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: self.moveSettleDelay)
                guard !Task.isCancelled else { return }
                if self.mouseIsDown() { continue }
                self.finishMove()
                return
            }
        }
    }

    /// 끌기가 끝났다: 보이는 영역 · 레일 밖이면 안으로 넣고 그 자리를 기억한다
    func finishMove() {
        settleTask = nil
        // 실제 프레임 좌표를 다시 읽는다: 정착을 기다리는 사이 높이 변경이 창을 밀었으면(위 화면 바닥의 창이 커져 위로 밀림)
        // `windowDidMove`가 따라온 바라는 자리와 실제 자리가 다르고, 바라는 자리로 놓으면 다른 화면을 골라 거기에 저장한다
        desiredTopLeft = CGPoint(x: panel.frame.minX, y: panel.frame.maxY)
        applyFrame(.placement)
        desiredTopLeft = topLeft
        onMoved(topLeft)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        onBecameKey()
    }

    func windowDidResignKey(_ notification: Notification) {
        // 대상 메뉴가 키를 가져간 것은 창을 잃은 것이 아니다
        guard !targetMenu.isOpen else { return }
        onResignedKey()
    }

    private static let timing = CAMediaTimingFunction(
        controlPoints: Float(TFMotion.easeControlPoints.x1), Float(TFMotion.easeControlPoints.y1),
        Float(TFMotion.easeControlPoints.x2), Float(TFMotion.easeControlPoints.y2)
    )
}
#endif
