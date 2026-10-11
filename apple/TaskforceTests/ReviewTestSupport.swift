import Auth
import Foundation
import Supabase
import Testing
@testable import Taskforce
@testable import TaskforceKit

// S4 Review 시험 도구: 진짜 `APIClient` · `NowStore` · `SessionStore`를 가짜 네트워크(URLProtocol) 위에서 돌린다.
// 가짜 서버는 v1 서버의 읽은 동작만 흉내 낸다 (`GET /now` · Confirm = `POST …/confirm` · Dismiss = `DELETE …`): 적용되면 확인 요청에서 빠진다.
// 서버 쪽 CAS · 멱등성은 없다 (v1에 없다): 같은 요청을 다시 보내면 다시 적용된다. 실제 서버 · 계정 · AI 호출은 없다.

/// 가짜 서버가 한 번의 쓰기에 하는 일
enum FakeWrite: Sendable, Equatable {
    /// 적용하고 200 `{ action }`
    case apply
    /// 적용하지 않고 `status` + `{ error: { code, message } }` (409 conflict · 404 not_found · 403 …)
    case reject(Int, String)
    /// 서버는 적용했는데 응답이 끊김 (응답 유실)
    case applyThenLose
    /// 서버에 닿기 전에 끊김
    case loseBeforeApply
    /// 적용했는데 200 본문을 읽을 수 없음
    case applyWithGarbage
    /// 적용했는데 500
    case applyThenServerError
}

enum FakeReply: Sendable {
    case http(Int, Data)
    case fail(URLError.Code)
}

