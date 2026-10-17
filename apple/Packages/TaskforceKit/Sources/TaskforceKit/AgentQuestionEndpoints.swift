import Foundation
import Supabase

// OA D4b-m-1: 질문 읽기(RLS select만, 새 서버 읽기 route 없음)와 답 요청(`POST /api/v2/agent-tasks/{id}/answer`). 서버 변경은 없다 — 모두 main에 있다.
// 읽은 질문 글 · 선택지는 사용자 데이터라 메모리에만 두고 로그 · 디스크에 남기지 않는다. 서버의 한국어 거절 문구는 화면에 쓰지 않는다 (코드로 가른다: `AgentQuestionAnswerResult`).

extension APIClient {
    /// 질문에 답한다: 질문 id마다 글 하나(2000자까지) 또는 선택지 배열(다중, 10개까지) — 한 요청에 모든 답. 승인은 `{"approval": "allow" | "deny"}`.
    /// 같은 답을 다시 보내면 서버가 `duplicate`로 모은다. 비밀값이 섞인 질문은 409 `secret_requires_local`이다 (값은 서버로 오지 않는다: 이 Mac에서 `answer-local`로 간다, D4b-m-2).
    /// Bearer 인증이라 CSRF 대상이 아니다
    public func answerAgentQuestion(taskID: UUID, _ request: AgentAnswerRequest) async throws -> AgentAnswerResponse {
        try await send(.post, "agent-tasks/\(taskID.lowercased)/answer", body: request, version: .v2)
    }
}

/// `bridges` 행 중 Mac 이름 (열 권한 `id` · `device_name`)
private struct BridgeNameRow: Decodable {
    let deviceName: String?

    enum CodingKeys: String, CodingKey {
        case deviceName = "device_name"
    }
}

extension TaskforceReads {
    /// `in (…)`으로 묶는 세션 id 수 (URL이 길어지지 않게)
    static let questionSessionChunk = 100

    /// 그 세션들의 열린 질문 (`state = 'awaiting_answer'`인 task). 세션마다 task 하나뿐이지만 서버 순서에 기대지 않는다.
    /// 모양이 깨진 행도 돌려준다 (`isMalformed`): 한 행이 다른 세션의 읽기를 막지 않는다
    public func openQuestions(sessionIDs: Set<UUID>) async throws -> [AgentQuestionRecord] {
        guard !sessionIDs.isEmpty else { return [] }
        let ordered = sessionIDs.sorted { $0.uuidString < $1.uuidString }
        var result: [AgentQuestionRecord] = []
        for start in stride(from: 0, to: ordered.count, by: Self.questionSessionChunk) {
            let chunk = ordered[start..<min(start + Self.questionSessionChunk, ordered.count)]
            let page: [AgentQuestionRecord] = try await rows(
                supabase.from("agent_tasks").select(AgentQuestionRecord.columns).eq("state", value: "awaiting_answer")
                    .in("agent_session_id", values: chunk.map(\.lowercased))
            )
            result.append(contentsOf: page)
        }
        return result
    }

    /// 그 Mac의 이름 (`bridges.device_name`). 이름이 없거나(null) 행이 없으면 nil — 화면이 대체 문구를 쓴다
    public func bridgeDeviceName(id: UUID) async throws -> String? {
        let found: [BridgeNameRow] = try await rows(supabase.from("bridges").select("id, device_name").eq("id", value: id.lowercased).limit(1))
        return found.first?.deviceName
    }
}
