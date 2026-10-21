import Auth
import Foundation
import Synchronization
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

/// `onSigningOut` 정리가 본 값
@MainActor
final class SigningOutProbe {
    var states: [SessionStore.State] = []
    var storedBefore: [Bool] = []
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

    // MARK: 로그아웃 직전 정리 (`onSigningOut`, OA 외부 세션: 옛 토큰이 살아 있는 동안 서버 목록을 비운다)

    /// 정리는 세션이 아직 저장돼 있고 로그인 상태일 때 돈다 (그 뒤에는 토큰이 없어 서버를 부를 수 없다)
    @Test func signingOutHandlersRunWhileTheSessionIsStillStored() async throws {
        let storage = try RemovableStorage(fixtures.session(expiresIn: 3600))
        let store = store(storage: storage)
        store.start()
        await wait(for: signedIn, in: store)
        let seen = SigningOutProbe()
        store.onSigningOut { [unowned store] in
            seen.states.append(store.state)
            seen.storedBefore.append(!storage.isEmpty)
        }
        await store.signOut()
        await wait(for: .signedOut, in: store)
        #expect(seen.states == [signedIn] && seen.storedBefore == [true], "정리가 돌 때는 아직 로그인 상태이고 세션이 저장돼 있다")
        #expect(store.state == .signedOut && storage.isEmpty, "정리 뒤에 로그아웃은 그대로 끝난다")
    }

    /// 끝나지 않는 정리가 로그아웃을 막지 않는다: 한도(기본 3초, 시험은 줄인다) 안에서 로그아웃이 끝난다
    @Test func aSigningOutHandlerThatNeverFinishesDoesNotBlockSignOutPastTheBound() async throws {
        #expect(SessionStore.defaultSigningOutTimeout == .seconds(3))
        let storage = try RemovableStorage(fixtures.session(expiresIn: 3600))
        let store = store(storage: storage)
        store.signingOutTimeout = .milliseconds(150)
        store.start()
        await wait(for: signedIn, in: store)
        store.onSigningOut { try? await Task.sleep(for: .seconds(20)) }
        let started = ContinuousClock.now
        await store.signOut()
        let elapsed = ContinuousClock.now - started
        #expect(elapsed < .seconds(2), "한도 150ms 뒤에는 기다리지 않고 로그아웃한다: \(elapsed)")
        await wait(for: .signedOut, in: store)
        #expect(store.state == .signedOut && storage.isEmpty)
    }

    /// 정리가 던져도 로그아웃은 멈추지 않고 오류로도 알리지 않는다. 뒤의 정리도 돈다
    @Test func aThrowingSigningOutHandlerDoesNotStopSignOutOrTheNextHandler() async throws {
        struct Boom: Error {}
        let storage = try RemovableStorage(fixtures.session(expiresIn: 3600))
        let store = store(storage: storage)
        store.start()
        await wait(for: signedIn, in: store)
        let seen = SigningOutProbe()
        store.onSigningOut { throw Boom() }
        store.onSigningOut { seen.states.append(.signedOut) }
        await store.signOut()
        await wait(for: .signedOut, in: store)
        #expect(seen.states.count == 1, "앞의 정리가 던져도 다음 정리는 돈다")
        #expect(store.state == .signedOut && storage.isEmpty && store.errorMessage == nil)
    }

