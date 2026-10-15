import SwiftUI
import TaskforceKit

extension ActivityRing.Kind {
    /// 세션의 링 → 링 부품의 종류 (Kit은 그리지 않는다)
    public init(_ ring: AgentSessionRing) {
        switch ring {
        case .needsYou: self = .needsYou
        case .unreachable: self = .unreachable
        case .stopping: self = .stopping
        case .running: self = .running
        case .done: self = .done
        case .waiting: self = .waiting
        case .idle: self = .idle
        }
    }
}

/// 탭 항목 하나 (세션 하나)
public struct SessionTabItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let ring: ActivityRing.Kind
    /// "{이름} · {말}"
    public let accessibilityName: String
    public let current: Bool

    public init(id: UUID, ring: ActivityRing.Kind, accessibilityName: String, current: Bool) {
        self.id = id
        self.ring = ring
        self.accessibilityName = accessibilityName
        self.current = current
    }

    public init(_ item: AgentSessionItem, current: Bool) {
        self.init(id: item.id, ring: .init(item.ring ?? .idle), accessibilityName: item.tabAccessibilityName, current: current)
    }
}

/// SessionTab의 수치 (DS SessionTab README · `bundle.css` `.tf-stab`). 순수 값이라 시험으로 고정한다
public enum SessionTabGeometry {
    public struct Layout: Equatable, Sendable {
        public let item: CGFloat
        public let ring: CGFloat
        public let top: CGFloat
        public let leading: CGFloat
        public let bottom: CGFloat
        public let trailing: CGFloat
        public let spacing: CGFloat
        public let radius: CGFloat
        public let itemRadius: CGFloat

        public var width: CGFloat { leading + item + trailing }

        /// 항목 `count`개(More · New 포함)가 쌓인 몸통 높이
        public func height(count: Int) -> CGFloat {
            top + CGFloat(count) * item + CGFloat(max(count - 1, 0)) * spacing + bottom
        }
    }

    /// 접힘: 20 항목 · 링 12 · 안쪽 6/3/6/1 → 폭 24 · 모서리 10 · 항목 모서리 6
    public static let collapsed = Layout(item: 20, ring: 12, top: 6, leading: 3, bottom: 6, trailing: 1, spacing: 2, radius: 10, itemRadius: 6)
    /// 펼침: 28 항목 · 링 18 · 안쪽 4 → 폭 36 · 모서리 12 · 항목 모서리 8
    public static let expanded = Layout(item: 28, ring: 18, top: 4, leading: 4, bottom: 4, trailing: 4, spacing: 2, radius: 12, itemRadius: 8)
    /// 패널의 평평한 가장자리로 이어 주는 오목한 모서리
    public static let fillet: CGFloat = 10
    /// 패널과 겹치는 반 점: 두 반투명 면 사이에 이음선이 비치지 않게 (DS `right: calc(100% - .5px)`)
    public static let overlap: CGFloat = 0.5
    /// 펼침 애니메이션: 폭 · 안쪽 · 크기는 움직이지 않고 불투명도만 220ms
    public static let crossfade: Double = 0.22

    /// 탭이 차지하는 칸의 크기 (필렛 포함, 펼침 기준): 폭 36, 높이 = 몸통 + 위아래 필렛
    public static func frameSize(count: Int) -> CGSize {
        CGSize(width: expanded.width, height: expanded.height(count: count) + 2 * fillet)
    }
}

