import Auth
import Foundation
import Synchronization
import Testing
@testable import TaskforceKit

/// 로그인 이어 붙이기 (OA 로그인 계약 5.5): 방법별 줄 · `linkApple` · `linkGoogle` · 계정 경계 · 승인 전 문구.
/// 인증 서버는 가짜다 (`FakeAuthServer`): 실제 Apple · Google · Supabase에 닿지 않는다.

private func identity(_ provider: String, email: String?, userID: UUID) -> UserIdentity {
    UserIdentity(id: "sub-\(provider)", identityId: UUID(), userId: userID, identityData: email.map { ["email": .string($0)] } ?? [:],
        provider: provider, createdAt: nil, lastSignInAt: nil, updatedAt: nil)
}

private func user(
    id: UUID, providers: [String], emails: [String: String] = [:], accountEmail: String? = "me@example.com", withIdentities: Bool = true,
    appMetadata extra: [String: AnyJSON] = [:]
) -> User {
    var appMetadata: [String: AnyJSON] = ["provider": .string(providers.first ?? "email"), "providers": .array(providers.map { .string($0) })]
    appMetadata.merge(extra) { _, new in new }
    return User(id: id, appMetadata: appMetadata, userMetadata: [:],
        aud: "authenticated", email: accountEmail, createdAt: Date(), updatedAt: Date(),
        identities: withIdentities ? providers.map { identity($0, email: emails[$0], userID: id) } : nil)
}

private func session(for user: User, token: String = "access", validFor seconds: TimeInterval = 3600) -> Session {
    Session(accessToken: token, tokenType: "bearer", expiresIn: seconds, expiresAt: Date().addingTimeInterval(seconds).timeIntervalSince1970,
        refreshToken: "refresh-\(token)", user: user)
}

/// 메모리 세션 저장소
private final class MemoryStorage: AuthLocalStorage, @unchecked Sendable {
    static let key = "taskforce.auth.linking"
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    init(_ session: Session) throws { try save(session) }

    var isEmpty: Bool { lock.withLock { values[Self.key] == nil } }
    func save(_ session: Session) throws {
        let value = try AuthClient.Configuration.jsonEncoder.encode(session)
        lock.withLock { values[Self.key] = value }
    }
    func store(key: String, value: Data) throws { lock.withLock { values[key] = value } }
    func retrieve(key: String) throws -> Data? { lock.withLock { values[key] } }
    func remove(key: String) throws { lock.withLock { _ = values.removeValue(forKey: key) } }
}

/// 응답을 붙들어 두고 풀 수 있는 문 (한 번)
private actor Gate {
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

    /// 문에 닿을 때까지 기다린다 (제한 시간은 실패를 알리려는 것일 뿐, 고정 대기가 아니다)
    func waitUntilEntered(timeout: Duration = .seconds(60)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !entered, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return entered
    }
}

/// 가짜 Supabase 인증 서버: 이어 붙이기(`/token`) · 사용자 읽기(`/user`) · 로그아웃(`/logout`)에 정해 둔 답을 준다
private final class FakeAuthServer: @unchecked Sendable {
    struct Reply {
        var status: Int
        var body: Data
    }

    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    let link: Reply?           // nil이면 오프라인
    let userRead: Reply?       // nil이면 오프라인
    let linkGate: Gate?
    /// 이어 붙이기가 아닌 `/token`(로그인 · 갱신)의 답. 없으면 `link`와 같다
    let signIn: Reply?
    /// 이어 붙이기가 아닌 `/token`의 답을 붙들어 두는 문
    let signInGate: Gate?

    init(link: Reply?, userRead: Reply?, linkGate: Gate? = nil, signIn: Reply? = nil, signInGate: Gate? = nil) {
        self.link = link
        self.userRead = userRead
        self.linkGate = linkGate
        self.signIn = signIn
        self.signInGate = signInGate
    }

    var requests: [URLRequest] { lock.withLock { recorded } }
    func requests(path: String) -> [URLRequest] { requests.filter { $0.url?.path == "/auth/v1/\(path)" } }