    /// 세션 만료 · 다른 기기에서 계정 삭제는 "누른 로그아웃"이 아니다: 토큰이 이미 없어 정리를 부르지 않는다 (서버 목록은 보관 기간 · 계정 삭제 cascade가 지운다)
    @Test func signingOutHandlersAreNotCalledWhenTheSessionEndsByItself() async throws {
        let session = fixtures.session(expiresIn: 3600)
        let store = store(storage: try RemovableStorage(session))
        let seen = SigningOutProbe()
        store.onSigningOut { seen.states.append(.signedOut) }
        store.apply(event: .signedIn, session: session)
        store.apply(event: .signedOut, session: nil)
        #expect(seen.states.isEmpty)
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

/// 로그인 방법이 Apple · Google · 이메일 무엇이든 세션은 그대로 로그인 상태다 (Mac의 Google 전용 막기를 없앴다)
@MainActor
struct AnySignInMethodSessionTests {
    static let combinations: [Set<String>] = [["apple"], ["email"], [], ["google"], ["apple", "google"]]

    func store(for session: Session) throws -> SessionStore {
        SessionStore(auth: AuthClient(url: URL(string: "https://example.supabase.co/auth/v1")!,
            localStorage: SavedSessionStorage(data: try JSONEncoder().encode(session)), autoRefreshToken: false))
    }

    func session(providers: Set<String>) -> Session {
        var session = SessionStoreTests().session(expiresIn: 3600)
        session.user.appMetadata = ["providers": .array(providers.map { .string($0) })]
        return session
    }

    @Test(arguments: [AuthChangeEvent.initialSession, .signedIn, .tokenRefreshed])
    func everySignInMethodStaysSignedInWithoutANotice(event: AuthChangeEvent) throws {
        for providers in Self.combinations {
            let session = session(providers: providers)
            let store = try store(for: session)
            store.apply(event: event, session: session)
            #expect(store.state == .signedIn(userID: session.user.id, email: session.user.email), "\(providers)")
            #expect(store.notice == nil)
            #expect(store.errorMessage == nil)
            #expect(store.signInMethods.providers == providers)
        }
    }

    /// 로그아웃하면 방법을 잊는다: 늦게 도착한 토큰 갱신이 로그아웃한 계정을 되살리지 않는다 (이 확인은 방법과 상관없다)
    @Test func signingOutDropsTheAccountForEveryMethod() throws {
        for providers in Self.combinations {
            let session = session(providers: providers)
            let store = try store(for: session)
            store.apply(event: .signedIn, session: session)
            store.apply(event: .signedOut, session: nil)
            #expect(store.state == .signedOut)
            #expect(store.signInMethods == .unknown)
        }
    }

    /// 예전 Google 전용 문구 · 상태는 어디에도 남지 않았다
    @Test func noSignInMethodMakesTheStoreSayGoogleOnly() async throws {
        for providers in Self.combinations {
            let session = session(providers: providers)
            let store = try store(for: session)
            store.apply(event: .initialSession, session: session)
            #expect(store.notice == nil)
        }
    }

    /// 앱 안(iPhone)·브라우저 창(Mac)이 준 Apple ID 토큰으로 로그인한다: Supabase에는 nonce 원본을, provider는 apple로 보낸다
    @Test func signInWithAppleSendsTheAppleProviderTokenAndRawNonce() async throws {
        let fixtures = SessionStoreTests()
        var signedIn = fixtures.session(expiresIn: 3600)
        signedIn.user.appMetadata = ["provider": "apple", "providers": ["apple"]]
        let body = try AuthClient.Configuration.jsonEncoder.encode(signedIn)
        let requests = Mutex<[[String: Any]]>([])
        let store = SessionStore(auth: AuthClient(
            url: URL(string: "https://example.supabase.co/auth/v1")!, localStorage: SavedSessionStorage(data: try JSONEncoder().encode(signedIn)),
            fetch: { request in
                let url = try #require(request.url)
                #expect(url.path == "/auth/v1/token")
                #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "grant_type", value: "id_token")])
                requests.withLock { $0.append((try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:]) }
                return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
            },
            autoRefreshToken: false
        ))
        let nonce = SignInNonce.random()
        await store.signInWithApple(idToken: "apple-id-token", nonce: nonce)
        let sent = try #require(requests.withLock { $0.first })
        #expect(sent["provider"] as? String == "apple")
        #expect(sent["id_token"] as? String == "apple-id-token")
        #expect(sent["nonce"] as? String == nonce.raw)
        #expect(sent["nonce"] as? String != nonce.hashed)
        #expect(sent["access_token"] == nil)
        // 로그인이지 이어 붙이기가 아니다
        #expect(sent["link_identity"] as? Bool != true)
        #expect(store.errorMessage == nil)
    }

    @Test func signInWithAppleReportsFailure() async {
        let store = SessionStore(auth: AuthClient(url: URL(string: "https://example.supabase.co/auth/v1")!, localStorage: EmptyStorage(),
            fetch: { _ in throw URLError(.notConnectedToInternet) }, autoRefreshToken: false))
        await store.signInWithApple(idToken: "apple-id-token", nonce: SignInNonce(raw: "nonce"))
        #expect(store.errorMessage?.hasPrefix("Couldn't sign in.") == true)
        #expect(store.state == .loading)
    }

    /// 이메일 로그인 함수(심사 계정)도 더는 안내만 띄우고 돌아가지 않는다: 인증 서버에 요청을 보낸다
    @Test func emailSignInContactsTheAuthServer() async {
        let contacted = Mutex(false)
        let store = SessionStore(auth: AuthClient(url: URL(string: "https://example.supabase.co/auth/v1")!, localStorage: EmptyStorage(),
            fetch: { _ in contacted.withLock { $0 = true }; throw URLError(.notConnectedToInternet) }, autoRefreshToken: false))
        await store.signInWithEmail(email: "review@example.com", password: "pw")
        #expect(contacted.withLock { $0 })
        #expect(store.notice == nil)
    }
}

// MARK: 이메일 8자리 코드 (`sendEmailCode` · `verifyEmailCode`, OA 이메일 로그인 계약 5.1 · 11.1)

/// 응답을 붙들어 두고 풀 수 있는 문 (한 번)
private actor EmailGate {
    private var entered = false
    private var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        entered = true
        if released { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        released = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }

    func waitUntilEntered(timeout: Duration = .seconds(60)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !entered, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return entered
    }
}

/// 저장 · 읽기가 되는 메모리 저장소 (SDK가 로그인한 세션을 저장하고 `currentSession`이 읽는다)
private final class KeyedStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func store(key: String, value: Data) throws { lock.withLock { values[key] = value } }
    func retrieve(key: String) throws -> Data? { lock.withLock { values[key] } }
    func remove(key: String) throws { lock.withLock { _ = values.removeValue(forKey: key) } }
}

@MainActor
struct SessionStoreEmailCodeTests {
    let fixtures = SessionStoreTests()

