import AppKit
import AuthenticationServices
import Auth
import Foundation
import Synchronization
import Testing
@testable import Taskforce
@testable import TaskforceKit

// Mac의 Apple 웹 로그인 흐름 · Settings Sign-in의 Add · Sign-in 절 구조 (OA 로그인 계약 5.1 · 5.5 · 11.2).
// 실제 Apple · Google 창 · 실제 Keychain · 실제 Supabase는 0: 브라우저 창과 인증 서버는 모두 가짜다.

private let servicesID = "dev.taskforcelabs.taskforce.signin"
private let returnURL = "https://api.taskforcelabs.dev/api/v1/apple/return"

private func appleConfig() -> AppleWebSignInConfig {
    AppleWebSignInConfig(infoDictionary: ["AppleServicesID": servicesID, "AppleWebReturnURL": returnURL])!
}

private func queryValue(_ name: String, in url: URL) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
}

/// 가짜 브라우저 창: 열린 주소를 기록하고, 정해 둔 대로 돌아온 주소(또는 취소 · 실패)를 준다. `hold`가 있으면 풀 때까지 떠 있다
@MainActor
final class FakeWebAuthenticationRunner: WebAuthenticationRunning {
    var opened: [URL] = []
    var cancels = 0
    /// 열린 주소 → 돌려줄 결과. 기본은 취소
    var reply: (URL) -> WebAuthenticationResult = { _ in .canceled }
    private var held: CheckedContinuation<Void, Never>?
    private var entered = false
    var hold = false

    /// 창이 떠 있는 동안 또 열리면(흐름이 하나만이라는 규칙이 깨짐) 기다리지 않고 기록한 뒤 바로 끝낸다 (시험이 멈추지 않고 빨개지게)
    private(set) var overlapped = false
    private var inFlight = 0

    func run(url: URL, anchor: ASPresentationAnchor) async -> WebAuthenticationResult {
        opened.append(url)
        entered = true
        if inFlight > 0 {
            overlapped = true
            return .canceled
        }
        inFlight += 1
        defer { inFlight -= 1 }
        if hold { await withCheckedContinuation { held = $0 } }
        return reply(url)
    }

    func cancel() {
        cancels += 1
        reply = { _ in .canceled }
        release()
    }

    func release() {
        held?.resume()
        held = nil
    }

    func waitUntilOpen() async {
        for _ in 0..<12_000 where !entered { try? await Task.sleep(for: .milliseconds(5)) }
    }

    /// 열린 주소의 state를 되돌려 싣는 callback
    static func callback(for url: URL, extra: [(String, String)], state: String? = nil) -> URL {
        var parts = URLComponents(string: "taskforce://auth/apple")!
        parts.queryItems = [URLQueryItem(name: "state", value: state ?? queryValue("state", in: url))] + extra.map { URLQueryItem(name: $0.0, value: $0.1) }
        return parts.url!
    }
}

@MainActor
struct AppleSignInFlowTests {
    func makeFlow(_ runner: FakeWebAuthenticationRunner, config: AppleWebSignInConfig? = appleConfig()) -> AppleSignInFlow {
        AppleSignInFlow(config: config, runner: runner)
    }

    let anchor = NSWindow()

    @Test func signInOpensTheAuthorizeURLAndReturnsTheTokenWithItsNonce() async throws {
        let runner = FakeWebAuthenticationRunner()
        runner.reply = { FakeWebAuthenticationRunner.callback(for: $0, extra: [("id_token", "aaa.bbb.ccc"), ("code", "c1")]).asCallback }
        let result = await makeFlow(runner).authorizeSignIn(presenting: anchor)

        guard case .value(let token) = result else { Issue.record("expected a token, got \(result)"); return }
        #expect(token.idToken == "aaa.bbb.ccc")
        let url = try #require(runner.opened.first)
        #expect(url.host == "appleid.apple.com" && url.path == "/auth/authorize")
        #expect(queryValue("client_id", in: url) == servicesID)
        #expect(queryValue("response_type", in: url) == "code id_token")
        #expect(queryValue("response_mode", in: url) == "form_post")
        #expect(queryValue("scope", in: url) == "email")
        // Apple에는 해시를, Supabase에 보낼 값은 그 원본
        #expect(queryValue("nonce", in: url) == token.nonce.hashed)
        #expect(queryValue("nonce", in: url) != token.nonce.raw)
        #expect(runner.opened.count == 1)
    }

