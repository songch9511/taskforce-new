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
    let action: () -> Void
    @State private var hovering = false

    public init(title: String, date: String, preview: String?, isCurrent: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.date = date
        self.preview = preview
        self.isCurrent = isCurrent
        self.action = action
    }

    public var body: some View {
        let selected = hovering || isCurrent
        Button(action: action) {
            VStack(alignment: .leading, spacing: TFSpace.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: TFSpace.md) {
                    Text(title)
                        .font(TFFont.calloutEmphasis)
                        .tracking(-0.24)
                        .foregroundStyle(TFColor.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
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
        .accessibilityLabel(Self.accessibilityLabel(title: title, date: date, preview: preview))
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }

    /// "Pricing copy check, Oct 8, Draft · Can you compare plan B with"
    nonisolated public static func accessibilityLabel(title: String, date: String, preview: String?) -> String {
        [title, date, preview].compactMap { $0 }.joined(separator: ", ")
    }
}

/// ChatHistory (Organism): 지난 대화 목록, 새 것이 위, 목록 위에 설명 글이 없다. 날짜는 실제 날짜.
/// 빈 목록 · 읽는 중 · 오프라인 · 실패는 쓰는 쪽이 `PanelEmptyState`로 보인다 (이 부품은 줄만 그린다)
public struct ChatHistory: View {
    let entries: [ChatListEntry]
    let currentID: UUID?
    let now: Date
    let onOpen: (UUID) -> Void

    public init(entries: [ChatListEntry], currentID: UUID? = nil, now: Date = Date(), onOpen: @escaping (UUID) -> Void) {
        self.entries = entries
        self.currentID = currentID
        self.now = now
        self.onOpen = onOpen
    }

    public var body: some View {
        VStack(spacing: 0) {
            ForEach(entries) { entry in
                ChatItem(
                    title: entry.title, date: ChatHistoryRules.dateLabel(entry.date, now: now), preview: entry.previewText,
                    isCurrent: entry.id == currentID, action: { onOpen(entry.id) }
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ChatCopy.historyTitle)
    }
}

/// Message (Molecule): 대화의 한 번. 사용자 글은 `bg/field` 면에 32 들여, Taskforce의 말은 패널 위에 전폭으로. 아바타 · 이름 · 말풍선 없음, 긴 낱말은 줄을 바꾼다.
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
                content
                    .padding(EdgeInsets(top: 10, leading: TFSpace.md, bottom: 10, trailing: TFSpace.md))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(TFColor.bgField, in: RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous))
                    .padding(.leading, TFSpace.xxl)
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

    public init(_ text: String, isDeleted: Bool = false) {
        self.text = text
        self.isDeleted = isDeleted
    }

    public var body: some View {
        Text(isDeleted ? MemoryCopy.purgedStatement : text)
            .font(TFFont.callout)
            .tracking(-0.24)
            .lineSpacing(3)
            .foregroundStyle(isDeleted ? TFColor.textSecondary : TFColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}

/// 보낸 글 아래의 상태 한 줄: 서버가 확인하기 전에는 완료로 보이지 않는다 ("Sending…" · "Not sent · …" · "No reply yet" · "Not answered")
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

    public var body: some View {
        if let text = Self.text(status) {
            HStack(alignment: .firstTextBaseline, spacing: TFSpace.xs) {
                Text(text)
                    .font(TFFont.meta)
                    .foregroundStyle(TFColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if status.canRetry {
                    Button(ChatCopy.tryAgain, action: onRetry)
                        .buttonStyle(TFButtonStyle(.text, size: .sm))
                }
            }
            .padding(.leading, TFSpace.xxl)
            .padding(.horizontal, TFSpace.xs)
            .accessibilityElement(children: .combine)
        }
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
    @Environment(\.colorSchemeContrast) private var contrast

    public init(
        service: SourceService? = nil, from: String? = nil, place: String? = nil, time: String? = nil, text: String,
        openTitle: String? = nil, onOpen: (() -> Void)? = nil
    ) {
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
                    if let service { SourceIcon(service, size: .m) }
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
    let onSubmit: (String) -> Void
    @State private var focused = false
    @Environment(\.colorSchemeContrast) private var contrast

    public init(
        text: Binding<String>, placeholder: String = ChatCopy.composerPlaceholder, label: String = ChatCopy.composerLabel,
        isDisabled: Bool = false, isSending: Bool = false, focusRequest: Int = 0, onSubmit: @escaping (String) -> Void
    ) {
        _text = text
        self.placeholder = placeholder
        self.label = label
        self.isDisabled = isDisabled
        self.isSending = isSending
        self.focusRequest = focusRequest
        self.onSubmit = onSubmit
    }

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
            Button(action: submit) {
                TFIcon.send.image(size: 16)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(TFColor.textPrimary)
            .opacity(canSend ? 1 : 0.45)
            .disabled(!canSend)
            .accessibilityLabel(isSending ? "Sending" : "Send")
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
