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
    /// 오류는 아니지만 로그인 화면에 한 줄로 알릴 것 (예: 계정은 지웠지만 Apple 로그인 연결은 남음)
    public private(set) var notice: String?

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
        // supabase-swift는 세션을 Keychain에 저장하지 못해도(오류는 삼킨다) 로그인 이벤트를 보낸다.
        // 그대로 두면 화면은 로그인 상태인데 서버 요청마다 "Sign in again"이 뜬다. 로그인되지 않은 것으로 보고 알린다.
        if event == .signedIn, session != nil, auth.currentSession == nil {
            state = .signedOut
            errorMessage = Self.sessionNotSavedMessage
            return
        }
        state = Self.state(for: event, session: session)
    }

    static let sessionNotSavedMessage = "Couldn't save your sign-in. Try again."

    /// 저장된 세션이 만료됐더라도 로그인 상태로 둔다. 자동 갱신이 곧 `tokenRefreshed`를 보내고,
    /// 갱신이 끝내 실패하면 `signedOut`이 온다. 오프라인일 때 로그인 화면으로 튕기지 않게 하려는 것.
    nonisolated static func state(for event: AuthChangeEvent, session: Session?) -> State {
        guard event != .signedOut, let session else { return .signedOut }
        return .signedIn(userID: session.user.id, email: session.user.email)
    }

    /// 로그인한 계정이 Sign in with Apple 계정인가. 계정 삭제 때 Apple 확인을 받을지 정한다
    /// (이메일로 가입한 계정 · App Store 심사 계정은 폐기할 Apple 토큰이 없다).
    /// 저장된 세션을 읽지 못해 알 수 없으면 Apple 계정으로 본다: 확인 창 한 번이 폐기를 빠뜨리는 것보다 낫다.
    public var isAppleAccount: Bool {
        auth.currentUser.map(Self.hasAppleIdentity) ?? true
    }

    /// 서버(`/api/v1/account`)처럼 identities를 본다. 저장된 세션에 identities가 빠졌을 때를 위해
    /// GoTrue가 모든 사용자에 넣는 app_metadata.providers도 본다.
    nonisolated static func hasAppleIdentity(_ user: User) -> Bool {
        user.identities?.contains { $0.provider == "apple" } == true
            || user.appMetadata["providers"]?.arrayValue?.contains(.string("apple")) == true
    }

    /// Sign in with Apple이 돌려준 ID 토큰으로 Supabase에 로그인한다.
    public func signInWithApple(idToken: String, nonce: AppleSignInNonce) async {
        errorMessage = nil
        notice = nil
        do {
            _ = try await auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce.raw)
            )
        } catch {
            errorMessage = "Couldn't sign in. \(error.localizedDescription)"
        }
    }

    /// 이메일 · 비밀번호 로그인 (App Store 심사 계정용). 가입 화면은 없다: 서버가 허용한 계정만 로그인된다.
    public func signInWithEmail(email: String, password: String) async {
        errorMessage = nil
        notice = nil
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !password.isEmpty else {
            errorMessage = "Enter your email and password."
            return
        }
        do {
            _ = try await auth.signIn(email: email, password: password)
        } catch {
            errorMessage = "Couldn't sign in. Check your email and password."
        }
    }

    public func reportError(_ message: String) {
        errorMessage = message
    }

    /// 계정을 지운 뒤: 서버에는 더 이상 세션이 없으니 이 기기의 세션만 지운다 (공유 Keychain에서도 지워진다).
    /// supabase-swift는 저장된 세션을 먼저 지우고 `signedOut`을 보낸 뒤 서버에 알리므로, 그 요청이 실패해도 로그아웃된다.
    public func accountDeleted(note: String? = nil) async {
        errorMessage = nil
        notice = note
        try? await auth.signOut(scope: .local)
    }

    public func signOut() async {
        errorMessage = nil
        do {
            try await auth.signOut()
        } catch {
            errorMessage = "Couldn't sign out. \(error.localizedDescription)"
        }
    }
}
