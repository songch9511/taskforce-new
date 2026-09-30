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
}

@MainActor
private final class LauncherHarness {
    let model: LauncherModel
    let session: SessionStore
    let router: LauncherTestRouter
    let source: SourceRecord
    let otherSession: Session

    private let storage: MutableSessionStorage
    private let urlSession: URLSession

    private init(
        model: LauncherModel,
        session: SessionStore,
        router: LauncherTestRouter,
        source: SourceRecord,
        otherSession: Session,
        storage: MutableSessionStorage,
        urlSession: URLSession
    ) {
        self.model = model
        self.session = session
        self.router = router
        self.source = source
        self.otherSession = otherSession
        self.storage = storage
        self.urlSession = urlSession
    }

    static func make() async throws -> LauncherHarness {
        let sourceID = UUID()
        let firstSession = makeSession(userID: UUID())
        let otherSession = makeSession(userID: UUID())
        let storage = MutableSessionStorage(data: try AuthClient.Configuration.jsonEncoder.encode(firstSession))
        let host = "supabase-\(UUID().uuidString.lowercased()).test"
        let router = LauncherTestRouter(sourceID: sourceID)
        await LauncherTestRouterRegistry.shared.register(router, for: host)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LauncherStubURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let config = AppConfig(
            supabaseURL: URL(string: "https://\(host)")!,
            supabaseKey: "test-key",
            appGroupID: "group.test.taskforce",
            apiBaseURL: URL(string: "https://api.test")!
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

        let source = SourceRecordFixture.make(id: sourceID, rawText: "Private source line")
        return LauncherHarness(
            model: model,
            session: session,
            router: router,
            source: source,
            otherSession: otherSession,
            storage: storage,
            urlSession: urlSession
        )
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
    private var detailResponse: CheckedContinuation<StubResponse, any Error>?

    init(sourceID: UUID) {
        self.sourceID = sourceID
    }

    func response(path: String, query: [String: String]) async throws -> StubResponse {
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
