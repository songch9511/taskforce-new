#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

/// EdgeRail의 자리 (디자인 README › Layout · EdgeRail CSS). 창 좌표, 위가 0.
/// 창은 화면 오른쪽 모서리에 붙은 44pt 폭이고, 숨은 레일은 오른쪽으로 19pt 밀려 25pt 노치만 화면에 남는다(나머지는 화면 밖).
/// 그리기와 포인터 판정이 같은 값을 쓴다. 모양은 바뀌지 않고 숨김 · 펼침은 가로 이동과 아래쪽 펼침뿐이다.
struct EdgeRailLayout: Equatable {
    static let railWidth: CGFloat = 44
    static let notchWidth: CGFloat = 25
    static let idleWidth: CGFloat = 6
    static let idleHeight: CGFloat = 36
    static let item: CGFloat = RailItem.side
    static let gap: CGFloat = 2
    static let padding: CGFloat = 6
    static let corner: CGFloat = 12
    static let idleCorner: CGFloat = 4
    /// 베젤로 이어지는 오목한 모서리
    static let fillet: CGFloat = 10
    /// 구분선: 1pt + 위아래 6
    static let ruleBlock: CGFloat = 13
    /// 화면 위에서 레일 위 모서리까지 (디자인 EdgeRail `top` 기본값)
    static let topFromScreen: CGFloat = 120
    /// 창 안에서 레일이 시작하는 높이 (위 오목 모서리 자리)
    static let top: CGFloat = fillet
    /// 가장 크게 펼친 레일 (일 넷 + 구분선 + 고정 칸 셋) + 위아래 오목 모서리
    static let windowHeight: CGFloat = top + padding + 4 * (item + gap) + ruleBlock + gap + 3 * item + 2 * gap + padding + fillet

    let notchCount: Int
    let restCount: Int
    let expanded: Bool
    let idle: Bool

    /// 숨은 레일이 밀려난 거리
    var shift: CGFloat {
        if expanded { return 0 }
        return Self.railWidth - (idle ? Self.idleWidth : Self.notchWidth)
    }

    /// 노치 링을 노치 가운데로 옮기는 거리
    var notchShift: CGFloat { expanded ? 0 : shift / 2 }

    private var itemX: CGFloat { shift + (Self.railWidth - Self.item) / 2 }

    func notchFrame(_ index: Int) -> CGRect {
        CGRect(x: itemX, y: Self.top + Self.padding + CGFloat(index) * (Self.item + Self.gap), width: Self.item, height: Self.item)
    }

    /// 펼친 부분이 시작하는 높이 (노치 링 아래, 간격 하나)
    private var moreTop: CGFloat { Self.top + Self.padding + CGFloat(notchCount) * (Self.item + Self.gap) }

    func restFrame(_ index: Int) -> CGRect {
        CGRect(x: itemX, y: moreTop + CGFloat(index) * (Self.item + Self.gap), width: Self.item, height: Self.item)
    }

    var ruleY: CGFloat { moreTop + CGFloat(restCount) * (Self.item + Self.gap) + 6 }

    func controlFrame(_ control: EdgeShellModel.Control) -> CGRect {
        let index = CGFloat(EdgeShellModel.Control.allCases.firstIndex(of: control) ?? 0)
        let first = moreTop + CGFloat(restCount) * (Self.item + Self.gap) + Self.ruleBlock + Self.gap
        return CGRect(x: itemX, y: first + index * (Self.item + Self.gap), width: Self.item, height: Self.item)
    }

    /// 펼친 부분의 높이 (접히면 0)
    var moreHeight: CGFloat {
        guard expanded else { return 0 }
        return CGFloat(restCount) * (Self.item + Self.gap) + Self.ruleBlock + Self.gap + 3 * Self.item + 2 * Self.gap
    }

    /// 검은 레일 모양 (창 좌표, 화면 밖으로 밀린 부분 포함)
    var railRect: CGRect {
        if idle {
            return CGRect(x: shift, y: Self.top, width: Self.railWidth, height: Self.idleHeight)
        }
        let height = Self.padding + CGFloat(notchCount) * (Self.item + Self.gap) + moreHeight + Self.padding
        return CGRect(x: shift, y: Self.top, width: Self.railWidth, height: height)
    }

    /// 포인터가 레일 위인지 (화면에 보이는 부분만)
    var hitRect: CGRect {
        railRect.intersection(CGRect(x: 0, y: 0, width: Self.railWidth, height: Self.windowHeight))
    }

