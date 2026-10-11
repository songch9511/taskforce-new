import SwiftUI
import Testing
@testable import TaskforceUI

/// S4 Review의 DecisionBlock · AnswerOption: 디자인 기하 · 보내는 중에는 완료 표시를 하지 않는다
@MainActor
struct DecisionBlockTests {
    @Test func geometryMatchesTheDesign() {
        #expect(AnswerOption.minHeight == 40, "디자인 --answer-row")
        #expect(DecisionBlock<EmptyView>.answerGap == 6, "디자인 .tf-answers gap")
    }

    @Test func onlyTheServersAnswerEarnsTheCheck() {
        // 보내는 중에는 "Chosen"이 아니라 "Sending" (결과를 모른다)
        #expect(AnswerOption.accessibilityValue(.sending) == "Sending")
        #expect(AnswerOption.accessibilityValue(.chosen) == "Chosen")
        #expect(AnswerOption.accessibilityValue(.ready).isEmpty && AnswerOption.accessibilityValue(.locked).isEmpty)
    }

    @Test func answersAreIdentifiedByTheirKey() {
        let answers: [DecisionBlock<EmptyView>.Answer] = [.init(index: 1, label: "Confirm"), .init(index: 2, label: "Dismiss", phase: .locked)]
        #expect(answers.map(\.id) == [1, 2])
        #expect(answers[0].phase == .ready && answers[1].phase == .locked && answers[0].hint == nil)
    }

    @Test func factsAreIdentifiedByStyleAndText() {
        let facts: [DecisionBlock<EmptyView>.Fact] = [.init("Full title", .subject), .init("Due Fri"), .init("Due Yesterday", .urgent)]
        #expect(Set(facts.map(\.id)).count == 3)
        #expect(facts[1].style == .value)
    }
}