    /// 매번 새 state · nonce
    @Test func everyFlowHasItsOwnStateAndNonce() async throws {
        let runner = FakeWebAuthenticationRunner()
        runner.reply = { FakeWebAuthenticationRunner.callback(for: $0, extra: [("id_token", "t")]).asCallback }
        let flow = makeFlow(runner)
        _ = await flow.authorizeSignIn(presenting: anchor)
        _ = await flow.authorizeSignIn(presenting: anchor)
        let states = runner.opened.compactMap { queryValue("state", in: $0) }
        let nonces = runner.opened.compactMap { queryValue("nonce", in: $0) }
        #expect(states.count == 2 && Set(states).count == 2)
        #expect(nonces.count == 2 && Set(nonces).count == 2)
    }

    /// 다른 흐름 · 위조된 주소(state가 다름)는 토큰이 있어도 쓰지 않는다
    @Test func aCallbackWithAnotherStateIsIgnored() async {
        let runner = FakeWebAuthenticationRunner()
        runner.reply = { FakeWebAuthenticationRunner.callback(for: $0, extra: [("id_token", "stolen.id.token")], state: "Zzzzzzzzzzzzzzzz_-9999999999").asCallback }
        let result = await makeFlow(runner).authorizeSignIn(presenting: anchor)
        guard case .canceled = result else { Issue.record("expected canceled, got \(result)"); return }
    }

    @Test func aCanceledWindowIsQuiet() async {
        let runner = FakeWebAuthenticationRunner()
        let signIn = await makeFlow(runner).authorizeSignIn(presenting: anchor)
        guard case .canceled = signIn else { Issue.record("expected canceled"); return }
        runner.reply = { FakeWebAuthenticationRunner.callback(for: $0, extra: [("error", "user_cancelled_authorize")]).asCallback }
        let relayed = await makeFlow(runner).authorizeSignIn(presenting: anchor)
        guard case .canceled = relayed else { Issue.record("expected canceled"); return }
    }

    @Test func failuresAreOneLineMessagesWithoutAnyToken() async {
        let runner = FakeWebAuthenticationRunner()
        let flow = makeFlow(runner)
        func message(_ result: AppleSignInFlow.Authorization<AppleSignInFlow.SignInToken>) -> String? {
            if case .failed(let text) = result { text } else { nil }
        }
        runner.reply = { FakeWebAuthenticationRunner.callback(for: $0, extra: [("code", "c1")]).asCallback }
        #expect(message(await flow.authorizeSignIn(presenting: anchor)) == "Apple didn't return a sign-in token. Try again.")
        runner.reply = { FakeWebAuthenticationRunner.callback(for: $0, extra: [("error", "invalid_request"), ("id_token", "SECRET.TOKEN.X")]).asCallback }
        // Apple이 준 오류 코드는 화면에 싣지 않는다 (고정 한 줄)
        let apple = message(await flow.authorizeSignIn(presenting: anchor))
        #expect(apple == "Couldn't sign in with Apple. Try again.")
        #expect(apple?.contains("SECRET") == false)
        runner.reply = { _ in .failed }
        #expect(message(await flow.authorizeSignIn(presenting: anchor)) == "Couldn't sign in with Apple. Try again.")
        runner.reply = { _ in .couldNotOpen }
        #expect(message(await flow.authorizeSignIn(presenting: anchor)) == "Couldn't open Apple sign-in. Try again.")
    }

    /// 흐름은 하나만: 떠 있는 동안 또 눌러도 새 창을 열지 않는다. 끝나면 다시 열 수 있다
    @Test func onlyOneWindowAtATime() async {
        let runner = FakeWebAuthenticationRunner()
        runner.hold = true
        runner.reply = { FakeWebAuthenticationRunner.callback(for: $0, extra: [("id_token", "t")]).asCallback }
        let flow = makeFlow(runner)
        let first = Task { await flow.authorizeSignIn(presenting: anchor) }
        await runner.waitUntilOpen()
        let second = await flow.authorizeSignIn(presenting: anchor)
        guard case .canceled = second else { Issue.record("a second flow must not start"); return }
        let code = await flow.reauthorizationCode(presenting: anchor)
        #expect(code == nil)
        #expect(runner.opened.count == 1)
        #expect(!runner.overlapped, "떠 있는 동안 두 번째 창을 열지 않는다")
        runner.release()
        guard case .value = await first.value else { Issue.record("the first flow should finish"); return }
        runner.hold = false
        guard case .value = await flow.authorizeSignIn(presenting: anchor) else { Issue.record("a new flow should start"); return }
        #expect(runner.opened.count == 2)
    }

    /// 로그인 화면이 사라지면 떠 있는 창을 닫는다 (다음 로그인이 막히지 않게)
    @Test func forgettingTheRunningFlowClosesTheWindow() async {
        let runner = FakeWebAuthenticationRunner()
        runner.hold = true
        let flow = makeFlow(runner)
        flow.forgetRunningFlow()
        #expect(runner.cancels == 0, "떠 있지 않으면 닫을 것이 없다")
        let pending = Task { await flow.authorizeSignIn(presenting: anchor) }
        await runner.waitUntilOpen()
        flow.forgetRunningFlow()
        #expect(runner.cancels == 1)
        guard case .canceled = await pending.value else { Issue.record("expected canceled"); return }
    }