    /// 포인터 아래의 칸
    func hit(_ point: CGPoint, slots: [RailEntry]) -> (item: UUID?, control: EdgeShellModel.Control?) {
        guard hitRect.contains(point), !idle else { return (nil, nil) }
        for (index, entry) in slots.enumerated() {
            let frame = index < notchCount ? notchFrame(index) : restFrame(index - notchCount)
            if index >= notchCount, !expanded { continue }
            if frame.contains(point) { return (entry.id, nil) }
        }
        guard expanded else { return (nil, nil) }
        for control in EdgeShellModel.Control.allCases where controlFrame(control).contains(point) {
            return (nil, control)
        }
        return (nil, nil)
    }
}

/// 위 · 아래 오목 모서리: 레일의 가장자리를 베젤(화면 오른쪽 모서리)로 이어 준다 (CSS radial-gradient의 바깥 부분)
struct RailFillet: Shape {
    enum Edge { case top, bottom }
    let edge: Edge

    func path(in rect: CGRect) -> Path {
        // 원 1/4을 베지어로 (κ = 0.5523)
        let r = rect.width
        let k = 0.5523 * r
        var path = Path()
        switch edge {
        case .top:
            // 중심 (0,0)의 원 바깥: 오른쪽 아래가 채워진다
            path.move(to: CGPoint(x: r, y: 0))
            path.addLine(to: CGPoint(x: r, y: r))
            path.addLine(to: CGPoint(x: 0, y: r))
            path.addCurve(to: CGPoint(x: r, y: 0), control1: CGPoint(x: k, y: r), control2: CGPoint(x: r, y: k))
        case .bottom:
            // 중심 (0, r)의 원 바깥: 오른쪽 위가 채워진다
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: r, y: 0))
            path.addLine(to: CGPoint(x: r, y: r))
            path.addCurve(to: CGPoint(x: 0, y: 0), control1: CGPoint(x: r, y: r - k), control2: CGPoint(x: k, y: 0))
        }
        path.closeSubpath()
        return path.offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

/// 레일 (디자인 EdgeRail): 늘 `bezel` 검정. 로고 · 개수 · 트레이 아이콘 · 색 점 없음. 패널에는 탐색 막대가 없고 이것이 유일한 탐색이다.
struct EdgeRailView: View {
    @Bindable var shell: EdgeShellModel
    let onMore: (CGRect) -> Void

    private var layout: EdgeRailLayout {
        EdgeRailLayout(notchCount: shell.notch.count, restCount: shell.rest.count, expanded: shell.isExpanded, idle: shell.isIdle)
    }

    private var slide: Animation? { TFMotion.move(TFMotion.railSlide, reduceMotion: shell.reduceMotion) }

    var body: some View {
        let layout = layout
        let rail = layout.railRect
        ZStack(alignment: .topLeading) {
            // 오목 모서리는 화면 모서리에 붙어 있다 (밀리지 않는다)
            RailFillet(edge: .top)
                .fill(TFColor.bezelBase)
                .frame(width: EdgeRailLayout.fillet, height: EdgeRailLayout.fillet)
                .offset(x: EdgeRailLayout.railWidth - EdgeRailLayout.fillet, y: rail.minY - EdgeRailLayout.fillet)
            RailFillet(edge: .bottom)
                .fill(TFColor.bezelBase)
                .frame(width: EdgeRailLayout.fillet, height: EdgeRailLayout.fillet)
                .offset(x: EdgeRailLayout.railWidth - EdgeRailLayout.fillet, y: rail.maxY)
            UnevenRoundedRectangle(
                topLeadingRadius: layout.idle ? EdgeRailLayout.idleCorner : EdgeRailLayout.corner,
                bottomLeadingRadius: layout.idle ? EdgeRailLayout.idleCorner : EdgeRailLayout.corner,
                style: .continuous
            )
            .fill(TFColor.bezelBase)
            .frame(width: rail.width, height: rail.height)
            .offset(x: rail.minX, y: rail.minY)
            if !layout.idle {
                content(layout)
                    .mask(alignment: .topLeading) {
                        Rectangle()
                            .frame(width: EdgeRailLayout.railWidth, height: rail.height)
                            .offset(x: rail.minX, y: rail.minY)
                    }
            }
        }
        .frame(width: EdgeRailLayout.railWidth, height: EdgeRailLayout.windowHeight, alignment: .topLeading)
        .animation(slide, value: layout)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(shell.railAccessibilityLabel)
    }

