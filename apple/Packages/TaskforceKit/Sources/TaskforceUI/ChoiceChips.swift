import SwiftUI

/// ChoiceChips (0.2.0 디자인 시스템 Molecules): 줄바꿈되는 짧은 목록에서 하나를 고른다 (프로젝트 · 상태 필터).
/// `Card` 안에 두고, 목록마다 12pt 캡션. 고른 칩은 `fill/segment`로 떠오르고 굵어진다(굵은 폭을 미리 잡아 두어 아무것도 밀리지 않는다).
/// 고르지 않은 칩은 맨 글자에 호버 받침. 선택지가 데이터(프로젝트)이거나 줄이 넘칠 수 있으면 이것, 고정된 둘–넷이면 Segmented.
/// VoiceOver: 목록 이름(캡션) 안의 버튼들, 고른 칩은 "selected"
public struct ChoiceChips<Value: Hashable>: View {
    public struct Option: Hashable {
        public let value: Value
        public let label: String

        public init(_ value: Value, label: String) {
            self.value = value
            self.label = label
        }
    }

    let label: String
    let options: [Option]
    let selection: Value
    let onSelect: (Value) -> Void
    let continued: Bool

    /// - continued: 같은 카드에서 앞 목록 바로 뒤 (위 여백 2, 디자인 `.tf-chips + .tf-chips`)
    public init(_ label: String, options: [Option], selection: Value, continued: Bool = false, onSelect: @escaping (Value) -> Void) {
        self.label = label
        self.options = options
        self.selection = selection
        self.continued = continued
        self.onSelect = onSelect
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(TFFont.caption)
                .foregroundStyle(TFColor.textSecondarySelected)
                .accessibilityHidden(true)
            WrapLayout(spacing: TFSpace.xs) {
                ForEach(options, id: \.self) { option in
                    ChoiceChip(label: option.label, selected: option.value == selection) { onSelect(option.value) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: continued ? 2 : 10, leading: 12, bottom: 10, trailing: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

private struct ChoiceChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            // 굵은 글자 폭을 잡아 두고 그 위에 지금 굵기로 쓴다 (고를 때 칩 폭이 바뀌지 않는다)
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .hidden()
                .overlay {
                    Text(label)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected || hovering ? TFColor.textPrimary : TFColor.textSecondarySelected)
                }
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(minHeight: 26)
                .background {
                    Capsule()
                        .fill(selected ? TFColor.fillSegment : (hovering ? TFColor.bgSelected : .clear))
                        .shadow(color: .black.opacity(selected ? 0.12 : 0), radius: 1, y: 1)
                        .overlay { Capsule().strokeBorder(.black.opacity(selected ? 0.06 : 0), lineWidth: 0.5) }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(TFMotion.ease(0.14), value: selected)
        .animation(TFMotion.ease(0.14), value: hovering)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 줄바꿈 배치: 가로로 놓다가 넘치면 다음 줄 (칩 사이 `spacing`, 줄 사이도 같다)
struct WrapLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty, needed > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

#Preview("Choice chips") {
    @Previewable @State var project = "All"
    @Previewable @State var status = "Waiting"
    Card {
        ChoiceChips("Project", options: ["All", "Shape launch", "Acme website", "Ungrouped"].map { .init($0, label: $0) }, selection: project) { project = $0 }
        ChoiceChips("Status", options: ["All", "In Progress", "To Do", "Waiting", "Done"].map { .init($0, label: $0) }, selection: status, continued: true) {
            status = $0
        }
    }
    .padding()
    .frame(width: 380)
    .background(TFColor.bgPanel)
}