    @Test func withoutAConfigNothingOpens() async {
        let runner = FakeWebAuthenticationRunner()
        let flow = makeFlow(runner, config: nil)
        guard case .canceled = await flow.authorizeSignIn(presenting: anchor) else { Issue.record("expected canceled"); return }
        #expect(await flow.reauthorizationCode(presenting: anchor) == nil)
        #expect(runner.opened.isEmpty)
    }

    // MARK: 삭제 재확인

    @Test func reauthorizationAsksOnlyForACodeAndReturnsIt() async throws {
        let runner = FakeWebAuthenticationRunner()
        runner.reply = { FakeWebAuthenticationRunner.callback(for: $0, extra: [("code", "c0de.1.2")]).asCallback }
        let code = await makeFlow(runner).reauthorizationCode(presenting: anchor)
        #expect(code == "c0de.1.2")
        let url = try #require(runner.opened.first)
        #expect(queryValue("response_type", in: url) == "code")
        #expect(queryValue("scope", in: url) == nil && queryValue("nonce", in: url) == nil)
        #expect(queryValue("response_mode", in: url) == "form_post")
    }

    @Test func reauthorizationGivesNothingWhenCanceledOrForged() async {
        let runner = FakeWebAuthenticationRunner()
        let flow = makeFlow(runner)
        #expect(await flow.reauthorizationCode(presenting: anchor) == nil)
        runner.reply = { FakeWebAuthenticationRunner.callback(for: $0, extra: [("code", "x")], state: "Zzzzzzzzzzzzzzzz_-9999999999").asCallback }
        #expect(await flow.reauthorizationCode(presenting: anchor) == nil)
        runner.reply = { FakeWebAuthenticationRunner.callback(for: $0, extra: [("error", "user_cancelled_authorize")]).asCallback }
        #expect(await flow.reauthorizationCode(presenting: anchor) == nil)
        runner.reply = { FakeWebAuthenticationRunner.callback(for: $0, extra: [("id_token", "a.b.c")]).asCallback }
        #expect(await flow.reauthorizationCode(presenting: anchor) == nil, "로그인용 토큰은 재확인 code가 아니다")
    }

    // MARK: 로그인 끝까지 (가짜 인증 서버)

    @Test func signInHandsTheTokenAndTheRawNonceToSupabase() async throws {
        let runner = FakeWebAuthenticationRunner()
        runner.reply = { FakeWebAuthenticationRunner.callback(for: $0, extra: [("id_token", "apple.id.token")]).asCallback }
        let auth = FakeSupabase(userID: UUID())
        let session = auth.makeStore()
        let finished = Mutex(false)
        makeFlow(runner).signIn(session: session, presenting: anchor) { finished.withLock { $0 = true } }
        await waitUntil { finished.withLock { $0 } }

        let body = try #require(auth.tokenBodies.first)
        #expect(body["provider"] as? String == "apple")
        #expect(body["id_token"] as? String == "apple.id.token")
        let nonce = try #require(body["nonce"] as? String)
        // 보낸 원본의 해시가 Apple에 간 값이다
        #expect(SignInNonce(raw: nonce).hashed == queryValue("nonce", in: try #require(runner.opened.first)))
        #expect(session.errorMessage == nil)
    }

    @Test func signInReportsAFailureOnTheSignInScreen() async {
        let runner = FakeWebAuthenticationRunner()
        runner.reply = { FakeWebAuthenticationRunner.callback(for: $0, extra: [("error", "access_denied")]).asCallback }
        let session = FakeSupabase(userID: UUID()).makeStore()
        let finished = Mutex(false)
        makeFlow(runner).signIn(session: session, presenting: anchor) { finished.withLock { $0 = true } }
        await waitUntil { finished.withLock { $0 } }
        #expect(session.errorMessage == "Couldn't sign in with Apple. Try again.")
    }

    @Test func aCanceledSignInSaysNothing() async {
        let runner = FakeWebAuthenticationRunner()
        let auth = FakeSupabase(userID: UUID())
        let session = auth.makeStore()
        let finished = Mutex(false)
        makeFlow(runner).signIn(session: session, presenting: anchor) { finished.withLock { $0 = true } }
        await waitUntil { finished.withLock { $0 } }
        #expect(session.errorMessage == nil && session.notice == nil)
        #expect(auth.tokenBodies.isEmpty)
    }
}

private extension URL {
    var asCallback: WebAuthenticationResult { .callback(self) }
}

