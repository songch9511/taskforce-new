import Foundation
import Testing
@testable import TaskforceKit

/// 복귀 요약의 글자 · 표시 규칙 (순수 함수). 핵심: 비어 있다는 말은 어디에도 없고(완전한 빈 응답은 아무것도 그리지 않는다),
/// 읽지 못함 · 일부 실패 · 잘림 · 모르는 값은 정직하게 말하며, 숫자(개수)가 없고, 지운 원문은 글이 아니라 토큰의 말로만 보인다
struct ReturnSummaryRulesTests {
    typealias Fx = ReturnSummaryFx
    let utc = TimeZone(secondsFromGMT: 0)!
    let now = Date.test(0)

    func content(
        _ summary: ReturnSummaryResponse?, isStale: Bool = false, readFailed: Bool = false, cursorSpent: Bool = false, isClearing: Bool = false,
        message: String? = nil, canOpen: @escaping (UUID) -> Bool = { _ in true }
    ) -> ReturnSummaryContent? {
        ReturnSummaryPresentation.make(
            summary: summary, isStale: isStale, readFailed: readFailed, cursorSpent: cursorSpent, isClearing: isClearing, message: message,
            now: now, timeZone: utc, canOpen: canOpen
        )
    }

    // MARK: 카드 캡션

    @Test func theCaptionIsSinceAndWhenTheLastClearWas() {
        #expect(ReturnSummaryCopy.title(since: .test(-3_600), now: now, timeZone: utc) == "Since today 08:00")
        #expect(ReturnSummaryCopy.title(since: .test(-86_400), now: now, timeZone: utc) == "Since yesterday 09:00")
        #expect(ReturnSummaryCopy.title(since: .test(-5 * 86_400), now: now, timeZone: utc) == "Since Oct 6")
    }

    /// 마지막 Clear 시각을 모르면 시각을 지어내지 않는다 (첫 기준 시각은 열린 제품 결정)
    @Test func withoutASinceTheCaptionDoesNotInventATime() {
        #expect(ReturnSummaryCopy.title(since: nil, now: now, timeZone: utc) == "Changes")
        let never = Fx.response([Fx.item(1, changes: [Fx.change()])], since: nil, baseline: .neverCleared)
        #expect(content(never)?.title == "Changes")
        // 기준이 cleared가 아니면 since가 있어도 쓰지 않는다 (모르는 기준을 시각으로 말하지 않는다)
        let unknownBaseline = Fx.response([Fx.item(1, changes: [Fx.change()])], since: -3_600, baseline: .unknown)
        #expect(content(unknownBaseline)?.title == "Changes")
        let cleared = Fx.response([Fx.item(1, changes: [Fx.change()])], since: -3_600, baseline: .cleared)
        #expect(content(cleared)?.title == "Since today 08:00")
    }

    // MARK: 변화 글 (기존 앱 문구 재사용 + 새 문구)

    @Test func actionEventTokensReadAsShortPhrases() {
        func text(_ kind: String, _ state: ReturnSummarySourceState? = .available) -> String? {
            ReturnSummaryCopy.change(Fx.change(.actionEvent, kind, sourceState: state))
        }
        #expect(text("due_changed") == "Due date changed")
        #expect(text("scope_changed") == "Details changed")
        #expect(text("owner_changed") == "Owner changed")
        #expect(text("merged") == "Mentioned again")
        #expect(text("completed") == "Completed")
        #expect(text("dropped") == "Canceled")
        #expect(text("reopened") == "Reopened")
        #expect(text("artifact_created") == "Draft ready")
        #expect(text("teleported") == nil)
    }

    @Test func runResultsReuseTheRunLaneWords() {
        func text(_ kind: String, _ detail: String? = nil) -> String? {
            ReturnSummaryCopy.change(Fx.change(.run, kind, detail: detail))
        }
        #expect(text("done", "draft_ready") == "Draft ready")
        #expect(text("done", "needs_input") == "Taskforce has a question")
        #expect(text("done", "needs_connection") == "Needs a connection")
        #expect(text("done", "needs_capability") == "Needs a connection")
        #expect(text("done", "review_failed") == "Review failed")
        #expect(text("done", "agent_done") == "Agent finished")
        #expect(text("done", "something_new") == "Run finished")
        #expect(text("done") == "Run finished")
        #expect(text("failed") == "Couldn't finish the draft")
        #expect(text("exploded") == nil)
    }