    /// `reply`로 답하는 가짜 인증 서버 (nil이면 오프라인). 받은 요청은 `log`에 남는다
    fileprivate func store(
        storage: any AuthLocalStorage = KeyedStorage(), log: RequestLog = RequestLog(), gate: EmailGate? = nil,
        reply: (status: Int, body: String)?
    ) -> SessionStore {
        SessionStore(auth: AuthClient(
            url: URL(string: "https://example.supabase.co/auth/v1")!, localStorage: storage,
            fetch: { request in
                log.append(request)
                await gate?.pass()
                guard let reply else { throw URLError(.notConnectedToInternet) }
                return (Data(reply.body.utf8), HTTPURLResponse(
                    url: request.url!, statusCode: reply.status, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json", "X-Supabase-Api-Version": "2024-01-01"]
                )!)
            },
            autoRefreshToken: false
        ))
    }

    func sessionBody(_ session: Session) throws -> String {
        String(decoding: try AuthClient.Configuration.jsonEncoder.encode(session), as: UTF8.self)
    }

    func body(of request: URLRequest) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
    }

    // MARK: 코드 보내기

    /// 새 사용자를 만들 수 있게(`create_user: true`) 이메일만 보낸다: 사용자 데이터 · 돌아올 주소 · CAPTCHA 없음
    @Test func sendingAsksForANewUserAndSendsNothingElse() async throws {
        let log = RequestLog()
        let store = store(log: log, reply: (200, "{}"))
        let result = await store.sendEmailCode(email: "me@example.com")
        #expect(result == .sent)
        let request = try #require(log.requests.first)
        #expect(log.requests.count == 1)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/auth/v1/otp")
        #expect(URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems == nil)
        let sent = try body(of: request)
        #expect(sent["email"] as? String == "me@example.com")
        #expect(sent["create_user"] as? Bool == true)
        #expect(sent["data"] == nil)
        #expect(sent["gotrue_meta_security"] == nil)
    }

    @Test func sendingClearsTheOldQuietLine() async {
        let store = store(reply: (200, "{}"))
        store.reportError("Couldn't sign in with Apple. Try again.")
        _ = await store.sendEmailCode(email: "me@example.com")
        #expect(store.errorMessage == nil && store.notice == nil)
    }