/// 조건이 참이 될 때까지 기다린다 (고정 대기가 아니다: 부하가 큰 머신에서도 제한 시간 안에 끝나면 통과)
@MainActor
func waitUntil(timeout: Duration = .seconds(60), _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
}

// MARK: 가짜 Supabase 인증 서버

private func fixtureUser(id: UUID, providers: [String], emails: [String: String] = [:], accountEmail: String? = "me@example.com") -> User {
    User(id: id, appMetadata: ["provider": .string(providers.first ?? "email"), "providers": .array(providers.map { .string($0) })], userMetadata: [:],
        aud: "authenticated", email: accountEmail, createdAt: Date(), updatedAt: Date(),
        identities: providers.map {
            UserIdentity(id: "sub-\($0)", identityId: UUID(), userId: id, identityData: emails[$0].map { ["email": .string($0)] } ?? [:],
                provider: $0, createdAt: nil, lastSignInAt: nil, updatedAt: nil)
        })
}

private func fixtureSession(for user: User, token: String = "access") -> Session {
    Session(accessToken: token, tokenType: "bearer", expiresIn: 3600, expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970,
        refreshToken: "refresh-\(token)", user: user)
}

private final class MemoryAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func store(key: String, value: Data) throws { lock.withLock { values[key] = value } }
    func retrieve(key: String) throws -> Data? { lock.withLock { values[key] } }
    func remove(key: String) throws { lock.withLock { _ = values.removeValue(forKey: key) } }
}

/// `/token`에 로그인(또는 이어 붙이기) 응답을, `/user`에 읽기 응답을 주는 가짜 서버. 받은 `/token` 본문을 기록한다
private final class FakeSupabase: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [[String: Any]] = []
    private var headers: [String?] = []
    let userID: UUID
    var tokenStatus = 200
    var tokenErrorCode: String?
    var linkedProviders: [String] = ["apple"]

    init(userID: UUID) { self.userID = userID }

    var tokenBodies: [[String: Any]] { lock.withLock { bodies } }
    var tokenAuthorizations: [String?] { lock.withLock { headers } }

    @MainActor
    func makeStore() -> SessionStore {
        SessionStore(auth: AuthClient(url: URL(string: "https://signin-flow.invalid/auth/v1")!, localStorage: MemoryAuthStorage(),
            fetch: { [self] in try handle($0) }, autoRefreshToken: false))
    }

    func handle(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        var status = 200
        let payload: Data
        switch url.path {
        case "/auth/v1/token":
            lock.withLock {
                bodies.append((try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:])
                headers.append(request.value(forHTTPHeaderField: "Authorization"))
            }
            if let code = tokenErrorCode {
                status = tokenStatus
                payload = Data(#"{"code":"\#(code)","msg":"\#(code)"}"#.utf8)
            } else {
                payload = try AuthClient.Configuration.jsonEncoder.encode(fixtureSession(for: fixtureUser(id: userID, providers: linkedProviders)))
            }
        case "/auth/v1/user":
            payload = try AuthClient.Configuration.jsonEncoder.encode(fixtureUser(id: userID, providers: linkedProviders))
        default:
            payload = Data()
            status = 204
        }
        return (payload, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json", "X-Supabase-Api-Version": "2024-01-01"])!)
    }
}

// MARK: Sign-in 절

@MainActor
struct SignInSectionModelTests {
    let me = UUID()

    func methods(_ providers: [String], emails: [String: String] = [:]) -> SignInMethods {
        SignInMethods(user: fixtureUser(id: me, providers: providers, emails: emails))
    }

    /// 방식을 모르면(세션에 정보가 없음) 예전 한 줄 (계정 줄 이름 · 이메일 · Sign Out)
    @Test func unknownMethodsStayOneRow() {
        let model = SignInSectionModel.make(methods: .unknown, accountEmail: "me@example.com")
        #expect(model.rows.count == 1 && model.rows[0].control == .signOut)
        #expect(model.rows[0].method == nil)
        #expect(model.rows[0].label == "Apple ID")
        #expect(model.rows[0].detail == "me@example.com")
        #expect(model.footnote == AccountCopy.signOutScope)
    }

    /// 이어진 Google이 먼저, 안 이어진 Apple은 Add. 각주는 지금 문장 + 새 문장
    @Test func aGoogleAccountShowsGoogleThenAddApple() {
        let model = SignInSectionModel.make(methods: methods(["google"], emails: ["google": "me@gmail.com"]), accountEmail: "me@example.com")
        #expect(model.rows == [
            .init(method: .google, label: "Google", detail: "me@gmail.com", control: .signOut),
            .init(method: .apple, label: "Apple", detail: nil, control: .add(busy: false)),
        ])
        #expect(model.footnote == "Sign Out applies only to this device. Add the other one to sign in with either.")
    }

    @Test func anAppleAccountShowsAppleThenAddGoogle() {
        let model = SignInSectionModel.make(methods: methods(["apple"], emails: ["apple": "relay-x1y2z3@privaterelay.appleid.com"]), accountEmail: nil)
        #expect(model.rows == [
            .init(method: .apple, label: "Apple", detail: "relay-x1y2z3@privaterelay.appleid.com", control: .signOut),
            .init(method: .google, label: "Google", detail: nil, control: .add(busy: false)),
        ])
        #expect(model.footnote.hasSuffix("Add the other one to sign in with either."))
    }

    @Test func bothLinkedShowTwoRowsAndSignOutOnlyOnTheFirst() {
        let model = SignInSectionModel.make(methods: methods(["google", "apple"], emails: ["google": "g@x.co", "apple": "a@x.co"]), accountEmail: nil)
        #expect(model.rows == [
            .init(method: .apple, label: "Apple", detail: "a@x.co", control: .signOut),
            .init(method: .google, label: "Google", detail: "g@x.co", control: .none),
        ])
        #expect(model.footnote == AccountCopy.signOutScope, "더할 것이 없으면 각주 문장도 없다")
    }

    /// 심사 계정은 Email 줄만이다: Add도 새 각주 문장도 없다
    @Test func theReviewAccountShowsOnlyTheEmailRow() {
        let model = SignInSectionModel.make(methods: methods(["email"]), accountEmail: "review@example.com")
        #expect(model.rows == [.init(method: .email, label: "Email", detail: "review@example.com", control: .signOut)])
        #expect(model.footnote == AccountCopy.signOutScope)
    }

    @Test func busyAndMessagesLandOnTheRowThatIsBeingAdded() {
        let model = SignInSectionModel.make(
            methods: methods(["google"], emails: ["google": "me@gmail.com"]), accountEmail: nil, busy: .apple,
            messages: [.apple: SignInCopy.appleBelongsToAnotherAccount])
        #expect(model.rows[1].control == .add(busy: true))
        #expect(model.rows[1].detail == "This Apple ID belongs to another Taskforce account.")
        #expect(model.rows[0].control == .signOut && model.rows[0].detail == "me@gmail.com")
    }

    /// 줄 이름에 계정 줄의 옛 이름("Apple ID" · "Google Account")이 섞이지 않는다
    @Test func rowLabelsAreTheShortApprovedNames() {
        for providers in [["google"], ["apple"], ["apple", "google"], ["email"]] {
            let model = SignInSectionModel.make(methods: methods(providers), accountEmail: "e")
            for row in model.rows { #expect(["Apple", "Google", "Email"].contains(row.label), "\(row.label)") }
        }
    }
}