    @Test func messageTokens() {
        #expect(ReturnSummaryCopy.change(Fx.change(.message, "assistant")) == "New reply")
        #expect(ReturnSummaryCopy.change(Fx.change(.message, "event")) == "New update")
        #expect(ReturnSummaryCopy.change(Fx.change(.message, "gossip")) == nil)
        #expect(ReturnSummaryCopy.change(Fx.change(.unknown, "done")) == nil)
    }

    /// 지운 원문 · 접근 상실 · 보관 만료는 글이나 옛 제목이 아니라 토큰의 말이다 (Remembered · 초안과 같은 말)
    @Test func aGoneSourceIsAWordNotAQuote() {
        func text(_ state: ReturnSummarySourceState) -> String? {
            ReturnSummaryCopy.change(Fx.change(.actionEvent, "scope_changed", sourceState: state))
        }
        #expect(text(.available) == "Details changed")
        #expect(text(.deleted) == "Details changed · Original text deleted")
        #expect(text(.accessLost) == "Details changed · The source is no longer available")
        #expect(text(.textExpired) == "Details changed · Text deleted after 90 days.")
        #expect(text(.unknown) == "Details changed")
        #expect(ReturnSummaryCopy.sourceDeleted == MemoryCopy.purgedStatement && ReturnSummaryCopy.sourceUnavailable == MemoryCopy.sourceMissing)
        // 토큰을 모르는 변화에 원문이 지워졌다는 사실만 있어도 그 말은 남는다
        #expect(ReturnSummaryCopy.change(Fx.change(.actionEvent, "teleported", sourceState: .deleted)) == "Original text deleted")
    }

    // MARK: 줄의 보조 글

    @Test func needsYourAnswerLeadsThenChangesThenNext() {
        let both = Fx.item(1, needsAnswer: true, changes: [Fx.change(.run, "done", detail: "review_failed")])
        #expect(ReturnSummaryCopy.detail(both) == "Needs your answer · Review failed")
        let result = Fx.item(2, changes: [Fx.change(.run, "done", detail: "draft_ready")], next: .reviewResult)
        #expect(ReturnSummaryCopy.detail(result) == "Draft ready · Next: review the result")
        let onlyAnswer = Fx.item(3, needsAnswer: true)
        #expect(ReturnSummaryCopy.detail(onlyAnswer) == "Needs your answer")
        // answer · open은 Next를 더 말하지 않는다 (강조가 이미 말한다 / 줄 자체가 그 작업을 연다)
        #expect(ReturnSummaryCopy.next(ReturnSummaryNext(kind: .answer, decisionKinds: [.confirm])) == nil)
        #expect(ReturnSummaryCopy.next(ReturnSummaryNext(kind: .open)) == nil)
        #expect(ReturnSummaryCopy.detail(Fx.item(4)) == nil, "말할 것이 없는 줄은 제목만")
    }

    @Test func repeatedPhrasesAppearOnceAndOnlyTheLatestThreeAreSaid() {
        let many = Fx.item(1, changes: [
            Fx.change(.actionEvent, "due_changed", at: 1), Fx.change(.actionEvent, "due_changed", at: 2),
            Fx.change(.actionEvent, "scope_changed", at: 3), Fx.change(.actionEvent, "owner_changed", at: 4), Fx.change(.actionEvent, "merged", at: 5),
        ])
        #expect(ReturnSummaryCopy.detail(many) == "Details changed · Owner changed · Mentioned again")
    }

