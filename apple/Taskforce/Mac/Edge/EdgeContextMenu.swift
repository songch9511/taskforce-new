#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

/// 메뉴 창: 열리면 키 창이 되어 호버 · 클릭을 받고(앱이 활성이 아니어도), 닫히면 키를 창에 돌려준다
final class EdgeMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 범용 ContextMenu의 창 (OA U2-15). 눌린 행을 덮지 않는 자리(`ContextMenuGeometry`: 행 아래 4, 아래가 없으면 위, 가로는 포인터에서 화면 안으로)에 열리고,
/// ↑ ↓ Return Esc는 메뉴가 키 창일 때 그 창의 키만 처리한다. 바깥 클릭 · 키를 잃음 · 하나를 고름으로 닫는다. U2 안의 사용처는 More 목록(탭의 `…`)뿐이다 (프로젝트 · 이슈 메뉴 내용은 D4c)
@MainActor
final class EdgeContextMenu {
    private var panel: EdgeMenuPanel?
    private(set) var model: ContextMenuModel?
    private var monitors: [Any] = []
    private var resignObserver: NSObjectProtocol?
    private var row: CGRect = .zero
    private var pointerX: CGFloat = 0
    private var visibleFrame: CGRect = .zero
    private var onClose: (() -> Void)?
    private weak var parent: NSWindow?
    /// 창을 실제 화면에 올리는가 (시험은 끈다)
    var shows = true

    var isOpen: Bool { panel != nil }
    var window: NSWindow? { panel }

    /// - row: 눌린 행의 자리 (화면 좌표, 아래가 0), pointer: 포인터의 가로 위치
    func present(model: ContextMenuModel, label: String, row: CGRect, pointerX: CGFloat, over parent: NSWindow, onClose: @escaping () -> Void) {
        dismiss(notify: false)
        self.model = model
        self.row = row
        self.pointerX = pointerX
        self.onClose = onClose
        model.onPick = { [weak self] in self?.dismiss() }
        let hosting = NSHostingView(rootView: ContextMenuView(model: model, label: label))
        hosting.sizingOptions = [.intrinsicContentSize]
        let size = hosting.intrinsicContentSize
        let panel = EdgeMenuPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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
        visibleFrame = visible
        panel.setFrame(ContextMenuGeometry.frame(size: size, row: row, pointerX: pointerX, visible: visible), display: true)
        self.panel = panel
        self.parent = parent
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        if shows {
            parent.addChildWindow(panel, ordered: .above)
            panel.makeKeyAndOrderFront(nil)
            installMonitors()
        }
    }

    func dismiss(notify: Bool = true) {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            // 키를 부모 창에 돌려준다
            if panel.isKeyWindow { parent?.makeKey() }
        }
        panel = nil
        model = nil
        let close = onClose
        onClose = nil
        if notify { close?() }
    }

    private func installMonitors() {
        if let key = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }) {
            monitors.append(key)
        }
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

    /// 메뉴 창이 키 창일 때 그 창으로 온 키만: ↑ ↓ Return Esc. 다른 창의 Return을 가로채지 않는다
    func handle(_ event: NSEvent) -> Bool {
        guard let model, let panel, event.window === panel else { return false }
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
        guard let panel, event.window !== panel else { return }
        dismiss()
    }
}
#endif
