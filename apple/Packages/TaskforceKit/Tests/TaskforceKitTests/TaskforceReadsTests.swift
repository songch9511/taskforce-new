import Auth
import Foundation
import Supabase
import Synchronization
import Testing
@testable import TaskforceKit

/// Supabase 직접 읽기가 보내는 PostgREST 질의
struct TaskforceReadsTests {
    /// 바뀜 점을 본 기록(`user_seen`)은 변경 이력 읽기에서 뺀다 (#79 뒤 운영 `action_events`에 있다)
    @Test func actionDetailSkipsSeenEvents() async throws {
        let host = "reads-\(UUID().uuidString.lowercased()).supabase.test"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PathStubProtocol.self]
        let supabase = SupabaseClient(
            supabaseURL: URL(string: "https://\(host)")!,
            supabaseKey: "test-public-key",
            options: SupabaseClientOptions(
                auth: .init(storage: EmptyAuthStorage(), autoRefreshToken: false),
                global: .init(session: URLSession(configuration: configuration))
            )
        )

        let detail = try await TaskforceReads(supabase: supabase).actionDetail(id: Fixtures.actionID)
        #expect(detail.action.id == Fixtures.actionID)

        let events = try #require(PathStubProtocol.requests(host: host).first { $0.path.hasSuffix("/action_events") })
        let query = Dictionary(grouping: events.query, by: \.name).mapValues { $0.compactMap(\.value) }
        #expect(query["type"] == ["neq.user_seen"])
        #expect(query["action_id"] == ["eq.11111111-1111-4111-8111-111111111111"])
    }
}

/// 실행 읽기 (RLS `execution_*`): 경로 · 필터 · 순서, `stopped_at` 열이 없는 DB면 그 열 없이 다시 읽는다
struct TaskforceReadsExecutionTests {
    let host = "exec-\(UUID().uuidString.lowercased()).supabase.test"

    func reads(withoutStoppedAt: Bool = false) -> TaskforceReads {
        ExecutionStubProtocol.configure(host: host, withoutStoppedAt: withoutStoppedAt)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ExecutionStubProtocol.self]
        let supabase = SupabaseClient(
            supabaseURL: URL(string: "https://\(host)")!,
            supabaseKey: "test-public-key",
            options: SupabaseClientOptions(
                auth: .init(storage: EmptyAuthStorage(), autoRefreshToken: false),
                global: .init(session: URLSession(configuration: configuration))
            )
        )
        return TaskforceReads(supabase: supabase)
    }

    func query(_ recorded: ExecutionStubProtocol.Recorded) -> [String: String] {
        Dictionary(recorded.query.compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { first, _ in first })
    }

    @Test func latestRunsFiltersByActionNewestFirst() async throws {
        let runs = try await reads().latestRuns(actionIDs: [Fixtures.actionID])
        #expect(runs.map(\.id) == [ExecutionFixtures.runID])
        #expect(runs.first?.stoppedAt != nil)
        let request = try #require(ExecutionStubProtocol.requests(host: host).last)
        #expect(request.path == "/rest/v1/execution_runs")
        let q = query(request)
        #expect(q["select"]?.contains("stopped_at") == true)
        #expect(q["action_id"] == "in.(11111111-1111-4111-8111-111111111111)")
        #expect(q["order"]?.hasPrefix("created_at.desc") == true)
    }

    @Test func noActionsNoRequest() async throws {
        #expect(try await reads().latestRuns(actionIDs: []).isEmpty)
        #expect(ExecutionStubProtocol.requests(host: host).isEmpty)
    }

    @Test func activeAndPausedRunFilters() async throws {
        let reads = reads()
        _ = try await reads.activeRuns()
        _ = try await reads.pausedRuns()
        let requests = ExecutionStubProtocol.requests(host: host)
        #expect(requests.count == 2)
        #expect(query(requests[0])["state"] == "in.(queued,running,waiting_approval)")
        #expect(query(requests[0])["hold_reason"] == nil)
        #expect(query(requests[1])["state"] == "in.(queued,running,waiting_approval)")
        #expect(query(requests[1])["hold_reason"] == "eq.credit")
    }

    /// 서버 U2 Mac PR1 마이그레이션 전 DB: `stopped_at`을 고르면 42703 → 그 열 없이 다시 읽는다
    @Test func fallsBackWithoutStoppedAt() async throws {
        let reads = reads(withoutStoppedAt: true)
        let runs = try await reads.activeRuns()
        #expect(runs.map(\.id) == [ExecutionFixtures.runID])
        #expect(runs.first?.stoppedAt == nil)
        // 한 번 알면 이번 실행 동안은 처음부터 그 열 없이 (폴링마다 실패 응답을 받지 않게)
        _ = try await reads.latestRuns(actionIDs: [Fixtures.actionID])
        let selects = ExecutionStubProtocol.requests(host: host).map { query($0)["select"] ?? "" }
        #expect(selects.count == 3)
        #expect(selects[0].contains("stopped_at"))
        #expect(!selects[1].contains("stopped_at"))
        #expect(!selects[2].contains("stopped_at"))
    }

    @Test func stepsAndArtifacts() async throws {
        let reads = reads()
        let steps = try await reads.steps(runID: ExecutionFixtures.runID)
        #expect(steps.map(\.kind) == [.plan])
        let drafts = try await reads.artifacts(actionID: Fixtures.actionID)
        #expect(drafts.map(\.title) == ["일정 변경 회신"])
        let found = try await reads.artifact(id: ExecutionFixtures.artifactID)
        #expect(found?.id == ExecutionFixtures.artifactID)
        let requests = ExecutionStubProtocol.requests(host: host)
        #expect(requests.map(\.path) == ["/rest/v1/execution_steps", "/rest/v1/execution_artifacts", "/rest/v1/execution_artifacts"])
        #expect(query(requests[0])["run_id"] == "eq.55555555-5555-4555-8555-555555555555")
        #expect(query(requests[0])["order"]?.hasPrefix("seq.asc") == true)
        #expect(query(requests[1])["action_id"] == "eq.11111111-1111-4111-8111-111111111111")
        #expect(query(requests[1])["order"]?.hasPrefix("created_at.desc") == true)
        #expect(query(requests[2])["id"] == "eq.77777777-7777-4777-8777-777777777777")
    }

    @Test func missingArtifactIsNil() async throws {
        #expect(try await reads().artifact(id: UUID()) == nil)
    }
}

