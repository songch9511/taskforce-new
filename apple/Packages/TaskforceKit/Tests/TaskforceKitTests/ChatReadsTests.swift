import Auth
import Foundation
import Supabase
import Synchronization
import Testing
@testable import TaskforceKit

/// 대화 · 기억 읽기가 보내는 PostgREST 질의 (RLS 본인 행): 경로 · 필터 · 순서 · 열
struct ChatReadsTests {
    let host = "chat-\(UUID().uuidString.lowercased()).supabase.test"

    func reads(rows: [String: String] = [:]) -> TaskforceReads {
        ChatReadStub.configure(host: host, rows: rows)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatReadStub.self]
        let supabase = SupabaseClient(
            supabaseURL: URL(string: "https://\(host)")!, supabaseKey: "test-public-key",
            options: SupabaseClientOptions(
                auth: .init(storage: ChatEmptyAuthStorage(), autoRefreshToken: false),
                global: .init(session: URLSession(configuration: configuration))
            )
        )
        return TaskforceReads(supabase: supabase)
    }

    func query(_ recorded: ChatReadStub.Recorded) -> [String: String] {
        Dictionary(recorded.query.compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { first, _ in first })
    }

    var requests: [ChatReadStub.Recorded] { ChatReadStub.requests(host: host) }

    /// 지금 기억 = 정정되지 않았고(superseded_at) 잊지 않은(revoked_at) 행. `superseded_by`로 판단하지 않는다
    @Test func currentMemoryUsesTheSameConditionAsTheIndex() async throws {
        _ = try await reads().currentMemoryItems()
        let request = try #require(requests.last)
        #expect(request.path == "/rest/v1/memory_items")
        let q = query(request)
        #expect(q["superseded_at"] == "is.null" && q["revoked_at"] == "is.null")
        #expect(q["superseded_by"] == nil)
        #expect(q["order"]?.hasPrefix("observed_at.desc") == true)
        #expect(q["select"]?.contains("version") == true && q["select"]?.contains("source_purged") == true)
    }

    @Test func memoryByIDReadsReplacedAndForgottenRowsToo() async throws {
        let ids = [ChatContractFixtures.id(1), ChatContractFixtures.id(2)]
        _ = try await reads().memoryItems(ids: ids)
        let q = query(try #require(requests.last))
        #expect(q["id"]?.hasPrefix("in.(") == true)
        #expect(q["superseded_at"] == nil && q["revoked_at"] == nil, "정정 · 잊음 행도 읽는다: 옛 답의 refs가 가리킨다")
        // 빈 목록은 요청하지 않는다
        let source = reads()
        let before = requests.count
        _ = try await source.memoryItems(ids: [])
        #expect(requests.count == before)
    }

    @Test func conversationsReadTouchedAndUntouchedNotArchived() async throws {
        _ = try await reads().conversations()
        let all = requests.filter { $0.path == "/rest/v1/conversations" }
        #expect(all.count == 2)
        let touched = try #require(all.first(where: { query($0)["last_message_at"] == "not.is.null" }))
        let untouched = try #require(all.first(where: { query($0)["last_message_at"] == "is.null" }))
        for request in all { #expect(query(request)["archived_at"] == "is.null") }
        #expect(query(touched)["order"]?.hasPrefix("last_message_at.desc") == true)
        #expect(query(untouched)["order"]?.hasPrefix("created_at.desc") == true)
    }

    @Test func threadReadsNewestPagesAndReturnsThemOldestFirst() async throws {
        func row(_ seq: Int) -> String {
            """
            {"id":"aaaa0000-0000-4000-8000-\(String(format: "%012d", seq))","conversation_id":"\(ChatContractFixtures.conversationID.uuidString.lowercased())","seq":\(seq),
             "role":"user","client_message_id":null,"text":"m\(seq)","refs":{},"created_at":"2026-10-10T00:00:00Z","reply_to":null,"content":null}
            """
        }
        let rows = "[\((1...3).reversed().map(row).joined(separator: ","))]"
        let messages = try await reads(rows: ["conversation_messages": rows]).messages(conversationID: ChatContractFixtures.conversationID)
        #expect(messages.map(\.seq) == [1, 2, 3])
        let q = query(try #require(requests.last))
        #expect(q["conversation_id"] == "eq.\(ChatContractFixtures.conversationID.uuidString.lowercased())")
        #expect(q["order"]?.hasPrefix("seq.desc") == true)
    }

    @Test func previewsReadOnlyUserAndAssistantTextForTheListedChats() async throws {
        let ids = [ChatContractFixtures.id(1, prefix: "bcb50000"), ChatContractFixtures.id(2, prefix: "bcb50000")]
        _ = try await reads().lastMessages(conversationIDs: ids)
        let q = query(try #require(requests.last))
        #expect(q["role"] == "in.(user,assistant)")
        #expect(q["select"] == "id,conversation_id,seq,role,text,created_at")
        #expect(q["conversation_id"]?.hasPrefix("in.(") == true)
        #expect(q["order"]?.hasPrefix("created_at.desc") == true)
    }

    @Test func workContextsAreReadByName() async throws {
        let rows = """
        [{"id":"\(ChatContractFixtures.contextID.uuidString.lowercased())","name":"Shape launch","kind":"project","status":"active","context_version":3,"last_activity_at":null},
         {"id":"\(ChatContractFixtures.otherContextID.uuidString.lowercased())","name":"Old","kind":"goal","status":"archived","context_version":1,"last_activity_at":null}]
        """
        let contexts = try await reads(rows: ["work_contexts": rows]).workContexts()
        #expect(contexts.map(\.name) == ["Shape launch", "Old"] && contexts.map(\.isActive) == [true, false])
        #expect(query(try #require(requests.last))["order"]?.hasPrefix("name.asc") == true)
    }
}

/// 경로마다 답하는 가짜 PostgREST: 테이블 이름 → JSON 행들 (없으면 빈 목록)
final class ChatReadStub: URLProtocol {
    struct Recorded: Sendable {
        let path: String
        let query: [URLQueryItem]
    }

    private static let state = Mutex<(rows: [String: [String: String]], requests: [String: [Recorded]])>(([:], [:]))

    static func configure(host: String, rows: [String: String]) {
        state.withLock {
            $0.rows[host] = rows
            $0.requests[host] = []
        }
    }

    static func requests(host: String) -> [Recorded] {
        state.withLock { $0.requests[host] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let table = url.lastPathComponent
        let body = Self.state.withLock { state -> String in
            state.requests[url.host ?? "", default: []].append(Recorded(path: url.path, query: components?.queryItems ?? []))
            return state.rows[url.host ?? ""]?[table] ?? "[]"
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct ChatEmptyAuthStorage: AuthLocalStorage {
    func store(key: String, value: Data) throws {}
    func retrieve(key: String) throws -> Data? { nil }
    func remove(key: String) throws {}
}
