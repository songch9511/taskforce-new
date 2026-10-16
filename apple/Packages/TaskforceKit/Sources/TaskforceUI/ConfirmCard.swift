import SwiftUI
import TaskforceKit

/// 두 번 눌러도 한 번만 동작하게 하는 문 (ConfirmCard의 단추 · 같은 대상의 반복 누름)
public struct OneShot: Equatable, Sendable {
    private var claimed = false

    public init() {}

    /// 처음 부르면 true, 그다음은 `reset` 전까지 false
    public mutating func claim() -> Bool {
        guard !claimed else { return false }
        claimed = true
        return true
    }

    public mutating func reset() { claimed = false }
}

/// ConfirmCard (0.2.0 디자인 시스템 Molecules, OA D4a): 되돌리기 어려운 일 앞의 예 · 아니오 하나 (이슈 삭제 · 병합, 터미널에서 연 세션 Resume here). 질문 카드 자리 — 프롬프트 박스 바로 위에 열린다. **모달이 아니다**.
/// - 질문 카드와 같은 면: `bg/field` · 모서리 12 · 안쪽 12 · 간격 6. 제목 callout 15/20 semibold, `detail` callout, `rows`(라벨 footnote 52 열 · 값 callout), `meta` footnote `text/secondary-selected`, 그 아래 단추 둘 (위 6)
/// - 주 단추는 하나: 일어나는 동사 ("Delete" · "Merge" · "Resume here", "Confirm" · "OK"가 아니다). Cancel은 secondary(`bg/selected`: 카드 면 위에서 읽힌다)
/// - `autoFocus`면 Cancel이 먼저 포커스를 받는다 (안전한 쪽). Return · Esc는 **포커스가 이 카드 안에 있을 때만** 이 카드의 일이다: 입력칸에서 쓰다 누른 Return이 카드를 확정하지 않는다
/// - `error`는 입력 오류 한 줄(`status/overdue`): 이 카드의 유일한 빨강이다. 접근성 알림으로 읽힌다. `busy`면 단추가 꺼진다
public struct ConfirmCard: View {
    public struct Row: Equatable, Sendable {
        public let label: String
        public let value: String

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }

