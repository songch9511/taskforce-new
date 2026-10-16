import Foundation
import Testing
@testable import TaskforceKit

/// OA U3-28 · 11.1: Taskforce 대화 끝의 "변화만" 복귀 요약. Needs 태그 · 질문만 있는 제목이 없고, 옛 content는 같은 입력에 같은 출력이다 (Release `C3SummaryTests`)
struct ReturnSummaryChangesOnlyTests {
    typealias Fx = ReturnSummaryFx

    private func changesOnly(
        _ response: ReturnSummaryResponse?, isStale: Bool = false, readFailed: Bool = false, cursorSpent: Bool = false, isClearing: Bool = false,
        message: String? = nil
    ) -> ReturnSummaryContent? {
        ReturnSummaryPresentation.makeChangesOnly(
            summary: response, isStale: isStale, readFailed: readFailed, cursorSpent: cursorSpent, isClearing: isClearing, message: message,
            now: .test(0), timeZone: TimeZone(identifier: "UTC")!
        )
    }

    private func legacy(_ response: ReturnSummaryResponse?, readFailed: Bool = false) -> ReturnSummaryContent? {
        ReturnSummaryPresentation.make(
            summary: response, isStale: false, readFailed: readFailed, cursorSpent: false, isClearing: false, message: nil,
            now: .test(0), timeZone: TimeZone(identifier: "UTC")!
        )
    }

    @Test func thereIsNoNeedsTagAndNoHighlight() throws {
        let content = try #require(changesOnly(Fx.withChanges))
        #expect(content.rows.allSatisfy { !$0.needsAnswer && $0.highlight == nil })
        #expect(content.rows.allSatisfy { !($0.detail ?? "").contains("Needs your answer") }, "결정은 요청 카드가 말한다")
        #expect(content.rows.first?.detail == "Needs revision", "같은 줄의 변화 말만 남는다")
        #expect(content.changesOnly)
    }

    @Test func aRowThatOnlyHoldsADecisionIsLeftOut() throws {
        let response = Fx.response([
            Fx.item(1, title: "Waiting on you", needsAnswer: true),
            Fx.item(2, title: "Launch design", changes: [Fx.change(.run, "done", detail: "draft_ready")]),
        ])
        let content = try #require(changesOnly(response))
        #expect(content.rows.map(\.title) == ["Launch design"])
        #expect(try #require(legacy(response)).rows.count == 2, "옛 content는 결정 줄도 그린다 (Release용, 그대로)")
    }

    @Test func aSummaryWithOnlyQuestionsHasNothingToShowAndNeverTheQuestionTitle() {
        let response = Fx.response([Fx.item(1, needsAnswer: true), Fx.item(2, needsAnswer: true)], since: nil, baseline: .neverCleared)
        #expect(changesOnly(response) == nil, "질문만 남은 요약은 빈 메시지를 만들지 않는다")
        #expect(legacy(response)?.title == ReturnSummaryCopy.questionsTitle, "옛 content의 제목 변형은 그대로")
    }

    @Test func theTitleIsSinceOrChangesAndNeverNeedsYourAnswer() throws {
        let cleared = try #require(changesOnly(Fx.withChanges))
        #expect(cleared.title.hasPrefix("Since "))
        let fresh = try #require(changesOnly(Fx.response([Fx.item(1, changes: [Fx.change(.run, "done", detail: "draft_ready")])], since: nil, baseline: .neverCleared)))
        #expect(fresh.title == ReturnSummaryCopy.changesTitle)
        #expect(![cleared.title, fresh.title].contains(ReturnSummaryCopy.needsYourAnswer))
    }

    @Test func theQuestionListNoteIsNotShownBecauseDecisionsAreRequestCards() throws {
        let response = Fx.response([Fx.item(1, changes: [Fx.change(.run, "done", detail: "draft_ready")])], decisions: .unavailable)
        #expect(try #require(changesOnly(response)).notes.isEmpty)
        #expect(try #require(legacy(response)).notes == [.couldNotLoadQuestions], "옛 content는 그대로")
    }

    @Test func theChangeNotesAreTheSameAsBefore() throws {
        let unreadable = Fx.response([Fx.item(1, changes: [Fx.change(.run, "done", detail: "draft_ready")])], changes: .unavailable)
        #expect(try #require(changesOnly(unreadable)).notes == [.couldNotLoad])
        let stale = try #require(changesOnly(Fx.withChanges, isStale: true))
        #expect(stale.notes == [.couldNotLoad] && !stale.canClear, "다시 읽지 못한 줄에는 Clear가 없다")
        #expect(changesOnly(nil) == nil && changesOnly(nil, readFailed: true)?.notes == [.couldNotLoad])
        #expect(changesOnly(nil, readFailed: true)?.changesOnly == true)
    }

    @Test func clearFollowsTheSameRuleAsTheOldCard() throws {
        let response = Fx.withChanges
        #expect(try #require(changesOnly(response)).canClear == (try #require(legacy(response)).canClear))
        #expect(try #require(changesOnly(response)).canClear)
        #expect(try #require(changesOnly(response, cursorSpent: true)).canClear == false, "이미 쓴 커서는 다시 받지 않는다")
        let message = try #require(changesOnly(response, isClearing: true, message: "This changed somewhere else. It's been refreshed."))
        #expect(message.isClearing && message.message == "This changed somewhere else. It's been refreshed.")
    }

    @Test func theOldContentIsUnchangedForTheSameInput() throws {
        // Release `C3SummaryTests`가 고정한 모양: 결정 줄 + 변화 줄, Needs 태그 · 형광펜 구절
        let content = try #require(legacy(Fx.withChanges))
        #expect(content.rows.count == 2 && content.rows[0].detail == "Needs your answer · Needs revision" && content.rows[0].highlight == "Needs your answer")
        #expect(!content.changesOnly)
    }

    @Test func aRowThatCannotBeOpenedKeepsItsPlaceWithoutAnAffordance() throws {
        let response = Fx.response([Fx.item(1, changes: [Fx.change(.run, "done", detail: "draft_ready")]), Fx.item(2, changes: [Fx.change(.run, "done", detail: "draft_ready")])])
        let content = try #require(ReturnSummaryPresentation.makeChangesOnly(
            summary: response, isStale: false, readFailed: false, cursorSpent: false, isClearing: false, message: nil, canOpen: { $0 == Fx.id(1) }
        ))
        #expect(content.rows.map(\.canOpen) == [true, false])
    }
}