/// 탭 몸통 + 위아래 오목 필렛: 오른쪽이 패널의 평평한 왼쪽 가장자리에 붙어 한 모양을 이룬다. 왼쪽 두 모서리만 둥글다
struct SessionTabShape: Shape {
    let bodyWidth: CGFloat
    let bodyHeight: CGFloat
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let fillet = SessionTabGeometry.fillet
        let right = rect.maxX + SessionTabGeometry.overlap
        let left = right - SessionTabGeometry.overlap - bodyWidth
        let top = rect.minY + fillet
        let bottom = top + bodyHeight
        var path = Path()
        // 몸통: 왼쪽 위 · 아래만 둥글다
        path.move(to: CGPoint(x: left + radius, y: top))
        path.addLine(to: CGPoint(x: right, y: top))
        path.addLine(to: CGPoint(x: right, y: bottom))
        path.addLine(to: CGPoint(x: left + radius, y: bottom))
        path.addArc(center: CGPoint(x: left + radius, y: bottom - radius), radius: radius, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: left, y: top + radius))
        path.addArc(center: CGPoint(x: left + radius, y: top + radius), radius: radius, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        // 위 필렛: 상자 [right-10, right] × [top-10, top], 중심 (right-10, top-10)의 원 바깥
        let topBox = CGRect(x: right - SessionTabGeometry.overlap - fillet, y: top - fillet, width: fillet, height: fillet)
        path.move(to: CGPoint(x: topBox.minX, y: topBox.maxY))
        path.addLine(to: CGPoint(x: right, y: topBox.maxY))
        path.addLine(to: CGPoint(x: right, y: topBox.minY))
        path.addArc(center: CGPoint(x: topBox.minX, y: topBox.minY), radius: fillet, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.closeSubpath()
        // 아래 필렛: 상자 [right-10, right] × [bottom, bottom+10], 중심 (right-10, bottom+10)의 원 바깥
        let bottomBox = CGRect(x: right - SessionTabGeometry.overlap - fillet, y: bottom, width: fillet, height: fillet)
        path.move(to: CGPoint(x: bottomBox.minX, y: bottomBox.minY))
        path.addLine(to: CGPoint(x: right, y: bottomBox.minY))
        path.addLine(to: CGPoint(x: right, y: bottomBox.maxY))
        path.addArc(center: CGPoint(x: bottomBox.minX, y: bottomBox.maxY), radius: fillet, startAngle: .degrees(0), endAngle: .degrees(-90), clockwise: true)
        path.closeSubpath()
        return path
    }
}

/// SessionTab (0.2.0 디자인 시스템 Organisms, OA U2): 패널의 왼쪽 가장자리에 붙은 세션 띠. 열린 프로젝트 · 이슈의 세션만 (전체 세션이 아니다).
/// - 패널과 같은 재료, 왼쪽 두 모서리 10(펼침 12), 오른쪽은 패널에 붙고 위아래 10pt 오목 필렛으로 한 모양. 그림자는 창이 그린다 (`shadow-float`)
/// - 접힘: 20pt 항목 · 링 12 · 폭 24. 호버 · 키보드 포커스에서 펼침: 28 · 링 18 · 폭 36. **폭 · 안쪽 · 크기는 움직이지 않는다**: 두 모양을 불투명도로 바꾼다
///   (220ms, `TFMotion.ease`). 움직임 줄이기면 바로 바꾼다
/// - 링은 `ActivityRing` 빛 위(`ground: .light`). 현재 세션은 `bg/selected`. 맨 뒤 `+`(New session), 그 앞에 More(`ellipsis`, 화면에 개수 없음)
/// - 항목 이름 "{세션 이름} · {말}", 그룹 이름 "Sessions", `+` "New session", More "{n} more sessions"
public struct SessionTab: View {
    let items: [SessionTabItem]
    let moreLabel: String?
    let forceExpanded: Bool
    let reduceMotion: Bool
    let onOpen: (UUID) -> Void
    let onMore: () -> Void
    let onNew: () -> Void

    @State private var hovering = false
    @FocusState private var focusedIndex: Int?

    nonisolated public static let groupLabel = "Sessions"
    nonisolated public static let newLabel = "New session"

    public init(
        items: [SessionTabItem], moreLabel: String? = nil, expanded: Bool = false, reduceMotion: Bool = false, onOpen: @escaping (UUID) -> Void,
        onMore: @escaping () -> Void = {}, onNew: @escaping () -> Void
    ) {
        self.items = items
        self.moreLabel = moreLabel
        self.forceExpanded = expanded
        self.reduceMotion = reduceMotion
        self.onOpen = onOpen
        self.onMore = onMore
        self.onNew = onNew
    }

    private var isExpanded: Bool { forceExpanded || hovering || focusedIndex != nil }
    /// 몸통에 쌓이는 칸: 세션들 · More · New
    private var count: Int { items.count + (moreLabel == nil ? 0 : 1) + 1 }

