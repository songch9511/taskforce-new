#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit

/// QuestionCard가 부르는 동작 (OA D4b-m-1): 카드는 그리고 키만 풀어서 이 동작을 부른다. 상태(접힘 · 2초 보류 · Undo · 실패)는 `AgentQuestionStore`에 있다
public struct QuestionCardActions {
    /// 줄 하나를 골랐다 (단일 · 승인 · Other의 선택지 · Other 줄: 줄 번호)
    public var onChoose: (Int) -> Void
    /// 체크 상자 하나를 켜고 껐다
    public var onToggle: (Int) -> Void
    /// 체크한 것을 보낸다
    public var onSendChecked: () -> Void
    /// 입력한 글을 보낸다 (Other · 글만)
    public var onSubmitText: (String) -> Void
    /// 비밀값을 보낸다 (마스크 칸에서 한 번 읽은 값. 칸은 이미 비워졌다)
    public var onSubmitSecret: (SecretBox) -> Void
    /// Other 입력 칸을 줄로 되돌린다
    public var onCloseOther: () -> Void
    public var onUndo: () -> Void
    /// 카드(또는 그 줄)가 포커스를 가졌다 · 잃었다 (입력 칸은 세지 않는다)
    public var onFocusChange: (Bool) -> Void

    public init(
        onChoose: @escaping (Int) -> Void = { _ in }, onToggle: @escaping (Int) -> Void = { _ in }, onSendChecked: @escaping () -> Void = {},
        onSubmitText: @escaping (String) -> Void = { _ in }, onSubmitSecret: @escaping (SecretBox) -> Void = { _ in }, onCloseOther: @escaping () -> Void = {},
        onUndo: @escaping () -> Void = {}, onFocusChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.onChoose = onChoose
        self.onToggle = onToggle
        self.onSendChecked = onSendChecked
        self.onSubmitText = onSubmitText
        self.onSubmitSecret = onSubmitSecret
        self.onCloseOther = onCloseOther
        self.onUndo = onUndo
        self.onFocusChange = onFocusChange
    }
}

/// QuestionCard (0.2.0 디자인 시스템 Molecules, OA D4b-m-1): 에이전트가 올린 질문. 프롬프트 박스 바로 위에 고정되어 다른 무엇을 쓰기 전에 답하게 한다 (모달이 아니다).
/// 일곱 종류(`AgentQuestionCard.Kind`: single · multi · other · text · approval · secret · secretRemote)와 세 상태가 있다.
/// - **면**: `bg/field`, 모서리 12, 안쪽 12, 간격 6. 질문(callout-strong) → 메타(footnote) → 답 줄들(16 아래, 줄 사이 6). 줄은 `bg/elevated` 모서리 8, 안쪽 10/12, 글은 callout. 번호(Keycap)는 줄이 정확히 넷일 때만
/// - **open**: 위 모양. 실패하면(`failure`) 메타 밑에 굵은 "Couldn't send" + 이유 한 줄이 붙는다 (빨강 아님: 빨강은 기한 · 입력 오류뿐)
/// - **holding**: 고른 순간 한 줄로 접힌다: 체크 · "Answer sent" · 고른 답(footnote, 보조) · Undo(`text/accent` 링크). 앱이 2초 쥐고 있다가 보낸다
/// - **sent**: 같은 줄에서 Undo만 없다
/// - **비밀값**: 자물쇠 + 마스크 칸. 값은 칸에서 한 번 읽고 칸을 비운다. 접힌 줄에도 값이 없다
/// 키: 1–4는 카드(또는 줄)에 포커스가 있을 때만 (입력 칸에서는 글자). 키 규칙은 `AgentQuestionKeyboard`다 (순수 함수, 시험으로 고정)
public struct QuestionCard: View {
    public enum Status: Equatable, Sendable {
        case open
        /// 접혔고 Undo가 있다 (2초 보류)
        case holding
        /// 접혔고 Undo가 없다 (보내는 중 · 보냈다)
        case sent
    }

    /// 카드 안에서 포커스가 어디 있나
    enum Focus: Hashable {
        case card
        case row(Int)
    }

