import SwiftUI
import TaskforceKit
#if os(macOS)
import AppKit
#endif

/// 프롬프트 박스의 Return 규칙 (테스트로 고정): Enter는 보내고, Shift+Enter(또는 Option+Enter)는 줄을 바꾸고,
/// IME가 글자를 조합하는 중(marked text)의 Enter는 조합을 확정할 뿐 보내지 않는다.
enum PromptKeyRule {
    enum Decision: Equatable {
        case submit, newline, passThrough
    }

    /// kVK_Return · kVK_ANSI_KeypadEnter
    static let returnKeys: Set<UInt16> = [36, 76]

    static func decision(keyCode: UInt16, shift: Bool, option: Bool, command: Bool, control: Bool, hasMarkedText: Bool) -> Decision {
        guard returnKeys.contains(keyCode), !hasMarkedText, !control else { return .passThrough }
        if shift || option { return .newline }
        _ = command
        return .submit
    }
}

#if os(macOS)
/// PromptBox (0.2.0 디자인 시스템 Molecules): Assistant의 입력 하나. **트레이 하나**(`bg/field`, 모서리 12, 안쪽 8/6/6/8)에 칩 줄 · 글 · 아래 줄.
/// - 아래 줄: 왼쪽 TargetPicker 알약, 오른쪽 Attach(`paperclip`, `text/secondary`)와 28pt 보내기 원(`arrow-up`, `fill/inverse`)
/// - 글 영역은 **두 줄 이상**(40pt)부터 늘고 160pt에서 스크롤한다. Enter 보내기 · Shift+Enter 줄바꿈 · IME 조합 중에는 안 보냄 · 빈 글은 보낼 수 없다 (보내기가 .35로 흐려진다)
/// - **Running**: 보내기가 Stop(10pt 사각형, "Stop new steps")이 된다. 입력은 계속 가능하다
/// - **Blocked**: 비밀 질문이 위에 열려 있다. 글 입력이 꺼지고 자리표시가 이유를 말하고, 보내기는 `bg/selected` 원 + 회색 화살표이며 아무 일도 하지 않는다
/// - 포커스 링(`border/accent` 1.5pt)은 트레이 전체를 안쪽으로 두른다. 대비 높이기에서는 1pt `border/control`
/// - 모델 선택기 · 글자 수 · 둘째 입력칸을 두지 않는다
public struct PromptBox: View {
    nonisolated public static let minTextHeight: CGFloat = 40
    nonisolated public static let maxTextHeight: CGFloat = 160
    nonisolated public static let sendSize: CGFloat = 28
    nonisolated public static let inset = EdgeInsets(top: 8, leading: 8, bottom: 6, trailing: 6)

    @Binding var text: String
    let placeholder: String
    let chips: [AssistantChip]
    let chipLabel: (AssistantChip) -> String
    let targetName: String
    let targetMark: AgentMarkKind
    let targetOpen: Bool
    let isBlocked: Bool
    let isRunning: Bool
    let canSend: Bool
    let focusRequest: Int
    let onSend: () -> Void
    let onStop: () -> Void
    let onRemoveChip: (String) -> Void
    let onTargetTap: () -> Void
    let onAttach: (() -> Void)?
    let onTargetFrame: (CGRect) -> Void
    let onActivateChip: ((String) -> Void)?
    let chipActivationName: (AssistantChip) -> String?
    @State private var textHeight: CGFloat = PromptBox.minTextHeight
    @State private var focused = false
    @Environment(\.colorSchemeContrast) private var contrast

    public init(
        text: Binding<String>, placeholder: String, chips: [AssistantChip], chipLabel: @escaping (AssistantChip) -> String,
        targetName: String, targetMark: AgentMarkKind, targetOpen: Bool, isBlocked: Bool = false, isRunning: Bool = false, canSend: Bool,
        focusRequest: Int = 0, onSend: @escaping () -> Void, onStop: @escaping () -> Void = {}, onRemoveChip: @escaping (String) -> Void,
        onTargetTap: @escaping () -> Void, onTargetFrame: @escaping (CGRect) -> Void = { _ in }, onAttach: (() -> Void)? = nil,
        onActivateChip: ((String) -> Void)? = nil, chipActivationName: @escaping (AssistantChip) -> String? = { _ in nil }
    ) {
        self.onActivateChip = onActivateChip
        self.chipActivationName = chipActivationName
        _text = text
        self.placeholder = placeholder
        self.chips = chips
        self.chipLabel = chipLabel
        self.targetName = targetName
        self.targetMark = targetMark
        self.targetOpen = targetOpen
        self.isBlocked = isBlocked
        self.isRunning = isRunning
        self.canSend = canSend
        self.focusRequest = focusRequest
        self.onSend = onSend
        self.onStop = onStop
        self.onRemoveChip = onRemoveChip
        self.onTargetTap = onTargetTap
        self.onAttach = onAttach
        self.onTargetFrame = onTargetFrame
    }

