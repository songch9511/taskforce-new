import SwiftUI
import TaskforceKit

// Remembered 부품 (0.2.0 디자인 시스템 Molecules: RememberedNote · RememberedRow, Organism: RememberedDetail) + 설정 행의 팝업 버튼.
// 값과 동작만 받는다. 성공은 서버가 답한 뒤에만 말한다: 보내는 중에는 동작을 끄고(`isBusy`) 옛 값 그대로 둔다.

/// Select `size="sm"` (Mac 팝업 버튼): 24pt, `fill/segment`에 머리카락 테두리와 작은 그림자, 오른쪽 `chevrons-up-down`.
/// 메뉴는 시스템 메뉴라 키보드 · VoiceOver가 그대로 된다. 이름은 행의 라벨이 준다 (`label`)
public struct SettingsPopup<Value: Hashable>: View {
    let label: String
    let selection: Value?
    let choices: [(value: Value, name: String)]
    let isEnabled: Bool
    let onSelect: (Value) -> Void
    @State private var hovering = false

    public init(label: String, selection: Value?, choices: [(value: Value, name: String)], isEnabled: Bool = true, onSelect: @escaping (Value) -> Void) {
        self.label = label
        self.selection = selection
        self.choices = choices
        self.isEnabled = isEnabled
        self.onSelect = onSelect
    }

    private var selectedName: String { choices.first { $0.value == selection }?.name ?? "" }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: TFRadius.sm, style: .continuous)
        Menu {
            // 시스템 메뉴의 고른 줄 표시 (자체 기호를 그리지 않는다)
            Picker(label, selection: Binding(get: { selection }, set: { if let value = $0 { onSelect(value) } })) {
                ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                    Text(choice.name).tag(Optional(choice.value))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Text(selectedName)
                    .font(TFFont.footnote)
                    .foregroundStyle(TFColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                TFIcon.popupButton.image(size: 12)
                    .foregroundStyle(TFColor.textSecondarySelected)
            }
            .padding(.horizontal, TFSpace.sm)
            .frame(minHeight: SettingsTray.controlHeight)
            .background(hovering && isEnabled ? TFColor.bgElevated : TFColor.fillSegment, in: shape)
            .overlay(shape.strokeBorder(TFColor.borderDefault, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.14), radius: 0.5, y: 0.5)
            .contentShape(shape)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
        .accessibilityValue(selectedName)
    }
}

/// 문장을 고치는 한 줄 입력 (RememberedNote · RememberedDetail의 Edit)
struct MemoryStatementField: View {
    @Binding var text: String
    let label: String
    let onSubmit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField(label, text: $text)
            .textFieldStyle(.plain)
            .font(TFFont.footnote)
            .foregroundStyle(TFColor.textPrimary)
            .focused($focused)
            .onSubmit(onSubmit)
            .padding(.horizontal, TFSpace.sm)
            .frame(minWidth: SettingsTray.fieldWidth, maxWidth: .infinity, minHeight: SettingsTray.controlHeight)
            .background(TFColor.bgPanel, in: RoundedRectangle(cornerRadius: TFRadius.sm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: TFRadius.sm, style: .continuous).strokeBorder(focused ? TFColor.borderAccent : TFColor.borderDefault, lineWidth: focused ? 1.5 : 1))
            .accessibilityLabel(label)
            .onAppear { focused = true }
    }
}

/// RememberedNote (Molecule): Taskforce 답 아래, 대화에서 기억해 둔 것. 문장, 그 아래 kind · scope, 그다음 동작 (Confirm · Edit · Forget).
/// 추정(Inferred)은 보조 색에 "Inferred · Unconfirmed"와 Confirm. 출처의 말은 Settings › Account › Remembered에 있다.
/// 지금 기억이 아니면(잊음 · 대체 · 읽을 수 없음) 이유를 지어내지 않고 그렇게만 말한다.
public struct RememberedNote: View {
    public struct Content: Equatable, Sendable {
        public var statement: String
        public var meta: String
        public var isTentative: Bool
        public var canConfirm: Bool
        /// Edit · Forget을 줄 수 있나 (기능이 꺼져 있으면 아니다)
        public var canChange: Bool
        public var isBusy: Bool
        /// 쓰기 뒤 안내 한 줄 (충돌 · 실패)
        public var message: String?
        /// 서버 gate가 꺼져 쓰기를 못 한다고 말한다
        public var writesUnavailable: Bool

