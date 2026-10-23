#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

extension ExternalSessionSuites {
    /// 중계 `claude -p`의 stdout 줄 읽기 (PR-D3k, 계약 25.4.1 "모델 0 확인" · DT5 · DT12): 줄 모양은 CLI 2.1.306 실측(PR-D3 탐침)이다.
    /// mod 명령의 답은 `assistant`(model `<synthetic>`) + `result`(`local_command: "custom"`, `num_turns` 0, 비용 0, `modelUsage` 빔)이고 글은 `tf-relay: {JSON 한 줄}`이다.
    /// 모델이 한 번이라도 불리면(어느 칸이든 어긋남) 모델 턴이다
    struct ClaudeAppRelayOutputTests {
        let nonce = "0123456789abcdef0123456789abcdef"

        private func line(_ object: [String: Any]) -> Data {
            (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        }

        /// 실측한 mod 명령 결과 줄 (필요한 칸만)
        private func result(
            text: String? = nil, localCommand: Any? = "custom", turns: Any? = 0, cost: Any? = 0, usage: Any? = [String: Any](), isError: Bool = false, subtype: String = "success"
        ) -> [String: Any] {
            var object: [String: Any] = ["type": "result", "subtype": subtype, "is_error": isError, "session_id": "s", "uuid": "u"]
            if let text { object["result"] = text }
            if let localCommand { object["local_command"] = localCommand }
            if let turns { object["num_turns"] = turns }
            if let cost { object["total_cost_usd"] = cost }
            if let usage { object["modelUsage"] = usage }
            return object
        }

        private func assistant(model: Any? = "<synthetic>", text: String = "tf-relay: {}") -> [String: Any] {
            var message: [String: Any] = ["role": "assistant", "content": [["type": "text", "text": text]]]
            if let model { message["model"] = model }
            return ["type": "assistant", "message": message, "session_id": "s"]
        }

        // MARK: 줄 읽기

        @Test func aModCommandAnswerIsAnAssistantLineOfTheSyntheticModelAndAZeroCostResult() {
            #expect(ClaudeAppRelayLine.parse(line(assistant())) == .assistant(model: "<synthetic>"))
            let text = "tf-relay: {\"mod\":\"tf-relay\",\"ok\":true}"
            guard case .result(let parsed) = ClaudeAppRelayLine.parse(line(result(text: text))) else {
                Issue.record("result가 아니다")
                return
            }
            #expect(parsed.text == text && !parsed.isError && parsed.numTurns == 0 && parsed.costUSD == 0 && !parsed.hasModelUsage && parsed.localCommand == "custom")
            #expect(!parsed.involvedAModel && ClaudeAppRelayLine.result(parsed).isModelTurn == false)
        }

        @Test func linesThatAreNotAssistantOrResultAreOtherAndGarbageIsOtherToo() {
            #expect(ClaudeAppRelayLine.parse(line(["type": "system", "subtype": "init", "model": "claude-opus-5-5"])) == .other, "init의 model 칸은 모델 호출이 아니다")
            #expect(ClaudeAppRelayLine.parse(line(["type": "system", "subtype": "session_title_changed"])) == .other)
            #expect(ClaudeAppRelayLine.parse(Data("not json".utf8)) == .other)
            #expect(ClaudeAppRelayLine.parse(Data()) == .other)
            #expect(ClaudeAppRelayLine.parse(line(["no": "type"])) == .other)
            #expect(ClaudeAppRelayLine.other.isModelTurn == false)
        }

        // MARK: 모델 턴 (DT5 · DT12)

        @Test func anAssistantLineOfAnyRealModelIsAModelTurn() {
            // mod가 안 올라와 `/tfsend …`가 모델에 갔다 (탐침: model claude-opus-5-5, 비용 0.026)
            #expect(ClaudeAppRelayLine.parse(line(assistant(model: "claude-opus-5-5"))).isModelTurn)
            #expect(ClaudeAppRelayLine.parse(line(assistant(model: nil))).isModelTurn, "모델 칸이 없으면 모른다: 막는다")
            #expect(ClaudeAppRelayLine.parse(line(assistant(model: 5))).isModelTurn)
        }

        @Test func aResultWithTurnsCostUsageOrWithoutTheCustomCommandMarkIsAModelTurn() {
            let bad: [(String, [String: Any])] = [
                ("num_turns 1", result(turns: 1)), ("num_turns 없음", result(turns: nil)), ("num_turns가 숫자가 아님", result(turns: "0")),
                ("비용 0.026", result(cost: 0.026_337)), ("비용 없음", result(cost: nil)), ("modelUsage가 비지 않음", result(usage: ["claude-opus-5-5": ["inputTokens": 3]])),
                ("modelUsage 없음", result(usage: nil)), ("local_command 없음", result(localCommand: nil)), ("local_command가 custom이 아님", result(localCommand: "builtin")),
                ("예산 초과 오류", result(localCommand: nil, turns: 1, cost: 0.026, usage: ["m": [:]], isError: true, subtype: "error_max_budget_usd")),
            ]
            for (why, object) in bad {
                #expect(ClaudeAppRelayLine.parse(line(object)).isModelTurn, "\(why)")
            }
        }

        // MARK: 답 읽기

        @Test func theHealthAnswerMustCarryTheNonceWeGaveAndTheModsNameAndVersion() {
            func pinged(_ json: String, prefix: String = "tf-relay: ") -> ClaudeAppRelayResult? {
                guard case .result(let parsed) = ClaudeAppRelayLine.parse(line(result(text: prefix + json))) else { return nil }
                return parsed
            }
            let good = "{\"mod\":\"tf-relay\",\"version\":\"1\",\"ok\":true,\"nonce\":\"\(nonce)\"}"
            #expect(pinged(good).map { ClaudeAppRelayAnswer.pingMatches($0, nonce: nonce) } == true)
            #expect(pinged(good).map { ClaudeAppRelayAnswer.pingMatches($0, nonce: "ffffffffffffffffffffffffffffffff") } == false, "다른 nonce")
            #expect(pinged("{\"mod\":\"other\",\"version\":\"1\",\"ok\":true,\"nonce\":\"\(nonce)\"}").map { ClaudeAppRelayAnswer.pingMatches($0, nonce: nonce) } == false)
            #expect(pinged("{\"mod\":\"tf-relay\",\"version\":\"2\",\"ok\":true,\"nonce\":\"\(nonce)\"}").map { ClaudeAppRelayAnswer.pingMatches($0, nonce: nonce) } == false, "모르는 mod 판")
            #expect(pinged("{\"mod\":\"tf-relay\",\"version\":\"1\",\"ok\":false,\"error\":\"bad_nonce\"}").map { ClaudeAppRelayAnswer.pingMatches($0, nonce: nonce) } == false)
            #expect(pinged(good, prefix: "other-plugin: ").map { ClaudeAppRelayAnswer.pingMatches($0, nonce: nonce) } == false, "플러그인 이름이 앞에 붙은 줄이 아니다")
            #expect(pinged("not json").map { ClaudeAppRelayAnswer.pingMatches($0, nonce: nonce) } == false)
            // 답이 모델이 쓴 글 같으면 (접두사가 없다) 믿지 않는다
            #expect(pinged(good, prefix: "").map { ClaudeAppRelayAnswer.pingMatches($0, nonce: nonce) } == false)
        }

        @Test func theSendAnswerIsDeliveredWhenTheModSaysSoAndFoldsTheReasonIntoACode() {
            func outcome(_ json: String) -> ClaudeAppRelaySendOutcome? {
                guard case .result(let parsed) = ClaudeAppRelayLine.parse(line(result(text: "tf-relay: " + json))) else { return nil }
                return ClaudeAppRelayAnswer.sendOutcome(parsed)
            }
            #expect(outcome("{\"mod\":\"tf-relay\",\"version\":\"1\",\"ok\":true,\"isDelivered\":true,\"reason\":null}") == .delivered)
            // 탐침(P10): 살아 있지 않은 id
            let closed = "no live session on this machine has id 11111111-2222-4333-8444-555555555555 (a session that exited, or another machine's; a Remote Control or cloud session is addressed by its session_... id)"
            #expect(outcome("{\"mod\":\"tf-relay\",\"version\":\"1\",\"ok\":true,\"isDelivered\":false,\"reason\":\"\(closed)\"}") == .notDelivered(.sessionClosed))
            #expect(outcome("{\"mod\":\"tf-relay\",\"version\":\"1\",\"ok\":true,\"isDelivered\":false,\"reason\":\"this session has no SendMessage tool\"}") == .notDelivered(.notReceived))
            #expect(outcome("{\"mod\":\"tf-relay\",\"version\":\"1\",\"ok\":true,\"isDelivered\":false,\"reason\":null}") == .notDelivered(.notReceived))
            // mod가 인자를 거절했다 · 모양이 틀리다 · 접두사 없음: 중계 실패
            #expect(outcome("{\"mod\":\"tf-relay\",\"version\":\"1\",\"ok\":false,\"error\":\"bad_args\"}") == .failed)
            #expect(outcome("garbage") == .failed)
            #expect(outcome("{\"mod\":\"tf-relay\",\"version\":\"1\",\"ok\":true,\"isDelivered\":\"yes\"}") == .failed, "isDelivered가 불리언이 아니다")
            #expect(outcome("{\"mod\":\"other\",\"version\":\"1\",\"ok\":true,\"isDelivered\":true}") == .failed)
        }

        @Test func theSendAnswerOfAResultWithoutTextIsAFailure() {
            guard case .result(let parsed) = ClaudeAppRelayLine.parse(line(result(text: nil))) else {
                Issue.record("result가 아니다")
                return
            }
            #expect(ClaudeAppRelayAnswer.sendOutcome(parsed) == .failed)
            #expect(!ClaudeAppRelayAnswer.pingMatches(parsed, nonce: nonce))
        }

        @Test func nothingPrintsTheTextOrTheIds() {
            guard case .result(let parsed) = ClaudeAppRelayLine.parse(line(result(text: "tf-relay: SENTINEL-TEXT"))) else {
                Issue.record("result가 아니다")
                return
            }
            #expect(!"\(parsed)".contains("SENTINEL") && !"\(String(reflecting: parsed))".contains("SENTINEL"))
        }
    }
}
#endif
