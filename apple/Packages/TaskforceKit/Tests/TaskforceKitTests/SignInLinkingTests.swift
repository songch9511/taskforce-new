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

private func user(id: UUID, providers: [String], emails: [String: String] = [:], accountEmail: String? = "me@example.com", withIdentities: Bool = true) -> User {
    User(id: id, appMetadata: ["provider": .string(providers.first ?? "email"), "providers": .array(providers.map { .string($0) })], userMetadata: [:],
        aud: "authenticated", email: accountEmail, createdAt: Date(), updatedAt: Date(),
        identities: withIdentities ? providers.map { identity($0, email: emails[$0], userID: id) } : nil)
}

private func session(for user: User, token: String = "access") -> Session {
    Session(accessToken: token, tokenType: "bearer", expiresIn: 3600, expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970,
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

    init(link: Reply?, userRead: Reply?, linkGate: Gate? = nil) {
        self.link = link
        self.userRead = userRead
        self.linkGate = linkGate
    }

    var requests: [URLRequest] { lock.withLock { recorded } }
    func requests(path: String) -> [URLRequest] { requests.filter { $0.url?.path == "/auth/v1/\(path)" } }

    func handle(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { recorded.append(request) }
        let url = try #require(request.url)
        let reply: Reply
        switch url.path {
        case "/auth/v1/token":
            await linkGate?.pass()
            guard let link else { throw URLError(.notConnectedToInternet) }
            reply = link
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
            fetch: { try await server.handle($0) }, autoRefreshToken: false))
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

    /// 서버 응답을 기다리는 사이 계정이 바뀌면 그 결과를 쓰지 않는다: 지금 계정의 방법 목록은 그대로고,
    /// supabase-swift가 방금 저장한 떠난 계정의 세션은 이 기기에서 지운다 (떠난 계정이 되살아나지 않게)
    @Test func aLateResponseAfterAnAccountSwitchIsDiscarded() async throws {
        let gate = Gate()
        let linked = user(id: me, providers: ["google", "apple"])
        let (store, server, storage) = try signedInWithGoogle(link: FakeAuthServer.ok(session(for: linked, token: "late")), userRead: FakeAuthServer.ok(linked), gate: gate)
        let pending = Task { await store.linkApple(idToken: "t", nonce: SignInNonce(raw: "n"), expectedUserID: me) }
        #expect(await gate.waitUntilEntered())

        // 응답을 기다리는 사이 로그아웃하고 다른 계정으로 로그인한다
        let other = UUID()
        let otherSession = session(for: user(id: other, providers: ["apple"], accountEmail: "other@example.com"), token: "other")
        store.apply(event: .signedOut, session: nil)
        try storage.save(otherSession)
        store.apply(event: .signedIn, session: otherSession)
        #expect(store.state == .signedIn(userID: other, email: "other@example.com"))
        await gate.release()
        let result = await pending.value

        #expect(result == .failed)
        // 지금(떠난 뒤 들어온) 계정의 방법 목록에 옛 계정의 결과가 섞이지 않는다
        #expect(store.signInMethods.providers != ["google", "apple"])
        #expect(server.requests(path: "user").isEmpty)
        // 떠난 계정의 세션이 이 기기에 남지 않는다
        #expect(server.requests(path: "logout").count >= 1)
        #expect(storage.isEmpty)
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
