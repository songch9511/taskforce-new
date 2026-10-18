import Auth
import Foundation
import Supabase
import Testing
@testable import TaskforceKit

/// Macs 목록의 읽기 (OA Settings › Your agents 6.4): `bridges`를 RLS로 읽는다. 열 · 필터 · 모양. 쓰기는 없다
struct AgentSettingsReadsTests {
    private let host = "agentmacs-\(UUID().uuidString.lowercased()).supabase.test"

    private func reads(rows: [String: String]) -> TaskforceReads {
        ChatReadStub.configure(host: host, rows: rows)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatReadStub.self]
        let supabase = SupabaseClient(
            supabaseURL: URL(string: "https://\(host)")!, supabaseKey: "test-public-key",
            options: SupabaseClientOptions(auth: .init(storage: ChatEmptyAuthStorage(), autoRefreshToken: false), global: .init(session: URLSession(configuration: configuration)))
        )
        return TaskforceReads(supabase: supabase)
    }

    private func query(_ recorded: ChatReadStub.Recorded) -> [String: String] {
        Dictionary(recorded.query.compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { first, _ in first })
    }

    @Test func theActiveMacsAreReadFromBridgesWithTheFourColumnsAndOnlyActiveRows() async throws {
        let json = """
        [{"id":"b1111111-1111-4111-8111-111111111111","device_name":"Studio","last_heartbeat_at":"2026-10-18T05:00:00+00:00","app_version":"0.2.0"},
         {"id":"b2222222-2222-4222-8222-222222222222","device_name":null,"last_heartbeat_at":null,"app_version":null}]
        """
        let macs = try await reads(rows: ["bridges": json]).activeBridges()
        #expect(macs.map(\.deviceName) == ["Studio", nil] && macs[0].appVersion == "0.2.0")
        let request = try #require(ChatReadStub.requests(host: host).last)
        let q = query(request)
        #expect(request.path == "/rest/v1/bridges")
        #expect(q["select"] == "id,device_name,last_heartbeat_at,app_version", "secret_hash · heartbeat_result는 읽지 않는다")
        #expect(q["status"] == "eq.active", "폐기된 Mac은 거른다")
    }

    // MARK: 프로젝트를 id로 직접 (ch.21 3: 이름순 500 목록으로 판단하지 않는다)

    @Test func projectsAreAskedByTheirRegisteredIdsInChunksSoMoreThanFiveHundredNeverLoseOne() async throws {
        let ids = (0..<501).map { _ in UUID() }
        let rows = ids.prefix(3).enumerated().map { index, id in
            #"{"id":"\#(id.uuidString.lowercased())","name":"P\#(index)","kind":"project","status":"active","context_version":1,"last_activity_at":null,"icon":"folder","version":1}"#
        }.joined(separator: ",")
        let stub = reads(rows: ["work_contexts": "[\(rows)]"])
        let found = try await stub.workContexts(ids: ids)
        let requests = ChatReadStub.requests(host: host).filter { $0.path == "/rest/v1/work_contexts" }
        #expect(requests.count == 6, "501개는 100개씩 여섯 번: \(requests.count)")
        var asked = Set<String>()
        for request in requests {
            let filter = try #require(query(request)["id"], "id in (…) 필터")
            #expect(filter.hasPrefix("in.("))
            let list = filter.dropFirst("in.(".count).dropLast().split(separator: ",").map(String.init)
            #expect(list.count <= 100 && query(request)["limit"] == nil, "한 번에 100개 이하 · 이름순 한도(limit) 없음")
            asked.formUnion(list)
        }
        #expect(asked == Set(ids.map { $0.uuidString.lowercased() }), "등록된 id를 하나도 빼지 않고 물었다")
        #expect(found.count == 3 * 6, "각 묶음의 답을 모두 모은다")
    }

    @Test func askingForNoProjectsReadsNothing() async throws {
        let stub = reads(rows: ["work_contexts": "[]"])
        #expect(try await stub.workContexts(ids: []).isEmpty)
        #expect(ChatReadStub.requests(host: host).isEmpty, "빈 목록은 서버를 부르지 않는다")
    }

    @Test func noRowsIsAnEmptyList() async throws {
        #expect(try await reads(rows: ["bridges": "[]"]).activeBridges().isEmpty)
    }
}
