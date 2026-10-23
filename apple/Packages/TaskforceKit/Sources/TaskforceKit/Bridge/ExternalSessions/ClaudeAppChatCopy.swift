#if os(macOS)
import Foundation

/// 데스크톱 세션과 대화하는 입력창 · 전달 줄 · 확인 카드의 문구 (PR-D3m, DZ 승인 2026-10-22 `oa-desktop-rail-dz` 시트 3 · 4 · 사용자 승인 · 계약 26장 Q-D3c "From another session").
/// **승인된 말만 있다.** 새 문구를 더하려면 먼저 승인을 받는다 (Debug 상수로만 둔다): 이 파일의 글자는 시험이 DZ 문구 표와 한 글자까지 맞춰 본다
public enum ClaudeAppChatCopy {
    /// 입력창 자리 글 (C1 B, 이미 승인된 말: Taskforce가 돌리는 Claude Code 세션의 입력창과 같다)
    public static let composerPlaceholder = "Message Claude Code"
    public static let composerLabel = "Message Claude Code"
    /// 전달 줄 (C2 · C4)
    public static let sending = ChatCopy.sending
    public static let sent = AgentCopy.sent
    public static let received = AgentCopy.received
    public static let viaTaskforce = "via Taskforce"
    public static let receivedViaTaskforce = "\(received) · \(viaTaskforce)"
    public static let notSent = AgentCopy.notSent
    public static let sessionClosed = AgentCopy.sessionClosed
    public static let notReceived = AgentCopy.notReceived
    public static let bypassMode = "Session is in Bypass mode"
    public static let twoPlaces = "Running in two places"
    public static let sendAgain = AgentCopy.sendAgain
    /// Taskforce가 보낸 것이 아닌 다른 세션의 메시지 아래 (D2 보안 검토 P3, 사용자 승인 2026-10-22 Q-D3c)
    public static let fromAnotherSession = "From another session"
    /// 첫 보내기 확인 카드 (C5, 세션마다 한 번)
    public static let confirmTitle = "Send to this session?"
    public static let confirmDetail = "Claude sees it as a message from Taskforce. Approvals stay in Claude."
    public static let confirmSend = "Send"
    public static let confirmCancel = AgentCopy.cancel
}

/// 못 보낸 이유 (DZ 시트 4 · 서버 `claude-app-sent`의 `reason`): 말이 넷이고 지표 코드는 다섯이다 (중계 실패도 말은 Not received)
public enum ClaudeAppNotSentReason: String, Equatable, Sendable, CaseIterable {
    case sessionClosed = "session_closed"
    case notReceived = "not_received"
    case bypass
    case twoWriters = "two_writers"
    case relayFailed = "relay_failed"

    /// 서버 지표의 이유 코드 (글 0)
    public var code: String { rawValue }

    /// 화면의 이유 말 (회색)
    public var words: String {
        switch self {
        case .sessionClosed: ClaudeAppChatCopy.sessionClosed
        case .notReceived, .relayFailed: ClaudeAppChatCopy.notReceived
        case .bypass: ClaudeAppChatCopy.bypassMode
        case .twoWriters: ClaudeAppChatCopy.twoPlaces
        }
    }

    /// 닫힌 세션은 다시 보낼 곳이 없다 (Send again 없음)
    public var allowsSendAgain: Bool { self != .sessionClosed }
}
#endif