/// Launcher reads preserve the public Done Today limit while fetching the complete list and provider-only metadata in bounded calls.
struct TaskforceReadsLauncherListTests {
    let host = "launcher-reads-\(UUID().uuidString.lowercased()).supabase.test"
    let reads: TaskforceReads

    init() {
        LauncherListReadStubProtocol.configure(host: host, doneCount: 501)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LauncherListReadStubProtocol.self]
        let supabase = SupabaseClient(
            supabaseURL: URL(string: "https://\(host)")!,
            supabaseKey: "test-public-key",
            options: SupabaseClientOptions(
                auth: .init(storage: EmptyAuthStorage(), autoRefreshToken: false),
                global: .init(session: URLSession(configuration: configuration))
            )
        )
        reads = TaskforceReads(supabase: supabase)
    }

    private func query(_ recorded: LauncherListReadStubProtocol.Recorded) -> [String: String] {
        Dictionary(grouping: recorded.query, by: \.name).mapValues { $0.compactMap(\.value).joined(separator: ",") }
    }

    @Test func allDoneTodayUsesStablePagination() async throws {
        let rows = try await reads.allDoneToday(since: Date(timeIntervalSince1970: 0))
        #expect(rows.count == 501)
        #expect(rows.first?.id != rows.last?.id)

        let requests = LauncherListReadStubProtocol.requests(host: host)
        #expect(requests.map(\.range) == ["0-499", "500-999"])
        #expect(requests.map { query($0)["order"] } == [
            "updated_at.desc.nullslast,id.desc.nullslast", "updated_at.desc.nullslast,id.desc.nullslast"
        ])
    }

    @Test func explicitDoneTodayLimitRemainsSupported() async throws {
        let rows = try await reads.doneToday(since: Date(timeIntervalSince1970: 0), limit: 3)
        #expect(rows.count == 3)
        let request = try #require(LauncherListReadStubProtocol.requests(host: host).first)
        #expect(query(request)["limit"] == "3")
    }

    @Test func sourceServicesReadOnlyReferencesAndProviderMetadata() async throws {
        let action2 = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let result = try await reads.actionSourceServices(actionIDs: [action2, Fixtures.actionID, Fixtures.actionID])

        #expect(result[Fixtures.actionID] == [.notion])
        #expect(result[action2] == [.notion, .slack])
        let requests = LauncherListReadStubProtocol.requests(host: host)
        let evidence = try #require(requests.first { $0.path.hasSuffix("/evidence") })
        let sources = try #require(requests.first { $0.path.hasSuffix("/sources") })
        #expect(query(evidence)["select"] == "id,action_id,source_id,created_at")
        #expect(query(sources)["select"] == "id,kind,external_url")
        #expect(!query(evidence)["select", default: ""].contains("quote"))
        #expect(!query(sources)["select", default: ""].contains("raw_text"))
    }
}

