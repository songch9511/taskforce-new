import Foundation
@testable import TaskforceKit

/// 열린 질문(`agent_tasks.pending_question`)의 JSON 모양 픽스처 (OA D4b-m-1).
/// 모양의 출처는 서버 검증 함수 `agent_pending_question_valid`(`supabase/migrations/20261116000000_agent_events.sql`)와 그 시험 상수
/// (`tests/db/review-agent-inputs.scenarios.ts`의 `question()`)다: 키는 `question_key` · `provider_request_id` · `kind`(`input` | `approval`) · `structured` · `questions` · `asked_at`,
/// 질문은 1–4개(`id` · `header` · `text` · `options` ≤ 10 · `multi_select` · `allow_other` · `secret`), 선택지는 `label` · `description`.
/// 승인 질문의 글은 D3a 어댑터의 `approvalQuestion` 출력(머리 `Edit file` · `Write file` · `Run command`, 글 `Edit <상대 경로>` · `Run: <명령>`, 사유는 둘째 줄)과 같은 모양이다.
/// 아래 글은 모두 지어낸 예시다 (사용자 글이 아니다).
enum AgentQuestionFixtures {
    static let taskID = UUID(uuidString: "a5555555-5555-4555-8555-555555555555")!
    static let sessionID = UUID(uuidString: "a4444444-4444-4444-8444-444444444444")!
    static let bridgeID = UUID(uuidString: "b1d6e000-0000-4000-8000-000000000001")!
    static let otherBridgeID = UUID(uuidString: "b1d6e000-0000-4000-8000-000000000002")!
    static let requestID = "toolu_01F2SecretLocalAnswer"

    static func key(_ request: String = requestID, task: UUID = taskID) -> AgentQuestionKey {
        AgentQuestionKey(taskID: task, requestID: request)
    }

