#if os(macOS)
import AppKit
import Carbon.HIToolbox
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
        var hosting = NSHostingView(rootView: ContextMenuView(model: model, label: label))
        hosting.sizingOptions = [.intrinsicContentSize]
        var size = hosting.intrinsicContentSize
        let visible = (parent.screen ?? NSScreen.main)?.visibleFrame ?? parent.frame
        // 줄이 화면보다 길면 높이를 줄이고 안에서 스크롤한다 (키보드로 짚은 줄을 따라간다): 줄 몇 개가 화면 밖으로 넘쳐 못 보는 일이 없다
        let limited = ContextMenuGeometry.limited(natural: size, visible: visible)
        if limited.height < size.height {
            hosting = NSHostingView(rootView: ContextMenuView(model: model, label: label, height: limited.height))
            hosting.sizingOptions = [.intrinsicContentSize]
            size = limited
        }
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

    /// 메뉴가 듣는 키
    enum Key: Equatable {
        case up, down, activate, escape
    }

    /// 키 → 메뉴 키 (순수). 방향키는 `.numericPad` · `.function`이 함께 오고 키패드 Enter는 `.numericPad`가 온다: 이 두 비트를 지운 뒤 비교한다
    /// (`EdgeReviewKeys`와 같다). ⌘ · ⌃ · ⌥ · ⇧가 함께면 메뉴 키가 아니다
    nonisolated static func key(keyCode: Int, flags: NSEvent.ModifierFlags) -> Key? {
        let flags = flags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        guard flags.isEmpty else { return nil }
        switch keyCode {
        case kVK_UpArrow: return .up
        case kVK_DownArrow: return .down
        case kVK_Return, kVK_ANSI_KeypadEnter: return .activate
        case kVK_Escape: return .escape
        default: return nil
        }
    }

    /// 메뉴 창이 키 창일 때 그 창으로 온 키만: ↑ ↓ Return Esc. 다른 창의 Return을 가로채지 않는다
    func handle(_ event: NSEvent) -> Bool {
        guard let model, let panel, event.window === panel, let key = Self.key(keyCode: Int(event.keyCode), flags: event.modifierFlags) else { return false }
        switch key {
        case .up: model.move(-1)
        case .down: model.move(1)
        case .activate: model.activate()
        case .escape: dismiss()
        }
        return true
    }

    private func outsideClick(_ event: NSEvent) {
        guard let panel, event.window !== panel else { return }
        dismiss()
    }
}
#endif