    /// 숫자 없음 (디자인 D-12): 줄 글에 개수를 말하는 문구가 없다
    @Test func noCountsAnywhereInTheCopy() {
        let items = (1...12).map { Fx.item($0, title: "Work \($0)", needsAnswer: $0 % 2 == 0, changes: [Fx.change(), Fx.change(.run, "done", detail: "draft_ready")]) }
        let shown = content(Fx.response(items, complete: false, changes: .truncated))!
        let texts = shown.rows.compactMap(\.detail) + shown.notes.map(\.text) + [shown.title]
        for text in texts {
            #expect(text.rangeOfCharacter(from: .decimalDigits) == nil || text.hasPrefix("Since"), "\(text)")
            #expect(!text.localizedCaseInsensitiveContains("more") && !text.localizedCaseInsensitiveContains("others"), "\(text)")
        }
    }

    // MARK: 무엇을 보이나 · 무엇을 보이지 않나

    @Test func nothingShowsBeforeTheFirstReadOrWhenTheFeatureIsOff() {
        #expect(content(nil) == nil)
    }

    @Test func aFailedFirstReadSaysSoInsteadOfBeingEmpty() {
        let failed = content(nil, readFailed: true)
        #expect(failed?.rows.isEmpty == true && failed?.notes == [.couldNotLoad] && failed?.showsCard == false)
        #expect(failed?.notes.first?.text == "Couldn't load changes" && failed?.notes.first?.offersRetry == true)
        #expect(failed?.canClear == false)
    }

    /// 완전한 빈 응답은 아무것도 그리지 않는다: "변화 없음" 같은 문구는 이 앱 어디에도 없다
    @Test func aCompleteEmptyResponseDrawsNothingAndNothingSaysAllCaughtUp() {
        let empty = Fx.response([])
        #expect(empty.isEmpty)
        #expect(content(empty) == nil)
    }

    @Test func anIncompleteEmptyLookingResponseIsNeverHiddenOrCalledEmpty() {
        let cases: [(ReturnSummaryResponse, [ReturnSummaryContent.Note])] = [
            (Fx.response([], complete: false, changes: .unavailable), [.couldNotLoad]),
            (Fx.response([], complete: false, decisions: .unavailable), [.couldNotLoadDecisions]),
            (Fx.response([], complete: false, changes: .unavailable, decisions: .unavailable), [.couldNotLoad, .couldNotLoadDecisions]),
            (Fx.response([], complete: false, changes: .truncated), [.someNotShown]),
            (Fx.response([], complete: false, changes: .unknown), [.someNotShown]),
            (Fx.response([], complete: false, empty: true), [.someNotShown]),
        ]
        for (summary, notes) in cases {
            let shown = content(summary)
            #expect(shown?.notes == notes && shown?.rows.isEmpty == true && shown?.canClear == false, "\(notes)")
        }
    }

    @Test func partialAndTruncatedPagesKeepTheirRowsAndSayTheyAreIncomplete() {
        let rows = [Fx.item(1, changes: [Fx.change()])]
        #expect(content(Fx.response(rows, complete: false, changes: .truncated))?.notes == [.someNotShown])
        #expect(content(Fx.response(rows, complete: false, changes: .unavailable))?.notes == [.couldNotLoad])
        #expect(content(Fx.response(rows, complete: false, decisions: .unavailable))?.notes == [.couldNotLoadDecisions])
        // 모르는 값이 든 줄은 줄은 보이되 완전하다고 하지 않는다
        let unknown = Fx.response([Fx.item(1, state: .unknown, changes: [Fx.change()])])
        let shown = content(unknown)
        #expect(shown?.rows.count == 1 && shown?.rows[0].progress == nil && shown?.notes == [.someNotShown])
        #expect(content(Fx.response(rows))?.notes == [])
    }

    @Test func aStaleListKeepsItsRowsButCannotBeClearedAndSaysItIsStale() {
        let summary = Fx.withChanges
        let fresh = content(summary)
        #expect(fresh?.canClear == true && fresh?.notes == [])
        let stale = content(summary, isStale: true)
        #expect(stale?.rows.count == 2 && stale?.canClear == false && stale?.notes == [.couldNotLoad])
    }

    // MARK: Clear 가시성

