#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

/// 테두리 없는 비활성 패널: 다른 앱을 앞에 둔 채로 키 입력만 받는다 (Spotlight처럼)
final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// ⌥Space 런처 창 (Figma 5:57 · 5:90): 폭 696, 모서리 26, 높이는 내용에 맞춘다.
/// 바탕은 macOS 26부터 Liquid Glass(`NSGlassEffectView`), 그 전은 시스템 유리 재질(`NSVisualEffectView` popover).
/// 화면 가운데 위쪽 1/3에 뜨고, esc · 다른 곳 클릭(포커스 잃음) · 동작 완료로 닫힌다.
@MainActor
final class LauncherPanelController: NSObject, NSWindowDelegate {
    static let width: CGFloat = 696

    /// 창 바탕이 Liquid Glass인지 (유리는 제 테두리를 그려서 따로 긋지 않는다)
    static var usesGlass: Bool {
        if #available(macOS 26.0, *) { true } else { false }
    }

    let model: LauncherModel
    private let panel: LauncherPanel
    private var keyMonitor: Any?
    private var openThrottle = LauncherOpenThrottle()
    private var height: CGFloat = 120
    /// 창 높이 맞추기를 다음 차례로 미뤄 둔 상태
    private var resizeScheduled = false

    init(model: LauncherModel) {
        self.model = model
        panel = LauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 120),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // 창 그림자는 macOS가 그린다 (BRAND "모양")
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.delegate = self

        let hosting = NSHostingView(
            rootView: LauncherRootView(model: model) { [weak self] height in self?.resize(height: height) }
        )
        // 창 크기는 이 컨트롤러가 정한다 (내용 높이를 받아서)
        hosting.sizingOptions = []

        let background: NSView
        if #available(macOS 26.0, *) {
            // Liquid Glass: 내용은 유리의 contentView로 (유리가 제약으로 같은 크기에 맞춘다. setFrame(display: true)의 레이아웃에서 바로 맞춰진다)
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = TFRadius.xl
            glass.contentView = hosting
            background = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.maskImage = Self.roundedMask(radius: TFRadius.xl)
            // 제약 대신 autoresizing: 창 크기가 바뀌는 즉시 내용도 같은 크기가 된다 (제약은 다음 레이아웃 차례까지 옛 크기로 남는다)
            hosting.frame = effect.bounds
            hosting.autoresizingMask = [.width, .height]
            effect.addSubview(hosting)
            background = effect
        }
        panel.contentView = background
        // macOS 14부터 뷰는 기본으로 제 영역 밖을 자르지 않는다: 크기가 잠깐 어긋나도 내용이 유리 밖으로 새지 않게
        background.clipsToBounds = true

        model.close = { [weak self] in self?.hide() }
        model.presentationAnchor = { [weak self] in self?.panel }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        model.prepareForShow()
        position()
        panel.makeKeyAndOrderFront(nil)
        // 처음 앞으로 나올 때 창이 만들어지며 크기가 처음 값으로 돌아갈 수 있어 한 번 더 맞춘다
        position()
        installKeyMonitor()
        // 지표 2 · 3: 런처를 띄울 때마다가 아니라 30분에 한 번
        if model.isSignedIn, openThrottle.shouldSend(at: Date()) {
            model.reportAppOpened()
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        removeKeyMonitor()
        model.didHide()
    }

    #if DEBUG
    /// 디자인 비교용 PNG (`LauncherSnapshot`)
    func snapshotIfRequested() {
        LauncherSnapshot.run(panel: panel, model: model)
    }
    #endif

    // MARK: 크기 · 위치

    private func resize(height: CGFloat) {
        let height = ceil(height)
        guard abs(height - self.height) > 0.5 else { return }
        self.height = height
        // SwiftUI 레이아웃 도중(onGeometryChange)에 창 크기를 바꾸면 창 · 유리 · 내용 · 그림자가 서로 다른 크기로 남는다.
        // 이번 차례가 끝난 뒤 마지막 높이로 한 번에 맞춘다.
        guard panel.isVisible, !resizeScheduled else { return }
        resizeScheduled = true
        Task { [weak self] in self?.applyHeight() }
    }

    private func applyHeight() {
        resizeScheduled = false
        guard panel.isVisible else { return }
        var frame = panel.frame
        guard abs(frame.height - height) > 0.5 else { return }
        // 위 모서리를 고정하고 아래로 늘고 준다
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
        // 그림자는 새 크기로 다시 그린 뒤에 계산한다 (먼저 계산하면 옛 모양이 남는다)
        panel.invalidateShadow()
    }

    private func position() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let width = min(Self.width, visible.width - 32)
        // 가운데, 위쪽 1/3 지점에 위 모서리
        let top = visible.maxY - visible.height / 5
        panel.setFrame(NSRect(x: visible.midX - width / 2, y: top - height, width: width, height: height), display: false)
        panel.invalidateShadow()
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // MARK: 키보드

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // 로컬 모니터는 메인 스레드에서 불린다
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, event.window === self.panel else { return false }
                return self.model.handleKey(event)
            }
            return handled ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // 다른 곳을 누르면 닫는다 (Apple · Google 로그인 창을 띄운 동안은 빼고)
        guard !model.suspendsAutoClose else { return }
        hide()
    }
}
#endif
