import AppKit
import Auth
import Foundation
import Supabase
import Testing
@testable import Taskforce
@testable import TaskforceKit

/// Provider metadata is optional; account changes and stale responses must not restore an old account's icons.
@Suite(.serialized)
@MainActor
struct NowStoreSourceMetadataTests {
    @Test func successCachesProviderServicesForRows() async throws {
        let harness = try await MetadataHarness.make()
        await harness.store.load()
        await harness.waitUntil { harness.store.sourceServicesByAction[harness.actionID] == [.notion] }

        #expect(harness.store.response != nil)
        #expect(!harness.store.sourceServicesFailed)
    }

    @Test func failureKeepsTasksAndRetryCanRecover() async throws {
        let harness = try await MetadataHarness.make(sourceStatus: 500)
        await harness.store.load()
        await harness.waitUntil { harness.store.sourceServicesFailed }

        #expect(harness.store.response != nil)
        #expect(harness.store.sourceServicesByAction.isEmpty)

        await harness.router.setSourceStatus(200)
        await harness.store.load()
        await harness.waitUntil { harness.store.sourceServicesByAction[harness.actionID] == [.notion] }
        #expect(!harness.store.sourceServicesFailed)
    }

    @Test func resetClearsCachedServicesAndFailureState() async throws {
        let harness = try await MetadataHarness.make()
        await harness.store.load()
        await harness.waitUntil { harness.store.sourceServicesByAction[harness.actionID] == [.notion] }

        harness.store.reset()

        #expect(harness.store.sourceServicesByAction.isEmpty)
        #expect(!harness.store.sourceServicesFailed)
        #expect(harness.store.response == nil)
    }

    @Test func lateMetadataResponseCannotRepopulateAfterAccountSwitch() async throws {
        let harness = try await MetadataHarness.make()
        await harness.router.holdSourceReads()
        await harness.store.load()
        await harness.waitUntil { await harness.router.pendingSourceReads() > 0 }

        harness.session.apply(event: .signedIn, session: metadataSession(userID: UUID()))
        harness.store.reset()
        await harness.router.releaseSourceReads()
        try await Task.sleep(for: .milliseconds(80))

        #expect(harness.store.sourceServicesByAction.isEmpty)
        #expect(!harness.store.sourceServicesFailed)
        #expect(harness.store.response == nil)
    }
}

@MainActor
private final class MetadataHarness {
    let store: NowStore
    let session: SessionStore
    let router: MetadataRouter
    let actionID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let storage: MetadataSessionStorage
    private let urlSession: URLSession

    private init(store: NowStore, session: SessionStore, router: MetadataRouter, storage: MetadataSessionStorage, urlSession: URLSession) {
        self.store = store
        self.session = session
        self.router = router
        self.storage = storage
        self.urlSession = urlSession
    }

