import Auth
import Foundation
import Supabase
import Testing
@testable import Taskforce
@testable import TaskforceKit

@Suite(.serialized)
@MainActor
struct LauncherModelSessionTests {
    @Test func sourceReadCompletesWhileTheSessionIsUnchanged() async throws {
        let harness = try await LauncherHarness.make()
        await harness.openSource()

        await harness.router.releaseDetail()
        for _ in 0..<100 where harness.model.screen != .pickLines(harness.source, .reportMissing) {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(harness.model.screen == .pickLines(harness.source, .reportMissing))
        #expect(harness.model.sourceText?.raw == "Private source line")
    }

    @Test func accountChangeDiscardsLateSourceDetail() async throws {
        let harness = try await LauncherHarness.make()
        await harness.openSource()

        try harness.signInAsOtherAccount()
        harness.model.sessionChanged()
        #expect(harness.model.screen == .list)
        #expect(harness.model.sourceText == nil)

        // Releasing the held response used to reveal A's raw text in B's launcher.
        await harness.router.releaseDetail()
        try await Task.sleep(for: .milliseconds(100))

        #expect(harness.model.signedInUserID == harness.otherSession.user.id)
        #expect(harness.model.screen == .list)
        #expect(harness.model.sourceText == nil)
    }

    @Test func failedSourceReadDoesNotReplaceSignedOutScreenWithNotice() async throws {
        let harness = try await LauncherHarness.make()
        await harness.openSource()
        #expect(await harness.router.hasPendingDetail())

        harness.session.apply(event: .signedOut, session: nil)
        harness.model.sessionChanged()
        #expect(harness.model.screen == .list)

        // A network error racing with sign-out must not replace the signed-out screen.
        await harness.router.cancelDetail()
        try await Task.sleep(for: .milliseconds(100))

        #expect(harness.model.signedInUserID == nil)
        #expect(harness.model.screen == .list)
        #expect(harness.model.sourceText == nil)
    }

    /// 계정이 바뀌면 `SessionStore.onSignedOut` 한 곳에서 화면 · 선택 · 입력 · 최근 원문 · 근거를 지운다 (`sessionChanged`를 따로 부르지 않아도)
    @Test func accountChangeResetsScreenSelectionAndEvidence() async throws {
        let harness = try await LauncherHarness.make()
        let now = try #require(harness.model.now)
        await harness.router.holdActionDetail()
        let evidenceRead = Task { await now.loadEvidence(harness.actionID) }
        await harness.waitUntil { await harness.router.hasPendingActionDetail() }
        await harness.router.releaseActionDetail()
        _ = await evidenceRead.value
        #expect(now.evidence[harness.actionID] != nil)
        harness.model.run(.command(.reportMissing))
        await harness.waitUntil { harness.model.sourcesLoaded }
        harness.model.text = "Private"
        harness.model.selection = 1
        #expect(harness.model.screen == .pickSource(.reportMissing))

        try harness.signInAsOtherAccount()

        #expect(harness.model.signedInUserID == harness.otherSession.user.id)
        #expect(harness.model.screen == .list)
        #expect(harness.model.selection == 0)
        #expect(harness.model.text.isEmpty)
        #expect(harness.model.recentSources.isEmpty)
        #expect(now.evidence.isEmpty)
    }

    @Test func evidenceLoadingFromOldAccountCannotClearNewAccountRequest() async throws {
        let harness = try await LauncherHarness.make()
        let now = try #require(harness.model.now)
        await harness.router.holdActionDetail()

        let oldRead = Task { await now.loadEvidence(harness.actionID) }
        await harness.waitUntil { await harness.router.pendingActionDetailCount() == 1 }
        #expect(now.evidenceLoading.contains(harness.actionID))

        try harness.signInAsOtherAccount()
        harness.model.sessionChanged()
        #expect(now.evidenceLoading.isEmpty, "Account reset clears the previous account's loading state")

        let newRead = Task { await now.loadEvidence(harness.actionID) }
        await harness.waitUntil { await harness.router.pendingActionDetailCount() == 2 }
        #expect(now.evidenceLoading.contains(harness.actionID))

        await harness.router.releaseFirstActionDetail()
        _ = await oldRead.value
        #expect(now.evidenceLoading.contains(harness.actionID), "A late old-account defer cannot clear the new account's spinner")

        await harness.router.releaseActionDetail()
        _ = await newRead.value
        #expect(!now.evidenceLoading.contains(harness.actionID))
    }

    @Test func accountChangeClearsSavedDisclosure() async throws {
        let harness = try await LauncherHarness.make()
        let now = try #require(harness.model.now)
        now.applySampleState(saved: SavedNow(savedAt: Date(), tasks: [
            .init(title: "Saved Alpha", dueDate: nil, status: .review),
        ]), offlineSince: nil, failedAt: nil)
        let row = try #require(harness.model.items.compactMap { item -> SavedNow.Row? in
            if case .saved(let row) = item { return row }
            return nil
        }.first)
        harness.model.toggleSavedRow(row)
        #expect(harness.model.isSavedRowExpanded(row))

