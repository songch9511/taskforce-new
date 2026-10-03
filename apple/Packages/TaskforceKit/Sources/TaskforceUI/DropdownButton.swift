import SwiftUI

/// Dropdown (Figma 285:1683): 테두리 팝업 버튼. 글자가 지금 값이다.
/// - regular: 설정 행 (28, 안쪽 12 · 10, settings/line 테두리)
/// - compact: 런처 범위 `All Tasks ⌄` (26, bg/elevated 면 + settings/line 테두리)
/// `Menu`의 label로 쓰거나(`DropdownLabel`) 누르면 직접 메뉴를 여는 버튼(`DropdownButton`)으로 쓴다.
public struct DropdownLabel: View {
    public enum Size: Sendable, Hashable {
        case regular, compact
    }

    let title: String
    let size: Size

    public init(_ title: String, size: Size = .regular) {
        self.title = title
        self.size = size
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous)
        HStack(spacing: size == .compact ? TFSpace.xs : 6) {
            Text(title)
                .font(TFFont.footnote)
                .foregroundStyle(TFColor.textPrimary)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(TFColor.textSecondary)
                .frame(width: 12, height: 12)
        }
        .padding(.leading, size == .compact ? 10 : TFSpace.md)
        .padding(.trailing, size == .compact ? TFSpace.sm : 10)
        .frame(height: size == .compact ? 26 : 28)
        .background(size == .compact ? TFColor.bgElevated : .clear, in: shape)
        .overlay(shape.strokeBorder(TFColor.settingsLine, lineWidth: 1))
        .contentShape(shape)
    }
}

/// 누르면 `action`(메뉴 열기)을 부르는 Dropdown. VoiceOver: 이름 "Scope" + 값 "All Tasks"
public struct DropdownButton: View {
    let title: String
    let size: DropdownLabel.Size
    let accessibilityName: String?
    let action: () -> Void

    public init(_ title: String, size: DropdownLabel.Size = .regular, accessibilityName: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.size = size
        self.accessibilityName = accessibilityName
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            DropdownLabel(title, size: size)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityName ?? title)
        .accessibilityValue(accessibilityName == nil ? "" : title)
    }
}

#Preview("Dropdown") {
    HStack(spacing: 12) {
        DropdownButton("All Tasks", size: .compact, accessibilityName: "Scope") {}
        DropdownButton("Search Only") {}
        DropdownButton("Full Access") {}
    }
    .padding()
    .background(TFColor.bgElevated)
}
