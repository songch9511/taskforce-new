import Foundation
import Testing
@testable import TaskforceKit

/// 레일 Review 타일 (OA U1): 노랑 needs-you · 조용한 changes · 없음. 판정은 서버가 한 것(Review 큐 · 복귀 요약)을 모아 보일 뿐이다.
/// 툴팁 시각 규칙(U1-25): 오늘 "6:40 PM" · 어제 "Yesterday, 6:40 PM" · 그 전 "Oct 12, 6:40 PM"
struct AssistantReviewTileTests {
    /// 한국 시간대 (UTC+9) 기준 달력. 시험은 시스템 시간대를 읽지 않는다
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    func date(_ y: Int, _ m: Int, _ d: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour, minute: minute))!
    }

    // MARK: 상태 판정

    @Test func needsYouOutranksChangesAndNothingMeansNoTile() {
        let withChanges = ReturnSummaryFx.withChanges
        #expect(ReviewTileRules.content(reviewCount: 2, summary: withChanges, reviewEnabled: true, summaryEnabled: true) == .needsYou(count: 2))
        guard case .changes(_, let count) = ReviewTileRules.content(reviewCount: 0, summary: withChanges, reviewEnabled: true, summaryEnabled: true) else {
            Issue.record("changes여야 한다")
            return
        }
        #expect(count == 2, "변화가 있는 줄 수")
        #expect(ReviewTileRules.content(reviewCount: 0, summary: nil, reviewEnabled: true, summaryEnabled: true) == nil)
        let empty = ReturnSummaryFx.response([])
        #expect(ReviewTileRules.content(reviewCount: 0, summary: empty, reviewEnabled: true, summaryEnabled: true) == nil, "비면 타일 자체가 없다 (비활성이 아니다)")
    }

    @Test func aRowThatOnlyWaitsForAnAnswerIsNotAChange() {
        let questionsOnly = ReturnSummaryFx.response([ReturnSummaryFx.item(1, needsAnswer: true)])
        #expect(ReviewTileRules.content(reviewCount: 0, summary: questionsOnly, reviewEnabled: true, summaryEnabled: true) == nil, "changes = 읽음 처리할 변화가 있는 줄 (hasChangesToClear)")
    }

    /// 타일은 Review(S4)와 복귀 요약(C3)이 둘 다 켜졌을 때만 (U1-23)
    @Test func theTileNeedsBothReviewAndSummaryFlags() {
        let withChanges = ReturnSummaryFx.withChanges
        #expect(ReviewTileRules.content(reviewCount: 3, summary: withChanges, reviewEnabled: false, summaryEnabled: true) == nil)
        #expect(ReviewTileRules.content(reviewCount: 3, summary: withChanges, reviewEnabled: true, summaryEnabled: false) == nil)
        #expect(ReviewTileRules.content(reviewCount: 3, summary: withChanges, reviewEnabled: false, summaryEnabled: false) == nil)
        #expect(ReviewTileRules.content(reviewCount: 3, summary: nil, reviewEnabled: true, summaryEnabled: true) == .needsYou(count: 3))
    }

    @Test func sinceIsTheLastClearOnlyWhenThereWasOne() {
        let cleared = ReturnSummaryFx.response(ReturnSummaryFx.withChanges.items, since: -3_600, baseline: .cleared)
        guard case .changes(let since, _) = ReviewTileRules.content(reviewCount: 0, summary: cleared, reviewEnabled: true, summaryEnabled: true) else {
            Issue.record("changes여야 한다")
            return
        }
        #expect(since == cleared.since)
        let never = ReturnSummaryFx.response(ReturnSummaryFx.withChanges.items, since: nil, baseline: .neverCleared)
        guard case .changes(let none, _) = ReviewTileRules.content(reviewCount: 0, summary: never, reviewEnabled: true, summaryEnabled: true) else {
            Issue.record("changes여야 한다")
            return
        }
        #expect(none == nil, "한 번도 Clear하지 않았으면 시각을 지어내지 않는다")
        // 기준점만 있는 initialized의 since는 Clear의 시각이 아니다
        let initialized = ReturnSummaryFx.response(ReturnSummaryFx.withChanges.items, since: -3_600, baseline: .initialized)
        guard case .changes(let baselineOnly, _) = ReviewTileRules.content(reviewCount: 0, summary: initialized, reviewEnabled: true, summaryEnabled: true) else {
            Issue.record("changes여야 한다")
            return
        }
        #expect(baselineOnly == nil)
    }

    // MARK: 툴팁 · 이름

    @Test func tooltipSaysWhatWaitsOrSinceWhen() {
        let now = date(2026, 10, 14, 21, 0)
        #expect(ReviewTileRules.tooltip(.needsYou(count: 2), now: now, calendar: calendar) == "Review · Needs your answer")
        #expect(ReviewTileRules.tooltip(.changes(since: date(2026, 10, 14, 18, 40), count: 1), now: now, calendar: calendar) == "Review · Changes since 6:40 PM")
        #expect(ReviewTileRules.tooltip(.changes(since: date(2026, 10, 13, 18, 40), count: 1), now: now, calendar: calendar) == "Review · Changes since Yesterday, 6:40 PM")
        #expect(ReviewTileRules.tooltip(.changes(since: date(2026, 10, 12, 18, 40), count: 1), now: now, calendar: calendar) == "Review · Changes since Oct 12, 6:40 PM")
        #expect(ReviewTileRules.tooltip(.changes(since: nil, count: 1), now: now, calendar: calendar) == "Review · Changes")
    }

    @Test func timeLabelsUseTheTwelveHourClockAndTheCalendarDay() {
        let now = date(2026, 10, 14, 0, 30)
        #expect(ReviewTileRules.timeLabel(date(2026, 10, 14, 0, 5), now: now, calendar: calendar) == "12:05 AM", "자정 직후")
        #expect(ReviewTileRules.timeLabel(date(2026, 10, 13, 23, 59), now: now, calendar: calendar) == "Yesterday, 11:59 PM", "자정 1분 전은 어제")
        #expect(ReviewTileRules.timeLabel(date(2026, 10, 13, 12, 0), now: now, calendar: calendar) == "Yesterday, 12:00 PM")
        #expect(ReviewTileRules.timeLabel(date(2026, 10, 12, 23, 59), now: now, calendar: calendar) == "Oct 12, 11:59 PM", "그제는 날짜")
        // 올해가 아니면 연도가 붙는다 (목록의 날짜 표기와 같다)
        #expect(ReviewTileRules.timeLabel(date(2025, 12, 31, 9, 5), now: now, calendar: calendar) == "Dec 31, 2025, 9:05 AM")
        // 앞으로의 시각(시계가 어긋남)도 오늘이면 시각만
        #expect(ReviewTileRules.timeLabel(date(2026, 10, 14, 8, 0), now: now, calendar: calendar) == "8:00 AM")
    }

    @Test func theTimeZoneOfTheCalendarDecidesToday() {
        // 같은 순간이 UTC에서는 어제, 서울에서는 오늘이다
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        utc.locale = Locale(identifier: "en_US_POSIX")
        let seoulMorning = date(2026, 10, 14, 7, 0)   // UTC 10-13 22:00
        let seoulNow = date(2026, 10, 14, 9, 0)       // UTC 10-14 00:00
        #expect(ReviewTileRules.timeLabel(seoulMorning, now: seoulNow, calendar: calendar) == "7:00 AM")
        #expect(ReviewTileRules.timeLabel(seoulMorning, now: seoulNow, calendar: utc) == "Yesterday, 10:00 PM")
    }

    @Test func theAccessibleNameCarriesTheCountAndTheScreenNeverDoes() {
        let now = date(2026, 10, 14, 21, 0)
        let since = date(2026, 10, 14, 18, 40)
        #expect(ReviewTileRules.accessibilityName(.needsYou(count: 3), now: now, calendar: calendar) == "Review · Needs your answer, 3 items")
        #expect(ReviewTileRules.accessibilityName(.needsYou(count: 1), now: now, calendar: calendar) == "Review · Needs your answer, 1 item")
        #expect(ReviewTileRules.accessibilityName(.changes(since: since, count: 2), now: now, calendar: calendar) == "Review · Changes since 6:40 PM, 2 items")
        #expect(!ReviewTileRules.tooltip(.needsYou(count: 3), now: now, calendar: calendar).contains("3"), "화면(툴팁)에는 개수가 없다")
        #expect(!ReviewTileRules.tooltip(.changes(since: since, count: 2), now: now, calendar: calendar).contains("items"))
    }

    // MARK: 눌렀을 때

    @Test func aClickOpensTheNewestReviewWhenSomethingWaitsAndTheSummaryOtherwise() {
        #expect(ReviewTileRules.destination(for: .needsYou(count: 1)) == .newestReview)
        #expect(ReviewTileRules.destination(for: .changes(since: nil, count: 1)) == .returnSummary)
    }
}
