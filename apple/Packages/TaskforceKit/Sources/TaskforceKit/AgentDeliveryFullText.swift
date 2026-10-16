import Foundation

// View full (OA D4a-17, DS Message "View full"): 서버는 에이전트 글을 20,000자 · 32KB에서 자르고(`content.truncated`) 전문은 에이전트를 돌리는 Mac의 원장에 둔다.
// 이 Mac의 원장에 전문이 있을 때만 링크가 보이고, 누르면 그 자리에서 펼친다 (다른 것은 바꾸지 않는다). 다른 Mac이거나 한 달 정리로 지워졌으면 링크가 없다.
// 원장 찾기는 `Bridge/BridgeLedger+ServerKey.swift`가 서버 열쇠로 한다 (앱이 `fullTextLookup`에 건다).

extension ChatStore {
    /// 한 대화의 잘린 답 중 이 Mac 원장에 전문이 있는 것을 찾아 둔다 (펼치지는 않는다). 부른 계정이 떠났으면 버린다
    func lookupFullTexts(in id: UUID) async {
        guard let lookup = fullTextLookup, let token = scope.token else { return }
        let started = tombstoneClock
        let wanted = (threads[id]?.messages ?? []).filter { $0.content?.truncated == true && $0.externalEventID != nil && fullTexts[$0.id] == nil }
        for message in wanted {
            guard let key = message.externalEventID else { continue }
            let text = await lookup(key)
            guard scope.isCurrent(token), !isStale(id, since: started) else { return }
            if let text, !text.isEmpty { fullTexts[message.id] = text }
        }
    }

    /// View full: 찾아 둔 전문을 그 자리에서 펼친다 (없는 전문은 펼치지 않는다)
    public func viewFull(_ messageID: UUID) {
        guard fullTexts[messageID] != nil else { return }
        fullTextExpanded.insert(messageID)
    }
}
