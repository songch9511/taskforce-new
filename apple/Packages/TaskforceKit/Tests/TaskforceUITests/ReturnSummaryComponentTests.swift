import Foundation
import Testing
import TaskforceKit
@testable import TaskforceUI

/// C3 ReturnSummary · Receipts 부품의 순수 규칙: 줄의 접근성 이름 · StatusMark 대응 · 강조 구절 · 다른 화면 문구와 같은 말 · Receipts 틀의 Retry 규칙
struct ReturnSummaryComponentTests {
    func row(_ title: String = "Pricing page", progress: ReturnSummaryProgress? = .inProgress, needsAnswer: Bool = false, detail: String? = nil) -> ReturnSummaryRow {
        ReturnSummaryRow(id: UUID(), title: title, progress: progress, needsAnswer: needsAnswer, detail: detail)
    }

    @Test func rowNameIsStateTitleThenDetail() {
        #expect(ReturnSummary.accessibilityLabel(row(needsAnswer: true, detail: "Needs your answer · Needs revision")) == "In Progress, Pricing page, Needs your answer · Needs revision")
        #expect(ReturnSummary.accessibilityLabel(row("Launch direction", progress: .done, detail: "Completed")) == "Done, Launch direction, Completed")
        #expect(ReturnSummary.accessibilityLabel(row("Onboarding", progress: .toDo)) == "To Do, Onboarding")
        // 표시가 없는 줄(취소된 작업 · 모르는 상태)은 상태를 지어내지 않는다
        #expect(ReturnSummary.accessibilityLabel(row("Old banner", progress: nil, detail: "Canceled")) == "Old banner, Canceled")
    }

    @Test func statusMarkFollowsTheServerStateAndNeverInventsOne() {
        #expect(ReturnSummary.mark(.toDo) == .toDo && ReturnSummary.mark(.inProgress) == .inProgress && ReturnSummary.mark(.done) == .done)
        #expect(ReturnSummary.mark(nil) == nil && ReturnSummary.mark(.unknown) == nil)
    }

    /// 형광펜은 `Needs your answer`에만 쓴다 (디자인 Highlight: "당신을 기다림"에만): 줄 글 안에 그 구절이 있을 때만 칠한다
    @Test func onlyNeedsYourAnswerIsHighlighted() {
        let asking = row(needsAnswer: true, detail: "Needs your answer · Needs revision")
        #expect(asking.highlight == "Needs your answer" && MarkerText.contains(asking.detail ?? "", phrase: asking.highlight))
        let plain = row(detail: "Draft ready")
        #expect(plain.highlight == nil && !MarkerText.contains(plain.detail ?? "", phrase: plain.highlight))
    }

    @Test func staticWordsComeFromTheDesignAndTheExistingApp() {
        #expect(ReturnSummaryCopy.clear == "Clear" && ReturnSummaryCopy.needsYourAnswer == "Needs your answer")
        #expect(ReturnSummaryCopy.needsYourAnswer == ReviewCopy.needsYourAnswer)
        // 보관 만료 글은 초안 본문과 같은 말이다 (TaskforceKit이 TaskforceUI를 모르므로 여기서 같음을 확인한다)
        #expect(ReturnSummaryCopy.sourceExpired == DraftBody.purgedMessage)
        #expect(ReturnSummaryCopy.tryAgain == "Try again")
        #expect(PanelEmptyKind.allCases.map(\.title).allSatisfy { !$0.localizedCaseInsensitiveContains("caught up") })
    }

    // MARK: Receipts (틀)

    @Test func receiptsRetryAppearsOnlyOnAFailedRowThatCanBeRetried() {
        let ok = Receipts.Item(id: UUID(), title: "Pricing page", outcome: "FAQ shortened · Version 5")
        let failed = Receipts.Item(id: UUID(), title: "Acme pricing", outcome: "Not applied · locked for review", failed: true)
        #expect(!Receipts.showsRetry(ok, hasHandler: true))
        #expect(Receipts.showsRetry(failed, hasHandler: true))
        #expect(!Receipts.showsRetry(failed, hasHandler: false), "다시 할 길이 없는 실패를 버튼으로 꾸미지 않는다")
        #expect(Receipts.retryLabel == "Retry")
    }
}