    /// 카드가 그 면 높이의 이만큼을 넘으면 카드 안에서 스크롤한다 (대화가 보이게 남기는 값, D4bm-17)
    nonisolated public static let maxHeightShare: CGFloat = 0.6

    let card: AgentQuestionCard
    let status: Status
    let summary: String?
    let failure: AgentQuestionFailure?
    let checked: Set<Int>
    let otherOpen: Bool
    let initialText: String
    let remoteRow: String?
    let focusRequest: Int
    let maxHeight: CGFloat?
    let actions: QuestionCardActions

    @FocusState private var focus: Focus?
    @State private var draft = ""
    @State private var fieldFocused = false
    @State private var fieldFocusRequest = 0
    @State private var secretHasText = false
    @State private var secretClear = 0
    @State private var secretHandle = SecretFieldHandle()
    @State private var contentHeight: CGFloat = 0
    @Environment(\.colorSchemeContrast) private var contrast

    /// - remoteRow: 다른 기기 비밀값 카드의 "Answer on <Mac>" 줄 (이름을 모르고 대체 문구도 아직 없으면 nil: 줄을 그리지 않는다)
    /// - focusRequest: 오를 때마다 포커스가 카드로 온다 (링 · 알림으로 세션이 열릴 때). 입력 카드는 입력 칸이 받는다
    /// - maxHeight: 이 값을 넘으면 카드 안에서 스크롤한다 (nil이면 자라는 대로)
    public init(
        card: AgentQuestionCard, status: Status = .open, summary: String? = nil, failure: AgentQuestionFailure? = nil, checked: Set<Int> = [], otherOpen: Bool = false,
        initialText: String = "", remoteRow: String? = nil, focusRequest: Int = 0, maxHeight: CGFloat? = nil, actions: QuestionCardActions = QuestionCardActions()
    ) {
        self.card = card
        self.status = status
        self.summary = summary
        self.failure = failure
        self.checked = checked
        self.otherOpen = otherOpen
        self.initialText = initialText
        self.remoteRow = remoteRow
        self.focusRequest = focusRequest
        self.maxHeight = maxHeight
        self.actions = actions
    }

    // MARK: 순수 규칙 (시험)

    /// 접근성 이름: 질문 줄
    nonisolated public static func accessibilityName(_ card: AgentQuestionCard) -> String { card.accessibilityName }

    /// 줄의 접근성 힌트: 번호가 보이면 "Press n", 설명이 있으면 그것 (설명은 화면에 그리지 않는다, D4bm-13)
    nonisolated public static func rowHint(card: AgentQuestionCard, index: Int) -> String? {
        let key = card.showsKeycaps ? "Press \(index + 1)" : nil
        return [card.rows[index].hint, key].compactMap { $0 }.joined(separator: ". ").nilIfEmpty
    }

    /// 줄 앞 번호 (Keycap): 정확히 네 줄일 때만 1부터
    nonisolated public static func keycap(card: AgentQuestionCard, index: Int) -> String? {
        card.showsKeycaps ? String(index + 1) : nil
    }

    /// 접힌 줄의 접근성 이름: "Answer sent" + 고른 답 (비밀값은 값이 없다)
    nonisolated public static func foldedName(summary: String?) -> String {
        [AgentQuestionCopy.answerSent, summary].compactMap { $0 }.joined(separator: ". ")
    }

    /// 실패 줄의 두 조각: 굵은 앞 말과 보조색 이유
    nonisolated public static func failureLine(_ failure: AgentQuestionFailure) -> (lead: String, reason: String) {
        (AgentQuestionFailure.lead, " · " + failure.reason)
    }

    /// 다중 선택의 Send는 하나라도 체크되기 전까지 꺼져 있다
    nonisolated public static func sendEnabled(kind: AgentQuestionCard.Kind, checkedCount: Int, hasText: Bool) -> Bool {
        switch kind {
        case .multi: checkedCount > 0
        case .other, .text, .secret: hasText
        case .single, .approval, .secretRemote: false
        }
    }