/// 실행 표마다 답하는 가짜 PostgREST. `withoutStoppedAt`이면 `stopped_at`을 고른 run 읽기에 42703(없는 열)으로 답한다
final class ExecutionStubProtocol: URLProtocol {
    struct Recorded: Sendable {
        let path: String
        let query: [URLQueryItem]
    }

    private static let state = Mutex<(recorded: [String: [Recorded]], withoutStoppedAt: Set<String>)>(([:], []))

    static func configure(host: String, withoutStoppedAt: Bool) {
        state.withLock { if withoutStoppedAt { $0.withoutStoppedAt.insert(host) } }
    }

    static func requests(host: String) -> [Recorded] {
        state.withLock { $0.recorded[host] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let host = url.host ?? ""
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let select = items.first { $0.name == "select" }?.value ?? ""
        let missingColumn = Self.state.withLock { state -> Bool in
            state.recorded[host, default: []].append(Recorded(path: url.path, query: items))
            return state.withoutStoppedAt.contains(host)
        }
        var status = 200
        var body = "[]"
        switch url.path {
        case "/rest/v1/execution_runs":
            if missingColumn, select.contains("stopped_at") {
                status = 400
                body = #"{"code":"42703","details":null,"hint":null,"message":"column execution_runs.stopped_at does not exist"}"#
            } else {
                body = "[\(missingColumn ? ExecutionFixtures.heldRun : ExecutionFixtures.stoppedRun)]"
            }
        case "/rest/v1/execution_steps":
            body = "[\(ExecutionFixtures.planStep)]"
        case "/rest/v1/execution_artifacts":
            let id = items.first { $0.name == "id" }?.value
            body = id == nil || id == "eq.\(ExecutionFixtures.artifactID.uuidString.lowercased())" ? "[\(ExecutionFixtures.artifact)]" : "[]"
        default:
            break
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// 경로마다 답하는 가짜 PostgREST: `actions`는 행 하나, 나머지는 빈 목록
private final class PathStubProtocol: URLProtocol {
    struct Recorded: Sendable {
        let path: String
        let query: [URLQueryItem]
    }

    private static let recorded = Mutex<[String: [Recorded]]>([:])

    static func requests(host: String) -> [Recorded] {
        recorded.withLock { $0[host] ?? [] }
    }

    static let actionRow = """
    [{
      "id": "11111111-1111-4111-8111-111111111111", "title": "투자 자료 보내기", "scope_summary": null, "owner": "me",
      "counterpart": null, "due_date": null, "status": "open", "needs_confirmation": false, "confirm_reasons": [],
      "started_at": null, "last_activity_at": "2026-10-03T00:00:00Z", "created_at": "2026-10-01T00:00:00Z"
    }]
    """

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        Self.recorded.withLock {
            $0[url.host ?? "", default: []].append(Recorded(path: url.path, query: components?.queryItems ?? []))
        }
        let body = url.path.hasSuffix("/actions") ? Self.actionRow : "[]"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Small PostgREST stub for launcher provider metadata and paginated Done Today rows.
private final class LauncherListReadStubProtocol: URLProtocol {
    struct Recorded: Sendable {
        let path: String
        let query: [URLQueryItem]
        let range: String?
    }

    private struct HostState {
        var requests: [String: [Recorded]] = [:]
        var doneCount: [String: Int] = [:]
    }

    private static let state = Mutex(HostState())
    private static let action1 = Fixtures.actionID.uuidString.lowercased()
    private static let action2 = "22222222-2222-4222-8222-222222222222"
    private static let notionID = "33333333-3333-4333-8333-333333333333"
    private static let slackID = "44444444-4444-4444-8444-444444444444"
    private static let receiptID = "55555555-5555-4555-8555-555555555555"

    static func configure(host: String, doneCount: Int) {
        state.withLock { $0.doneCount[host] = doneCount }
    }

    static func requests(host: String) -> [Recorded] {
        state.withLock { $0.requests[host] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let host = url.host ?? ""
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let rangeHeader = request.value(forHTTPHeaderField: "Range")
        let rangeBounds = rangeHeader?.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) } ?? []
        let queryOffset = query.first(where: { $0.name == "offset" })?.value.flatMap(Int.init)
        let queryLimit = query.first(where: { $0.name == "limit" })?.value.flatMap(Int.init)
        let range: String?
        if rangeBounds.count == 2 {
            range = "\(rangeBounds[0])-\(rangeBounds[1])"
        } else if let queryOffset, let queryLimit {
            range = "\(queryOffset)-\(queryOffset + queryLimit - 1)"
        } else {
            range = nil
        }
        let total = Self.state.withLock { hostState -> Int in
            hostState.requests[host, default: []].append(Recorded(path: url.path, query: query, range: range))
            return hostState.doneCount[host] ?? 0
        }
        var body = "[]"
        switch url.path {
        case "/rest/v1/actions":
            let bounds = rangeHeader?.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) } ?? []
            let queryOffset = query.first(where: { $0.name == "offset" })?.value.flatMap(Int.init) ?? 0
            let start = bounds.first ?? queryOffset
            let count: Int
            if bounds.count == 2 {
                count = max(0, min(total, bounds[1] + 1) - start)
            } else if let limit = query.first(where: { $0.name == "limit" })?.value.flatMap(Int.init) {
                count = max(0, min(total - start, limit))
            } else {
                count = total
            }
            body = "[" + (start..<start + count).map(Self.doneAction).joined(separator: ",") + "]"
        case "/rest/v1/evidence":
            body = """
            [
              {"id":"66666666-6666-4666-8666-666666666666","action_id":"\(Self.action1)","source_id":"\(Self.notionID)","created_at":"2026-10-01T00:00:00Z"},
              {"id":"77777777-7777-4777-8777-777777777777","action_id":"\(Self.action1)","source_id":"\(Self.receiptID)","created_at":"2026-10-01T00:00:00Z"},
              {"id":"88888888-8888-4888-8888-888888888888","action_id":"\(Self.action2)","source_id":"\(Self.notionID)","created_at":"2026-10-02T00:00:00Z"},
              {"id":"99999999-9999-4999-8999-999999999999","action_id":"\(Self.action2)","source_id":"\(Self.slackID)","created_at":"2026-10-03T00:00:00Z"}
            ]
            """
        case "/rest/v1/sources":
            body = """
            [
              {"id":"\(Self.notionID)","kind":"doc","external_url":"https://www.notion.so/workspace/page"},
              {"id":"\(Self.slackID)","kind":"message","external_url":"https://app.slack.com/archives/channel"},
              {"id":"\(Self.receiptID)","kind":"execution","external_url":null}
            ]
            """
        default:
            break
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func doneAction(_ index: Int) -> String {
        let id = String(format: "00000000-0000-4000-8000-%012d", index + 1)
        return """
        {"id":"\(id)","title":"Done \(index + 1)","owner":"me","status":"done","due_date":null,"counterpart":null,
         "needs_confirmation":false,"confirm_reasons":[],"started_at":null,"last_activity_at":"2026-10-06T10:00:00Z"}
        """
    }
}

/// 로그인 세션 없는 저장소 (anon 키로 읽는다)
private final class EmptyAuthStorage: AuthLocalStorage, Sendable {
    func store(key: String, value: Data) throws {}
    func retrieve(key: String) throws -> Data? { nil }
    func remove(key: String) throws {}
}
