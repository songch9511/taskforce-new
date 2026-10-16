import Foundation
import Testing
@testable import TaskforceKit

/// 레일 Review 타일 (OA U1 · U2b): 노랑 needs-you 또는 없음. 판정은 서버가 한 것(Review 큐)을 모아 보일 뿐이다.
/// OA U2b: 타일은 답할 것이 있을 때만 있다. 복귀 요약의 바뀐 것은 타일의 입력이 아니다 (셸 시험 `noTileWhenOnlyChangesWait`가 지킨다)
struct AssistantReviewTileTests {
    // MARK: 상태 판정

    @Test func theTileExistsOnlyWhenSomethingWaitsForAnAnswer() {
        #expect(ReviewTileRules.content(reviewCount: 2, reviewEnabled: true, summaryEnabled: true) == .needsYou(count: 2))
        #expect(ReviewTileRules.content(reviewCount: 1, reviewEnabled: true, summaryEnabled: true) == .needsYou(count: 1))
        #expect(ReviewTileRules.content(reviewCount: 0, reviewEnabled: true, summaryEnabled: true) == nil, "비면 타일 자체가 없다 (비활성이 아니다)")
    }

    /// 타일은 Review(S4)와 복귀 요약(C3)이 둘 다 켜졌을 때만 (U1-23)
    @Test func theTileNeedsBothReviewAndSummaryFlags() {
        #expect(ReviewTileRules.content(reviewCount: 3, reviewEnabled: false, summaryEnabled: true) == nil)
        #expect(ReviewTileRules.content(reviewCount: 3, reviewEnabled: true, summaryEnabled: false) == nil)
        #expect(ReviewTileRules.content(reviewCount: 3, reviewEnabled: false, summaryEnabled: false) == nil)
        #expect(ReviewTileRules.content(reviewCount: 3, reviewEnabled: true, summaryEnabled: true) == .needsYou(count: 3))
    }

    // MARK: 툴팁 · 이름

    @Test func tooltipSaysWhatWaits() {
        #expect(ReviewTileRules.tooltip(.needsYou(count: 2)) == "Review · Needs your answer")
    }

    @Test func theAccessibleNameCarriesTheCountAndTheScreenNeverDoes() {
        #expect(ReviewTileRules.accessibilityName(.needsYou(count: 3)) == "Review · Needs your answer, 3 items")
        #expect(ReviewTileRules.accessibilityName(.needsYou(count: 1)) == "Review · Needs your answer, 1 item")
        #expect(!ReviewTileRules.tooltip(.needsYou(count: 3)).contains("3"), "화면(툴팁)에는 개수가 없다")
    }
}
