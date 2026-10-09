import SwiftUI

/// Rail item (0.2.0 디자인 시스템 Molecules): 레일의 일 하나. 32pt 정사각형(`radius-md`) 안의 `ActivityRing`이고, 누르면 그 일을 연다.
/// 접근성 이름 · 툴팁은 "제목 · 상태 · 활동" (상태 = `TaskStatusMark`의 To Do · In Progress · Done, 활동 = 링의 말 또는 활동 글).
/// 숨은 레일에서는 링이 14pt로 노치 가운데에 있고, 펼친 레일에서는 18pt(×1.286)로 자란다. 자리 · 크기는 바뀌지 않고 transform만 바뀐다.
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
    let action: () -> Void

    /// - notchShift: 숨은 레일에서 링을 노치 가운데로 옮기는 거리(왼쪽, pt). 레일이 펼치면 0
    /// - highlighted: 호버 · 지금 연 일 · 열린 메뉴 (`bezel/hover`로 칸 전체를 칠한다, 펼친 레일에서만)
    public init(
        kind: ActivityRing.Kind, title: String, state: TaskStatusMark.State, activity: String,
        expanded: Bool, highlighted: Bool = false, notchShift: CGFloat = 0, reduceMotion: Bool = false,
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
        self.action = action
    }

    /// "Title · State · Activity"
    nonisolated public static func accessibilityLabel(title: String, state: TaskStatusMark.State, activity: String) -> String {
        "\(title) · \(state.label) · \(activity)"
    }

    public var body: some View {
        Button(action: action) {
            ActivityRing(kind, size: .small, reduceMotion: reduceMotion)
                .scaleEffect(expanded ? 18.0 / 14.0 : 1)
                .offset(x: expanded ? 0 : -notchShift)
                .frame(width: Self.side, height: Self.side)
                .background {
                    RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous)
                        .fill(expanded && highlighted ? TFColor.bezelHover : .clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 버튼의 이름이 링의 이름을 덮는다 (누르기 동작은 버튼 그대로)
        .accessibilityLabel(Self.accessibilityLabel(title: title, state: state, activity: activity))
    }
}

/// 레일의 고정 칸 (All work · Chats · More): 32pt 정사각형의 Lucide 글리프, `bezel/ink`
public struct RailButton: View {
    let icon: TFIcon
    let label: String
    let highlighted: Bool
    let action: () -> Void

    public init(icon: TFIcon, label: String, highlighted: Bool = false, action: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.highlighted = highlighted
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            icon.image()
                .foregroundStyle(TFColor.bezelInk)
                .frame(width: RailItem.side, height: RailItem.side)
                .background {
                    RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous)
                        .fill(highlighted ? TFColor.bezelHover : .clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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
