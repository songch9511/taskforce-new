#if os(macOS)
import Foundation

/// Claude 데스크톱 세션 보기의 승인된 문구 (DZ 승인 2026-10-22 `oa-desktop-rail-dz` R1–R3 · P1–P5 · 사용자 승인). 화면은 이 상수만 쓴다.
/// 입력창(Composer) 문구는 S2의 몫이라 여기 없다 (이 PR은 읽기 전용이다)
public enum ClaudeAppCopy {
    public static let runningInClaude = ExternalSessionCopy.runningInClaude
    public static let needsApproval = "Needs approval in Claude"
    public static let needsAnswer = "Needs your answer in Claude"
    public static let idle = ExternalSessionCopy.idle
    public static let closedInClaude = "Closed in Claude"
    public static let openInClaude = ExternalSessionCopy.openInClaude
    /// 띠 제목: 권한 질문 · 물음 (Taskforce는 어느 쪽에도 답하지 않는다: 승인은 늘 Claude에서)
    public static let approveBand = "Approve in Claude"
    public static let answerBand = "Answer in Claude"
    public static let showEarlier = "Show earlier"
    /// Taskforce 세션 패널과 같은 말
    public static let couldNotLoadChat = "Couldn't load this chat"
    public static let tryAgain = "Try again"
}

/// 입력창 자리의 띠 (질문 카드 자리, `Notice`): 제목 + Open in Claude 단추뿐이다. Approve · Deny 버튼은 없다
public enum ClaudeAppPanelBand: Equatable, Sendable {
    case approve
    case answer

    public var title: String {
        switch self {
        case .approve: ClaudeAppCopy.approveBand
        case .answer: ClaudeAppCopy.answerBand
        }
    }
}

/// 살아 있는 데스크톱 세션이 지금 어떤 상태인가: 레일 링 · Sessions의 줄 · 세션 보기의 머리가 같은 값을 읽는다.
/// 끝남(done)은 Taskforce가 끝난 것을 본 뒤 아직 열어 보지 않은 것이고, 열어 보면 idle이다
public enum ClaudeAppLiveStatus: Equatable, Sendable {
    case running
    case needsApproval
    case needsAnswer
    case done
    case idle

    /// 링 (데스크톱 줄 · 링은 Taskforce 세션의 링과 똑같이 그린다: 마크 없음, 구분은 툴팁 · 머리의 마크로)
    public var ring: AgentSessionRing {
        switch self {
        case .running: .running
        case .needsApproval, .needsAnswer: .needsYou
        case .done: .done
        case .idle: .idle
        }
    }

    /// 상태 말 (승인된 문구)
    public var word: String {
        switch self {
        case .running: ClaudeAppCopy.runningInClaude
        case .needsApproval: ClaudeAppCopy.needsApproval
        case .needsAnswer: ClaudeAppCopy.needsAnswer
        case .done: AgentSessionRules.done
        case .idle: ClaudeAppCopy.idle
        }
    }

    /// 입력창 자리에 띠를 보이나: 권한 · 물음을 기다릴 때만
    public var band: ClaudeAppPanelBand? {
        switch self {
        case .needsApproval: .approve
        case .needsAnswer: .answer
        case .running, .done, .idle: nil
        }
    }
}

extension ClaudeAppSessionsModel {
    /// 이 세션의 지금 상태. 살아 있지 않거나 상태를 모르면(`unknown`) nil: 모르는 것을 말하지 않는다
    public func liveStatus(for id: String) -> ClaudeAppLiveStatus? {
        guard let session = session(id: id) else { return nil }
        if rail.contains(where: { $0.id == id && $0.kind == .done }) { return .done }
        switch session.state {
        case .busy: return .running
        case .waiting(.approval): return .needsApproval
        case .waiting(.answer): return .needsAnswer
        case .idle: return .idle
        case .unknown: return nil
        }
    }
}
#endif
