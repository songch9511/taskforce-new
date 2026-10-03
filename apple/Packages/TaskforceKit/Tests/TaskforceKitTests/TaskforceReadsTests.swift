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

/// 로그인 세션 없는 저장소 (anon 키로 읽는다)
private final class EmptyAuthStorage: AuthLocalStorage, Sendable {
    func store(key: String, value: Data) throws {}
    func retrieve(key: String) throws -> Data? { nil }
    func remove(key: String) throws {}
}
