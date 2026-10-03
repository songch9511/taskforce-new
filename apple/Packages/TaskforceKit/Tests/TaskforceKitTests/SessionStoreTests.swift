import Auth
import Foundation
import Testing
@testable import TaskforceKit

struct SessionStoreTests {
    let userID = UUID()

    func session(expiresIn seconds: TimeInterval) -> Session {
        let user = User(
            id: userID, appMetadata: [:], userMetadata: [:], aud: "authenticated",
            email: "me@example.com", createdAt: Date(), updatedAt: Date()
        )
        return Session(
            accessToken: "access", tokenType: "bearer", expiresIn: seconds,
            expiresAt: Date().addingTimeInterval(seconds).timeIntervalSince1970,
            refreshToken: "refresh", user: user
        )
    }

    @Test func noSessionIsSignedOut() {
        #expect(SessionStore.state(for: .initialSession, session: nil) == .signedOut)
    }

    @Test func signedOutEventWinsOverSession() {
        #expect(SessionStore.state(for: .signedOut, session: session(expiresIn: 3600)) == .signedOut)
    }

    @Test(arguments: [AuthChangeEvent.initialSession, .signedIn, .tokenRefreshed])
    func sessionIsSignedIn(_ event: AuthChangeEvent) {
        #expect(SessionStore.state(for: event, session: session(expiresIn: 3600))
            == .signedIn(userID: userID, email: "me@example.com"))
    }

    @Test func expiredStoredSessionStaysSignedInUntilRefreshResolves() {
        #expect(SessionStore.state(for: .initialSession, session: session(expiresIn: -60))
            == .signedIn(userID: userID, email: "me@example.com"))
    }
}

/// Keychain 권한이 없을 때처럼 저장이 늘 실패하는 저장소
private struct UnsavableStorage: AuthLocalStorage {
    struct Failure: Error {}
    func store(key: String, value: Data) throws { throw Failure() }
    func retrieve(key: String) throws -> Data? { throw Failure() }
    func remove(key: String) throws {}
}

private struct EmptyStorage: AuthLocalStorage {
    func store(key: String, value: Data) throws {}
    func retrieve(key: String) throws -> Data? { nil }
    func remove(key: String) throws {}
}

/// 세션 하나가 저장돼 있는 저장소
private struct SavedSessionStorage: AuthLocalStorage {
    let data: Data
    func store(key: String, value: Data) throws {}
    func retrieve(key: String) throws -> Data? { data }
    func remove(key: String) throws {}
}

@MainActor
struct SessionStoreSaveTests {
    let fixtures = SessionStoreTests()

    func store(storage: any AuthLocalStorage) -> SessionStore {
        SessionStore(auth: AuthClient(
            url: URL(string: "https://example.supabase.co/auth/v1")!, localStorage: storage, autoRefreshToken: false
        ))
    }

    func emailStore(status: Int, body: String) -> SessionStore {
        let data = Data(body.utf8)
        return SessionStore(auth: AuthClient(
            url: URL(string: "https://example.supabase.co/auth/v1")!, localStorage: EmptyStorage(),
            fetch: { request in
                let url = request.url!
                return (data, HTTPURLResponse(
                    url: url, statusCode: status, httpVersion: nil,
                    headerFields: [
                        "Content-Type": "application/json",
                        "X-Supabase-Api-Version": "2024-01-01",
                    ]
                )!)
            },
            autoRefreshToken: false
        ))
    }

    func offlineEmailStore() -> SessionStore {
        SessionStore(auth: AuthClient(
            url: URL(string: "https://example.supabase.co/auth/v1")!, localStorage: EmptyStorage(),
            fetch: { _ in throw URLError(.notConnectedToInternet) },
            autoRefreshToken: false
        ))
    }

    @Test func signInThatWasNotSavedStaysSignedOut() {
        let store = store(storage: UnsavableStorage())
        store.apply(event: .signedIn, session: fixtures.session(expiresIn: 3600))
        #expect(store.state == .signedOut)
        #expect(store.errorMessage == SessionStore.sessionNotSavedMessage)
    }

    @Test func savedSignInIsSignedIn() throws {
        let session = fixtures.session(expiresIn: 3600)
        let store = store(storage: SavedSessionStorage(data: try JSONEncoder().encode(session)))
        store.apply(event: .signedIn, session: session)
        #expect(store.state == .signedIn(userID: fixtures.userID, email: "me@example.com"))
        #expect(store.errorMessage == nil)
    }

    @Test func signInForDifferentUserThanSavedSessionStaysSignedOut() throws {
        var savedSession = fixtures.session(expiresIn: 3600)
        savedSession.user.id = UUID()
        savedSession.user.email = "previous@example.com"
        let attemptedSession = fixtures.session(expiresIn: 3600)
        let store = store(storage: SavedSessionStorage(data: try JSONEncoder().encode(savedSession)))

        store.apply(event: .signedIn, session: attemptedSession)

        #expect(store.state == .signedOut)
        #expect(store.errorMessage == SessionStore.sessionNotSavedMessage)
    }

