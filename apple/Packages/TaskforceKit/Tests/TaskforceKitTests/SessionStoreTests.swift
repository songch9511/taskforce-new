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

/// 저장 · 삭제가 되는 메모리 저장소 (로그아웃이 세션을 지운다)
private final class RemovableStorage: AuthLocalStorage, @unchecked Sendable {
    static let key = "taskforce.auth.signout"
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    init(_ session: Session) throws {
        try save(session)
    }

    var isEmpty: Bool { lock.withLock { values[Self.key] == nil } }

    func save(_ session: Session) throws {
        let value = try AuthClient.Configuration.jsonEncoder.encode(session)
        lock.withLock { values[Self.key] = value }
    }

    func store(key: String, value: Data) throws { lock.withLock { values[key] = value } }
    func retrieve(key: String) throws -> Data? { lock.withLock { values[key] } }
    func remove(key: String) throws { lock.withLock { _ = values.removeValue(forKey: key) } }
}

/// 가짜 인증 서버가 받은 요청
private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []

    var requests: [URLRequest] { lock.withLock { recorded } }

    func append(_ request: URLRequest) { lock.withLock { recorded.append(request) } }
}

/// `onSignedOut`이 받은 계정들
@MainActor
final class Departures {
    var ids: [UUID] = []
    /// 정리가 불릴 때 본 로그인 상태
    var states: [SessionStore.State] = []
}

@MainActor
struct SessionStoreSignOutTests {
    let fixtures = SessionStoreTests()

    /// `/logout`에 `logoutStatus`로 답하는 인증 서버 (nil이면 오프라인)
    fileprivate func store(storage: RemovableStorage, log: RequestLog = RequestLog(), logoutStatus: Int? = 204) -> SessionStore {
        SessionStore(auth: AuthClient(
            url: URL(string: "https://example.supabase.co/auth/v1")!, storageKey: RemovableStorage.key, localStorage: storage,
            fetch: { request in
                log.append(request)
                guard let logoutStatus else { throw URLError(.notConnectedToInternet) }
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: logoutStatus, httpVersion: nil, headerFields: nil)!)
            },
            autoRefreshToken: false
        ))
    }

    func wait(for state: SessionStore.State, in store: SessionStore) async {
        for _ in 0..<300 where store.state != state {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    var signedIn: SessionStore.State { .signedIn(userID: fixtures.userID, email: "me@example.com") }

    /// Sign Out은 이 기기의 세션만 끝낸다 (`/logout?scope=local`): 같은 계정의 다른 기기 세션은 서버에 남는다
    @Test func signOutEndsOnlyThisDeviceSession() async throws {
        let storage = try RemovableStorage(fixtures.session(expiresIn: 3600))
        let log = RequestLog()
        let store = store(storage: storage, log: log)
        store.start()
        await wait(for: signedIn, in: store)
        #expect(store.state == signedIn)

        await store.signOut()
        await wait(for: .signedOut, in: store)

        let logout = try #require(log.requests.last)
        #expect(logout.httpMethod == "POST")
        #expect(logout.url?.path == "/auth/v1/logout")
        #expect(URLComponents(url: try #require(logout.url), resolvingAgainstBaseURL: false)?.queryItems
            == [URLQueryItem(name: "scope", value: "local")])
        #expect(logout.value(forHTTPHeaderField: "Authorization") == "Bearer access")
        #expect(store.state == .signedOut)
        #expect(store.errorMessage == nil)
        #expect(storage.isEmpty)
    }

    /// 서버에 알리지 못해도(오프라인) 이 기기의 세션은 이미 지워졌다: 로그아웃 상태이고 오류로 알리지 않는다
    @Test func signOutWhileOfflineStillSignsOutThisDevice() async throws {
        let storage = try RemovableStorage(fixtures.session(expiresIn: 3600))
        let store = store(storage: storage, logoutStatus: nil)
        store.start()
        await wait(for: signedIn, in: store)
        #expect(store.state == signedIn)

        await store.signOut()
        await wait(for: .signedOut, in: store)

        #expect(store.state == .signedOut)
        #expect(store.errorMessage == nil)
        #expect(storage.isEmpty)
    }

    /// 계정이 떠날 때마다 그 계정으로 정리를 한 번 부른다. 토큰 갱신은 떠난 것이 아니다
    @Test func signedOutCleanupRunsOncePerDepartedAccount() throws {
        let session = fixtures.session(expiresIn: 3600)
        let store = store(storage: try RemovableStorage(session))
        let departed = Departures()
        store.onSignedOut { departed.ids.append($0) }

        store.apply(event: .signedIn, session: session)
        store.apply(event: .tokenRefreshed, session: session)
        #expect(departed.ids.isEmpty)

        store.apply(event: .signedOut, session: nil)
        store.apply(event: .signedOut, session: nil)
        #expect(departed.ids == [fixtures.userID])
    }

    /// 다른 계정으로 바뀌면 전 계정을 정리한다. 정리는 상태가 바뀐 뒤에 불린다 (정리하는 쪽이 새 상태를 본다)
    @Test func accountSwitchCleansUpThePreviousAccount() throws {
        let first = fixtures.session(expiresIn: 3600)
        var second = fixtures.session(expiresIn: 3600)
        second.user.id = UUID()
        second.user.email = "second@example.com"
        let storage = try RemovableStorage(first)
        let store = store(storage: storage)
        let departed = Departures()
        store.onSignedOut { departed.ids.append($0) }
        store.onSignedOut { [unowned store] _ in departed.states.append(store.state) }

        store.apply(event: .signedIn, session: first)
        try storage.save(second)
        store.apply(event: .signedIn, session: second)

        let next = SessionStore.State.signedIn(userID: second.user.id, email: "second@example.com")
        #expect(store.state == next)
        #expect(departed.ids == [first.user.id])
        #expect(departed.states == [next])
    }
}
