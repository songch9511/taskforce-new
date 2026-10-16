import Foundation
import Testing
@testable import TaskforceKit

/// 전달 다시 읽기 규칙 (OA D4a-10): 순수 함수 하나가 언제 · 어디서부터 읽을지 정한다. `sent` · `queued` · `needs_referent`인 내 메시지가 보이는 동안 5초마다,
/// 그 밖과 앱이 잠잘 때는 멈춘다. `since_seq` 이어 읽기는 100개 단위다. 읽은 값을 쥔 값에 합치는 규칙(`AgentDeliveryBook`)도 여기서 본다
struct AgentDeliveryRulesTests {
    typealias Policy = AgentDeliveryReadPolicy

    func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "d0000000-0000-4000-8000-%012d", n))! }
    func entry(_ n: Int, seq: Int? = nil, _ state: AgentDeliveryState, reason: AgentDeliveryReason? = nil) -> ConversationDeliveryResponse.Entry {
        ConversationDeliveryResponse.Entry(messageID: id(n), seq: seq ?? n, delivery: AgentDelivery(state: state, reason: reason))
    }

    // MARK: 언제

    @Test func onlySentQueuedAndNeedsReferentKeepPolling() {
        let pollable: [AgentDeliveryState] = [.sent, .queued, .needsReferent]
        let others: [AgentDeliveryState] = [.accepted, .notSent, .expired, .cancelled, .answered, .outcomeUnknown, .unknown("x")]
        for state in pollable { #expect(Policy.isPollable(state), "\(state.raw)") }
        for state in others { #expect(!Policy.isPollable(state), "\(state.raw)") }
    }

    @Test func thePollIsFiveSecondsWhileSomethingIsUnsettledAndNeverWhileAsleep() {
        #expect(Policy.interval == 5)
        #expect(Policy.pollInterval(unsettled: true, asleep: false) == 5)
        #expect(Policy.pollInterval(unsettled: false, asleep: false) == nil, "없으면 멈춘다")
        #expect(Policy.pollInterval(unsettled: true, asleep: true) == nil, "앱이 잠자면 멈춘다")
        #expect(Policy.pollInterval(unsettled: false, asleep: true) == nil)
    }

    // MARK: 어디서부터

    private func plan(messages: [(Int, Int)], book: AgentDeliveryBook, hasRead: Bool) -> Policy.Plan {
        Policy.plan(messages: messages.map { (id: id($0.0), seq: $0.1) }, book: book, hasRead: hasRead)
    }

    @Test func theFirstReadOfAConversationReadsEverythingFromTheStart() {
        #expect(plan(messages: [(1, 1), (2, 2)], book: AgentDeliveryBook(), hasRead: false) == .read(since: nil))
        // 메시지가 없어도 처음엔 읽는다 (서버가 사실이다)
        #expect(plan(messages: [], book: AgentDeliveryBook(), hasRead: false) == .read(since: nil))
    }

    @Test func laterReadsStartJustBeforeTheLowestUnsettledSeq() {
        var book = AgentDeliveryBook()
        book.record(AgentDelivery(state: .accepted), for: id(1), at: 1)
        book.record(AgentDelivery(state: .queued), for: id(7), at: 2)
        book.record(AgentDelivery(state: .sent), for: id(12), at: 3)
        #expect(plan(messages: [(1, 1), (7, 7), (12, 12)], book: book, hasRead: true) == .read(since: 6), "가장 낮은 안 끝난 seq 7 바로 앞부터")
        #expect(plan(messages: [(7, 1), (12, 2)], book: book, hasRead: true) == .read(since: 0), "seq 1이면 since_seq=0 (nil이 아니다)")
    }

    @Test func nothingUnsettledMeansNoReadAndAMessageWithoutALineIsRead() {
        var book = AgentDeliveryBook()
        book.record(AgentDelivery(state: .accepted), for: id(1), at: 1)
        book.record(AgentDelivery(state: .notSent, reason: .usageLimited), for: id(2), at: 2)
        book.record(AgentDelivery(state: .answered), for: id(3), at: 3)
        #expect(plan(messages: [(1, 1), (2, 2), (3, 3)], book: book, hasRead: true) == .skip)
        // 이미 읽은 뒤에 다른 기기에서 보낸 메시지(줄을 모른다)는 읽는다
        #expect(plan(messages: [(1, 1), (2, 2), (3, 3), (4, 9)], book: book, hasRead: true) == .read(since: 8))
    }

    @Test func aHundredEntriesMeanAnotherPageAndAShortPageEndsTheRead() {
        let full = (1...100).map { entry($0, .accepted) }
        #expect(Policy.pageSize == 100)
        #expect(Policy.nextSince(afterPage: full) == 100, "100개: 이어 읽는다 (마지막 seq 뒤부터)")
        #expect(Policy.nextSince(afterPage: Array(full.prefix(99))) == nil, "100개보다 적으면 끝이다")
        #expect(Policy.nextSince(afterPage: []) == nil)
        let shifted = (101...200).map { entry($0, seq: $0, .accepted) }
        #expect(Policy.nextSince(afterPage: shifted) == 200)
    }

    @Test func theUnsettledCheckLooksOnlyAtMessagesThatCanStillChange() {
        var book = AgentDeliveryBook()
        book.record(AgentDelivery(state: .accepted), for: id(1), at: 1)
        #expect(!Policy.hasUnsettled(messages: [id(1)], book: book))
        book.record(AgentDelivery(state: .needsReferent), for: id(2), at: 2)
        #expect(Policy.hasUnsettled(messages: [id(1), id(2)], book: book))
        #expect(!Policy.hasUnsettled(messages: [id(1), id(3)], book: book), "줄을 모르는 메시지는 5초 읽기를 만들지 않는다 (한 번 읽는다)")
    }

    // MARK: 합치기

    @Test func aReadFillsAnEmptyBookAndReplacesOlderLines() {
        var book = AgentDeliveryBook()
        book.merge([entry(1, .sent), entry(2, .queued)], readStartedAt: 1, appliedAt: 2)
        #expect(book.delivery(for: id(1))?.state == .sent && book.delivery(for: id(2))?.state == .queued)
        book.merge([entry(1, .accepted)], readStartedAt: 3, appliedAt: 4)
        #expect(book.delivery(for: id(1))?.state == .accepted, "나중에 시작한 읽기가 이긴다")
    }

    /// 읽기를 시작한 뒤에 내가 쓴 것(Send again 응답 · 후보 고르기)이 그 읽기의 옛 응답에 덮이지 않는다
    @Test func aWriteAfterTheReadStartedBeatsTheOlderAnswerButARereadAfterItWins() {
        var book = AgentDeliveryBook()
        book.record(AgentDelivery(state: .notSent), for: id(1), at: 5)
        book.record(AgentDelivery(state: .queued), for: id(1), at: 9)
        book.merge([entry(1, .notSent)], readStartedAt: 7, appliedAt: 10)
        #expect(book.delivery(for: id(1))?.state == .queued, "읽기(7)를 시작한 뒤(9)에 쓴 값이 이긴다")
        book.merge([entry(1, .accepted)], readStartedAt: 11, appliedAt: 12)
        #expect(book.delivery(for: id(1))?.state == .accepted, "쓴 뒤에 시작한 읽기는 이긴다")
    }

    @Test func resetForgetsEverything() {
        var book = AgentDeliveryBook()
        book.record(AgentDelivery(state: .sent), for: id(1), at: 1)
        book.reset()
        #expect(book.delivery(for: id(1)) == nil && book == AgentDeliveryBook())
    }
}
