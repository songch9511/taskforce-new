import SwiftUI
import TaskforceKit

/// ContextChip (0.2.0 디자인 시스템 Atoms): 다음 Assistant 메시지가 실을 맥락 하나 (이슈 · 세션 · 파일).
/// - **Auto**: Taskforce가 지금 있는 곳에서 고른 것. 면 없음 + 1pt 점선 `border/control` + `text/secondary`
/// - **Added**: 사용자가 고른 것. `bg/elevated` + `text/primary`
/// - 약 22pt (DS bundle.css: 안쪽 3/4/3/6 · 줄 높이 16, auto는 테두리 1pt를 안쪽에서 덜어 같은 22), 모서리 6, 간격 4. 이름은 `footnote` 한 줄이고 **가운데를 줄인다**
///   (`#139 …` 번호와 끝이 함께 보인다). 아이콘 · ×는 줄지 않는다
/// - 칩은 `bg/field` 트레이 위에서만 (맨 패널 위에서는 added의 면이 사라진다). 개수를 보이지 않는다
public struct ContextChip: View {
    public enum Icon: Equatable, Sendable {
        /// 항목 아이콘 (`file-text` 12pt)
        case item(TFIcon)
        /// 세션 칩: 에이전트 마크 12pt
        case agent(AgentMarkKind)
    }

    nonisolated public static let iconSize: CGFloat = 12
    nonisolated public static let radius: CGFloat = 6

    let label: String
    let origin: ChatAttachmentOrigin
    let icon: Icon
    let onRemove: (() -> Void)?
    let onActivate: (() -> Void)?
    let activationName: String?
    @Environment(\.colorSchemeContrast) private var contrast

    /// - onActivate: 에이전트 대상의 auto 칩을 누르면 added가 된다 (OA D4a-12). Taskforce 대상 · added 칩에는 주지 않는다
    /// - activationName: 그 눌림의 접근성 동작 이름 ("Add #139 …", 사용자 승인 2026-10-18)
    public init(
        label: String, origin: ChatAttachmentOrigin, icon: Icon = .item(.result), onRemove: (() -> Void)? = nil, onActivate: (() -> Void)? = nil,
        activationName: String? = nil
    ) {
        self.label = label
        self.origin = origin
        self.icon = icon
        self.onRemove = onRemove
        self.onActivate = onActivate
        self.activationName = activationName
    }

    private var isAuto: Bool { origin == .auto }

    /// auto 칩은 눌러서 더할 수 있나: 누르는 동작이 주어졌을 때만 (에이전트 대상)
    nonisolated public static func isActivatable(origin: ChatAttachmentOrigin, hasAction: Bool) -> Bool { origin == .auto && hasAction }

    /// 눌러서 더하는 접근성 동작의 이름 ("Add {칩 이름}")
    nonisolated public static func activationName(chip: String) -> String {
        AgentCopy.addChip(chip)
    }

    /// "Remove #139 Rewrite pricing page copy"
    nonisolated public static func removeLabel(_ label: String) -> String { "Remove \(label)" }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        let secondary = isAuto ? TFColor.textSecondary : TFColor.textPrimary
        HStack(spacing: TFSpace.xs) {
            labelPart(secondary)
            if let onRemove {
                RemoveButton(label: Self.removeLabel(label), action: onRemove)
                    .layoutPriority(1)
            }
        }
        // auto는 점선 1pt가 안쪽 둘레를 쓴다: 안쪽 3/4/3/6에서 1씩 덜어 added와 같은 22pt
        .padding(isAuto ? EdgeInsets(top: 2, leading: 5, bottom: 2, trailing: 3) : EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: TFSpace.xs))
        .background(isAuto ? Color.clear : TFColor.bgElevated, in: shape)
        .overlay {
            if isAuto {
                shape.strokeBorder(TFColor.borderControl, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            } else if contrast == .increased {
                shape.strokeBorder(TFColor.borderControl, lineWidth: 1)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// 아이콘 + 이름. 눌러서 더할 수 있는 auto 칩이면 이 부분이 단추다 (×는 따로)
    @ViewBuilder
    private func labelPart(_ color: Color) -> some View {
        let content = HStack(spacing: TFSpace.xs) {
            Group {
                switch icon {
                case .item(let glyph): glyph.image(size: Self.iconSize).foregroundStyle(TFColor.textSecondary)
                case .agent(let kind): AgentMark(kind, size: Self.iconSize)
                }
            }
            .layoutPriority(1)
            Text(label)
                .font(TFFont.footnote)
                .tracking(-0.08)
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(height: 16)
        }
        if Self.isActivatable(origin: origin, hasAction: onActivate != nil), let onActivate {
            Button(action: onActivate) { content.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
                .accessibilityAddTraits(.isButton)
                .modifier(ActivationAction(name: activationName, action: onActivate))
        } else {
            content
        }
    }

    /// 접근성 동작 이름이 있으면 (승인된 문구) 그 이름의 동작을 더한다
    private struct ActivationAction: ViewModifier {
        let name: String?
        let action: () -> Void

        func body(content: Content) -> some View {
            if let name { content.accessibilityAction(named: Text(name), action) } else { content }
        }
    }

    /// × (`tf-chip-x`): 16pt 누르는 칸, 호버 `bg/selected`
    private struct RemoveButton: View {
        let label: String
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                TFIcon.removeItem.image(size: ContextChip.iconSize)
                    .foregroundStyle(hovering ? TFColor.textPrimary : TFColor.textSecondary)
                    .frame(width: 16, height: 16)
                    .background(hovering ? TFColor.bgSelected : Color.clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityLabel(label)
        }
    }
}

/// 줄바꿈 흐름: 칩 줄 (칩 사이 `gap`, 한 칩이 한 줄보다 길면 그 줄 폭까지 줄여 이름을 줄인다)
public struct ChipFlowLayout: Layout {
    let spacing: CGFloat

    public init(spacing: CGFloat = TFSpace.xs) {
        self.spacing = spacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        return arrange(width: width, subviews: subviews).size
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placed = arrange(width: bounds.width, subviews: subviews)
        for (index, frame) in placed.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let ideal = subview.sizeThatFits(.unspecified)
            let available = width.isFinite ? width : ideal.width
            // 한 줄보다 긴 칩은 그 줄 폭까지 줄인다 (이름이 가운데에서 줄어든다)
            let fitted = subview.sizeThatFits(ProposedViewSize(width: min(ideal.width, available), height: nil))
            if x > 0, x + fitted.width > available {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: fitted.width, height: fitted.height))
            x += fitted.width + spacing
            rowHeight = max(rowHeight, fitted.height)
            usedWidth = max(usedWidth, x - spacing)
        }
        return (frames, CGSize(width: usedWidth, height: frames.isEmpty ? 0 : y + rowHeight))
    }
}

#Preview("Context chips") {
    ChipFlowLayout(spacing: 4) {
        ContextChip(label: "#139 Rewrite pricing page copy · Not sent", origin: .auto, onRemove: {})
        ContextChip(label: "Lifetime plan section", origin: .added, icon: .agent(.codex), onRemove: {})
        ContextChip(label: "#140 A very long issue name that has to be cut in the middle so the number and the end stay together", origin: .added, onRemove: {})
    }
    .padding(8)
    .frame(width: 356)
    .background(TFColor.bgField)
}
