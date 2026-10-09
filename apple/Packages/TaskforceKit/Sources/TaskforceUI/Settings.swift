import SwiftUI

/// Settings row (Figma 286:5742): 아이콘(선택) · 제목 13 · 부제 12(선택) · 오른쪽 컨트롤 하나. 안쪽 12 · 16, 사이 12.
/// 오른쪽은 값 글자 · `QuietButton` · `DropdownButton` · `Toggle` · `DisclosureChevron` 중 하나를 넣는다.
public struct SettingsRow<Icon: View, Trailing: View>: View {
    let title: String
    let subtitle: String?
    let icon: Icon
    let trailing: Trailing

    public init(_ title: String, subtitle: String? = nil, @ViewBuilder icon: () -> Icon, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon()
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: TFSpace.md) {
            icon
            VStack(alignment: .leading, spacing: TFSpace.xxs) {
                Text(title)
                    .font(TFFont.footnote)
                    .foregroundStyle(TFColor.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(TFFont.meta)
                        .foregroundStyle(TFColor.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.vertical, TFSpace.md)
        .padding(.horizontal, TFSpace.lg)
    }
}

extension SettingsRow where Icon == EmptyView {
    public init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.init(title, subtitle: subtitle, icon: { EmptyView() }, trailing: trailing)
    }
}

extension SettingsRow where Icon == EmptyView, Trailing == EmptyView {
    public init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle, icon: { EmptyView() }, trailing: { EmptyView() })
    }
}

/// 설정 행 오른쪽의 값 글자 (Control=Value). 0.2.0 설정 창의 `Value`도 이것을 쓴다(읽기 전용 · 보조 색 · 한 줄 줄임표,
/// 숫자 폭 고정은 쓰는 쪽이 `.monospacedDigit()`으로). 사용자가 바꿀 수 있는 값이면 Value가 아니다
public struct SettingsValue: View {
    let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(TFFont.footnote)
            .foregroundStyle(TFColor.textSecondary)
            .lineLimit(1)
    }
}

/// 행을 누르면 다음 페이지로 간다는 회색 › (Control=Disclosure, 14)
public struct DisclosureChevron: View {
    public init() {}

    public var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(TFColor.textSecondary)
            .frame(width: 14, height: 14)
            .accessibilityHidden(true)
    }
}

/// 설정 카드: 행과 `SettingsDivider`를 쌓는 틀 (Figma: r12, settings/line 테두리, bg/elevated)
public struct SettingsCard<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: TFRadius.panel, style: .continuous)
        VStack(spacing: 0) {
            content
        }
        .background(TFColor.bgElevated, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(TFColor.settingsLine, lineWidth: 1))
    }
}

/// Settings divider (Figma 286:5745): 좌우 16 들인 1pt settings/line
public struct SettingsDivider: View {
    public init() {}

    public var body: some View {
        Rectangle()
            .fill(TFColor.settingsLine)
            .frame(height: 1)
            .padding(.horizontal, TFSpace.lg)
            .accessibilityHidden(true)
    }
}

#Preview("Settings card") {
    VStack(alignment: .leading, spacing: TFSpace.md) {
        Text("Connections").font(TFFont.pageTitle).foregroundStyle(TFColor.textPrimary)
        Text("Needs attention").font(TFFont.footnoteEmphasis).foregroundStyle(TFColor.textPrimary)
        SettingsCard {
            SettingsRow("Slack", subtitle: "Signed out at 15:50.") {
                QuietButton("Sign In…") {}
            }
            SettingsDivider()
            SettingsRow("Notion", subtitle: "Search, find tasks, comment") {
                DropdownButton("Manual") {}
            }
            SettingsDivider()
            SettingsRow("Keyboard Shortcut") {
                SettingsValue("⌥Space")
            }
            SettingsDivider()
            SettingsRow("Imported sources", subtitle: "1,284") {
                DisclosureChevron()
            }
        }
    }
    .padding(24)
    .frame(width: 516)
    .background(TFColor.settingsContent)
}