    /// 눌린 키를 규칙의 키로 (모르는 키는 nil)
    nonisolated static func keyboardKey(key: KeyEquivalent, characters: String) -> AgentQuestionKeyboard.Key? {
        switch key {
        case .return: return .return
        case .space: return .space
        case .escape: return .escape
        case .upArrow: return .up
        case .downArrow: return .down
        default:
            if characters.count == 1, let number = Int(characters) { return .digit(number) }
            return nil
        }
    }

    nonisolated static func phase(_ status: Status) -> AgentQuestionStore.Phase {
        switch status {
        case .open: .open
        case .holding: .holding
        case .sent: .sent
        }
    }

    /// 규칙이 보는 포커스
    private var keyboardFocus: AgentQuestionKeyboard.Focus {
        if fieldFocused { return .field }
        switch focus {
        case .row(let index)?: return .row(index)
        default: return .card
        }
    }

    private var hasFieldText: Bool {
        card.kind == .secret ? secretHasText : !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: 몸

    public var body: some View {
        Group {
            if status == .open {
                scrolling { openContent }
            } else {
                folded
            }
        }
        .padding(TFSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TFColor.bgField, in: shape)
        .overlay(shape.strokeBorder(contrast == .increased ? TFColor.borderControl : .clear, lineWidth: 1))
        .focusable()
        .focused($focus, equals: .card)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { handle($0) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(status == .open ? Self.accessibilityName(card) : Self.foldedName(summary: summary))
        .onAppear { draft = initialText }
        .onChange(of: initialText) { _, new in draft = new }
        .onChange(of: otherOpen) { _, open in if open { fieldFocusRequest += 1 } }
        .onChange(of: focusRequest) { focusFromOutside() }
        .onChange(of: focus) { _, _ in reportFocus() }
        .onChange(of: fieldFocused) { _, _ in reportFocus() }
        .onChange(of: status) { old, new in
            // 접히거나 펴져도 포커스가 카드를 떠나지 않는다 (Esc가 Undo가 되려면 카드에 포커스가 있어야 한다)
            if old == .open, new != .open, focus != nil || fieldFocused { focus = .card }
            if old != .open, new == .open { secretClear += 1 }
        }
        .onChange(of: failure) { _, new in
            if let new { AccessibilityNotification.Announcement("\(Self.failureLine(new).lead)\(Self.failureLine(new).reason)").post() }
        }
        .task(id: card.promptID) { if focusRequest > 0 { focusFromOutside() } }
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: TFRadius.panel, style: .continuous) }

    @ViewBuilder
    private func scrolling<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let body = content().onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
        if let maxHeight, contentHeight > maxHeight {
            ScrollView(.vertical) { body }.frame(height: maxHeight)
        } else {
            body
        }
    }

    // MARK: 열린 카드