        try harness.signInAsOtherAccount()
        harness.model.sessionChanged()

        #expect(!harness.model.isSavedRowExpanded(row))
    }

    /// 로그아웃 직전에 보낸 `/now` · 근거 읽기가 로그아웃 뒤에 도착해도 화면 · 저장소에 남지 않는다
    @Test func lateNowAndEvidenceAfterSignOutStayHidden() async throws {
        let harness = try await LauncherHarness.make()
        let now = try #require(harness.model.now)
        await harness.router.holdNow()
        await harness.router.holdActionDetail()
        let listRead = Task { await now.load() }
        let evidenceRead = Task { await now.loadEvidence(harness.actionID) }
        await harness.waitUntil { await harness.router.hasPendingNow() }
        await harness.waitUntil { await harness.router.hasPendingActionDetail() }

        harness.session.apply(event: .signedOut, session: nil)
        #expect(harness.model.screen == .list)

        await harness.router.releaseNow()
        await harness.router.releaseActionDetail()
        _ = await listRead.value
        _ = await evidenceRead.value

        #expect(harness.model.signedInUserID == nil)
        #expect(now.response == nil)
        #expect(now.loadError == nil)
        #expect(now.evidence.isEmpty)
        #expect(now.evidenceFailed.isEmpty)
        #expect(!harness.model.items.contains { $0.action != nil })
    }
}

@MainActor
private final class LauncherHarness {
    let model: LauncherModel
    let session: SessionStore
    let router: LauncherTestRouter
    let source: SourceRecord
    let otherSession: Session
    /// 전 계정의 할 일 (`/now` · 근거 읽기 응답)
    let actionID: UUID

    private let storage: MutableSessionStorage
    private let urlSession: URLSession

    private init(
        model: LauncherModel,
        session: SessionStore,
        router: LauncherTestRouter,
        source: SourceRecord,
        otherSession: Session,
        actionID: UUID,
        storage: MutableSessionStorage,
        urlSession: URLSession
    ) {
        self.model = model
        self.session = session
        self.router = router
        self.source = source
        self.otherSession = otherSession
        self.actionID = actionID
        self.storage = storage
        self.urlSession = urlSession
    }

    static func make() async throws -> LauncherHarness {
        let sourceID = UUID()
        let firstSession = makeSession(userID: UUID())
        let otherSession = makeSession(userID: UUID())
        let storage = MutableSessionStorage(data: try AuthClient.Configuration.jsonEncoder.encode(firstSession))
        let host = "supabase-\(UUID().uuidString.lowercased()).test"
        let apiHost = "api-\(UUID().uuidString.lowercased()).test"
        let actionID = UUID()
        let router = LauncherTestRouter(sourceID: sourceID, actionID: actionID)
        await LauncherTestRouterRegistry.shared.register(router, for: host)
        await LauncherTestRouterRegistry.shared.register(router, for: apiHost)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LauncherStubURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let config = AppConfig(
            supabaseURL: URL(string: "https://\(host)")!,
            supabaseKey: "test-key",
            appGroupID: "group.test.taskforce",
            apiBaseURL: URL(string: "https://\(apiHost)")!
        )
        let supabase = SupabaseClient(
            supabaseURL: config.supabaseURL,
            supabaseKey: config.supabaseKey,
            options: SupabaseClientOptions(
                auth: .init(storage: storage, autoRefreshToken: false, emitLocalSessionAsInitialSession: true),
                global: .init(session: urlSession)
            )
        )
        let session = SessionStore(auth: supabase.auth)
        session.apply(event: .signedIn, session: firstSession)
        let services = AppServices(config: config, supabase: supabase, session: urlSession)
        let account = AccountStore(services: services, session: session)
        let model = LauncherModel(session: session, services: services, account: account)
        model.sessionChanged()
        // 첫 목록 읽기(서버 500)가 끝난 뒤 시작한다: 테스트가 붙잡을 `/now`와 섞이지 않게
        for _ in 0..<100 where model.now?.loaded != true {
            try await Task.sleep(for: .milliseconds(10))
        }

        let source = SourceRecordFixture.make(id: sourceID, rawText: "Private source line")
        return LauncherHarness(
            model: model,
            session: session,
            router: router,
            source: source,
            otherSession: otherSession,
            actionID: actionID,
            storage: storage,
            urlSession: urlSession
        )
    }

