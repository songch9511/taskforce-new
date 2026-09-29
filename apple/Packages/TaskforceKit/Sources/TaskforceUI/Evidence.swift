import SwiftUI
import TaskforceKit

/// Evidence (Figma 3:407): 출처 로고 + 원문 인용 + "When · Source".
/// When은 줄이지 않고 원문 이름만 …로 줄인다 (E2). 출처가 여럿이면 줄 끝에 작은 겹침. Open은 Mac에서만.
public struct EvidenceView: View {
    let service: SourceService
    let quote: String
    let when: String?
    let source: String?
    let others: [SourceService]
    let quoteLineLimit: Int?
    let showsOpen: Bool
    let onOpen: (() -> Void)?

    public init(
        service: SourceService,
        quote: String,
        when: String?,
        source: String?,
        others: [SourceService] = [],
        quoteLineLimit: Int? = nil,
        showsOpen: Bool = false,
        onOpen: (() -> Void)? = nil
    ) {
        self.service = service
        self.quote = quote
        self.when = when
        self.source = source
        self.others = others
        self.quoteLineLimit = quoteLineLimit
        self.showsOpen = showsOpen
        self.onOpen = onOpen
    }

    /// 근거 한 줄 (`EvidenceDigest`의 줄)
    public init(
        _ line: EvidenceLine,
        others: [SourceService] = [],
        now: Date = Date(),
        quoteLineLimit: Int? = nil,
        showsOpen: Bool = false,
        onOpen: (() -> Void)? = nil
    ) {
        self.init(
            service: line.service,
            quote: line.quote,
            when: line.occurredAt.map { WhenText.label($0, now: now) },
            source: line.sourceTitle,
            others: others,
            quoteLineLimit: quoteLineLimit,
            showsOpen: showsOpen,
            onOpen: onOpen
        )
    }

    public var body: some View {
        HStack(alignment: .top, spacing: TFSpace.md) {
            SourceIcon(service)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: TFSpace.xxs) {
                quoteText
                meta
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsOpen, let onOpen {
                Button("Open", action: onOpen)
                    .buttonStyle(.plain)
                    .font(TFFont.footnote)
                    .foregroundStyle(TFColor.textSecondary)
                    .padding(.top, 2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var quoteText: some View {
        let removed = RemovedQuote.isRemoved(quote)
        let text = Text(removed ? RemovedQuote.label : "“\(quote)”")
            .font(TFFont.callout)
            .foregroundStyle(removed ? TFColor.textSecondary : TFColor.textPrimary)
            .lineLimit(quoteLineLimit)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        if let onOpen, !showsOpen {
            // 인용을 누르면 원문 (C2)
            Button(action: onOpen) { text }
                .buttonStyle(.plain)
        } else {
            text
        }
    }

    private var meta: some View {
        HStack(spacing: TFSpace.xs) {
            if let when {
                Text(when)
                    .fixedSize()
            }
            if let source, !source.isEmpty {
                if when != nil {
                    Text("·").fixedSize()
                }
                Text(source)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if !others.isEmpty {
                SourceStack(others: others)
            }
        }
        .font(TFFont.footnote)
        .foregroundStyle(TFColor.textSecondary)
    }
}

/// Evidence group (Figma 10:737, Mac "Sources N"): 겹친 로고 + "Sources N" 아래에 근거를 줄마다, 오래된 것이 위.
public struct SourcesGroup: View {
    let lines: [EvidenceLine]
    let now: Date
    let onOpen: (EvidenceLine) -> Void

    public init(lines: [EvidenceLine], now: Date = Date(), onOpen: @escaping (EvidenceLine) -> Void) {
        self.lines = lines
        self.now = now
        self.onOpen = onOpen
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: TFRadius.lg, style: .continuous)
        VStack(alignment: .leading, spacing: TFSpace.md) {
            HStack(spacing: TFSpace.sm) {
                SourceStack(services: lines.map(\.service))
                Text("Sources \(lines.count)")
                    .font(TFFont.footnote)
                    .foregroundStyle(TFColor.textSecondary)
            }
            ForEach(lines) { line in
                EvidenceView(
                    line,
                    now: now,
                    showsOpen: line.externalURL != nil,
                    onOpen: line.externalURL == nil ? nil : { onOpen(line) }
                )
            }
        }
        .padding(.horizontal, TFSpace.lg)
        .padding(.vertical, TFSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TFColor.bgElevated, in: shape)
        .overlay(shape.strokeBorder(TFColor.borderDefault, lineWidth: 1))
    }
}

extension PreviewData {
    static let lines: [EvidenceLine] = [
        EvidenceLine(
            id: UUID(), quote: "금요일까지 제안서 보내드릴게요", sourceID: UUID(), sourceTitle: "김대표 미팅 회의록",
            occurredAt: Date(timeIntervalSinceNow: -5 * 86_400), externalURL: URL(string: "https://www.notion.so/x"), service: .notion
        ),
        EvidenceLine(
            id: UUID(), quote: "제안서는 월요일에 받아도 괜찮아요", sourceID: UUID(), sourceTitle: "#sales · 김대표",
            occurredAt: Date(timeIntervalSinceNow: -3 * 86_400), externalURL: URL(string: "https://acme.slack.com/x"), service: .slack
        ),
    ]
}

#Preview("Evidence") {
    VStack(alignment: .leading, spacing: 24) {
        EvidenceView(service: .notion, quote: "제안서는 월요일에 받아도 괜찮아요", when: "Sep 22", source: "김대표 미팅 회의록")
        EvidenceView(
            service: .notion,
            quote: "Can you bring your legal team into the draft review? We'd like their comments before Thursday so we can finalize.",
            when: "Yesterday 18:00",
            source: "A very long meeting note title that should truncate before the date does",
            others: [.slack, .gmail, .notion],
            quoteLineLimit: 3,
            onOpen: {}
        )
        SourcesGroup(lines: PreviewData.lines) { _ in }
    }
    .padding()
    .frame(width: 520)
}