    /// 질문 하나의 JSON
    static func prompt(
        id: String = "q1", text: String = "Which price should lead the yearly card?", header: String = "outside the brief",
        options: [(String, String)] = [("First-month price", ""), ("Monthly price", ""), ("Yearly total", ""), ("Price per month", "")],
        multi: Bool = false, other: Bool = false, secret: Bool = false
    ) -> String {
        let rows = options.map { #"{"label":\#(quoted($0.0)),"description":\#(quoted($0.1))}"# }.joined(separator: ",")
        return #"{"id":\#(quoted(id)),"header":\#(quoted(header)),"text":\#(quoted(text)),"options":[\#(rows)],"multi_select":\#(multi),"allow_other":\#(other),"secret":\#(secret)}"#
    }

    /// `pending_question` 전체 JSON
    static func pending(
        prompts: [String], request: String = requestID, task: UUID = taskID, kind: String = "input", structured: Bool = true,
        asked: String = "2026-10-18T01:02:03.000Z"
    ) -> String {
        #"{"question_key":[\#(quoted(task.uuidString.lowercased())),\#(quoted(request))],"provider_request_id":\#(quoted(request)),"kind":\#(quoted(kind)),"structured":\#(structured),"questions":[\#(prompts.joined(separator: ","))],"asked_at":\#(quoted(asked))}"#
    }

    /// `agent_tasks` 행 (RLS select가 돌려주는 모양)
    static func row(
        pending: String?, task: UUID = taskID, session: UUID = sessionID, turn: Int = 1, state: String = "awaiting_answer"
    ) -> String {
        #"{"id":\#(quoted(task.uuidString.lowercased())),"agent_session_id":\#(quoted(session.uuidString.lowercased())),"turn_seq":\#(turn),"state":\#(quoted(state)),"pending_question":\#(pending ?? "null")}"#
    }

    static func quoted(_ text: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [text], options: [])
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    // MARK: 모양들 (계약 5장 표의 줄마다 하나)

    /// 단일 선택, 선택지 넷 (Keycap이 보이는 경우)
    static var single: String { pending(prompts: [prompt()]) }
    /// 단일 선택, 선택지 셋 (Keycap 없음)
    static var singleThree: String {
        pending(prompts: [prompt(options: [("Pro monthly", ""), ("Pro yearly", ""), ("Lifetime", "")])])
    }
    /// 다중 선택
    static var multi: String {
        pending(prompts: [prompt(text: "Which plans show the 3-day trial?", header: "Choose any", options: [("Pro monthly", ""), ("Pro yearly", ""), ("Lifetime", "")], multi: true)])
    }
    /// 선택지 셋 + Other (줄 넷: Keycap이 보인다)
    static var otherThree: String {
        pending(prompts: [prompt(text: "Which plan should the banner mention?", options: [("Pro monthly", ""), ("Pro yearly", ""), ("Lifetime", "")], other: true)])
    }
    /// 선택지 없는 질문 (글만)
    static var textOnly: String {
        pending(prompts: [prompt(text: "What should the banner say?", header: "", options: [], other: true)])
    }
    /// 여러 질문 셋 (한 번에 하나)
    static var several: String {
        pending(prompts: [
            prompt(id: "price", text: "Which price should lead the yearly card?"),
            prompt(id: "plans", text: "Which plans show the 3-day trial?", header: "Choose any", options: [("Pro monthly", ""), ("Pro yearly", ""), ("Lifetime", "")], multi: true),
            prompt(id: "banner", text: "What should the banner say?", header: "", options: [], other: true),
        ])
    }
    /// 비밀값 질문
    static var secret: String {
        pending(prompts: [prompt(text: "Enter the staging deploy token", header: "", options: [], other: true, secret: true)])
    }
    /// 비밀값이 섞인 두 질문 (한 요청, 모두 이 Mac에서 답한다)
    static var secretMixed: String {
        pending(prompts: [
            prompt(id: "env", text: "Which environment?", header: "Deploy", options: [("Staging", ""), ("Production", "")]),
            prompt(id: "token", text: "Enter the deploy token", header: "Deploy", options: [], other: true, secret: true),
        ])
    }
    /// 비밀값이 **앞**에 있는 두 질문 (검토 1: 앞 단계 비밀값도 Undo · 실패 · 종료에서 지워져야 한다)
    static var secretFirstMixed: String {
        pending(prompts: [
            prompt(id: "token", text: "Enter the deploy token", header: "Deploy", options: [], other: true, secret: true),
            prompt(id: "env", text: "Which environment?", header: "Deploy", options: [("Staging", ""), ("Production", "")]),
        ])
    }
    /// 비밀값이 **가운데**에 있는 세 질문
    static var secretMiddle: String {
        pending(prompts: [
            prompt(id: "env", text: "Which environment?", header: "Deploy", options: [("Staging", ""), ("Production", "")]),
            prompt(id: "token", text: "Enter the deploy token", header: "Deploy", options: [], other: true, secret: true),
            prompt(id: "region", text: "Which region?", header: "Deploy", options: [("eu", ""), ("us", "")]),
        ])
    }
    /// 승인: 파일 고치기 (D3a: 머리 `Edit file`, 글 `Edit <상대 경로>`)
    static var approvalEdit: String {
        pending(
            prompts: [prompt(id: "approval", text: "Edit src/content/pricing.mdx", header: "Edit file", options: [("Allow", ""), ("Deny", "")])],
            kind: "approval"
        )
    }
    /// 승인: 명령 실행, 사유가 둘째 줄 (D3a: `Run: <명령>\n<사유>`)
    static var approvalRunWithReason: String {
        pending(
            prompts: [prompt(id: "approval", text: "Run: npm run build\nContains a secret value", header: "Run command", options: [("Allow", ""), ("Deny", "")])],
            kind: "approval"
        )
    }
    /// 선택지 열: 설명이 있다 (화면에는 그리지 않고 도움말에만)
    static var singleWithDescriptions: String {
        pending(prompts: [prompt(options: [("Trim the scope", "Drop the Lifetime section for Thursday"), ("Keep the scope", "")])])
    }

    // MARK: 깨진 모양 (카드를 그리지 않는다)

    static var unknownKind: String { pending(prompts: [prompt()], kind: "future_kind") }
    static var noQuestions: String { pending(prompts: []) }
    static var fiveQuestions: String { pending(prompts: (1...5).map { prompt(id: "q\($0)") }) }
    static var elevenOptions: String {
        pending(prompts: [prompt(options: (1...11).map { ("Option \($0)", "") })])
    }
    /// 질문 열쇠의 둘째 값이 `provider_request_id`와 다르다
    static var keyMismatch: String {
        #"{"question_key":["\#(taskID.uuidString.lowercased())","other-request"],"provider_request_id":"\#(requestID)","kind":"input","structured":true,"questions":[\#(prompt())],"asked_at":"2026-10-18T01:02:03.000Z"}"#
    }
    /// 열쇠의 첫 값이 행의 task id와 다르다
    static var keyForAnotherTask: String { pending(prompts: [prompt()], task: UUID(uuidString: "a9999999-9999-4999-8999-999999999999")!) }
    /// 승인인데 질문 id가 `approval`이 아니다 (서버 답 route가 400이다)
    static var approvalWithWrongID: String {
        pending(prompts: [prompt(id: "x", text: "Edit a.txt", header: "Edit file", options: [("Allow", ""), ("Deny", "")])], kind: "approval")
    }
    /// 승인인데 선택지가 둘이 아니다
    static var approvalWithOneOption: String {
        pending(prompts: [prompt(id: "approval", text: "Edit a.txt", header: "Edit file", options: [("Allow", "")])], kind: "approval")
    }
    static var missingField: String {
        #"{"question_key":["\#(taskID.uuidString.lowercased())","\#(requestID)"],"provider_request_id":"\#(requestID)","kind":"input","structured":true,"asked_at":"2026-10-18T01:02:03.000Z"}"#
    }

    // MARK: 답 route 응답 (서버 `src/lib/api/contract.ts` `answerAgentQuestionResponseSchema`와 같은 모양)

    static let answered = #"{"status":"answered","step_id":"f0000000-0000-f000-f000-000000000001"}"#
    static let duplicate = #"{"status":"duplicate","step_id":"f0000000-0000-f000-f000-000000000001"}"#
    static func error(_ code: String, _ message: String = "서버 문구") -> String {
        #"{"error":{"code":"\#(code)","message":"\#(message)"}}"#
    }

    /// `bridges` 행 (열 권한은 `device_name`뿐 아니라 `id`도 읽는다)
    static func bridge(name: String?) -> String {
        #"[{"id":"\#(bridgeID.uuidString.lowercased())","device_name":\#(name.map(quoted) ?? "null")}]"#
    }
}
