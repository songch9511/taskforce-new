import SwiftUI

/// 액션 바의 동작 하나: 이름 + 단축키 (`KeyHint`)
public struct ActionBarItem {
    public let title: String
    public let keys: String
    public let action: () -> Void

    public init(_ title: String, keys: String, action: @escaping () -> Void) {
        self.title = title
        self.keys = keys
        self.action = action
    }
}

/// 런처 아래 액션 바 (Figma M1 · M19 · M20 Footer, Raycast): 높이 44, 좌우 18.
/// 왼쪽은 앱 기호 + 화면 이름(`Tasks`) 또는 상태(`Offline since 8:01.`), 오른쪽은
/// 다시 시도 같은 보조 동작 → Return 동작(회색 알약, 이름 + ↩) → `Actions ⌘K`. 사이에 세로 구분선.
public struct ActionBar: View {
    public enum Leading {
        /// 앱 기호 + 화면 이름
        case app(String)
        /// 상태 기호 + 문장. `alert`면 기호를 text/primary로 (새로고침 실패)
        case status(systemImage: String, text: String, alert: Bool = false)
    }

    let leading: Leading
    let secondary: ActionBarItem?
    let primary: ActionBarItem?
    let actions: ActionBarItem?

    public init(leading: Leading, secondary: ActionBarItem? = nil, primary: ActionBarItem? = nil, actions: ActionBarItem? = nil) {
        self.leading = leading
        self.secondary = secondary
        self.primary = primary
        self.actions = actions
    }

    public var body: some View {
        HStack(spacing: TFSpace.sm) {
            leadingView
            Spacer(minLength: TFSpace.sm)
            let trailing = [secondary.map { (item: $0, isPrimary: false) }, primary.map { (item: $0, isPrimary: true) }, actions.map { (item: $0, isPrimary: false) }]
                .compactMap { $0 }
            ForEach(Array(trailing.enumerated()), id: \.offset) { index, entry in
                if index > 0 { separator }
                if entry.isPrimary {
                    primaryButton(entry.item)
                } else {
                    plainButton(entry.item)
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 44)
    }

    @ViewBuilder
    private var leadingView: some View {
        switch leading {
        case .app(let title):
            HStack(spacing: TFSpace.sm) {
                TFImage.logoMark
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(TFImage.logoMarkAspectRatio, contentMode: .fit)
                    .frame(width: 12.7)
                    .foregroundStyle(TFColor.fillInverse)
                    .frame(width: 18, height: 18)
                    .background(TFColor.bgCanvas, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .accessibilityHidden(true)
                Text(title)
                    .font(TFFont.footnote)
                    .foregroundStyle(TFColor.textSecondary)
                    .lineLimit(1)
            }
        case .status(let systemImage, let text, let alert):
            HStack(spacing: TFSpace.sm) {
                Image(systemName: systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(alert ? TFColor.textPrimary : TFColor.textSecondary)
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
                Text(text)
                    .font(TFFont.footnote)
                    .foregroundStyle(TFColor.textSecondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(TFColor.borderDefault)
            .frame(width: 1, height: 16)
            .accessibilityHidden(true)
    }

    private func primaryButton(_ item: ActionBarItem) -> some View {
        Button(action: item.action) {
            HStack(spacing: 6) {
                Text(item.title)
                    .font(TFFont.footnoteEmphasis)
                    .foregroundStyle(TFColor.textPrimary)
                    .lineLimit(1)
                KeyHint(item.keys, onFill: true)
            }
            .padding(.vertical, TFSpace.xs)
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(height: 28)
            .background(TFColor.settingsFill, in: RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityHint(KeyHint.spokenName(KeyHint.keys(item.keys)))
    }

    private func plainButton(_ item: ActionBarItem) -> some View {
        Button(action: item.action) {
            HStack(spacing: 6) {
                Text(item.title)
                    .font(TFFont.footnote)
                    .foregroundStyle(TFColor.textSecondary)
                    .lineLimit(1)
                KeyHint(item.keys)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityHint(KeyHint.spokenName(KeyHint.keys(item.keys)))
    }
}

#Preview("Action bar") {
    VStack(spacing: 0) {
        ActionBar(
            leading: .app("Tasks"),
            primary: ActionBarItem("Open in Notion", keys: "↩") {},
            actions: ActionBarItem("Actions", keys: "⌘K") {}
        )
        ActionBar(
            leading: .status(systemImage: "exclamationmark.triangle", text: "Couldn’t refresh at 10:46. Showing 10:31.", alert: true),
            secondary: ActionBarItem("Try Again", keys: "⌘R") {},
            primary: ActionBarItem("Open in Notion", keys: "↩") {},
            actions: ActionBarItem("Actions", keys: "⌘K") {}
        )
        ActionBar(
            leading: .status(systemImage: "wifi.slash", text: "Offline since 8:01."),
            actions: ActionBarItem("Actions", keys: "⌘K") {}
        )
    }
    .frame(width: 752)
    .background(TFColor.bgGlass)
}