    public var body: some View {
        let size = SessionTabGeometry.frameSize(count: count)
        ZStack(alignment: .topTrailing) {
            layer(SessionTabGeometry.collapsed, expanded: false)
                .opacity(isExpanded ? 0 : 1)
                .allowsHitTesting(!isExpanded)
                .accessibilityHidden(true)
            layer(SessionTabGeometry.expanded, expanded: true)
                .opacity(isExpanded ? 1 : 0)
                .allowsHitTesting(isExpanded)
        }
        .frame(width: size.width, height: size.height, alignment: .topTrailing)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : TFMotion.ease(SessionTabGeometry.crossfade), value: isExpanded)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.groupLabel)
    }

    private func layer(_ layout: SessionTabGeometry.Layout, expanded: Bool) -> some View {
        let bodyHeight = layout.height(count: count)
        let frameSize = SessionTabGeometry.frameSize(count: count)
        return ZStack(alignment: .topTrailing) {
            // 면: 패널과 같은 재료
            ZStack {
                SessionTabShape(bodyWidth: layout.width, bodyHeight: bodyHeight, radius: layout.radius).fill(.ultraThinMaterial)
                SessionTabShape(bodyWidth: layout.width, bodyHeight: bodyHeight, radius: layout.radius).fill(TFColor.bgPanel)
            }
            VStack(spacing: layout.spacing) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    entry(layout, expanded: expanded) {
                        Button { onOpen(item.id) } label: {
                            ActivityRing(item.ring, size: expanded ? .medium : .small, ground: .light, reduceMotion: reduceMotion)
                                .frame(width: layout.item, height: layout.item)
                                .background(item.current ? TFColor.bgSelected : Color.clear, in: RoundedRectangle(cornerRadius: layout.itemRadius, style: .continuous))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.accessibilityName)
                        .accessibilityAddTraits(item.current ? .isSelected : [])
                    }
                    .modifier(FocusIndex(index: index, expanded: expanded, focus: $focusedIndex))
                }
                if let moreLabel {
                    entry(layout, expanded: expanded) {
                        Button(action: onMore) { glyph(.more, layout) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(moreLabel)
                    }
                    .modifier(FocusIndex(index: items.count, expanded: expanded, focus: $focusedIndex))
                }
                entry(layout, expanded: expanded) {
                    Button(action: onNew) { glyph(.addTask, layout) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Self.newLabel)
                }
                .modifier(FocusIndex(index: items.count + (moreLabel == nil ? 0 : 1), expanded: expanded, focus: $focusedIndex))
            }
            .padding(EdgeInsets(top: layout.top, leading: layout.leading, bottom: layout.bottom, trailing: layout.trailing))
            .frame(width: layout.width, alignment: .top)
            .padding(.top, SessionTabGeometry.fillet)
        }
        .frame(width: frameSize.width, height: frameSize.height, alignment: .topTrailing)
    }

    /// 한 칸: 접힘 층의 칸은 키보드 포커스를 받지 않는다 (펼침 층의 같은 칸이 받는다)
    private func entry<Content: View>(_ layout: SessionTabGeometry.Layout, expanded: Bool, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(width: layout.item, height: layout.item)
            .focusable(expanded)
    }

    /// 펼침 층의 칸만 키보드 포커스를 받는다 (접힘 층은 포커스 상태에 묶지 않는다)
    private struct FocusIndex: ViewModifier {
        let index: Int
        let expanded: Bool
        var focus: FocusState<Int?>.Binding

        @ViewBuilder
        func body(content: Content) -> some View {
            if expanded { content.focused(focus, equals: index) } else { content }
        }
    }

    private func glyph(_ icon: TFIcon, _ layout: SessionTabGeometry.Layout) -> some View {
        icon.image(size: layout.ring)
            .foregroundStyle(TFColor.textSecondary)
            .frame(width: layout.item, height: layout.item)
            .contentShape(Rectangle())
    }
}

#Preview("SessionTab") {
    let items = [
        SessionTabItem(id: UUID(), ring: .running, accessibilityName: "Pricing copy draft · Running", current: true),
        SessionTabItem(id: UUID(), ring: .needsYou, accessibilityName: "Lifetime plan section · Needs your answer", current: false),
        SessionTabItem(id: UUID(), ring: .idle, accessibilityName: "Trial wording · Idle", current: false),
    ]
    HStack(alignment: .top, spacing: 40) {
        ZStack(alignment: .topTrailing) {
            Rectangle().fill(TFColor.bgPanel).frame(width: 200, height: 300).padding(.leading, 36)
            SessionTab(items: items, onOpen: { _ in }, onNew: {}).padding(.top, 30)
        }
        ZStack(alignment: .topTrailing) {
            Rectangle().fill(TFColor.bgPanel).frame(width: 200, height: 300).padding(.leading, 36)
            SessionTab(items: items, moreLabel: "3 more sessions", expanded: true, onOpen: { _ in }, onNew: {}).padding(.top, 30)
        }
    }
    .padding(24)
    .background(Color.gray.opacity(0.3))
}