        public var accessibilityLabel: String { "\(label): \(value)" }
    }

    public enum Focus: Hashable, Sendable {
        case confirm, cancel
    }

    public struct ButtonSpec: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case primary, secondary }

        public let kind: Kind
        public let title: String
    }

    nonisolated public static let defaultCancelLabel = "Cancel"
    nonisolated public static let errorColor = TFColor.statusOverdue

    /// 단추 둘: 주 동작이 먼저, Cancel이 뒤
    nonisolated public static func buttons(confirmLabel: String, cancelLabel: String = defaultCancelLabel) -> [ButtonSpec] {
        [ButtonSpec(kind: .primary, title: confirmLabel), ButtonSpec(kind: .secondary, title: cancelLabel)]
    }

    /// 처음 포커스: `autoFocus`면 Cancel (카드가 키를 가져가지 않으면 nil: 입력칸에서 쓰던 글을 건드리지 않는다)
    nonisolated public static func initialFocus(autoFocus: Bool) -> Focus? { autoFocus ? .cancel : nil }

    /// Return이 누르는 단추: 포커스가 있는 단추다 (카드에 포커스가 없으면 Return은 카드의 일이 아니다)
    nonisolated public static func returnTarget(focus: Focus?) -> Focus? { focus }

    /// Esc가 Cancel인가: 카드가 포커스를 가졌을 때 (아니면 패널의 Esc 차례가 처리한다)
    nonisolated public static func escapeCancels(focus: Focus?) -> Bool { focus != nil }

    /// 입력 오류를 접근성 알림으로 읽을 글 (없으면 nil)
    nonisolated public static func errorAnnouncement(_ error: String?) -> String? {
        guard let error, !error.isEmpty else { return nil }
        return error
    }

    nonisolated public static func accessibilityTraits(forError hasError: Bool) -> AccessibilityTraits {
        hasError ? [.isStaticText] : []
    }

    nonisolated public static func buttonsDisabled(busy: Bool) -> Bool { busy }

    let title: String
    let detail: String?
    let rows: [Row]
    let meta: String?
    let error: String?
    let confirmLabel: String
    let cancelLabel: String
    let busy: Bool
    let autoFocus: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @FocusState private var focus: Focus?
    @State private var gate = OneShot()
    @Environment(\.colorSchemeContrast) private var contrast

    public init(
        title: String, detail: String? = nil, rows: [Row] = [], meta: String? = nil, error: String? = nil, confirmLabel: String,
        cancelLabel: String = ConfirmCard.defaultCancelLabel, busy: Bool = false, autoFocus: Bool = false, onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void
    ) {
        self.title = title
        self.detail = detail
        self.rows = rows
        self.meta = meta
        self.error = error
        self.confirmLabel = confirmLabel
        self.cancelLabel = cancelLabel
        self.busy = busy
        self.autoFocus = autoFocus
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: TFRadius.panel, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(TFFont.calloutEmphasis)
                .tracking(-0.24)
                .foregroundStyle(TFColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let detail {
                Text(detail)
                    .font(TFFont.callout)
                    .tracking(-0.24)
                    .foregroundStyle(TFColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(rows, id: \.label) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text(row.label)
                                .font(TFFont.footnote)
                                .tracking(-0.08)
                                .foregroundStyle(TFColor.textSecondarySelected)
                                .frame(width: 52, alignment: .leading)
                            Text(row.value)
                                .font(TFFont.callout)
                                .tracking(-0.24)
                                .foregroundStyle(TFColor.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(row.accessibilityLabel)
                    }
                }
            }
            if let meta {
                Text(meta)
                    .font(TFFont.footnote)
                    .tracking(-0.08)
                    .foregroundStyle(TFColor.textSecondarySelected)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Text(error)
                    .font(TFFont.footnote)
                    .tracking(-0.08)
                    .foregroundStyle(Self.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(Self.accessibilityTraits(forError: true))
            }
            actions
        }
        .padding(TFSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TFColor.bgField, in: shape)
        .overlay(shape.strokeBorder(contrast == .increased ? TFColor.borderControl : .clear, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .onAppear { if let initial = Self.initialFocus(autoFocus: autoFocus) { focus = initial } }
        .onChange(of: error) { _, new in
            if let words = Self.errorAnnouncement(new) { AccessibilityNotification.Announcement(words).post() }
        }
        // 대상이 바뀌어 카드가 새로 그려지면(다른 제목 · 새 오류) 다시 한 번 누를 수 있다
        .onChange(of: title) { gate.reset() }
        .onChange(of: busy) { _, now in if !now { gate.reset() } }
    }

    private var actions: some View {
        let specs = Self.buttons(confirmLabel: confirmLabel, cancelLabel: cancelLabel)
        return HStack(spacing: TFSpace.sm) {
            Button(specs[0].title) { if gate.claim() { onConfirm() } }
                .buttonStyle(TFButtonStyle(.primary, size: .md))
                .focused($focus, equals: .confirm)
                .onKeyPress(.return) { act(.confirm) }
                .onKeyPress(.escape) { cancelIfFocused() }
                .focusRing(focus == .confirm, in: Capsule())
            Button(specs[1].title) { onCancel() }
                .buttonStyle(CancelButtonStyle())
                .focused($focus, equals: .cancel)
                .onKeyPress(.return) { act(.cancel) }
                .onKeyPress(.escape) { cancelIfFocused() }
                .focusRing(focus == .cancel, in: Capsule())
        }
        .disabled(Self.buttonsDisabled(busy: busy))
        .padding(.top, 6)
    }

    /// Return: 포커스가 있는 단추에만 간다
    private func act(_ target: Focus) -> KeyPress.Result {
        guard Self.returnTarget(focus: focus) == target else { return .ignored }
        switch target {
        case .confirm: if gate.claim() { onConfirm() }
        case .cancel: onCancel()
        }
        return .handled
    }

    private func cancelIfFocused() -> KeyPress.Result {
        guard Self.escapeCancels(focus: focus) else { return .ignored }
        onCancel()
        return .handled
    }
}

/// Cancel: Button secondary md이지만 카드 면(`bg/field`) 위에서 읽히도록 `bg/selected` 면이다 (DS `.tf-ccard .tf-btn.is-secondary`). 호버는 한 겹 더
private struct CancelButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CancelButtonBody(configuration: configuration)
    }
}

private struct CancelButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(TFColor.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(minHeight: 32)
            .background {
                ZStack {
                    Capsule().fill(TFColor.bgSelected)
                    if hovering && isEnabled { Capsule().fill(TFColor.bgSelected) }
                }
            }
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed && isEnabled ? TFMotion.pressScale : 1)
            .onHover { hovering = $0 }
            .animation(TFMotion.ease(TFMotion.hoverFade), value: hovering)
    }
}

extension View {
    /// 키보드 포커스 링 (DS 전역 `:focus-visible`: `border/accent` 2pt, 밖으로 3)
    fileprivate func focusRing(_ visible: Bool, in shape: some InsettableShape) -> some View {
        overlay {
            if visible { shape.strokeBorder(TFColor.borderAccent, lineWidth: 2).padding(-3) }
        }
        .focusEffectDisabled()
    }
}

#Preview("Confirm card") {
    VStack(spacing: 12) {
        ConfirmCard(title: "Is the Terminal session closed?", meta: "Queued messages send after you resume", confirmLabel: "Resume here", onConfirm: {}, onCancel: {})
        ConfirmCard(
            title: "Is the Terminal session closed?", meta: "Queued messages send after you resume", error: "Close the terminal session first",
            confirmLabel: "Resume here", onConfirm: {}, onCancel: {}
        )
        ConfirmCard(
            title: "Merge #144 into #139?", rows: [.init(label: "Closes", value: "#144 Confirm the refund window"), .init(label: "Keeps", value: "#139 Rewrite pricing page copy")],
            meta: "Shows 2 sources and 1 session from #144 on #139", confirmLabel: "Merge", onConfirm: {}, onCancel: {}
        )
    }
    .padding(12)
    .frame(width: 380)
    .background(TFColor.bgPanel)
}
