import Foundation
import Observation

/// 후보 고르기 메뉴 (OA D4a-06): `needs_referent`인 메시지 하나의 후보 (≤ 3). 줄의 링크가 연다
public struct AgentReferentMenu: Equatable, Sendable {
    public let messageID: UUID
    public let candidates: [AgentReferentCandidate]
}

extension ChatTurn {
    /// 내 글 아래에 전달 줄 대신 기존 상태 줄(Not sent · 이유 · Try again / 동의 안내)을 보이나: 전달 표시를 아직 모르거나(첫 보내기가 실패했다),
    /// Send again · 후보 고르기가 거절되거나 막혀 오류 · 동의 안내가 붙었을 때 (`ChatStore.deliveryNotices`)
    public var showsStatusInsteadOfDelivery: Bool { delivery == nil || status.canRetry }
}

/// 에이전트 대화의 줄 동작 (OA D4a-1): 전달 줄 말 · Send again · 후보 고르기 메뉴 · View full. **Assistant 창과 세션 패널이 같이 쓴다** (둘 다 같은 `ChatStore`의 대화를 그린다).
/// 상태는 열린 메뉴 하나뿐이고 나머지는 `ChatStore`가 쥔다 (줄 · 진행 중 표시 · 서버 응답)
@MainActor
@Observable
public final class AgentTurnDesk {
    public private(set) var referentMenu: AgentReferentMenu?
    @ObservationIgnored private let chat: ChatStore

    public init(chat: ChatStore) {
        self.chat = chat
    }

    /// 한 줄. 에이전트가 아니거나 전달 표시를 아직 읽지 못했거나 줄이 없는 상태(answered · 모르는 값)면 nil
    public func line(for turn: ChatTurn, context: AgentDeliveryContext) -> MessageDeliveryLine? {
        guard turn.isUser, let delivery = turn.delivery else { return nil }
        return MessageDeliveryLine.of(delivery, context: context)
    }

    public func canSendAgain(_ turn: ChatTurn, in conversationID: UUID) -> Bool {
        chat.canSendAgain(turn.id, in: conversationID)
    }

    /// Send again (서버 메시지 id)
    public func sendAgain(_ turn: ChatTurn, in conversationID: UUID) async {
        await chat.sendAgain(turn.id, in: conversationID)
    }

    /// Try again (거절 · 막힘 안내의): 같은 Send again · 후보 고르기를 다시 한다
    public func retry(_ turn: ChatTurn, in conversationID: UUID) async {
        await chat.retryDelivery(turn.id, in: conversationID)
    }

    /// 줄의 링크: 그 메시지의 후보 메뉴를 연다 (이미 열려 있으면 닫는다). 후보가 없거나 `needs_referent`가 아니면 열지 않는다
    public func openReferentMenu(for messageID: UUID) {
        if referentMenu?.messageID == messageID {
            referentMenu = nil
            return
        }
        guard let delivery = chat.delivery(forMessage: messageID), delivery.state == .needsReferent, !delivery.candidates.isEmpty else { return }
        referentMenu = AgentReferentMenu(messageID: messageID, candidates: delivery.candidates)
    }

    public func closeReferentMenu() {
        referentMenu = nil
    }

    /// 후보 하나를 고른다 (`POST …/referent`): 메뉴는 닫힌다
    public func chooseReferent(_ actionID: UUID, in conversationID: UUID) async {
        guard let menu = referentMenu else { return }
        referentMenu = nil
        await chat.chooseReferent(actionID, for: menu.messageID, in: conversationID)
    }

    /// View full: 이 Mac 원장에서 찾아 둔 전문을 그 자리에서 펼친다
    public func viewFull(_ turn: ChatTurn) {
        chat.viewFull(turn.id)
    }
}
