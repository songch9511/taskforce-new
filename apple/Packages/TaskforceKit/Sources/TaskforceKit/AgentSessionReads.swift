import Foundation
import Supabase

// OA U2: 세션 읽기 (RLS select만, 새 서버 읽기 route 없음). 다섯 표를 열 목록대로 읽는다 (`AgentSessionModels.swift`의 `columns`).
// 질문 글(`pending_question`)과 결과(`result_refs`)는 읽지 않는다. 읽은 이름 · 대화 id는 사용자 글이라 메모리에만 둔다.
// 쓰기(이름 · Open in Terminal · Resume here · Stop)는 `AgentSessionEndpoints.swift`다.

extension TaskforceReads {
    /// 한 번에 읽는 세션의 최대 수 (최근에 바뀐 것부터)
    static let agentSessionLimit = 200
    /// `in (…)`으로 묶는 세션 id 수
    private static let agentSessionIDChunk = 100
    /// 마지막 턴의 task를 `or(…)` 한 요청으로 묻는 세션 수 (URL이 길어지지 않게)
    static let agentTaskFilterChunk = 25

    /// 세션 · 연결 · 대화 run · 마지막 턴의 task · 대화를 읽는다
    public func agentSessionSnapshot() async throws -> AgentSessionSnapshot {
        let sessions: [AgentSessionRecord] = try await rows(
            supabase.from("agent_sessions").select(AgentSessionRecord.columns)
                .order("updated_at", ascending: false).order("id", ascending: false).limit(Self.agentSessionLimit)
        )
        return try await snapshot(of: sessions)
    }

    /// 그 세션들만 좁게 읽는다 (OA D4a-13b): Assistant 창이 열린 에이전트 대화의 세션. 연결은 같은 표라 그대로 읽는다 (에이전트 이름 · 이 Mac의 세션인지)
    public func agentSessionSnapshot(sessionIDs: Set<UUID>) async throws -> AgentSessionSnapshot {
        guard !sessionIDs.isEmpty else { return .empty }
        var sessions: [AgentSessionRecord] = []
        for chunk in Self.chunks(Array(sessionIDs).sorted { $0.uuidString < $1.uuidString }, size: Self.agentSessionIDChunk) {
            sessions += try await rows(
                supabase.from("agent_sessions").select(AgentSessionRecord.columns).in("id", values: chunk.map(\.lowercased))
                    .order("updated_at", ascending: false).order("id", ascending: false)
            )
        }
        return try await snapshot(of: sessions)
    }

    private func snapshot(of sessions: [AgentSessionRecord]) async throws -> AgentSessionSnapshot {
        async let connectionRows: [AgentConnectionRecord] = rows(
            supabase.from("agent_connections").select(AgentConnectionRecord.columns).order("created_at", ascending: true).limit(200)
        )
        let ids = sessions.map(\.id)
        async let runRows = conversationRuns(sessionIDs: ids)
        async let taskRows = lastTurnTasks(of: sessions)
        async let conversationRows = sessionConversations(sessionIDs: ids)
        return AgentSessionSnapshot(
            sessions: sessions, tasks: try await taskRows, runs: try await runRows, connections: try await connectionRows,
            conversations: try await conversationRows
        )
    }

    /// 세션들의 대화 run (`kind = 'conversation'`): 세션 ↔ 이슈. 오래된 것이 먼저
    private func conversationRuns(sessionIDs: [UUID]) async throws -> [AgentSessionRunRecord] {
        var result: [AgentSessionRunRecord] = []
        for chunk in Self.chunks(sessionIDs, size: Self.agentSessionIDChunk) {
            var offset = 0
            while true {
                let page: [AgentSessionRunRecord] = try await rows(
                    supabase.from("execution_runs").select(AgentSessionRunRecord.columns)
                        .eq("kind", value: AgentSessionRunRecord.conversationKind).in("agent_session_id", values: chunk.map(\.lowercased))
                        .order("created_at", ascending: true).order("id", ascending: true)
                        .range(from: offset, to: offset + Self.chatPageSize - 1)
                )
                result.append(contentsOf: page)
                guard page.count == Self.chatPageSize else { break }
                offset += page.count
            }
        }
        return result
    }

    /// 세션마다 마지막 턴(`turn_seq == last_turn_seq`)의 task 하나. 턴이 없는 세션(`last_turn_seq` 0)은 묻지 않는다
    private func lastTurnTasks(of sessions: [AgentSessionRecord]) async throws -> [AgentTaskRecord] {
        var result: [AgentTaskRecord] = []
        for filter in Self.lastTurnFilters(sessions) {
            let page: [AgentTaskRecord] = try await rows(supabase.from("agent_tasks").select(AgentTaskRecord.columns).or(filter))
            result.append(contentsOf: page)
        }
        return result
    }

    /// 세션들의 대화 (새 것이 먼저)
    private func sessionConversations(sessionIDs: [UUID]) async throws -> [AgentSessionConversationRecord] {
        var result: [AgentSessionConversationRecord] = []
        for chunk in Self.chunks(sessionIDs, size: Self.agentSessionIDChunk) {
            let page: [AgentSessionConversationRecord] = try await rows(
                supabase.from("conversations").select(AgentSessionConversationRecord.columns)
                    .in("agent_session_id", values: chunk.map(\.lowercased)).filter("archived_at", operator: "is", value: "null")
                    .order("created_at", ascending: false).order("id", ascending: false)
            )
            result.append(contentsOf: page)
        }
        // 청크 사이의 순서는 의미가 없다: 한 세션의 대화는 한 청크에 있다
        return result
    }

    /// PostgREST `or` 조건: `and(agent_session_id.eq.<id>,turn_seq.eq.<n>)`을 세션마다, 25개씩 한 줄로
    static func lastTurnFilters(_ sessions: [AgentSessionRecord]) -> [String] {
        let withTurns = sessions.filter { $0.lastTurnSeq >= 1 }
        return chunks(withTurns, size: agentTaskFilterChunk).map { chunk in
            chunk.map { "and(agent_session_id.eq.\($0.id.lowercased),turn_seq.eq.\($0.lastTurnSeq))" }.joined(separator: ",")
        }
    }

    private static func chunks<T>(_ values: [T], size: Int) -> [[T]] {
        stride(from: 0, to: values.count, by: size).map { Array(values[$0..<min($0 + size, values.count)]) }
    }
}

extension TaskforceReads: AgentSessionGateway {}
