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

/// ⌥Space 런처 창 (Figma 156:6 M1 · M20): 760×480 고정, 모서리 18 (`TFRadius.window`).
/// 바탕은 macOS 26부터 Liquid Glass(`NSGlassEffectView`), 그 전은 시스템 유리 재질(`NSVisualEffectView` popover).
/// 그 위에 bg/glass(투명도 줄이기면 불투명 settings/window)를 깐다 (`LauncherRootView`).
/// 화면 가운데 위쪽 1/5 지점에 뜨고, esc · 다른 곳 클릭(포커스 잃음) · 동작 완료로 닫힌다.
@MainActor
final class LauncherPanelController: NSObject, NSWindowDelegate {
    static let size = CGSize(width: 760, height: 480)

    /// 창 바탕이 Liquid Glass인지 (유리는 제 테두리를 그려서 따로 긋지 않는다)
    static var usesGlass: Bool {
        if #available(macOS 26.0, *) { true } else { false }
    }

    let model: LauncherModel
    private let panel: LauncherPanel
    private var keyMonitor: Any?
    private var openThrottle = LauncherOpenThrottle()

    init(model: LauncherModel) {
        self.model = model
        panel = LauncherPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
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

        let hosting = NSHostingView(rootView: LauncherRootView(model: model))
        // 창 크기는 고정 (760×480)
        hosting.sizingOptions = []

        let background: NSView
        if #available(macOS 26.0, *) {
            // Liquid Glass: 내용은 유리의 contentView로 (유리가 제약으로 같은 크기에 맞춘다. setFrame(display: true)의 레이아웃에서 바로 맞춰진다)
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = TFRadius.window
            glass.contentView = hosting
            background = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.maskImage = Self.roundedMask(radius: TFRadius.window)
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

    // MARK: 위치

    private func position() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = Self.size
        // 가운데, 위 모서리는 위에서 1/5 지점 (작은 화면에서는 아래로 넘치지 않게)
        let top = visible.maxY - visible.height / 5
        let origin = NSPoint(x: visible.midX - size.width / 2, y: max(visible.minY, top - size.height))
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
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