    func handle(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { recorded.append(request) }
        let url = try #require(request.url)
        let reply: Reply
        switch url.path {
        case "/auth/v1/token":
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:]
            if body["link_identity"] as? Bool == true {
                await linkGate?.pass()
                guard let link else { throw URLError(.notConnectedToInternet) }
                reply = link
            } else {
                await signInGate?.pass()
                guard let answer = signIn ?? link else { throw URLError(.notConnectedToInternet) }
                reply = answer
            }
        case "/auth/v1/user":
            guard let userRead else { throw URLError(.notConnectedToInternet) }
            reply = userRead
        default:
            reply = Reply(status: 204, body: Data())
        }
        return (reply.body, HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: ["Content-Type": "application/json", "X-Supabase-Api-Version": "2024-01-01"])!)
    }

    static func ok(_ value: some Encodable) throws -> Reply {
        Reply(status: 200, body: try AuthClient.Configuration.jsonEncoder.encode(value))
    }
    static func error(status: Int, code: String) -> Reply {
        Reply(status: status, body: Data(#"{"code":"\#(code)","msg":"\#(code)"}"#.utf8))
    }
}

@MainActor
struct SignInLinkingTests {
    let me = UUID()

    fileprivate func makeStore(server: FakeAuthServer, storage: MemoryStorage) -> SessionStore {
        SessionStore(auth: AuthClient(url: URL(string: "https://example.supabase.co/auth/v1")!, storageKey: MemoryStorage.key, localStorage: storage,
            fetch: { try await server.handle($0) }, autoRefreshToken: false), link: transport(server))
    }

    /// 이어 붙이기를 같은 가짜 서버로 보낸다 (공유 세션 저장소에 쓰지 않는 길)
    fileprivate func transport(_ server: FakeAuthServer) -> LinkTransport {
        LinkTransport(authURL: URL(string: "https://example.supabase.co/auth/v1")!, headers: ["apikey": "public-key"]) { try await server.handle($0) }
    }

    /// Google 계정으로 로그인해 있는 상태 (Apple은 아직 이어지지 않음)
    fileprivate func signedInWithGoogle(link: FakeAuthServer.Reply? = nil, userRead: FakeAuthServer.Reply? = nil, gate: Gate? = nil)
        throws -> (store: SessionStore, server: FakeAuthServer, storage: MemoryStorage) {
        let current = session(for: user(id: me, providers: ["google"], emails: ["google": "me@gmail.com"]))
        let storage = try MemoryStorage(current)
        let server = FakeAuthServer(link: link, userRead: userRead, linkGate: gate)
        let store = makeStore(server: server, storage: storage)
        store.apply(event: .signedIn, session: current)
        return (store, server, storage)
    }

    func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
    }

    // MARK: 이어 붙이기

    @Test func linkingAppleSendsTheTokenWithTheRawNonceAndUpdatesTheMethods() async throws {
        let linked = user(id: me, providers: ["google", "apple"], emails: ["google": "me@gmail.com", "apple": "relay@privaterelay.appleid.com"])
        let (store, server, _) = try signedInWithGoogle(link: FakeAuthServer.ok(session(for: linked, token: "linked")), userRead: FakeAuthServer.ok(linked))
        #expect(store.signInMethods.providers == ["google"])
        let nonce = SignInNonce.random()

        let result = await store.linkApple(idToken: "apple-id-token", nonce: nonce, expectedUserID: me)

        #expect(result == .linked)
        let request = try #require(server.requests(path: "token").first)
        #expect(request.httpMethod == "POST")
        #expect(URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "grant_type", value: "id_token")])
        // 지금 로그인한 계정의 토큰으로 보낸다 (이 계정에 붙는다)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access")
        let body = try jsonBody(request)
        #expect(body["provider"] as? String == "apple")
        #expect(body["id_token"] as? String == "apple-id-token")
        #expect(body["nonce"] as? String == nonce.raw)
        #expect(body["link_identity"] as? Bool == true)
        #expect(body["access_token"] == nil)
        // 이어 붙인 뒤 방법 목록을 서버에서 다시 읽는다
        #expect(server.requests(path: "user").count == 1)
        #expect(store.signInMethods.providers == ["google", "apple"])
        #expect(store.signInMethods.emails["apple"] == "relay@privaterelay.appleid.com")
        // 계정이 그대로라서 저장된 세션도 새로 읽는다 (identities가 새로): 두 번째 /token은 이어 붙이기가 아니라 갱신이다
        let tokenRequests = server.requests(path: "token")
        #expect(tokenRequests.count == 2)
        let refresh = try #require(tokenRequests.last)
        #expect(URLComponents(url: try #require(refresh.url), resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "grant_type", value: "refresh_token")])
        #expect(try jsonBody(refresh)["link_identity"] == nil)
        #expect(store.state == .signedIn(userID: me, email: "me@example.com"))
    }

    @Test func linkingGoogleSendsBothTokens() async throws {
        let current = session(for: user(id: me, providers: ["apple"], emails: ["apple": "me@example.com"]))
        let linked = user(id: me, providers: ["apple", "google"], emails: ["apple": "me@example.com", "google": "me@gmail.com"])
        let storage = try MemoryStorage(current)
        let server = FakeAuthServer(link: try FakeAuthServer.ok(session(for: linked, token: "linked")), userRead: try FakeAuthServer.ok(linked))
        let store = makeStore(server: server, storage: storage)
        store.apply(event: .signedIn, session: current)

        let result = await store.linkGoogle(idToken: "g-id", accessToken: "g-access", nonce: SignInNonce(raw: "raw-n"), expectedUserID: me)

        #expect(result == .linked)
        let body = try jsonBody(try #require(server.requests(path: "token").first))
        #expect(body["provider"] as? String == "google")
        #expect(body["id_token"] as? String == "g-id")
        #expect(body["access_token"] as? String == "g-access")
        #expect(body["nonce"] as? String == "raw-n")
        #expect(body["link_identity"] as? Bool == true)
        #expect(store.signInMethods.providers == ["apple", "google"])
    }

    /// 요청은 시작 계정의 access token과 공개 키로, `link_identity: true`와 함께 직접 보낸다 (SDK의 저장하는 길이 아니다)
    @Test func theLinkRequestIsSentDirectlyWithTheStartAccountsToken() async throws {
        let linked = user(id: me, providers: ["google", "apple"])
        let (store, server, _) = try signedInWithGoogle(link: FakeAuthServer.ok(session(for: linked, token: "linked")), userRead: FakeAuthServer.ok(linked))
        #expect(await store.linkApple(idToken: "t", nonce: SignInNonce(raw: "n"), expectedUserID: me) == .linked)
        let request = try #require(server.requests(path: "token").first)
        #expect(request.value(forHTTPHeaderField: "apikey") == "public-key")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(try jsonBody(request)["link_identity"] as? Bool == true)
    }

    /// 길(LinkTransport)이 없으면 이어 붙이지 않는다 (서버를 부르지 않는다)
    @Test func withoutALinkTransportNothingIsSent() async throws {
        let current = session(for: user(id: me, providers: ["google"]))
        let storage = try MemoryStorage(current)
        let server = FakeAuthServer(link: nil, userRead: nil)
        let store = SessionStore(auth: AuthClient(url: URL(string: "https://example.supabase.co/auth/v1")!, storageKey: MemoryStorage.key, localStorage: storage,
            fetch: { try await server.handle($0) }, autoRefreshToken: false))
        store.apply(event: .signedIn, session: current)
        #expect(await store.linkApple(idToken: "t", nonce: SignInNonce(raw: "n"), expectedUserID: me) == .failed)
        #expect(server.requests.isEmpty)
    }

    /// 오류 코드는 `code`(문자열) 판과 `error_code` 판 둘 다 읽는다
    @Test func bothErrorBodyShapesAreRead() {
        #expect(LinkTransport.failure(from: Data(#"{"code":"identity_already_exists","msg":"x"}"#.utf8)) == .identityAlreadyExists)
        #expect(LinkTransport.failure(from: Data(#"{"code":422,"error_code":"identity_already_exists","msg":"x"}"#.utf8)) == .identityAlreadyExists)
        #expect(LinkTransport.failure(from: Data(#"{"code":"manual_linking_disabled"}"#.utf8)) == .failed)
        #expect(LinkTransport.failure(from: Data("not json".utf8)) == .failed)
    }

    /// 검토 1 P3-5: 로그인 응답을 기다리는 사이 다른 계정이 들어왔으면 늦은 오류를 화면에 쓰지 않는다
    @Test func aLateSignInErrorAfterAnAccountChangeIsNotShown() async throws {
        let gate = Gate()
        let storage = try MemoryStorage(session(for: user(id: me, providers: ["google"])))
        let server = FakeAuthServer(link: nil, userRead: nil, signIn: FakeAuthServer.error(status: 500, code: "unexpected_failure"), signInGate: gate)
        let store = makeStore(server: server, storage: storage)
        let pending = Task { await store.signInWithApple(idToken: "t", nonce: SignInNonce(raw: "n")) }
        #expect(await gate.waitUntilEntered())
        // 기다리는 사이 다른 계정이 로그인한다
        let other = session(for: user(id: UUID(), providers: ["apple"], accountEmail: "other@example.com"), token: "other")
        try storage.save(other)
        store.apply(event: .signedIn, session: other)
        await gate.release()
        await pending.value
        #expect(store.errorMessage == nil)
        #expect(store.state == .signedIn(userID: other.user.id, email: "other@example.com"))
    }

    /// 계정이 그대로면 로그인 오류는 그대로 보인다
    @Test func aSignInErrorWithoutAnAccountChangeIsShown() async throws {
        let storage = try MemoryStorage(session(for: user(id: me, providers: ["google"])))
        let server = FakeAuthServer(link: nil, userRead: nil, signIn: FakeAuthServer.error(status: 500, code: "unexpected_failure"))
        let store = makeStore(server: server, storage: storage)
        await store.signInWithApple(idToken: "t", nonce: SignInNonce(raw: "n"))
        #expect(store.errorMessage?.hasPrefix("Couldn't sign in.") == true)
    }

    /// 이어 붙인 응답에 identities가 빠져 있고 다시 읽지 못해도, 응답의 사용자로 목록을 갱신한다
    @Test func ifTheRereadFailsTheLinkResponseUpdatesTheMethods() async throws {
        let linked = user(id: me, providers: ["google", "apple"], withIdentities: false)
        let (store, server, _) = try signedInWithGoogle(link: FakeAuthServer.ok(session(for: linked, token: "linked")), userRead: nil)
        let result = await store.linkApple(idToken: "t", nonce: SignInNonce(raw: "n"), expectedUserID: me)
        #expect(result == .linked)
        // 읽지 못하면 SDK가 읽기를 다시 시도할 수 있다
        #expect(server.requests(path: "user").count >= 1)
        #expect(store.signInMethods.providers == ["google", "apple"])
    }

    /// 이미 다른 Taskforce 계정에 이어진 Apple · Google: 한 줄로 알릴 수 있게 따로 가른다. 방법 목록은 그대로
    @Test func anIdentityOfAnotherAccountIsReportedSeparately() async throws {
        let (store, server, _) = try signedInWithGoogle(link: FakeAuthServer.error(status: 422, code: "identity_already_exists"))
        let result = await store.linkApple(idToken: "t", nonce: SignInNonce(raw: "n"), expectedUserID: me)
        #expect(result == .belongsToAnotherAccount)
        #expect(store.signInMethods.providers == ["google"])
        #expect(server.requests(path: "user").isEmpty)
        let google = await store.linkGoogle(idToken: "t", accessToken: "a", nonce: SignInNonce(raw: "n"), expectedUserID: me)
        #expect(google == .belongsToAnotherAccount)
        #expect(store.state == .signedIn(userID: me, email: "me@example.com"))
    }

    @Test func everyOtherFailureIsAGenericFailure() async throws {
        for reply in [
            FakeAuthServer.error(status: 422, code: "manual_linking_disabled"),
            FakeAuthServer.error(status: 400, code: "bad_jwt"),
            FakeAuthServer.error(status: 429, code: "over_request_rate_limit"),
            FakeAuthServer.error(status: 500, code: "unexpected_failure"),
            nil,
        ] as [FakeAuthServer.Reply?] {
            let (store, _, _) = try signedInWithGoogle(link: reply)
            let result = await store.linkApple(idToken: "t", nonce: SignInNonce(raw: "n"), expectedUserID: me)
            #expect(result == .failed, "\(String(describing: reply?.status))")
            #expect(store.signInMethods.providers == ["google"])
            #expect(store.state == .signedIn(userID: me, email: "me@example.com"))
            #expect(store.errorMessage == nil)
        }
    }

    // MARK: 계정 경계

    /// 흐름을 시작한 계정이 지금 로그인한 계정이 아니면 서버를 부르지 않는다 (다른 계정에 이어 붙이지 않는다)
    @Test func aFlowStartedForAnotherAccountNeverReachesTheServer() async throws {
        let linked = user(id: me, providers: ["google", "apple"])
        let (store, server, _) = try signedInWithGoogle(link: FakeAuthServer.ok(session(for: linked)), userRead: FakeAuthServer.ok(linked))
        let apple = await store.linkApple(idToken: "t", nonce: SignInNonce(raw: "n"), expectedUserID: UUID())
        let google = await store.linkGoogle(idToken: "t", accessToken: "a", nonce: SignInNonce(raw: "n"), expectedUserID: UUID())
        #expect(apple == .failed && google == .failed)
        #expect(server.requests.isEmpty)
        #expect(store.signInMethods.providers == ["google"])
    }

    @Test func signedOutNeverReachesTheServer() async throws {
        let server = FakeAuthServer(link: nil, userRead: nil)
        let current = session(for: user(id: me, providers: ["google"]))
        let store = makeStore(server: server, storage: try MemoryStorage(current))
        #expect(store.state == .loading)
        #expect(await store.linkApple(idToken: "t", nonce: SignInNonce(raw: "n"), expectedUserID: me) == .failed)
        store.apply(event: .signedOut, session: nil)
        #expect(await store.linkApple(idToken: "t", nonce: SignInNonce(raw: "n"), expectedUserID: me) == .failed)
        #expect(server.requests.isEmpty)
    }

    /// 검토 1 P1: 실제 listener를 켠 채로 A에서 Add → 로그아웃 → B 로그인 → A의 늦은 응답이 도착해도 B의 세션 · bearer는 그대로다.
    /// (SDK의 `linkIdentityWithIdToken`은 응답을 먼저 공유 저장소에 쓰므로, 이어 붙이기는 저장하지 않는 길로 부른다)
    @Test func aLateLinkResponseNeverReplacesTheNewAccountsSession() async throws {
        let gate = Gate()
        let accountB = UUID()
        let sessionA = session(for: user(id: me, providers: ["google"], emails: ["google": "me@gmail.com"]), token: "access-A")
        let sessionB = session(for: user(id: accountB, providers: ["apple"], accountEmail: "b@example.com"), token: "access-B")
        let linkedA = user(id: me, providers: ["google", "apple"])
        let storage = try MemoryStorage(sessionA)
        let server = FakeAuthServer(link: try FakeAuthServer.ok(session(for: linkedA, token: "late-A")), userRead: try FakeAuthServer.ok(linkedA),
            linkGate: gate, signIn: try FakeAuthServer.ok(sessionB))
        let auth = AuthClient(url: URL(string: "https://example.supabase.co/auth/v1")!, storageKey: MemoryStorage.key, localStorage: storage,
            fetch: { try await server.handle($0) }, autoRefreshToken: false)
        let store = SessionStore(auth: auth, link: transport(server))
        store.start()
        func waitFor(_ state: SessionStore.State) async {
            for _ in 0..<12_000 where store.state != state { try? await Task.sleep(for: .milliseconds(5)) }
        }
        await waitFor(.signedIn(userID: me, email: "me@example.com"))
        #expect(store.state == .signedIn(userID: me, email: "me@example.com"))

        let pending = Task { await store.linkApple(idToken: "t", nonce: SignInNonce(raw: "n"), expectedUserID: me) }
        #expect(await gate.waitUntilEntered())
        await store.signOut()
        await waitFor(.signedOut)
        await store.signInWithApple(idToken: "b-token", nonce: SignInNonce(raw: "b-nonce"))
        await waitFor(.signedIn(userID: accountB, email: "b@example.com"))
        #expect(store.state == .signedIn(userID: accountB, email: "b@example.com"))

        await gate.release()
        #expect(await pending.value == .failed)

        // B의 세션 · bearer가 그대로다 (저장소가 비어도, A로 바뀌어도 안 된다)
        #expect(auth.currentSession?.user.id == accountB)
        #expect(auth.currentSession?.accessToken == "access-B")
        #expect(store.state == .signedIn(userID: accountB, email: "b@example.com"))
        #expect(!storage.isEmpty)
        // 늦은 응답 때문에 로그아웃을 더 보내지 않았다 (A가 직접 한 로그아웃 하나뿐)
        #expect(server.requests(path: "logout").count == 1)
        // 새 계정의 세션을 새로 읽지도, 사용자를 다시 읽지도 않았다 (늦은 응답은 서버 호출 없이 버려진다)
        let refreshes = server.requests(path: "token").filter { $0.url?.query?.contains("refresh_token") == true }
        #expect(refreshes.isEmpty)
        #expect(server.requests(path: "user").isEmpty)
    }

    /// 같은 계정이면 토큰 갱신이 겹쳐도 결과를 쓴다 (계정이 바뀐 것이 아니다)
    @Test func aTokenRefreshInTheMeantimeIsNotAnAccountSwitch() async throws {
        let gate = Gate()
        let linked = user(id: me, providers: ["google", "apple"])
        let (store, _, _) = try signedInWithGoogle(link: FakeAuthServer.ok(session(for: linked, token: "linked")), userRead: FakeAuthServer.ok(linked), gate: gate)
        let pending = Task { await store.linkApple(idToken: "t", nonce: SignInNonce(raw: "n"), expectedUserID: me) }
        #expect(await gate.waitUntilEntered())
        store.apply(event: .tokenRefreshed, session: session(for: user(id: me, providers: ["google"]), token: "access"))
        await gate.release()
        #expect(await pending.value == .linked)
        #expect(store.signInMethods.providers == ["google", "apple"])
    }

    /// 시작 계정이 아니면 만료된 세션을 새로 읽으러 서버에도 가지 않는다 (남의 계정의 토큰을 건드리지 않는다)
    @Test func aFlowStartedForAnotherAccountDoesNotEvenRefreshAnExpiredSession() async throws {
        let expired = session(for: user(id: me, providers: ["google"]), validFor: -60)
        let server = FakeAuthServer(link: nil, userRead: nil)
        let store = makeStore(server: server, storage: try MemoryStorage(expired))
        store.apply(event: .signedIn, session: expired)
        #expect(await store.linkApple(idToken: "t", nonce: SignInNonce(raw: "n"), expectedUserID: UUID()) == .failed)
        #expect(server.requests.isEmpty)
    }

    /// 이어 붙인 뒤 세션을 새로 읽는 사이 다른 계정이 들어오면, 떠난 계정의 방법 목록을 쓰지 않는다
    @Test func aSwitchWhileTheSessionIsReReadDoesNotWriteTheOldAccountsMethods() async throws {
        let gate = Gate()
        let linked = user(id: me, providers: ["google", "apple"])
        let current = session(for: user(id: me, providers: ["google"]))
        let storage = try MemoryStorage(current)
        let server = FakeAuthServer(link: try FakeAuthServer.ok(session(for: linked, token: "linked")), userRead: try FakeAuthServer.ok(linked),
            signIn: try FakeAuthServer.ok(session(for: linked, token: "refreshed")), signInGate: gate)
        let store = makeStore(server: server, storage: storage)
        store.apply(event: .signedIn, session: current)

        let pending = Task { await store.linkApple(idToken: "t", nonce: SignInNonce(raw: "n"), expectedUserID: me) }
        // 이어 붙이기 응답은 도착했고, 세션을 새로 읽는 요청에 붙들려 있다
        #expect(await gate.waitUntilEntered())
        let other = session(for: user(id: UUID(), providers: ["apple"], accountEmail: "other@example.com"), token: "other")
        try storage.save(other)
        store.apply(event: .signedIn, session: other)
        await gate.release()

        #expect(await pending.value == .failed)
        #expect(store.state == .signedIn(userID: other.user.id, email: "other@example.com"))
        #expect(store.signInMethods.providers == ["apple"])
    }

    /// 이미 다른 계정 것이라는 늦은 답도, 그 사이 계정이 바뀌었으면 지금 계정의 화면에 알리지 않는다
    @Test func aLateAnotherAccountAnswerAfterAnAccountSwitchIsJustAFailure() async throws {
        let gate = Gate()
        let (store, _, storage) = try signedInWithGoogle(link: FakeAuthServer.error(status: 422, code: "identity_already_exists"), gate: gate)
        let pending = Task { await store.linkApple(idToken: "t", nonce: SignInNonce(raw: "n"), expectedUserID: me) }
        #expect(await gate.waitUntilEntered())
        let other = session(for: user(id: UUID(), providers: ["apple"], accountEmail: "other@example.com"), token: "other")
        try storage.save(other)
        store.apply(event: .signedIn, session: other)
        await gate.release()
        #expect(await pending.value == .failed)
    }

    /// 서버가 다른 사용자를 돌려주면 그 방법 목록을 쓰지 않는다 (이어 붙이기 응답의 사용자로 갱신한다)
    @Test func aRereadOfAnotherUserIsNotUsed() async throws {
        let linked = user(id: me, providers: ["google", "apple"])
        let stranger = user(id: UUID(), providers: ["google", "apple", "email"])
        let (store, _, _) = try signedInWithGoogle(link: FakeAuthServer.ok(session(for: linked, token: "linked")), userRead: FakeAuthServer.ok(stranger))
        #expect(await store.linkApple(idToken: "t", nonce: SignInNonce(raw: "n"), expectedUserID: me) == .linked)
        #expect(store.signInMethods.providers == ["google", "apple"])
    }

    /// 앱이 쓰는 길은 설정의 Supabase 주소와 공개 키를 쓴다
    @Test func theAppTransportUsesTheConfiguredAuthServerAndPublicKey() {
        let config = AppConfig(supabaseURL: URL(string: "https://abc.supabase.co")!, supabaseKey: "sb_publishable_x", appGroupID: "group.example",
            apiBaseURL: URL(string: "https://api.example.com")!)
        let transport = LinkTransport(config: config)
        #expect(transport.authURL.absoluteString == "https://abc.supabase.co/auth/v1")
        #expect(transport.headers == ["apikey": "sb_publishable_x"])
    }
}

struct SignInMethodRowTests {
    let id = UUID()

    func methods(_ providers: [String], emails: [String: String] = [:]) -> SignInMethods {
        SignInMethods(user: user(id: id, providers: providers, emails: emails))
    }

    @Test func linkedMethodsComeFirstThenTheOnesToAdd() {
        let google = methods(["google"], emails: ["google": "me@gmail.com"])
        #expect(google.rows(accountEmail: "me@example.com") == [
            SignInMethodRow(method: .google, linked: true, email: "me@gmail.com"),
            SignInMethodRow(method: .apple, linked: false, email: nil),
        ])
        let apple = methods(["apple"], emails: ["apple": "a@icloud.com"])
        #expect(apple.rows(accountEmail: nil) == [
            SignInMethodRow(method: .apple, linked: true, email: "a@icloud.com"),
            SignInMethodRow(method: .google, linked: false, email: nil),
        ])
        let both = methods(["google", "apple"], emails: ["google": "g@x.co", "apple": "a@x.co"])
        #expect(both.rows(accountEmail: nil).map(\.method) == [.apple, .google])
        #expect(both.rows(accountEmail: nil).allSatisfy { $0.linked })
        #expect(both.rows(accountEmail: nil).allSatisfy { !$0.canAdd })
    }

    /// 이메일 로그인(App Store 심사 계정)은 Email 줄만 있다: Apple · Google Add를 두지 않는다. 이메일이 없는 identity는 계정 이메일을 보인다
    @Test func theReviewAccountHasOnlyAnEmailRow() {
        let review = methods(["email"])
        let rows = review.rows(accountEmail: "review@example.com")
        #expect(rows == [SignInMethodRow(method: .email, linked: true, email: "review@example.com")])
        #expect(rows.map(\.canAdd) == [false])
        // 이메일이 다른 방법과 함께 붙어 있어도 Add는 없다 (이메일 계정은 이어 붙이지 않는다)
        let mixed = methods(["email", "apple"], emails: ["apple": "a@x.co"]).rows(accountEmail: "review@example.com")
        #expect(mixed.map(\.method) == [.apple, .email])
        #expect(mixed.allSatisfy { $0.linked })
    }

    // MARK: 이메일 로그인을 연 뒤의 줄 (OA 이메일 로그인 계약 5.8, 게이트 `emailSignIn: true`)

    func reviewMethods() -> SignInMethods {
        SignInMethods(user: user(id: id, providers: ["email"], appMetadata: ["review_account": .bool(true)]))
    }

    /// Apple · Google로 만든 계정의 주소가 실제 주소면 그 주소로 코드 로그인이 되니 Email 줄이 이어져 있다 (버튼 없음)
    @Test func aGoogleAccountWithARealAddressAlsoShowsAnEmailRow() {
        let rows = methods(["google"], emails: ["google": "me@gmail.com"]).rows(accountEmail: "me@gmail.com", emailSignIn: true)
        #expect(rows == [
            SignInMethodRow(method: .google, linked: true, email: "me@gmail.com"),
            SignInMethodRow(method: .email, linked: true, email: "me@gmail.com"),
            SignInMethodRow(method: .apple, linked: false, email: nil),
        ])
        #expect(rows.map(\.canAdd) == [false, false, true])
    }

    @Test func anAppleAccountWithARealAddressShowsAnEmailRowBetweenAppleAndTheAdd() {
        let rows = methods(["apple"], emails: ["apple": "me@icloud.com"]).rows(accountEmail: "me@icloud.com", emailSignIn: true)
        #expect(rows.map(\.method) == [.apple, .email, .google])
        #expect(rows.map(\.linked) == [true, true, false])
        #expect(rows[1].email == "me@icloud.com")
    }

    /// "이메일 가리기" 주소(`@privaterelay.appleid.com`)로는 코드를 받기 어렵다: Email 줄을 보이지 않는다
    @Test(arguments: ["relay-x1y2z3@privaterelay.appleid.com", "Relay-X@PrivateRelay.AppleID.com"])
    func aHiddenAppleAddressHasNoEmailRow(_ address: String) {
        let rows = methods(["apple"], emails: ["apple": address]).rows(accountEmail: address, emailSignIn: true)
        #expect(rows.map(\.method) == [.apple, .google])
        #expect(rows.map(\.linked) == [true, false])
    }

    @Test func anAccountWithoutAnAddressHasNoEmailRow() {
        let rows = methods(["apple"]).rows(accountEmail: nil, emailSignIn: true)
        #expect(rows.map(\.method) == [.apple, .google])
        #expect(methods(["google"]).rows(accountEmail: "  ", emailSignIn: true).map(\.method) == [.google, .apple])
    }

    /// 이메일 코드로 만든 계정은 Email 줄이 이어져 있고 Apple · Google은 둘 다 Add다
    @Test func anEmailCodeAccountCanAddAppleAndGoogle() {
        let rows = methods(["email"], emails: ["email": "me@example.com"]).rows(accountEmail: "me@example.com", emailSignIn: true)
        #expect(rows == [
            SignInMethodRow(method: .email, linked: true, email: "me@example.com"),
            SignInMethodRow(method: .apple, linked: false, email: nil),
            SignInMethodRow(method: .google, linked: false, email: nil),
        ])
        #expect(rows.map(\.canAdd) == [false, true, true])
    }

    @Test func anEmailCodeAccountWithGoogleAddedHasOneAddLeft() {
        let rows = methods(["email", "google"], emails: ["google": "other@gmail.com"]).rows(accountEmail: "me@example.com", emailSignIn: true)
        #expect(rows.map(\.method) == [.google, .email, .apple])
        #expect(rows.map(\.linked) == [true, true, false])
        #expect(rows[0].email == "other@gmail.com")
        #expect(rows[1].email == "me@example.com")
    }

    /// 심사 계정(`app_metadata.review_account`)은 이메일을 모두에게 연 뒤에도 Email 줄만 있다: 심사원이 Add를 누르지 않게
    @Test func theReviewAccountKeepsOnlyItsEmailRow() {
        let rows = reviewMethods().rows(accountEmail: "review@example.com", emailSignIn: true)
        #expect(rows == [SignInMethodRow(method: .email, linked: true, email: "review@example.com")])
        #expect(rows.allSatisfy { !$0.canAdd })
    }

    @Test func theReviewMarkerMustBeTheBooleanTrue() {
        func parsed(_ marker: AnyJSON?) -> Bool {
            SignInMethods(user: user(id: id, providers: ["email"], appMetadata: marker.map { ["review_account": $0] } ?? [:])).isReviewAccount
        }
        #expect(parsed(.bool(true)))
        #expect(!parsed(.bool(false)))
        #expect(!parsed(.string("true")))
        #expect(!parsed(.integer(1)))
        #expect(!parsed(nil))
        #expect(!SignInMethods(providers: ["email"], primary: "email").isReviewAccount)
    }

    /// 이메일 로그인이 닫혀 있으면(게이트 NO) 줄은 지금과 같다: 이메일 계정은 Email 줄만, Apple · Google에는 Email 줄이 없다
    @Test func withTheGateClosedTheRowsAreTheOldOnes() {
        #expect(methods(["google"], emails: ["google": "me@gmail.com"]).rows(accountEmail: "me@gmail.com", emailSignIn: false).map(\.method) == [.google, .apple])
        #expect(methods(["email"]).rows(accountEmail: "me@example.com", emailSignIn: false).map(\.method) == [.email])
        #expect(methods(["email"]).rows(accountEmail: "me@example.com") == methods(["email"]).rows(accountEmail: "me@example.com", emailSignIn: false))
    }

    @Test func anUnknownMethodListStillGivesNoRowsWithTheGateOpen() {
        #expect(SignInMethods.unknown.rows(accountEmail: "me@example.com", emailSignIn: true).isEmpty)
    }

    @Test func anUnknownMethodListGivesNoRows() {
        #expect(SignInMethods.unknown.rows(accountEmail: "me@example.com").isEmpty)
    }

    @Test func emailsComeFromTheIdentitiesAndIgnoreBlankOnes() {
        var u = user(id: id, providers: ["apple", "google"])
        u.identities = [identity("apple", email: " relay@privaterelay.appleid.com ", userID: id), identity("google", email: "  ", userID: id)]
        let m = SignInMethods(user: u)
        #expect(m.emails == ["apple": "relay@privaterelay.appleid.com"])
        #expect(m.hasApple && m.hasGoogle)
        #expect(m.rows(accountEmail: "acct@example.com").map(\.email) == ["relay@privaterelay.appleid.com", "acct@example.com"])
    }

    /// 예전 값 만들기(`providers:primary:`)는 그대로고 이메일을 모르는 것과 같다
    @Test func theOldInitializerStillWorks() {
        #expect(SignInMethods(providers: ["google"], primary: "google").emails.isEmpty)
        #expect(SignInMethods(providers: ["google"], primary: "google") == SignInMethods(providers: ["google"], primary: "google", emails: [:]))
    }
}