@MainActor
struct SignInAddModelTests {
    let me = UUID()

    /// 로그인해 있는 상태의 가짜 서버 + 저장소. Google 계정 하나가 붙어 있다
    fileprivate func signedIn(_ server: FakeSupabase) throws -> (SessionStore, MemoryAuthStorage) {
        let storage = MemoryAuthStorage()
        let current = fixtureSession(for: fixtureUser(id: me, providers: ["google"]))
        try storage.store(key: "supabase.auth.token", value: AuthClient.Configuration.jsonEncoder.encode(current))
        let store = SessionStore(auth: AuthClient(url: URL(string: "https://signin-flow.invalid/auth/v1")!, localStorage: storage,
            fetch: { try server.handle($0) }, autoRefreshToken: false))
        store.apply(event: .signedIn, session: current)
        return (store, storage)
    }

    func model(apple: AppleSignInFlow.Authorization<AppleSignInFlow.SignInToken> = .canceled,
               google: GoogleSignInFlow.Authorization = .unavailable) -> (SignInAddModel, Counter) {
        let model = SignInAddModel()
        let counter = Counter()
        model.authorizeApple = { counter.appleCalls += 1; return apple }
        model.authorizeGoogle = { counter.googleCalls += 1; return google }
        model.discardGoogle = { counter.googleDiscards += 1 }
        return (model, counter)
    }

    @MainActor
    final class Counter {
        var appleCalls = 0
        var googleCalls = 0
        var googleDiscards = 0
    }

    let token = AppleSignInFlow.SignInToken(idToken: "apple.id.token", nonce: SignInNonce(raw: "raw-nonce"))

    @Test func addingAppleLinksItToTheCurrentAccount() async throws {
        let server = FakeSupabase(userID: me)
        server.linkedProviders = ["google", "apple"]
        let (store, _) = try signedIn(server)
        let (model, counter) = model(apple: .value(token))
        await model.add(.apple, session: store)

        #expect(counter.appleCalls == 1)
        let body = try #require(server.tokenBodies.first)
        #expect(body["provider"] as? String == "apple" && body["link_identity"] as? Bool == true)
        #expect(body["nonce"] as? String == "raw-nonce")
        #expect(store.signInMethods.providers == ["google", "apple"])
        #expect(model.busy == nil)
        #expect(model.messages.isEmpty)
    }

