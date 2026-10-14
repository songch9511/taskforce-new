#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

/// 메뉴 창: 열리면 키 창이 되어 호버 · 클릭을 받고(앱이 활성이 아니어도), 닫히면 키를 창에 돌려준다. ↑ ↓ Return Esc는 모니터가 먼저 듣는다
final class AssistantMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 대상 메뉴 (DS TargetPicker / ContextMenu): 대상 알약 **위로** 열리는 떠 있는 면. 알약 위 6pt, 왼쪽은 알약보다 4pt 바깥, 가장 긴 줄에 맞춰 240 ~ 460pt.
/// 창 폭(380)보다 넓을 수 있어 창 안이 아니라 자기 창이다. Esc · 바깥 클릭으로 닫고, 고르면 닫는다
@MainActor
final class AssistantTargetMenu {
    nonisolated static let gap: CGFloat = 6
    nonisolated static let leftOutdent: CGFloat = 4

    private var panel: AssistantMenuPanel?
    private var model: TargetMenuModel?
    private var monitors: [Any] = []
    private var pillFrame: CGRect = .zero
    private var onClose: (() -> Void)?
    private weak var parent: NSWindow?

    var isOpen: Bool { panel != nil }
    var window: NSWindow? { panel }

    /// 메뉴의 자리 (화면 좌표, 아래가 0): 알약 위 6pt, 왼쪽은 4pt 바깥. 보이는 영역을 벗어나면 안으로 민다
    nonisolated static func frame(size: CGSize, pill: CGRect, visible: CGRect) -> CGRect {
        var x = pill.minX - leftOutdent
        var y = pill.maxY + gap
        x = max(visible.minX, min(x, visible.maxX - size.width))
        y = min(y, visible.maxY - size.height)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// - pill: 대상 알약의 자리 (화면 좌표, 아래가 0)
    func present(model: TargetMenuModel, pill: CGRect, over parent: NSWindow, onClose: @escaping () -> Void) {
        dismiss(notify: false)
        self.model = model
        pillFrame = pill
        self.onClose = onClose
        let hosting = NSHostingView(rootView: TargetMenuView(model: model))
        // 크기는 내용이 정한다 (줄 수 · 가장 긴 줄). `[]`이면 fittingSize가 0이 되어 창이 자리를 잘못 잡는다
        hosting.sizingOptions = [.intrinsicContentSize]
        let size = hosting.intrinsicContentSize
        let panel = AssistantMenuPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = parent.level
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // `shadow-float`: macOS가 둥근 모서리를 따라 그린다
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = hosting
        let visible = (parent.screen ?? NSScreen.main)?.visibleFrame ?? parent.frame
        panel.setFrame(Self.frame(size: size, pill: pill, visible: visible), display: true)
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        self.parent = parent
        installMonitors(parent: parent)
    }

    func dismiss(notify: Bool = true) {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            // 키를 창에 돌려준다 (프롬프트의 초안 · 포커스가 이어진다)
            if panel.isKeyWindow { parent?.makeKey() }
        }
        panel = nil
        model = nil
        let close = onClose
        onClose = nil
        if notify { close?() }
    }

    private func installMonitors(parent: NSWindow) {
        // ↑ ↓ Return Esc: 메뉴가 열려 있는 동안 창의 키 입력을 먼저 받는다
        if let key = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }) {
            monitors.append(key)
        }
        // 바깥을 누르면 닫는다 (알약은 자기 클릭이 열고 닫는다: 여기서 닫으면 같은 클릭이 다시 열어 버린다)
        if let click = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.outsideClick(event) }
            return event
        }) {
            monitors.append(click)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }) {
            monitors.append(global)
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let model else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isEmpty || flags == .numericPad || flags == .function else { return false }
        switch Int(event.keyCode) {
        case 126: model.move(-1)
        case 125: model.move(1)
        case 36, 76: model.activate()
        case 53: dismiss()
        default: return false
        }
        return true
    }

    private func outsideClick(_ event: NSEvent) {
        guard let panel else { return }
        if event.window === panel { return }
        // 알약 위: 알약의 클릭이 처리한다
        if let window = event.window {
            let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
            if pillFrame.contains(screenPoint) { return }
        }
        dismiss()
    }
}
#endif
