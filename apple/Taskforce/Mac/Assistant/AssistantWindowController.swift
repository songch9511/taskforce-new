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

/// 창 하나의 NSPanel · 자리 · 높이. 어느 대화를 보이는지는 `AssistantWindowModel`, 창 개수 · 위치 기억은 `AssistantWindowManager`가 정한다.
/// - 380pt 폭, 높이는 내용에 맞춰 560까지 (빈 대화는 440 아래로 줄지 않는다). 높이가 변해도 **위 가장자리**가 움직이지 않는다
/// - 크기 조절 없음. 핸들 · 머리의 빈 곳으로 끌고(`isMovable`), 핸들에 포커스를 두고 화살표 키로 8pt씩
/// - 열고 닫는 움직임은 불투명도뿐이다 (DS가 창의 움직임을 말하지 않는다. 움직임 줄이기와 같은 모양)
@MainActor
final class AssistantWindowController: NSObject, NSWindowDelegate {
    let model: AssistantWindowModel
    let panel: AssistantPanel
    let presentation = AssistantWindowPresentation()
    let targetMenu = AssistantTargetMenu()
    private let hosting: NSHostingView<AssistantWindowView>
    private let runtime: ChatRuntime
    private let environment: AssistantWindowManager.Environment
    private(set) var topLeft: CGPoint
    /// 우리가 옮기는 중(프로그램): `windowDidMove`가 사용자의 이동으로 기억하지 않게
    private var programmatic = false
    private var generation = 0
    private var observing = false
    var onMoved: (CGPoint) -> Void = { _ in }
    var onBecameKey: () -> Void = {}
    var onResignedKey: () -> Void = {}
    var onOpenConnections: () -> Void = {}
    /// 창을 실제 화면에 올리는가 (시험은 끈다: 창을 만들고 자리만 잡는다)
    var presents = true

    init(model: AssistantWindowModel, runtime: ChatRuntime, topLeft: CGPoint, environment: AssistantWindowManager.Environment, reduceMotion: Bool) {
        self.model = model
        self.runtime = runtime
        self.topLeft = topLeft
        self.environment = environment
        panel = AssistantPanel(
            contentRect: NSRect(x: 0, y: 0, width: AssistantWindowGeometry.width, height: AssistantWindowGeometry.emptyHeight),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        hosting = NSHostingView(rootView: AssistantWindowView(model: model, runtime: runtime, presentation: AssistantWindowPresentation(), reduceMotion: reduceMotion))
        super.init()
        hosting.rootView = AssistantWindowView(
            model: model, runtime: runtime, presentation: presentation, reduceMotion: reduceMotion,
            actions: AssistantWindowActions(
                toggleTargetMenu: { [weak self] in self?.toggleTargetMenu() },
                move: { [weak self] direction in self?.move(by: direction) },
                openConnections: { [weak self] in self?.onOpenConnections() }
            )
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
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        panel.delegate = self
        panel.setAccessibilityLabel("Assistant")
        panel.title = "Assistant"
        applyFrame()
        followLayout()
    }

    // MARK: 자리 · 높이

    /// 지금 내용에 맞는 높이
    var height: CGFloat {
        AssistantWindowGeometry.height(content: presentation.contentHeight, isEmpty: model.isEmptyConversation)
    }

    /// 위 가장자리를 둔 채 높이를 맞춘다. 보이는 영역 · 레일 밖으로 넣는다
    func applyFrame() {
        let height = height
        topLeft = AssistantWindowGeometry.clamped(topLeft: topLeft, height: height, visible: environment.visibleFrame(), railWidth: environment.railWidth)
        let frame = NSRect(x: topLeft.x, y: topLeft.y - height, width: AssistantWindowGeometry.width, height: height)
        guard frame != panel.frame else { return }
        programmatic = true
        panel.setFrame(frame, display: true)
        programmatic = false
        panel.invalidateShadow()
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
        topLeft = AssistantWindowGeometry.moved(topLeft, by: direction)
        applyFrame()
        onMoved(topLeft)
    }

    /// 지금의 위치를 알려 준 위치로 (관리자가 기억한 위치 · 겹쳐 열기)
    func place(topLeft: CGPoint) {
        self.topLeft = topLeft
        applyFrame()
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
        Task { await runtime.targets.refresh() }
        let options = runtime.targets.options
        let menuModel = TargetMenuModel(
            options: options, selected: AssistantTargetRules.index(of: model.pick, in: options),
            onPick: { [weak self] option in
                guard let self else { return }
                self.targetMenu.dismiss()
                self.model.chooseTarget(option)
            }
        )
        presentation.targetMenuOpen = true
        targetMenu.present(model: menuModel, pill: pillFrameOnScreen, over: panel) { [weak self] in
            self?.presentation.targetMenuOpen = false
            self?.model.requestFocus()
        }
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
