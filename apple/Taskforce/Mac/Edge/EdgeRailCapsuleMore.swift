#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

/// More 카드의 호스팅 뷰: VoiceOver에는 "메뉴"다 (이름은 레일 "More"). 안의 줄은 단추로 읽힌다
final class EdgeRailMoreCardHostingView: NSHostingView<RailMoreCard> {
    var spokenLabel = ""

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .menu }
    override func accessibilityLabel() -> String? { spokenLabel }
}

/// 캡슐 레일의 More 카드 창 (OA U3 16.1, DS EdgeRail "More open"): 게이트 켜짐에서 ⋯가 macOS 기본 메뉴(NSMenu) 대신 여는 DS 카드.
/// 셋째 캡슐 왼쪽 10pt, 아래 끝은 그 캡슐과 같다 (`RailMoreCardGeometry`). 창은 열리면 키 창이 되어 호버 · 클릭을 받고(앱이 활성이 아니어도),
/// ↑ ↓ Return Esc는 그 창이 키 창일 때 그 창의 키만 처리한다 (`EdgeContextMenu.key`와 같은 규칙, 줄 이동 · 고름은 `ContextMenuModel`).
/// 바깥 클릭 · 키를 잃음 · 하나를 고름 · Esc로 닫고, 닫히면 키를 부모 창에 돌려주며 ⋯에게 접근성 포커스를 돌려준다(`onClose`).
/// 게이트 꺼짐 · Release의 ⋯ 메뉴는 그대로 `NSMenu`다 (`EdgeRailPanelController.showMore`)
@MainActor
final class EdgeRailMoreCard {
    private var panel: EdgeMenuPanel?
    private(set) var model: ContextMenuModel?
    private var monitors: [Any] = []
    private var resignObserver: NSObjectProtocol?
    private weak var parent: NSWindow?
    private var onClose: (() -> Void)?
    /// 창을 실제 화면에 올리는가 (시험은 끈다)
    var shows = true
    /// ⋯ 위에서 카드를 닫은 바로 그 클릭이 ⋯를 눌러 카드를 곧바로 다시 열지 않게: 그 클릭을 삼킨다 (카드 밖 클릭을 닫음으로만 쓴다)
    var swallowsOutsideClick: (NSEvent) -> Bool = { _ in false }

    var isOpen: Bool { panel != nil }
    var window: NSWindow? { panel }

    /// - capsule: 셋째 캡슐의 화면 좌표 (아래가 0)
    func present(model: ContextMenuModel, label: String, capsule: CGRect, over parent: NSWindow, onClose: @escaping () -> Void) {
        dismiss(notify: false)
        self.model = model
        self.onClose = onClose
        model.onPick = { [weak self] in self?.dismiss() }
        let hosting = EdgeRailMoreCardHostingView(rootView: RailMoreCard(model: model, label: label))
        hosting.spokenLabel = label
        hosting.sizingOptions = [.intrinsicContentSize]
        let size = hosting.intrinsicContentSize
        let visible = (parent.screen ?? NSScreen.main)?.visibleFrame ?? parent.frame
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
        panel.setFrame(RailMoreCardGeometry.frame(size: size, capsule: capsule, visible: visible), display: true)
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
            let swallowed = MainActor.assumeIsolated { self?.outsideClick(event) ?? false }
            return swallowed ? nil : event
        }) {
            monitors.append(click)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }) {
            monitors.append(global)
        }
    }

    /// 카드 창이 키 창일 때 그 창으로 온 키만: ↑ ↓ Return Esc. 다른 창의 Return을 가로채지 않는다
    func handle(_ event: NSEvent) -> Bool {
        guard let model, let panel, event.window === panel, let key = EdgeContextMenu.key(keyCode: Int(event.keyCode), flags: event.modifierFlags) else { return false }
        switch key {
        case .up: model.move(-1)
        case .down: model.move(1)
        case .activate: model.activate()
        case .escape: dismiss()
        }
        return true
    }

    /// 카드 밖 클릭은 카드를 닫는다. ⋯ 위의 클릭이면 클릭을 삼켜 ⋯가 다시 열지 않게 한다 (눌러서 열고 다시 눌러서 닫는 토글)
    @discardableResult
    func outsideClick(_ event: NSEvent) -> Bool {
        guard let panel, event.window !== panel else { return false }
        let swallow = swallowsOutsideClick(event)
        dismiss()
        return swallow
    }
}
#endif
