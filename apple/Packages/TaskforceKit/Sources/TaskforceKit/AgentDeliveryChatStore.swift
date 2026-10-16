import Foundation

// 에이전트 대화의 전달 (OA D4a-1, 계약 D4a-10 · 11): ChatStore에 더하는 동작. 상태는 `ChatStore.swift`가 쥐고 (U2가 고정한 경합 규칙은 그대로),
// 규칙은 `AgentDeliveryRules.swift`(순수 함수)에 있다. 여기는 그 규칙을 서버 요청에 잇는다.
// - 전달 줄 다시 읽기: 대화를 열 때 · 온라인 복귀 · 깸에 처음부터 읽고, 안 끝난 줄(sent · queued · needs_referent)이 보이는 동안 5초마다 그 줄 앞부터 읽는다
// - Send again: not_sent · expired는 `POST …/deliver {message_ids:[서버 id]}` (서버가 칩을 쥐고 있어 앱을 다시 켜도 칩이 그대로다), cancelled는 같은 글 · 같은 칩을 새 `client_message_id`로 보낸다
// - 후보 고르기: `POST …/messages/{id}/referent`
// 모든 응답은 부른 계정이 지금도 그대로일 때만 반영한다. 서버의 한국어 거절 문구는 쓰지 않는다. 사용자 글은 로그에 남기지 않는다.

extension MessageDeliveryLine {
    /// 이 전달 표시에 Send again이 있나: not_sent · expired · cancelled (닫힌 세션의 not_sent는 다시 보낼 곳이 없다)
    public static func allowsSendAgain(_ delivery: AgentDelivery) -> Bool {
        switch delivery.state {
        case .expired, .cancelled: true
        case .notSent: delivery.reason != .sessionClosed
        case .accepted, .sent, .outcomeUnknown, .queued, .answered, .needsReferent, .unknown: false
        }
    }
}

extension ChatStore {
    // MARK: 보이는 대화

    /// 지금 보이는 에이전트 대화 (공유 `currentID` · 열린 창들 · 세션 패널). 서버에 있는 것만
    func shownAgentConversations() -> [UUID] {
        var shown = viewedConversations().union(panelConversations())
        if let id = currentID { shown.insert(id) }
        return shown.filter { id in conversations.contains { $0.id == id } && conversationTarget(for: id).isAgent }.sorted { $0.uuidString < $1.uuidString }
    }

    /// 한 대화에서 내가 보낸 메시지 (id · seq)
    func userMessages(of id: UUID) -> [(id: UUID, seq: Int)] {
        (threads[id]?.messages ?? []).filter { $0.role.isUser }.map { (id: $0.id, seq: $0.seq) }
    }

    // MARK: 다시 읽기

    /// 보이는 에이전트 대화의 전달 표시를 처음부터 읽는다 (온라인 복귀 · 깸)
    func refreshShownDeliveries() async {
        for id in shownAgentConversations() { await refreshDeliveries(id) }
    }

    /// 한 에이전트 대화의 전달 표시를 서버에서 **처음부터** 읽는다 (대화를 열 때 · 온라인 복귀 · 깸 · 요청이 실패했을 때): 서버가 사실이다
    public func refreshDeliveries(_ id: UUID) async {
        await readDeliveries(id, full: true)
    }

    /// 5초 읽기: 안 끝난 가장 낮은 seq 바로 앞부터. 읽을 것이 없으면 읽지 않는다
    private func pollDeliveries(_ id: UUID) async {
        await readDeliveries(id, full: false)
    }

    private func readDeliveries(_ id: UUID, full: Bool) async {
        guard let gateway = agentConversation, let token = scope.token, conversations.contains(where: { $0.id == id }), conversationTarget(for: id).isAgent else { return }
        // 이미 읽는 중이면 그 읽기가 서버 값을 가져온다 (끝나면 그 읽기가 5초 시계를 건다)
        guard deliveryReadInFlight.insert(id).inserted else { return }
        defer { deliveryReadInFlight.remove(id) }
        var since: Int?
        if !full {
            switch AgentDeliveryReadPolicy.plan(messages: userMessages(of: id), book: deliveryBook, hasRead: deliveryRead.contains(id)) {
            case .skip:
                scheduleDeliveryPolling()
                return
            case .read(let from): since = from
            }
        }
        let started = tombstoneClock
        let sequence = (deliveryReadSeq[id] ?? 0) + 1
        deliveryReadSeq[id] = sequence
        let readStart = tickRow()
        while true {
            let page: ConversationDeliveryResponse
            do {
                page = try await gateway.deliveries(conversationID: id, sinceSeq: since)
            } catch {
                // 읽기 실패: 앞 줄을 그대로 둔다 (오류 말을 만들지 않는다). 안 끝난 줄이 있으면 다음 5초에 다시 읽는다
                guard scope.isCurrent(token), deliveryReadSeq[id] == sequence else { return }
                scheduleDeliveryPolling()
                return
            }
            // 계정이 떠났거나 · 더 나중에 시작한 읽기가 있거나 · 그 사이 서버가 대화를 없다고 확인했으면 이 응답은 버린다
            guard scope.isCurrent(token), deliveryReadSeq[id] == sequence, !isStale(id, since: started) else { return }
            deliveryBook.merge(page.messages, readStartedAt: readStart, appliedAt: tickRow())
            deliveryRead.insert(id)
            guard let next = AgentDeliveryReadPolicy.nextSince(afterPage: page.messages) else { break }
            since = next
        }
        scheduleDeliveryPolling()
    }

