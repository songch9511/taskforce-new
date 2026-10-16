import SwiftUI
import TaskforceKit
#if os(macOS)
import AppKit
#endif

// Chats 부품 (0.2.0 디자인 시스템 Molecules: ChatItem · Message · SourceQuote · Composer · Organism: ChatHistory).
// 값과 동작만 받는다: 서버 · 계정은 모른다 (`ChatStore`가 값을 만든다). 설명 문단 없이 내용 · 상태 · 동작 이름만 쓴다.

/// ChatItem (Molecule): 대화 하나. 이름 · 날짜, 그 아래 초안(`Draft · …`) 또는 마지막 메시지. 빈 대화는 `No messages yet`.
/// 호버 · 지금 대화는 `bg/selected` 면이고 보조 글은 그 위 4.5:1을 지키는 색으로 올린다.
public struct ChatItem: View {
    let title: String
    let date: String
    let preview: String?
    let isCurrent: Bool
    /// 에이전트 대화는 이름 앞에 AgentMark (Taskforce 대화는 nil: 마크 없음)
    let mark: AgentMarkKind?
    let action: () -> Void
    @State private var hovering = false

    public init(title: String, date: String, preview: String?, isCurrent: Bool = false, mark: AgentMarkKind? = nil, action: @escaping () -> Void) {
        self.title = title
        self.date = date
        self.preview = preview
        self.isCurrent = isCurrent
        self.mark = mark
        self.action = action
    }

