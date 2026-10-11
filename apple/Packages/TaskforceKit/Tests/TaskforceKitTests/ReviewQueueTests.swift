import Foundation
import Testing
@testable import TaskforceKit

/// S4 Review의 화면 없는 규칙: 서버 순서 · stable id · 가장 새 항목 · 큐가 바뀔 때 보던 항목 · 본문 화면 · 질문 · meta · 원문
struct ReviewQueueTests {
    static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!
    }

    static func review(_ n: Int, activity: TimeInterval, reasons: [String] = ["기한 확인"]) -> ActionSummary {
        ActionSummary(
            id: id(n), title: "Review \(n)", owner: .me, status: .open, dueDate: nil, counterpart: nil, needsConfirmation: true,
            confirmReasons: reasons, startedAt: nil, lastActivityAt: Date(timeIntervalSince1970: activity)
        )
    }

    /// 서버 순서: last_activity_at 오름차순 (오래된 것이 앞)
    let queue = ReviewQueue([review(1, activity: 100), review(2, activity: 200), review(3, activity: 300), review(4, activity: 400)])

    // MARK: 답 · 번호 키

    @Test func onlyTheTwoRealV1WritesHaveKeys() {
        #expect(ReviewAnswer.allCases == [.confirm, .dismiss])
        #expect(ReviewAnswer(key: 1) == .confirm && ReviewAnswer(key: 2) == .dismiss)
        // 세 번째 행동은 v1에 없다: 3은 아무 답도 아니다
        #expect(ReviewAnswer(key: 3) == nil && ReviewAnswer(key: 0) == nil && ReviewAnswer(key: 4) == nil)
        #expect(ReviewAnswer.confirm.label == "Confirm" && ReviewAnswer.dismiss.label == "Dismiss")
    }

    // MARK: 가장 새 항목 (⌘1)

    @Test func newestIsTheLatestActivityNotTheFirstRow() {
        #expect(queue.newest?.id == Self.id(4))
        // 서버 순서가 달라져도 규칙은 last_activity_at이다
        let shuffled = ReviewQueue([Self.review(3, activity: 300), Self.review(4, activity: 400), Self.review(1, activity: 100), Self.review(2, activity: 200)])
        #expect(shuffled.newest?.id == Self.id(4))
    }

    @Test func newestTieGoesToTheLaterServerRow() {
        let tied = ReviewQueue([Self.review(1, activity: 500), Self.review(2, activity: 500)])
        #expect(tied.newest?.id == Self.id(2))
        #expect(ReviewQueue([]).newest == nil)
    }

    // MARK: id로 가리킨다

    @Test func itemsAreFoundByIDNotByPosition() {
        #expect(queue.index(of: Self.id(3)) == 2 && queue.item(Self.id(3))?.title == "Review 3")
        // 앞 항목이 빠져도 같은 id는 같은 항목이다 (index만 바뀐다)
        let after = ReviewQueue(Array(queue.items.dropFirst()))
        #expect(after.index(of: Self.id(3)) == 1 && after.item(Self.id(3))?.title == "Review 3")
        #expect(after.item(Self.id(1)) == nil && !after.contains(Self.id(1)))
    }

    @Test func neighborStopsAtTheEndsWithoutWrapping() {
        #expect(queue.neighbor(of: Self.id(2), offset: 1) == Self.id(3))
        #expect(queue.neighbor(of: Self.id(2), offset: -1) == Self.id(1))
        #expect(queue.neighbor(of: Self.id(1), offset: -1) == Self.id(1), "처음에서 ←는 멈춘다")
        #expect(queue.neighbor(of: Self.id(4), offset: 1) == Self.id(4), "끝에서 →는 멈춘다")
        #expect(queue.neighbor(of: Self.id(99), offset: 1) == nil, "큐에 없는 id에서는 어디로도 가지 않는다")
    }

    // MARK: 큐가 바뀔 때 보던 항목

    @Test func successorIsTheNextLiveItemElseTheClosestEarlierOne() {
        let before = queue.ids
        // 2가 빠짐 → 뒤에 있던 3
        #expect(ReviewQueue.successor(of: Self.id(2), previous: before, current: [1, 3, 4].map(Self.id)) == Self.id(3))
        // 2와 3이 함께 빠짐 → 4
        #expect(ReviewQueue.successor(of: Self.id(2), previous: before, current: [1, 4].map(Self.id)) == Self.id(4))
        // 마지막 4가 빠짐 → 앞에서 가장 가까운 3
        #expect(ReviewQueue.successor(of: Self.id(4), previous: before, current: [1, 2, 3].map(Self.id)) == Self.id(3))
        // 이어받을 항목이 없다
        #expect(ReviewQueue.successor(of: Self.id(4), previous: before, current: []) == nil)
        // 이전 큐에 없던 id는 이어받지 않는다
        #expect(ReviewQueue.successor(of: Self.id(9), previous: before, current: before) == nil)
    }

    @Test func aReorderedQueueKeepsShowingTheSameItem() {
        let reordered = ReviewQueue([queue.items[2], queue.items[0], queue.items[3], queue.items[1]])
        #expect(reordered.resolving(Self.id(2), previous: queue.ids) == Self.id(2), "순서가 바뀌어도 보던 id가 그대로")
    }

    @Test func aRemovedItemHandsOverToItsSuccessorNeverToTheSamePosition() {
        // 2를 보던 중 2가 빠졌다: 같은 index의 항목이 아니라 "그 뒤를 이은 항목"
        let after = ReviewQueue([queue.items[0], queue.items[2], queue.items[3]])
        #expect(after.resolving(Self.id(2), previous: queue.ids) == Self.id(3))
        // 보던 것이 없으면(처음 열었거나 큐가 비었다 채워짐) 가장 새 항목
        #expect(queue.resolving(nil, previous: []) == Self.id(4))
        // 큐가 비면 아무것도 보이지 않는다
        #expect(ReviewQueue([]).resolving(Self.id(2), previous: queue.ids) == nil)
    }

    // MARK: 본문 화면

    @Test func theBodyDoesNotClaimAnEmptyQueueBeforeTheListArrives() {
        #expect(ReviewScreen.of(load: .loading, hasDecision: false) == .blank)
        #expect(ReviewScreen.of(load: .offline, hasDecision: false) == .offline)
        #expect(ReviewScreen.of(load: .failed, hasDecision: false) == .failed)
        #expect(ReviewScreen.of(load: .loaded(problem: nil), hasDecision: false) == .empty(problem: nil))
        #expect(ReviewScreen.of(load: .loaded(problem: .failed), hasDecision: false) == .empty(problem: .failed))
        #expect(ReviewScreen.of(load: .loaded(problem: nil), hasDecision: true) == .decision(problem: nil))
        // 목록이 없을 때는 결정이 있다고 해도(저장본 등) 보이지 않는다
        #expect(ReviewScreen.of(load: .loading, hasDecision: true) == .blank)
        #expect(ReviewScreen.of(load: .offline, hasDecision: true) == .offline)
    }

    @Test func answersAreOnlyOfferedWhileOnlineWithADecisionShown() {
        #expect(ReviewScreen.decision(problem: nil).canAnswer)
        #expect(ReviewScreen.decision(problem: .failed).canAnswer, "마지막 읽기가 실패했어도 서버에 닿을 수 있다: 쓰기가 사실을 알려 준다")
        #expect(!ReviewScreen.decision(problem: .offline).canAnswer, "오프라인에서는 나중에 보내려고 모아 두지 않는다")
        for screen in [ReviewScreen.blank, .offline, .failed, .empty(problem: nil)] { #expect(!screen.canAnswer) }
    }

    // MARK: 글자

    @Test func theQuestionIsTheExistingConfirmReasonWording() {
        #expect(ReviewCopy.question(Self.review(1, activity: 0, reasons: ["판정 확인: NOT_MY_ACTION", "기한 확인"])) == "Not sure it's yours")
        #expect(ReviewCopy.question(Self.review(1, activity: 0, reasons: ["병합 확인 (55%)"])) == "Update may not belong here")
        #expect(ReviewCopy.question(Self.review(1, activity: 0, reasons: [])) == "Needs review", "이유가 없으면 기존 대체 문구")
        #expect(ReviewCopy.question(Self.review(1, activity: 0, reasons: ["unknown-code"])) == "Needs review")
    }

    @Test func theMetaNamesAProjectOnlyForConfirmedMemberships() {
        #expect(ReviewCopy.meta(memberships: .unknown) == "Needs your answer")
        #expect(ReviewCopy.meta(memberships: .none) == "Needs your answer")
        let shape = WorkProject(id: Self.id(10), name: "Shape launch")
        let acme = WorkProject(id: Self.id(11), name: "Acme website")
        let old = WorkProject(id: Self.id(12), name: "Old launch", isArchived: true)
        #expect(ReviewCopy.meta(memberships: .known(links: [WorkLink(project: shape, origin: .user)], candidates: [])) == "Needs your answer · Shape launch")
        // 모델이 제안한 후보는 이름을 붙이지 않는다
        #expect(ReviewCopy.meta(memberships: .known(links: [], candidates: [WorkCandidate(project: shape, confidence: 0.9)])) == "Needs your answer")
        // 여러 프로젝트는 하나로 합치지 않고 이름을 모두 · 보관된 범위는 그렇게 적는다
        #expect(
            ReviewCopy.meta(memberships: .known(links: [WorkLink(project: acme, origin: .auto), WorkLink(project: old, origin: .user)], candidates: []))
                == "Needs your answer · Acme website, Old launch · Archived"
        )
        // "Waiting"은 쓰지 않는다
        #expect(!ReviewCopy.needsYourAnswer.contains("Waiting"))
    }

    // MARK: 원문

    static func line(_ n: Int, quote: String, at seconds: TimeInterval, service: SourceService = .gmail, url: URL? = nil, title: String? = "Thread") -> EvidenceLine {
        EvidenceLine(
            id: id(100 + n), quote: quote, sourceID: id(200 + n), sourceTitle: title, occurredAt: Date(timeIntervalSince1970: seconds),
            externalURL: url, service: service
        )
    }

    @Test func theSourceIsReadingFailedOrWhateverWasActuallyRead() {
        #expect(ReviewSource.of(digest: nil, failed: false) == .loading)
        #expect(ReviewSource.of(digest: nil, failed: true) == .failed)
        #expect(ReviewSource.of(digest: EvidenceDigest(lines: []), failed: false) == .noQuote)
    }

    @Test func quotesAreShownNewestFirstAsTheyWereSaid() {
        let digest = EvidenceDigest(lines: [
            Self.line(1, quote: "Friday works", at: 100), Self.line(2, quote: "Could we do Thursday instead?", at: 300, url: URL(string: "https://mail.google.com/x")),
        ])
        guard case .lines(let lines) = ReviewSource.of(digest: digest, failed: false) else {
            Issue.record("quotes expected")
            return
        }
        #expect(lines.map(\.text) == ["Could we do Thursday instead?", "Friday works"], "가장 최근 근거가 위")
        #expect(lines[0].url?.host == "mail.google.com" && lines[1].url == nil && lines[0].service == .gmail && lines[0].place == "Thread")
    }

    @Test func aRemovedSlackQuoteIsStatedAsRemovedNeverAsAQuote() {
        let digest = EvidenceDigest(lines: [Self.line(1, quote: RemovedQuote.slackDisconnected, at: 100, service: .slack)])
        guard case .lines(let lines) = ReviewSource.of(digest: digest, failed: false) else {
            Issue.record("a line expected")
            return
        }
        #expect(lines[0].removed && lines[0].text.isEmpty)
    }

    @Test func executionReceiptsAreNotSourcesOfADecision() {
        let receipt = EvidenceLine(
            id: Self.id(150), quote: "초안 저장: 제안서", sourceID: Self.id(250), sourceTitle: "제안서", occurredAt: Date(timeIntervalSince1970: 900),
            externalURL: nil, service: .manual(.execution)
        )
        let digest = EvidenceDigest(lines: [Self.line(1, quote: "Real words", at: 100), receipt])
        guard case .lines(let lines) = ReviewSource.of(digest: digest, failed: false) else {
            Issue.record("quotes expected")
            return
        }
        #expect(lines.map(\.text) == ["Real words"])
        #expect(ReviewSource.of(digest: EvidenceDigest(lines: [receipt]), failed: false) == .noQuote)
    }
}