    @Test func clearNeedsAServerCursorAndSomethingToMarkRead() {
        func canClear(_ summary: ReturnSummaryResponse, stale: Bool = false, spent: Bool = false) -> Bool {
            ReturnSummaryPresentation.canClear(summary, isStale: stale, cursorSpent: spent)
        }
        let changed = [Fx.item(1, changes: [Fx.change()])]
        #expect(canClear(Fx.response(changed)))
        #expect(!canClear(Fx.response(changed, cursor: nil)), "커서가 없으면 보이지 않는다")
        #expect(!canClear(Fx.response(changed), stale: true), "다시 읽지 못했다")
        #expect(!canClear(Fx.response(changed), spent: true), "이미 쓴 커서는 다시 보내지 않는다")
        // 결정만 있는 줄: Clear가 할 일이 없다 (서버 applied:false). 그래도 줄은 남는다 — 읽음은 결정이 아니다
        let onlyDecision = Fx.response([Fx.item(1, needsAnswer: true)])
        #expect(!canClear(onlyDecision))
        #expect(content(onlyDecision)?.rows.count == 1)
    }

    /// 서버가 잘린 쪽에도 커서를 주면(P2-C) Clear는 보인다. 잘림 자체로 보이고 숨기지 않는다
    @Test func truncationAloneNeverDecidesClear() {
        let changed = [Fx.item(1, changes: [Fx.change()])]
        let withCursor = Fx.response(changed, complete: false, changes: .truncated)
        let withoutCursor = Fx.response(changed, cursor: nil, complete: false, changes: .truncated)
        #expect(content(withCursor)?.canClear == true && content(withCursor)?.notes == [.someNotShown])
        #expect(content(withoutCursor)?.canClear == false && content(withoutCursor)?.notes == [.someNotShown])
    }

    // MARK: 줄

    @Test func rowsFollowTheServersOrderAndCarryOnlyStableFacts() {
        let summary = Fx.response([
            Fx.item(2, title: "B", needsAnswer: true), Fx.item(1, title: "A", state: .done, changes: [Fx.change()]),
            Fx.item(3, title: "C", state: nil, changes: [Fx.change(.actionEvent, "dropped")]),
        ])
        let rows = content(summary)!.rows
        #expect(rows.map(\.title) == ["B", "A", "C"], "순서는 서버가 정한다")
        #expect(rows.map(\.id) == [Fx.id(2), Fx.id(1), Fx.id(3)])
        #expect(rows.map(\.progress) == [.inProgress, .done, nil])
        #expect(rows[0].highlight == "Needs your answer" && rows[1].highlight == nil)
    }

    @Test func rowsThatHaveNowhereToGoAreNotOpenable() {
        let summary = Fx.response([Fx.item(1, changes: [Fx.change()]), Fx.item(2, changes: [Fx.change()])])
        let rows = content(summary, canOpen: { $0 == Fx.id(1) })!.rows
        #expect(rows.map(\.canOpen) == [true, false])
    }

    @Test func theMessageOnlyAccompaniesRows() {
        #expect(content(Fx.withChanges, message: "This changed somewhere else. It's been refreshed.")?.message == "This changed somewhere else. It's been refreshed.")
        let noRows = content(Fx.response([], complete: false, changes: .unavailable), message: "x")
        #expect(noRows?.message == nil)
    }

    /// 어떤 상태에서도 "다 봤다 · 변화 없음" 같은 문구를 만들지 않는다
    @Test func noStateEverProducesAnAllClearSentence() {
        let states: [ReturnSummaryContent?] = [
            content(nil), content(nil, readFailed: true), content(Fx.response([])), content(Fx.withChanges),
            content(Fx.response([], complete: false, changes: .unavailable)), content(Fx.response([], complete: false, changes: .truncated)),
            content(Fx.withChanges, isStale: true), content(Fx.withChanges, isClearing: true, message: "m"),
        ]
        let banned = ["caught up", "nothing changed", "no changes", "all handled", "all clear", "nothing new", "all done"]
        for state in states.compactMap({ $0 }) {
            let text = ([state.title] + state.rows.compactMap(\.detail) + state.notes.map(\.text) + [state.message ?? ""]).joined(separator: " ").lowercased()
            for phrase in banned { #expect(!text.contains(phrase), "\(phrase)") }
        }
    }
}
