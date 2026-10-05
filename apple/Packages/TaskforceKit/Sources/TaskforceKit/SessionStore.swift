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

    public static let googleOnlyNotice = "This Mac app supports Google sign-in only. Existing Apple accounts and their data are preserved, but Apple-only accounts cannot sign in or delete their account here. Signing in with Google may open a different account."
    private let googleOnly: Bool
    private var verifiedGoogleUserID: UUID?
    private var googleSignInInProgress = false
    private let auth: AuthClient
    private var listenTask: Task<Void, Never>?
    /// 계정이 이 기기를 떠날 때 부를 정리 (`onSignedOut`)
    @ObservationIgnored private var signedOutCleanups: [@MainActor (UUID) -> Void] = []

    public init(auth: AuthClient, googleOnly: Bool = false) {
        self.googleOnly = googleOnly
        self.auth = auth
    }

    /// 계정이 이 기기를 떠날 때마다 그 계정 ID로 한 번 부른다: 로그아웃 · 세션 만료 · 계정 삭제(이 기기 · 다른 기기에서 지운 뒤
    /// 서버 401로 확인) · 다른 계정으로 전환. 토큰 갱신처럼 같은 계정이면 부르지 않는다.
    /// 상태(`state` · 로그인 방식 · 오류)를 모두 바꾼 직후 같은 흐름에서 불러, 다음 화면이 그려지기 전에 지운다.
    /// 계정별로 이 기기에 남는 데이터(화면 상태 · 메모리 캐시 · 기기 저장본)는 여기에 등록한다.
    /// 앱이 돌지 않을 때 떠난 계정(로그아웃 도중 종료 등)은 여기로 오지 않는다: 디스크에 남기는 것은 시작할 때도 지금 계정 것만 남겨야 한다.
    public func onSignedOut(_ cleanup: @escaping @MainActor (UUID) -> Void) {
        signedOutCleanups.append(cleanup)
    }

    /// 로그인해 있던 계정이 떠났으면(로그아웃 · 다른 계정) 그 계정으로 정리를 부른다
    private func runSignedOutCleanups(ifLeft previous: UUID?) {
        guard let previous, previous != Self.userID(in: state) else { return }
        for cleanup in signedOutCleanups { cleanup(previous) }
    }

    private static func userID(in state: State) -> UUID? {
        if case .signedIn(let userID, _) = state { userID } else { nil }
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
        // 계정이 떠났으면 아래에서 상태를 모두 바꾼 뒤 정리를 부른다 (`onSignedOut`)
        let previousUserID = Self.userID(in: state)
        defer { runSignedOutCleanups(ifLeft: previousUserID) }
        let currentSession = auth.currentSession
        var appliedSession = session
        // supabase-swift는 Keychain 저장 오류를 삼키고 로그인 이벤트를 보낼 수 있다.
        // 저장된 계정이 없거나 다르면 이 로그인은 이 기기에 저장되지 않은 것이다.
        if event == .signedIn, let session, currentSession?.user.id != session.user.id {
            state = .signedOut
            signInMethods = .unknown
            accountNameFill = nil
            errorMessage = Self.sessionNotSavedMessage
            return
        }
        // authStateChanges는 버퍼된 이벤트를 전달한다. 계정이 바뀐 뒤 늦게 도착한 초기 세션이나
        // 토큰 갱신 이벤트는 현재 저장된 계정을 반영한다. 로그아웃 뒤면 저장된 계정이 없다.
        // 비교는 사용자 ID로 해 토큰 갱신에 따른 정상적인 토큰 교체는 허용한다.
        if event != .signedOut, let session, currentSession?.user.id != session.user.id {
            appliedSession = currentSession
        }
        if event == .signedOut { verifiedGoogleUserID = nil }
        if googleOnly, event != .signedOut, let appliedSession,
           !Self.allowsGoogleSession(appliedSession, verifiedGoogleUserID: verifiedGoogleUserID) {
            state = googleSignInInProgress ? .loading : .signedOut
            signInMethods = .unknown
            accountNameFill = nil
            notice = Self.googleOnlyNotice
            return
        }
        state = Self.state(for: event, session: appliedSession)
        if case .signedIn = state, let appliedSession {
            signInMethods = SignInMethods(user: appliedSession.user)
        } else {
            signInMethods = .unknown
            accountNameFill = nil
        }
    }

    // Linked Apple/Google accounts must prove Google sign-in again in this process:
    // provider membership alone does not identify how a persisted session authenticated.
    nonisolated static func allowsGoogleSession(_ session: Session, verifiedGoogleUserID: UUID?) -> Bool {
        let methods = SignInMethods(user: session.user)
        return methods.hasGoogle && (methods.providers == ["google"] || verifiedGoogleUserID == session.user.id)
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
        guard !googleOnly else { notice = Self.googleOnlyNotice; return }
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
        googleSignInInProgress = true
        defer {
            googleSignInInProgress = false
            if googleOnly { apply(event: .initialSession, session: auth.currentSession) }
        }
        do {
            let session = try await auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(provider: .google, idToken: idToken, accessToken: accessToken, nonce: nonce.raw)
            )
            // 세션을 Keychain에 저장하지 못했으면 로그인되지 않은 것이다 (`apply`와 같은 판단)
            guard auth.currentSession?.user.id == session.user.id else {
                errorMessage = Self.sessionNotSavedMessage
                return false
            }
            if googleOnly {
                guard SignInMethods(user: session.user).hasGoogle else {
                    notice = Self.googleOnlyNotice
                    return false
                }
                verifiedGoogleUserID = session.user.id
                apply(event: .signedIn, session: session)
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
        guard !googleOnly else { notice = Self.googleOnlyNotice; return }
        errorMessage = nil
        notice = nil
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !password.isEmpty else {
            errorMessage = "Enter your email and password."
            return
        }
        do {
            _ = try await auth.signIn(email: email, password: password)
        } catch let error as AuthError {
            switch error.errorCode {
            case .invalidCredentials:
                errorMessage = "Couldn't sign in. Check your email and password."
            case .overRequestRateLimit, .overEmailSendRateLimit:
                errorMessage = "Too many sign-in attempts. Wait a moment before trying again."
            default:
                errorMessage = "Couldn't sign in. Try again in a moment."
            }
        } catch is URLError {
            errorMessage = "Can't reach the sign-in service. Check your connection."
        } catch {
            errorMessage = "Couldn't sign in. Try again in a moment."
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

    /// Sign Out: 이 기기의 세션만 끝낸다 (`.local`). 다른 기기의 세션 · 토큰 갱신은 그대로다 (모든 기기 로그아웃은 따로 만들 때 명시적인 동작으로).
    /// supabase-swift는 저장된 세션을 먼저 지우고 `signedOut`을 보낸 뒤 서버에 알린다: 그 요청이 실패해도(오프라인) 이 기기는 이미 로그아웃됐으니 오류로 알리지 않는다.
    public func signOut() async {
        errorMessage = nil
        try? await auth.signOut(scope: .local)
    }
}

extension AuthClient {
    /// 서버 API가 401을 돌려준 뒤: 인증 서버에 지금 세션을 다시 묻는다(`GET /user`). 401만으로는 로그아웃하지 않는다.
    /// - 세션이 서버에 없음(`session_not_found` 등): SDK가 이 기기의 세션을 이미 지우고 `signedOut`을 보냈다
    /// - 계정이 없음(`user_not_found`, 다른 기기에서 계정을 지움): 이 기기의 세션만 지운다 (`.local` → `signedOut` → `SessionStore.onSignedOut`)
    /// 이 기기의 세션이 끝났으면 true. 세션이 살아 있거나 확인하지 못했으면(오프라인 · 인증 서버 오류) false: 그대로 둔다.
    func endSessionIfGone() async -> Bool {
        let checkedUserID = currentSession?.user.id
        do {
            _ = try await user()
            return false
        } catch AuthError.sessionMissing {
            return currentSession == nil
        } catch let AuthError.api(_, code, _, _) where code == .userNotFound {
            guard let checkedUserID else { return false }
            // 겹친 다른 401의 확인이 먼저 이 기기를 로그아웃시켰다
            guard let current = currentSession?.user.id else { return true }
            // 확인하는 사이 다른 계정이 로그인했으면 그 세션은 지우지 않는다
            guard current == checkedUserID else { return false }
            try? await signOut(scope: .local)
            return true
        } catch {
            return false
        }
    }
}