    @Test(arguments: [AuthChangeEvent.initialSession, .tokenRefreshed])
    func staleSessionEventKeepsTheSavedUser(_ event: AuthChangeEvent) throws {
        var savedSession = fixtures.session(expiresIn: 3600)
        savedSession.user.id = UUID()
        savedSession.user.email = "current@example.com"
        let staleSession = fixtures.session(expiresIn: 3600)
        let store = store(storage: SavedSessionStorage(data: try JSONEncoder().encode(savedSession)))

        store.apply(event: event, session: staleSession)

        #expect(store.state == .signedIn(userID: savedSession.user.id, email: savedSession.user.email))
        #expect(store.errorMessage == nil)
    }

    @Test(arguments: [AuthChangeEvent.initialSession, .tokenRefreshed])
    func staleSessionEventAfterLogoutStaysSignedOut(_ event: AuthChangeEvent) {
        let store = store(storage: EmptyStorage())

        store.apply(event: event, session: fixtures.session(expiresIn: 3600))

        #expect(store.state == .signedOut)
        #expect(store.errorMessage == nil)
    }

    @Test func expiredSavedSessionRemainsSignedInUntilRefreshResolves() throws {
        let expiredSession = fixtures.session(expiresIn: -60)
        let store = store(storage: SavedSessionStorage(data: try JSONEncoder().encode(expiredSession)))

        store.apply(event: .initialSession, session: expiredSession)

        #expect(store.state == .signedIn(userID: fixtures.userID, email: "me@example.com"))
    }

    @Test func tokenRefreshForSavedUserCanRotateTokens() throws {
        let savedSession = fixtures.session(expiresIn: 3600)
        var refreshedSession = savedSession
        refreshedSession.accessToken = "rotated-access"
        refreshedSession.refreshToken = "rotated-refresh"
        let store = store(storage: SavedSessionStorage(data: try JSONEncoder().encode(savedSession)))

        store.apply(event: .tokenRefreshed, session: refreshedSession)

        #expect(store.state == .signedIn(userID: fixtures.userID, email: "me@example.com"))
        #expect(store.errorMessage == nil)
    }

    // MARK: Google 로그인 (`signInWithGoogle`)

    /// Google ID 토큰 로그인(`/token?grant_type=id_token`)에 이 세션을 돌려주는 서버. 받은 요청이 `signInWithGoogle`의 값인지 본다
    func store(storage: any AuthLocalStorage, signingIn session: Session) throws -> SessionStore {
        let body = try AuthClient.Configuration.jsonEncoder.encode(session)
        return SessionStore(auth: AuthClient(
            url: URL(string: "https://example.supabase.co/auth/v1")!, localStorage: storage,
            fetch: { request in
                let url = try #require(request.url)
                #expect(url.path == "/auth/v1/token")
                #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "grant_type", value: "id_token")])
                let sent = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
                #expect(sent["provider"] as? String == "google")
                #expect(sent["id_token"] as? String == "id-token")
                #expect(sent["access_token"] as? String == "access-token")
                #expect(sent["nonce"] as? String == "nonce")
                return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
            },
            autoRefreshToken: false
        ))
    }

    /// Supabase가 Google ID 토큰으로 만든 사용자 (이름은 `user_metadata`에)
    func googleSession() -> Session {
        var session = fixtures.session(expiresIn: 3600)
        session.user.appMetadata = ["provider": "google", "providers": ["google"]]
        session.user.userMetadata = ["full_name": "Doyun Kim", "name": "Doyun Kim"]
        return session
    }

    func signInWithGoogle(_ store: SessionStore) async -> Bool {
        await store.signInWithGoogle(idToken: "id-token", accessToken: "access-token", nonce: SignInNonce(raw: "nonce"))
    }

    /// 서버는 로그인시켰지만 세션을 Keychain에 저장하지 못했으면 실패다 (앱이 Google SDK 쪽 로그인도 지운다). 이름도 들고 있지 않는다
    @Test func googleSignInThatWasNotSavedFails() async throws {
        let store = try store(storage: UnsavableStorage(), signingIn: googleSession())
        #expect(await signInWithGoogle(store) == false)
        #expect(store.errorMessage == SessionStore.sessionNotSavedMessage)
        #expect(store.takeAccountNameFill(for: fixtures.userID) == nil)
    }

