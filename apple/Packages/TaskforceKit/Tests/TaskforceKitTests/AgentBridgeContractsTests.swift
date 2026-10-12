import Foundation
import Testing
@testable import TaskforceKit

/// 에이전트 · bridge 계약 (0.2.0 A2). 본문은 `src/lib/api/contract-v2.test.ts`의 AGENT_* · BRIDGE_* 픽스처와 같은 JSON이다 —
/// 한쪽을 고치면 다른 쪽도 고친다. 모르는 값은 `.unknown(raw)`로 읽고 그대로 다시 보낸다.
struct AgentBridgeContractsTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try TaskforceJSON.decoder().decode(type, from: Data(json.utf8))
    }

    private func object(_ value: some Encodable) throws -> NSDictionary {
        let data = try TaskforceJSON.encoder().encode(value)
        return try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    private func date(_ string: String) -> Date { PostgresTimestamp.parse(string)! }

    static let capabilityJSON = #"""
    {"adapter":"agent:claude-code","transport":"local_bridge",
     "session":{"list":false,"attach_existing":true,"create":true,"workspace_scoped":true},
     "dispatch":{"ack_level":"agent","max_instruction_chars":20000},
     "events":"push","question":{"receive":true,"answer":true},
     "cancel":"requested_only","resume":"supported",
     "enforcement":{
       "approval_gate":{"channel":"permission_prompt_tool","verified":false,"evidence":"docs 2026-10-09, not measured"},
       "target_scope":{"channel":"allowed_tools","verified":false},
       "revocation":{"channel":"process_exit","verified":false},
       "budget":{"channel":"max_budget_usd","verified":false}},
     "cost":"estimated","artifacts":["files","diff","text"]}
    """#

    static let questionEventJSON = #"""
    {"adapter":"agent:claude-code","session_id":"c0ffee00-0000-4000-8000-000000000001","external_task_id":"turn-7",
     "event_id":"evt-42","seq":42,"type":"question","directive_version":2,
     "payload":{"kind":"approval","question_id":"q-1","tool":"Bash","target":"git push"},
     "observed_at":"2026-10-09T05:00:00.123Z"}
    """#

    static let commandsJSON = #"""
    {"commands":[{"id":"b2222222-2222-4222-8222-222222222222","bridge_id":"b1111111-1111-4111-8111-111111111111",
     "kind":"dispatch","payload":{"bundle_hash":"sha256:abc","marker":"tf-1"},
     "lease_until":"2026-10-09T05:00:25+00:00","acked_at":null,"created_at":"2026-10-09T05:00:00.123456+00:00"}]}
    """#

    // MARK: capability

    @Test func capabilityDecodes() throws {
        let capability = try decode(AgentCapability.self, Self.capabilityJSON)
        #expect(capability.adapter == "agent:claude-code")
        #expect(capability.transport == .localBridge)
        #expect(capability.session == .init(list: false, attachExisting: true, create: true, workspaceScoped: true))
        #expect(capability.dispatch == .init(ackLevel: .agent, maxInstructionChars: 20000))
        #expect(capability.events == .push)
        #expect(capability.question == .init(receive: true, answer: true))
        #expect(capability.cancel == .requestedOnly)
        #expect(capability.resume == .supported)
        #expect(capability.enforcement.approvalGate == AgentBoundary(channel: "permission_prompt_tool", verified: false, evidence: "docs 2026-10-09, not measured"))
        #expect(capability.enforcement.budget == AgentBoundary(channel: "max_budget_usd", verified: false))
        #expect(capability.cost == .estimated)
        #expect(capability.artifacts == [.files, .diff, .text])
    }

    /// 서버 · bridge가 새 값을 더해도 디코딩은 실패하지 않는다. 모르는 값은 그대로 다시 보낸다
    @Test func capabilityUnknownValuesDecodeAndRoundTrip() throws {
        let future = Self.capabilityJSON
            .replacingOccurrences(of: #""transport":"local_bridge""#, with: #""transport":"websocket""#)
            .replacingOccurrences(of: #""ack_level":"agent""#, with: #""ack_level":"receipt""#)
            .replacingOccurrences(of: #""events":"push""#, with: #""events":"stream""#)
            .replacingOccurrences(of: #""cancel":"requested_only""#, with: #""cancel":"graceful""#)
            .replacingOccurrences(of: #""resume":"supported""#, with: #""resume":"partial""#)
            .replacingOccurrences(of: #""cost":"estimated""#, with: #""cost":"metered""#)
            .replacingOccurrences(of: #""artifacts":["files","diff","text"]"#, with: #""artifacts":["files","video"]"#)
        let capability = try decode(AgentCapability.self, future)
        #expect(capability.transport == .unknown("websocket"))
        #expect(capability.dispatch.ackLevel == .unknown("receipt"))
        #expect(capability.events == .unknown("stream"))
        #expect(capability.cancel == .unknown("graceful"))
        #expect(capability.resume == .unknown("partial"))
        #expect(capability.cost == .unknown("metered"))
        #expect(capability.artifacts == [.files, .unknown("video")])

        let again = try TaskforceJSON.decoder().decode(AgentCapability.self, from: TaskforceJSON.encoder().encode(capability))
        #expect(again == capability)
        let sent = try object(capability)
        #expect(sent["transport"] as? String == "websocket")
        #expect(sent["artifacts"] as? [String] == ["files", "video"])
    }

    @Test(arguments: [
        ("observable", AgentCostVisibility.observable), ("estimated", .estimated), ("unknown", .notObservable), ("free", .unknown("free")),
    ])
    func costValues(_ raw: String, _ cost: AgentCostVisibility) {
        #expect(AgentCostVisibility(raw: raw) == cost)
        #expect(cost.raw == raw)
    }

    @Test func eventsNoneIsNotOptionalNone() throws {
        let capability = try decode(AgentCapability.self, Self.capabilityJSON.replacingOccurrences(of: #""events":"push""#, with: #""events":"none""#))
        #expect(capability.events == .noEvents)
        #expect(try object(capability)["events"] as? String == "none")
    }

    /// Boundary: channel이 없으면 null로 보내고(zod nullable), evidence가 없으면 키를 뺀다(zod optional)
    @Test func boundaryEncodesNullChannelAndOmitsEvidence() throws {
        let sent = try object(AgentBoundary(channel: nil, verified: false))
        #expect(sent.allKeys.compactMap { $0 as? String }.sorted() == ["channel", "verified"])
        #expect(sent["channel"] is NSNull)
        #expect(sent["verified"] as? Bool == false)
    }

    // MARK: 사건 봉투

    @Test func questionEventDecodes() throws {
        let event = try decode(AgentEventEnvelope.self, Self.questionEventJSON)
        #expect(event.adapter == "agent:claude-code")
        #expect(event.sessionID == "c0ffee00-0000-4000-8000-000000000001")
        #expect(event.externalTaskID == "turn-7")
        #expect(event.eventID == "evt-42")
        #expect(event.seq == 42)
        #expect(event.type == .question)
        #expect(event.directiveVersion == 2)
        #expect(event.resultRevision == nil)
        #expect(event.payload["kind"] == .string("approval"))
        #expect(event.payload["target"] == .string("git push"))
        #expect(event.observedAt == date("2026-10-09T05:00:00.123Z"))
    }

    @Test func unknownEventTypeDecodes() throws {
        let event = try decode(AgentEventEnvelope.self, Self.questionEventJSON.replacingOccurrences(of: #""type":"question""#, with: #""type":"thinking""#))
        #expect(event.type == .unknown("thinking"))
        #expect(try object(event)["type"] as? String == "thinking")
    }

    @Test(arguments: [
        "accepted", "progress", "question", "artifact", "completed", "failed", "cancelled", "unreachable", "reconcile", "unsupported",
    ])
    func eventTypesRoundTrip(_ raw: String) {
        let type = AgentEventType(raw: raw)
        #expect(type != .unknown(raw))
        #expect(type.raw == raw)
    }

    /// bridge가 보내는 봉투: 선택 값이 없으면 키를 빼고(zod optional은 null을 받지 않는다), 시각은 UTC ISO 8601
    @Test func eventEncodesForServer() throws {
        let event = AgentEventEnvelope(
            adapter: "agent:claude-code", sessionID: "s-1", externalTaskID: "turn-1", eventID: "evt-1", type: .completed,
            resultRevision: 1, payload: ["files": .number(2)], observedAt: date("2026-10-09T05:00:00Z")
        )
        let sent = try object(event)
        #expect(sent.allKeys.compactMap { $0 as? String }.sorted() == [
            "adapter", "event_id", "external_task_id", "observed_at", "payload", "result_revision", "session_id", "type",
        ])
        #expect(sent["observed_at"] as? String == "2026-10-09T05:00:00.000Z")
        #expect(sent["type"] as? String == "completed")
        #expect(sent["result_revision"] as? Int == 1)
        let again = try TaskforceJSON.decoder().decode(AgentEventEnvelope.self, from: TaskforceJSON.encoder().encode(event))
        #expect(again == event)
    }

    @Test(arguments: [
        ("dispatched", AgentTaskState.dispatched), ("accepted", .accepted), ("running", .running), ("awaiting_answer", .awaitingAnswer),
        ("completed", .completed), ("failed", .failed), ("cancelled", .cancelled), ("unreachable", .unreachable), ("paused", .unknown("paused")),
    ])
    func taskStates(_ raw: String, _ state: AgentTaskState) throws {
        #expect(AgentTaskState(raw: raw) == state)
        #expect(try decode([AgentTaskState].self, "[\"\(raw)\"]") == [state])
        #expect(state.raw == raw)
    }

    // MARK: bridge

    @Test func commandsDecode() throws {
        let response = try decode(BridgeCommandsResponse.self, Self.commandsJSON)
        let command = try #require(response.commands.first)
        #expect(command.id == UUID(uuidString: "b2222222-2222-4222-8222-222222222222"))
        #expect(command.bridgeID == UUID(uuidString: "b1111111-1111-4111-8111-111111111111"))
        #expect(command.kind == .dispatch)
        #expect(command.payload["bundle_hash"] == .string("sha256:abc"))
        #expect(command.leaseUntil == date("2026-10-09T05:00:25Z"))
        #expect(command.ackedAt == nil)
        #expect(command.createdAt == date("2026-10-09T05:00:00.123456Z"))
    }

    /// 모르는 명령 kind도 목록 전체를 읽는다 (bridge는 그 명령만 실행하지 않고 unsupported로 답한다)
    @Test func unknownCommandKindDecodes() throws {
        let json = Self.commandsJSON
            .replacingOccurrences(of: #""kind":"dispatch""#, with: #""kind":"spawn_browser""#)
            .replacingOccurrences(of: #""lease_until":"2026-10-09T05:00:25+00:00","#, with: "")
        let command = try #require(try decode(BridgeCommandsResponse.self, json).commands.first)
        #expect(command.kind == .unknown("spawn_browser"))
        #expect(command.leaseUntil == nil)
    }

    @Test(arguments: [
        ("dispatch", BridgeCommandKind.dispatch), ("message", .message), ("cancel", .cancel), ("reconcile", .reconcile), ("check", .check),
    ])
    func commandKinds(_ raw: String, _ kind: BridgeCommandKind) {
        #expect(BridgeCommandKind(raw: raw) == kind)
        #expect(kind.raw == raw)
    }

    @Test func heartbeatEncodes() throws {
        let bridge = try #require(UUID(uuidString: "b1111111-1111-4111-8111-111111111111"))
        let task = try #require(UUID(uuidString: "b3333333-3333-4333-8333-333333333333"))
        let beat = BridgeHeartbeat(bridgeID: bridge, sentAt: date("2026-10-09T05:00:30Z"), tasks: [.init(taskID: task, processAlive: true, lastSeq: 42)])
        let sent = try object(beat)
        #expect((sent["bridge_id"] as? String)?.lowercased() == "b1111111-1111-4111-8111-111111111111")
        #expect(sent["sent_at"] as? String == "2026-10-09T05:00:30.000Z")
        let tasks = try #require(sent["tasks"] as? [NSDictionary])
        #expect(tasks.count == 1)
        #expect((tasks[0]["task_id"] as? String)?.lowercased() == "b3333333-3333-4333-8333-333333333333")
        #expect(tasks[0]["process_alive"] as? Bool == true)
        #expect(tasks[0]["last_seq"] as? Int == 42)
        let again = try TaskforceJSON.decoder().decode(BridgeHeartbeat.self, from: TaskforceJSON.encoder().encode(beat))
        #expect(again == beat)
    }

    @Test func registerAndEventsRequestsEncode() throws {
        let capability = try decode(AgentCapability.self, Self.capabilityJSON)
        let register = try object(BridgeRegisterRequest(deviceID: "mac-1", appVersion: "0.2.0", capabilities: [capability]))
        #expect(register.allKeys.compactMap { $0 as? String }.sorted() == ["app_version", "capabilities", "device_id"])
        let sentCapability = try #require((register["capabilities"] as? [NSDictionary])?.first)
        #expect(sentCapability == (try JSONSerialization.jsonObject(with: Data(Self.capabilityJSON.utf8)) as? NSDictionary))

        let bridge = try #require(UUID(uuidString: "b1111111-1111-4111-8111-111111111111"))
        let event = try decode(AgentEventEnvelope.self, Self.questionEventJSON)
        let events = try object(BridgeEventsRequest(bridgeID: bridge, events: [event]))
        let sentEvent = try #require((events["events"] as? [NSDictionary])?.first)
        #expect(sentEvent["event_id"] as? String == "evt-42")
        #expect(sentEvent["observed_at"] as? String == "2026-10-09T05:00:00.123Z")

        let accepted = try decode(BridgeEventsResponse.self, #"{"accepted_event_ids":["evt-42"]}"#)
        #expect(accepted.acceptedEventIDs == ["evt-42"])
        let registered = try decode(BridgeRegisterResponse.self, #"{"bridge_id":"b1111111-1111-4111-8111-111111111111","heartbeat_interval_seconds":30}"#)
        #expect(registered == BridgeRegisterResponse(bridgeID: bridge, heartbeatIntervalSeconds: 30))
    }
}
