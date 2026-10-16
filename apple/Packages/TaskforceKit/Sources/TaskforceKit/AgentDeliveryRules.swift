import Foundation

// 전달 다시 읽기 규칙 (OA D4a-10, 계약 3.2): 전달 표시는 서버가 계산한다 (`GET …/delivery?since_seq=`, 한 번에 ≤ 100개).
// 앱은 (1) 대화를 열 때 (2) 온라인으로 돌아왔을 때 (3) 잠자기에서 깼을 때 읽고, (4) `sent` · `queued` · `needs_referent`인 내 메시지가 보이는 동안 5초마다 읽는다.
// 이 파일은 그 규칙을 화면 · 네트워크 없이 값으로 둔다 (`ChatStore`가 부른다). 보낸 응답에서 받은 줄만 쥐던 U1의 메모리 표시는 이 읽기가 대신한다 (앱을 다시 켜도 서버가 사실이다).

/// 메시지마다 쥔 전달 표시. 값마다 "쥔 때"(`appliedAt`, 저장소의 단조 시계)를 적는다: 읽기를 시작한 **뒤에** 내가 쓴 값(Send again 응답 · 후보 고르기)은
/// 그 읽기의 옛 응답에 덮이지 않고, 쓴 값 **뒤에** 시작한 읽기는 늘 이긴다 (`ChatStore`의 행 읽기와 같은 규칙)
public struct AgentDeliveryBook: Equatable, Sendable {
    struct Held: Equatable, Sendable {
        var delivery: AgentDelivery
        var appliedAt: Int
    }

    private(set) var entries: [UUID: Held] = [:]

    public init() {}

    public func delivery(for messageID: UUID) -> AgentDelivery? { entries[messageID]?.delivery }

    public var count: Int { entries.count }

    /// 내가 쓴 값 (보내기 · Send again · 후보 고르기의 응답): 늘 반영한다
    public mutating func record(_ delivery: AgentDelivery, for messageID: UUID, at stamp: Int) {
        entries[messageID] = Held(delivery: delivery, appliedAt: stamp)
    }

    /// 읽은 값: 읽기를 시작한 뒤(`readStartedAt`)에 쥔 값이 있으면 그 값이 이긴다. 없거나 그 전에 쥔 값이면 읽은 값으로 바꾼다
    public mutating func merge(_ read: [ConversationDeliveryResponse.Entry], readStartedAt: Int, appliedAt: Int) {
        for entry in read {
            if let held = entries[entry.messageID], held.appliedAt >= readStartedAt { continue }
            entries[entry.messageID] = Held(delivery: entry.delivery, appliedAt: appliedAt)
        }
    }

    public mutating func reset() { entries = [:] }
}

public enum AgentDeliveryReadPolicy {
    /// 안 끝난 줄이 있을 때 다시 읽는 간격 (초)
    public static let interval: TimeInterval = 5
    /// 서버가 한 번에 돌려주는 최대 개수 (`since_seq`로 이어 읽는다)
    public static let pageSize = 100

    /// 아직 바뀔 수 있는 상태: 보냈으나 에이전트가 받지 않았다(sent) · 기다린다(queued) · 후보 고르기를 기다린다(needs_referent).
    /// 끝난 줄(accepted · not_sent · expired · cancelled · answered · unknown)은 다시 읽지 않는다 (Send again이 줄을 바꾸는 것은 그 응답이 직접 쓴다)
    public static func isPollable(_ state: AgentDeliveryState) -> Bool {
        switch state {
        case .sent, .queued, .needsReferent: true
        case .accepted, .notSent, .expired, .cancelled, .answered, .outcomeUnknown, .unknown: false
        }
    }

    /// 다음 읽기까지의 시간. 안 끝난 줄이 없거나(앱이 잠자거나) 하면 nil — 멈춘다
    public static func pollInterval(unsettled: Bool, asleep: Bool) -> TimeInterval? {
        unsettled && !asleep ? interval : nil
    }

    /// 보이는 내 메시지 중 5초마다 읽게 만드는 것이 있다 (줄을 모르는 메시지는 5초 읽기를 만들지 않는다: 한 번 읽는다)
    public static func hasUnsettled(messages: [UUID], book: AgentDeliveryBook) -> Bool {
        messages.contains { id in book.delivery(for: id).map { isPollable($0.state) } ?? false }
    }

    public enum Plan: Equatable, Sendable {
        /// 읽을 것이 없다
        case skip
        /// `since_seq` 뒤부터 읽는다 (nil = 처음부터)
        case read(since: Int?)
    }

    /// 한 대화에서 어디서부터 읽을까. 처음이면 처음부터, 아니면 안 끝난 줄(또는 줄을 모르는 메시지)의 가장 낮은 seq 바로 앞부터 — 없으면 읽지 않는다
    public static func plan(messages: [(id: UUID, seq: Int)], book: AgentDeliveryBook, hasRead: Bool) -> Plan {
        guard hasRead else { return .read(since: nil) }
        let needs = messages.filter { message in book.delivery(for: message.id).map { isPollable($0.state) } ?? true }
        guard let lowest = needs.map(\.seq).min() else { return .skip }
        return .read(since: max(0, lowest - 1))
    }

    /// 한 쪽을 읽은 뒤 이어 읽을 `since_seq`. 꽉 찬 쪽(100개)이면 마지막 seq, 아니면 끝(nil)
    public static func nextSince(afterPage page: [ConversationDeliveryResponse.Entry]) -> Int? {
        guard page.count >= pageSize else { return nil }
        return page.map(\.seq).max()
    }
}