    func waitUntil(_ condition: @MainActor () async -> Bool) async {
        for _ in 0..<100 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await condition())
    }

    func openSource() async {
        model.run(.command(.reportMissing))
        for _ in 0..<100 where !model.sourcesLoaded {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.sourcesLoaded)
        #expect(model.screen == .pickSource(.reportMissing))
        model.primary()
        for _ in 0..<100 {
            if await router.hasPendingDetail() { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await router.hasPendingDetail())
        #expect(model.screen == .working("Opening…"))
    }

    func signInAsOtherAccount() throws {
        try storage.store(key: "session", value: AuthClient.Configuration.jsonEncoder.encode(otherSession))
        session.apply(event: .signedIn, session: otherSession)
    }
}

private final class MutableSessionStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data

    init(data: Data) {
        self.data = data
    }

    func store(key: String, value: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        data = value
    }

    func retrieve(key: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    func remove(key: String) throws {}
}

private struct StubResponse: Sendable {
    let status: Int
    let body: Data
}

private actor LauncherTestRouter {
    private let sourceID: UUID
    private let actionID: UUID
    private var detailResponse: CheckedContinuation<StubResponse, any Error>?
    private var holdingNow = false
    private var nowResponses: [CheckedContinuation<StubResponse, any Error>] = []
    private var holdingActionDetail = false
    private var actionDetailResponses: [CheckedContinuation<StubResponse, any Error>] = []

    init(sourceID: UUID, actionID: UUID) {
        self.sourceID = sourceID
        self.actionID = actionID
    }

    func response(path: String, query: [String: String]) async throws -> StubResponse {
        if path == "/api/v1/now", holdingNow {
            return try await withCheckedThrowingContinuation { nowResponses.append($0) }
        }
        if path == "/rest/v1/actions", query["id"] != nil, holdingActionDetail {
            return try await withCheckedThrowingContinuation { actionDetailResponses.append($0) }
        }
        if path == "/rest/v1/sources", query["id"] != nil {
            return try await withCheckedThrowingContinuation { continuation in
                detailResponse = continuation
            }
        }
        if path == "/rest/v1/sources" {
            return StubResponse(status: 200, body: SourceSummaryFixture.json(id: sourceID))
        }
        if path.hasPrefix("/api/v1/") {
            return StubResponse(status: 500, body: Data("{}".utf8))
        }
        return StubResponse(status: 200, body: Data("[]".utf8))
    }

    func hasPendingDetail() -> Bool { detailResponse != nil }

    func holdNow() { holdingNow = true }

    func hasPendingNow() -> Bool { !nowResponses.isEmpty }

    /// 전 계정의 할 일 하나가 든 `/now`
    func releaseNow() {
        holdingNow = false
        let body = Data("""
        {"now":[{"id":"\(actionID.uuidString.lowercased())","title":"Private task","owner":"me","status":"open","due_date":null,"counterpart":null,"needs_confirmation":false,"confirm_reasons":[],"started_at":null,"last_activity_at":"2026-09-29T10:00:00Z","score":10,"reasons":[],"days_until_due":null}],"confirmations":[]}
        """.utf8)
        for response in nowResponses { response.resume(returning: StubResponse(status: 200, body: body)) }
        nowResponses = []
    }

    func holdActionDetail() { holdingActionDetail = true }

    func hasPendingActionDetail() -> Bool { !actionDetailResponses.isEmpty }

    func pendingActionDetailCount() -> Int { actionDetailResponses.count }

    func releaseFirstActionDetail() {
        guard !actionDetailResponses.isEmpty else { return }
        let response = actionDetailResponses.removeFirst()
        let body = Data("""
        [{"id":"\(actionID.uuidString.lowercased())","title":"Private task","scope_summary":null,"owner":"me","counterpart":null,"due_date":null,"status":"open","needs_confirmation":false,"confirm_reasons":[],"started_at":null,"last_activity_at":"2026-09-29T10:00:00Z","created_at":"2026-09-29T10:00:00Z"}]
        """.utf8)
        response.resume(returning: StubResponse(status: 200, body: body))
    }

    /// 전 계정의 할 일 행 (근거 · 이력은 빈 목록으로 답한다)
    func releaseActionDetail() {
        holdingActionDetail = false
        let body = Data("""
        [{"id":"\(actionID.uuidString.lowercased())","title":"Private task","scope_summary":null,"owner":"me","counterpart":null,"due_date":null,"status":"open","needs_confirmation":false,"confirm_reasons":[],"started_at":null,"last_activity_at":"2026-09-29T10:00:00Z","created_at":"2026-09-29T10:00:00Z"}]
        """.utf8)
        for response in actionDetailResponses { response.resume(returning: StubResponse(status: 200, body: body)) }
        actionDetailResponses = []
    }

    func releaseDetail() {
        detailResponse?.resume(returning: StubResponse(status: 200, body: SourceRecordFixture.json(id: sourceID, rawText: "Private source line")))
        detailResponse = nil
    }

    func cancelDetail() {
        guard let detailResponse else { return }
        self.detailResponse = nil
        detailResponse.resume(throwing: URLError(.networkConnectionLost))
    }
}

