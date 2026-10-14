import Foundation
import Testing
@testable import TaskforceKit

/// 대화 API v2 확장의 DTO (OA D1d-m). 본문은 서버 `src/lib/agents/conversation-contract.test.ts`의 `AGENT_CONVERSATION_*` 상수와 같은 JSON이다
/// (`AgentConversationFixtures`, 출처 표시는 그 파일 머리). 모르는 값은 `.unknown(raw)`로 읽고 그대로 다시 보내며,
/// 계약 값 `"unknown"`(전달 결과 불명)은 `outcomeUnknown`이지 모르는 값이 아니다.
struct AgentConversationContractsTests {
    typealias F = AgentConversationFixtures

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try TaskforceJSON.decoder().decode(type, from: Data(json.utf8))
    }

    private func object(_ value: some Encodable) throws -> NSDictionary {
        let data = try TaskforceJSON.encoder().encode(value)
        return try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    /// 픽스처 JSON의 한 자리를 바꾼 문자열 (모르는 값 시험)
    private func replacing(_ json: String, _ old: String, _ new: String) -> String {
        #expect(json.contains(old), "픽스처에 \(old)가 없다")
        return json.replacingOccurrences(of: old, with: new)
    }

    // MARK: 보내는 모양

    @Test func targetEncodesTaskforceAndAgent() throws {
        #expect(try object(ChatTarget.taskforce) == ["kind": "taskforce"])
        #expect(try object(ChatTarget.agent(connectionID: F.connectionID)) == ["kind": "agent", "connection_id": F.connectionID.uuidString.lowercased()])
        let withSession = try object(ChatTarget.agent(connectionID: F.connectionID, sessionID: F.sessionID))
        #expect(withSession == ["kind": "agent", "connection_id": F.connectionID.uuidString.lowercased(), "session_id": F.sessionID.uuidString.lowercased()])
    }

    @Test func attachmentEncodesSnakeCase() throws {
        let chip = ChatAttachment(kind: .agentSession, id: F.sessionID, origin: .added)
        #expect(try object(chip) == ["kind": "agent_session", "id": F.sessionID.uuidString.lowercased(), "origin": "added"])
        // 버전 비트가 없는 결정적 id도 소문자 그대로 간다
        let deterministic = ChatAttachment(kind: .action, id: F.deterministicActionID, origin: .auto)
        #expect(try object(deterministic) == ["kind": "action", "id": "f0000000-0000-f000-f000-000000000001", "origin": "auto"])
        #expect(ChatAttachment.maxPerMessage == 20)
        // 여섯 종류가 서버 enum 순서 그대로 문자열이다
        let kinds: [ChatAttachmentKind] = [.action, .context, .agentSession, .run, .artifact, .source]
        #expect(kinds.map(\.raw) == ["action", "context", "agent_session", "run", "artifact", "source"])
        // 받은 칩은 같은 모양으로 읽힌다 (왕복)
        let again = try TaskforceJSON.decoder().decode(ChatAttachment.self, from: TaskforceJSON.encoder().encode(chip))
        #expect(again == chip)
    }

    @Test func unknownAttachmentKindAndOriginRoundTrip() throws {
        let chip = try decode(ChatAttachment.self, #"{"kind":"hologram","id":"a1111111-1111-4111-8111-111111111111","origin":"telepathy"}"#)
        #expect(chip.kind == .unknown("hologram") && chip.origin == .unknown("telepathy"))
        #expect(try object(chip)["kind"] as? String == "hologram" && object(chip)["origin"] as? String == "telepathy")
    }

    // MARK: 전달 표시

    @Test func deliveryStateDecodesAllContractValues() throws {
        let expected: [(String, AgentDeliveryState)] = [
            ("answered", .answered), ("queued", .queued), ("needs_referent", .needsReferent), ("not_sent", .notSent), ("expired", .expired),
            ("cancelled", .cancelled), ("sent", .sent), ("accepted", .accepted), ("unknown", .outcomeUnknown),
        ]
        for (raw, state) in expected {
            let delivery = try decode(AgentDelivery.self, #"{"state":"\#(raw)"}"#)
            #expect(delivery.state == state, "\(raw)")
            #expect(state.raw == raw)
        }
        #expect(expected.count == 9, "서버 agentDeliveryStateSchema는 아홉 값이다")
    }

    /// 계약 값 `"unknown"`(결과 불명)은 이 앱이 모르는 값이 아니다. 둘을 섞으면 "결과 불명"이 "모르는 상태"로 보인다
    @Test func deliveryUnknownOutcomeIsNotUnrecognizedValue() throws {
        let outcome = try decode(AgentDelivery.self, #"{"state":"unknown"}"#)
        #expect(outcome.state == .outcomeUnknown)
        #expect(outcome.state != .unknown("unknown"))
        let future = try decode(AgentDelivery.self, #"{"state":"teleported"}"#)
        #expect(future.state == .unknown("teleported"))
        #expect(future.state != .outcomeUnknown)
        // 다시 보내면 받은 글자 그대로
        #expect(outcome.state.raw == "unknown" && future.state.raw == "teleported")
    }

    @Test func deliveryReasonUnknownRoundTrips() throws {
        let reasons = [
            "not_connected", "sign_in_needed", "unsupported", "write_gate_closed", "session_external", "version_unsupported", "usage_limited", "spawn_failed", "not_received",
            "session_busy", "live_limit", "queue_order", "session_closed", "invalid_referent", "not_found", "already_dispatched", "question_open",
        ]
        #expect(reasons.count == 17, "계약 아홉 + SQL이 쓰는 여덟 (OD-12)")
        for raw in reasons {
            let reason = try decode(AgentDelivery.self, #"{"state":"not_sent","reason":"\#(raw)"}"#).reason
            #expect(reason != nil && reason?.raw == raw, "\(raw)")
            if case .unknown = reason { Issue.record("\(raw)를 모르는 값으로 읽었다") }
        }
        let future = try decode(AgentDelivery.self, #"{"state":"not_sent","reason":"disk_full"}"#)
        #expect(future.reason == .unknown("disk_full"))
        #expect(future.reason?.raw == "disk_full")
        // reason이 없으면 nil
        #expect(try decode(AgentDelivery.self, #"{"state":"sent"}"#).reason == nil)
    }

    @Test func needsReferentCarriesAtMostThreeCandidates() throws {
        let posted = try decode(AgentPostedMessage.self, F.needsReferent)
        #expect(posted.delivery.state == .needsReferent)
        #expect(posted.delivery.candidates.map(\.title) == ["가격 문구", "온보딩"])
        #expect(posted.delivery.candidates.map(\.actionID) == [F.deterministicActionID, F.secondID])
        #expect(posted.agentTask == nil && posted.createdAction == nil)
        #expect(posted.attachmentsDropped.isEmpty)
        // 후보가 없는 전달은 빈 목록
        #expect(try decode(AgentDelivery.self, #"{"state":"queued","reason":"session_busy"}"#).candidates.isEmpty)
    }

    // MARK: 보내기 응답

    @Test func agentPostedMessageDecodesNullReplyAndDefaults() throws {
        let posted = try decode(AgentPostedMessage.self, F.postResponse)
        #expect(posted.reply == nil, "에이전트 대상의 reply는 null — 답은 비동기로 대화에 쓰인다")
        #expect(posted.message.id == F.messageID && posted.message.role == .user)
        #expect(posted.message.text == "이어서 해 줘" && posted.message.clientMessageID == F.secondID)
        #expect(posted.delivery.state == .sent)
        #expect(posted.attachmentsDropped == [AttachmentDropped(kind: .source, id: F.secondID, reason: .slackPurged)])
        #expect(posted.agentTask == AgentTaskRef(id: F.taskID, state: .dispatched, agentSessionID: F.sessionID))
        // 빠진 배열 · 빠진 선택 필드는 기본값
        let minimal = #"{"message":\#(F.userMessage),"reply":null,"delivery":{"state":"queued"}}"#
        let bare = try decode(AgentPostedMessage.self, minimal)
        #expect(bare.attachmentsDropped.isEmpty && bare.createdAction == nil && bare.agentTask == nil && bare.reply == nil)
        #expect(bare.delivery.state == .queued)
    }

    @Test func createdActionAcceptsDeterministicID() throws {
        let posted = try decode(AgentPostedMessage.self, F.postResponse)
        let action = try #require(posted.createdAction)
        // 메시지 id에서 결정적으로 만든 Action id: 버전 · 변형 비트가 없어도 UUID로 읽는다
        #expect(action.id == F.deterministicActionID)
        #expect(action.number == 139 && action.title == "이어서 해 줘" && action.contextID == F.contextID)
        // 번호는 아직 없을 수 있다
        let numberless = replacing(F.postResponse, #""number":139"#, #""number":null"#)
        #expect(try decode(AgentPostedMessage.self, numberless).createdAction?.number == nil)
    }

    /// 에이전트 응답은 reply가 null이라 옛 `ChatPostedMessage`(reply 필수)로는 못 읽는다 — taskforce 응답은 그 모양 그대로다 (OD-7)
    @Test func taskforcePostedMessageStillDecodes() throws {
        let body = ChatContractFixtures.posted(clientMessageID: UUID(), memory: [])
        let posted = try decode(ChatPostedMessage.self, body)
        #expect(posted.message.role == .user && posted.reply.role == .assistant)
        #expect(throws: (any Error).self) { try decode(ChatPostedMessage.self, F.postResponse) }
    }

    @Test func unknownAttachmentDropReasonRoundTrips() throws {
        let json = replacing(F.postResponse, "slack_purged", "quota_exceeded")
        let dropped = try #require(try decode(AgentPostedMessage.self, json).attachmentsDropped.first)
        #expect(dropped.reason == .unknown("quota_exceeded") && dropped.reason.raw == "quota_exceeded")
        for raw in ["deleted", "access_lost", "slack_purged"] {
            let known = try decode(AttachmentDropped.self, #"{"kind":"run","id":"a5555555-5555-4555-8555-555555555555","reason":"\#(raw)"}"#)
            #expect(known.reason.raw == raw)
            if case .unknown = known.reason { Issue.record("\(raw)를 모르는 값으로 읽었다") }
        }
    }

    // MARK: 만들기 응답 · 대상 열

    @Test func createResponseDecodesTargetColumns() throws {
        let created = try decode(ChatCreatedConversation.self, F.createResponse)
        #expect(created.conversation.id == F.conversationID)
        #expect(created.conversation.title == nil && created.conversation.isUntouched)
        #expect(created.target == ChatConversationTarget(kind: .agent, agentConnectionID: F.connectionID, agentSessionID: nil))
        #expect(created.target.isAgent)
    }

    @Test func conversationRowWithoutTargetColumnsIsTaskforce() throws {
        let row = replacing(F.createResponse, #","target_kind":"agent","agent_connection_id":"a3333333-3333-4333-8333-333333333333","agent_session_id":null"#, "")
        let created = try decode(ChatCreatedConversation.self, row)
        #expect(created.target == .taskforce && !created.target.isAgent)
        #expect(created.target.agentConnectionID == nil)
        // 같은 열을 가진 RLS 행도 같은 모양으로 읽는다
        let target = try decode(ChatConversationTarget.self, #"{"target_kind":"agent","agent_connection_id":"a3333333-3333-4333-8333-333333333333","agent_session_id":"a4444444-4444-4444-8444-444444444444"}"#)
        #expect(target.agentSessionID == F.sessionID)
    }

    @Test func unknownTargetKindOnAConversationRowIsKeptNotCrashed() throws {
        let row = replacing(F.createResponse, #""target_kind":"agent""#, #""target_kind":"human""#)
        let created = try decode(ChatCreatedConversation.self, row)
        #expect(created.target.kind == .unknown("human") && !created.target.isAgent)
    }

    // MARK: 대상 목록

    @Test func targetsDecodeUnknownKindWithoutDroppingList() throws {
        let known = try decode(AssistantTargetsResponse.self, F.targets)
        #expect(known.targets.count == 3)
        #expect(known.targets[0] == .taskforce)
        guard case .agent(let claude) = known.targets[1], case .agent(let codex) = known.targets[2] else {
            Issue.record("에이전트 행 둘이어야 한다")
            return
        }
        #expect(claude.adapter == "agent:claude-code" && claude.displayName == "Claude Code")
        #expect(claude.connectionID == F.connectionID && claude.state == .unsupported && claude.access == nil)
        #expect(codex.adapter == "agent:codex" && codex.connectionID == nil && codex.state == .notConnected && codex.access == .readOnly)
        // 모르는 kind 한 행이 목록 전체를 못 읽게 하지 않는다
        let withFuture = replacing(F.targets, #"{"kind":"taskforce"}"#, #"{"kind":"taskforce"},{"kind":"workspace","name":"x"}"#)
        let list = try decode(AssistantTargetsResponse.self, withFuture).targets
        #expect(list.count == 4)
        #expect(list[1] == .other("workspace"))
        #expect(list[2] != .other("workspace") && list.first == .taskforce)
    }

    @Test func targetStateAndAccessUnknownValues() throws {
        let states: [(String, AgentTargetState)] = [
            ("ready", .ready), ("not_connected", .notConnected), ("sign_in_needed", .signInNeeded), ("unreachable", .unreachable), ("unsupported", .unsupported),
        ]
        for (raw, state) in states {
            let json = #"{"targets":[{"kind":"agent","adapter":"agent:codex","display_name":"Codex","connection_id":null,"state":"\#(raw)","access":"write"}]}"#
            guard case .agent(let agent) = try #require(try decode(AssistantTargetsResponse.self, json).targets.first) else {
                Issue.record("에이전트 행이어야 한다")
                return
            }
            #expect(agent.state == state, "\(raw)")
            #expect(agent.access == .write)
        }
        let future = #"{"targets":[{"kind":"agent","adapter":"agent:future","display_name":"Future","connection_id":null,"state":"hibernating","access":"admin"}]}"#
        guard case .agent(let agent) = try #require(try decode(AssistantTargetsResponse.self, future).targets.first) else {
            Issue.record("에이전트 행이어야 한다")
            return
        }
        #expect(agent.state == .unknown("hibernating") && agent.access == .unknown("admin"))
        #expect(agent.state.raw == "hibernating" && agent.access?.raw == "admin")
        #expect(agent.adapter == "agent:future", "모르는 adapter도 그대로")
    }

    // MARK: 중단 · 세션

    @Test func stopResultDecodesProcessesWarning() throws {
        let stop = try decode(AgentStopResponse.self, F.stopResponse)
        #expect(stop.tasks.count == 2)
        #expect(stop.tasks[0] == AgentStopResult(agentTaskID: F.taskID, cancel: .requestedOnly, processes: .mayContinue))
        #expect(stop.tasks[1] == AgentStopResult(agentTaskID: F.stepID, cancel: .confirmed, processes: nil))
        let future = replacing(F.stopResponse, #""cancel":"confirmed""#, #""cancel":"vanished""#)
        #expect(try decode(AgentStopResponse.self, future).tasks[1].cancel == .unknown("vanished"))
        let processes = replacing(F.stopResponse, "may_continue", "orphaned")
        #expect(try decode(AgentStopResponse.self, processes).tasks[0].processes == .unknown("orphaned"))
        #expect(try decode(AgentStopResponse.self, #"{"tasks":[]}"#).tasks.isEmpty)
    }

    @Test func sessionRowDecodesExternalAndUnknownStatus() throws {
        let session = try decode(AgentSessionResponse.self, F.session).session
        #expect(session.id == F.sessionID && session.connectionID == F.connectionID)
        #expect(session.displayName == "Pricing copy" && session.status == .external && session.lastTurnSeq == 3)
        #expect(session.updatedAt == PostgresTimestamp.parse("2026-10-14T01:00:00.000Z"))
        let paused = replacing(F.session, #""status":"external""#, #""status":"paused""#)
        #expect(try decode(AgentSessionResponse.self, paused).session.status == .unknown("paused"))
        let resume = try decode(AgentResumeResponse.self, F.resumeResponse)
        #expect(resume.startedMessageID == F.messageID && resume.session.status == .external)
        let none = replacing(F.resumeResponse, #""started_message_id":"a2222222-2222-4222-8222-222222222222""#, #""started_message_id":null"#)
        #expect(try decode(AgentResumeResponse.self, none).startedMessageID == nil)
    }

    // MARK: Send again · 답 · 전달 읽기

    @Test func deliverResultDecodesSkipped() throws {
        let response = try decode(AgentDeliverResponse.self, F.deliverResponse)
        #expect(response.messages.count == 3)
        let requeued = response.messages[0]
        #expect(requeued.result == .requeued && requeued.skippedReason == nil)
        #expect(requeued.delivery == AgentDelivery(state: .queued, reason: .sessionBusy))
        let unknownOutcome = response.messages[1]
        #expect(unknownOutcome.result == .skipped && unknownOutcome.skippedReason == .unknownOutcome)
        #expect(unknownOutcome.delivery?.state == .outcomeUnknown)
        let notFound = response.messages[2]
        #expect(notFound.skippedReason == .notFound && notFound.delivery == nil, "not_found에는 delivery가 없다")
        let future = replacing(F.deliverResponse, "unknown_outcome", "later")
        #expect(try decode(AgentDeliverResponse.self, future).messages[1].skippedReason == .unknown("later"))
    }

    @Test func deliverAndReferentRequestsEncode() throws {
        #expect(try object(AgentDeliverRequest()) == [:])
        #expect(try object(AgentDeliverRequest(messageIDs: [F.messageID])) == ["message_ids": [F.messageID.uuidString.lowercased()]])
        #expect(try object(AgentReferentRequest(actionID: F.deterministicActionID)) == ["action_id": "f0000000-0000-f000-f000-000000000001"])
    }

    @Test func answerRequestEncodesSingleAndMultiple() throws {
        let request = AgentAnswerRequest(providerRequestID: "q-1", answers: ["a": .text("x"), "b": .choices(["y", "z"])])
        let body = try object(request)
        #expect(body["provider_request_id"] as? String == "q-1")
        let answers = try #require(body["answers"] as? NSDictionary)
        #expect(answers["a"] as? String == "x")
        #expect(answers["b"] as? [String] == ["y", "z"])
        let response = try decode(AgentAnswerResponse.self, F.answerResponse)
        #expect(response.status == .answered && response.stepID == F.deterministicActionID)
        let duplicate = replacing(F.answerResponse, "answered", "duplicate")
        #expect(try decode(AgentAnswerResponse.self, duplicate).status == .duplicate)
        let future = replacing(F.answerResponse, "answered", "stale")
        #expect(try decode(AgentAnswerResponse.self, future).status == .unknown("stale"))
    }

    @Test func deliveryReadDecodesPerMessageDelivery() throws {
        let read = try decode(ConversationDeliveryResponse.self, F.deliveryRead)
        #expect(read.messages.map(\.seq) == [1, 2])
        #expect(read.messages[0].messageID == F.messageID && read.messages[0].delivery.state == .accepted)
        #expect(read.messages[1].delivery == AgentDelivery(state: .notSent, reason: .usageLimited))
    }

    // MARK: 오류 코드

    @Test func errorCodesDecodeFromTheErrorBody() throws {
        let known: [(String, AgentConversationErrorCode)] = [
            ("target_mismatch", .targetMismatch), ("question_stale", .questionStale), ("secret_requires_local", .secretRequiresLocal),
            ("session_busy", .sessionBusy), ("approval_via_review", .approvalViaReview), ("busy_retry", .busyRetry),
        ]
        for (raw, code) in known {
            let body = try AgentConversationErrorBody(data: Data(#"{"error":{"code":"\#(raw)","message":"m"}}"#.utf8))
            #expect(body.code == code && code.raw == raw, "\(raw)")
        }
        #expect(known.count == 6)
        let future = try AgentConversationErrorBody(data: Data(#"{"error":{"code":"quota_gone","message":"그만"}}"#.utf8))
        #expect(future.code == .unknown("quota_gone") && future.error.message == "그만")
        // 기존 v2 코드는 이 목록이 아니다 — 모르는 값으로 읽힌다 (`APIErrorCode`가 안다)
        #expect(try AgentConversationErrorBody(data: Data(#"{"error":{"code":"conflict","message":"x"}}"#.utf8)).code == .unknown("conflict"))
    }

    // MARK: 요청 (경로 · 본문)

    private func client(status: Int = 200, body: String = "{}") -> (APIClient, String) {
        let host = "t\(UUID().uuidString.lowercased().prefix(8)).test"
        StubProtocol.register(host: host, reply: .init(status: status, body: body))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return (APIClient(baseURL: URL(string: "https://\(host)")!, session: URLSession(configuration: configuration), token: { "token-123" }), host)
    }

    private func json(_ data: Data?) throws -> NSDictionary {
        let body = try #require(data)
        return try #require(try JSONSerialization.jsonObject(with: body) as? NSDictionary)
    }

    @Test func targetsAreReadFromTheV2AssistantRoute() async throws {
        let (api, host) = client(body: F.targets)
        let response = try await api.assistantTargets()
        #expect(response.targets.count == 3)
        let sent = try #require(StubProtocol.requests(host: host).last)
        #expect(sent.method == "GET" && sent.url.path == "/api/v2/assistant/targets")
        #expect(sent.headers["Authorization"] == "Bearer token-123")
    }

    @Test func aConversationWithATargetCarriesTheTargetAndKeepsTheOldFields() async throws {
        let (api, host) = client(status: 201, body: F.createResponse)
        let created = try await api.createConversation(id: F.conversationID, title: nil, contextID: nil, target: .agent(connectionID: F.connectionID))
        #expect(created.target.agentConnectionID == F.connectionID)
        let sent = try #require(StubProtocol.requests(host: host).last)
        #expect(sent.method == "POST" && sent.url.path == "/api/v2/conversations")
        #expect(try json(sent.body) == [
            "id": F.conversationID.uuidString.lowercased(), "context_id": NSNull(),
            "target": ["kind": "agent", "connection_id": F.connectionID.uuidString.lowercased()],
        ])
        _ = try await api.createConversation(id: F.conversationID, title: "Pricing", contextID: F.contextID, target: .taskforce)
        let again = try #require(StubProtocol.requests(host: host).last)
        #expect(try json(again.body) == [
            "id": F.conversationID.uuidString.lowercased(), "title": "Pricing", "context_id": F.contextID.uuidString.lowercased(), "target": ["kind": "taskforce"],
        ])
    }

    /// 에이전트 대상은 reply가 null이다. 칩이 없으면 `attachments` 키를 보내지 않고, `refs`는 어느 경우에도 보내지 않는다 (함께 보내면 서버 400)
    @Test func anAgentMessageSendsChipsAsAttachmentsAndNeverRefs() async throws {
        let (api, host) = client(body: F.postResponse)
        let chip = ChatAttachment(kind: .action, id: F.deterministicActionID, origin: .added)
        let posted = try await api.postAgentMessage(conversationID: F.conversationID, clientMessageID: F.secondID, text: "이어서 해 줘", attachments: [chip])
        #expect(posted.reply == nil && posted.delivery.state == .sent)
        let sent = try #require(StubProtocol.requests(host: host).last)
        #expect(sent.method == "POST" && sent.url.path == "/api/v2/conversations/\(F.conversationID.uuidString.lowercased())/messages")
        #expect(try json(sent.body) == [
            "client_message_id": F.secondID.uuidString.lowercased(), "text": "이어서 해 줘",
            "attachments": [["kind": "action", "id": "f0000000-0000-f000-f000-000000000001", "origin": "added"]],
        ])
        #expect(try json(sent.body)["refs"] == nil)
        _ = try await api.postAgentMessage(conversationID: F.conversationID, clientMessageID: F.secondID, text: "x", attachments: [])
        let bare = try #require(StubProtocol.requests(host: host).last)
        #expect(try json(bare.body).allKeys.compactMap { $0 as? String }.sorted() == ["client_message_id", "text"])
    }

    @Test func aTaskforceMessageWithChipsKeepsTheOldReplyShapeAndTheLongTimeout() async throws {
        let cmid = UUID()
        let (api, host) = client(body: ChatContractFixtures.posted(clientMessageID: cmid))
        let chip = ChatAttachment(kind: .context, id: F.contextID, origin: .auto)
        let posted = try await api.postChatMessage(conversationID: F.conversationID, clientMessageID: cmid, text: "Use the shorter FAQ", attachments: [chip])
        #expect(posted.reply.role == .assistant)
        let sent = try #require(StubProtocol.requests(host: host).last)
        #expect(sent.timeout == APIClient.chatTimeout)
        let attachments = try #require(try json(sent.body)["attachments"] as? [NSDictionary])
        #expect(attachments == [["kind": "context", "id": F.contextID.uuidString.lowercased(), "origin": "auto"]])
        // 칩 없는 옛 호출은 그대로 칩 키가 없다
        _ = try await api.postChatMessage(conversationID: F.conversationID, clientMessageID: cmid, text: "Use the shorter FAQ")
        let old = try #require(StubProtocol.requests(host: host).last)
        #expect(try json(old.body)["attachments"] == nil)
    }
}
