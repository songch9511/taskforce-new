import Auth
import Foundation
import Observation
import Supabase

/// 앱 전체의 로그인 상태. 화면은 `state`만 보고 그린다.
@MainActor
@Observable
public final class SessionStore {
    public enum State: Equatable {
        case loading
        case signedOut
        case signedIn(userID: UUID, email: String?)
    }

    public private(set) var state: State = .loading
    public private(set) var errorMessage: String?

    private let auth: AuthClient
    private var listenTask: Task<Void, Never>?

    public init(auth: AuthClient) {
        self.auth = auth
    }

    /// 저장된 세션을 읽고 이후 로그인 · 로그아웃 · 토큰 갱신을 따라간다.
    public func start() {
        guard listenTask == nil else { return }
        listenTask = Task { [weak self, auth] in
            for await (event, session) in auth.authStateChanges {
                self?.apply(event: event, session: session)
            }
        }
    }

    func apply(event: AuthChangeEvent, session: Session?) {
        state = Self.state(for: event, session: session)
    }

    /// 저장된 세션이 만료됐더라도 로그인 상태로 둔다. 자동 갱신이 곧 `tokenRefreshed`를 보내고,
    /// 갱신이 끝내 실패하면 `signedOut`이 온다. 오프라인일 때 로그인 화면으로 튕기지 않게 하려는 것.
    nonisolated static func state(for event: AuthChangeEvent, session: Session?) -> State {
        guard event != .signedOut, let session else { return .signedOut }
        return .signedIn(userID: session.user.id, email: session.user.email)
    }

    /// Sign in with Apple이 돌려준 ID 토큰으로 Supabase에 로그인한다.
    public func signInWithApple(idToken: String, nonce: AppleSignInNonce) async {
        errorMessage = nil
        do {
            _ = try await auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce.raw)
            )
        } catch {
            errorMessage = "로그인하지 못했습니다: \(error.localizedDescription)"
        }
    }

    public func reportError(_ message: String) {
        errorMessage = message
    }

    public func signOut() async {
        errorMessage = nil
        do {
            try await auth.signOut()
        } catch {
            errorMessage = "로그아웃하지 못했습니다: \(error.localizedDescription)"
        }
    }
}
