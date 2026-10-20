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
    private let linkTransport: LinkTransport?
    /// 이 기기의 로그인 계정이 바뀔 때마다(로그아웃 · 다른 계정 · 처음 로그인) 오른다: 오래 걸린 이어 붙이기가 그사이 계정이 바뀌었는지 안다
    private var accountEpoch = 0
    private var listenTask: Task<Void, Never>?
    /// 계정이 이 기기를 떠날 때 부를 정리 (`onSignedOut`)
    @ObservationIgnored private var signedOutCleanups: [@MainActor (UUID) -> Void] = []

    /// `link`: 로그인 방법 이어 붙이기를 보내는 길 (`LinkTransport`). 없으면 이어 붙이기는 늘 `.failed`다
    public init(auth: AuthClient, link: LinkTransport? = nil) {
        self.auth = auth
        self.linkTransport = link
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
        defer {
            if previousUserID != Self.userID(in: state) { accountEpoch += 1 }
            runSignedOutCleanups(ifLeft: previousUserID)
        }
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
        state = Self.state(for: event, session: appliedSession)
        if case .signedIn = state, let appliedSession {
            signInMethods = SignInMethods(user: appliedSession.user)
        } else {
            signInMethods = .unknown
            accountNameFill = nil
        }
    }

    nonisolated static let sessionNotSavedMessage = "Couldn't save your sign-in. Try again."

    /// 저장된 세션이 만료됐더라도 로그인 상태로 둔다. 자동 갱신이 곧 `tokenRefreshed`를 보내고,
    /// 갱신이 끝내 실패하면 `signedOut`이 온다. 오프라인일 때 로그인 화면으로 튕기지 않게 하려는 것.
    nonisolated static func state(for event: AuthChangeEvent, session: Session?) -> State {
        guard event != .signedOut, let session else { return .signedOut }
        return .signedIn(userID: session.user.id, email: session.user.email)
    }

    /// Sign in with Apple이 돌려준 ID 토큰으로 Supabase에 로그인한다.
    /// 응답을 기다리는 사이 다른 계정이 들어왔으면(`accountEpoch`) 늦은 오류를 화면에 쓰지 않는다 (지금 계정의 화면에 남의 오류가 뜨지 않게).
    public func signInWithApple(idToken: String, nonce: SignInNonce) async {
        errorMessage = nil
        notice = nil
        let epoch = accountEpoch
        do {
            _ = try await auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce.raw)
            )
        } catch {
            guard epoch == accountEpoch else { return }
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

    // MARK: 로그인 방법 이어 붙이기 (Settings › Account › Sign-in "Add")

    /// 이어 붙이기 결과. 화면은 이것만 보고 문구를 고른다
    public enum LinkResult: Equatable, Sendable {
        case linked
        /// 그 Apple · Google 계정은 이미 다른 Taskforce 계정에 이어져 있다 (`identity_already_exists`). 데이터를 합치지 않는다
        case belongsToAnotherAccount
        /// 그 밖의 모든 실패 (`manual_linking_disabled` 포함), 또는 흐름을 시작한 계정이 지금 로그인한 계정이 아님 (서버를 부르지 않았다)
        case failed
    }

    /// Apple ID 토큰을 지금 로그인한 계정에 이어 붙인다. 로그인과 같은 nonce 규칙: Apple에는 `nonce.hashed`, 여기에는 원본.
    /// `expectedUserID`: 이 흐름을 시작한 계정. 흐름이 도는 사이 계정이 바뀌었으면 서버에 쓰기 전에 버린다 (다른 계정에 이어 붙이지 않는다).
    public func linkApple(idToken: String, nonce: SignInNonce, expectedUserID: UUID) async -> LinkResult {
        await link(OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce.raw), expectedUserID: expectedUserID)
    }

    /// Google ID 토큰 · 액세스 토큰을 지금 로그인한 계정에 이어 붙인다 (`linkApple`과 같은 규칙, Google에는 `nonce.hashed`를 보냈다).
    public func linkGoogle(idToken: String, accessToken: String, nonce: SignInNonce, expectedUserID: UUID) async -> LinkResult {
        await link(OpenIDConnectCredentials(provider: .google, idToken: idToken, accessToken: accessToken, nonce: nonce.raw), expectedUserID: expectedUserID)
    }

    private func isSignedIn(as userID: UUID) -> Bool {
        Self.userID(in: state) == userID && auth.currentSession?.user.id == userID
    }

    /// 이어 붙이기는 **공유 세션 저장소에 쓰지 않는 길**로 부른다: supabase-swift의 `linkIdentityWithIdToken`은 응답의 세션을 확인 없이 먼저 저장하고 이벤트를 내보내,
    /// 계정이 바뀐 뒤 늦게 온 응답이 새 계정의 세션을 덮는다 (검토 1 P1). 시작 계정의 access token으로 직접 부르고(`LinkTransport`), 응답은 계정이 그대로일 때만 쓴다.
    /// 그 뒤 같은 계정이면 세션을 새로 읽는다(`refreshSession`: 저장된 세션의 identities를 새로). 이것은 지금 저장된 세션 자신을 갱신하는 일이라 SDK가 늦은 갱신을 막는다.
    private func link(_ credentials: OpenIDConnectCredentials, expectedUserID: UUID) async -> LinkResult {
        guard isSignedIn(as: expectedUserID), let linkTransport else { return .failed }
        let epoch = accountEpoch
        func stillTheSameAccount() -> Bool { epoch == accountEpoch && isSignedIn(as: expectedUserID) }
        do {
            // 유효한 access token (만료가 가까우면 SDK가 갱신한다)
            let current = try await auth.session
            guard stillTheSameAccount(), current.user.id == expectedUserID else { return .failed }
            let linked = try await linkTransport.link(credentials, accessToken: current.accessToken)
            // 응답을 기다리는 사이 계정이 바뀌었으면 이 응답을 쓰지 않는다. 저장한 것이 없으니 지울 것도 없다
            guard stillTheSameAccount(), linked.user.id == expectedUserID else { return .failed }
            _ = try? await auth.refreshSession()
            // 이어 붙인 뒤 방법 목록을 서버에서 다시 읽는다 (응답의 사용자에 identities가 빠졌을 수 있다). 못 읽으면 응답의 사용자로 갱신한다
            let fresh = try? await auth.user()
            guard stillTheSameAccount() else { return .failed }
            signInMethods = SignInMethods(user: fresh.flatMap { $0.id == expectedUserID ? $0 : nil } ?? linked.user)
            return .linked
        } catch LinkTransport.Failure.identityAlreadyExists {
            return epoch == accountEpoch ? .belongsToAnotherAccount : .failed
        } catch {
            return .failed
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

    // MARK: 이메일 8자리 코드 (OA 이메일 로그인 계약 5.1 · 19)

    /// 이메일 로그인의 연결 실패 줄이 쓰는 문구: 이미 이메일 · 비밀번호 로그인(`signInWithEmail`)이 쓰는 글이다
    nonisolated static let offlineMessage = "Can't reach the sign-in service. Check your connection."

    /// 이메일로 8자리 코드를 보낸다. 처음 보는 주소면 이때 계정(코드를 넣기 전에는 미확인)이 만들어진다(`shouldCreateUser: true`).
    /// 새 주소 · 기존 주소 모두 같은 결과다: 계정이 있는지 알려 주지 않는다. 서버가 준 설명 · 오류 코드는 화면에 싣지 않는다(`EmailSignInFailure`).
    public func sendEmailCode(email: String) async -> EmailCodeSendResult {
        errorMessage = nil
        notice = nil
        do {
            try await auth.signInWithOTP(email: email, shouldCreateUser: true)
            return .sent
        } catch {
            return .failed(EmailSignInFailure.forSend(error))
        }
    }

    /// 받은 8자리 코드로 로그인한다 (`verifyOTP(type: .email)`). SDK가 응답의 세션을 저장하고 `apply`가 로그인 상태로 바꾼다.
    /// **로그아웃 상태에서만** 부른다: 로그인해 있으면 서버를 부르지 않는다 (다른 계정의 세션을 이메일 세션이 덮지 않게).
    /// 응답을 기다리는 사이 다른 계정이 들어왔으면(`accountEpoch`) 늦은 오류를 쓰지 않는다 (`.ignored`).
    public func verifyEmailCode(email: String, code: String) async -> EmailCodeVerifyResult {
        guard state == .signedOut else { return .ignored }
        errorMessage = nil
        notice = nil
        let epoch = accountEpoch
        do {
            let response = try await auth.verifyOTP(email: email, token: code, type: .email)
            // 세션을 Keychain에 저장하지 못했으면 로그인되지 않은 것이다 (`apply`와 같은 판단)
            guard let session = response.session, auth.currentSession?.user.id == session.user.id else {
                return .failed(.notSaved)
            }
            return .signedIn
        } catch {
            guard epoch == accountEpoch else { return .ignored }
            return .failed(EmailSignInFailure.forVerify(error))
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

/// 로그인 방법 이어 붙이기 요청을 보내는 길 (Supabase Auth REST `POST /token?grant_type=id_token`, `link_identity: true`).
/// `AuthClient`를 거치지 않아 응답의 세션이 공유 저장소에 쓰이지 않는다 (`SessionStore.link`).
public struct LinkTransport: Sendable {
    public enum Failure: Error, Equatable {
        /// 그 Apple · Google 계정은 이미 다른 Taskforce 계정에 이어져 있다 (`identity_already_exists`)
        case identityAlreadyExists
        case failed
    }

    let authURL: URL
    let headers: [String: String]
    let fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// `authURL`: `https://<project ref>.supabase.co/auth/v1`, `headers`: 공개 키(`apikey`)
    public init(authURL: URL, headers: [String: String], fetch: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) {
        self.authURL = authURL
        self.headers = headers
        self.fetch = fetch
    }

    /// 앱: 설정의 Supabase 주소 · 공개 키, 디스크 캐시 없는 세션
    public init(config: AppConfig, session: URLSession = TaskforceClient.urlSession) {
        self.init(authURL: config.supabaseURL.appendingPathComponent("auth/v1"), headers: ["apikey": config.supabaseKey]) { request in
            try await session.data(for: request)
        }
    }

    func link(_ credentials: OpenIDConnectCredentials, accessToken: String) async throws -> Session {
        var components = URLComponents(url: authURL.appendingPathComponent("token"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "grant_type", value: "id_token")]
        guard let url = components?.url else { throw Failure.failed }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 오류 코드가 `code` 문자열로 오는 판 (SDK 기본과 같다)
        request.setValue("2024-01-01", forHTTPHeaderField: "X-Supabase-Api-Version")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        var body = (try JSONSerialization.jsonObject(with: AuthClient.Configuration.jsonEncoder.encode(credentials)) as? [String: Any]) ?? [:]
        body["link_identity"] = true
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await fetch(request)
        guard let http = response as? HTTPURLResponse else { throw Failure.failed }
        guard (200..<300).contains(http.statusCode) else { throw Self.failure(from: data) }
        return try AuthClient.Configuration.jsonDecoder.decode(Session.self, from: data)
    }

    /// 오류 본문의 코드: `code`(문자열) 또는 `error_code`
    static func failure(from data: Data) -> Failure {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = (json?["error_code"] as? String) ?? (json?["code"] as? String)
        return code == "identity_already_exists" ? .identityAlreadyExists : .failed
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
