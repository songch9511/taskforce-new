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
    private(set) var model: TargetMenuModel?
    private var monitors: [Any] = []
    private var resignObserver: NSObjectProtocol?
    private var pillFrame: CGRect = .zero
    private var visibleFrame: CGRect = .zero
    private var onClose: (() -> Void)?
    private weak var parent: NSWindow?
    /// 창을 실제 화면에 올리는가 (시험은 끈다: 창만 만들고 올리지 않는다)
    var shows = true

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
        let hosting = MenuHostingView(rootView: TargetMenuView(model: model))
        // 크기는 내용이 정한다 (줄 수 · 가장 긴 줄 · 읽는 중 줄). `[]`이면 fittingSize가 0이 되어 창이 자리를 잘못 잡는다
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
        visibleFrame = visible
        panel.setFrame(Self.frame(size: size, pill: pill, visible: visible), display: true)
        self.panel = panel
        self.parent = parent
        // 읽기가 끝나 줄이 늘면 아래 끝(알약 위 6pt)은 그대로 두고 위로 자란다
        hosting.onContentSizeChange = { [weak self] in self?.resizeToContent() }
        // 키를 잃으면(다른 창이 키가 됨 · ⌘Tab) 닫는다: 남은 메뉴가 다른 창의 키를 가로채지 않게
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        if shows {
            parent.addChildWindow(panel, ordered: .above)
            panel.makeKeyAndOrderFront(nil)
            installMonitors(parent: parent)
        }
    }

    private func resizeToContent() {
        guard let panel, let hosting = panel.contentView as? MenuHostingView else { return }
        let size = hosting.intrinsicContentSize
        guard size.width > 0, size.height > 0 else { return }
        let frame = Self.frame(size: size, pill: pillFrame, visible: visibleFrame)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    func dismiss(notify: Bool = true) {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
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

    /// 메뉴 창이 키 창일 때 그 창으로 온 키만 처리한다: 다른 창의 Return을 가로채지 않는다
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
/// 내용 크기가 바뀌면 알리는 호스팅 뷰 (메뉴 창이 새 크기로 자란다)
private final class MenuHostingView: NSHostingView<TargetMenuView> {
    var onContentSizeChange: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onContentSizeChange?()
    }
}
#endif