private actor LauncherTestRouterRegistry {
    static let shared = LauncherTestRouterRegistry()
    private var routers: [String: LauncherTestRouter] = [:]

    func register(_ router: LauncherTestRouter, for host: String) {
        routers[host] = router
    }

    func router(for host: String) -> LauncherTestRouter? {
        routers[host]
    }
}

private final class LauncherStubURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".test") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let query = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let path = url.path
        let completion = LauncherURLProtocolCompletion(self)
        Task {
            do {
                guard let router = await LauncherTestRouterRegistry.shared.router(for: host) else {
                    throw URLError(.cannotFindHost)
                }
                let result = try await router.response(path: path, query: query)
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: result.status,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                completion.succeed(response, body: result.body)
            } catch {
                completion.fail(error)
            }
        }
    }

    override func stopLoading() {
        guard
            let url = request.url,
            let host = url.host,
            url.path == "/rest/v1/sources",
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "id" }) == true
        else { return }
        Task {
            await LauncherTestRouterRegistry.shared.router(for: host)?.cancelDetail()
        }
    }
}

// URLProtocolClient is not Sendable, so the task uses this one-shot unchecked box to retain the protocol.
private final class LauncherURLProtocolCompletion: @unchecked Sendable {
    private var urlProtocol: LauncherStubURLProtocol?

    init(_ urlProtocol: LauncherStubURLProtocol) {
        self.urlProtocol = urlProtocol
    }

    func succeed(_ response: URLResponse, body: Data) {
        guard let urlProtocol else { return }
        self.urlProtocol = nil
        urlProtocol.client?.urlProtocol(urlProtocol, didReceive: response, cacheStoragePolicy: .notAllowed)
        urlProtocol.client?.urlProtocol(urlProtocol, didLoad: body)
        urlProtocol.client?.urlProtocolDidFinishLoading(urlProtocol)
    }

    func fail(_ error: Error) {
        guard let urlProtocol else { return }
        self.urlProtocol = nil
        urlProtocol.client?.urlProtocol(urlProtocol, didFailWithError: error)
    }
}

private enum SourceSummaryFixture {
    static func json(id: UUID) -> Data {
        Data("""
        [{"id":"\(id.uuidString)","kind":"note","title":"Private source","occurred_at":"2026-09-29T10:00:00Z","external_url":null,"created_at":"2026-09-29T10:00:00Z","processing_status":"done","meeting":null}]
        """.utf8)
    }
}

private enum SourceRecordFixture {
    static func make(id: UUID, rawText: String) -> SourceRecord {
        let data = json(id: id, rawText: rawText)
        return try! TaskforceJSON.decoder().decode([SourceRecord].self, from: data)[0]
    }

    static func json(id: UUID, rawText: String) -> Data {
        let row: [String: Any] = [
            "id": id.uuidString,
            "kind": "note",
            "title": "Private source",
            "occurred_at": "2026-09-29T10:00:00Z",
            "external_url": NSNull(),
            "created_at": "2026-09-29T10:00:00Z",
            "processing_status": "done",
            "meeting": NSNull(),
            "raw_text": rawText,
        ]
        return try! JSONSerialization.data(withJSONObject: [row])
    }
}

private func makeSession(userID: UUID) -> Session {
    let user = User(
        id: userID,
        appMetadata: [:],
        userMetadata: [:],
        aud: "authenticated",
        email: "\(userID.uuidString)@example.com",
        createdAt: Date(),
        updatedAt: Date()
    )
    let lifetime: TimeInterval = 3600
    return Session(
        accessToken: "access-\(userID)",
        tokenType: "bearer",
        expiresIn: lifetime,
        expiresAt: Date().addingTimeInterval(lifetime).timeIntervalSince1970,
        refreshToken: "refresh-\(userID)",
        user: user
    )
}
