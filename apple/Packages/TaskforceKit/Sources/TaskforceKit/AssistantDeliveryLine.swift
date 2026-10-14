import Foundation

/// 에이전트 대상 메시지 아래의 전달 한 줄 (OA U1, DS MessageDelivery): 서버가 계산한 `delivery`를 **기존 여섯 단어로만** 옮긴다.
/// Received(accepted) · Sent · Unknown · Queued · **Not sent**(굵게, 빨강 아님) · Expired. 단어만: 아이콘 · 스피너 · 색 없음.
/// 이유 코드(17개) 문구 · "무엇에 대한 지시인가" 후보 고르기 · 취소 · Send again은 D4a가 다듬는다:
/// 그 전에는 여섯에 들지 않는 상태(answered · needs_referent · cancelled · 모르는 값)를 일반 실패 줄 "Not sent"로 보이고, 이유로 문구를 바꾸지 않는다.
public struct MessageDeliveryLine: Equatable, Sendable {
    /// 굵은 text-primary 부분 (Not sent뿐)
    public let strong: String?
    /// 보조 글(secondary) 부분
    public let text: String?

    public init(strong: String?, text: String?) {
        self.strong = strong
        self.text = text
    }

    public static let notSent = MessageDeliveryLine(strong: "Not sent", text: nil)

    public static func of(_ delivery: AgentDelivery) -> MessageDeliveryLine {
        switch delivery.state {
        case .accepted: MessageDeliveryLine(strong: nil, text: "Received")
        case .sent: MessageDeliveryLine(strong: nil, text: "Sent")
        case .outcomeUnknown: MessageDeliveryLine(strong: nil, text: "Unknown · Not confirmed by the agent")
        case .queued: MessageDeliveryLine(strong: nil, text: "Queued")
        case .expired: MessageDeliveryLine(strong: nil, text: "Expired · Older than 24 hours")
        case .notSent, .answered, .needsReferent, .cancelled, .unknown: .notSent
        }
    }

    /// 한 줄로 이은 글 (접근성 이름 · 시험)
    public var combined: String {
        [strong, text].compactMap { $0 }.joined(separator: " · ")
    }
}