    @Test func anIdentityOfAnotherAccountShowsOneQuietLine() async throws {
        let server = FakeSupabase(userID: me)
        server.tokenStatus = 422
        server.tokenErrorCode = "identity_already_exists"
        let (store, _) = try signedIn(server)
        let (model, _) = model(apple: .value(token))
        await model.add(.apple, session: store)
        #expect(model.messages[.apple] == "This Apple ID belongs to another Taskforce account.")
        #expect(model.busy == nil)
        #expect(store.signInMethods.providers == ["google"])
    }

    @Test func manualLinkingDisabledAndOtherFailuresShowTheGenericLine() async throws {
        let server = FakeSupabase(userID: me)
        server.tokenStatus = 422
        server.tokenErrorCode = "manual_linking_disabled"
        let (store, _) = try signedIn(server)
        let (model, _) = model(apple: .value(token))
        await model.add(.apple, session: store)
        #expect(model.messages[.apple] == "Couldn't add it. Try again.")
        // 창에서 오류가 와도 같은 줄
        let (failing, _) = self.model(apple: .failed("Couldn't sign in with Apple. x"))
        await failing.add(.apple, session: store)
        #expect(failing.messages[.apple] == "Couldn't add it. Try again.")
    }

    @Test func aCanceledWindowLeavesNoMessageAndNoBusy() async throws {
        let server = FakeSupabase(userID: me)
        let (store, _) = try signedIn(server)
        let (model, counter) = model(apple: .canceled)
        await model.add(.apple, session: store)
        #expect(counter.appleCalls == 1)
        #expect(model.messages.isEmpty && model.busy == nil)
        #expect(server.tokenBodies.isEmpty)
    }

    @Test func googleLinksWithBothTokensAndKeepsTheGoogleSignIn() async throws {
        let server = FakeSupabase(userID: me)
        server.linkedProviders = ["google", "apple"]
        let (store, _) = try signedIn(server)
        let (model, counter) = model(google: .tokens(idToken: "g-id", accessToken: "g-access", nonce: SignInNonce(raw: "g-nonce")))
        await model.add(.google, session: store)
        let body = try #require(server.tokenBodies.first)
        #expect(body["provider"] as? String == "google" && body["access_token"] as? String == "g-access" && body["nonce"] as? String == "g-nonce")
        #expect(counter.googleDiscards == 0)
        #expect(model.messages.isEmpty)
    }

    /// 이어 붙이지 못한 Google 로그인은 이 기기에서 지운다
    @Test func aFailedGoogleLinkSignsTheGoogleSdkOut() async throws {
        let server = FakeSupabase(userID: me)
        server.tokenStatus = 422
        server.tokenErrorCode = "identity_already_exists"
        let (store, _) = try signedIn(server)
        let (model, counter) = model(google: .tokens(idToken: "g-id", accessToken: "g-access", nonce: SignInNonce(raw: "n")))
        await model.add(.google, session: store)
        #expect(model.messages[.google] == "This Google account belongs to another Taskforce account.")
        #expect(counter.googleDiscards == 1)
    }

    /// 흐름이 도는 사이 계정이 바뀌면 그 결과를 버린다: 새 계정의 줄 · 오류에 섞이지 않고 서버에도 쓰지 않는다
    @Test func aFlowThatEndsAfterAnAccountSwitchIsDropped() async throws {
        let server = FakeSupabase(userID: me)
        let (store, storage) = try signedIn(server)
        let hold = Hold()
        let add = SignInAddModel()
        add.authorizeApple = { await hold.wait(); return .value(self.token) }
        let started = Task { await add.add(.apple, session: store) }
        await waitUntil { add.busy == .apple }
        #expect(add.busy == .apple)

        // 기다리는 사이 로그아웃하고 다른 계정으로 로그인한다
        let other = fixtureSession(for: fixtureUser(id: UUID(), providers: ["apple"], accountEmail: "other@example.com"), token: "other")
        store.apply(event: .signedOut, session: nil)
        try storage.store(key: "supabase.auth.token", value: AuthClient.Configuration.jsonEncoder.encode(other))
        store.apply(event: .signedIn, session: other)
        add.follow(userID: other.user.id)
        hold.release()
        await started.value

        #expect(server.tokenBodies.isEmpty, "다른 계정의 토큰으로 쓰지 않았다")
        #expect(add.busy == nil)
        #expect(add.messages.isEmpty)
    }

