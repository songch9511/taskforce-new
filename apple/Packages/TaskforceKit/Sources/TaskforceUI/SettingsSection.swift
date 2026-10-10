import SwiftUI

// 0.2.0 설정 창의 묶음 (디자인 SSOT Settings, `SettingsSection` · `SettingsRow` · `ConfirmRow` · `KeyCombo` · `ShortcutRecorder`).
// 예전 설정 카드(`SettingsCard` · `SettingsRow` · `SettingsDivider`, Figma v1)는 기존 설정 창이 그대로 쓴다.

/// 설정 트레이의 치수 (디자인 README › Settings "Spatial rhythm")
enum SettingsTray {
    /// 제목 → 트레이 · 트레이 → 각주
    static let titleGap: CGFloat = 6
    /// 주제 사이 (창 본문의 줄 간격)
    static let topicGap: CGFloat = 24
    /// 제목 없는 이어지는 트레이
    static let followOnGap: CGFloat = 12
    /// 행 최소 높이 · 안쪽 여백(위아래 8 · 좌우 12)
    static let rowMinHeight: CGFloat = 40
    static let rowPadding = EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
    /// 구분선은 좌우 12 들인다. 앞 마크(20)가 있는 행은 글자에서 시작한다
    static let separatorInset: CGFloat = 12
    static let leadSide: CGFloat = 20
    static var leadSeparatorInset: CGFloat { separatorInset + leadSide + 12 }
    /// 설정 컨트롤은 24pt (`size="sm"`), TextField sm은 폭 180
    static let controlHeight: CGFloat = 24
    static let fieldWidth: CGFloat = 180
    static let toggleSize = CGSize(width: 34, height: 20)
}

extension ContainerValues {
    /// 이 행 위 구분선이 시작하는 자리 (`SettingsTrayRow`가 앞 마크가 있으면 글자 자리로 바꾼다)
    @Entry var settingsSeparatorLeading: CGFloat = SettingsTray.separatorInset
}

/// SettingsSection (0.2.0 Organisms): 설정 탭의 주제 하나. 제목(선택) · 행들의 트레이 하나 · 각주.
/// - 제목은 트레이 6 위, 각주는 6 아래. 주제 사이 24(창 본문 간격), 제목 없는 이어지는 트레이는 앞 것과 12 (CSS `margin-top: -12px`와 같다).
/// - 트레이는 `bg/surface` 위의 `bg/elevated`, 모서리 8, 머리카락 가장자리. 행 사이 구분선은 좌우 12 들인다.
/// - 결과(무엇을 지우는지 · 정책 뜻)는 각주에 둔다. 각주는 설명 글이 허락되는 유일한 자리다. 제목은 창 제목을 되풀이하지 않는다.
public struct SettingsSection<Content: View>: View {
    let title: String?
    let footnote: String?
    let content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    public init(_ title: String? = nil, footnote: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footnote = footnote
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SettingsTray.titleGap) {
            if let title {
                Text(title)
                    .font(TFFont.footnoteEmphasis)
                    .foregroundStyle(TFColor.textPrimary)
                    .padding(.horizontal, SettingsTray.separatorInset)
                    .accessibilityAddTraits(.isHeader)
            }
            tray
            if let footnote {
                Text(footnote)
                    .font(TFFont.meta)
                    .foregroundStyle(TFColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SettingsTray.separatorInset)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, title == nil ? SettingsTray.followOnGap - SettingsTray.topicGap : 0)
        .accessibilityElement(children: .contain)
    }

    private var tray: some View {
        let shape = RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous)
        let increased = contrast == .increased
        return VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(rows) { row in
                    if row.id != rows.first?.id {
                        Rectangle()
                            .fill(increased ? TFColor.borderControl : TFColor.borderDefault)
                            .frame(height: 1)
                            .padding(.leading, row.containerValues.settingsSeparatorLeading)
                            .padding(.trailing, SettingsTray.separatorInset)
                            .accessibilityHidden(true)
                    }
                    row
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TFColor.bgElevated, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(increased ? TFColor.borderControl : TFColor.borderDefault, lineWidth: increased ? 1 : 0.5))
    }
}

/// SettingsRow (0.2.0 Molecules, 트레이 행): 왼쪽 라벨 + 보조 줄(선택), 오른쪽 진짜 컨트롤 하나.
/// - 컨트롤은 행의 라벨이 이름을 준다(컨트롤 글자에 라벨을 되풀이하지 않는다). 편집 값은 TextField · Toggle · 팝업, 읽기 값은 `SettingsValue`.
/// - `onOpen`만 있으면 행 전체가 상세를 열고 끝에 ›, 컨트롤도 있으면 글자 쪽만 연다. `external`이면 › 대신 ↗(밖에서 열림).
/// - `lead`(서비스 마크 20pt)가 있으면 구분선이 글자에서 시작한다. `aside`는 라벨 뒤 회색(계정 · 범위), `attention`은 보조 줄을 굵게(색은 더하지 않는다).
/// - `message`는 오류 한 줄(`status/overdue`): 문제와 고치는 길을 말한다.
public struct SettingsTrayRow<Lead: View, Control: View>: View {
    let label: String
    let aside: String?
    let detail: String?
    let attention: Bool
    let message: String?
    let external: Bool
    let onOpen: (() -> Void)?
    let lead: Lead
    let control: Control
    @State private var hovering = false