actor FakeNowServer {
    struct Item: Sendable {
        let id: UUID
        var title: String
        var activity: Date
        var reasons: [String]
        var isReview: Bool
        var status = "open"
    }

    struct Evidence: Sendable {
        let quote: String
        let sourceTitle: String?
        let url: String?
        let at: Date
    }

    struct WriteRecord: Sendable, Equatable {
        let method: String
        let id: UUID
        let kind: String
    }

    enum NowMode: Sendable, Equatable {
        case ok
        case status(Int)
        case lose
    }

    private(set) var items: [Item]
    private(set) var writes: [WriteRecord] = []
    private(set) var nowRequests = 0
    private var behaviors: [UUID: [FakeWrite]] = [:]
    private var heldWrites: Set<UUID> = []
    private var writeWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var arrivedWrites: [UUID: Int] = [:]
    private var nowMode: NowMode = .ok
    private var holdNow = false
    private var nowWaiters: [CheckedContinuation<Void, Never>] = []
    private var heldNowArrivals = 0
    private var evidence: [UUID: [Evidence]] = [:]
    private var evidenceStatus = 200
    private var evidenceReads: [UUID: Int] = [:]
    /// 근거 읽기(`actionDetail`)마다 그 읽기가 **도착한 때** 정해지는 동작 (없으면 `evidenceStatus`): 도착 순서대로 하나씩 쓴다
    private var evidenceScript: [Int] = []
    private var holdEvidenceReads = false
    private var evidenceWaiters: [CheckedContinuation<Void, Never>] = []
    private var heldEvidenceCount = 0

    init(items: [Item]) { self.items = items }

    // MARK: 시나리오

    func script(_ id: UUID, _ behaviors: FakeWrite...) { self.behaviors[id] = behaviors }
    func hold(_ id: UUID) { heldWrites.insert(id) }

    /// 붙잡힌 쓰기를 보낸다 (그때 정해진 동작대로 적용된다)
    func release(_ id: UUID) {
        heldWrites.remove(id)
        let waiting = writeWaiters.removeValue(forKey: id) ?? []
        waiting.forEach { $0.resume() }
    }

    /// 붙잡힌 쓰기 중 가장 먼저 온 것 하나만 보낸다 (이 할 일은 계속 붙잡아 둔다)
    func releaseNext(_ id: UUID) {
        guard var waiting = writeWaiters[id], !waiting.isEmpty else { return }
        let first = waiting.removeFirst()
        writeWaiters[id] = waiting
        first.resume()
    }

    func arrived(_ id: UUID) -> Int { arrivedWrites[id] ?? 0 }
    func setNow(_ mode: NowMode) { nowMode = mode }
    func holdNowReads() { holdNow = true }
    func pendingNowReads() -> Int { heldNowArrivals }

    func releaseNowReads() {
        holdNow = false
        heldNowArrivals = 0
        let waiting = nowWaiters
        nowWaiters = []
        waiting.forEach { $0.resume() }
    }

    func setEvidence(_ id: UUID, _ lines: [Evidence]) { evidence[id] = lines }

    /// 다음 근거 읽기들의 HTTP 상태를 도착 순서대로 (200이면 그 순간의 근거를 돌려준다. 아니면 그 오류)
    func scriptEvidence(_ statuses: Int...) { evidenceScript = statuses }
    func holdEvidence() { holdEvidenceReads = true }
    func pendingEvidenceReads() -> Int { heldEvidenceCount }

    /// 붙잡힌 근거 읽기 중 가장 먼저 온 것 하나를 보낸다 (그 읽기는 **도착한 때**의 근거 · 상태로 답한다)
    func releaseNextEvidence() {
        guard !evidenceWaiters.isEmpty else { return }
        heldEvidenceCount -= 1
        evidenceWaiters.removeFirst().resume()
    }

    /// 붙잡힌 근거 읽기 중 `index`번째(도착 순서, 0부터)를 보낸다: 나중에 도착한 읽기가 먼저 끝나는 순서를 만든다
    func releaseEvidenceWaiter(_ index: Int) {
        guard evidenceWaiters.indices.contains(index) else { return }
        heldEvidenceCount -= 1
        evidenceWaiters.remove(at: index).resume()
    }

    func releaseAllEvidence() {
        holdEvidenceReads = false
        heldEvidenceCount = 0
        let waiting = evidenceWaiters
        evidenceWaiters = []
        waiting.forEach { $0.resume() }
    }
    func setEvidenceStatus(_ status: Int) { evidenceStatus = status }
    func evidenceReadCount(_ id: UUID) -> Int { evidenceReads[id] ?? 0 }

    /// 다른 기기가 확인 요청을 처리했다 (서버 상태만 바뀐다)
    func otherDeviceResolves(_ id: UUID, confirmed: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if confirmed { items[index].isReview = false } else { items.remove(at: index) }
    }

    /// 서버가 같은 할 일을 다시 확인 요청으로 올렸다 (새 원문이 붙어 다시 불확실해짐)
    func reflag(_ id: UUID, at activity: Date) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isReview = true
        items[index].status = "open"
        items[index].reasons = ["기한 확인"]
        items[index].activity = activity
    }

    func add(_ item: Item) { items.append(item) }
    func bump(_ id: UUID, to activity: Date) { if let index = items.firstIndex(where: { $0.id == id }) { items[index].activity = activity } }
    func removeFromServer(_ id: UUID) { items.removeAll { $0.id == id } }

    func writeCount(_ kind: String? = nil, for id: UUID? = nil) -> Int {
        writes.filter { (kind == nil || $0.kind == kind) && (id == nil || $0.id == id) }.count
    }

    // MARK: 응답

    func respond(method: String, url: URL) async -> FakeReply {
        let path = url.path
        if path == "/api/v1/now" { return await nowReply() }
        if path == "/rest/v1/evidence", (url.query ?? "").lowercased().contains("action_id=eq.") { return await evidenceDetailReply(url: url) }
        if let write = Self.write(method: method, path: path) { return await writeReply(write.id, kind: write.kind, method: method) }
        if path.hasPrefix("/rest/v1/") { return restReply(path: path, url: url) }
        return .http(404, Data("{}".utf8))
    }

    private static func write(method: String, path: String) -> (id: UUID, kind: String)? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[0] == "api", parts[1] == "v1", parts[2] == "actions", let id = UUID(uuidString: parts[3]) else { return nil }
        if parts.count == 5, parts[4] == "confirm", method == "POST" { return (id, "confirm") }
        if parts.count == 4, method == "DELETE" { return (id, "delete") }
        return nil
    }

    private func nowReply() async -> FakeReply {
        nowRequests += 1
        let mode = nowMode
        let body = nowBody()
        if holdNow {
            heldNowArrivals += 1
            await withCheckedContinuation { nowWaiters.append($0) }
        }
        switch mode {
        case .ok: return .http(200, body)
        case .status(let status): return .http(status, Self.error("internal_error"))
        case .lose: return .fail(.networkConnectionLost)
        }
    }

    private func writeReply(_ id: UUID, kind: String, method: String) async -> FakeReply {
        arrivedWrites[id, default: 0] += 1
        if heldWrites.contains(id) {
            await withCheckedContinuation { writeWaiters[id, default: []].append($0) }
        }
        // 서버에 없는 할 일 (지워짐 · 남의 것): 404
        guard items.contains(where: { $0.id == id }) else { return .http(404, Self.error("not_found")) }
        let behavior = behaviors[id]?.isEmpty == false ? behaviors[id]!.removeFirst() : .apply
        switch behavior {
        case .apply:
            apply(id, kind: kind)
            return .http(200, summaryResponse(id))
        case .reject(let status, let code):
            return .http(status, Self.error(code))
        case .applyThenLose:
            apply(id, kind: kind)
            return .fail(.networkConnectionLost)
        case .loseBeforeApply:
            return .fail(.notConnectedToInternet)
        case .applyWithGarbage:
            apply(id, kind: kind)
            return .http(200, Data("not json".utf8))
        case .applyThenServerError:
            apply(id, kind: kind)
            return .http(500, Self.error("internal_error"))
        }
    }

    /// v1 서버: Confirm은 확인 이유를 지우고 열린 할 일로, Dismiss(DELETE)는 취소(dropped). 다시 보내면 다시 적용된다 (멱등성 없음)
    private func apply(_ id: UUID, kind: String) {
        writes.append(WriteRecord(method: kind == "confirm" ? "POST" : "DELETE", id: id, kind: kind))
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if kind == "confirm" {
            items[index].isReview = false
            items[index].reasons = []
        } else {
            items[index].status = "dropped"
            items[index].isReview = false
            items[index].reasons = []
        }
    }

    // MARK: 본문

    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private static func error(_ code: String) -> Data {
        Data("{\"error\":{\"code\":\"\(code)\",\"message\":\"서버 설명\"}}".utf8)
    }

    private func summaryJSON(_ item: Item) -> String {
        let reasons = item.reasons.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {"id":"\(item.id.uuidString.lowercased())","title":"\(item.title)","owner":"me","status":"\(item.status)","due_date":null,"counterpart":null,\
        "needs_confirmation":\(item.isReview),"confirm_reasons":[\(reasons)],"started_at":null,"last_activity_at":"\(Self.iso(item.activity))"}
        """
    }

    private func summaryResponse(_ id: UUID) -> Data {
        guard let item = items.first(where: { $0.id == id }) else { return Self.error("not_found") }
        return Data("{\"action\":\(summaryJSON(item))}".utf8)
    }

    /// v1 `GET /now`: 확인 요청은 `last_activity_at` 오름차순(오래된 것이 앞), 열린 할 일은 그 밖
    private func nowBody() -> Data {
        let reviews = items.filter { $0.isReview && $0.status == "open" }.sorted { $0.activity < $1.activity }
        let open = items.filter { !$0.isReview && $0.status == "open" }
        let openJSON = open.map { item in
            String(summaryJSON(item).dropLast()) + ",\"score\":1,\"reasons\":[],\"days_until_due\":null}"
        }
        return Data("{\"now\":[\(openJSON.joined(separator: ","))],\"confirmations\":[\(reviews.map(summaryJSON).joined(separator: ","))]}".utf8)
    }

    /// `actionDetail`의 근거 읽기: 도착한 때의 근거 · 동작으로 답하고, 붙잡혀 있으면 풀릴 때까지 기다린다
    private func evidenceDetailReply(url: URL) async -> FakeReply {
        let queryText = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&").lowercased()
        let ids = evidence.keys.filter { queryText.contains($0.uuidString.lowercased()) }
        for id in ids { evidenceReads[id, default: 0] += 1 }
        let status = evidenceScript.isEmpty ? evidenceStatus : evidenceScript.removeFirst()
        var rows: [String] = []
        for id in ids {
            for (index, line) in (evidence[id] ?? []).enumerated() {
                rows.append(Self.evidenceRow(id, index, line))
            }
        }
        if holdEvidenceReads {
            heldEvidenceCount += 1
            await withCheckedContinuation { evidenceWaiters.append($0) }
        }
        guard status == 200 else { return .http(status, Self.error(status == 404 ? "not_found" : "internal_error")) }
        return .http(200, Data("[\(rows.joined(separator: ","))]".utf8))
    }

    private static func evidenceRow(_ id: UUID, _ index: Int, _ line: Evidence) -> String {
        """
        {"id":"\(evidenceID(id, index))","action_id":"\(id.uuidString.lowercased())","source_id":"\(sourceID(id, index))",\
        "quote":"\(line.quote)","role":"updated","created_at":"\(iso(line.at))"}
        """
    }

    private func restReply(path: String, url: URL) -> FakeReply {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let queryText = query.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&").lowercased()
        func mentioned(_ id: UUID) -> Bool { queryText.contains(id.uuidString.lowercased()) }
        switch path {
        case "/rest/v1/actions":
            guard let item = items.first(where: { mentioned($0.id) }), queryText.contains("id=eq.") else { return .http(200, Data("[]".utf8)) }
            let record = """
            [{"id":"\(item.id.uuidString.lowercased())","title":"\(item.title)","scope_summary":null,"owner":"me","counterpart":null,"due_date":null,\
            "status":"\(item.status)","needs_confirmation":\(item.isReview),"confirm_reasons":[],"started_at":null,\
            "last_activity_at":"\(Self.iso(item.activity))","created_at":"\(Self.iso(item.activity))"}]
            """
            return .http(200, Data(record.utf8))
        case "/rest/v1/evidence":
            let ids = evidence.keys.filter(mentioned)
            // 근거 읽기(`actionDetail`)만 센다: 구 목록의 출처 아이콘 읽기(`in.(…)`)는 세지 않는다
            if queryText.contains("action_id=eq.") { for id in ids { evidenceReads[id, default: 0] += 1 } }
            guard evidenceStatus == 200 else { return .http(evidenceStatus, Self.error("internal_error")) }
            var rows: [String] = []
            for id in ids {
                for (index, line) in (evidence[id] ?? []).enumerated() {
                    rows.append("""
                    {"id":"\(Self.evidenceID(id, index))","action_id":"\(id.uuidString.lowercased())","source_id":"\(Self.sourceID(id, index))",\
                    "quote":"\(line.quote)","role":"updated","created_at":"\(Self.iso(line.at))"}
                    """)
                }
            }
            return .http(200, Data("[\(rows.joined(separator: ","))]".utf8))
        case "/rest/v1/sources":
            var rows: [String] = []
            for (id, lines) in evidence {
                for (index, line) in lines.enumerated() where queryText.contains(Self.sourceID(id, index)) {
                    let title = line.sourceTitle.map { "\"\($0)\"" } ?? "null"
                    let link = line.url.map { "\"\($0)\"" } ?? "null"
                    rows.append("""
                    {"id":"\(Self.sourceID(id, index))","kind":"email","title":\(title),"occurred_at":"\(Self.iso(line.at))","external_url":\(link),\
                    "created_at":"\(Self.iso(line.at))","processing_status":"done","meeting":null}
                    """)
                }
            }
            return .http(200, Data("[\(rows.joined(separator: ","))]".utf8))
        default:
            return .http(200, Data("[]".utf8))
        }
    }

    private static func evidenceID(_ id: UUID, _ index: Int) -> String { String(format: "e1d00000-0000-4000-8000-%012d", abs(id.hashValue % 1_000_000) * 10 + index) }
    private static func sourceID(_ id: UUID, _ index: Int) -> String { String(format: "50c00000-0000-4000-8000-%012d", abs(id.hashValue % 1_000_000) * 10 + index) }
}

// MARK: URLProtocol

private actor FakeServerRegistry {
    static let shared = FakeServerRegistry()
    private var servers: [String: FakeNowServer] = [:]

    func register(_ server: FakeNowServer, host: String) { servers[host] = server }
    func server(for host: String) -> FakeNowServer? { servers[host] }
}

private final class FakeServerURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".review-test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let method = request.httpMethod ?? "GET"
        let box = Completion(self)
        Task {
            guard let server = await FakeServerRegistry.shared.server(for: host) else {
                box.fail(URLError(.cannotFindHost))
                return
            }
            switch await server.respond(method: method, url: url) {
            case .http(let status, let body):
                let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                box.succeed(response, body: body)
            case .fail(let code):
                box.fail(URLError(code))
            }
        }
    }

    override func stopLoading() {}
}

private final class Completion: @unchecked Sendable {
    private var urlProtocol: FakeServerURLProtocol?

    init(_ urlProtocol: FakeServerURLProtocol) { self.urlProtocol = urlProtocol }

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

// MARK: 계정 · 저장소

final class ReviewAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data

    init(_ session: Session) throws { data = try AuthClient.Configuration.jsonEncoder.encode(session) }

    func set(_ session: Session) throws {
        lock.lock()
        defer { lock.unlock() }
        data = try AuthClient.Configuration.jsonEncoder.encode(session)
    }

    func store(key: String, value: Data) throws { lock.withLock { data = value } }
    func retrieve(key: String) throws -> Data? { lock.withLock { data } }
    func remove(key: String) throws {}
}

func reviewSession(userID: UUID) -> Session {
    let user = User(
        id: userID, appMetadata: [:], userMetadata: [:], aud: "authenticated", email: "\(userID.uuidString)@example.com",
        createdAt: Date(), updatedAt: Date()
    )
    return Session(
        accessToken: "access-\(userID)", tokenType: "bearer", expiresIn: 3_600,
        expiresAt: Date().addingTimeInterval(3_600).timeIntervalSince1970, refreshToken: "refresh-\(userID)", user: user
    )
}

/// 진짜 `NowStore` + `SessionStore` + `AccountScope`(앱 시작 때처럼 먼저 붙음)를 가짜 서버 위에서. 로그아웃 때 `NowStore.reset()`은 앱처럼 `onSignedOut`에서 부른다 (`LauncherModel.sessionChanged`)
@MainActor
final class ReviewHarness {
    static let userID = UUID(uuidString: "00000000-0000-4000-8000-0000000000aa")!
    let server: FakeNowServer
    let store: NowStore
    let session: SessionStore
    let scope: AccountScope
    let services: AppServices
    private let storage: ReviewAuthStorage
    private(set) var currentUser: Session

    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))! }

    /// 확인 요청 `reviews` 개(1…n, 오래된 것이 앞)와 열린 할 일 `open` 개 (101…)
    static func make(reviews: Int = 3, open: Int = 1, signedIn: Bool = true) async throws -> ReviewHarness {
        let base = Date(timeIntervalSince1970: 1_791_000_000)
        var items = (1...max(reviews, 1)).prefix(reviews).map { n in
            FakeNowServer.Item(id: id(n), title: "Review \(n)", activity: base.addingTimeInterval(Double(n) * 60), reasons: ["기한 확인"], isReview: true)
        }
        items += (0..<open).map { n in
            FakeNowServer.Item(id: id(101 + n), title: "Open \(n + 1)", activity: base, reasons: [], isReview: false)
        }
        let server = FakeNowServer(items: items)
        let host = "review-\(UUID().uuidString.lowercased().prefix(8)).review-test"
        await FakeServerRegistry.shared.register(server, host: host)
        let user = reviewSession(userID: userID)
        let storage = try ReviewAuthStorage(user)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeServerURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let config = AppConfig(
            supabaseURL: URL(string: "https://\(host)")!, supabaseKey: "test-key", appGroupID: "group.test.taskforce",
            apiBaseURL: URL(string: "https://\(host)")!
        )
        let supabase = SupabaseClient(
            supabaseURL: config.supabaseURL, supabaseKey: config.supabaseKey,
            options: SupabaseClientOptions(
                auth: .init(storage: storage, autoRefreshToken: false, emitLocalSessionAsInitialSession: true), global: .init(session: urlSession)
            )
        )
        let session = SessionStore(auth: supabase.auth)
        let scope = AccountScope()
        scope.bind(to: session)
        if signedIn { session.apply(event: .signedIn, session: user) }
        let services = AppServices(config: config, supabase: supabase, session: urlSession)
        let store = NowStore(services: services, session: session)
        session.onSignedOut { [weak store] _ in store?.reset() }
        return ReviewHarness(server: server, store: store, session: session, scope: scope, services: services, storage: storage, user: user)
    }

    private init(server: FakeNowServer, store: NowStore, session: SessionStore, scope: AccountScope, services: AppServices, storage: ReviewAuthStorage, user: Session) {
        self.server = server
        self.store = store
        self.session = session
        self.scope = scope
        self.services = services
        self.storage = storage
        currentUser = user
    }

    /// 같은 UUID로 다시 로그인 (로그아웃 → 로그인): `onSignedOut`이 한 번 돈다
    func reloginSameUser() {
        session.apply(event: .signedOut, session: nil)
        session.apply(event: .signedIn, session: currentUser)
    }

    /// 다른 계정으로 로그인
    func switchAccount() throws {
        session.apply(event: .signedOut, session: nil)
        let other = reviewSession(userID: UUID())
        try storage.set(other)
        currentUser = other
        session.apply(event: .signedIn, session: other)
    }

    /// 토큰 갱신(같은 계정, 새 토큰): 계정이 떠난 것이 아니다
    func refreshToken() throws {
        let user = currentUser.user
        let refreshed = Session(
            accessToken: "access-refreshed", tokenType: "bearer", expiresIn: 3_600,
            expiresAt: Date().addingTimeInterval(3_600).timeIntervalSince1970, refreshToken: "refresh-refreshed", user: user
        )
        try storage.set(refreshed)
        currentUser = refreshed
        session.apply(event: .tokenRefreshed, session: refreshed)
    }

    func signOut() { session.apply(event: .signedOut, session: nil) }

    /// 조건이 될 때까지 기다린다 (최대 `seconds`)
    func wait(seconds: Double = 3, _ condition: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<Int(seconds * 200) {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
}
