import OSLog
import SwiftUI
import TaskforceKit
import TaskforceUI

/// 로그인 · 이어 붙이기 · 재확인의 **결과 코드만** OSLog에 남긴다 (OA 로그인 계약 9장): `apple|google` `signin|link|reauth` `ok|canceled|failed:<코드>`.
/// 이메일 · 토큰 · code · nonce · state는 어디에도 싣지 않는다. 코드는 아래 고정 낱말과 Apple이 돌려준 안전한 오류 코드(영문 · 숫자 · `_-.`, 60자까지)뿐이다.
/// 시험이 `sink`로 받아 비밀 값이 없는지 본다.
@MainActor
enum SignInLog {
    enum Provider: String {
        case apple, google
    }

    enum Step: String {
        case signIn = "signin", link, reauth
    }

    enum Result: Equatable {
        case ok
        case canceled
        case failed(String)

        var text: String {
            switch self {
            case .ok: "ok"
            case .canceled: "canceled"
            case .failed(let code): "failed:" + Self.safe(code)
            }
        }

        private static func safe(_ code: String) -> String {
            let kept = code.filter { $0.isASCII && ($0.isLetter || $0.isNumber || "_-.".contains($0)) }
            return kept.isEmpty ? "unknown" : String(kept.prefix(60))
        }
    }

    private static let logger = Logger(subsystem: "dev.taskforcelabs.taskforce", category: "sign-in")
    static var sink: (String) -> Void = { message in logger.notice("\(message, privacy: .public)") }

    static func record(_ provider: Provider, _ step: Step, _ result: Result) {
        sink("\(provider.rawValue) \(step.rawValue) \(result.text)")
    }
}

/// 로그인 화면이 무엇을 보이는지 (버튼 순서 · 제목 · 법률 줄). 화면은 이것만 그린다: 시험이 구조를 본다.
/// DS `SignIn`(inline, 사용자 승인 2026-10-19): 제목 · 버튼 둘(Apple 먼저, Google 같은 크기) · 오류 한 줄(조용한 회색) · 법률 한 줄.
/// 로고 · "Taskforce" 글자 · 안내 글 · 연락 링크는 두지 않는다.
struct SignInScreen: Equatable {
    enum Button: Equatable {
        case apple, google
    }

    /// 위에서 아래 순서 (Apple 먼저)
    let buttons: [Button]
    /// 버튼이 하나도 없을 때(Debug 빌드, 설정 값 없음)의 한 줄
    let unavailable: String?

    static func make(appleAvailable: Bool, googleAvailable: Bool) -> SignInScreen {
        let buttons = (appleAvailable ? [Button.apple] : []) + (googleAvailable ? [Button.google] : [])
        return SignInScreen(buttons: buttons, unavailable: buttons.isEmpty ? SignInCopy.unavailable : nil)
    }
}

struct SignInView: View {
    @Environment(SessionStore.self) private var session
    @State private var signingInWithApple = false
    @State private var signingInWithGoogle = false

    /// Apple 버튼과 Google 버튼은 같은 크기다 (App Store 4.8: Apple을 먼저, 적어도 같게)
    private let buttonHeight = SignInWithGoogleButton.height

    private var screen: SignInScreen {
        SignInScreen.make(appleAvailable: AppleSignInFlow.isAvailable, googleAvailable: GoogleSignInFlow.isAvailable)
    }

    var body: some View {
        let screen = screen
        VStack(spacing: TFSpace.xl) {
            Spacer()
            Text(SignInCopy.title)
                .font(TFFont.title)
                .foregroundStyle(TFColor.textPrimary)
            Spacer()
            VStack(spacing: TFSpace.md) {
                ForEach(screen.buttons, id: \.self) { button in
                    switch button {
                    case .apple:
                        SystemSignInWithAppleButton {
                            signingInWithApple = true
                            AppleSignInFlow.shared.signIn(session: session) { signingInWithApple = false }
                        }
                        .frame(maxWidth: 360, minHeight: buttonHeight, maxHeight: buttonHeight)
                        .disabled(signingInWithApple || signingInWithGoogle)
                    case .google:
                        SignInWithGoogleButton {
                            signingInWithGoogle = true
                            GoogleSignInFlow.signIn(session: session) { signingInWithGoogle = false }
                        }
                        .frame(maxWidth: 360, minHeight: buttonHeight, maxHeight: buttonHeight)
                        .disabled(signingInWithApple || signingInWithGoogle)
                    }
                }
                if let unavailable = screen.unavailable {
                    Text(unavailable)
                        .font(TFFont.footnote)
                        .foregroundStyle(TFColor.textSecondary)
                }
            }

            // 로그인 실패 · 알림은 조용한 회색 한 줄이다 (빨강은 입력 오류와 지난 날짜만)
            if let message = session.errorMessage ?? session.notice {
                Text(message)
                    .font(TFFont.footnote)
                    .foregroundStyle(TFColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
            Text(Self.legalText(SignInCopy.legalLine))
                .font(TFFont.footnote)
                .foregroundStyle(TFColor.textSecondary)
                .multilineTextAlignment(.center)
                .tint(TFColor.textLink)
        }
        .padding(TFSpace.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TFColor.bgCanvas)
        .onDisappear {
            GoogleSignInFlow.forgetRunningFlow()
            AppleSignInFlow.shared.forgetRunningFlow()
        }
    }

    /// 한 줄 안의 "Terms"와 "Privacy Policy"를 링크로
    static func legalText(_ line: String) -> AttributedString {
        var text = AttributedString(line)
        for (word, url) in [("Privacy Policy", LegalLinks.privacy), ("Terms", LegalLinks.terms)] {
            if let range = text.range(of: word) {
                text[range].link = url
                text[range].underlineStyle = .single
            }
        }
        return text
    }
}