    @Test(arguments: [
        (429, #"{"code":"over_email_send_rate_limit","msg":"email rate limit exceeded"}"#, EmailSignInFailure.rateLimited),
        (429, #"{"code":"over_request_rate_limit","msg":"too many"}"#, .rateLimited),
        (403, #"{"code":"unexpected_failure","msg":"This email address can't be used."}"#, .blockedAddress),
        (500, #"{"code":"unexpected_failure","msg":"Error sending confirmation email"}"#, .sendFailed),
    ])
    func sendingFailuresAreSorted(_ status: Int, _ body: String, _ expected: EmailSignInFailure) async {
        let store = store(reply: (status, body))
        #expect(await store.sendEmailCode(email: "me@example.com") == .failed(expected))
    }

    @Test func sendingOfflineIsOffline() async {
        let store = store(reply: nil)
        #expect(await store.sendEmailCode(email: "me@example.com") == .failed(.offline))
    }

    // MARK: 코드 확인

    @Test func verifyingUsesTheEmailTypeAndSignsIn() async throws {
        let session = fixtures.session(expiresIn: 3600)
        let log = RequestLog()
        let store = store(log: log, reply: (200, try sessionBody(session)))
        store.apply(event: .initialSession, session: nil)
        #expect(store.state == .signedOut)

        let result = await store.verifyEmailCode(email: "me@example.com", code: "12345678")

        #expect(result == .signedIn)
        let request = try #require(log.requests.first)
        #expect(request.url?.path == "/auth/v1/verify")
        let sent = try body(of: request)
        #expect(sent["type"] as? String == "email")
        #expect(sent["token"] as? String == "12345678")
        #expect(sent["email"] as? String == "me@example.com")
        #expect(sent["token_hash"] == nil)
        #expect(store.errorMessage == nil)
    }

    @Test(arguments: [
        (403, #"{"code":"otp_expired","msg":"Token has expired or is invalid"}"#, EmailSignInFailure.wrongOrExpiredCode),
        (429, #"{"code":"over_request_rate_limit","msg":"too many requests"}"#, .rateLimited),
    ])
    func verifyingFailuresAreSorted(_ status: Int, _ body: String, _ expected: EmailSignInFailure) async {
        let store = store(reply: (status, body))
        store.apply(event: .initialSession, session: nil)
        #expect(await store.verifyEmailCode(email: "me@example.com", code: "12345678") == .failed(expected))
        #expect(store.state == .signedOut)
    }

    @Test func verifyingOfflineIsOffline() async {
        let store = store(reply: nil)
        store.apply(event: .initialSession, session: nil)
        #expect(await store.verifyEmailCode(email: "me@example.com", code: "12345678") == .failed(.offline))
    }

    /// 서버는 로그인시켰지만 세션을 저장하지 못했으면 로그인되지 않은 것이다
    @Test func aSignInThatWasNotSavedFails() async throws {
        let store = store(storage: UnsavableStorage(), reply: (200, try sessionBody(fixtures.session(expiresIn: 3600))))
        store.apply(event: .initialSession, session: nil)
        #expect(await store.verifyEmailCode(email: "me@example.com", code: "12345678") == .failed(.notSaved))
    }

    /// 로그인해 있으면 확인을 부르지 않는다 (다른 계정의 세션을 이메일 세션이 덮지 않게)
    @Test func verifyingWhileSignedInDoesNotCallTheServer() async throws {
        let signedIn = fixtures.session(expiresIn: 3600)
        let log = RequestLog()
        let store = store(storage: SavedSessionStorage(data: try JSONEncoder().encode(signedIn)), log: log, reply: (200, try sessionBody(signedIn)))
        store.apply(event: .signedIn, session: signedIn)
        #expect(store.state == .signedIn(userID: fixtures.userID, email: "me@example.com"))
        #expect(await store.verifyEmailCode(email: "me@example.com", code: "12345678") == .ignored)
        #expect(log.requests.isEmpty)
    }

    @Test func verifyingBeforeTheSessionIsReadDoesNotCallTheServer() async throws {
        let log = RequestLog()
        let store = store(log: log, reply: (200, "{}"))
        #expect(store.state == .loading)
        #expect(await store.verifyEmailCode(email: "me@example.com", code: "12345678") == .ignored)
        #expect(log.requests.isEmpty)
    }

    /// 확인하는 사이 다른 계정이 들어왔으면 늦은 오류를 쓰지 않는다 (지금 계정의 화면에 남의 오류가 뜨지 않게)
    @Test func aLateVerifyErrorAfterAnotherAccountSignedInIsIgnored() async throws {
        var other = fixtures.session(expiresIn: 3600)
        other.user.id = UUID()
        let gate = EmailGate()
        let store = store(
            storage: SavedSessionStorage(data: try JSONEncoder().encode(other)), gate: gate,
            reply: (403, #"{"code":"otp_expired","msg":"Token has expired or is invalid"}"#)
        )
        store.apply(event: .initialSession, session: nil)
        #expect(store.state == .signedOut)

        let pending = Task { await store.verifyEmailCode(email: "me@example.com", code: "12345678") }
        #expect(await gate.waitUntilEntered())
        // 그사이 Apple · Google로 다른 계정이 들어왔다
        store.apply(event: .signedIn, session: other)
        #expect(store.state == .signedIn(userID: other.user.id, email: "me@example.com"))
        await gate.release()

        #expect(await pending.value == .ignored)
        #expect(store.errorMessage == nil)
    }

    // MARK: 이미 있는 문구

    /// 연결 실패 줄은 새 문구가 아니라 이미 있는 문구다: 이메일 · 비밀번호 로그인(심사 계정)과 같은 글
    @Test func theOfflineWordsAreTheOnesThePasswordSignInAlreadyUses() async {
        let offline = store(reply: nil)
        await offline.signInWithEmail(email: "me@example.com", password: "password")
        #expect(offline.errorMessage == SessionStore.offlineMessage)
    }
}
