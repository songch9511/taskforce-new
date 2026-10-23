#if os(macOS)
import Foundation

/// 중계 `claude -p --output-format stream-json`의 결과 줄 하나 (PR-D3k, 계약 25.4.1 "모델 0 확인"). 칸 모양은 CLI 2.1.306 실측이다 (PR-D3 탐침):
/// mod 명령의 답은 `result` 줄의 `result`가 `tf-relay: {JSON 한 줄}`이고 `local_command == "custom"` · `num_turns 0` · `total_cost_usd 0` · `modelUsage {}`다.
/// **글 · id를 찍지 않는다**: `description`은 칸 모양만 말한다
public struct ClaudeAppRelayResult: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// `result` 칸 (`tf-relay: {…}`). 없으면 nil
    public var text: String?
    public var isError: Bool
    /// `num_turns`: 숫자가 아니거나 없으면 nil (모르면 모델을 불렀다고 본다)
    public var numTurns: Int?
    /// `total_cost_usd`
    public var costUSD: Double?
    /// `modelUsage`가 비어 있지 않다 (또는 객체가 아니다)
    public var hasModelUsage: Bool
    /// `local_command`: mod 명령이 답한 결과에만 `"custom"`이 있다
    public var localCommand: String?

    public init(text: String?, isError: Bool, numTurns: Int?, costUSD: Double?, hasModelUsage: Bool, localCommand: String?) {
        self.text = text
        self.isError = isError
        self.numTurns = numTurns
        self.costUSD = costUSD
        self.hasModelUsage = hasModelUsage
        self.localCommand = localCommand
    }

    /// 모델이 한 번이라도 불렸다고 볼 수 있다: mod 명령의 결과가 아니거나(`custom` 아님), 턴 · 비용 · 모델 사용이 0이 아니거나, 그 칸이 없어 모른다
    public var involvedAModel: Bool {
        localCommand != "custom" || numTurns != 0 || costUSD != 0 || hasModelUsage
    }

    public var description: String { "ClaudeAppRelayResult(isError: \(isError), model: \(involvedAModel))" }
    public var debugDescription: String { description }
}

/// stdout 한 줄이 말하는 것: 중계에는 `assistant`(모델 이름)와 `result`만 뜻이 있다
public enum ClaudeAppRelayLine: Equatable, Sendable {
    /// `assistant` 줄: mod 명령의 답은 `<synthetic>`이다
    case assistant(model: String?)
    case result(ClaudeAppRelayResult)
    /// `system` 줄 · 그 밖 · 깨진 줄
    case other

    /// 한 줄(JSON) 읽기. 깨졌거나 모르는 모양이면 `.other`
    public static func parse(_ data: Data) -> ClaudeAppRelayLine {
        guard !data.isEmpty, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let type = object["type"] as? String else { return .other }
        switch type {
        case "assistant":
            let message = object["message"] as? [String: Any]
            return .assistant(model: message?["model"] as? String)
        case "result":
            let usage = object["modelUsage"]
            return .result(
                ClaudeAppRelayResult(
                    text: object["result"] as? String, isError: object["is_error"] as? Bool ?? true, numTurns: (object["num_turns"] as? NSNumber).flatMap(integer),
                    costUSD: (object["total_cost_usd"] as? NSNumber).map(\.doubleValue), hasModelUsage: usage == nil || !((usage as? [String: Any])?.isEmpty ?? false),
                    localCommand: object["local_command"] as? String
                )
            )
        default:
            return .other
        }
    }

    /// 정수로 읽히는 숫자만 (`true`는 숫자가 아니다)
    private static func integer(_ number: NSNumber) -> Int? {
        guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue == number.doubleValue.rounded() else { return nil }
        return number.intValue
    }

    /// 이 줄이 모델 턴을 뜻한다 (DT5 · DT12): 실제 모델의 `assistant` 줄(모델 칸이 없거나 이상해도), 또는 모델을 부른 흔적이 있는 `result`.
    /// 이것이 나오면 중계를 바로 끝내고 이 실행 동안 S2를 끈다
    public var isModelTurn: Bool {
        switch self {
        case .assistant(let model): model != "<synthetic>"
        case .result(let result): result.involvedAModel
        case .other: false
        }
    }
}

public enum ClaudeAppRelaySendOutcome: Equatable, Sendable {
    /// mod가 `isDelivered true`를 돌려줬다
    case delivered
    /// 전달하지 못했다: 이유를 코드로 접었다 (`no live session` → 닫힘, 그 밖 → 받지 않음)
    case notDelivered(ClaudeAppNotSentReason)
    /// mod가 거절했거나 답이 모양을 어겼다
    case failed
}

/// mod 답 읽기 (계약 25.4.2): 글은 `tf-relay: ` 뒤의 JSON 한 줄이다. 접두사가 없으면(모델이 쓴 글일 수 있다) 믿지 않는다
public enum ClaudeAppRelayAnswer {
    static let prefix = "\(ClaudeAppRelayMod.pluginName): "

    private static func decode(_ result: ClaudeAppRelayResult) -> [String: Any]? {
        guard let text = result.text, text.hasPrefix(prefix), let data = String(text.dropFirst(prefix.count)).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object["mod"] as? String == ClaudeAppRelayMod.pluginName,
              object["version"] as? String == ClaudeAppRelayMod.version else { return nil }
        return object
    }

    /// `/tfping <nonce>`의 답이 우리 mod · 판이고 준 nonce를 그대로 돌려줬다
    public static func pingMatches(_ result: ClaudeAppRelayResult, nonce: String) -> Bool {
        guard let object = decode(result), object["ok"] as? Bool == true, let echoed = object["nonce"] as? String else { return false }
        return echoed == nonce
    }

    /// `/tfsend`의 답
    public static func sendOutcome(_ result: ClaudeAppRelayResult) -> ClaudeAppRelaySendOutcome {
        guard let object = decode(result), object["ok"] as? Bool == true, let delivered = object["isDelivered"] as? Bool else { return .failed }
        if delivered { return .delivered }
        // 탐침(P10): "no live session on this machine has id …" = 살아 있지 않다. 그 밖(SendMessage 도구 없음 · 받지 않음 · 이유 없음)은 받지 못함
        let reason = (object["reason"] as? String) ?? ""
        return .notDelivered(reason.hasPrefix("no live session") ? .sessionClosed : .notReceived)
    }
}
#endif
