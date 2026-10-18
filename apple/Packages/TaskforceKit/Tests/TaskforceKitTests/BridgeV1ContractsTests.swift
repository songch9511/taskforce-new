import Foundation
import Testing
@testable import TaskforceKit

/// D2a `bridgeV1*` 스키마의 Swift 짝 (OA D2b 계약 3장 · 4.1 K1).
/// `Fixtures/bridge-v1/*.json`은 서버 쪽 `src/lib/bridge/swift-fixtures.test.ts`가 같은 파일을 zod로 parse한다:
/// 요청은 파일과 **정확히 같은 키**를 내보내야 하고(서버 스키마가 모두 strictObject), 응답 파일은 서버가 실제로 줄 수 있는 모양이다.
enum BridgeFixtures {
    static func file(_ name: String) throws -> [String: Any] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "bridge-v1"))
        let data = try Data(contentsOf: url)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func data(_ value: Any?) throws -> Data {
        try JSONSerialization.data(withJSONObject: try #require(value), options: [.sortedKeys])
    }

    /// 키 순서와 상관없이 같은 문자열이 되게 정렬해 비교한다 (true와 1을 같다고 보지 않는다)
    static func canonical(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
    }
}

struct BridgeV1ContractsTests {
    static let bridgeID = "b1111111-1111-4111-8111-111111111111"
    static let sessionID = "5e551011-0000-4000-8000-000000000001"
    static let taskID = "7a5c0001-0000-4000-8000-000000000002"

    private func date(_ string: String) -> Date { PostgresTimestamp.parse(string)! }

