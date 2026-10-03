import SwiftUI
import TaskforceKit

/// 원문 슬립 (Figma Source slip 158:3878): 종이 면 위 인용(3줄까지) + 서비스 로고 · 원문 이름 · 시점. 누르면 원문을 연다.
/// 종이 면은 원문 인용에만 쓴다 (Taskforce의 말은 종이 위에 두지 않는다). Mac 상세 칸 · iPhone Review 카드 · 펼친 할 일 행이 같이 쓴다.
/// 인용 글자: Mac 13 · iPhone 15 (Dynamic Type `subheadline`, Figma P1).
public struct SourceSlip: View {
    let line: EvidenceLine
    let onOpen: (URL) -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    public init(line: EvidenceLine, onOpen: @escaping (URL) -> Void) {
        self.line = line
        self.onOpen = onOpen
    }

    public var body: some View {
        let removed = RemovedQuote.isRemoved(line.quote)
        VStack(alignment: .leading, spacing: 6) {
            Text(removed ? RemovedQuote.label : "“\(line.quote)”")
                .font(Self.quoteFont)
                .foregroundStyle(removed ? TFColor.sourceMeta : TFColor.sourceText)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                if typeSize.isAccessibilitySize {
                    // 큰 글자 (iPhone P11): 시점을 원문 이름 아래로 (한 줄에 두면 칸보다 넓어진다)
                    VStack(alignment: .leading, spacing: TFSpace.xxs) {
                        HStack(alignment: .firstTextBaseline, spacing: TFSpace.sm) {
                            SourceIcon(line.service, size: .s)
                            sourceTitle
                        }
                        when
                    }
                } else {
                    HStack(spacing: TFSpace.sm) {
                        SourceIcon(line.service, size: .s)
                        sourceTitle
                        when?.fixedSize()
                    }
                }
            }
            .font(TFFont.meta)
            .foregroundStyle(TFColor.sourceMeta)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, Self.verticalPadding)
        .background(TFColor.sourcePaper, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            if let url = line.externalURL { onOpen(url) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(line.externalURL == nil ? [] : .isLink)
    }

    @ViewBuilder
    private var sourceTitle: some View {
        if let title = line.displayTitle, !title.isEmpty {
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var when: Text? {
        line.displayDate.map { Text(WhenText.label($0)) }
    }

    #if os(iOS)
    private static let quoteFont = TFFont.callout
    private static let verticalPadding: CGFloat = 12
    #else
    private static let quoteFont = TFFont.footnote
    private static let verticalPadding: CGFloat = 10
    #endif
}
