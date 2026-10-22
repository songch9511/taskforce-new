#if os(macOS)
import Foundation

// 데스크톱 세션의 상태 값 (PR-D1 Kit, 계약 21.1 DR-1 · DR-2). 등록 파일 `sessions/<pid>.json`과 `claude agents --json`이 같은 이름의 값을 낸다.

/// 멈춘 세션이 무엇을 기다리나 (`waitingFor`). 레일의 말이 둘로 갈린다: "Needs approval in Claude" · "Needs your answer in Claude" (DZ 승인 2026-10-22)
public enum ClaudeAppWait: Hashable, Sendable {
    /// `permission prompt` · `sandbox request`
    case approval
    /// `input needed` · `dialog open` · `worker request` · 그 밖(모르는 값 · 값 없음)
    case answer
}

/// Claude Code가 적는 세션 상태. 키가 없거나 모르는 값이면 `unknown` (죽지 않는다, 레일에도 오르지 않는다)
public enum ClaudeAppSessionState: Hashable, Sendable {
    case busy
    case waiting(ClaudeAppWait)
    case idle
    case unknown

    /// 값은 정확히 `busy` · `waiting` · `idle`뿐이다 (대소문자 · 공백이 다르거나 32바이트를 넘으면 모르는 값). `waitingFor`는 `waiting`일 때만 본다
    static func parse(status: String?, waitingFor: String?) -> ClaudeAppSessionState {
        guard let status, status.utf8.count <= 32 else { return .unknown }
        switch status {
        case "busy": return .busy
        case "idle": return .idle
        case "waiting": return .waiting(wait(for: waitingFor))
        default: return .unknown
        }
    }

    static func wait(for waitingFor: String?) -> ClaudeAppWait {
        switch waitingFor {
        case "permission prompt"?, "sandbox request"?: .approval
        default: .answer
        }
    }
}
#endif
