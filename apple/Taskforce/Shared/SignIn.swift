import AuthenticationServices
import SwiftUI
import TaskforceKit
import TaskforceUI

/// Sign in with Apple 요청 만들기 · 결과 처리. iPhone 로그인 화면 · Mac 설정 창(SignInWithAppleButton)과
/// Mac 런처의 "Sign in with Apple" 행(ASAuthorizationController)이 같은 규칙을 쓴다.
@MainActor
final class AppleSignInFlow {
    private var nonce = SignInNonce.random()

    func configure(_ request: ASAuthorizationAppleIDRequest) {
        nonce = SignInNonce.random()
        request.requestedScopes = [.email]
        request.nonce = nonce.hashed
    }

    func handle(_ result: Result<ASAuthorization, Error>, session: SessionStore) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8)
            else {
                session.reportError("Apple didn't return a sign-in token. Try again.")
                return
            }
            let nonce = nonce
            Task { await session.signInWithApple(idToken: idToken, nonce: nonce) }
        case .failure(let error):
            // 사용자가 창을 닫은 경우는 오류로 보여주지 않는다.
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            session.reportError("Couldn't sign in with Apple. \(error.localizedDescription)")
        }
    }
}

/// 로그인 화면: 로고 + Sign in with Apple · Sign in with Google(설정이 있을 때, Apple 아래 같은 크기). 설명 문장은 두지 않는다.
/// 그 아래 눈에 덜 띄게 "Sign in with email" (App Store 심사 계정용, 가입 화면 없음: 서버가 허용한 계정만 로그인된다).
struct SignInView: View {
    /// Mac 런처의 "Sign in with email" 행이 설정 창을 열며 켠다
    static let emailExpandedKey = "signIn.emailExpanded"

    @Environment(SessionStore.self) private var session
    @Environment(\.colorScheme) private var colorScheme
    @State private var flow = AppleSignInFlow()
    @AppStorage(SignInView.emailExpandedKey) private var showsEmail = false
    @State private var email = ""
    @State private var password = ""
    @State private var signingIn = false
    @State private var signingInWithGoogle = false

    /// Apple · Google 버튼 높이 (iOS 48, macOS는 Apple 버튼이 그려지는 30). 둘을 같은 크기로 둔다.
    private let buttonHeight = SignInWithGoogleButton.height

    var body: some View {
        VStack(spacing: TFSpace.xl) {
            Spacer()
            HStack(spacing: TFSpace.md) {
                TFImage.logoMark
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(TFImage.logoMarkAspectRatio, contentMode: .fit)
                    .frame(height: 28)
                Text("Taskforce")
                    .font(.largeTitle.weight(.semibold))
            }
            .foregroundStyle(TFColor.textPrimary)
            .accessibilityElement(children: .combine)
            Spacer()
            VStack(spacing: TFSpace.md) {
                SignInWithAppleButton(.signIn) { request in
                    flow.configure(request)
                } onCompletion: { result in
                    flow.handle(result, session: session)
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(maxWidth: 360, minHeight: buttonHeight, maxHeight: buttonHeight)

                if GoogleSignInFlow.isAvailable {
                    SignInWithGoogleButton {
                        signingInWithGoogle = true
                        GoogleSignInFlow.signIn(session: session) { signingInWithGoogle = false }
                    }
                    .frame(maxWidth: 360, minHeight: buttonHeight, maxHeight: buttonHeight)
                    .disabled(signingInWithGoogle)
                }
            }

            if showsEmail {
                emailForm
            } else {
                Button("Sign in with email") { showsEmail = true }
                    .buttonStyle(.plain)
                    .font(TFFont.footnote)
                    .foregroundStyle(TFColor.textSecondary)
            }

            if let message = session.errorMessage {
                Text(message)
                    .font(TFFont.footnote)
                    .foregroundStyle(TFColor.statusOverdue)
                    .multilineTextAlignment(.center)
            } else if let notice = session.notice {
                Text(notice)
                    .font(TFFont.footnote)
                    .foregroundStyle(TFColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
            LegalLinksRow()
                .font(TFFont.footnote)
        }
        .padding(TFSpace.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TFColor.bgCanvas)
        // 다음 로그인 화면은 다시 Apple 버튼만
        .onDisappear {
            showsEmail = false
            GoogleSignInFlow.forgetRunningFlow()
        }
        #if os(iOS)
        // Google 로그인 콜백 (보통은 ASWebAuthenticationSession이 바로 받는다). Mac은 MacAppDelegate가 받는다.
        .onOpenURL { url in _ = GoogleSignInFlow.handle(url) }
        #endif
    }

    private var emailForm: some View {
        VStack(spacing: TFSpace.sm) {
            TextField("Email", text: $email)
                .textContentType(.username)
                .autocorrectionDisabled()
            #if os(iOS)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
            #endif
            SecureField("Password", text: $password)
                .textContentType(.password)
                .onSubmit(signIn)
            Button(action: signIn) {
                if signingIn {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Sign In")
                }
            }
            .buttonStyle(.bordered)
            .disabled(signingIn || email.isEmpty || password.isEmpty)
        }
        .textFieldStyle(.roundedBorder)
        .font(TFFont.callout)
        .frame(maxWidth: 360)
    }

    private func signIn() {
        guard !signingIn else { return }
        signingIn = true
        Task {
            await session.signInWithEmail(email: email, password: password)
            signingIn = false
            password = ""
        }
    }
}
