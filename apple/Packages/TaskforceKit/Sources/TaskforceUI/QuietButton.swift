import SwiftUI

/// Quiet button (Figma 285:1679): 회색 버튼. 화면의 주 동작 하나만 Strong(검은 면).
/// - Small: 런처 카드 (26, r7, 12)
/// - Regular: 설정 행 (28, r8, 13)
/// - Large: 시트 아래 (30, r8, 13)
/// - iOS: iPhone (34 캡슐, 15 Dynamic Type). 누르는 영역은 위아래로 넓혀 44를 지킨다
public struct QuietButtonStyle: ButtonStyle {
    public enum Size: Sendable, Hashable {
        case small, regular, large, iOS
    }

    public enum Emphasis: Sendable, Hashable {
        /// settings/fill 면 + text/primary
        case quiet
        /// text/primary 면 + bg/canvas 글자 (semibold)
        case strong
    }

    let size: Size
    let emphasis: Emphasis

    public init(size: Size = .regular, emphasis: Emphasis = .quiet) {
        self.size = size
        self.emphasis = emphasis
    }

    public func makeBody(configuration: Configuration) -> some View {
        QuietButtonBody(configuration: configuration, size: size, emphasis: emphasis)
    }
}

private struct QuietButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let size: QuietButtonStyle.Size
    let emphasis: QuietButtonStyle.Emphasis
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        configuration.label
            .font(font)
            .foregroundStyle(emphasis == .strong ? TFColor.bgCanvas : TFColor.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, horizontalPadding)
            .frame(minHeight: height)
            .background(emphasis == .strong ? TFColor.textPrimary : TFColor.settingsFill, in: shape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .padding(.vertical, size == .iOS ? 5 : 0)
            .contentShape(Rectangle())
    }

    private var font: Font {
        switch (size, emphasis) {
        case (.small, .quiet): TFFont.meta
        case (.small, .strong): TFFont.meta.weight(.semibold)
        case (.regular, .quiet), (.large, .quiet): TFFont.footnote
        case (.regular, .strong), (.large, .strong): TFFont.footnoteEmphasis
        case (.iOS, .quiet): TFFont.callout
        case (.iOS, .strong): TFFont.callout.weight(.semibold)
        }
    }

    private var height: CGFloat {
        switch size {
        case .small: 26
        case .regular: 28
        case .large: 30
        case .iOS: 34
        }
    }

    private var horizontalPadding: CGFloat {
        switch size {
        case .small: 10
        case .regular: TFSpace.md
        case .large, .iOS: 14
        }
    }

    private var radius: CGFloat {
        switch size {
        case .small: 7
        case .regular, .large: TFRadius.md
        case .iOS: 17
        }
    }
}

/// `QuietButtonStyle`을 입힌 글자 버튼
public struct QuietButton: View {
    let title: String
    let size: QuietButtonStyle.Size
    let emphasis: QuietButtonStyle.Emphasis
    let action: () -> Void

    public init(_ title: String, size: QuietButtonStyle.Size = .regular, emphasis: QuietButtonStyle.Emphasis = .quiet, action: @escaping () -> Void) {
        self.title = title
        self.size = size
        self.emphasis = emphasis
        self.action = action
    }

    public var body: some View {
        Button(title, action: action)
            .buttonStyle(QuietButtonStyle(size: size, emphasis: emphasis))
    }
}

#Preview("Quiet button") {
    VStack(alignment: .leading, spacing: 12) {
        HStack {
            QuietButton("View Draft", size: .small) {}
            QuietButton("Edit…") {}
            QuietButton("Edit…", emphasis: .strong) {}
            QuietButton("Cancel", size: .large) {}
            QuietButton("Allow", size: .large, emphasis: .strong) {}
        }
        HStack {
            QuietButton("Sign In", size: .iOS) {}
            QuietButton("Sign In…") {}.disabled(true)
        }
    }
    .padding()
    .background(TFColor.bgElevated)
}
