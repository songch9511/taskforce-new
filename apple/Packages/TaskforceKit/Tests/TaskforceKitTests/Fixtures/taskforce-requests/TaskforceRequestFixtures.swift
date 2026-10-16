import Foundation
@testable import TaskforceKit

// OA U3: 서버 시험 `tests/review/review-agents-contract.test.ts`(마지막 변경 커밋 e27403458ad859476dab24fb7485eb555a14b99d, 파일 blob dc7c73e680ad29d80a5caf6edf6d4fabda346d6c)의
// `REVIEW_WITH_AGENTS_JSON` · `RESOLVE_*`를 그대로 옮긴 JSON이다 (서버가 내리는 모양 그대로). 한쪽을 고치면 서버 문서 `docs/review-summary.md`의 JSON 계약 절도 함께 고친다.
// 응답에는 글이 없다: 질문 글 · 경로 · 이슈 번호는 앱이 RLS로 읽는다.
enum TaskforceRequestFixtures {
    /// GET /api/v2/review — 다섯 종류가 서버 순서로 든 응답 (긴급 → 오래 기다린 순 → 종류)
    static let review = #"""
{"generated_at":"2026-10-15T02:00:00.000Z","complete":true,"empty":false,"sources":{"decisions":"ok","suggestions":"ok","time_zone":"ok"},"decisions":[{"key":"a0000000-0000-4000-8000-000000000001:agent_approval","action_id":"a0000000-0000-4000-8000-000000000001","kind":"agent_approval","urgent":true,"version":"0123456789abcdef","created_at":"2026-10-15T01:00:00.000Z","items":[{"id":"agent_approval:b0000000-0000-4000-8000-000000000001","kind":"agent_approval","action_id":"a0000000-0000-4000-8000-000000000001","run_id":"d0000000-0000-4000-8000-000000000001","step_id":null,"question_id":null,"version":"question:b0000000-0000-4000-8000-000000000001:toolu-req-1","urgent":true,"urgent_reason":null,"created_at":"2026-10-15T01:00:00.000Z","agent":{"task_id":"b0000000-0000-4000-8000-000000000001","session_id":"5e000000-0000-4000-8000-000000000001","provider_request_id":"toolu-req-1","adapter":"agent:codex","bridge_id":"b1000000-0000-4000-8000-000000000001"}}]},{"key":"a0000000-0000-4000-8000-000000000002:agent_question","action_id":"a0000000-0000-4000-8000-000000000002","kind":"agent_question","urgent":false,"version":"0123456789abcdef","created_at":"2026-10-15T01:00:00.000Z","items":[{"id":"agent_question:b0000000-0000-4000-8000-000000000001","kind":"agent_question","action_id":"a0000000-0000-4000-8000-000000000002","run_id":"d0000000-0000-4000-8000-000000000001","step_id":null,"question_id":null,"version":"question:b0000000-0000-4000-8000-000000000001:toolu-req-1","urgent":false,"urgent_reason":null,"created_at":"2026-10-15T01:00:00.000Z","agent":{"task_id":"b0000000-0000-4000-8000-000000000001","session_id":"5e000000-0000-4000-8000-000000000001","provider_request_id":"toolu-req-1","adapter":"agent:claude-code","bridge_id":"b1000000-0000-4000-8000-000000000001"}}]},{"key":"a0000000-0000-4000-8000-000000000003:agent_secret_question","action_id":"a0000000-0000-4000-8000-000000000003","kind":"agent_secret_question","urgent":false,"version":"0123456789abcdef","created_at":"2026-10-15T01:00:00.000Z","items":[{"id":"agent_secret_question:b0000000-0000-4000-8000-000000000001","kind":"agent_secret_question","action_id":"a0000000-0000-4000-8000-000000000003","run_id":"d0000000-0000-4000-8000-000000000001","step_id":null,"question_id":null,"version":"question:b0000000-0000-4000-8000-000000000001:toolu-req-2","urgent":false,"urgent_reason":null,"created_at":"2026-10-15T01:00:00.000Z","agent":{"task_id":"b0000000-0000-4000-8000-000000000001","session_id":"5e000000-0000-4000-8000-000000000001","provider_request_id":"toolu-req-1","adapter":"agent:claude-code","bridge_id":null}}]},{"key":"a0000000-0000-4000-8000-000000000004:result_ready","action_id":"a0000000-0000-4000-8000-000000000004","kind":"result_ready","urgent":false,"version":"0123456789abcdef","created_at":"2026-10-15T01:00:00.000Z","items":[{"id":"result_ready:d0000000-0000-4000-8000-000000000001","kind":"result_ready","action_id":"a0000000-0000-4000-8000-000000000004","run_id":"d0000000-0000-4000-8000-000000000001","step_id":null,"question_id":null,"version":"result:d0000000-0000-4000-8000-000000000001:0:3:2","urgent":false,"urgent_reason":null,"created_at":"2026-10-15T01:00:00.000Z","result":{"session_id":"5e000000-0000-4000-8000-000000000001","reviewed_turn_seq":0,"last_turn_seq":3,"changed_at":"2026-10-15T01:00:00.000Z"}}]},{"key":"a0000000-0000-4000-8000-000000000005:path_conflict","action_id":"a0000000-0000-4000-8000-000000000005","kind":"path_conflict","urgent":false,"version":"0123456789abcdef","created_at":"2026-10-15T01:00:00.000Z","items":[{"id":"path_conflict:c0000000-0000-4000-8000-000000000001","kind":"path_conflict","action_id":"a0000000-0000-4000-8000-000000000005","run_id":"d0000000-0000-4000-8000-000000000001","step_id":null,"question_id":null,"version":"conflict:c0000000-0000-4000-8000-000000000001:2","urgent":false,"urgent_reason":null,"created_at":"2026-10-15T01:00:00.000Z","conflict":{"lease_id":"c0000000-0000-4000-8000-000000000001","conflict_version":2,"holder_action_id":"a0000000-0000-4000-8000-000000000006","holder_run_id":"d0000000-0000-4000-8000-000000000001","later_run_id":"d0000000-0000-4000-8000-000000000001","released":false,"stopped":true}}]},{"key":"a0000000-0000-4000-8000-000000000007:confirm","action_id":"a0000000-0000-4000-8000-000000000007","kind":"confirm","urgent":false,"version":"0123456789abcdef","created_at":"2026-10-15T01:00:00.000Z","items":[{"id":"confirm:a0000000-0000-4000-8000-000000000007","kind":"confirm","action_id":"a0000000-0000-4000-8000-000000000007","run_id":null,"step_id":null,"question_id":null,"version":"action:a0000000-0000-4000-8000-000000000007:3","urgent":false,"urgent_reason":null,"created_at":"2026-10-15T01:00:00.000Z"}]}],"suggestions":[],"suggestion_batch":{"state":"ready","local_day":"2026-10-15","size":3}}
"""#

    /// POST /api/v2/path-conflicts/{lease_id}/resolve
    static let resolveRequest = #"""
{"keep":"holder","conflict_version":2}
"""#
    static let resolveResponse = #"""
{"status":"resolved"}
"""#
    static let resolveStale409 = #"""
{"error":{"code":"conflict","message":"그 사이 충돌이 바뀌었거나 이미 해소됐습니다. 다시 불러온 뒤 시도해 주세요."}}
"""#

    // 서버 시험의 id (`A(n)` · TASK · RUN · LEASE · SESSION)
    static func action(_ n: Int) -> UUID { UUID(uuidString: "a0000000-0000-4000-8000-" + String(format: "%012d", n))! }
    static let run = UUID(uuidString: "d0000000-0000-4000-8000-000000000001")!
    static let lease = UUID(uuidString: "c0000000-0000-4000-8000-000000000001")!
    static let session = UUID(uuidString: "5e000000-0000-4000-8000-000000000001")!

    static func decode(_ json: String) throws -> TaskforceReviewResponse {
        try TaskforceJSON.decoder().decode(TaskforceReviewResponse.self, from: Data(json.utf8))
    }
}