    public var body: some View {
        let selected = hovering || isCurrent
        Button(action: action) {
            VStack(alignment: .leading, spacing: TFSpace.xxs) {
                HStack(alignment: .center, spacing: TFSpace.md) {
                    HStack(spacing: TFSpace.sm) {
                        if let mark { AgentMark(mark, size: TargetPill.markSize) }
                        Text(title)
                            .font(TFFont.calloutEmphasis)
                            .tracking(-0.24)
                            .foregroundStyle(TFColor.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                    Text(date)
                        .font(TFFont.meta)
                        .foregroundStyle(selected ? TFColor.textSecondarySelected : TFColor.textSecondary)
                        .fixedSize()
                }
                if let preview {
                    Text(preview)
                        .font(TFFont.footnote)
                        .foregroundStyle(selected ? TFColor.textSecondarySelected : TFColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(EdgeInsets(top: 10, leading: TFSpace.sm, bottom: 10, trailing: TFSpace.sm))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? TFColor.bgSelected : .clear, in: RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(TFMotion.ease(TFMotion.hoverFade), value: hovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(title: title, date: date, preview: preview, agent: mark?.accessibilityName))
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }

    /// "Pricing copy check, Oct 8, Draft · Can you compare plan B with"
    nonisolated public static func accessibilityLabel(title: String, date: String, preview: String?, agent: String? = nil) -> String {
        [title, agent, date, preview].compactMap { $0 }.joined(separator: ", ")
    }
}

/// ChatHistory (Organism): 지난 대화 목록, 새 것이 위, 목록 위에 설명 글이 없다. 날짜는 실제 날짜.
/// 빈 목록 · 읽는 중 · 오프라인 · 실패는 쓰는 쪽이 `PanelEmptyState`로 보인다 (이 부품은 줄만 그린다)
public struct ChatHistory: View {
    let entries: [ChatListEntry]
    let currentID: UUID?
    let now: Date
    let mark: (ChatListEntry) -> AgentMarkKind?
    let onOpen: (UUID) -> Void

    /// - mark: 에이전트 대화에 붙일 마크 (Assistant 창의 History는 두 대상의 대화를 모두 보인다)
    public init(
        entries: [ChatListEntry], currentID: UUID? = nil, now: Date = Date(), mark: @escaping (ChatListEntry) -> AgentMarkKind? = { _ in nil },
        onOpen: @escaping (UUID) -> Void
    ) {
        self.entries = entries
        self.currentID = currentID
        self.now = now
        self.mark = mark
        self.onOpen = onOpen
    }

    public var body: some View {
        VStack(spacing: 0) {
            ForEach(entries) { entry in
                ChatItem(
                    title: entry.title, date: ChatHistoryRules.dateLabel(entry.date, now: now), preview: entry.previewText,
                    isCurrent: entry.id == currentID, mark: mark(entry), action: { onOpen(entry.id) }
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ChatCopy.historyTitle)
    }
}

/// 사용자 말풍선이 글 폭에 맞춰 줄어드는가 (`Message`가 켠다). Taskforce의 말은 전폭이다
private struct MessageHugsTextKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    fileprivate var messageHugsText: Bool {
        get { self[MessageHugsTextKey.self] }
        set { self[MessageHugsTextKey.self] = newValue }
    }
}

/// Message (Molecule): 대화의 한 번. 사용자 글은 `bg/field` 면의 말풍선이 **오른쪽에 붙어 글 폭만큼만** 자라고(왼쪽 32는 늘 비운다), Taskforce의 말은 패널 위에 전폭으로.
/// 아바타 · 이름 없이, 긴 낱말은 줄을 바꾼다. (Figma 28:1416 배치: 오른쪽 맞춤. 값은 DS bundle.css: 안쪽 10/12 · 모서리 8 · 왼쪽 여백 32)
public struct Message<Content: View>: View {
    let isUser: Bool
    let content: Content

    public init(isUser: Bool, @ViewBuilder content: () -> Content) {
        self.isUser = isUser
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: TFSpace.sm) {
            if isUser {
                HStack(spacing: 0) {
                    Spacer(minLength: TFSpace.xxl)
                    content
                        .environment(\.messageHugsText, true)
                        .padding(EdgeInsets(top: 10, leading: TFSpace.md, bottom: 10, trailing: TFSpace.md))
                        .background(TFColor.bgField, in: RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous))
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                content.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 메시지 글: callout 15, 줄 21. 글자는 글자로 그린다 (선택 · 복사 가능)
public struct MessageText: View {
    let text: String
    let isDeleted: Bool
    @Environment(\.messageHugsText) private var hugs

    public init(_ text: String, isDeleted: Bool = false) {
        self.text = text
        self.isDeleted = isDeleted
    }

    public var body: some View {
        let label = Text(isDeleted ? MemoryCopy.purgedStatement : text)
            .font(TFFont.callout)
            .tracking(-0.24)
            .lineSpacing(3)
            .foregroundStyle(isDeleted ? TFColor.textSecondary : TFColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        if hugs {
            label
        } else {
            label.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 보낸 글 아래의 상태 한 줄: 서버가 확인하기 전에는 완료로 보이지 않는다 ("Sending…" · **Not sent** · 이유 · "No reply yet" · "Not answered").
/// DS MessageDelivery처럼 오른쪽 맞춤 footnote 한 줄이고, 막힌 말 "Not sent"는 굵은 `text/primary`다 (빨강이 아니다). 이유는 보조색, Try again은 링크 하나
public struct ChatStatusLine: View {
    let status: ChatTurn.Status
    let onRetry: () -> Void

    public init(status: ChatTurn.Status, onRetry: @escaping () -> Void) {
        self.status = status
        self.onRetry = onRetry
    }

    /// 보일 글 (보낸 글이 서버 확인을 마쳤으면 nil)
    nonisolated public static func text(_ status: ChatTurn.Status) -> String? {
        switch status {
        case .sent: nil
        case .sending: ChatCopy.sending
        case .failed(let reason): "\(ChatCopy.notSent) · \(reason)"
        case .needsConsent: ChatCopy.notSent
        case .noReply: ChatCopy.noReplyYet
        case .notAnswered: ChatCopy.notAnswered
        }
    }

    /// 굵게 보일 앞부분과 보조색 뒷부분 ("Not sent" · 이유)
    nonisolated public static func parts(_ status: ChatTurn.Status) -> (strong: String?, text: String?)? {
        switch status {
        case .sent: nil
        case .failed(let reason): (ChatCopy.notSent, reason)
        case .needsConsent: (ChatCopy.notSent, nil)
        case .sending, .noReply, .notAnswered: (nil, text(status))
        }
    }

    public var body: some View {
        if let parts = Self.parts(status) {
            HStack(alignment: .firstTextBaseline, spacing: TFSpace.sm) {
                Group {
                    if let strong = parts.strong, let text = parts.text {
                        Text(strong).font(TFFont.footnoteEmphasis).foregroundStyle(TFColor.textPrimary)
                            + Text(" · \(text)").font(TFFont.footnote).foregroundStyle(TFColor.textSecondary)
                    } else if let strong = parts.strong {
                        Text(strong).font(TFFont.footnoteEmphasis).foregroundStyle(TFColor.textPrimary)
                    } else if let text = parts.text {
                        Text(text).font(TFFont.footnote).foregroundStyle(TFColor.textSecondary)
                    }
                }
                .tracking(-0.08)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                if status.canRetry {
                    Button(ChatCopy.tryAgain, action: onRetry)
                        .buttonStyle(TFButtonStyle(.text, size: .sm))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, TFSpace.xs)
            .accessibilityElement(children: .combine)
        }
    }
}

/// 줄 안의 항목을 **오른쪽 끝에 붙여** 감싸는 배치 (DS `.tf-delivery`: flex-wrap · justify flex-end · 열 간격 8): 글이 길면 링크가 다음 줄로 내려가고 두 줄 모두 오른쪽 끝에 붙는다
public struct TrailingWrapLayout: Layout {
    let spacing: CGFloat

    public init(spacing: CGFloat = TFSpace.sm) {
        self.spacing = spacing
    }

    /// 순수한 자리 규칙: 항목을 앞에서부터 줄에 담고(줄 폭을 넘으면 다음 줄), 각 줄을 오른쪽 끝에 붙인다. 줄 사이 간격은 없다
    public static func place(sizes: [CGSize], width: CGFloat, spacing: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        var rows: [[Int]] = []
        var rowWidths: [CGFloat] = []
        for (index, size) in sizes.enumerated() {
            if let last = rows.indices.last, rowWidths[last] + spacing + size.width <= width {
                rows[last].append(index)
                rowWidths[last] += spacing + size.width
            } else {
                rows.append([index])
                rowWidths.append(size.width)
            }
        }
        var frames = Array(repeating: CGRect.zero, count: sizes.count)
        var y: CGFloat = 0
        for (row, indices) in rows.enumerated() {
            var x = width - rowWidths[row]
            let rowHeight = indices.map { sizes[$0].height }.max() ?? 0
            for index in indices {
                frames[index] = CGRect(x: x, y: y, width: sizes[index].width, height: sizes[index].height)
                x += sizes[index].width + spacing
            }
            y += rowHeight
        }
        return (frames, y)
    }

    private func fitted(_ subviews: Subviews, width: CGFloat) -> [CGSize] {
        subviews.map { subview in
            let ideal = subview.sizeThatFits(.unspecified)
            return subview.sizeThatFits(ProposedViewSize(width: min(ideal.width, width), height: nil))
        }
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        guard width.isFinite else {
            let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
            return CGSize(width: sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(0, sizes.count - 1)), height: sizes.map(\.height).max() ?? 0)
        }
        let sizes = fitted(subviews, width: width)
        return CGSize(width: width, height: Self.place(sizes: sizes, width: width, spacing: spacing).height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = fitted(subviews, width: bounds.width)
        let placed = Self.place(sizes: sizes, width: bounds.width, spacing: spacing)
        for (index, frame) in placed.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}

/// MessageDelivery (Molecule): 에이전트에게 보낸 메시지가 어디까지 갔는지 한 줄 (Received · Sent · Unknown · Queued · **Not sent** · Expired). 단어만: 아이콘 · 스피너 · 색 없음.
/// 오른쪽 맞춤 footnote, 말풍선 아래 4pt. Not sent만 굵은 `text/primary`고 나머지는 보조색이다. 링크 하나(Send again · 후보 고르기)는 DS Button `link`이고
/// 글이 길면 오른쪽 맞춤으로 감싼다 (`TrailingWrapLayout`). 이유 말은 `MessageDeliveryLine`(Kit)이 정한다
public struct MessageDeliveryView: View {
    let line: MessageDeliveryLine
    let onLink: ((MessageDeliveryLine.Link) -> Void)?

    public init(_ line: MessageDeliveryLine, onLink: ((MessageDeliveryLine.Link) -> Void)? = nil) {
        self.line = line
        self.onLink = onLink
    }

    /// 전달 줄의 접근성 이름: 한 줄로 이은 글 (`combined`). 링크는 따로 누르는 동작이다
    nonisolated public static func accessibilityName(_ line: MessageDeliveryLine) -> String { line.combined }

    /// 링크의 접근성 이름 (링크가 없으면 nil)
    nonisolated public static func linkAccessibilityName(_ line: MessageDeliveryLine) -> String? { line.link?.title }

    public var body: some View {
        TrailingWrapLayout(spacing: TFSpace.sm) {
            Group {
                if let strong = line.strong {
                    Text(strong).font(TFFont.footnoteEmphasis).foregroundStyle(TFColor.textPrimary)
                        + Text(line.text.map { " · \($0)" } ?? "").font(TFFont.footnote).foregroundStyle(TFColor.textSecondary)
                } else if let text = line.text {
                    Text(text).font(TFFont.footnote).foregroundStyle(TFColor.textSecondary)
                }
            }
            .tracking(-0.08)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(Self.accessibilityName(line))
            if let link = line.link, let onLink {
                LinkButton(link.title) { onLink(link) }
                    .font(TFFont.footnote)
                    .tracking(-0.08)
                    .accessibilityLabel(link.title)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.top, TFSpace.xs)
        .accessibilityElement(children: .contain)
    }
}

/// 서버가 쓴 이벤트 줄 (`role = 'event'`, OA D4a-18, Figma 57:2284): "Opened in Terminal" · "Resumed here" · "Queued messages cancelled" · "Answered" …
/// `footnote` `text/secondary`, 왼쪽 맞춤, 한 줄 끝 줄임. 앱은 글을 만들지 않는다
public struct EventLine: View {
    nonisolated public static let lineLimit = 1

    let text: String

    public init(_ text: String) {
        self.text = text
    }

    nonisolated public static func accessibilityName(_ text: String) -> String { text }

    public var body: some View {
        Text(text)
            .font(TFFont.footnote)
            .tracking(-0.08)
            .foregroundStyle(TFColor.textSecondary)
            .lineLimit(Self.lineLimit)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(Self.accessibilityName(text))
    }
}

/// 잘린 에이전트 답과 View full (OA D4a-17, DS Message): 서버가 32KB에서 자른 답은 말줄임표로 끝나고, **이 Mac 원장에 전문이 있을 때만** 글 바로 아래(8)에 링크가 보인다.
/// 누르면 그 자리에서 전문으로 바뀌고 링크는 사라진다 (다른 것은 바꾸지 않는다). 링크는 세션 패널 머리에 없다
public enum MessageViewFull {
    public static let title = AgentCopy.viewFull

    /// 보일 글: 펼쳤으면 전문, 잘렸으면 말줄임표로 끝난 글 (이미 "…"로 끝나면 더하지 않는다)
    public static func shownText(_ turn: ChatTurn) -> String {
        if let full = turn.fullText { return full }
        guard turn.isTruncated, !turn.text.hasSuffix("…") else { return turn.text }
        return turn.text + "…"
    }

    /// 링크가 보이나: 잘렸고, 이 Mac에서 전문을 찾았고, 아직 펼치지 않았다
    public static func showsLink(_ turn: ChatTurn) -> Bool {
        turn.isTruncated && turn.canViewFull && turn.fullText == nil
    }
}

/// SourceQuote (Molecule): 말이 나온 자리의 원문. 서비스의 단일 잉크 마크 · 보낸 사람 · 곳 · 시각, 그 아래 원문 그대로. 인용에 밑줄을 긋지 않는다.
/// 채팅에서 한 말은 서비스가 없어 마크가 없다 ("You · Chat · Today 10:24").
public struct SourceQuote: View {
    let service: SourceService?
    let from: String?
    let place: String?
    let time: String?
    let text: String
    let openTitle: String?
    let onOpen: (() -> Void)?
    /// DS의 SourceMark(공식 마크 그대로, 18pt 타일)로 그린다 (새 Issues 화면). 기본은 지금의 단일 잉크 `SourceIcon`이다
    let usesSourceMark: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    public init(
        service: SourceService? = nil, from: String? = nil, place: String? = nil, time: String? = nil, text: String,
        openTitle: String? = nil, onOpen: (() -> Void)? = nil, usesSourceMark: Bool = false
    ) {
        self.usesSourceMark = usesSourceMark
        self.service = service
        self.from = from
        self.place = place
        self.time = time
        self.text = text
        self.openTitle = openTitle
        self.onOpen = onOpen
    }

    /// "Jordan Lee · Gmail · Today 10:42" (있는 것만)
    nonisolated public static func metaLine(from: String?, place: String?, time: String?) -> String {
        [from, place, time].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            let meta = Self.metaLine(from: from, place: place, time: time)
            if service != nil || !meta.isEmpty {
                HStack(spacing: 6) {
                    if let service {
                        if usesSourceMark { SourceMark(service, size: .sm) } else { SourceIcon(service, size: .m) }
                    }
                    if !meta.isEmpty {
                        Text(meta)
                            .font(TFFont.meta)
                            .foregroundStyle(TFColor.textSecondarySelected)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            Text(text)
                .font(TFFont.callout)
                .tracking(-0.24)
                .lineSpacing(3)
                .foregroundStyle(TFColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            if let onOpen {
                Button(openTitle ?? "Open original", action: onOpen)
                    .buttonStyle(TFButtonStyle(.text, size: .sm))
                    .padding(.leading, -TFSpace.sm)
                    .padding(.bottom, -TFSpace.xs)
            }
        }
        .padding(EdgeInsets(top: 10, leading: TFSpace.md, bottom: 10, trailing: TFSpace.md))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TFColor.bgField, in: shape)
        .overlay(shape.strokeBorder(contrast == .increased ? TFColor.borderControl : .clear, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

/// Composer (Molecule): 패널 아래의 입력칸. 칸이지 카드가 아니다 (`bg/field` 면, 포커스 때 1.5pt `border/accent` 안쪽 링).
/// Enter로 보내고 IME 조합 중에는 보내지 않는다. 빈 글은 보낼 수 없다. 보내는 중에는 Send가 꺼진다 (글을 계속 쓸 수는 있다).
/// 기능이 꺼져 있으면(`isDisabled`) 자리표시 글이 이유를 말한다.
public struct Composer: View {
    @Binding var text: String
    let placeholder: String
    let label: String
    let isDisabled: Bool
    let isSending: Bool
    let focusRequest: Int
    let isRunning: Bool
    let onStop: () -> Void
    let onSubmit: (String) -> Void
    @State private var focused = false
    @Environment(\.colorSchemeContrast) private var contrast

    /// - isRunning: 이 대화에서 시작한 일이 돌고 있다 (OA D4a-13): 보내기 원이 Stop(10pt 사각형, "Stop new steps")이 된다. 글을 쓰고 Enter로 보내는 것은 그대로다 (그 메시지는 대기열에 들어간다)
    public init(
        text: Binding<String>, placeholder: String = ChatCopy.composerPlaceholder, label: String = ChatCopy.composerLabel,
        isDisabled: Bool = false, isSending: Bool = false, focusRequest: Int = 0, isRunning: Bool = false, onStop: @escaping () -> Void = {},
        onSubmit: @escaping (String) -> Void
    ) {
        _text = text
        self.placeholder = placeholder
        self.label = label
        self.isDisabled = isDisabled
        self.isSending = isSending
        self.focusRequest = focusRequest
        self.isRunning = isRunning
        self.onStop = onStop
        self.onSubmit = onSubmit
    }

    /// 보내기 원의 접근성 이름: 돌고 있으면 "Stop new steps" (Stop이 이긴다)
    nonisolated public static func sendLabel(running: Bool, isSending: Bool) -> String {
        running ? AgentCopy.stopNewSteps : (isSending ? "Sending" : "Send")
    }

    /// 보내기 원이 Stop으로 바뀌나 (DS Composer "Running")
    nonisolated public static func circleStopsInsteadOfSending(running: Bool) -> Bool { running }

    /// 보낼 수 있나 (글이 있고, 꺼져 있지 않고, 보내는 중이 아니다)
    nonisolated public static func canSend(text: String, isDisabled: Bool, isSending: Bool) -> Bool {
        !isDisabled && !isSending && ChatComposerRules.isSendable(text)
    }

    private var canSend: Bool { Self.canSend(text: text, isDisabled: isDisabled, isSending: isSending) }

    private func submit() {
        guard canSend else { return }
        onSubmit(text)
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous)
        HStack(spacing: TFSpace.xs) {
            field
            let stops = Self.circleStopsInsteadOfSending(running: isRunning)
            Button(action: { if stops { onStop() } else { submit() } }) {
                // DS `.tf-send`: `fill/inverse` 원 28, 안에 arrow-up 또는 Stop(10pt · 모서리 2의 사각형)
                ZStack {
                    if stops {
                        RoundedRectangle(cornerRadius: 2, style: .continuous).fill(TFColor.textInverse).frame(width: 10, height: 10)
                    } else {
                        TFIcon.send.image(size: 16).foregroundStyle(TFColor.textInverse)
                    }
                }
                .frame(width: 28, height: 28)
                .background(TFColor.fillInverse, in: Circle())
                .opacity(stops || canSend ? 1 : 0.35)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!stops && !canSend)
            .accessibilityLabel(Self.sendLabel(running: isRunning, isSending: isSending))
        }
        .padding(EdgeInsets(top: 0, leading: TFSpace.md, bottom: 0, trailing: 6))
        .frame(minHeight: 40)
        .background(TFColor.bgField, in: shape)
        .overlay(shape.strokeBorder(focused ? TFColor.borderAccent : (contrast == .increased ? TFColor.borderControl : .clear), lineWidth: focused ? 1.5 : 1))
        .opacity(isDisabled ? 0.6 : 1)
        .animation(TFMotion.ease(TFMotion.hoverFade), value: focused)
    }

    @ViewBuilder
    private var field: some View {
        #if os(macOS)
        ComposerTextField(
            text: $text, placeholder: placeholder, label: label, isEnabled: !isDisabled, focusRequest: focusRequest, onFocusChange: { focused = $0 },
            onSubmit: submit
        )
        #else
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(TFFont.callout)
            .disabled(isDisabled)
            .onSubmit(submit)
            .accessibilityLabel(label)
        #endif
    }
}

#if os(macOS)
/// Enter 처리의 규칙 (테스트로 고정): 한글 · 일본어 같은 IME가 글자를 조합하는 중(marked text)의 Enter는 조합을 확정할 뿐 보내지 않는다
enum ComposerKeyRule {
    /// 이 명령을 보내기로 바꿀까 (`insertNewline:` 이고 조합 중이 아닐 때만)
    static func shouldSubmit(selector: Selector, hasMarkedText: Bool) -> Bool {
        selector == #selector(NSResponder.insertNewline(_:)) && !hasMarkedText
    }
}

/// 한 줄 입력칸 (AppKit `NSTextField`): 조합 중 여부를 직접 본다. 글자가 길면 옆으로 흐른다.
struct ComposerTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let label: String
    let isEnabled: Bool
    let focusRequest: Int
    let onFocusChange: (Bool) -> Void
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ComposerNSTextField {
        let field = ComposerNSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.lineBreakMode = .byClipping
        field.delegate = context.coordinator
        field.onFocusChange = { [weak coordinator = context.coordinator] in coordinator?.parent.onFocusChange($0) }
        field.setAccessibilityLabel(label)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: ComposerNSTextField, context: Context) {
        context.coordinator.parent = self
        // 조합 중인 글을 덮어쓰지 않는다
        if field.stringValue != text, field.currentEditor().map({ ($0 as? NSTextView)?.hasMarkedText() != true }) ?? true {
            field.stringValue = text
        }
        field.isEnabled = isEnabled
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder, attributes: [.foregroundColor: NSColor(TFColor.textSecondarySelected), .font: NSFont.systemFont(ofSize: 15)]
        )
        field.setAccessibilityLabel(label)
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            field.requestFocus()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ComposerTextField
        var lastFocusRequest: Int

        init(_ parent: ComposerTextField) {
            self.parent = parent
            lastFocusRequest = parent.focusRequest - 1
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard ComposerKeyRule.shouldSubmit(selector: commandSelector, hasMarkedText: textView.hasMarkedText()) else { return false }
            parent.onSubmit()
            return true
        }
    }
}

/// 포커스를 알리고, 창에 붙으면 요청대로 포커스를 가져가는 입력칸. 포커스가 와도 쓰던 글을 전부 선택하지 않는다: 커서는 글 끝에 둔다
/// (선택된 채면 다음 글자가 쓰던 초안을 지운다)
final class ComposerNSTextField: NSTextField {
    var onFocusChange: (Bool) -> Void = { _ in }
    private var wantsFocus = false

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onFocusChange(true)
            // 필드 에디터가 전부 선택한 뒤에 커서를 끝으로 (바로 하면 다시 전부 선택된다)
            DispatchQueue.main.async { [weak self] in self?.placeCaretAtEnd() }
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange(false) }
        return accepted
    }

    /// 조합 중이 아닐 때만 커서를 옮긴다
    func placeCaretAtEnd() {
        guard let editor = currentEditor() as? NSTextView, !editor.hasMarkedText() else { return }
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
    }

    func requestFocus() {
        wantsFocus = true
        takeFocusIfPossible()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        takeFocusIfPossible()
    }

    private func takeFocusIfPossible() {
        guard wantsFocus, let window else { return }
        wantsFocus = false
        window.makeFirstResponder(self)
        placeCaretAtEnd()
    }
}
#endif

#Preview("Chat") {
    VStack(alignment: .leading, spacing: 12) {
        Message(isUser: true) { MessageText("Use the shorter FAQ on both pricing pages.") }
        ChatStatusLine(status: .failed("Can't reach the server. Check your connection."), onRetry: {})
        Message(isUser: false) { MessageText("Noted. I'll keep pricing-page FAQs short.") }
        SourceQuote(service: .gmail, from: "Jordan Lee", place: "Gmail", time: "Today 10:42", text: "Could we do the core launch on Thursday instead?")
        ChatItem(title: "Pricing copy check", date: "Oct 8", preview: "Draft · Can you compare plan B with", isCurrent: true) {}
        Composer(text: .constant(""), onSubmit: { _ in })
    }
    .padding(16)
    .frame(width: 380)
    .background(TFColor.bgPanel)
}
