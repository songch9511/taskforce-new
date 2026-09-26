import AuthenticationServices
import SwiftUI
import TaskforceKit

struct SignInView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.colorScheme) private var colorScheme
    @State private var nonce = AppleSignInNonce.random()

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            VStack(spacing: 8) {
                Text("Taskforce")
                    .font(.largeTitle.bold())
                Text("회의록과 메시지에서 할 일을 찾아드립니다.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            SignInWithAppleButton(.signIn) { request in
                nonce = AppleSignInNonce.random()
                request.requestedScopes = [.email]
                request.nonce = nonce.hashed
            } onCompletion: { result in
                handle(result)
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(maxWidth: 360, minHeight: 48, maxHeight: 48)

            if let message = session.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
    }

    private func handle(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8)
            else {
                session.reportError("Apple 로그인 응답에 ID 토큰이 없습니다.")
                return
            }
            let nonce = nonce
            Task { await session.signInWithApple(idToken: idToken, nonce: nonce) }
        case .failure(let error):
            // 사용자가 창을 닫은 경우는 오류로 보여주지 않는다.
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            session.reportError("Apple 로그인에 실패했습니다: \(error.localizedDescription)")
        }
    }
}
