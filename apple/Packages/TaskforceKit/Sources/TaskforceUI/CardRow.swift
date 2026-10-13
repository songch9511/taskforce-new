import SwiftUI

/// Card 안의 줄 (디자인 SettingsRow를 `Card` 위에 올린 모양): 앞 마크(선택) · 라벨 · 보조 줄 · 뒤 컨트롤(선택).
/// ReturnSummary · Receipts가 함께 쓴다. `Card`는 줄 사이 구분선을 그리지 않으므로 `CardRows`가 그린다.
/// - 카드 위의 보조 글은 `text/secondary-selected`다 (`Card`와 같은 대비 규칙, 디자인 `.tf-card .tf-set-detail`).
/// - `onOpen`만 있으면 줄 전체가 그 작업을 열고 끝에 ›, 컨트롤도 있으면 글자 쪽만 연다. `onOpen`이 없으면 누를 수 없는 줄이다 (› 없음, 호버 없음).
/// - `attention`: 보조 줄을 굵게 (색은 더하지 않는다). 실패는 굵은 글씨로 쓴다.
struct CardRow<Lead: View, Control: View>: View {
    let title: String
    let detail: AttributedString?
    let attention: Bool
    let onOpen: (() -> Void)?
    let lead: Lead
    let control: Control
    @State private var hovering = false

    init(
        title: String, detail: AttributedString? = nil, attention: Bool = false, onOpen: (() -> Void)? = nil,
        @ViewBuilder lead: () -> Lead, @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.detail = detail
        self.attention = attention
        self.onOpen = onOpen
        self.lead = lead()
        self.control = control()
    }

    private var hasLead: Bool { Lead.self != EmptyView.self }
    private var hasControl: Bool { Control.self != EmptyView.self }

    var body: some View {
        Group {
            if let onOpen, !hasControl {
                Button(action: onOpen) {
                    HStack(spacing: SettingsTray.separatorInset) {
                        leadSlot
                        text
                        TFIcon.disclosureClosed.image(size: 14).foregroundStyle(TFColor.textSecondary)
                    }
                    .modifier(CardRowFrame())
                    .background(hovering ? TFColor.bgSelected : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
            } else {
                HStack(spacing: SettingsTray.separatorInset) {
                    leadSlot
                    if let onOpen {
                        Button(action: onOpen) { text.contentShape(Rectangle()) }
                            .buttonStyle(.plain)
                            .onHover { hovering = $0 }
                    } else {
                        text
                    }
                    control
                }
                .modifier(CardRowFrame())
                .background(onOpen != nil && hovering ? TFColor.bgSelected : .clear)
            }
        }
        .animation(TFMotion.ease(TFMotion.hoverFade), value: hovering)
    }

    @ViewBuilder
    private var leadSlot: some View {
        if hasLead { lead.frame(width: SettingsTray.leadSide) }
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(TFFont.footnote)
                .foregroundStyle(TFColor.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let detail {
                Text(detail)
                    .font(attention ? TFFont.meta.weight(.semibold) : TFFont.meta)
                    .foregroundStyle(attention ? TFColor.textPrimary : TFColor.textSecondarySelected)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// 이 줄 위 구분선이 시작하는 자리: 앞 마크가 있으면 글자에서, 없으면 12
    static var separatorInset: CGFloat { Lead.self == EmptyView.self ? SettingsTray.separatorInset : SettingsTray.leadSeparatorInset }
}

private struct CardRowFrame: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(SettingsTray.rowPadding)
            .frame(maxWidth: .infinity, minHeight: SettingsTray.rowMinHeight, alignment: .leading)
    }
}

/// `Card` 안에 줄들을 세로로 쌓고 줄 사이에 구분선을 그린다. 아래 모서리는 카드 모양으로 자른다 (호버 면이 둥근 모서리를 넘지 않게)
struct CardRows<Content: View>: View {
    let content: Content
    /// 모든 줄에 앞 마크가 있으면 구분선이 글자에서 시작한다
    let hasLead: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    init(hasLead: Bool = false, @ViewBuilder content: () -> Content) {
        self.hasLead = hasLead
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(rows) { row in
                    if row.id != rows.first?.id {
                        Rectangle()
                            .fill(contrast == .increased ? TFColor.borderControl : TFColor.borderDefault)
                            .frame(height: 1)
                            .padding(.leading, hasLead ? SettingsTray.leadSeparatorInset : SettingsTray.separatorInset)
                            .padding(.trailing, SettingsTray.separatorInset)
                            .accessibilityHidden(true)
                    }
                    row
                }
            }
        }
        // 캡션 바로 아래 줄은 2pt 띄운다 (디자인 `.tf-card-title + .tf-set-row`)
        .padding(.top, 2)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12, style: .continuous))
    }
}

extension CardRow where Lead == EmptyView {
    init(title: String, detail: AttributedString? = nil, attention: Bool = false, onOpen: (() -> Void)? = nil, @ViewBuilder control: () -> Control) {
        self.init(title: title, detail: detail, attention: attention, onOpen: onOpen, lead: { EmptyView() }, control: control)
    }
}

extension CardRow where Lead == EmptyView, Control == EmptyView {
    init(title: String, detail: AttributedString? = nil, attention: Bool = false, onOpen: (() -> Void)? = nil) {
        self.init(title: title, detail: detail, attention: attention, onOpen: onOpen, lead: { EmptyView() }, control: { EmptyView() })
    }
}