    /// 보내기 단추의 이름
    nonisolated public static func sendLabel(running: Bool) -> String { running ? "Stop new steps" : "Send" }

    /// 보내기 원이 조용한 모양인가: 막혔고 Stop이 아닐 때만. 비밀값 질문으로 막혀도 에이전트가 실행 중이면 Stop은 살아 있다 (`Composer.circleIsQuiet`과 같은 규칙)
    nonisolated public static func circleIsQuiet(blocked: Bool, running: Bool) -> Bool { blocked && !running }

    /// 칩의 아이콘: 세션은 에이전트 마크, 그 밖은 항목 아이콘
    nonisolated static func icon(for chip: AssistantChip) -> ContextChip.Icon {
        chip.kind == .agentSession ? .agent(.placeholder) : .item(.result)
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: TFRadius.panel, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            if !chips.isEmpty {
                ChipFlowLayout(spacing: TFSpace.xs) {
                    ForEach(chips) { chip in
                        ContextChip(
                            label: chipLabel(chip), origin: chip.origin, icon: Self.icon(for: chip), onRemove: { onRemoveChip(chip.id) },
                            onActivate: onActivateChip.map { handler in { handler(chip.id) } }, activationName: chipActivationName(chip)
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            PromptTextView(
                text: $text, contentHeight: $textHeight, placeholder: placeholder, label: "Message", isEnabled: !isBlocked, focusRequest: focusRequest,
                onFocusChange: { focused = $0 }, onSubmit: { if canSend && !isBlocked { onSend() } }
            )
            .frame(height: min(max(textHeight, Self.minTextHeight), Self.maxTextHeight))
            .padding(.horizontal, TFSpace.xxs)
            bar
        }
        .padding(Self.inset)
        .background(TFColor.bgField, in: shape)
        .overlay(shape.strokeBorder(focused ? TFColor.borderAccent : (contrast == .increased ? TFColor.borderControl : .clear), lineWidth: focused ? 1.5 : 1))
        .animation(TFMotion.ease(TFMotion.hoverFade), value: focused)
        .accessibilityElement(children: .contain)
    }

    private var bar: some View {
        HStack(spacing: TFSpace.xs) {
            TargetPill(name: targetName, mark: targetMark, isOpen: targetOpen, action: onTargetTap)
                // 대상 메뉴가 알약 위에 열리도록 알약의 자리를 알린다 (창 좌표, 위가 0)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }, action: onTargetFrame)
            Spacer(minLength: 0)
            if let onAttach {
                Button(action: onAttach) {
                    TFIcon.attach.image(size: 16)
                        .foregroundStyle(TFColor.textSecondary)
                        .frame(width: Self.sendSize, height: Self.sendSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Attach")
            }
            sendButton
        }
    }

    private var sendButton: some View {
        let quiet = Self.circleIsQuiet(blocked: isBlocked, running: isRunning)
        let enabled = isRunning || (canSend && !isBlocked)
        return Button {
            if isRunning { onStop() } else if enabled { onSend() }
        } label: {
            ZStack {
                Circle().fill(quiet ? TFColor.bgSelected : TFColor.fillInverse)
                if isRunning {
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(TFColor.textInverse).frame(width: 10, height: 10)
                } else {
                    TFIcon.send.image(size: 16).foregroundStyle(quiet ? TFColor.textSecondary : TFColor.textInverse)
                }
            }
            .frame(width: Self.sendSize, height: Self.sendSize)
            .opacity(enabled || quiet ? 1 : 0.35)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled && !quiet)
        .accessibilityLabel(Self.sendLabel(running: isRunning))
        .animation(TFMotion.ease(TFMotion.hoverFade), value: enabled)
    }
}

/// 여러 줄 글 영역 (AppKit `NSTextView`): Return 규칙 · IME 조합 중 여부를 직접 본다. 글이 길면 높이를 알리고 160pt에서 스크롤한다
struct PromptTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var contentHeight: CGFloat
    let placeholder: String
    let label: String
    let isEnabled: Bool
    let focusRequest: Int
    let onFocusChange: (Bool) -> Void
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let view = PromptNSTextView()
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.importsGraphics = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.font = PromptNSTextView.font
        view.defaultParagraphStyle = PromptNSTextView.paragraphStyle
        view.typingAttributes = PromptNSTextView.attributes(color: PromptNSTextView.textColor)
        view.insertionPointColor = PromptNSTextView.caretColor
        view.setAccessibilityLabel(label)
        view.onFocusChange = { [weak coordinator = context.coordinator] in coordinator?.parent.onFocusChange($0) }
        view.onSubmit = { [weak coordinator = context.coordinator] in coordinator?.parent.onSubmit() }
        view.onLayout = { [weak coordinator = context.coordinator] in coordinator?.reportHeight() }
        scroll.documentView = view
        context.coordinator.view = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? PromptNSTextView else { return }
        // 조합 중인 글을 덮어쓰지 않는다
        if view.string != text, !view.hasMarkedText() {
            view.string = text
            view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
            view.needsDisplay = true
            context.coordinator.reportHeight()
        }
        view.isEditable = isEnabled
        view.isSelectable = true
        view.alphaValue = isEnabled ? 1 : 0.6
        if view.placeholder != placeholder {
            view.placeholder = placeholder
            view.needsDisplay = true
        }
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            view.requestFocus()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptTextView
        weak var view: PromptNSTextView?
        var lastFocusRequest: Int

        init(_ parent: PromptTextView) {
            self.parent = parent
            lastFocusRequest = parent.focusRequest - 1
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            self.view?.needsDisplay = true
            reportHeight()
        }

        /// 글 높이를 SwiftUI에 알린다 (바뀐 때만, 다음 틱에: 그리는 중에 상태를 바꾸지 않는다)
        func reportHeight() {
            guard let view, let container = view.textContainer, let layout = view.layoutManager else { return }
            layout.ensureLayout(for: container)
            let height = ceil(layout.usedRect(for: container).height)
            guard abs(parent.contentHeight - height) > 0.5 else { return }
            let binding = parent.$contentHeight
            DispatchQueue.main.async { binding.wrappedValue = height }
        }
    }
}

final class PromptNSTextView: NSTextView {
    static let font = NSFont.systemFont(ofSize: 15)
    static var textColor: NSColor { NSColor(named: "text/primary", bundle: TFColor.bundle) ?? .labelColor }
    static var placeholderColor: NSColor { NSColor(named: "text/secondary-selected", bundle: TFColor.bundle) ?? .secondaryLabelColor }
    static var caretColor: NSColor { NSColor(named: "text/accent", bundle: TFColor.bundle) ?? .controlAccentColor }

    /// 줄 높이 20, 자간 -0.24 (DS callout)
    static var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 20
        style.maximumLineHeight = 20
        return style
    }

    static func attributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color, .kern: -0.24, .paragraphStyle: paragraphStyle]
    }

    var placeholder = ""
    var onFocusChange: (Bool) -> Void = { _ in }
    var onSubmit: () -> Void = {}
    var onLayout: () -> Void = {}
    private var wantsFocus = false

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let line = NSAttributedString(string: placeholder, attributes: Self.attributes(color: Self.placeholderColor))
        // 한 줄, 끝을 줄인다
        let rect = NSRect(x: textContainerInset.width, y: textContainerInset.height, width: max(0, bounds.width - 2 * textContainerInset.width), height: 20)
        line.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override func layout() {
        super.layout()
        onLayout()
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch PromptKeyRule.decision(
            keyCode: event.keyCode, shift: flags.contains(.shift), option: flags.contains(.option), command: flags.contains(.command),
            control: flags.contains(.control), hasMarkedText: hasMarkedText()
        ) {
        case .submit: onSubmit()
        case .newline: insertNewlineIgnoringFieldEditor(nil)
        case .passThrough: super.keyDown(with: event)
        }
    }

    /// 붙여넣기는 글자만 (서식 · 그림이 칸에 들어오지 않는다)
    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange(false) }
        return accepted
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
        setSelectedRange(NSRange(location: string.utf16.count, length: 0))
    }
}
#endif