    @ViewBuilder
    private func content(_ layout: EdgeRailLayout) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(shell.notch.enumerated()), id: \.element.id) { index, entry in
                item(entry, layout: layout).offset(x: layout.notchFrame(index).minX, y: layout.notchFrame(index).minY)
            }
            Group {
                ForEach(Array(shell.rest.enumerated()), id: \.element.id) { index, entry in
                    item(entry, layout: layout).offset(x: layout.restFrame(index).minX, y: layout.restFrame(index).minY)
                }
                Rectangle()
                    .fill(TFColor.bezelTrack)
                    .frame(width: 18, height: 1)
                    .offset(x: layout.shift + (EdgeRailLayout.railWidth - 18) / 2, y: layout.ruleY)
                    .accessibilityHidden(true)
                ForEach(EdgeShellModel.Control.allCases, id: \.self) { control in
                    let frame = layout.controlFrame(control)
                    RailButton(icon: icon(control), label: control.label, highlighted: highlighted(control)) {
                        switch control {
                        case .allWork: shell.openAllWork()
                        case .chats: shell.openChats()
                        case .more: onMore(frame)
                        }
                    }
                    .offset(x: frame.minX, y: frame.minY)
                    .accessibilityHidden(!layout.expanded)
                }
            }
            .opacity(layout.expanded ? 1 : 0)
            .animation(TFMotion.ease(TFMotion.ringFade), value: layout.expanded)
        }
        .frame(width: EdgeRailLayout.railWidth, height: EdgeRailLayout.windowHeight, alignment: .topLeading)
    }

    private func item(_ entry: RailEntry, layout: EdgeRailLayout) -> some View {
        RailItem(
            kind: entry.kind, title: entry.title, state: entry.state, activity: entry.activity, expanded: layout.expanded,
            highlighted: entry.id == shell.hoveredID || (shell.panelOpen && entry.id == shell.currentID),
            notchShift: layout.notchShift, reduceMotion: shell.reduceMotion
        ) {
            shell.open(itemID: entry.id)
        }
        .transition(.opacity.animation(TFMotion.ease(TFMotion.ringFade)))
    }

    private func icon(_ control: EdgeShellModel.Control) -> TFIcon {
        switch control {
        case .allWork: .allWork
        case .chats: .talk
        case .more: .more
        }
    }

    private func highlighted(_ control: EdgeShellModel.Control) -> Bool {
        if control == .more { return shell.menuOpen || shell.hoveredControl == .more }
        if shell.hoveredControl == control { return true }
        guard shell.panelOpen else { return false }
        return control == .allWork ? shell.view == .allWork && shell.currentID == nil : control == .chats && shell.view == .chats
    }
}

/// 레일 창의 호스팅 뷰: 앱이 비활성이어도 포인터를 따라간다 (`activeAlways`). 투명한 곳의 클릭은 아래 창으로 지나간다.
final class RailHostingView: NSHostingView<EdgeRailView> {
    var onPointer: ((CGPoint?) -> Void)?
    private var tracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        report(event)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        report(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointer?(nil)
    }

    private func report(_ event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        // 위가 0인 레일 좌표로
        onPointer?(isFlipped ? local : CGPoint(x: local.x, y: bounds.height - local.y))
    }
}

/// 키를 받지 않는 창 (레일 · 툴팁). 다른 앱의 키 입력을 빼앗지 않는다
final class EdgePassivePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 레일 창: 화면 오른쪽 모서리, 위에서 120pt. 모든 Space · 전체 화면 앱 위에 머문다.
@MainActor
final class EdgeRailPanelController {
    let shell: EdgeShellModel
    let panel: EdgePassivePanel
    private let hosting: RailHostingView
    private let tooltip: RailTooltipController
    var onConnections: () -> Void = { SettingsOpener.open(.connections) }
    var onSettings: () -> Void = { SettingsOpener.open(.account) }

