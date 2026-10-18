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

    @Test func noRowsIsAnEmptyList() async throws {
        #expect(try await reads(rows: ["bridges": "[]"]).activeBridges().isEmpty)
    }
}