    // MARK: 5초 시계

    /// 안 끝난 줄이 보이는 동안 5초 뒤 다시 읽는다. 없거나 잠자면 걸지 않는다
    func scheduleDeliveryPolling() {
        deliveryPoll?.cancel()
        deliveryPoll = nil
        let unsettled = shownAgentConversations().contains { id in
            AgentDeliveryReadPolicy.hasUnsettled(messages: userMessages(of: id).map(\.id), book: deliveryBook)
        }
        guard let delay = AgentDeliveryReadPolicy.pollInterval(unsettled: unsettled, asleep: isAsleep) else { return }
        let sleep = sleep
        deliveryPoll = Task { [weak self] in
            await sleep(delay)
            guard !Task.isCancelled, let self else { return }
            for id in self.shownAgentConversations() { await self.pollDeliveries(id) }
            self.scheduleDeliveryPolling()
        }
    }

    /// 앱(Mac)이 잠잔다 · 깼다: 자는 동안 5초 읽기가 멈추고, 깨면 한 번 (처음부터) 읽는다
    public func setAsleep(_ asleep: Bool) {
        guard asleep != isAsleep else { return }
        isAsleep = asleep
        if asleep {
            deliveryPoll?.cancel()
            deliveryPoll = nil
        } else {
            spawn { await self.refreshShownDeliveries() }
        }
    }

    // MARK: Send again

    public func canSendAgain(_ messageID: UUID, in conversationID: UUID) -> Bool {
        guard agentConversation != nil, !sendAgainInFlight.contains(messageID), let delivery = deliveryBook.delivery(for: messageID) else { return false }
        return MessageDeliveryLine.allowsSendAgain(delivery)
    }

    /// Send again. 메시지 id별로 진행 중이면 다시 누른 것은 무시한다 (두 번 눌러도 요청은 하나).
    /// - not_sent · expired: `deliver {message_ids:[서버 id]}`. requeued → 응답의 delivery로 줄을 바꾼다 · skipped/unknown_outcome → Unknown 줄 · 그 밖의 skipped → 다시 읽는다
    /// - cancelled: 같은 글 · 같은 칩을 **새** `client_message_id`로 보내 새 메시지를 만든다 (원래 줄은 그대로)
    /// - 요청이 실패하면 줄은 그대로 두고 (새 말 없음) 서버가 사실이라 다시 읽는다
    public func sendAgain(_ messageID: UUID, in conversationID: UUID) async {
        guard let gateway = agentConversation, let token = scope.token, canSendAgain(messageID, in: conversationID),
              let delivery = deliveryBook.delivery(for: messageID) else { return }
        sendAgainInFlight.insert(messageID)
        defer { sendAgainInFlight.remove(messageID) }
        if delivery.state == .cancelled {
            guard let message = threads[conversationID]?.messages.first(where: { $0.id == messageID }) else { return }
            let chips = message.clientMessageID.flatMap { sentChips[$0] } ?? []
            await send(message.text, in: conversationID, attachments: chips, clearsDraft: false)
            return
        }
        let started = tombstoneClock
        do {
            let response = try await gateway.deliver(conversationID: conversationID, messageIDs: [messageID])
            guard scope.isCurrent(token), !isStale(conversationID, since: started) else { return }
            guard let result = response.messages.first(where: { $0.messageID == messageID }) else {
                await refreshDeliveries(conversationID)
                return
            }
            switch (result.result, result.skippedReason) {
            case (.requeued, _):
                guard let next = result.delivery else {
                    await refreshDeliveries(conversationID)
                    return
                }
                deliveryBook.record(next, for: messageID, at: tickRow())
                scheduleDeliveryPolling()
            case (.skipped, .unknownOutcome?):
                deliveryBook.record(result.delivery ?? AgentDelivery(state: .outcomeUnknown), for: messageID, at: tickRow())
            default:
                await refreshDeliveries(conversationID)
            }
        } catch {
            guard scope.isCurrent(token) else { return }
            if let api = error as? APIError, api.isFeatureOff { isUnavailable = true }
            await refreshDeliveries(conversationID)
        }
    }

    // MARK: 후보 고르기

    /// `needs_referent`의 후보 하나를 고른다. 응답의 새 전달 표시로 줄을 바꾼다. 두 번 눌러도 요청은 하나. 실패하면 줄은 그대로 두고 다시 읽는다
    public func chooseReferent(_ actionID: UUID, for messageID: UUID, in conversationID: UUID) async {
        guard let gateway = agentConversation, let token = scope.token, !referentInFlight.contains(messageID),
              deliveryBook.delivery(for: messageID)?.state == .needsReferent else { return }
        referentInFlight.insert(messageID)
        defer { referentInFlight.remove(messageID) }
        let started = tombstoneClock
        do {
            let posted = try await gateway.setReferent(conversationID: conversationID, messageID: messageID, actionID: actionID)
            guard scope.isCurrent(token), !isStale(conversationID, since: started) else { return }
            deliveryBook.record(posted.delivery, for: messageID, at: tickRow())
            scheduleDeliveryPolling()
        } catch {
            guard scope.isCurrent(token) else { return }
            if let api = error as? APIError, api.isFeatureOff { isUnavailable = true }
            await refreshDeliveries(conversationID)
        }
    }
}
