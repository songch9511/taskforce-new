import Foundation
import Testing
@testable import TaskforceKit

/// Plan & usage의 날짜 · 토큰 표기 (DZ 그림의 한 형식)
struct PlanSummaryFormatTests {
    private func date(_ iso: String, now: String = "2026-10-20T12:00:00Z", calendar: Calendar = PlanFixtures.calendar) -> String {
        PlanSummaryFormat.date(PlanFixtures.at(iso), now: PlanFixtures.at(now), calendar: calendar)
    }

    @Test func aDateInTheCurrentYearIsMonthAndDay() {
        #expect(date("2026-11-08T00:00:00Z") == "Nov 8")
        #expect(date("2026-10-22T09:30:00Z") == "Oct 22")
        #expect(date("2026-01-01T00:00:00Z") == "Jan 1")
        #expect(date("2026-12-31T23:59:59Z") == "Dec 31")
    }

    @Test func aDateInAnotherYearAddsTheYear() {
        #expect(date("2027-10-08T00:00:00Z") == "Oct 8, 2027")
        #expect(date("2027-12-31T00:00:00Z") == "Dec 31, 2027")
        #expect(date("2025-03-05T00:00:00Z") == "Mar 5, 2025")
    }

    @Test func theMonthNamesAreEnglishWhateverTheDeviceLocale() {
        var calendar = PlanFixtures.calendar
        calendar.locale = Locale(identifier: "ko_KR")
        #expect(date("2026-11-08T00:00:00Z", calendar: calendar) == "Nov 8")
    }

    @Test func theDayIsTheCalendarDayInTheDeviceTimeZone() {
        var seoul = PlanFixtures.calendar
        seoul.timeZone = TimeZone(identifier: "Asia/Seoul")!
        #expect(date("2026-11-08T18:00:00Z", calendar: seoul) == "Nov 9", "UTC 18시는 서울 다음 날 03시")
        var la = PlanFixtures.calendar
        la.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        #expect(date("2026-11-08T03:00:00Z", calendar: la) == "Nov 7")
    }

    @Test func theYearBoundaryUsesTheSameCalendarForBothDates() {
        // 연말 직전에 보는 다음 해 날짜
        #expect(date("2027-01-02T00:00:00Z", now: "2026-12-31T20:00:00Z") == "Jan 2, 2027")
    }

    @Test(arguments: [
        (0, "0 tokens"), (1, "1 token"), (2, "2 tokens"), (850, "850 tokens"), (999, "999 tokens"),
        (1_000, "1.0K tokens"), (12_340, "12.3K tokens"), (12_350, "12.4K tokens"), (999_940, "999.9K tokens"),
        (999_950, "1.0M tokens"), (1_000_000, "1.0M tokens"), (2_400_000, "2.4M tokens"), (9_800_000, "9.8M tokens"),
        (142_600_000, "142.6M tokens"), (1_284_600_000, "1,284.6M tokens"), (12_345_678_900, "12,345.7M tokens"),
    ])
    func tokensAreOneDecimalWithGroupedMillions(_ count: Int, _ expected: String) {
        #expect(PlanSummaryFormat.tokens(count) == expected)
    }

    @Test func aNegativeCountIsZero() {
        #expect(PlanSummaryFormat.tokens(-5) == "0 tokens")
    }
}
