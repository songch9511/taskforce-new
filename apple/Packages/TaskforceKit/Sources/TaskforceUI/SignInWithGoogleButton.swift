import SwiftUI

/// "Sign in with Google" 버튼. Google 브랜드 규칙(developers.google.com/identity/branding-guidelines)의 Light 테마:
/// 바탕 #FFFFFF · 1pt 안쪽 테두리 #747775 · 글자 #1F1F1F Medium, 표준 색 G 로고, iOS 여백(로고 앞 16 · 로고 뒤 12 · 글자 뒤 16).
/// 크기는 SignInWithAppleButton에 맞춘다 (Google: 다른 제3자 로그인만큼 눈에 띄게. App Store 4.8: Apple을 먼저, 적어도 같게):
/// iOS는 높이 48 · 글자 19, macOS는 Apple 버튼이 높이 30 · 글자 13에 머물러 같은 크기로 줄인다 (`height`).
/// 다크 모드에서도 Light 테마를 쓴다: G 로고는 흰 바탕 위에 둬야 하고, 다크 모드의 Apple 버튼도 흰색이다.
///
/// Google Sign-In SDK의 SwiftUI 버튼(GoogleSignInSwift)은 높이 40 고정 · 예전 디자인이라 Apple 버튼과 크기를 맞출 수 없어 쓰지 않는다.
/// 글꼴은 규칙의 Google Sans 대신 시스템 글꼴이다 (Apple 버튼과 같은 글꼴, 글꼴 파일을 앱에 넣지 않음).
public struct SignInWithGoogleButton: View {
    public static let title = "Sign in with Google"

    #if os(macOS)
    /// SignInWithAppleButton이 실제로 그려지는 높이 (프레임을 키워도 30)
    public static let height: CGFloat = 30
    private static let fontSize: CGFloat = 13
    private static let logoSize: CGFloat = 14
    private static let logoSpacing: CGFloat = 8
    private static let sidePadding: CGFloat = 12
    #else
    public static let height: CGFloat = 48
    private static let fontSize: CGFloat = 19
    private static let logoSize: CGFloat = 18
    private static let logoSpacing: CGFloat = 12
    private static let sidePadding: CGFloat = 16
    #endif

    let cornerRadius: CGFloat
    let action: () -> Void

    public init(cornerRadius: CGFloat = 6, action: @escaping () -> Void) {
        self.cornerRadius = cornerRadius
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: Self.logoSpacing) {
                TFImage.googleG
                    .resizable()
                    .frame(width: Self.logoSize, height: Self.logoSize)
                    .accessibilityHidden(true)
                Text(Self.title)
                    .font(.system(size: Self.fontSize, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, Self.sidePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(GoogleButtonStyle(cornerRadius: cornerRadius))
    }
}

private struct GoogleButtonStyle: ButtonStyle {
    let cornerRadius: CGFloat

    static let fill = Color.white
    static let stroke = Color(red: 0x74 / 255, green: 0x77 / 255, blue: 0x75 / 255)
    static let text = Color(red: 0x1F / 255, green: 0x1F / 255, blue: 0x1F / 255)

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        configuration.label
            .foregroundStyle(Self.text)
            .background(shape.fill(Self.fill))
            // 누른 상태: 글자색 12% 겹침 (Google 버튼 상태 규칙)
            .overlay(shape.fill(Self.text.opacity(configuration.isPressed ? 0.12 : 0)))
            .overlay(shape.strokeBorder(Self.stroke, lineWidth: 1))
            .contentShape(shape)
    }
}

#Preview("Sign in with Google") {
    VStack(spacing: 12) {
        SignInWithGoogleButton {}
            .frame(maxWidth: 360, minHeight: SignInWithGoogleButton.height, maxHeight: SignInWithGoogleButton.height)
    }
    .padding()
    .background(TFColor.bgCanvas)
}
