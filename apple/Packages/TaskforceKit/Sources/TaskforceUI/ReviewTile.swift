import SwiftUI
import TaskforceKit

/// ReviewTile (0.2.0 디자인 시스템 Atoms): 레일 맨 위의 Review 입구. 32pt 타일 하나, 안에 `clipboard-check` 16pt. 숫자 · 점이 화면에 없다 (개수는 접근성 이름에만).
/// - **Needs you**: `marker` 면 + `text-on-marker` 아이콘. 호버는 위에 `bezel-hover`(흰 12%)를 덧칠하고, 마커는 누르거나 열려도 노랑 그대로다
/// - **Changes**: `bezel-hover` 면 (호버 `bezel-track`) + `bezel-ink` 아이콘. 자리를 비운 사이 바뀐 것이 있지만 기다리는 것은 없다
/// - **Open**(Review 화면이 보이는 동안): 타일 밖 2pt에 1.5pt `bezel-ink` 링. **Focus**: 타일 밖 3pt에 2pt `border-accent` 링
/// - 숨은 레일에서는 노치 안 16pt 원(아이콘 10pt)이 되어 둥근 링과 같이 읽히고, 펼치면 정사각 타일로 돌아온다 (자리 · 크기는 레일의 미끄러짐을 따르고 transform만 바뀐다)
/// - 레일은 늘 `bezel` 검정이라 라이트 · 다크 값이 같다
public struct ReviewTile: View {
    public enum Kind: Equatable, Sendable {
        case needsYou, changes
    }

    nonisolated public static let side: CGFloat = 32
    nonisolated public static let openRing: (width: CGFloat, offset: CGFloat) = (1.5, 2)
    nonisolated public static let focusRing: (width: CGFloat, offset: CGFloat) = (2, 3)
    /// 숨은 레일: 16pt 원 · 아이콘 10pt (펼친 타일의 .5배 · 아이콘 1.25배)
    nonisolated public static let hiddenDiameter: CGFloat = 16
    nonisolated public static let hiddenIcon: CGFloat = 10

    let kind: Kind
    let label: String
    let expanded: Bool
    let open: Bool
    let highlighted: Bool
    let focused: Bool
    let notchShift: CGFloat
    let action: () -> Void

    /// - highlighted: 호버 (펼친 레일에서만 칠한다)
    /// - notchShift: 숨은 레일에서 노치 가운데로 옮기는 거리(왼쪽, pt). 펼치면 0
    public init(
        kind: Kind, label: String, expanded: Bool, open: Bool = false, highlighted: Bool = false, focused: Bool = false, notchShift: CGFloat = 0,
        action: @escaping () -> Void
    ) {
        self.kind = kind
        self.label = label
        self.expanded = expanded
        self.open = open
        self.highlighted = highlighted
        self.focused = focused
        self.notchShift = notchShift
        self.action = action
    }

    /// 면: needs-you는 마커(호버는 그 위에 bezel-hover), changes는 bezel-hover(호버 bezel-track)
    nonisolated static func usesHoverOverlay(_ kind: Kind) -> Bool { kind == .needsYou }

    private var iconColor: Color { kind == .needsYou ? TFColor.textOnMarker : TFColor.bezelInk }

    public var body: some View {
        let hover = expanded && highlighted
        Button(action: action) {
            ZStack {
                Group {
                    switch kind {
                    case .needsYou:
                        RoundedRectangle(cornerRadius: expanded ? TFRadius.md : Self.side / 2, style: .continuous).fill(TFColor.fillMarker)
                        if hover {
                            RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous).fill(TFColor.bezelHover)
                        }
                    case .changes:
                        RoundedRectangle(cornerRadius: expanded ? TFRadius.md : Self.side / 2, style: .continuous)
                            .fill(hover ? TFColor.bezelTrack : TFColor.bezelHover)
                    }
                }
                TFIcon.review.image(size: 16)
                    .foregroundStyle(iconColor)
                    .scaleEffect(expanded ? 1 : 1.25)
            }
            .frame(width: Self.side, height: Self.side)
            .scaleEffect(expanded ? 1 : Self.hiddenDiameter / Self.side)
            .offset(x: expanded ? 0 : -notchShift)
            .frame(width: Self.side, height: Self.side)
            .overlay {
                if expanded, focused {
                    ring(Self.focusRing, color: TFColor.borderAccent, radius: TFRadius.md + Self.focusRing.offset)
                } else if expanded, open {
                    ring(Self.openRing, color: TFColor.bezelInk, radius: TFRadius.md + Self.openRing.offset)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(open ? [.isButton, .isSelected] : .isButton)
    }

    /// 타일 밖 `offset`에 둘레 `width`의 링 (둘레가 타일 밖으로 나가 있어 레일 폭을 넘지 않는 마스크 안에 든다)
    private func ring(_ spec: (width: CGFloat, offset: CGFloat), color: Color, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(color, lineWidth: spec.width)
            .frame(width: Self.side + 2 * spec.offset + spec.width, height: Self.side + 2 * spec.offset + spec.width)
            .allowsHitTesting(false)
    }
}

#Preview("Review tile") {
    HStack(spacing: 24) {
        ForEach([ReviewTile.Kind.needsYou, .changes], id: \.self) { kind in
            VStack(spacing: 18) {
                ReviewTile(kind: kind, label: "Review", expanded: true) {}
                ReviewTile(kind: kind, label: "Review", expanded: true, highlighted: true) {}
                ReviewTile(kind: kind, label: "Review", expanded: true, open: true) {}
                ReviewTile(kind: kind, label: "Review", expanded: true, focused: true) {}
                ReviewTile(kind: kind, label: "Review", expanded: false, notchShift: 9.5) {}
            }
        }
    }
    .padding(28)
    .background(TFColor.bezelBase)
}
