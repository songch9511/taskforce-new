import Foundation

// 에이전트 대화의 전달 (OA D4a-1, 계약 D4a-10 · 11): ChatStore에 더하는 동작. 상태는 `ChatStore.swift`가 쥐고 (U2가 고정한 경합 규칙은 그대로),
// 규칙은 `AgentDeliveryRules.swift`(순수 함수)에 있다. 여기는 그 규칙을 서버 요청에 잇는다.
// - 전달 줄 다시 읽기: 대화를 열 때 · 온라인 복귀 · 깸에 처음부터 읽고, 안 끝난 줄(sent · queued · needs_referent)이 보이는 동안 5초마다 그 줄 앞부터 읽는다
// - Send again: not_sent · expired는 `POST …/deliver {message_ids:[서버 id]}` (서버가 칩을 쥐고 있어 앱을 다시 켜도 칩이 그대로다), cancelled는 같은 글 · 같은 칩을 새 `client_message_id`로 보낸다
// - 후보 고르기: `POST …/messages/{id}/referent`
// 모든 응답은 부른 계정이 지금도 그대로일 때만 반영한다. 서버의 한국어 거절 문구는 쓰지 않는다. 사용자 글은 로그에 남기지 않는다.

/// Send again · 후보 고르기가 서버에 거절됐거나(동의 철회 · 409 · 기능 꺼짐 · 전송 오류) 앱이 막은(원래 칩을 모른다) 메시지의 안내.
/// 전달 읽기가 **그 메시지를 덮어쓰지는 않지만**(같은 미전달 상태로 읽히는 동안은 남는다) 서버가 전달이 진전했다고 읽혀 주면(`sent` · `accepted` … 상태가 달라짐) 사라진다:
/// 요청은 서버에 닿았는데 응답만 못 받은 경우에 "Not sent"가 남지 않게 한다 (U2 12.1: 새로 읽은 서버 값이 이긴다).
/// 기존 Chat의 동의 안내 · 오류 줄(`ChatTurn.Status`)로 보이고 Try again(`retryDelivery`)이 같은 동작을 다시 한다
struct AgentDeliveryNotice: Equatable {
    enum Action: Equatable {
        case sendAgain
        case referent(UUID)
    }

    enum Failure: Equatable {
        case needsConsent
        case failed(String)
    }

    let action: Action
    let failure: Failure
    /// 안내가 생긴 때의 전달 상태: 이 상태로 읽히는 동안만 남는다
    let state: AgentDeliveryState

    var chatStatus: ChatTurn.Status {
        switch failure {
        case .needsConsent: .needsConsent
        case .failed(let reason): .failed(reason)
        }
    }
}

