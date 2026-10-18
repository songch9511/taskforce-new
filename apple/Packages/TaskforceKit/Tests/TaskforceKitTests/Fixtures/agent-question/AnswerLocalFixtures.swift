import Foundation

/// `POST /api/v1/bridge/answer-local` 기준 JSON (OA D4b-m-2). 서버 `src/lib/bridge/answer-local.contract.test.ts`의 `ANSWER_LOCAL_REQUEST_JSON`을 그대로 옮겼다
/// (원본 git blob `763202c8781fd34df849f6f207c90608bf18226b`, base `e330058`): 서버가 이 값이 바뀌면 이 파일도 같이 고친다.
/// 요청은 키 셋뿐이고, 알려진 `provider_request_id` 둘의 digest 중 둘째는 UTF-8 멀티바이트다
enum AnswerLocalFixtures {
    static let bridgeID = "11111111-1111-4111-8111-111111111111"
    static let taskID = "33333333-3333-4333-8333-333333333333"
    static let stepID = "44444444-4444-4444-8444-444444444444"

    /// 알려진 `provider_request_id`와 그 digest (UTF-8 SHA-256 소문자 16진 64자)
    static let knownIDs: [(providerRequestID: String, digest: String)] = [
        ("toolu_01F2SecretLocalAnswer", "0e558779236c0c8b12aad0b75364ec4a080b58bba3e5fb8795316522a2d08c4e"),
        ("가나 ✓ 日本", "f724923ecc39a80fbdc26c6afd41817f598f99a9d94cb7177b29c178cbdc7740"),
    ]

    static let requestJSON = #"{"bridge_id":"11111111-1111-4111-8111-111111111111","agent_task_id":"33333333-3333-4333-8333-333333333333","request_digest":"0e558779236c0c8b12aad0b75364ec4a080b58bba3e5fb8795316522a2d08c4e"}"#

    static let responses: [(name: String, json: String)] = [
        ("answered", #"{"status":"answered","step_id":"44444444-4444-4444-8444-444444444444"}"#),
        ("duplicate", #"{"status":"duplicate","step_id":"44444444-4444-4444-8444-444444444444"}"#),
        ("stale_question_closed", #"{"status":"stale","reason":"question_closed"}"#),
        ("stale_not_live", #"{"status":"stale","reason":"not_live"}"#),
        ("stale_not_secret", #"{"status":"stale","reason":"not_secret"}"#),
    ]

    static let errors: [(name: String, status: Int, body: String)] = [
        ("bad_request", 400, #"{"error":{"code":"invalid_request","message":"Invalid local answer request."}}"#),
        ("unauthorized", 401, #"{"error":{"code":"unauthorized","message":"로그인이 필요합니다."}}"#),
        ("revoked", 403, #"{"error":{"code":"unauthorized","message":"Bridge revoked."}}"#),
        ("not_found", 404, #"{"error":{"code":"not_found","message":"Local answer target not found."}}"#),
        ("conflict", 409, #"{"error":{"code":"conflict","message":"Busy, retry."}}"#),
        ("rate_limited", 429, #"{"error":{"code":"rate_limited","message":"Please try again later."}}"#),
    ]
}
