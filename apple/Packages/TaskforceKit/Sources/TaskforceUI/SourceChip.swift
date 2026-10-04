import SwiftUI
import TaskforceKit

/// Source chip (Figma M8 `Chip · …` 185:2566): fill/keycap r5, 안쪽 3 / 6 · 8, 서비스 로고 14 + 원문 이름 12.
/// 원문 이름은 한 줄 (길면 가운데를 줄이지 않고 끝을 줄인다).
public struct SourceChip: View {
    let title: String
    let service: SourceService?

    /// 원문 칩
    public init(_ source: DraftSource) {
        title = source.title
        service = source.service
    }

    /// 로고 없는 칩 ("4 more")
    public init(more count: Int) {
        title = ChipFlow.moreTitle(count)
        service = nil
    }

    public var body: some View {
        HStack(spacing: 5) {
            if let service {
                SourceIcon(service, size: .s)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(TFFont.meta)
                .foregroundStyle(TFColor.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: TFSpace.sm))
        .background(TFColor.fillKeycap, in: RoundedRectangle(cornerRadius: TFRadius.sm, style: .continuous))
    }
}

/// 칩을 줄바꿈해 늘어놓는다 (Figma M8 `Use`: 사이 6). 4개까지 보이고 나머지는 `N more` 칩 하나.
/// 칩은 읽기만 한다 (자료 고르기 `+`는 U2에서 숨김: 고르는 API가 없다).
public struct ChipFlow: View {
    let sources: [DraftSource]
    let limit: Int

    public init(_ sources: [DraftSource], limit: Int = ChipFlow.visibleLimit) {
        self.sources = sources
        self.limit = limit
    }

    /// Figma M8: 칩 4개 + `N more`
    nonisolated public static let visibleLimit = 4

    /// 보일 칩 수와 `N more`의 N (N이 0이면 그 칩이 없다)
    nonisolated static func split(count: Int, limit: Int) -> (shown: Int, more: Int) {
        guard count > limit else { return (max(0, count), 0) }
        return (limit, count - limit)
    }

    nonisolated static func moreTitle(_ count: Int) -> String { "\(count) more" }

    /// "Sources: 제품 회의록, 데모 요청, 2 more"
    nonisolated static func accessibilityLabel(_ titles: [String], limit: Int) -> String {
        let (shown, more) = split(count: titles.count, limit: limit)
        let parts = Array(titles.prefix(shown)) + (more > 0 ? [moreTitle(more)] : [])
        return "Sources: " + parts.joined(separator: ", ")
    }

    public var body: some View {
        let (shown, more) = Self.split(count: sources.count, limit: limit)
        FlowLayout(spacing: 6) {
            ForEach(sources.prefix(shown)) { source in
                SourceChip(source)
            }
            if more > 0 {
                SourceChip(more: more)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(sources.map(\.title), limit: limit))
    }
}

/// 왼쪽부터 채우고 넘치면 다음 줄로 (칸보다 넓은 칩은 칸 폭으로 줄인다)
struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            let needed = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.items.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.items.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.items.append((index, size))
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}

#Preview("Source chips") {
    let sources = [
        DraftSource(id: UUID(), title: "제품 회의록", service: .notion),
        DraftSource(id: UUID(), title: "데모 요청", service: .gmail),
        DraftSource(id: UUID(), title: "기획서 v1", service: .notion),
        DraftSource(id: UUID(), title: "고객 인터뷰 전사 — 아주 긴 원문 이름이 칸을 넘는 경우", service: .googleMeet),
        DraftSource(id: UUID(), title: "메모", service: .manual(.note)),
        DraftSource(id: UUID(), title: "견적서", service: .gmail),
    ]
    return ChipFlow(sources)
        .frame(width: 311, alignment: .leading)
        .padding(24)
        .background(TFColor.bgElevated)
}