    @Test func onlyOneAddAtATime() async throws {
        let server = FakeSupabase(userID: me)
        let (store, _) = try signedIn(server)
        let hold = Hold()
        let add = SignInAddModel()
        let calls = Counter()
        add.authorizeApple = { calls.appleCalls += 1; await hold.wait(); return .canceled }
        add.authorizeGoogle = { calls.googleCalls += 1; return .canceled }
        let first = Task { await add.add(.apple, session: store) }
        await waitUntil { add.busy == .apple }
        await add.add(.google, session: store)
        await add.add(.apple, session: store)
        #expect(calls.appleCalls == 1 && calls.googleCalls == 0)
        hold.release()
        await first.value
        #expect(add.busy == nil)
    }

    @Test func emailRowsAndSignedOutNeverStartAFlow() async throws {
        let server = FakeSupabase(userID: me)
        let (store, _) = try signedIn(server)
        let (model, counter) = model(apple: .value(token))
        await model.add(.email, session: store)
        store.apply(event: .signedOut, session: nil)
        await model.add(.apple, session: store)
        #expect(counter.appleCalls == 0 && counter.googleCalls == 0)
        #expect(server.tokenBodies.isEmpty)
    }

    @Test func followingAnotherAccountClearsTheRowState() {
        let model = SignInAddModel()
        model.follow(userID: me)
        model.debugForce(busy: .apple, messages: [.apple: "x"])
        model.follow(userID: me)
        #expect(model.busy == .apple, "같은 계정이면 그대로")
        model.follow(userID: UUID())
        #expect(model.busy == nil && model.messages.isEmpty)
    }
}

/// 한 번 푸는 문 (흐름을 붙들어 둔다)
@MainActor
final class Hold {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

// MARK: 결과 코드 로그 (OA 로그인 계약 9장)

/// 로그인 · 이어 붙이기 · 재확인은 **결과 코드만** 남긴다: 이메일 · 토큰 · code · nonce · state는 로그에 한 글자도 없다.
/// `SignInLog.sink`는 전역이라 이 묶음 안에서는 한 번에 하나씩 돈다 (다른 묶음이 같은 때 남기는 줄도 함께 받지만, 아래 확인은 그것까지 견딘다)
@MainActor
@Suite(.serialized)
struct SignInLogTests {
    @MainActor
    final class Lines {
        var all: [String] = []
    }

    func capture(_ body: () async -> Void) async -> [String] {
        let lines = Lines()
        let previous = SignInLog.sink
        SignInLog.sink = { lines.all.append($0) }
        defer { SignInLog.sink = previous }
        await body()
        return lines.all
    }

    let anchor = NSWindow()
    let secrets = ["SECRET.ID.TOKEN", "c0de-SECRET-code", "gildong@example.com", "NONCE-SECRET", "STATE-SECRET-value-123456"]

    func makeFlow(_ runner: FakeWebAuthenticationRunner) -> AppleSignInFlow {
        AppleSignInFlow(config: appleConfig(), runner: runner)
    }