    private var openContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(card.title)
                .font(TFFont.calloutEmphasis)
                .tracking(-0.24)
                .foregroundStyle(TFColor.textPrimary)
                .dsCallout()
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let meta = card.meta {
                Text(meta)
                    .font(TFFont.footnote)
                    .tracking(-0.08)
                    .foregroundStyle(TFColor.textSecondarySelected)
                    .dsFootnote()
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failure { failureView(failure) }
            answers
                .padding(.top, 10)
            if card.kind == .multi { multiFooter }
        }
    }

    private func failureView(_ failure: AgentQuestionFailure) -> some View {
        let line = Self.failureLine(failure)
        return (Text(line.lead).font(TFFont.footnoteEmphasis).foregroundStyle(TFColor.textPrimary) + Text(line.reason).font(TFFont.footnote).foregroundStyle(TFColor.textSecondarySelected))
            .tracking(-0.08)
            .dsFootnote()
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isStaticText)
    }

    @ViewBuilder
    private var answers: some View {
        VStack(alignment: .leading, spacing: 6) {
            if card.kind == .approval, let preview = card.preview { previewLine(preview) }
            switch card.kind {
            case .single, .approval:
                ForEach(Array(card.rows.enumerated()), id: \.offset) { index, row in pickRow(index, row) }
            case .other:
                ForEach(Array(card.rows.enumerated()), id: \.offset) { index, row in
                    if row.isOther && otherOpen { otherField } else { pickRow(index, row) }
                }
            case .multi:
                ForEach(Array(card.rows.enumerated()), id: \.offset) { index, row in checkRow(index, row) }
            case .text:
                textField
            case .secret:
                secretField
            case .secretRemote:
                if let remoteRow { remoteDisplay(remoteRow) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func previewLine(_ text: String) -> some View {
        Text(text)
            .font(TFFont.footnote)
            .tracking(-0.08)
            .foregroundStyle(TFColor.textPrimary)
            .lineLimit(1)
            .truncationMode(.tail)
            .dsFootnote()
            .padding(.vertical, TFSpace.sm)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TFColor.bgElevated, in: RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous).strokeBorder(contrast == .increased ? TFColor.borderControl : .clear, lineWidth: 1))
            .help(text)
            .accessibilityLabel("\(AgentQuestionCopy.previewLabel): \(text)")
    }

    private func pickRow(_ index: Int, _ row: AgentQuestionCard.Row) -> some View {
        QuestionRowButton(
            label: row.label, keycap: Self.keycap(card: card, index: index), checked: nil, hint: row.hint, accessibilityHint: Self.rowHint(card: card, index: index),
            isFocused: focus == .row(index)
        ) { actions.onChoose(index) }
            .focusable()
            .focused($focus, equals: .row(index))
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { handle($0) }
    }

    private func checkRow(_ index: Int, _ row: AgentQuestionCard.Row) -> some View {
        QuestionRowButton(
            label: row.label, keycap: nil, checked: checked.contains(index), hint: row.hint, accessibilityHint: Self.rowHint(card: card, index: index), isFocused: focus == .row(index)
        ) { actions.onToggle(index) }
            .focusable()
            .focused($focus, equals: .row(index))
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { handle($0) }
    }

    private var multiFooter: some View {
        HStack(spacing: TFSpace.sm) {
            Spacer(minLength: 0)
            Keycap("Return").accessibilityHidden(true)
            Button(AgentQuestionCopy.send) { actions.onSendChecked() }
                .buttonStyle(TFButtonStyle(.primary, size: .sm))
                .disabled(!Self.sendEnabled(kind: .multi, checkedCount: checked.count, hasText: false))
        }
    }

    // MARK: 입력 칸

    private func fieldBox<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous)
        return HStack(spacing: TFSpace.sm) { content() }
            .padding(EdgeInsets(top: 0, leading: TFSpace.md, bottom: 0, trailing: 6))
            .frame(minHeight: 40)
            .background(TFColor.bgElevated, in: shape)
            .overlay(shape.strokeBorder(fieldFocused ? TFColor.borderAccent : (contrast == .increased ? TFColor.borderControl : .clear), lineWidth: fieldFocused ? 1.5 : 1))
            .animation(TFMotion.ease(TFMotion.hoverFade), value: fieldFocused)
    }

    /// Other의 입력 칸 · 글만 질문의 입력 칸 (같은 모양: 글 + 잉크 보내기 원)
    private func textBox(label: String) -> some View {
        fieldBox {
            ComposerTextField(
                text: $draft, placeholder: "", label: label, isEnabled: true, focusRequest: fieldFocusRequest, claimsFocusOnCreation: false, onFocusChange: { fieldFocused = $0 },
                onSubmit: { submitText() }
            )
            sendCircle(enabled: Self.sendEnabled(kind: .other, checkedCount: 0, hasText: hasFieldText)) { submitText() }
        }
    }

    private var otherField: some View { textBox(label: AgentQuestionCopy.otherField) }

    private var textField: some View { textBox(label: card.title) }

    private var secretField: some View {
        fieldBox {
            LockGlyph().foregroundStyle(TFColor.textSecondary).frame(width: 16, height: 16).accessibilityHidden(true)
            SecretField(
                label: AgentQuestionCopy.secretFieldLabel, focusRequest: fieldFocusRequest, clearToken: secretClear, handle: secretHandle,
                onFocusChange: { fieldFocused = $0 }, onHasText: { secretHasText = $0 }, onSubmit: { actions.onSubmitSecret($0) }
            )
            sendCircle(enabled: secretHasText) { secretHandle.submit() }
        }
    }

    private func remoteDisplay(_ text: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous)
        return HStack(spacing: TFSpace.sm) {
            LockGlyph().foregroundStyle(TFColor.textSecondary).frame(width: 16, height: 16).accessibilityHidden(true)
            Text(text)
                .font(TFFont.callout)
                .tracking(-0.24)
                .foregroundStyle(TFColor.textSecondary)
                .dsCallout()
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, TFSpace.md)
        .frame(minHeight: 40)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TFColor.bgElevated, in: shape)
        .overlay(shape.strokeBorder(contrast == .increased ? TFColor.borderControl : .clear, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private func sendCircle(enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            TFIcon.send.image(size: 16)
                .foregroundStyle(TFColor.textInverse)
                .frame(width: 28, height: 28)
                .background(TFColor.fillInverse, in: Circle())
                .opacity(enabled ? 1 : 0.35)
                .contentShape(Circle())
        }
        .buttonStyle(SendCircleStyle())
        .disabled(!enabled)
        .accessibilityLabel(AgentQuestionCopy.send)
    }

    private func submitText() {
        guard hasFieldText else { return }
        actions.onSubmitText(draft)
    }

    // MARK: 접힌 줄

    private var folded: some View {
        HStack(spacing: 10) {
            TFIcon.check.image(size: 16)
                .foregroundStyle(TFColor.textPrimary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(AgentQuestionCopy.answerSent)
                    .font(TFFont.calloutEmphasis)
                    .tracking(-0.24)
                    .foregroundStyle(TFColor.textPrimary)
                    .dsCallout()
                if let summary {
                    Text(summary)
                        .font(TFFont.footnote)
                        .tracking(-0.08)
                        .foregroundStyle(TFColor.textSecondarySelected)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .dsFootnote()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if status == .holding {
                LinkButton(AgentQuestionCopy.undo) { actions.onUndo() }
                    .font(TFFont.callout)
                    .tracking(-0.24)
                    .accessibilityLabel(AgentQuestionCopy.undo)
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: 포커스 · 키

    private func reportFocus() {
        actions.onFocusChange(focus != nil && !fieldFocused)
    }

    /// 링 · 알림으로 세션이 열렸다 · 보낸 글이 질문 곁 대기열에 들어갔다: 입력 카드는 입력 칸이, 그 밖에는 카드가 포커스를 받는다
    private func focusFromOutside() {
        guard status == .open else {
            focus = .card
            return
        }
        switch card.kind {
        case .text, .secret: fieldFocusRequest += 1
        case .other where otherOpen: fieldFocusRequest += 1
        default: focus = .card
        }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard let key = Self.keyboardKey(key: press.key, characters: press.characters) else { return .ignored }
        let modified = !press.modifiers.intersection([.command, .control, .option]).isEmpty
        let context = AgentQuestionKeyboard.Context(
            card: card, phase: Self.phase(status), focus: keyboardFocus, checkedCount: checked.count, otherOpen: otherOpen, fieldHasText: hasFieldText
        )
        switch AgentQuestionKeyboard.resolve(key, modified: modified, context) {
        case .choose(let index): actions.onChoose(index)
        case .toggle(let index): actions.onToggle(index)
        case .sendChecked: actions.onSendChecked()
        case .submitField: if card.kind == .secret { secretHandle.submit() } else { submitText() }
        case .moveFocus(let delta): moveFocus(by: delta)
        case .cancelOther: actions.onCloseOther()
        case .undo: actions.onUndo()
        case .none: return .ignored
        }
        return .handled
    }

    private func moveFocus(by delta: Int) {
        guard !card.rows.isEmpty else { return }
        let current: Int
        if case .row(let index)? = focus { current = index } else { current = delta > 0 ? -1 : card.rows.count }
        focus = .row(min(max(current + delta, 0), card.rows.count - 1))
    }
}

/// 답 줄 하나 (`.tf-qopt`): 번호 키 또는 체크 상자 + 글. 호버하면 한 겹 어두워진다. 설명(`hint`)은 도움말로만 보인다
private struct QuestionRowButton: View {
    let label: String
    let keycap: String?
    /// nil = 고르는 줄, true/false = 체크 상자
    let checked: Bool?
    let hint: String?
    let accessibilityHint: String?
    let isFocused: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous)
        Button(action: action) {
            HStack(spacing: 10) {
                if let checked {
                    CheckBoxGlyph(isOn: checked)
                } else if let keycap {
                    Keycap(keycap)
                }
                Text(label)
                    .font(TFFont.callout)
                    .tracking(-0.24)
                    .foregroundStyle(TFColor.textPrimary)
                    .multilineTextAlignment(.leading)
                    .dsCallout()
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, TFSpace.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TFColor.bgElevated, in: shape)
            .overlay { if hovering { shape.fill(TFColor.bgSelected) } }
            .overlay(shape.strokeBorder(contrast == .increased ? TFColor.borderControl : .clear, lineWidth: 1))
            .overlay { if isFocused { shape.strokeBorder(TFColor.borderAccent, lineWidth: 2).padding(-3) } }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(TFMotion.ease(TFMotion.hoverFade), value: hovering)
        .help(hint ?? "")
        .accessibilityLabel(label)
        .accessibilityHint(accessibilityHint ?? "")
        .accessibilityAddTraits(checked == true ? .isSelected : [])
        .accessibilityValue(checked.map { $0 ? "Checked" : "Unchecked" } ?? "")
    }
}

/// 보내기 원의 버튼 모양: 꺼진 모양(`.tf-send:disabled`, 35%)은 원이 직접 그린다. 기본 plain 스타일은 꺼진 버튼을 한 번 더 흐리게 해서 35%가 겹쳐 DS보다 옅어지므로 쓰지 않는다
private struct SendCircleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}

/// 체크 상자 (`.tf-box`): 18, 모서리 sm, 꺼짐은 1.5 `border/control` 테두리, 켜짐은 잉크 + `text/inverse` 체크
private struct CheckBoxGlyph: View {
    let isOn: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TFRadius.sm, style: .continuous)
        ZStack {
            if isOn {
                shape.fill(TFColor.fillInverse)
                TFIcon.check.image(size: 12).foregroundStyle(TFColor.textInverse)
            } else {
                shape.strokeBorder(TFColor.borderControl, lineWidth: 1.5)
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}

/// 자물쇠 (Lucide `lock`, 24 격자의 선): 이 아이콘은 아직 토큰 아이콘 모음에 없어 같은 모양을 선으로 그린다
struct LockGlyph: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 24
            var body = Path()
            body.addRoundedRect(in: CGRect(x: 3 * scale, y: 11 * scale, width: 18 * scale, height: 11 * scale), cornerSize: CGSize(width: 2 * scale, height: 2 * scale))
            var shackle = Path()
            shackle.move(to: CGPoint(x: 7 * scale, y: 11 * scale))
            shackle.addLine(to: CGPoint(x: 7 * scale, y: 7 * scale))
            shackle.addArc(center: CGPoint(x: 12 * scale, y: 7 * scale), radius: 5 * scale, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            shackle.addLine(to: CGPoint(x: 17 * scale, y: 11 * scale))
            let style = StrokeStyle(lineWidth: 2 * scale, lineCap: .round, lineJoin: .round)
            context.stroke(body, with: .foreground, style: style)
            context.stroke(shackle, with: .foreground, style: style)
        }
    }
}

// MARK: 마스크 칸

/// 마스크 칸이 "보내기"를 부르는 길 (보내기 원 · Return이 같은 길을 쓴다)
@MainActor
final class SecretFieldHandle {
    weak var field: SecretNSField?
    func submit() { field?.submitValue() }
}

/// 비밀값 입력 칸 (AppKit `NSSecureTextField`): 값은 칸에서 **한 번** 읽고 곧바로 칸을 비운다. 실행 취소 기록 · 접근성 값(마스크) · UserDefaults에 남기지 않는다
struct SecretField: NSViewRepresentable {
    let label: String
    let focusRequest: Int
    /// 바뀔 때마다 칸을 비운다 (Undo · 실패로 카드가 돌아왔을 때)
    let clearToken: Int
    let handle: SecretFieldHandle
    let onFocusChange: (Bool) -> Void
    let onHasText: (Bool) -> Void
    let onSubmit: (SecretBox) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> SecretNSField {
        let field = SecretNSField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.setAccessibilityLabel(label)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.onFocusChange = { [weak coordinator = context.coordinator] in coordinator?.parent.onFocusChange($0) }
        field.onSubmit = { [weak coordinator = context.coordinator] box in coordinator?.parent.onSubmit(box) }
        handle.field = field
        return field
    }

    func updateNSView(_ field: SecretNSField, context: Context) {
        context.coordinator.parent = self
        handle.field = field
        if context.coordinator.lastClear != clearToken {
            context.coordinator.lastClear = clearToken
            field.wipe()
            onHasText(false)
        }
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            field.requestFocus()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SecretField
        var lastFocusRequest: Int
        var lastClear: Int

        init(_ parent: SecretField) {
            self.parent = parent
            // 처음 0은 요청 없음이다 (새 카드가 요청 없이 포커스를 가져가지 않는다, D4bm-31). 요청이 이미 있었으면(>0) 처음에 한 번 받는다
            lastFocusRequest = max(parent.focusRequest - 1, 0)
            lastClear = parent.clearToken
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.onHasText(!field.stringValue.isEmpty)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard ComposerKeyRule.shouldSubmit(selector: commandSelector, hasMarkedText: textView.hasMarkedText()), let field = control as? SecretNSField else { return false }
            field.submitValue()
            return true
        }
    }
}

final class SecretNSField: NSSecureTextField {
    var onFocusChange: (Bool) -> Void = { _ in }
    var onSubmit: (SecretBox) -> Void = { _ in }
    private var wantsFocus = false

    /// 값을 한 번 읽고 칸을 비운다. 빈 값은 보내지 않는다
    func submitValue() {
        let value = stringValue
        guard !value.isEmpty else { return }
        wipe()
        onSubmit(SecretBox(value))
    }

    /// 칸 · 필드 에디터 · 실행 취소 기록을 모두 비운다
    func wipe() {
        stringValue = ""
        if let editor = currentEditor() as? NSTextView {
            editor.string = ""
            editor.undoManager?.removeAllActions()
        }
        undoManager?.removeAllActions()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            // 실행 취소 기록에 입력을 남기지 않는다
            (currentEditor() as? NSTextView)?.allowsUndo = false
            onFocusChange(true)
        }
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
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension View {
    /// DS 줄 높이 callout 15/20: SwiftUI의 자연 줄 높이는 19다 (측정). 줄 사이에 1을 더하고 위아래 0.5씩 더해 n줄이 20n이 되게 한다
    fileprivate func dsCallout() -> some View {
        lineSpacing(1).padding(.vertical, 0.5)
    }

    /// DS 줄 높이 footnote 13/18: 자연 줄 높이는 16이다 (측정). 줄 사이에 2를 더하고 위아래 1씩 더해 n줄이 18n이 되게 한다
    fileprivate func dsFootnote() -> some View {
        lineSpacing(2).padding(.vertical, 1)
    }
}

#Preview("Question cards") {
    ScrollView {
        VStack(spacing: 12) {
            QuestionCard(card: .init(promptID: "q", kind: .single, title: "Which price should lead the yearly card?", meta: "outside the brief", rows: ["First-month price", "Monthly price", "Yearly total", "Price per month"].map { .init(label: $0) }))
            QuestionCard(
                card: .init(promptID: "q", kind: .multi, title: "Which plans show the 3-day trial?", meta: "Choose any", rows: ["Pro monthly", "Pro yearly", "Lifetime"].map { .init(label: $0) }), checked: [0, 1]
            )
            QuestionCard(card: .init(promptID: "q", kind: .secret, title: "Enter the staging deploy token", meta: "Stays on this Mac"))
            QuestionCard(card: .init(promptID: "q", kind: .single, title: "Which price should lead the yearly card?", rows: []), status: .holding, summary: "First-month price")
        }
        .padding(12)
    }
    .frame(width: 380, height: 700)
    .background(TFColor.bgPanel)
}
#endif
