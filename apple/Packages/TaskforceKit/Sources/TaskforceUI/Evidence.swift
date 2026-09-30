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

    /// 근거 한 줄 (`EvidenceDigest`의 줄). 원문에 일정이 붙었으면 "When · Source"가 일정 날짜 · 제목이다.
    /// `showsMeta`가 거짓이면 "When · Source" 줄을 그리지 않는다 (Sources에서 같은 회의의 줄은 마지막 줄에만).
    public init(
        _ line: EvidenceLine,
        others: [SourceService] = [],
        now: Date = Date(),
        quoteLineLimit: Int? = nil,
        showsMeta: Bool = true,
        showsOpen: Bool = false,
        onOpen: (() -> Void)? = nil
    ) {
        self.init(
            service: line.service,
            quote: line.quote,
            when: showsMeta ? line.displayDate.map { WhenText.label($0, now: now) } : nil,
            source: showsMeta ? line.displayTitle : nil,
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
                if hasMeta {
                    meta
                }
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

    private var hasMeta: Bool {
        when != nil || !(source ?? "").isEmpty || !others.isEmpty
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
/// 같은 일정에 붙은 원문의 근거(Notion 회의록 + Meet 전사)는 한 회의로 붙여 두고 "When · Source"(일정 날짜 · 제목)를 마지막 줄에 한 번만.
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
            ForEach(EvidenceGroup.grouped(lines)) { group in
                VStack(alignment: .leading, spacing: TFSpace.sm) {
                    ForEach(group.lines) { line in
                        EvidenceView(
                            line,
                            now: now,
                            showsMeta: line.id == group.lines.last?.id,
                            showsOpen: line.externalURL != nil,
                            onOpen: line.externalURL == nil ? nil : { onOpen(line) }
                        )
                    }
                }
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

    /// 같은 일정에 붙은 Notion 회의록 · Meet 전사 + 그 뒤의 메일 (google-verification.md 5장 영상 A)
    static let meetingLines: [EvidenceLine] = {
        let meeting = SourceMeeting(
            calendarEventID: "preview-event", title: "Proposal review — Acme",
            start: Date(timeIntervalSinceNow: -4 * 86_400), end: Date(timeIntervalSinceNow: -4 * 86_400 + 1_800)
        )
        return [
            EvidenceLine(
                id: UUID(), quote: "Alex to send the revised proposal to Jordan by Friday", sourceID: UUID(), sourceTitle: "Proposal review",
                occurredAt: Date(timeIntervalSinceNow: -4 * 86_400), externalURL: URL(string: "https://www.notion.so/x"), service: .notion,
                meeting: meeting
            ),
            EvidenceLine(
                id: UUID(), quote: "Alex Kim: Sure. I'll send the revised proposal to Jordan by Friday.", sourceID: UUID(),
                sourceTitle: "Proposal review — Acme", occurredAt: Date(timeIntervalSinceNow: -4 * 86_400 + 60),
                externalURL: URL(string: "https://docs.google.com/document/d/x/view"), service: .googleMeet, meeting: meeting
            ),
            EvidenceLine(
                id: UUID(), quote: "Wednesday works too.", sourceID: UUID(), sourceTitle: "RE: Revised proposal",
                occurredAt: Date(timeIntervalSinceNow: -2 * 86_400), externalURL: URL(string: "https://mail.google.com/mail/#all/x"),
                service: .gmail
            ),
        ]
    }()
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

#Preview("Evidence · meeting") {
    VStack(alignment: .leading, spacing: 24) {
        EvidenceView(PreviewData.meetingLines[1], others: [.notion, .gmail], quoteLineLimit: 3, onOpen: {})
        SourcesGroup(lines: PreviewData.meetingLines) { _ in }
    }
    .padding()
    .frame(width: 520)
}