    @Test func appleWebStepsLogOnlyTheirResultCodes() async {
        let runner = FakeWebAuthenticationRunner()
        let flow = makeFlow(runner)
        let lines = await capture {
            // ok (비밀 값이 든 callback)
            runner.reply = { FakeWebAuthenticationRunner.callback(for: $0, extra: [("id_token", "SECRET.ID.TOKEN"), ("code", "c0de-SECRET-code"), ("user", "gildong@example.com")]).asCallback }
            _ = await flow.authorizeSignIn(presenting: anchor)
            // 취소
            runner.reply = { _ in .canceled }
            _ = await flow.authorizeSignIn(presenting: anchor)
            // Apple 오류 (+ 같이 온 토큰)
            runner.reply = { FakeWebAuthenticationRunner.callback(for: $0, extra: [("error", "access_denied"), ("id_token", "SECRET.ID.TOKEN")]).asCallback }
            _ = await flow.authorizeSignIn(presenting: anchor)
            // 토큰 없음
            runner.reply = { FakeWebAuthenticationRunner.callback(for: $0, extra: [("code", "c0de-SECRET-code")]).asCallback }
            _ = await flow.authorizeSignIn(presenting: anchor)
            // 다른 흐름의 state
            runner.reply = { FakeWebAuthenticationRunner.callback(for: $0, extra: [("id_token", "SECRET.ID.TOKEN")], state: "STATE-SECRET-value-123456").asCallback }
            _ = await flow.authorizeSignIn(presenting: anchor)
            // 창 오류
            runner.reply = { _ in .failed }
            // 창을 열지 못함
            runner.reply = { _ in .couldNotOpen }
            _ = await flow.authorizeSignIn(presenting: anchor)
            runner.reply = { _ in .failed }
            _ = await flow.authorizeSignIn(presenting: anchor)
            // 이어 붙이기의 웹 단계 · 재확인
            runner.reply = { FakeWebAuthenticationRunner.callback(for: $0, extra: [("id_token", "SECRET.ID.TOKEN")]).asCallback }
            _ = await flow.authorizeSignIn(presenting: anchor, step: .link)
            runner.reply = { FakeWebAuthenticationRunner.callback(for: $0, extra: [("code", "c0de-SECRET-code")]).asCallback }
            _ = await flow.reauthorizationCode(presenting: anchor)
        }
        for expected in [
            "apple signin ok", "apple signin canceled", "apple signin failed:access_denied", "apple signin failed:missing_token",
            "apple signin failed:not_ours", "apple signin failed:session_error", "apple signin failed:open_failed", "apple link ok", "apple reauth ok",
        ] {
            #expect(lines.contains(expected), "\(expected)")
        }
        for line in lines {
            for secret in secrets { #expect(!line.contains(secret), "\(line)") }
            #expect(!line.contains("@") && !line.contains("="), "\(line)")
        }
    }

    @Test func linkResultsLogOnlyTheirCodes() async throws {
        let me = UUID()
        func run(status: Int, code: String?, linked: [String]) async throws -> [String] {
            let server = FakeSupabase(userID: me)
            if let code { server.tokenStatus = status; server.tokenErrorCode = code }
            server.linkedProviders = linked
            let storage = MemoryAuthStorage()
            let current = fixtureSession(for: fixtureUser(id: me, providers: ["google"]))
            try storage.store(key: "supabase.auth.token", value: AuthClient.Configuration.jsonEncoder.encode(current))
            let store = SessionStore(auth: AuthClient(url: URL(string: "https://signin-flow.invalid/auth/v1")!, localStorage: storage,
                fetch: { try server.handle($0) }, autoRefreshToken: false))
            store.apply(event: .signedIn, session: current)
            let add = SignInAddModel()
            add.authorizeApple = { .value(.init(idToken: "SECRET.ID.TOKEN", nonce: SignInNonce(raw: "NONCE-SECRET"))) }
            add.authorizeGoogle = { .tokens(idToken: "SECRET.ID.TOKEN", accessToken: "c0de-SECRET-code", nonce: SignInNonce(raw: "NONCE-SECRET")) }
            add.discardGoogle = {}
            return await capture {
                await add.add(.apple, session: store)
                await add.add(.google, session: store)
            }
        }
        let ok = try await run(status: 200, code: nil, linked: ["google", "apple"])
        #expect(ok.contains("apple link ok"))
        let another = try await run(status: 422, code: "identity_already_exists", linked: ["google"])
        #expect(another.contains("apple link failed:belongs_to_another_account") && another.contains("google link failed:belongs_to_another_account"))
        let generic = try await run(status: 422, code: "manual_linking_disabled", linked: ["google"])
        #expect(generic.contains("apple link failed:link"))
        for line in ok + another + generic {
            for secret in secrets { #expect(!line.contains(secret), "\(line)") }
        }
    }

    @Test func aResultCodeNeverCarriesAnythingButSafeCharacters() {
        for dirty in ["a@b.com token=XYZ", "한글", "", "x y", String(repeating: "e", count: 300), "ok;rm -rf"] {
            let text = SignInLog.Result.failed(dirty).text
            #expect(text.hasPrefix("failed:"))
            let code = String(text.dropFirst("failed:".count))
            #expect(!code.isEmpty && code.count <= 60)
            #expect(code.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_-.".contains($0)) }, "\(text)")
        }
        #expect(SignInLog.Result.failed("한글").text == "failed:unknown")
        #expect(SignInLog.Result.ok.text == "ok" && SignInLog.Result.canceled.text == "canceled")
    }

    /// 로그인 · 로그 소스에는 console 출력 · print가 없다 (시스템 로그의 공개 표시는 결과 코드 한 곳뿐이다)
    @Test func theSignInFilesNeverPrint() throws {
        let apple = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for file in ["Taskforce/Shared/AppleSignIn.swift", "Taskforce/Shared/GoogleSignIn.swift", "Taskforce/Shared/AccountDeletion.swift",
                     "Packages/TaskforceKit/Sources/TaskforceKit/AppleWebAuthorization.swift", "Packages/TaskforceKit/Sources/TaskforceKit/SessionStore.swift"] {
            let text = try String(contentsOf: apple.appending(path: file), encoding: .utf8)
            for banned in ["print(", "NSLog(", "debugPrint(", "dump(", "os_log(", "Logger("] {
                #expect(!text.contains(banned), "\(banned) in \(file)")
            }
        }
        let signIn = try String(contentsOf: apple.appending(path: "Taskforce/Shared/SignIn.swift"), encoding: .utf8)
        #expect(signIn.components(separatedBy: "privacy: .public").count == 2, "공개 표시는 결과 코드 한 곳뿐")
    }
}
