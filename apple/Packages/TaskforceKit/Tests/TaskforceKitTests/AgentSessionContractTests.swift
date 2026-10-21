import Foundation
import Testing
@testable import TaskforceKit

/// 세션 읽기 열 목록과 행 디코딩 (U2-35, 계약 3.1 ③). 모양은 마이그레이션 `20261113000000_agent_gateway_core.sql`의 표다 (서버 head 12520ad).
/// 사용자 글(질문 · 결과)은 읽지 않는다: `pending_question` · `result_refs`가 열 목록에 없다
struct AgentSessionContractTests {
    typealias Fx = SessionFx

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try TaskforceJSON.decoder().decode(type, from: Data(json.utf8))
    }

    // MARK: 열 목록

    @Test func theColumnListsAreExactlyWhatTheScreensNeed() {
        #expect(AgentSessionRecord.columns == "id, connection_id, display_name, status, external_session_id, last_turn_seq, created_at, updated_at")
        #expect(AgentTaskRecord.columns == "agent_session_id, run_id, turn_seq, state, last_live_state, cancel_requested_at, last_event_seq", "대화 글을 다시 읽을 때를 정하는 값싼 신호: 마지막 반영 사건 순서 하나를 더 읽는다")
        #expect(AgentSessionRunRecord.columns == "id, kind, agent_session_id, action_id")
        #expect(AgentConnectionRecord.columns == "id, adapter, bridge_id", "D4a-03: 알약은 그 세션 연결의 bridge가 이 Mac일 때만 — `bridge_id` 열 하나를 더 읽는다")
        #expect(AgentSessionConversationRecord.columns == "id, agent_session_id")
    }

    @Test func noColumnListReadsAUserTextColumn() {
        let all = [
            AgentSessionRecord.columns, AgentTaskRecord.columns, AgentSessionRunRecord.columns, AgentConnectionRecord.columns,
            AgentSessionConversationRecord.columns,
        ].joined(separator: ", ")
        for forbidden in ["pending_question", "result_refs", "answered_question", "workspace_ref", "device_ref", "text"] {
            #expect(!all.contains(forbidden), "\(forbidden)는 읽지 않는다")
        }
    }

    // MARK: 행

    private let sessionRow = """
    {"id":"5e5e5e5e-0000-4000-8000-000000000001","connection_id":"c0c0c0c0-0000-4000-8000-000000000001","display_name":"Pricing copy draft","status":"bound",
     "external_session_id":"abc123","last_turn_seq":3,"created_at":"2026-10-14T01:00:00.123456+00:00","updated_at":"2026-10-14T02:00:00.5+00:00"}
    """

    @Test func aSessionRowDecodesAndKeepsOnlyWhetherTheFirstTurnIsPending() throws {
        let row = try decode(AgentSessionRecord.self, sessionRow)
        #expect(row.displayName == "Pricing copy draft" && row.status == .bound && row.lastTurnSeq == 3 && !row.isPendingFirstTurn)
        let pending = try decode(AgentSessionRecord.self, sessionRow.replacingOccurrences(of: "abc123", with: "pending:a1111111-1111-4111-8111-111111111111"))
        #expect(pending.isPendingFirstTurn)
    }

    @Test func anExternalStatusAndAnUnknownStatusBothDecode() throws {
        #expect(try decode(AgentSessionRecord.self, sessionRow.replacingOccurrences(of: #""status":"bound""#, with: #""status":"external""#)).status == .external)
        #expect(try decode(AgentSessionRecord.self, sessionRow.replacingOccurrences(of: #""status":"bound""#, with: #""status":"hibernating""#)).status == .unknown("hibernating"))
    }

    @Test func anEmptyNameIsReadAsEmptyNotAsAnError() throws {
        #expect(try decode(AgentSessionRecord.self, sessionRow.replacingOccurrences(of: "Pricing copy draft", with: "")).displayName == "")
    }

    @Test func aTaskRowDecodesItsStatesAndTheStopRequest() throws {
        let json = """
        {"agent_session_id":"5e5e5e5e-0000-4000-8000-000000000001","run_id":"7a7a7a7a-0000-4000-8000-000000000001","turn_seq":2,"state":"unreachable",
         "last_live_state":"running","cancel_requested_at":"2026-10-14T02:00:00.000000+00:00","last_event_seq":17}
        """
        let task = try decode(AgentTaskRecord.self, json)
        #expect(task.state == .unreachable && task.lastLiveState == .running && task.cancelRequestedAt != nil && task.turnSeq == 2 && task.isOpen && task.lastEventSeq == 17)
        let future = try decode(AgentTaskRecord.self, json.replacingOccurrences(of: #""state":"unreachable""#, with: #""state":"teleporting""#))
        #expect(future.state == .unknown("teleporting") && !future.isOpen)
        let plain = try decode(AgentTaskRecord.self, #"{"agent_session_id":"5e5e5e5e-0000-4000-8000-000000000001","run_id":"7a7a7a7a-0000-4000-8000-000000000001","turn_seq":null,"state":"idle","last_live_state":null,"cancel_requested_at":null}"#)
        #expect(plain.turnSeq == nil && plain.state == .idle && plain.cancelRequestedAt == nil && !plain.isOpen && plain.lastEventSeq == nil, "열이 없는 읽기(옛 픽스처)는 nil")
    }

    @Test func aRunRowTiesASessionToAnIssueAndTheOtherRowsDecode() throws {
        let run = try decode(AgentSessionRunRecord.self, #"{"id":"7a7a7a7a-0000-4000-8000-000000000001","kind":"conversation","agent_session_id":"5e5e5e5e-0000-4000-8000-000000000001","action_id":"a0000000-0000-4000-8000-000000000001"}"#)
        #expect(run.kind == "conversation" && run.agentSessionID == UUID(uuidString: "5e5e5e5e-0000-4000-8000-000000000001"))
        #expect(run.actionID == UUID(uuidString: "a0000000-0000-4000-8000-000000000001"))
        let orphan = try decode(AgentSessionRunRecord.self, #"{"id":"7a7a7a7a-0000-4000-8000-000000000001","kind":"task","agent_session_id":null,"action_id":"a0000000-0000-4000-8000-000000000001"}"#)
        #expect(orphan.agentSessionID == nil && orphan.kind == "task")
        let connection = try decode(AgentConnectionRecord.self, #"{"id":"c0c0c0c0-0000-4000-8000-000000000001","adapter":"agent:claude-code"}"#)
        #expect(connection.adapter == "agent:claude-code")
        let conversation = try decode(AgentSessionConversationRecord.self, #"{"id":"d0d0d0d0-0000-4000-8000-000000000001","agent_session_id":"5e5e5e5e-0000-4000-8000-000000000001"}"#)
        #expect(conversation.agentSessionID.uuidString.lowercased() == "5e5e5e5e-0000-4000-8000-000000000001")
    }

    // MARK: 마지막 턴 조건

    @Test func theLastTurnFilterAsksOneAndPerSessionWithItsLastTurn() {
        let sessions = [Fx.session(1, turn: 3), Fx.session(2, turn: 1)]
        let filters = TaskforceReads.lastTurnFilters(sessions)
        #expect(filters.count == 1)
        #expect(filters[0] == "and(agent_session_id.eq.\(Fx.id(1).uuidString.lowercased()),turn_seq.eq.3),and(agent_session_id.eq.\(Fx.id(2).uuidString.lowercased()),turn_seq.eq.1)")
    }

    @Test func sessionsWithoutATurnAreNotAsked() {
        #expect(TaskforceReads.lastTurnFilters([Fx.session(1, turn: 0)]).isEmpty)
        #expect(TaskforceReads.lastTurnFilters([]).isEmpty)
    }

    @Test func theFilterSplitsEveryTwentyFiveSessionsSoTheUrlStaysShort() {
        let sessions = (1...60).map { Fx.session($0, turn: 2) }
        let filters = TaskforceReads.lastTurnFilters(sessions)
        #expect(filters.count == 3 && TaskforceReads.agentTaskFilterChunk == 25)
        #expect(filters.map { $0.components(separatedBy: "),and(").count } == [25, 25, 10])
        #expect(filters.allSatisfy { $0.utf8.count < 3_000 })
    }

    @Test func theSessionReadIsBoundedToTheNewestTwoHundred() {
        #expect(TaskforceReads.agentSessionLimit == 200)
    }
}