    static func make(sourceStatus: Int = 200) async throws -> MetadataHarness {
        let user = metadataSession(userID: UUID())
        let storage = MetadataSessionStorage(data: try AuthClient.Configuration.jsonEncoder.encode(user))
        let host = "source-meta-\(UUID().uuidString.lowercased()).test"
        let apiHost = "source-meta-api-\(UUID().uuidString.lowercased()).test"
        let router = MetadataRouter(sourceStatus: sourceStatus)
        await MetadataRouterRegistry.shared.register(router, hosts: [host, apiHost])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetadataURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let config = AppConfig(
            supabaseURL: URL(string: "https://\(host)")!, supabaseKey: "test-key", appGroupID: "group.test.taskforce",
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
        session.apply(event: .signedIn, session: user)
        let services = AppServices(config: config, supabase: supabase, session: urlSession)
        let store = NowStore(services: services, session: session)
        return MetadataHarness(store: store, session: session, router: router, storage: storage, urlSession: urlSession)
    }

    func waitUntil(seconds: Double = 2, _ condition: @MainActor () async -> Bool) async {
        for _ in 0..<Int(seconds * 100) {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await condition())
    }
}

private actor MetadataRouter {
    private let nowBody = Data("""
    {"now":[{"id":"11111111-1111-4111-8111-111111111111","title":"Task","owner":"me","status":"open",
     "due_date":null,"counterpart":null,"needs_confirmation":false,"confirm_reasons":[],"started_at":null,
     "last_activity_at":"2026-10-06T10:00:00Z","score":1,"reasons":[],"days_until_due":null}],"confirmations":[]}
    """.utf8)
    private let sourceBody = Data("""
    [{"id":"33333333-3333-4333-8333-333333333333","kind":"doc","external_url":"https://www.notion.so/workspace/page"}]
    """.utf8)
    private var sourceStatus: Int
    private var holdSources = false
    private var heldSources: [CheckedContinuation<MetadataReply, Never>] = []

    init(sourceStatus: Int) { self.sourceStatus = sourceStatus }

    func setSourceStatus(_ status: Int) { sourceStatus = status }
    func holdSourceReads() { holdSources = true }
    func pendingSourceReads() -> Int { heldSources.count }

    func releaseSourceReads() {
        holdSources = false
        let reply = sourceReply()
        heldSources.forEach { $0.resume(returning: reply) }
        heldSources = []
    }

    func response(method: String, path: String) async -> MetadataReply {
        switch path {
        case "/api/v1/now": return MetadataReply(status: 200, body: nowBody)
        case "/rest/v1/actions": return MetadataReply(status: 200, body: Data("[]".utf8))
        case "/rest/v1/evidence":
            return MetadataReply(status: 200, body: Data("""
            [{"id":"66666666-6666-4666-8666-666666666666","action_id":"11111111-1111-4111-8111-111111111111",
             "source_id":"33333333-3333-4333-8333-333333333333","created_at":"2026-10-06T10:00:00Z"}]
            """.utf8))
        case "/rest/v1/sources":
            if holdSources { return await withCheckedContinuation { heldSources.append($0) } }
            return sourceReply()
        default: return MetadataReply(status: 404, body: Data("{}".utf8))
        }
    }

    private func sourceReply() -> MetadataReply { MetadataReply(status: sourceStatus, body: sourceBody) }
}

private struct MetadataReply: Sendable {
    let status: Int
    let body: Data
}

private actor MetadataRouterRegistry {
    static let shared = MetadataRouterRegistry()
    private var routers: [String: MetadataRouter] = [:]

    func register(_ router: MetadataRouter, hosts: [String]) {
        for host in hosts { routers[host] = router }
    }

    func router(for host: String) -> MetadataRouter? { routers[host] }
}

private final class MetadataURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let method = request.httpMethod ?? "GET"
        let path = url.path
        let box = MetadataCompletion(self)
        Task {
            guard let router = await MetadataRouterRegistry.shared.router(for: host) else {
                box.fail(URLError(.cannotFindHost))
                return
            }
            let reply = await router.response(method: method, path: path)
            let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            box.succeed(response, body: reply.body)
        }
    }

    override func stopLoading() {}
}

private final class MetadataCompletion: @unchecked Sendable {
    private var urlProtocol: MetadataURLProtocol?

    init(_ urlProtocol: MetadataURLProtocol) { self.urlProtocol = urlProtocol }

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

private final class MetadataSessionStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data

    init(data: Data) { self.data = data }

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

private func metadataSession(userID: UUID) -> Session {
    let user = User(
        id: userID, appMetadata: [:], userMetadata: [:], aud: "authenticated", email: "\(userID.uuidString)@example.com",
        createdAt: Date(), updatedAt: Date()
    )
    return Session(
        accessToken: "access-\(userID)", tokenType: "bearer", expiresIn: 3_600,
        expiresAt: Date().addingTimeInterval(3_600).timeIntervalSince1970, refreshToken: "refresh-\(userID)", user: user
    )
}