    private func expectSameJSON(_ value: some Encodable, _ expected: Any?, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let data = try TaskforceJSON.encoder().encode(value)
        let actual = try BridgeFixtures.canonical(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
        let wanted = try BridgeFixtures.canonical(try #require(expected))
        #expect(actual == wanted, "\(actual) != \(wanted)", sourceLocation: sourceLocation)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ value: Any?) throws -> T {
        // 디코더 설정과 상관없이 읽어야 한다: 날짜 전략이 없는 기본 디코더로도
        try JSONDecoder().decode(type, from: try BridgeFixtures.data(value))
    }

    private func decode<T: Decodable>(_ type: T.Type, json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    // MARK: 요청: 고정 JSON과 같은 키

    @Test func registerRequestsHaveExactlyTheServerKeys() throws {
        let file = try BridgeFixtures.file("register")
        let request = BridgeV1RegisterRequest(
            deviceID: "Zm9vYmFyYmF6cXV4Zm9vYmFyYmF6cXV4Zm9vYmFyYmE", appVersion: "0.2.0",
            adapters: [
                BridgeV1AdapterReport(adapter: "agent:claude-code", installed: true, version: "2.1.241", signedIn: .yes, managedSettings: false),
                BridgeV1AdapterReport(adapter: "agent:codex", installed: false, version: nil, signedIn: .unknown, managedSettings: false),
            ],
            connect: ["agent:claude-code"], reactivate: false
        )
        try expectSameJSON(request, file["request"])
        let reactivate = BridgeV1RegisterRequest(
            deviceID: "Zm9vYmFyYmF6cXV4Zm9vYmFyYmF6cXV4Zm9vYmFyYmE", appVersion: "0.2.0", adapters: [], connect: [], reactivate: true
        )
        try expectSameJSON(reactivate, file["request_reactivate"])
    }

    /// OA F1m: 표시용 Mac 이름은 선택 키 `device_name`이다 (서버 `bridgeV1RegisterRequestWithDeviceSchema`). 없으면 키를 뺀다 (위 두 요청 파일에는 키가 없다)
    @Test func registerRequestCarriesTheDeviceNameKeyOnlyWhenThereIsAName() throws {
        let file = try BridgeFixtures.file("register")
        let request = BridgeV1RegisterRequest(
            deviceID: "Zm9vYmFyYmF6cXV4Zm9vYmFyYmF6cXV4Zm9vYmFyYmE", appVersion: "0.2.0",
            adapters: [BridgeV1AdapterReport(adapter: "agent:claude-code", installed: true, version: "2.1.241", signedIn: .yes, managedSettings: false)],
            connect: ["agent:claude-code"], reactivate: false, deviceName: "Daniel's MacBook Pro"
        )
        try expectSameJSON(request, file["request_with_device"])
        var without = request
        without.deviceName = nil
        let object = try #require(try JSONSerialization.jsonObject(with: try TaskforceJSON.encoder().encode(without)) as? [String: Any])
        #expect(object["device_name"] == nil, "null 금지: 키를 뺀다")
    }

    @Test func aMissingAdapterVersionIsSentAsNullNotOmitted() throws {
        let report = BridgeV1AdapterReport(adapter: "agent:codex", installed: false, version: nil, signedIn: .no, managedSettings: true)
        let data = try TaskforceJSON.encoder().encode(report)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["adapter", "installed", "version", "signed_in", "managed_settings"])
        #expect(object["version"] is NSNull)
    }

    @Test func revokeRequestMatchesFixture() throws {
        let file = try BridgeFixtures.file("revoke")
        try expectSameJSON(BridgeV1RevokeRequest(bridgeID: Self.bridgeID), file["request"])
    }

    @Test func ackRequestsMatchFixtures() throws {
        let requests = try #require(try BridgeFixtures.file("ack")["requests"] as? [String: Any])
        let command = "c2222222-2222-4222-8222-22222222222"
        func ack(_ suffix: String, _ op: BridgeV1AckOp) -> BridgeV1AckRequest {
            BridgeV1AckRequest(bridgeID: Self.bridgeID, commandID: command + suffix, op: op)
        }
        try expectSameJSON(ack("2", .lease), requests["lease"])
        try expectSameJSON(ack("1", .complete(.sent)), requests["complete_sent"])
        try expectSameJSON(ack("1", .complete(.taskUnknown)), requests["complete_task_unknown"])
        try expectSameJSON(ack("3", .readback(.received, processEnded: false)), requests["readback_received"])
        try expectSameJSON(ack("3", .readback(.notReceived, processEnded: true)), requests["readback_not_received"])
        try expectSameJSON(ack("3", .readback(.unknown, processEnded: false)), requests["readback_unknown"])
        try expectSameJSON(ack("4", .requestClosed), requests["request_closed"])
        try expectSameJSON(ack("5", .decline), requests["decline"])
    }

    @Test func aNotReceivedReadbackWithoutAnEndedProcessCannotBeEncoded() {
        let request = BridgeV1AckRequest(
            bridgeID: Self.bridgeID, commandID: "c2222222-2222-4222-8222-222222222223", op: .readback(.notReceived, processEnded: false)
        )
        #expect(throws: (any Error).self) { try TaskforceJSON.encoder().encode(request) }
    }

    @Test func heartbeatRequestsMatchFixturesAndKeepTheNullableLastSeqKey() throws {
        let file = try BridgeFixtures.file("heartbeat")
        let full = BridgeV1HeartbeatRequest(
            bridgeID: Self.bridgeID, sentAt: date("2026-10-14T05:00:00.000Z"), appVersion: "0.2.0",
            tasks: [
                BridgeV1HeartbeatTask(taskID: "7a5c0001-0000-4000-8000-000000000001", processAlive: true, lastSeq: 7),
                BridgeV1HeartbeatTask(taskID: "7a5c0001-0000-4000-8000-000000000002", processAlive: false, lastSeq: nil),
            ],
            adapters: [BridgeV1AdapterReport(adapter: "agent:claude-code", installed: true, version: "2.1.241", signedIn: .yes, managedSettings: false)]
        )
        try expectSameJSON(full, file["request"])
        let minimal = BridgeV1HeartbeatRequest(bridgeID: Self.bridgeID, sentAt: date("2026-10-14T05:00:30.000Z"), appVersion: nil, tasks: [], adapters: nil)
        try expectSameJSON(minimal, file["request_minimal"])
        let named = BridgeV1HeartbeatRequest(
            bridgeID: Self.bridgeID, sentAt: date("2026-10-14T05:01:00.000Z"), appVersion: nil, tasks: [], adapters: nil, deviceName: "Daniel's MacBook Pro"
        )
        try expectSameJSON(named, file["request_with_device"])
        let data = try TaskforceJSON.encoder().encode(minimal)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["app_version"] == nil && object["adapters"] == nil)
    }

    @Test func eachEventTypeMatchesItsFixture() throws {
        let events = try #require(try BridgeFixtures.file("events")["events"] as? [String: Any])
        let task = Self.taskID
        func event(_ id: String, seq: Int?, observed: String, external: String? = nil, adapter: String = "agent:claude-code", _ body: BridgeV1Event.Body) -> BridgeV1Event {
            BridgeV1Event(
                adapter: adapter, sessionID: Self.sessionID, taskID: task, externalTaskID: external, eventID: id, seq: seq, turnSeq: 2,
                observedAt: date(observed), body: body
            )
        }
        try expectSameJSON(event("\(task):1", seq: 1, observed: "2026-10-14T05:00:03.123Z", .accepted), events["accepted"])
        try expectSameJSON(event("\(task):2", seq: 2, observed: "2026-10-14T05:00:04.000Z", external: "turn-2", .progress), events["progress"])
        try expectSameJSON(event("\(task):3", seq: 3, observed: "2026-10-14T05:00:05.000Z", .message(text: "Here is the summary.")), events["message"])
        let question = BridgeV1Question(
            providerRequestID: "req-1", kind: .input, structured: true,
            questions: [
                BridgeV1QuestionItem(
                    id: "q1", header: "Environment", text: "Which environment should I deploy to?",
                    options: [
                        BridgeV1QuestionOption(label: "staging", description: "The staging cluster"),
                        BridgeV1QuestionOption(label: "production", description: "The production cluster"),
                    ],
                    multiSelect: false, allowOther: true, secret: false
                )
            ]
        )
        try expectSameJSON(event("\(task):4", seq: 4, observed: "2026-10-14T05:00:06.000Z", .question(text: "Which environment?", question)), events["question"])
        try expectSameJSON(
            event("\(task):5", seq: 5, observed: "2026-10-14T05:00:07.000Z", .artifact(path: "notes/summary.md", hash: "sha256:abc123", summary: "Summary of open tasks")),
            events["artifact"]
        )
        try expectSameJSON(event("\(task):6", seq: 6, observed: "2026-10-14T05:00:08.000Z", .turnCompleted), events["turn_completed"])
        try expectSameJSON(event("\(task):7", seq: 7, observed: "2026-10-14T05:00:09.000Z", .cancelled), events["cancelled"])
        try expectSameJSON(event("\(task):8", seq: 8, observed: "2026-10-14T05:00:10.000Z", .failed(.signInNeeded)), events["failed"])
        try expectSameJSON(event("\(task):9", seq: 9, observed: "2026-10-14T05:00:11.000Z", .failed(nil)), events["failed_bare"])
        try expectSameJSON(
            event("\(Self.sessionID):s1", seq: nil, observed: "2026-10-14T05:00:02.500Z", .sessionBound(externalSessionID: "claude-session-9", workspaceRef: "workspace-a")),
            events["session_bound"]
        )
        try expectSameJSON(
            event("\(Self.sessionID):s2", seq: nil, observed: "2026-10-14T05:00:02.600Z", adapter: "agent:codex", .sessionBound(externalSessionID: "thread-77", workspaceRef: nil)),
            events["session_bound_no_workspace"]
        )
        try expectSameJSON(event("\(task):r1", seq: nil, observed: "2026-10-14T05:10:00.000Z", .reconcile(state: nil)), events["reconcile"])
        try expectSameJSON(event("\(task):r2", seq: nil, observed: "2026-10-14T05:10:01.000Z", .reconcile(state: "running")), events["reconcile_with_state"])
    }

    @Test func eventsWithoutAPayloadOmitTheKeyAndTextBelongsOnlyToMessagesAndQuestions() throws {
        for body in [BridgeV1Event.Body.accepted, .progress, .turnCompleted, .cancelled, .failed(nil), .reconcile(state: nil)] {
            let event = BridgeV1Event(adapter: "agent:codex", sessionID: Self.sessionID, taskID: Self.taskID, externalTaskID: nil, eventID: "e", seq: 1, turnSeq: 1, observedAt: Date(timeIntervalSince1970: 0), body: body)
            let object = try #require(try JSONSerialization.jsonObject(with: try TaskforceJSON.encoder().encode(event)) as? [String: Any])
            #expect(object["payload"] == nil, "\(body)")
            #expect(object["text"] == nil, "\(body)")
            #expect(object["question"] == nil, "\(body)")
            #expect(object["external_task_id"] == nil, "\(body)")
        }
    }

    @Test func theEventsRequestIsTheBridgeIDPlusTheStoredEventJSONInOrder() throws {
        let file = try BridgeFixtures.file("events")
        let request = try #require(file["request"] as? [String: Any])
        let events = try #require(request["events"] as? [[String: Any]])
        let stored = try events.map { String(decoding: try BridgeFixtures.data($0), as: UTF8.self) }
        let body = BridgeV1EventsRequest.body(bridgeID: Self.bridgeID, eventJSON: stored)
        let parsed = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(try BridgeFixtures.canonical(parsed) == BridgeFixtures.canonical(request))
    }

    @Test func theCommandsQueryCarriesBridgeAfterAndWait() {
        let items = BridgeV1CommandsQuery(bridgeID: Self.bridgeID, after: 42, wait: 25).queryItems
        #expect(items == [URLQueryItem(name: "bridge_id", value: Self.bridgeID), URLQueryItem(name: "after", value: "42"), URLQueryItem(name: "wait", value: "25")])
    }

    // MARK: 응답: 고정 JSON 디코딩

    @Test func registerResponseDecodes() throws {
        let response = try decode(BridgeV1RegisterResponse.self, try BridgeFixtures.file("register")["response"])
        #expect(response.bridgeID == Self.bridgeID)
        #expect(response.bridgeSecret == "c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0MTI")
        #expect(response.heartbeatIntervalSeconds == 30 && response.unreachableAfterSeconds == 90 && response.longPollMaxSeconds == 25)
        #expect(response.connections.map(\.status) == [.active, .error])
        #expect(response.connections.map(\.adapter) == ["agent:claude-code", "agent:codex"])
    }

    @Test func revokeResponseDecodes() throws {
        let response = try decode(BridgeV1RevokeResponse.self, try BridgeFixtures.file("revoke")["response"])
        #expect(response.status == "revoked")
        #expect(response.tasks.map(\.cancel.raw) == ["requested_only", "confirmed"])
        #expect(response.tasks.map(\.processes) == ["may_continue", nil])
    }

    @Test func commandsResponseDecodesListReadbacksCursorAndServerTime() throws {
        let response = try decode(BridgeV1CommandsResponse.self, try BridgeFixtures.file("commands")["response"])
        #expect(response.commands.map(\.kind) == [.cancel, .message])
        #expect(response.commands.map(\.cursor) == [41, 42])
        #expect(response.commands.map(\.leasedByMe) == [false, true])
        #expect(response.commands[1].agentTaskID == Self.taskID && response.commands[1].turnSeq == 2)
        #expect(response.commands[0].createdAt == date("2026-10-14T05:00:00.123456+00:00"))
        #expect(response.readbacks.count == 1)
        #expect(response.readbacks[0].marker == "tf-marker-3" && response.readbacks[0].kind == .message)
        #expect(response.readbacks[0].leasedAt == date("2026-10-14T04:50:00.5+00:00"))
        #expect(response.nextCursor == 42)
        #expect(response.serverTime == date("2026-10-14T05:00:02.000Z"))
        let empty = try decode(BridgeV1CommandsResponse.self, try BridgeFixtures.file("commands")["response_empty"])
        #expect(empty.commands.isEmpty && empty.readbacks.isEmpty && empty.nextCursor == 0)
    }

    @Test func ackLeaseResponsesDecodeTheWholeCommandPayload() throws {
        let responses = try #require(try BridgeFixtures.file("ack")["responses"] as? [String: Any])
        guard case .leased(let payload, let expires) = try decode(BridgeV1AckResponse.self, responses["leased_message"]),
              case .message(let message) = payload else {
            Issue.record("leased message expected")
            return
        }
        #expect(expires == date("2026-10-14T05:05:30.000Z"))
        #expect(message.common.id == "c2222222-2222-4222-8222-222222222222")
        #expect(message.common.agentSessionID == Self.sessionID && message.common.agentTaskID == Self.taskID && message.common.turnSeq == 2)
        #expect(message.common.stepID == "57e90001-0000-4000-8000-000000000001")
        #expect(message.common.adapter == "agent:claude-code" && message.common.marker == "tf-marker-2")
        #expect(message.common.session == BridgeV1CommandSession(externalSessionID: nil, workspaceRef: nil, resume: false))
        #expect(message.access == .write && message.policyMode == .manual)
        #expect(message.messageID == "3e550001-0000-4000-8000-000000000001" && message.text == "Please summarize the open tasks.")
        #expect(message.closeBeforeRequestID == nil)

        guard case .replay(let replayed, _) = try decode(BridgeV1AckResponse.self, responses["replay_message_resume"]),
              case .message(let resumed) = replayed else {
            Issue.record("replay message expected")
            return
        }
        #expect(resumed.common.session == BridgeV1CommandSession(externalSessionID: "claude-session-9", workspaceRef: "workspace-a", resume: true))
        #expect(resumed.access == .readOnly && resumed.policyMode == .full && resumed.closeBeforeRequestID == "req-old")

        guard case .leased(let answerPayload, _) = try decode(BridgeV1AckResponse.self, responses["leased_answer"]),
              case .answer(let answer) = answerPayload else {
            Issue.record("leased answer expected")
            return
        }
        #expect(answer.providerRequestID == "req-1" && answer.questionKind == .input && answer.structured)
        #expect(answer.answers == ["q1": .one("Yes"), "q2": .many(["A", "B"])])
        #expect(answer.answerText == nil && !answer.answeredLocally)

        guard case .leased(let localPayload, _) = try decode(BridgeV1AckResponse.self, responses["leased_answer_local"]),
              case .answer(let local) = localPayload else {
            Issue.record("local answer expected")
            return
        }
        #expect(local.answeredLocally && local.answers == nil && local.answerText == nil)

        guard case .leased(let cancelPayload, _) = try decode(BridgeV1AckResponse.self, responses["leased_cancel"]),
              case .cancel(let cancel) = cancelPayload else {
            Issue.record("leased cancel expected")
            return
        }
        #expect(cancel.abandonedRequestID == "req-abandoned" && cancel.cancelScope == .turnAndProcesses)
    }

    @Test func ackStatusesWithAndWithoutReasonsDecode() throws {
        let responses = try #require(try BridgeFixtures.file("ack")["responses"] as? [String: Any])
        #expect(try decode(BridgeV1AckResponse.self, responses["withdrawn"]) == .withdrawn(reason: .writeGateClosed))
        #expect(try decode(BridgeV1AckResponse.self, responses["stale"]) == .stale(reason: .heartbeatFirst))
        #expect(try decode(BridgeV1AckResponse.self, responses["stale_bare"]) == .stale(reason: nil))
        #expect(try decode(BridgeV1AckResponse.self, responses["settled"]) == .settled(taskState: .cancelled))
        #expect(try decode(BridgeV1AckResponse.self, responses["settled_bare"]) == .settled(taskState: nil))
    }

    @Test func eventsResponseDecodesTheThreeAuthoritativeLists() throws {
        let response = try decode(BridgeV1EventsResponse.self, try BridgeFixtures.file("events")["response"])
        #expect(response.acceptedEventIDs.count == 2)
        #expect(response.retryEventIDs == ["7a5c0001-0000-4000-8000-000000000002:5"])
        #expect(response.rejected == [BridgeV1EventRejection(eventID: "7a5c0001-0000-4000-8000-000000000002:4", code: "invalid")])
        #expect(response.results.map(\.status) == [.applied, .duplicate, .stepNotCalling])
        #expect(response.results[0].taskState == .accepted)
    }

    @Test func heartbeatResponseDecodesWithAndWithoutThrottled() throws {
        let file = try BridgeFixtures.file("heartbeat")
        let normal = try decode(BridgeV1HeartbeatResponse.self, file["response"])
        #expect(!normal.throttled && normal.pendingCommands == 2 && normal.heartbeatIntervalSeconds == 30)
        #expect(normal.unknownTaskIDs == ["7a5c0001-0000-4000-8000-000000000009"] && normal.missingTaskIDs.isEmpty)
        #expect(normal.serverTime == date("2026-10-14T05:00:00.250Z"))
        let throttled = try decode(BridgeV1HeartbeatResponse.self, file["response_throttled"])
        #expect(throttled.throttled && throttled.missingTaskIDs == ["7a5c0001-0000-4000-8000-000000000004"])
    }

    // MARK: 받을 때는 너그럽게 (계약 3.1 · 3.3)

    @Test func unknownKeysAreIgnored() throws {
        let response = try decode(
            BridgeV1HeartbeatResponse.self,
            json: #"{"heartbeat_interval_seconds":30,"server_time":"2026-10-14T05:00:00Z","pending_commands":0,"unknown_task_ids":[],"missing_task_ids":[],"future":{"a":1}}"#
        )
        #expect(response.pendingCommands == 0)
    }

    @Test func anUnknownCommandKindInTheListIsKeptAsUnknownNotAFailure() throws {
        let json = #"""
        {"commands":[{"id":"c2222222-2222-4222-8222-222222222290","cursor":9,"kind":"quantum","agent_session_id":"5e551011-0000-4000-8000-000000000001",
        "agent_task_id":"7a5c0001-0000-4000-8000-000000000002","turn_seq":1,"created_at":"2026-10-14T05:00:00Z","leased_by_me":false}],
        "readbacks":[],"next_cursor":9,"server_time":"2026-10-14T05:00:00Z"}
        """#
        let response = try decode(BridgeV1CommandsResponse.self, json: json)
        #expect(response.commands[0].kind == .unknown("quantum"))
        #expect(response.commands[0].kind.raw == "quantum")
    }

    @Test func anUnknownAckStatusIsKeptAsUnknown() throws {
        #expect(try decode(BridgeV1AckResponse.self, json: #"{"status":"teleported","extra":1}"#) == .unknown(status: "teleported"))
    }

    @Test func unknownWithdrawnAndStaleReasonsAreKeptNotRejected() throws {
        #expect(try decode(BridgeV1AckResponse.self, json: #"{"status":"withdrawn","reason":"moon_phase"}"#) == .withdrawn(reason: .unknown("moon_phase")))
        #expect(try decode(BridgeV1AckResponse.self, json: #"{"status":"stale","reason":"moon_phase"}"#) == .stale(reason: .unknown("moon_phase")))
    }

    @Test func unknownPayloadValuesAreKeptSoTheRuntimeCanRefuseToRun() throws {
        var responses = try #require(try BridgeFixtures.file("ack")["responses"] as? [String: Any])
        func mutate(_ key: String, _ field: String, _ value: String) throws -> BridgeV1CommandPayload {
            var response = try #require(responses[key] as? [String: Any])
            var command = try #require(response["command"] as? [String: Any])
            command[field] = value
            response["command"] = command
            guard case .leased(let payload, _) = try decode(BridgeV1AckResponse.self, response) else {
                Issue.record("leased expected")
                throw CancellationError()
            }
            return payload
        }
        guard case .message(let access) = try mutate("leased_message", "access", "root") else { Issue.record("message"); return }
        #expect(access.access == .unknown("root"))
        guard case .message(let mode) = try mutate("leased_message", "policy_mode", "yolo") else { Issue.record("message"); return }
        #expect(mode.policyMode == .unknown("yolo"))
        guard case .answer(let kind) = try mutate("leased_answer", "question_kind", "riddle") else { Issue.record("answer"); return }
        #expect(kind.questionKind == .unknown("riddle"))
        guard case .cancel(let scope) = try mutate("leased_cancel", "cancel_scope", "galaxy") else { Issue.record("cancel"); return }
        #expect(scope.cancelScope == .unknown("galaxy"))
        responses["unused"] = nil
    }

    @Test func anUnknownPayloadKindBecomesUnsupportedWithoutDecodingTheRest() throws {
        let json = #"{"status":"leased","lease_expires_at":"2026-10-14T05:05:30Z","command":{"id":"c2222222-2222-4222-8222-222222222290","kind":"telepathy","brand_new":true}}"#
        guard case .leased(let payload, _) = try decode(BridgeV1AckResponse.self, json: json) else { Issue.record("leased"); return }
        #expect(payload == .unsupported(kind: "telepathy"))
    }

    @Test func unknownConnectionAndResultStatusesAreKeptAsRawText() throws {
        let register = try decode(
            BridgeV1RegisterResponse.self,
            json: #"{"bridge_id":"b1111111-1111-4111-8111-111111111111","bridge_secret":"s","heartbeat_interval_seconds":30,"unreachable_after_seconds":90,"long_poll_max_seconds":25,"connections":[{"connection_id":"c0000001-0000-4000-8000-000000000001","adapter":"agent:codex","status":"paused"}]}"#
        )
        #expect(register.connections[0].status == .unknown("paused"))
        let events = try decode(
            BridgeV1EventsResponse.self,
            json: #"{"results":[{"event_id":"e","status":"brand_new","task_state":"hibernating"}],"accepted_event_ids":[],"retry_event_ids":[],"rejected":[]}"#
        )
        #expect(events.results[0].status == .unknown("brand_new") && events.results[0].taskState == .unknown("hibernating"))
    }

    @Test func aPayloadMissingARequiredKeyFailsToDecode() {
        let json = #"{"status":"leased","lease_expires_at":"2026-10-14T05:05:30Z","command":{"id":"c2222222-2222-4222-8222-222222222222","kind":"cancel"}}"#
        #expect(throws: (any Error).self) { try decode(BridgeV1AckResponse.self, json: json) }
    }
}