    init(shell: EdgeShellModel) {
        self.shell = shell
        panel = EdgePassivePanel(
            contentRect: NSRect(x: 0, y: 0, width: EdgeRailLayout.railWidth, height: EdgeRailLayout.windowHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        tooltip = RailTooltipController(shell: shell)
        var openMore: (CGRect) -> Void = { _ in }
        hosting = RailHostingView(rootView: EdgeRailView(shell: shell, onMore: { openMore($0) }))
        hosting.sizingOptions = []
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = hosting
        hosting.onPointer = { [weak self] point in self?.pointer(point) }
        openMore = { [weak self] frame in self?.showMore(from: frame) }
    }

    /// 레일이 붙는 화면 (메뉴 막대가 있는 화면)
    static var screen: NSScreen? { NSScreen.screens.first ?? NSScreen.main }

    /// 레일 위 모서리 (화면 좌표, 아래가 0)
    static func railTop(on screen: NSScreen) -> CGFloat {
        screen.frame.maxY - EdgeRailLayout.topFromScreen
    }

    func show() {
        guard let screen = Self.screen else { return }
        let top = Self.railTop(on: screen) + EdgeRailLayout.top
        panel.setFrame(
            NSRect(x: screen.frame.maxX - EdgeRailLayout.railWidth, y: top - EdgeRailLayout.windowHeight,
                   width: EdgeRailLayout.railWidth, height: EdgeRailLayout.windowHeight),
            display: true
        )
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
        tooltip.hide()
    }

    private var layout: EdgeRailLayout {
        EdgeRailLayout(notchCount: shell.notch.count, restCount: shell.rest.count, expanded: shell.isExpanded, idle: shell.isIdle)
    }

    private func pointer(_ point: CGPoint?) {
        guard let point else {
            shell.pointer(inside: false)
            tooltip.update(anchor: nil, in: panel)
            return
        }
        let layout = layout
        shell.pointer(inside: layout.hitRect.contains(point))
        let hit = layout.hit(point, slots: shell.slots)
        if let id = hit.item {
            shell.hover(item: id)
        } else {
            shell.hover(control: hit.control)
        }
        let anchor: CGRect? = {
            if let id = hit.item, let index = shell.slots.firstIndex(where: { $0.id == id }) {
                return index < layout.notchCount ? layout.notchFrame(index) : layout.restFrame(index - layout.notchCount)
            }
            return hit.control.map { layout.controlFrame($0) }
        }()
        tooltip.update(anchor: anchor, in: panel)
    }

    /// More: 레일 왼쪽의 메뉴, Connections와 Settings 둘만. 둘 다 Mac 설정 창을 연다
    private func showMore(from frame: CGRect) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let connections = NSMenuItem(title: "Connections", action: #selector(MenuTarget.connections), keyEquivalent: "")
        let settings = NSMenuItem(title: "Settings", action: #selector(MenuTarget.settings), keyEquivalent: "")
        let target = MenuTarget(connections: onConnections, settings: onSettings)
        for (item, icon) in [(connections, TFIcon.connections), (settings, TFIcon.settings)] {
            item.target = target
            item.image = icon.nsImage(size: 14)
            menu.addItem(item)
        }
        shell.setMenuOpen(true)
        tooltip.hide()
        // 메뉴 오른쪽 위를 레일 왼쪽 10pt에 둔다 (화면 오른쪽이라 macOS가 왼쪽으로 펼친다)
        let point = NSPoint(x: frame.minX - 10, y: hosting.isFlipped ? frame.maxY : hosting.bounds.height - frame.maxY)
        menu.popUp(positioning: nil, at: point, in: hosting)
        withExtendedLifetime(target) {}
        shell.setMenuOpen(false)
    }

    private final class MenuTarget: NSObject {
        let onConnections: () -> Void
        let onSettings: () -> Void

        init(connections: @escaping () -> Void, settings: @escaping () -> Void) {
            onConnections = connections
            onSettings = settings
        }

        @objc func connections() { onConnections() }
        @objc func settings() { onSettings() }
    }
}

/// 레일 툴팁: 칸 왼쪽 14pt, "Title · State · Activity" (고정 칸은 "All work ⌘2"). 패널이 열려 있으면 끈다
@MainActor
final class RailTooltipController {
    private let shell: EdgeShellModel
    private let panel: EdgePassivePanel
    private let hosting: NSHostingView<RailTooltipView>

    init(shell: EdgeShellModel) {
        self.shell = shell
        panel = EdgePassivePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        hosting = NSHostingView(rootView: RailTooltipView(title: "", detail: ""))
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = hosting
    }

    func update(anchor: CGRect?, in rail: NSWindow) {
        guard let anchor, let text = shell.tooltip else {
            hide()
            return
        }
        hosting.rootView = RailTooltipView(title: text.title, detail: text.detail)
        let size = hosting.fittingSize
        // 레일 창 좌표(위가 0) → 화면 좌표
        let railFrame = rail.frame
        let midY = railFrame.maxY - anchor.midY
        let origin = NSPoint(x: railFrame.minX + anchor.minX - 14 - size.width, y: midY - size.height / 2)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

struct RailTooltipView: View {
    let title: String
    let detail: String

    var body: some View {
        (Text(title).fontWeight(.semibold).foregroundStyle(TFColor.textPrimary)
            + Text(" ") + Text(detail).foregroundStyle(TFColor.textSecondarySelected))
            .font(TFFont.meta)
            .lineLimit(1)
            .fixedSize()
            .padding(EdgeInsets(top: 6, leading: 9, bottom: 6, trailing: 9))
            .background(TFColor.bgTooltip, in: RoundedRectangle(cornerRadius: TFRadius.sm, style: .continuous))
            .accessibilityHidden(true)
    }
}
#endif
