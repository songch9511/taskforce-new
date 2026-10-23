import Auth
import Foundation
import Supabase
import Synchronization
@testable import TaskforceKit

/// 저장된 Claude 데스크톱 대화 시험의 가짜 서버 (D3v-m): Supabase 읽기(`/rest/v1/...`)와 `/api/v2` 지우기를 한 호스트가 같이 받는다.
/// 길(`"METHOD /경로"`)마다 답을 차례로 준다: 하나만 남으면 그 답을 되풀이한다 (409 → 204 같은 순서를 만든다). 모르는 길은 404 `PGRST205`가 아니라 빈 404다.
/// 호스트마다 따로라 시험이 병렬로 돌아도 섞이지 않는다
final class SavedChatsFakeServer: URLProtocol {
    struct Reply: Sendable {
        var status = 200
        var body = "[]"

        static func rows(_ json: String) -> Reply { Reply(status: 200, body: json) }
        static let noContent = Reply(status: 204, body: "")
        static func error(_ status: Int, code: String) -> Reply { Reply(status: status, body: #"{"error":{"code":"\#(code)","message":"x"}}"#) }
        /// PostgREST의 없는 표 오류 (마이그레이션이 아직 없는 DB)
        static let missingTable = Reply(status: 404, body: #"{"code":"PGRST205","details":null,"hint":null,"message":"Could not find the table 'public.claude_app_chats' in the schema cache"}"#)
    }

    struct Recorded: Sendable {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]

        /// 로그에 찍히면 안 되는 값을 시험이 찾을 때: 경로 + 질의 전체
        var line: String { "\(method) \(path)" }
    }

    private struct Host {
        var routes: [String: [Reply]] = [:]
        var recorded: [Recorded] = []
    }

    private static let state = Mutex<[String: Host]>([:])

    static func configure(host: String, routes: [String: [Reply]]) {
        state.withLock { $0[host] = Host(routes: routes) }
    }

    static func requests(host: String) -> [Recorded] {
        state.withLock { $0[host]?.recorded ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let host = url.host ?? ""
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let recorded = Recorded(
            method: request.httpMethod ?? "GET", path: url.path,
            query: Dictionary(items.compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { first, _ in first }),
            headers: request.allHTTPHeaderFields ?? [:]
        )
        let reply = Self.state.withLock { all -> Reply in
            var entry = all[host] ?? Host()
            entry.recorded.append(recorded)
            let key = recorded.line
            var reply = Reply(status: 404, body: "")
            if var queue = entry.routes[key], !queue.isEmpty {
                reply = queue[0]
                if queue.count > 1 { queue.removeFirst() }
                entry.routes[key] = queue
            }
            all[host] = entry
            return reply
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct EmptySavedChatsAuthStorage: AuthLocalStorage {
    func store(key: String, value: Data) throws {}
    func retrieve(key: String) throws -> Data? { nil }
    func remove(key: String) throws {}
}

/// 한 시험이 쓰는 가짜 서버 + 그 서버를 보는 읽기 · API 클라이언트
struct SavedChatsRig {
    let host = "savedchats-\(UUID().uuidString.lowercased()).test"

    init(routes: [String: [SavedChatsFakeServer.Reply]] = [:]) {
        SavedChatsFakeServer.configure(host: host, routes: routes)
    }

    private var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SavedChatsFakeServer.self]
        return URLSession(configuration: configuration)
    }

    var reads: TaskforceReads {
        TaskforceReads(supabase: SupabaseClient(
            supabaseURL: URL(string: "https://\(host)")!, supabaseKey: "test-public-key",
            options: SupabaseClientOptions(auth: .init(storage: EmptySavedChatsAuthStorage(), autoRefreshToken: false), global: .init(session: session))
        ))
    }

    var api: APIClient {
        APIClient(baseURL: URL(string: "https://\(host)")!, session: session, token: { "token-123" })
    }

    var requests: [SavedChatsFakeServer.Recorded] { SavedChatsFakeServer.requests(host: host) }
}

enum SavedChatSamples {
    static let chatA = UUID(uuidString: "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa")!
    static let chatB = UUID(uuidString: "bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb")!
    static let macThis = UUID(uuidString: "11111111-aaaa-4aaa-8aaa-111111111111")!
    static let macOther = UUID(uuidString: "22222222-bbbb-4bbb-8bbb-222222222222")!

    static func record(_ n: Int, title: String? = "Chat", bridge: UUID = macOther, minutesAgo: Double = 0, now: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> SavedChatRecord {
        SavedChatRecord(id: id(n), bridgeID: bridge, title: title, lastMessageAt: now.addingTimeInterval(-minutesAgo * 60))
    }

    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "cccccccc-0000-4000-8000-%012x", n))! }

    static func row(_ n: Int, title: String? = "Chat", device: String? = "Daniel's MacBook Air", minutesAgo: Double = 0) -> SavedChatRow {
        SavedChatRow(id: id(n), title: title, lastMessageAt: Date(timeIntervalSince1970: 1_800_000_000).addingTimeInterval(-minutesAgo * 60), deviceName: device)
    }

    /// 서버가 주는 채팅 한 줄의 JSON (PostgREST: 마이크로초 시각)
    static func chatJSON(_ n: Int, title: String? = "Chat", bridge: UUID = macOther) -> String {
        let titleJSON = title.map { "\"\($0)\"" } ?? "null"
        return #"{"id":"\#(id(n).uuidString.lowercased())","bridge_id":"\#(bridge.uuidString.lowercased())","title":\#(titleJSON),"last_message_at":"2026-10-22T09:41:05.123456+00:00"}"#
    }

    static func messageJSON(_ n: Int, role: String = "user", body: String = "hi", tools: [String] = [], at: String = "2026-10-22T09:41:05+00:00", seq: Int? = nil, truncated: Bool = false) -> String {
        let names = tools.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"id":"\#(UUID(uuidString: String(format: "dddddddd-0000-4000-8000-%012x", n))!.uuidString.lowercased())","role":"\#(role)","body":"\#(body)","truncated":\#(truncated),"tool_names":[\#(names)],"said_at":"\#(at)","seq":\#(seq ?? n)}"#
    }

    static func message(_ n: Int, role: SavedChatMessage.Role = .user, body: String = "hi", tools: [String] = [], at: Date = Date(timeIntervalSince1970: 1_800_000_000), seq: Int64? = nil) -> SavedChatMessage {
        SavedChatMessage(
            id: UUID(uuidString: String(format: "dddddddd-0000-4000-8000-%012x", n))!, role: role, body: body, truncated: false, toolNames: tools, saidAt: at, seq: seq ?? Int64(n)
        )
    }

    static func messageRecord(_ n: Int, role: String = "user", body: String = "hi", tools: [String] = [], at: Date = Date(timeIntervalSince1970: 1_800_000_000), seq: Int64? = nil) -> SavedChatMessageRecord {
        SavedChatMessageRecord(
            id: UUID(uuidString: String(format: "dddddddd-0000-4000-8000-%012x", n))!, role: role, body: body, truncated: false, toolNames: tools, saidAt: at, seq: seq ?? Int64(n)
        )
    }
}
