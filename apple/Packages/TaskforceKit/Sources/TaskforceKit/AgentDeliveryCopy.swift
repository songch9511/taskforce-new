import Foundation

// 에이전트 대화의 UI 문구 (OA D4a 계약 4장 · 7장). 모두 승인됐다: DS에 있는 말과 사용자가 2026-10-18에 승인한 새 말 아홉 (계약 7장 표).
// 승인 전에는 새 말을 `AgentUnapprovedCopy`(후보는 Debug 견본에서만 보임)에 따로 모아 두었다가, 승인되어 이 한 곳(`AgentCopy`)으로 옮기고 그 구분을 없앴다.

/// 승인된 문구 (바꾸지 않는다): DS에 있는 전달 · Stop · 확인 카드의 말과, 사용자가 승인한 새 말 아홉
public enum AgentCopy {
    public static let received = "Received"
    public static let sent = "Sent"
    public static let unknown = "Unknown · Not confirmed by the agent"
    public static let queued = "Queued"
    public static let sessionInTerminal = "Session is in Terminal"
    public static let macOffline = "Mac is offline"
    public static let answerFirst = "Answer the question first"
    public static let notSent = "Not sent"
    public static let accessNotVerified = "Access not verified"
    public static let notConnected = "Not connected"
    public static let unsupported = "Unsupported"
    public static let expired = "Expired · Older than 24 hours"
    public static let sendAgain = "Send again"
    public static let stopNewSteps = "Stop new steps"
    public static let stopRequested = "Stop requested · not confirmed"
    public static let resumeTitle = "Is the Terminal session closed?"
    public static let resumeMeta = "Queued messages send after you resume"
    public static let resumeConfirm = "Resume here"
    public static let cancel = "Cancel"
    public static let closeTerminalFirst = "Close the terminal session first"
    public static let viewFull = "View full"

    public static func notSignedIn(to agent: String) -> String { "Not signed in to \(agent)" }

    // 사용자 승인 2026-10-18 (계약 7장 새 문구 아홉)
    /// `version_unsupported` 이유
    public static let versionUnsupported = "Unsupported version"
    /// `usage_limited` 이유
    public static let usageLimited = "Usage limit reached"
    /// `spawn_failed` 이유
    public static let spawnFailed = "Session didn't start"
    /// `not_received` 이유
    public static let notReceived = "Not received"
    /// `session_closed` 이유 (닫힌 세션: Send again 없음)
    public static let sessionClosed = "Session closed"
    /// `cancelled` 이유
    public static let stopped = "Stopped"
    /// `needs_referent` 줄의 링크
    public static let chooseReferent = "Choose an issue"
    /// Stop 뒤 명령이 남을 수 있다 (계약 v3 :310)
    public static let stoppedMayContinue = "Stopped · commands may still be running"

    /// auto 칩을 눌러 더하는 접근성 동작 이름: "Add #139 Rewrite pricing page copy"
    public static func addChip(_ chipName: String) -> String { "Add \(chipName)" }

    /// `not_sent`의 이유 중 새로 승인된 말 (그 밖의 이유는 DS 말이거나 일반 줄 "Not sent"뿐이다)
    static func reasonWords(_ reason: AgentDeliveryReason) -> String? {
        switch reason {
        case .versionUnsupported: versionUnsupported
        case .usageLimited: usageLimited
        case .spawnFailed: spawnFailed
        case .notReceived: notReceived
        case .sessionClosed: sessionClosed
        default: nil
        }
    }
}