/// 원래 칩을 모르는 cancelled를 새 메시지로 다시 보낼 수 없다 (오류 말은 기존 일반 문장: 새 문구 없음)
private struct SendAgainWithoutOriginalChips: Error {}

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

    /// 한 에이전트 대화의 전달 표시를 서버에서 **처음부터** 읽는다 (대화를 열 때 · 온라인 복귀 · 깸): 서버가 사실이다
    public func refreshDeliveries(_ id: UUID) async {
        await readDeliveries(id, full: true, followsMyRequest: false)
    }

    /// 내 요청(Send again · 후보 고르기)이 서버를 바꿨을 수 있어 다시 읽는다. 읽는 중이면 그 읽기는 요청 **전에** 시작했으니 옛 값을 가져올 수 있다 → 끝난 뒤 한 번 더 읽는다
    func refreshDeliveries(afterMyRequestIn id: UUID) async {
        await readDeliveries(id, full: true, followsMyRequest: true)
    }

    /// 5초 읽기: 안 끝난 가장 낮은 seq 바로 앞부터. 읽을 것이 없으면 읽지 않는다
    private func pollDeliveries(_ id: UUID) async {
        await readDeliveries(id, full: false, followsMyRequest: false)
    }

    private func readDeliveries(_ id: UUID, full: Bool, followsMyRequest: Bool) async {
        guard agentConversation != nil, scope.token != nil, conversations.contains(where: { $0.id == id }), conversationTarget(for: id).isAgent else { return }
        // 이미 읽는 중이면 그 읽기가 서버 값을 가져온다 (끝나면 그 읽기가 5초 시계를 건다). 단 내 요청 뒤의 읽기는 그 읽기가 끝난 뒤 한 번 더 한다
        guard deliveryReadInFlight.insert(id).inserted else {
            if followsMyRequest { deliveryReadFollowUp.insert(id) }
            return
        }
        defer { deliveryReadInFlight.remove(id) }
        var wantsFull = full
        repeat {
            deliveryReadFollowUp.remove(id)
            await readDeliveriesOnce(id, full: wantsFull)
            wantsFull = true
        } while deliveryReadFollowUp.contains(id)
    }

    private func readDeliveriesOnce(_ id: UUID, full: Bool) async {
        guard let gateway = agentConversation, let token = scope.token else { return }
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
            dropNoticesThatProgressed()
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
    /// - cancelled: 같은 글 · 같은 칩을 **새** `client_message_id`로 보내 새 메시지를 만든다 (원래 줄은 그대로). **원래 칩을 모르면 보내지 않는다**:
    ///   "모른다"(앱을 다시 켰다: 서버가 칩을 읽게 주지 않는다)와 "칩이 없었다"(이번 실행에서 칩 없이 보냈다)는 다르다 — 모르는 채 칩 없이 보내면 지정했던 이슈 대신 다른 이슈에서 실행될 수 있다 (D4a-07)
    /// - 서버가 거절하거나(동의 철회 · 409 · 기능 꺼짐 · 전송 오류) 앱이 막으면 그 메시지에 기존 Chat의 동의 안내 · 오류 줄을 남긴다 (전달 읽기와 별개, Try again = `retryDelivery`)
    public func sendAgain(_ messageID: UUID, in conversationID: UUID) async {
        guard let gateway = agentConversation, let token = scope.token, canSendAgain(messageID, in: conversationID),
              let delivery = deliveryBook.delivery(for: messageID) else { return }
        sendAgainInFlight.insert(messageID)
        defer { sendAgainInFlight.remove(messageID) }
        deliveryNotices[messageID] = nil
        if delivery.state == .cancelled {
            guard let message = threads[conversationID]?.messages.first(where: { $0.id == messageID }) else { return }
            guard let cmid = message.clientMessageID, let chips = sentChips[cmid] else {
                deliveryNotices[messageID] = AgentDeliveryNotice(
                    action: .sendAgain, failure: .failed(ReadFailure.userMessage(SendAgainWithoutOriginalChips())), state: delivery.state
                )
                return
            }
            await send(message.text, in: conversationID, attachments: chips, clearsDraft: false)
            return
        }
        let started = tombstoneClock
        do {
            let response = try await gateway.deliver(conversationID: conversationID, messageIDs: [messageID])
            guard scope.isCurrent(token), !isStale(conversationID, since: started) else { return }
            guard let result = response.messages.first(where: { $0.messageID == messageID }) else {
                await refreshDeliveries(afterMyRequestIn: conversationID)
                return
            }
            switch (result.result, result.skippedReason) {
            case (.requeued, _):
                guard let next = result.delivery else {
                    await refreshDeliveries(afterMyRequestIn: conversationID)
                    return
                }
                deliveryBook.record(next, for: messageID, at: tickRow())
                scheduleDeliveryPolling()
                // 대기열이 비어 있으면 바로 새 턴이 시작된다: 세션을 다시 읽게 한다
                onAgentTurnMayStart?()
            case (.skipped, .unknownOutcome?):
                deliveryBook.record(result.delivery ?? AgentDelivery(state: .outcomeUnknown), for: messageID, at: tickRow())
            default:
                await refreshDeliveries(afterMyRequestIn: conversationID)
            }
        } catch {
            guard scope.isCurrent(token), !isStale(conversationID, since: started) else { return }
            noteDeliveryFailure(error, for: messageID, action: .sendAgain, state: delivery.state)
            await refreshDeliveries(afterMyRequestIn: conversationID)
        }
    }

    // MARK: 후보 고르기

    /// `needs_referent`의 후보 하나를 고른다. 응답의 새 전달 표시로 줄을 바꾼다. 두 번 눌러도 요청은 하나.
    /// 실패하면 줄은 그대로 두고 그 메시지에 동의 안내 · 오류 줄을 남긴다 (Try again이 같은 후보를 다시 고른다). 서버가 사실이라 다시 읽는다
    public func chooseReferent(_ actionID: UUID, for messageID: UUID, in conversationID: UUID) async {
        guard let gateway = agentConversation, let token = scope.token, !referentInFlight.contains(messageID),
              deliveryBook.delivery(for: messageID)?.state == .needsReferent else { return }
        referentInFlight.insert(messageID)
        defer { referentInFlight.remove(messageID) }
        deliveryNotices[messageID] = nil
        let started = tombstoneClock
        do {
            let posted = try await gateway.setReferent(conversationID: conversationID, messageID: messageID, actionID: actionID)
            guard scope.isCurrent(token), !isStale(conversationID, since: started) else { return }
            deliveryBook.record(posted.delivery, for: messageID, at: tickRow())
            scheduleDeliveryPolling()
            // 후보를 고르면 막혀 있던 메시지가 시작될 수 있다: 세션을 다시 읽게 한다
            onAgentTurnMayStart?()
        } catch {
            guard scope.isCurrent(token), !isStale(conversationID, since: started) else { return }
            noteDeliveryFailure(error, for: messageID, action: .referent(actionID), state: .needsReferent)
            await refreshDeliveries(afterMyRequestIn: conversationID)
        }
    }

    // MARK: 거절 · 오류 안내

    /// 거절의 종류를 기존 Chat의 말로 옮긴다 (`failed(_:turnID:in:)`와 같다): 동의 철회의 409 → 동의 안내 · 기능 꺼짐 → "Chats aren't available yet." · 그 밖 → 한 줄 이유
    private func noteDeliveryFailure(_ error: Error, for messageID: UUID, action: AgentDeliveryNotice.Action, state: AgentDeliveryState) {
        let failure: AgentDeliveryNotice.Failure
        if let api = error as? APIError, api.isFeatureOff {
            isUnavailable = true
            failure = .failed(ChatCopy.unavailable)
        } else if let api = error as? APIError, api.isChatConsentRequired {
            failure = .needsConsent
        } else {
            failure = .failed(ReadFailure.userMessage(error))
        }
        deliveryNotices[messageID] = AgentDeliveryNotice(action: action, failure: failure, state: state)
    }

    /// 서버가 전달이 진전했다고 읽혀 준 메시지의 안내를 지운다 (안내가 생긴 때와 상태가 달라졌다: 그 사이 다른 기기가 보냈거나 요청이 사실은 닿았다)
    func dropNoticesThatProgressed() {
        let kept = deliveryNotices.filter { id, notice in deliveryBook.delivery(for: id)?.state == notice.state }
        if kept.count != deliveryNotices.count { deliveryNotices = kept }
    }

    /// Try again (거절 · 막힘 안내의): 같은 Send again · 같은 후보 고르기를 다시 한다. 그 사이 서버가 그 메시지를 바꿨으면(다른 기기) 아무것도 보내지 않고 안내만 지운다
    public func retryDelivery(_ messageID: UUID, in conversationID: UUID) async {
        guard let notice = deliveryNotices[messageID] else { return }
        // 사용자가 직접 다시 시도했다: 꺼짐 안내를 걷고 서버에 다시 묻는다 (아직 꺼져 있으면 다시 알게 된다)
        isUnavailable = false
        deliveryNotices[messageID] = nil
        switch notice.action {
        case .sendAgain: await sendAgain(messageID, in: conversationID)
        case .referent(let actionID): await chooseReferent(actionID, for: messageID, in: conversationID)
        }
    }
}
