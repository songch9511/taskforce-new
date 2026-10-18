import Foundation
import Testing
@testable import TaskforceKit

/// 대상 목록 agent 행의 `bridge_id` · `device_name` (OA F1s 서버 → F1m Swift): 있을 때 · 없을 때(옛 서버 JSON) · null일 때
struct AssistantTargetBridgeFieldsTests {
    static let bridge = "b1111111-1111-4111-8111-111111111111"
    static let connection = "c0000001-0000-4000-8000-000000000001"

    private func decode(_ json: String) throws -> [AssistantTarget] {
        try JSONDecoder().decode(AssistantTargetsResponse.self, from: Data(json.utf8)).targets
    }

    private func agent(_ target: AssistantTarget) throws -> AssistantTarget.Agent {
        guard case .agent(let agent) = target else { throw DecodeProbe.notAnAgent }
        return agent
    }

    private enum DecodeProbe: Error { case notAnAgent }

    @Test func theServerWithTheNewFieldsGivesTheBridgeAndTheMacName() throws {
        let rows = try decode("""
        {"targets":[{"kind":"taskforce"},
        {"kind":"agent","adapter":"agent:claude-code","display_name":"Claude Code","connection_id":"\(Self.connection)","state":"ready","access":"write",
         "device_name":"Daniel's MacBook Pro","bridge_id":"\(Self.bridge)"}]}
        """)
        let claude = try agent(rows[1])
        #expect(claude.bridgeID == UUID(uuidString: Self.bridge) && claude.deviceName == "Daniel's MacBook Pro")
        #expect(claude.state == .ready && claude.access == .write && claude.connectionID == UUID(uuidString: Self.connection))
    }

    @Test func anOlderServerJSONWithoutTheKeysStillDecodesWithNilFields() throws {
        let rows = try decode("""
        {"targets":[{"kind":"agent","adapter":"agent:claude-code","display_name":"Claude Code","connection_id":"\(Self.connection)","state":"ready","access":"write"}]}
        """)
        let claude = try agent(rows[0])
        #expect(claude.bridgeID == nil && claude.deviceName == nil, "짐작하지 않는다: 옛 서버는 Mac을 알려 주지 않는다")
    }

    @Test func aRowWithNoConnectionHasNullForBoth() throws {
        let rows = try decode("""
        {"targets":[{"kind":"agent","adapter":"agent:claude-code","display_name":"Claude Code","connection_id":null,"state":"not_connected","access":null,
         "device_name":null,"bridge_id":null}]}
        """)
        let claude = try agent(rows[0])
        #expect(claude.connectionID == nil && claude.bridgeID == nil && claude.deviceName == nil && claude.access == nil)
        #expect(claude.state == .notConnected)
    }

    @Test func theNewFieldsDoNotChangeTheWordsTheMenuShows() throws {
        let rows = try decode("""
        {"targets":[{"kind":"taskforce"},
        {"kind":"agent","adapter":"agent:claude-code","display_name":"Claude Code","connection_id":"\(Self.connection)","state":"unsupported","access":"read_only",
         "device_name":"Studio","bridge_id":"\(Self.bridge)"}]}
        """)
        let options = AssistantTargetRules.options(from: rows, canRunAgents: true)
        #expect(options.map(\.status) == [nil, "Unsupported"])
    }
}
