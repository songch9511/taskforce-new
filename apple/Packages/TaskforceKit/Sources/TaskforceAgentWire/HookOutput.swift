#if os(macOS)
import Foundation

/// Claude Code 훅 출력 JSON (OA D3a 계약 3.4, S0 `tf_hook_v3.py:26–30`과 같은 모양). 모르는 경우는 모두 deny다
public enum HookOutput {
    /// SessionStart 표식 (자체 점검 ③). 모델 문맥에 들어가므로 nonce · spawn id를 넣지 않는다
    public static let marker = "tf-hook-ready"

    public static func sessionStart() -> Data {
        WireJSON.object(["hookSpecificOutput": .object(["hookEventName": .string("SessionStart"), "additionalContext": .string(marker)])]).canonicalData
    }

    /// `updatedInput`은 allow이고 bridge가 `answers`나 `command`를 줬을 때만
    public static func preToolUse(_ decision: HookDecision, reason: String, updatedInput: WireJSON? = nil) -> Data {
        var fields: [String: WireJSON] = [
            "hookEventName": .string("PreToolUse"), "permissionDecision": .string(decision.rawValue), "permissionDecisionReason": .string(String(reason.prefix(1000))),
        ]
        if decision == .allow, let updatedInput { fields["updatedInput"] = updatedInput }
        return WireJSON.object(["hookSpecificOutput": .object(fields)]).canonicalData
    }
}

/// 훅이 스스로 정하는 거절 이유 (영어, 모델에게 간다)
public enum HookReason {
    /// bridge에 닿지 못했거나 답이 없거나 깨졌다
    public static let unavailable = "Taskforce could not check this tool call, so it was not run."
    /// 훅 입력을 읽지 못했다
    public static let unreadable = "Taskforce could not read this tool call, so it was not run."
}
#endif