/// 승인된 문구 (사용자 승인 2026-10-19, handoffs/oa-signin-dz/README.md): 글자 하나하나 고정한다
struct SignInCopyTests {
    @Test func theApprovedWordsAreExactlyTheApprovedOnes() {
        #expect(SignInCopy.title == "Sign in to Taskforce")
        #expect(SignInCopy.appleTitle == "Sign in with Apple")
        #expect(SignInCopy.googleTitle == "Continue with Google")
        #expect(SignInCopy.legalLine == "By continuing you agree to the Terms and Privacy Policy.")
        #expect(SignInCopy.unavailable == "Sign-in is unavailable in this build.")
        #expect(SignInCopy.appleMissingToken == "Apple didn't return a sign-in token. Try again.")
        #expect(SignInCopy.appleFailed == "Couldn't sign in with Apple. Try again.")
        #expect(SignInCopy.appleOpenFailed == "Couldn't open Apple sign-in. Try again.")
        #expect([SignInMethodRow.Method.apple, .google, .email].map(SignInCopy.rowLabel) == ["Apple", "Google", "Email"])
        #expect(SignInCopy.addButton == "Add")
        #expect(SignInCopy.addTheOther == "Add the other one to sign in with either.")
        #expect(SignInCopy.deleteRemovesAccess == "We try to remove Apple, Google, and connected-service access, but it may remain.")
        #expect(SignInCopy.signInBeforeDeleting == "Sign in before deleting your account.")
        #expect(SignInCopy.appleRevokeSkipped == "Account deleted. To remove Sign in with Apple too, go to account.apple.com › Sign-In and Security › Sign in with Apple.")
    }