    /// 전 계정의 세션이 남아 있어도 새 세션을 저장하지 못했으면 실패다
    @Test func googleSignInOverAnotherSavedSessionFails() async throws {
        var other = fixtures.session(expiresIn: 3600)
        other.user.id = UUID()
        let store = try store(storage: SavedSessionStorage(data: try JSONEncoder().encode(other)), signingIn: googleSession())
        #expect(await signInWithGoogle(store) == false)
        #expect(store.errorMessage == SessionStore.sessionNotSavedMessage)
        #expect(store.takeAccountNameFill(for: fixtures.userID) == nil)
    }

    /// 저장된 Google 로그인은 그 로그인이 준 이름을 한 번만 준다 (로그인 이벤트는 지우지 않는다)
    @Test func googleSignInGivesItsNameOnce() async throws {
        let session = googleSession()
        let store = try store(storage: SavedSessionStorage(data: try JSONEncoder().encode(session)), signingIn: session)
        #expect(await signInWithGoogle(store))
        #expect(store.errorMessage == nil)
        store.apply(event: .signedIn, session: session)
        #expect(store.takeAccountNameFill(for: fixtures.userID) == AccountNameFill(userID: fixtures.userID, name: "Doyun Kim"))
        #expect(store.takeAccountNameFill(for: fixtures.userID) == nil)
    }

    /// 다른 사용자를 읽던 늦은 읽기(로그아웃 전에 시작한 전 계정의 읽기)는 이름을 가져가지 못하고, 이름은 그 사용자의 읽기에 남는다
    @Test func googleNameIsOnlyForItsOwnUser() async throws {
        let session = googleSession()
        let store = try store(storage: SavedSessionStorage(data: try JSONEncoder().encode(session)), signingIn: session)
        #expect(await signInWithGoogle(store))
        #expect(store.takeAccountNameFill(for: UUID()) == nil)
        #expect(store.takeAccountNameFill(for: fixtures.userID) == AccountNameFill(userID: fixtures.userID, name: "Doyun Kim"))
    }

    /// 꺼내 쓰기 전에 로그아웃하면 이름을 버린다 (다음 계정의 프로필에 채우지 않게)
    @Test func signOutDropsTheGoogleName() async throws {
        let session = googleSession()
        let store = try store(storage: SavedSessionStorage(data: try JSONEncoder().encode(session)), signingIn: session)
        #expect(await signInWithGoogle(store))
        store.apply(event: .signedIn, session: session)
        store.apply(event: .signedOut, session: nil)
        #expect(store.takeAccountNameFill(for: fixtures.userID) == nil)
    }

    @Test func signInMethodsFollowTheSession() throws {
        var session = fixtures.session(expiresIn: 3600)
        session.user.appMetadata = ["provider": "google", "providers": ["google"]]
        let store = store(storage: SavedSessionStorage(data: try JSONEncoder().encode(session)))
        store.apply(event: .signedIn, session: session)
        #expect(store.signInMethods == SignInMethods(providers: ["google"], primary: "google"))
        store.apply(event: .signedOut, session: nil)
        #expect(store.signInMethods == .unknown)
    }

    @Test func emailSignInInvalidCredentialsKeepCredentialGuidance() async {
        let store = emailStore(
            status: 400,
            body: #"{"code":"invalid_credentials","msg":"Invalid login credentials"}"#
        )

        await store.signInWithEmail(email: "me@example.com", password: "wrong")

        #expect(store.errorMessage == "Couldn't sign in. Check your email and password.")
    }

    @Test func emailSignInRateLimitExplainsRetry() async {
        let store = emailStore(
            status: 429,
            body: #"{"code":"over_request_rate_limit","msg":"Too many requests"}"#
        )

        await store.signInWithEmail(email: "me@example.com", password: "password")

        #expect(
            store.errorMessage == "Too many sign-in attempts. Wait a moment before trying again."
        )
    }

    @Test func emailSignInTransportErrorExplainsConnectionIssue() async {
        let store = offlineEmailStore()

        await store.signInWithEmail(email: "me@example.com", password: "password")

        #expect(store.errorMessage == "Can't reach the sign-in service. Check your connection.")
    }

    @Test func emailSignInUnexpectedAuthErrorDoesNotBlameCredentials() async {
        let store = emailStore(
            status: 500,
            body: #"{"code":"unexpected_failure","msg":"Internal server error"}"#
        )

        await store.signInWithEmail(email: "me@example.com", password: "password")

        #expect(store.errorMessage == "Couldn't sign in. Try again in a moment.")
    }

    @Test func emailSignInNotAuthorizedDoesNotRevealAccountStatus() async {
        let store = emailStore(
            status: 403,
            body: #"{"code":"email_address_not_authorized","msg":"Email address is not authorized"}"#
        )

        await store.signInWithEmail(email: "not-allowed@example.com", password: "password")

        #expect(store.errorMessage == "Couldn't sign in. Try again in a moment.")
    }
}
