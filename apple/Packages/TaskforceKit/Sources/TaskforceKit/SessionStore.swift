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
    /// 로그인한 계정의 로그인 방식 (계정 줄 이름). 로그인 전이면 `unknown`. 계정 삭제는 서버에서 새로 읽는다(`AccountDeletionPlan`)
    public private(set) var signInMethods = SignInMethods.unknown
    /// 방금 Google 로그인이 준 이름: 그 사용자의 프로필을 처음 읽을 때 한 번 꺼내 쓴다 (`takeAccountNameFill`)
    private var accountNameFill: AccountNameFill?

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
            signInMethods = .unknown
            accountNameFill = nil
            errorMessage = Self.sessionNotSavedMessage
            return
        }
        state = Self.state(for: event, session: session)
        if case .signedIn = state, let session {
            signInMethods = SignInMethods(user: session.user)
        } else {
            signInMethods = .unknown
            accountNameFill = nil
        }
    }

    static let sessionNotSavedMessage = "Couldn't save your sign-in. Try again."

    /// 저장된 세션이 만료됐더라도 로그인 상태로 둔다. 자동 갱신이 곧 `tokenRefreshed`를 보내고,
    /// 갱신이 끝내 실패하면 `signedOut`이 온다. 오프라인일 때 로그인 화면으로 튕기지 않게 하려는 것.
    nonisolated static func state(for event: AuthChangeEvent, session: Session?) -> State {
        guard event != .signedOut, let session else { return .signedOut }
        return .signedIn(userID: session.user.id, email: session.user.email)
    }

    /// Sign in with Apple이 돌려준 ID 토큰으로 Supabase에 로그인한다.
    public func signInWithApple(idToken: String, nonce: SignInNonce) async {
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

    /// Google Sign-In이 돌려준 ID 토큰 · 액세스 토큰으로 Supabase에 로그인한다 (Google에는 `nonce.hashed`를 보냈다).
    /// 액세스 토큰은 Supabase가 ID 토큰의 `at_hash`와 맞춰 보는 데만 쓴다(저장하지 않음). 실패하면 false (앱이 Google SDK 쪽 로그인도 지운다).
    /// 성공하면 그 로그인이 준 이름을 한 번 들고 있다 (`takeAccountNameFill`).
    @discardableResult
    public func signInWithGoogle(idToken: String, accessToken: String, nonce: SignInNonce) async -> Bool {
        errorMessage = nil
        notice = nil
        do {
            let session = try await auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(provider: .google, idToken: idToken, accessToken: accessToken, nonce: nonce.raw)
            )
            // 세션을 Keychain에 저장하지 못했으면 로그인되지 않은 것이다 (`apply`와 같은 판단)
            guard auth.currentSession?.user.id == session.user.id else {
                errorMessage = Self.sessionNotSavedMessage
                return false
            }
            accountNameFill = AccountNameFill(user: session.user)
            return true
        } catch {
            errorMessage = "Couldn't sign in. \(error.localizedDescription)"
            return false
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

    /// Google 로그인 직후 한 번만 준다: 꺼내면 지운다 (이름이 이미 있어도 다시 채우지 않게).
    /// 그 로그인의 사용자를 읽은 쪽만 꺼낸다: 로그아웃 전에 시작한 전 계정의 늦은 읽기는 다음 계정의 이름을 가져가지 못한다
    public func takeAccountNameFill(for userID: UUID) -> AccountNameFill? {
        guard accountNameFill?.userID == userID else { return nil }
        defer { accountNameFill = nil }
        return accountNameFill
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
