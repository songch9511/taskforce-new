import SwiftUI

/// Rail item (0.2.0 디자인 시스템 Molecules): 레일의 일 하나. 32pt 정사각형(`radius-md`) 안의 `ActivityRing`이고, 누르면 그 일을 연다.
/// 접근성 이름 · 툴팁은 "제목 · 상태 · 활동" (상태 = `TaskStatusMark`의 To Do · In Progress · Done, 활동 = 링의 말 또는 활동 글).
/// 숨은 레일에서는 링이 14pt로 노치 가운데에 있고, 펼친 레일에서는 18pt(×1.286)로 자란다. 자리 · 크기는 바뀌지 않고 transform만 바뀐다.
/// **캡슐 모양**(`look: .capsule`, OA U3): 칸은 원이고 링은 늘 18pt(14 × 1.286)다 — 접힘은 열 전체가 .72배로 줄어 약 13pt가 된다. 노치로 미는 일이 없다.
public struct RailItem: View {
    nonisolated public static let side: CGFloat = 32

    let kind: ActivityRing.Kind
    let title: String
    let state: TaskStatusMark.State
    let activity: String
    let expanded: Bool
    let highlighted: Bool
    let notchShift: CGFloat
    let reduceMotion: Bool
    let look: ActivityRing.Look
    let action: () -> Void

    /// - notchShift: 숨은 레일에서 링을 노치 가운데로 옮기는 거리(왼쪽, pt). 레일이 펼치면 0
    /// - highlighted: 호버 · 지금 연 일 · 열린 메뉴 (`bezel/hover`로 칸 전체를 칠한다, 펼친 레일에서만)
    public init(
        kind: ActivityRing.Kind, title: String, state: TaskStatusMark.State, activity: String,
        expanded: Bool, highlighted: Bool = false, notchShift: CGFloat = 0, reduceMotion: Bool = false, look: ActivityRing.Look = .classic,
        action: @escaping () -> Void
    ) {
        self.kind = kind
        self.title = title
        self.state = state
        self.activity = activity
        self.expanded = expanded
        self.highlighted = highlighted
        self.notchShift = notchShift
        self.reduceMotion = reduceMotion
        self.look = look
        self.action = action
    }

    /// "Title · State · Activity"
    nonisolated public static func accessibilityLabel(title: String, state: TaskStatusMark.State, activity: String) -> String {
        "\(title) · \(state.label) · \(activity)"
    }

    public var body: some View {
        Button(action: action) {
            ActivityRing(kind, size: .small, reduceMotion: reduceMotion, look: look)
                .scaleEffect(look == .capsule ? RailCapsuleMetrics.ringScale : (expanded ? 18.0 / 14.0 : 1))
                .offset(x: look == .capsule ? 0 : (expanded ? 0 : -notchShift))
                .frame(width: Self.side, height: Self.side)
                .background {
                    if look == .capsule {
                        Circle().fill(expanded && highlighted ? TFColor.bezelHover : .clear)
                    } else {
                        RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous)
                            .fill(expanded && highlighted ? TFColor.bezelHover : .clear)
                    }
                }
                .contentShape(look == .capsule ? AnyShape(Circle()) : AnyShape(Rectangle()))
        }
        .buttonStyle(.plain)
        // 버튼의 이름이 링의 이름을 덮는다 (누르기 동작은 버튼 그대로)
        .accessibilityLabel(Self.accessibilityLabel(title: title, state: state, activity: activity))
    }
}

/// 레일의 고정 칸 (All work · Chats · More): 32pt 정사각형의 Lucide 글리프, `bezel/ink`. 캡슐 레일(OA U3)에서는 칸이 원이다 (`circular`)
public struct RailButton: View {
    /// 새것 표시 점 (DS B): 흰 잉크(`bezel/ink`) 7pt에 `bezel` 2pt 테두리, 칸의 오른쪽 위. 색 점 · 숫자 배지는 아니다
    nonisolated public static let dotSize: CGFloat = 7
    nonisolated public static let dotBorder: CGFloat = 2

    let icon: TFIcon
    let label: String
    let highlighted: Bool
    let circular: Bool
    let dot: Bool
    let dotAccessibilityLabel: String?
    let action: () -> Void

    /// - dot: 새것이 있다는 점. 접근성 이름은 `dotAccessibilityLabel`(없으면 `label` 그대로)이 된다 (숫자는 이름에만)
    public init(
        icon: TFIcon, label: String, highlighted: Bool = false, circular: Bool = false, dot: Bool = false, dotAccessibilityLabel: String? = nil, action: @escaping () -> Void
    ) {
        self.icon = icon
        self.label = label
        self.highlighted = highlighted
        self.circular = circular
        self.dot = dot
        self.dotAccessibilityLabel = dotAccessibilityLabel
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            icon.image()
                .foregroundStyle(TFColor.bezelInk)
                .frame(width: RailItem.side, height: RailItem.side)
                .background {
                    if circular {
                        Circle().fill(highlighted ? TFColor.bezelHover : .clear)
                    } else {
                        RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous)
                            .fill(highlighted ? TFColor.bezelHover : .clear)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if dot {
                        Circle()
                            .fill(TFColor.bezelInk)
                            .frame(width: Self.dotSize, height: Self.dotSize)
                            .overlay(Circle().strokeBorder(TFColor.bezelBase, lineWidth: Self.dotBorder).frame(width: Self.dotSize + 2 * Self.dotBorder, height: Self.dotSize + 2 * Self.dotBorder))
                            .offset(x: -3, y: 4)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(circular ? AnyShape(Circle()) : AnyShape(Rectangle()))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dot ? (dotAccessibilityLabel ?? label) : label)
    }
}

#Preview("Rail items") {
    HStack(spacing: 24) {
        VStack(spacing: 2) {
            ForEach(ActivityRing.Kind.allCases, id: \.self) { kind in
                RailItem(kind: kind, title: "Pricing page", state: .inProgress, activity: kind.accessibilityLabel, expanded: false, notchShift: 9.5) {}
            }
        }
        VStack(spacing: 2) {
            ForEach(ActivityRing.Kind.allCases, id: \.self) { kind in
                RailItem(kind: kind, title: "Pricing page", state: .inProgress, activity: kind.accessibilityLabel, expanded: true, highlighted: kind == .running) {}
            }
            RailButton(icon: .allWork, label: "All work") {}
            RailButton(icon: .talk, label: "Chats") {}
            RailButton(icon: .more, label: "More") {}
        }
    }
    .padding(16)
    .background(TFColor.bezelBase)
}