        public init(
            statement: String, meta: String, isTentative: Bool, canConfirm: Bool, canChange: Bool, isBusy: Bool = false, message: String? = nil,
            writesUnavailable: Bool = false
        ) {
            self.statement = statement
            self.meta = meta
            self.isTentative = isTentative
            self.canConfirm = canConfirm
            self.canChange = canChange
            self.isBusy = isBusy
            self.message = message
            self.writesUnavailable = writesUnavailable
        }
    }

    let content: Content?
    let onConfirm: () -> Void
    let onEdit: (String) -> Void
    let onForget: () -> Void
    @State private var editing = false
    @State private var draft = ""

    /// - content: nil이면 지금 기억이 아니다 ("No longer remembered")
    public init(content: Content?, onConfirm: @escaping () -> Void, onEdit: @escaping (String) -> Void, onForget: @escaping () -> Void) {
        self.content = content
        self.onConfirm = onConfirm
        self.onEdit = onEdit
        self.onForget = onForget
    }

    public var body: some View {
        Card(title: MemoryCopy.noteTitle) {
            if let content {
                VStack(alignment: .leading, spacing: TFSpace.xxs) {
                    if editing {
                        MemoryStatementField(text: $draft, label: MemoryCopy.statementLabel, onSubmit: { save(content) })
                    } else {
                        Text(content.statement)
                            .font(TFFont.callout)
                            .tracking(-0.24)
                            .lineSpacing(3)
                            .foregroundStyle(content.isTentative ? TFColor.textSecondarySelected : TFColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        Text(content.meta)
                            .font(TFFont.meta)
                            .foregroundStyle(TFColor.textSecondarySelected)
                    }
                    if let message = content.message {
                        Text(message)
                            .font(TFFont.meta)
                            .foregroundStyle(TFColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    actions(content)
                        .padding(.top, 6)
                }
                .padding(EdgeInsets(top: TFSpace.xs, leading: TFSpace.md, bottom: 10, trailing: TFSpace.md))
            } else {
                Text(MemoryCopy.noLongerRemembered)
                    .font(TFFont.callout)
                    .foregroundStyle(TFColor.textSecondarySelected)
                    .padding(EdgeInsets(top: TFSpace.xs, leading: TFSpace.md, bottom: 10, trailing: TFSpace.md))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func save(_ content: Content) {
        guard MemoryText.editedStatement(draft) != nil else { return }
        editing = false
        onEdit(draft)
    }

    @ViewBuilder
    private func actions(_ content: Content) -> some View {
        if content.writesUnavailable {
            Text(MemoryCopy.writesUnavailable)
                .font(TFFont.meta)
                .foregroundStyle(TFColor.textSecondarySelected)
        } else if editing {
            HStack(spacing: TFSpace.xs) {
                Button(MemoryCopy.save) { save(content) }
                    .buttonStyle(TFButtonStyle(.primary))
                    .disabled(MemoryText.editedStatement(draft) == nil || draft.trimmingCharacters(in: .whitespacesAndNewlines) == content.statement)
                Button(MemoryCopy.cancel) { editing = false }
                    .buttonStyle(TFButtonStyle(.text))
            }
        } else if content.canChange {
            HStack(spacing: TFSpace.xxs) {
                if content.canConfirm {
                    Button(MemoryCopy.confirm, action: onConfirm)
                        .buttonStyle(TFButtonStyle(.secondary))
                        .padding(.trailing, 6)
                }
                Button(MemoryCopy.edit) {
                    draft = content.statement
                    editing = true
                }
                .buttonStyle(TFButtonStyle(.text))
                Button(MemoryCopy.forgetConfirm, action: onForget)
                    .buttonStyle(TFButtonStyle(.text))
            }
            .disabled(content.isBusy)
        }
    }
}

/// RememberedRow (Molecule): 설정 목록의 기억 하나. 문장, 그 아래 kind · scope · when. 누르면 RememberedDetail. 확인 전 추정 문장은 보조 색.
public struct RememberedRow: View {
    let statement: String
    let meta: String
    let isTentative: Bool
    let onOpen: () -> Void

    public init(statement: String, meta: String, isTentative: Bool, onOpen: @escaping () -> Void) {
        self.statement = statement
        self.meta = meta
        self.isTentative = isTentative
        self.onOpen = onOpen
    }

    public var body: some View {
        SettingsTrayRow(statement, detail: meta, mutedLabel: isTentative, onOpen: onOpen)
    }
}

/// RememberedDetail (Organism): 설정에서 기억 하나. 문장(추정이면 Confirm, 그리고 Edit) · kind · scope(팝업) · 언제 · 출처 인용 · Forget(제자리 확인).
/// 추정이면 각주 하나("isn't used … until you confirm"). 출처가 없거나 지워졌으면 사실대로 말한다. Forget은 이미 한 일을 건드리지 않는다.
public struct RememberedDetail: View {
    public struct Content: Equatable {
        public var statement: String
        public var isTentative: Bool
        /// 지금 기억이 아니다 (충돌 뒤 다시 읽었더니 잊었거나 대체됨): 동작 없이 사실만
        public var isCurrent: Bool
        public var kind: String
        public var scopeName: String
        /// 비어 있으면 범위를 바꿀 수 없다 (읽기 전용 Value)
        public var scopeChoices: [MemoryScopeChoice]
        public var selectedScope: MemoryTarget?
        public var when: String
        public var source: MemorySourceDisplay
        public var canConfirm: Bool
        public var canChange: Bool
        public var isBusy: Bool
        /// 맨 위 안내 하나 (충돌 · 실패)
        public var notice: String?
        public var writesUnavailable: Bool

        public init(
            statement: String, isTentative: Bool, isCurrent: Bool = true, kind: String, scopeName: String, scopeChoices: [MemoryScopeChoice] = [],
            selectedScope: MemoryTarget? = nil, when: String, source: MemorySourceDisplay, canConfirm: Bool = false, canChange: Bool = true,
            isBusy: Bool = false, notice: String? = nil, writesUnavailable: Bool = false
        ) {
            self.statement = statement
            self.isTentative = isTentative
            self.isCurrent = isCurrent
            self.kind = kind
            self.scopeName = scopeName
            self.scopeChoices = scopeChoices
            self.selectedScope = selectedScope
            self.when = when
            self.source = source
            self.canConfirm = canConfirm
            self.canChange = canChange
            self.isBusy = isBusy
            self.notice = notice
            self.writesUnavailable = writesUnavailable
        }
    }

    let content: Content
    let onConfirm: () -> Void
    let onEdit: (String) -> Void
    let onMove: (MemoryTarget) -> Void
    let onForget: () -> Void
    let isConfirmingForget: Bool
    let onAskForget: () -> Void
    let onCancelForget: () -> Void
    let onRetrySource: () -> Void
    let onOpenURL: (URL) -> Void
    @State private var editing = false
    @State private var draft = ""

    /// - isConfirmingForget: Forget의 제자리 확인이 열려 있나. 쓰는 쪽(설정 창 모델)이 가진다: 탭 · 상세를 옮기면 닫힌다
    public init(
        content: Content, isConfirmingForget: Bool = false, onConfirm: @escaping () -> Void, onEdit: @escaping (String) -> Void,
        onMove: @escaping (MemoryTarget) -> Void, onAskForget: @escaping () -> Void = {}, onCancelForget: @escaping () -> Void = {},
        onForget: @escaping () -> Void, onRetrySource: @escaping () -> Void = {}, onOpenURL: @escaping (URL) -> Void = { _ in }
    ) {
        self.content = content
        self.isConfirmingForget = isConfirmingForget
        self.onConfirm = onConfirm
        self.onEdit = onEdit
        self.onMove = onMove
        self.onAskForget = onAskForget
        self.onCancelForget = onCancelForget
        self.onForget = onForget
        self.onRetrySource = onRetrySource
        self.onOpenURL = onOpenURL
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SettingsTray.topicGap) {
            if let notice = content.notice {
                Notice(title: notice)
            }
            SettingsSection(footnote: content.isTentative && content.isCurrent ? MemoryCopy.inferredFootnote : nil) {
                statementRow
                if content.isCurrent {
                    SettingsTrayRow(MemoryCopy.kindLabel) { SettingsValue(content.kind) }
                    scopeRow
                    SettingsTrayRow(MemoryCopy.whenLabel) { SettingsValue(content.when) }
                } else {
                    SettingsTrayRow(MemoryCopy.noLongerRemembered)
                }
            }
            sourceSection
            if content.isCurrent, content.canChange, !content.writesUnavailable {
                SettingsSection {
                    if isConfirmingForget {
                        ConfirmRow(
                            MemoryCopy.forgetTitle, detail: MemoryCopy.forgetDetail, confirmLabel: MemoryCopy.forgetConfirm, busy: content.isBusy,
                            onConfirm: onForget, onCancel: onCancelForget
                        )
                    } else {
                        SettingsTrayRow("Forget") {
                            Button(MemoryCopy.forgetOpen, action: onAskForget)
                                .buttonStyle(TFButtonStyle())
                                .disabled(content.isBusy)
                        }
                    }
                }
            } else if content.writesUnavailable, content.isCurrent {
                SettingsSection(footnote: MemoryCopy.writesUnavailable) {}
            }
        }
        // 다른 항목으로 바뀌면 열린 편집을 닫는다
        .onChange(of: content.statement) { editing = false }
    }

    // MARK: 문장

    private var statementRow: some View {
        VStack(alignment: .leading, spacing: TFSpace.sm) {
            if editing {
                Text(MemoryCopy.statementLabel)
                    .font(TFFont.footnote)
                    .foregroundStyle(TFColor.textPrimary)
                HStack(spacing: TFSpace.sm) {
                    MemoryStatementField(text: $draft, label: MemoryCopy.statementLabel, onSubmit: save)
                    Button(MemoryCopy.save, action: save)
                        .buttonStyle(TFButtonStyle(.primary))
                        .disabled(MemoryText.editedStatement(draft) == nil || draft.trimmingCharacters(in: .whitespacesAndNewlines) == content.statement)
                    Button(MemoryCopy.cancel) { editing = false }
                        .buttonStyle(TFButtonStyle(.text))
                }
            } else {
                Text(content.statement)
                    .font(TFFont.footnote)
                    .foregroundStyle(content.isTentative ? TFColor.textSecondary : TFColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                if content.isCurrent, content.canChange, !content.writesUnavailable {
                    HStack(spacing: TFSpace.sm) {
                        if content.canConfirm {
                            Button(MemoryCopy.confirm, action: onConfirm).buttonStyle(TFButtonStyle(.primary))
                        }
                        Button(MemoryCopy.edit) {
                            draft = content.statement
                            editing = true
                        }
                        .buttonStyle(TFButtonStyle())
                    }
                    .disabled(content.isBusy)
                }
            }
        }
        .padding(SettingsTray.rowPadding)
        .frame(maxWidth: .infinity, minHeight: SettingsTray.rowMinHeight, alignment: .leading)
    }

    private func save() {
        guard MemoryText.editedStatement(draft) != nil else { return }
        editing = false
        onEdit(draft)
    }

    // MARK: 범위

    @ViewBuilder
    private var scopeRow: some View {
        if content.scopeChoices.isEmpty || !content.canChange || content.writesUnavailable {
            SettingsTrayRow(MemoryCopy.scopeLabel) { SettingsValue(content.scopeName) }
        } else {
            SettingsTrayRow(MemoryCopy.scopeLabel) {
                SettingsPopup(
                    label: MemoryCopy.scopeLabel, selection: content.selectedScope, choices: content.scopeChoices.map { ($0.target, $0.name) },
                    isEnabled: !content.isBusy
                ) { target in
                    if target != content.selectedScope { onMove(target) }
                }
            }
        }
    }

    // MARK: 출처

    @ViewBuilder
    private var sourceSection: some View {
        switch content.source {
        case .hidden, .loading:
            EmptyView()
        case .failed:
            SettingsSection(MemoryCopy.sourceTitle) {
                SettingsTrayRow("Couldn't load the source") {
                    Button(MemoryCopy.tryAgain, action: onRetrySource).buttonStyle(TFButtonStyle())
                }
            }
        case .unavailable(let text):
            SettingsSection(MemoryCopy.sourceTitle) {
                SettingsTrayRow(text)
            }
        case .quote(let quote):
            SettingsSection(MemoryCopy.sourceTitle) {
                SourceQuote(
                    service: quote.service, from: quote.from, place: quote.place, time: quote.time.map { WhenText.label($0) }, text: quote.text,
                    openTitle: quote.service?.openTitle, onOpen: quote.url.map { url in { onOpenURL(url) } }
                )
                .padding(SettingsTray.rowPadding)
            }
        }
    }
}

#Preview("Remembered") {
    ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            RememberedNote(
                content: .init(statement: "Keeps pricing-page FAQs short", meta: "Explicit · Shape launch", isTentative: false, canConfirm: false, canChange: true),
                onConfirm: {}, onEdit: { _ in }, onForget: {}
            )
            RememberedNote(
                content: .init(statement: "Jordan Lee decides partner dates", meta: "Inferred · Unconfirmed · Shape launch", isTentative: true, canConfirm: true, canChange: true),
                onConfirm: {}, onEdit: { _ in }, onForget: {}
            )
            SettingsSection(footnote: MemoryCopy.listFootnote) {
                RememberedRow(statement: "Keeps pricing-page FAQs short", meta: "Explicit · Shape launch · Today 10:24", isTentative: false) {}
                RememberedRow(statement: "Jordan Lee decides partner dates", meta: "Inferred · Unconfirmed · Shape launch · Today 10:42", isTentative: true) {}
            }
        }
        .padding(20)
    }
    .frame(width: 560, height: 640)
    .background(TFColor.bgSurface)
}
