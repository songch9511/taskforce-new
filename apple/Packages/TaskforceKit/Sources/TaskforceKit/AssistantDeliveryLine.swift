import Foundation

/// 에이전트 대상 메시지 아래의 전달 한 줄 (DS MessageDelivery, OA D4a-04 – 09): 서버가 계산한 `delivery`(상태 9 × 이유 17)를 말로 옮긴다. 판정은 서버가 하고 앱은 옮기기만 한다.
/// Received(accepted) · Sent · Unknown · Queued · **Not sent**(굵게, 빨강 아님) · Expired. 단어만: 아이콘 · 스피너 · 색 없음. 링크는 Send again · 후보 고르기뿐이다.
/// - 이유 말: DS에 있는 것(Session is in Terminal · Not signed in to {에이전트} · Access not verified · Not connected · Unsupported · Mac is offline · Answer the question first)과
///   사용자가 승인한 새 말(Unsupported version · Usage limit reached · Session didn't start · Not received · Session closed · Stopped · Choose an issue, `AgentCopy`). 모르는 이유는 일반 줄 "Not sent · Send again"
/// - answered(서버가 곧바로 이벤트 줄 "Answered"를 쓴다) · 모르는 상태는 줄이 없다 (두 번 말하지 않고, 모르는 값에 아무것도 주장하지 않는다)
public struct MessageDeliveryLine: Equatable, Sendable {
    /// 줄 끝의 링크 하나 (DS Button `link`, `text/accent`)
    public struct Link: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// `POST …/deliver` (not_sent · expired) 또는 새 메시지 보내기(cancelled)
            case sendAgain
            /// `needs_referent`의 후보 (≤ 3): 누르면 후보 메뉴가 열린다
            case chooseReferent([AgentReferentCandidate])
        }

        public let kind: Kind
        public let title: String

        public init(_ kind: Kind, _ title: String) {
            self.kind = kind
            self.title = title
        }
    }

    /// 굵은 text-primary 부분 (Not sent뿐)
    public let strong: String?
    /// 보조 글(secondary) 부분
    public let text: String?
    public let link: Link?

    public init(strong: String?, text: String?, link: Link? = nil) {
        self.strong = strong
        self.text = text
        self.link = link
    }

    public static let sendAgainTitle = AgentCopy.sendAgain

    /// 줄 하나. 줄이 없는 상태(answered · 모르는 값)는 nil
    public static func of(_ delivery: AgentDelivery, context: AgentDeliveryContext = AgentDeliveryContext()) -> MessageDeliveryLine? {
        let sendAgain = Link(.sendAgain, sendAgainTitle)
        switch delivery.state {
        case .accepted: return MessageDeliveryLine(strong: nil, text: AgentCopy.received)
        case .sent: return MessageDeliveryLine(strong: nil, text: AgentCopy.sent)
        case .outcomeUnknown: return MessageDeliveryLine(strong: nil, text: AgentCopy.unknown)
        case .queued: return MessageDeliveryLine(strong: nil, text: queued(reason: delivery.reason, context: context))
        case .expired: return MessageDeliveryLine(strong: nil, text: AgentCopy.expired, link: sendAgain)
        case .notSent: return notSent(reason: delivery.reason, context: context)
        case .cancelled: return MessageDeliveryLine(strong: AgentCopy.notSent, text: AgentCopy.stopped, link: sendAgain)
        case .needsReferent:
            // 후보가 없으면 고를 것이 없다: "Queued"뿐이다
            guard !delivery.candidates.isEmpty else { return MessageDeliveryLine(strong: nil, text: AgentCopy.queued) }
            return MessageDeliveryLine(strong: nil, text: AgentCopy.queued, link: Link(.chooseReferent(delivery.candidates), AgentCopy.chooseReferent))
        case .answered, .unknown: return nil
        }
    }

    private static func queued(reason: AgentDeliveryReason?, context: AgentDeliveryContext) -> String {
        switch reason {
        case .sessionExternal?: return "\(AgentCopy.queued) · \(AgentCopy.sessionInTerminal)"
        case .questionOpen?: return "\(AgentCopy.queued) · \(AgentCopy.answerFirst)"
        case nil:
            // D4a-09: 이유가 없고 그 대화 연결의 대상 상태가 unreachable일 때뿐이다
            return context.targetState == .unreachable ? "\(AgentCopy.queued) · \(AgentCopy.macOffline)" : AgentCopy.queued
        default: return AgentCopy.queued
        }
    }

    private static func notSent(reason: AgentDeliveryReason?, context: AgentDeliveryContext) -> MessageDeliveryLine {
        let sendAgain = Link(.sendAgain, sendAgainTitle)
        guard let reason else { return MessageDeliveryLine(strong: AgentCopy.notSent, text: nil, link: sendAgain) }
        switch reason {
        case .signInNeeded: return MessageDeliveryLine(strong: AgentCopy.notSent, text: context.agentName.map(AgentCopy.notSignedIn(to:)), link: sendAgain)
        case .writeGateClosed: return MessageDeliveryLine(strong: AgentCopy.notSent, text: AgentCopy.accessNotVerified, link: sendAgain)
        case .notConnected: return MessageDeliveryLine(strong: AgentCopy.notSent, text: AgentCopy.notConnected, link: sendAgain)
        case .unsupported: return MessageDeliveryLine(strong: AgentCopy.notSent, text: AgentCopy.unsupported, link: sendAgain)
        case .sessionClosed:
            // 닫힌 세션은 다시 보낼 곳이 없다
            return MessageDeliveryLine(strong: AgentCopy.notSent, text: AgentCopy.reasonWords(reason))
        default: return MessageDeliveryLine(strong: AgentCopy.notSent, text: AgentCopy.reasonWords(reason), link: sendAgain)
        }
    }

    /// 한 줄로 이은 글 (접근성 이름 · 시험). 링크는 따로 누르는 동작이라 넣지 않는다
    public var combined: String {
        [strong, text].compactMap { $0 }.joined(separator: " · ")
    }
}

/// 전달 줄을 옮기는 데 필요한 화면 밖 사실: 에이전트 이름(Not signed in to …) · 그 대화 연결의 대상 상태(Mac is offline)
public struct AgentDeliveryContext: Equatable, Sendable {
    public var agentName: String?
    public var targetState: AgentTargetState?

    public init(agentName: String? = nil, targetState: AgentTargetState? = nil) {
        self.agentName = agentName
        self.targetState = targetState
    }
}
