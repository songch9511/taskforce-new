import Foundation

/// 세션 route 네 개(OA D1d)의 JSON 모양. 서버 시험(`src/app/api/v2/agent-sessions/[id]/**/route.test.ts`)이 이 모양의 응답을 단언한다:
/// - `[id]/route.test.ts` sha1 63268af56dec (PATCH 이름 바꾸기: 본문 `{display_name}` trim · 응답 `{session}`)
/// - `[id]/open-external/route.test.ts` sha1 018ba21073a6 (POST `{}` · 200 `{session}` external · 409 `session_busy`)
/// - `[id]/resume-here/route.test.ts` sha1 0d9006194fa0 (POST `{confirmed_terminal_closed:true}` · 200 `{session, started_message_id}` · 확인 없으면 400)
/// - `[id]/stop/route.test.ts` sha1 0f3d2eb8a5d3 (POST `{}` · 200 `{tasks:[{agent_task_id, cancel, processes?}]}`)
/// - 계약 `src/lib/api/contract.ts` `agentSessionSchema` · `updateAgentSessionRequestSchema`(trim 1–200) · `resumeAgentSessionRequestSchema`(`z.literal(true)`) · `agentStopResponseSchema`, 서버 head 12520ad
/// 서버 쪽이 바뀌면 이 파일을 다시 복사한다. 아이디 · 값은 서버 시험의 상수 그대로다
enum AgentSessionFixtures {
    static let sessionID = UUID(uuidString: "5e5e5e5e-0000-4000-8000-000000000001")!
    static let connectionID = UUID(uuidString: "c0c0c0c0-0000-4000-8000-000000000001")!
    static let taskID = UUID(uuidString: "7a7a7a7a-0000-4000-8000-000000000001")!
    static let startedMessageID = UUID(uuidString: "dddddddd-0000-4000-8000-000000000001")!

    private static func session(name: String, status: String, turn: Int) -> String {
        #"{"id":"5e5e5e5e-0000-4000-8000-000000000001","connection_id":"c0c0c0c0-0000-4000-8000-000000000001","display_name":"\#(name)","status":"\#(status)","last_turn_seq":\#(turn),"updated_at":"2026-10-14T01:00:00.000Z"}"#
    }

    /// PATCH 200
    static let renamed = #"{"session":\#(session(name: "Pricing", status: "bound", turn: 1))}"#
    /// open-external 200
    static let openedExternal = #"{"session":\#(session(name: "Pricing", status: "external", turn: 1))}"#
    /// resume-here 200
    static let resumed = #"{"session":\#(session(name: "Pricing", status: "bound", turn: 2)),"started_message_id":"dddddddd-0000-4000-8000-000000000001"}"#
    /// resume-here 200 (대기 메시지가 없었다)
    static let resumedWithoutMessage = #"{"session":\#(session(name: "Pricing", status: "bound", turn: 2)),"started_message_id":null}"#
    /// stop 200: 요청만 됐고 명령이 남을 수 있다 (Codex)
    static let stoppedRequestedOnly = #"{"tasks":[{"agent_task_id":"7a7a7a7a-0000-4000-8000-000000000001","cancel":"requested_only","processes":"may_continue"}]}"#
    /// stop 200: 확인됐다
    static let stoppedConfirmed = #"{"tasks":[{"agent_task_id":"7a7a7a7a-0000-4000-8000-000000000001","cancel":"confirmed"}]}"#
    /// 모르는 값이 섞인 stop 200 (서버가 새 값을 더해도 읽는다)
    static let stoppedFuture = #"{"tasks":[{"agent_task_id":"7a7a7a7a-0000-4000-8000-000000000001","cancel":"someday","processes":"mystery"}]}"#
    /// 모르는 세션 상태가 온 200
    static let futureStatus = #"{"session":\#(session(name: "Pricing", status: "hibernating", turn: 1))}"#

    /// 409 `session_busy` (open-external: 턴이 돌거나 답을 기다린다)
    static let sessionBusy = #"{"error":{"code":"session_busy","message":"에이전트가 일하고 있거나 답을 기다리고 있습니다."}}"#
    /// 409 `conflict` (resume-here: 터미널에서 열린 세션이 아니다 · open-external: 첫 턴 전)
    static let conflict = #"{"error":{"code":"conflict","message":"터미널에서 열린 세션이 아닙니다."}}"#
    /// 409 `busy_retry` (잠금 경합: 쓰기 0, 같은 요청을 다시 보내도 된다)
    static let busyRetry = #"{"error":{"code":"busy_retry","message":"잠시 뒤 다시 시도해 주세요."}}"#
    /// 404 (세션 없음 · gate 꺼짐 · adapter 꺼짐)
    static let notFound = #"{"error":{"code":"not_found","message":"세션이 없습니다."}}"#
}