    /// 이메일 로그인의 승인된 문구 (사용자 승인 2026-10-20, handoffs/oa-email-signin-dz/README.md): 글자 하나하나 고정한다
    @Test func theApprovedEmailWordsAreExactlyTheApprovedOnes() {
        #expect(SignInCopy.emailTitle == "Continue with email")
        #expect(SignInCopy.emailLabel == "Email")
        #expect(SignInCopy.sendCode == "Send code")
        #expect(SignInCopy.back == "Back")
        #expect(SignInCopy.codeLabel == "Code")
        #expect(SignInCopy.signIn == "Sign in")
        #expect(SignInCopy.resendCode == "Resend code")
        #expect(SignInCopy.useDifferentEmail == "Use a different email")
        #expect(SignInCopy.codeSent(to: "a@b.co") == "Code sent to a@b.co")
        #expect(SignInCopy.newCodeSent(to: "a@b.co") == "New code sent to a@b.co")
        #expect(SignInCopy.addressInvalid == "Add the full address, like jordan@example.com.")
        #expect(SignInCopy.addressBlocked == "This address can't be used. Try another one.")
        #expect(SignInCopy.wrongCode == "That code didn't work. Try the latest email.")
        #expect(SignInCopy.couldntContinue == "Couldn't continue. Try again in a few minutes.")
        #expect(SignInCopy.addEither == "Add Apple or Google to sign in with either.")
        #expect(SignInCopy.enterSixDigits == "Enter the 6-digit code")
        #expect(SignInCopy.resendAvailableIn(seconds: 42) == "Available in 42 seconds")
        // 1초 남았을 때는 단수 (승인된 낱말 그대로)
        #expect(SignInCopy.resendAvailableIn(seconds: 1) == "Available in 1 second")
        #expect(SignInCopy.resendAvailableIn(seconds: 2) == "Available in 2 seconds")
        #expect(SignInCopy.resendAvailableIn(seconds: 60) == "Available in 60 seconds")
    }

