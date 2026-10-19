import AuthenticationServices
import SwiftUI

/// 시스템 "Sign in with Apple" 버튼 (`ASAuthorizationAppleIDButton`). DS SignIn: "The shipping app uses the system ASAuthorizationAppleIDButton."
/// 이 버튼은 그리기만 한다: 누르면 `action`을 부른다. 요청은 만들지 않는다 (Mac은 브라우저 창의 Apple 웹 로그인, iPhone은 앱 안 로그인).
/// `com.apple.developer.applesignin` 권한이 없는 Mac 앱에서도 그려진다 (권한은 요청을 보낼 때만 필요하다).
/// 라이트는 검정, 다크는 흰색. 크기는 `SignInWithGoogleButton`과 같게 쓴다 (Apple 먼저, Google 같은 크기).
/// 이름이 `AuthenticationServices.SignInWithAppleButton`과 겹치지 않게 `System`을 붙였다.
public struct SystemSignInWithAppleButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat
    let action: () -> Void

    public init(cornerRadius: CGFloat = 6, action: @escaping () -> Void) {
        self.cornerRadius = cornerRadius
        self.action = action
    }

    public var body: some View {
        AppleIDButtonRepresentable(style: colorScheme == .dark ? .white : .black, cornerRadius: cornerRadius, action: action)
            // 모양이 바뀌면(라이트 ↔ 다크) 새로 만든다: 시스템 버튼의 스타일은 만든 뒤에 바꿀 수 없다
            .id(colorScheme)
    }
}

#if os(macOS)
import AppKit

private struct AppleIDButtonRepresentable: NSViewRepresentable {
    let style: ASAuthorizationAppleIDButton.Style
    let cornerRadius: CGFloat
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(type: .signIn, style: style)
        button.cornerRadius = cornerRadius
        button.target = context.coordinator
        button.action = #selector(Coordinator.pressed)
        return button
    }

    func updateNSView(_ button: ASAuthorizationAppleIDButton, context: Context) {
        context.coordinator.action = action
        button.cornerRadius = cornerRadius
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func pressed() { action() }
    }
}
#else
import UIKit

private struct AppleIDButtonRepresentable: UIViewRepresentable {
    let style: ASAuthorizationAppleIDButton.Style
    let cornerRadius: CGFloat
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(type: .signIn, style: style)
        button.cornerRadius = cornerRadius
        button.addTarget(context.coordinator, action: #selector(Coordinator.pressed), for: .touchUpInside)
        return button
    }

    func updateUIView(_ button: ASAuthorizationAppleIDButton, context: Context) {
        context.coordinator.action = action
        button.cornerRadius = cornerRadius
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func pressed() { action() }
    }
}
#endif