    public init(
        _ label: String, aside: String? = nil, detail: String? = nil, attention: Bool = false, message: String? = nil,
        external: Bool = false, onOpen: (() -> Void)? = nil,
        @ViewBuilder lead: () -> Lead, @ViewBuilder control: () -> Control
    ) {
        self.label = label
        self.aside = aside
        self.detail = detail
        self.attention = attention
        self.message = message
        self.external = external
        self.onOpen = onOpen
        self.lead = lead()
        self.control = control()
    }

    private var hasLead: Bool { Lead.self != EmptyView.self }
    private var hasControl: Bool { Control.self != EmptyView.self }

    public var body: some View {
        Group {
            if let onOpen, !hasControl {
                // 행 전체가 상세(›) 또는 밖(↗)을 연다
                Button(action: onOpen) {
                    HStack(spacing: SettingsTray.separatorInset) {
                        leadSlot
                        text
                        (external ? TFIcon.opensOutside : TFIcon.disclosureClosed).image(size: 14)
                            .foregroundStyle(TFColor.textSecondary)
                    }
                    .modifier(RowFrame())
                    .background(hovering ? TFColor.bgSelected : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .accessibilityHint(external ? "Opens in browser" : "")
            } else {
                HStack(spacing: SettingsTray.separatorInset) {
                    leadSlot
                    if let onOpen {
                        Button(action: onOpen) {
                            text.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering = $0 }
                    } else {
                        text
                    }
                    control
                }
                .modifier(RowFrame())
                .background(onOpen != nil && hovering ? TFColor.bgSelected : .clear)
            }
        }
        .animation(TFMotion.ease(TFMotion.hoverFade), value: hovering)
        .containerValue(\.settingsSeparatorLeading, hasLead ? SettingsTray.leadSeparatorInset : SettingsTray.separatorInset)
    }

    @ViewBuilder
    private var leadSlot: some View {
        if hasLead {
            lead.frame(width: SettingsTray.leadSide)
        }
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 0) {
                Text(label)
                    .foregroundStyle(TFColor.textPrimary)
                if let aside {
                    Text(" · \(aside)")
                        .foregroundStyle(secondary)
                }
            }
            .font(TFFont.footnote)
            .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(attention ? TFFont.meta.weight(.semibold) : TFFont.meta)
                    .foregroundStyle(attention ? TFColor.textPrimary : secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message {
                Text(message)
                    .font(TFFont.meta)
                    .foregroundStyle(TFColor.statusOverdue)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// 호버된 여는 행 위의 보조 글자는 `bg/selected` 위 4.5:1을 지키는 색으로
    private var secondary: Color {
        onOpen != nil && hovering ? TFColor.textSecondarySelected : TFColor.textSecondary
    }
}

private struct RowFrame: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(SettingsTray.rowPadding)
            .frame(maxWidth: .infinity, minHeight: SettingsTray.rowMinHeight, alignment: .leading)
    }
}

extension SettingsTrayRow where Lead == EmptyView {
    public init(
        _ label: String, aside: String? = nil, detail: String? = nil, attention: Bool = false, message: String? = nil,
        external: Bool = false, onOpen: (() -> Void)? = nil, @ViewBuilder control: () -> Control
    ) {
        self.init(label, aside: aside, detail: detail, attention: attention, message: message, external: external, onOpen: onOpen, lead: { EmptyView() }, control: control)
    }
}

extension SettingsTrayRow where Lead == EmptyView, Control == EmptyView {
    /// 여는 행 (상세 › · 밖 ↗) 또는 글자만 있는 행
    public init(_ label: String, aside: String? = nil, detail: String? = nil, attention: Bool = false, message: String? = nil,
                external: Bool = false, onOpen: (() -> Void)? = nil) {
        self.init(label, aside: aside, detail: detail, attention: attention, message: message, external: external, onOpen: onOpen, lead: { EmptyView() }, control: { EmptyView() })
    }
}

/// ConfirmRow (0.2.0 Molecules): 지우기를 모달 대신 그 트레이 안에서 확인한다.
/// 확인 버튼은 동사를 되풀이하고(`Disconnect` · `Delete Account`), 보조 줄은 무엇이 남고 무엇이 사라지는지 말한다.
/// Cancel이 먼저 포커스를 받고 기본 동작(↩) 버튼은 두지 않는다: ↩로는 아무것도 지워지지 않는다. Esc는 Cancel.
public struct ConfirmRow: View {
    let title: String
    let detail: String?
    let confirmLabel: String
    let busy: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @FocusState private var cancelFocused: Bool

    public init(_ title: String, detail: String? = nil, confirmLabel: String, busy: Bool = false,
                onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.title = title
        self.detail = detail
        self.confirmLabel = confirmLabel
        self.busy = busy
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: TFSpace.sm) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(TFFont.footnoteEmphasis)
                    .foregroundStyle(TFColor.textPrimary)
                if let detail {
                    Text(detail)
                        .font(TFFont.meta)
                        .foregroundStyle(TFColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: TFSpace.sm) {
                Button(confirmLabel, action: onConfirm)
                    .buttonStyle(TFButtonStyle(.primary))
                    .disabled(busy)
                Button("Cancel", action: onCancel)
                    .buttonStyle(TFButtonStyle(.secondary))
                    .keyboardShortcut(.cancelAction)
                    .focused($cancelFocused)
                if busy {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(TFSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .defaultFocus($cancelFocused, true)
        .onAppear { cancelFocused = true }
    }
}

/// KeyCombo (0.2.0 Molecules): 단축키를 채운 키캡(`Keycap`)으로, 하나의 이름("Option Space")으로 읽힌다. 수식키 순서는 ⌃ ⌥ ⇧ ⌘.
/// (테두리만 있는 `KeyHint`는 런처 액션 바용)
public struct KeyCombo: View {
    let keys: [String]

    public init(_ keys: [String]) {
        self.keys = keys
    }

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Keycap(key)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenName(keys))
    }

    /// 접근성 이름: 수식키 · 화살표는 이름으로 ("⌥", "Space" → "Option Space"), 액션 바의 `KeyHint`와 같은 이름
    nonisolated static func spokenName(_ keys: [String]) -> String {
        KeyHint.spokenName(keys.map { .text($0) })
    }
}

/// ShortcutRecorder의 칸 (0.2.0 Molecules): 누르면 기록을 시작하고 다시 누르면 멈춘다. 기록 중에는 "Type a shortcut"과 강조 링.
/// 키 읽기 · 등록 · 오류(행의 `message`) · Reset은 쓰는 쪽이 맡는다. `keys`가 nil이면 정해진 단축키가 없다("Not set").
public struct ShortcutRecorder: View {
    let keys: [String]?
    let recording: Bool
    let action: () -> Void
    @State private var hovering = false

    public init(keys: [String]?, recording: Bool, action: @escaping () -> Void) {
        self.keys = keys
        self.recording = recording
        self.action = action
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: TFRadius.sm, style: .continuous)
        Button(action: action) {
            Group {
                if recording {
                    Text("Type a shortcut")
                        .font(TFFont.meta)
                        .foregroundStyle(TFColor.textSecondarySelected)
                } else if let keys {
                    KeyCombo(keys)
                } else {
                    Text("Not set")
                        .font(TFFont.meta)
                        .foregroundStyle(TFColor.textSecondarySelected)
                }
            }
            .padding(.horizontal, TFSpace.sm)
            .frame(minWidth: 120, minHeight: 26)
            .background(TFColor.bgField, in: shape)
            .overlay(shape.strokeBorder(edge, lineWidth: recording ? 1.5 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityValue(recording ? "Type a shortcut" : keys.map(KeyCombo.spokenName) ?? "Not set")
        .accessibilityAddTraits(recording ? .isSelected : [])
    }

    private var edge: Color {
        if recording { return TFColor.borderAccent }
        return hovering ? TFColor.borderControl : TFColor.borderDefault
    }
}

#Preview("Settings section") {
    @Previewable @State var on = true
    @Previewable @State var confirming = false
    ScrollView {
        VStack(alignment: .leading, spacing: SettingsTray.topicGap) {
            SettingsSection("AI processing", footnote: "Turning this off stops new tasks from sources and new drafts. Your tasks and drafts stay.") {
                SettingsTrayRow("Use AI on new sources") {
                    Toggle("Use AI on new sources", isOn: $on).labelsHidden().toggleStyle(.tf)
                }
                SettingsTrayRow("Privacy & AI Data", onOpen: {})
            }
            SettingsSection("Sources") {
                SettingsTrayRow("Notion", aside: "Acme", detail: "Synced 10 min ago", onOpen: {}) {
                    SourceIcon(.notion)
                } control: {
                    EmptyView()
                }
                SettingsTrayRow("Gmail", detail: "Reconnect to keep syncing", attention: true, onOpen: {}) {
                    SourceIcon(.gmail)
                } control: {
                    Button("Reconnect") {}.buttonStyle(TFButtonStyle(.primary))
                }
            }
            SettingsSection {
                if confirming {
                    ConfirmRow("Disconnect Gmail?", detail: "Taskforce stops reading Gmail. Tasks already found stay.", confirmLabel: "Disconnect",
                               onConfirm: { confirming = false }, onCancel: { confirming = false })
                } else {
                    SettingsTrayRow("Disconnect") {
                        Button("Disconnect…") { confirming = true }.buttonStyle(TFButtonStyle())
                    }
                }
            }
            SettingsSection("In the panel") {
                SettingsTrayRow("All work") { KeyCombo(["⌘", "2"]) }
                SettingsTrayRow("Open launcher", message: "That shortcut is in use. Try another.") {
                    ShortcutRecorder(keys: ["⌥", "Space"], recording: false) {}
                }
                SettingsTrayRow("Version") { SettingsValue("0.1.0") }
            }
        }
        .padding(20)
    }
    .frame(width: 560, height: 640)
    .background(TFColor.bgSurface)
}