    /// 버린 문구는 어디에도 없다: 계약 7.2의 "Couldn't send a code…" · "Too many tries…"(합친 한 줄이 대신), 빨강 입력 오류의 옛 글
    @Test func theReplacedEmailWordsAreNotCopy() {
        let all = [
            SignInCopy.emailTitle, SignInCopy.emailLabel, SignInCopy.sendCode, SignInCopy.back, SignInCopy.codeLabel, SignInCopy.signIn,
            SignInCopy.resendCode, SignInCopy.useDifferentEmail, SignInCopy.addressInvalid, SignInCopy.addressBlocked, SignInCopy.wrongCode,
            SignInCopy.couldntContinue, SignInCopy.addEither, SignInCopy.enterSixDigits, SignInCopy.codeSent(to: "a@b.co"), SignInCopy.newCodeSent(to: "a@b.co"),
        ]
        for text in all {
            #expect(!text.contains("Couldn't send a code") && !text.contains("Too many tries") && !text.contains("or resend it"), "\(text)")
            #expect(!text.contains("{"), "\(text)")
        }
    }

    @Test func addMessagesAreOneQuietLineAndNothingOnSuccess() {
        #expect(SignInCopy.addMessage(for: .belongsToAnotherAccount, method: .apple) == "This Apple ID belongs to another Taskforce account.")
        #expect(SignInCopy.addMessage(for: .belongsToAnotherAccount, method: .google) == "This Google account belongs to another Taskforce account.")
        #expect(SignInCopy.addMessage(for: .failed, method: .apple) == "Couldn't add it. Try again.")
        #expect(SignInCopy.addMessage(for: .failed, method: .google) == "Couldn't add it. Try again.")
        #expect(SignInCopy.addMessage(for: .linked, method: .apple) == nil)
    }

    /// 거절된 문구는 어디에도 없다: 하나만 이어졌을 때 틀린 "both" 각주 · 시스템 설명을 붙이는 오류 줄 · 옛 Google 전용 안내
    @Test func theRejectedWordsAreNotCopy() {
        let all = [
            SignInCopy.title, SignInCopy.appleTitle, SignInCopy.googleTitle, SignInCopy.legalLine, SignInCopy.unavailable, SignInCopy.appleMissingToken,
            SignInCopy.appleFailed, SignInCopy.appleOpenFailed, SignInCopy.addButton, SignInCopy.addTheOther, SignInCopy.addFailed,
            SignInCopy.appleBelongsToAnotherAccount, SignInCopy.googleBelongsToAnotherAccount, SignInCopy.deleteRemovesAccess,
            SignInCopy.signInBeforeDeleting, SignInCopy.appleRevokeSkipped,
        ]
        for text in all {
            #expect(!text.contains("both"), "\(text)")
            #expect(!text.contains("Google sign-in only") && !text.contains("Google-only"), "\(text)")
            #expect(!text.contains("{"), "\(text)")
        }
    }
}
