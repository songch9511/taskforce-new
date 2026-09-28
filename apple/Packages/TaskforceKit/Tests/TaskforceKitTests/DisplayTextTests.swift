import Foundation
import Testing
@testable import TaskforceKit

struct DisplayTextTests {
    let today = LocalDate("2026-09-27")!  // 일요일

    @Test(arguments: [
        ("2026-09-27", "Today"),
        ("2026-09-28", "Tomorrow"),
        ("2026-09-26", "Yesterday"),
        ("2026-09-29", "Tue"),
        ("2026-10-03", "Sat"),
        ("2026-10-04", "Oct 4"),
        ("2026-09-22", "Sep 22"),
        ("2027-01-05", "Jan 5, 2027"),
        ("2025-12-31", "Dec 31, 2025"),
    ])
    func shortDue(_ due: String, _ expected: String) {
        #expect(DueText.short(LocalDate(due)!, today: today) == expected)
    }

    @Test func launcherAccessorySaysOverdueForPastDates() {
        #expect(DueText.accessory(LocalDate("2026-09-26")!, today: today) == "Overdue")
        #expect(DueText.accessory(LocalDate("2026-09-01")!, today: today) == "Overdue")
        #expect(DueText.accessory(LocalDate("2026-09-27")!, today: today) == "Today")
        #expect(DueText.accessory(LocalDate("2026-09-30")!, today: today) == "Wed")
        #expect(DueText.accessory(LocalDate("2026-10-30")!, today: today) == "Oct 30")
    }

    @Test func urgentMatchesRankReasonRule() {
        // 서버 이유가 있으면 그대로 (RankReason.isUrgent)
        #expect(DueText.isUrgent(due: nil, reasons: [.overdue], today: today))
        #expect(DueText.isUrgent(due: nil, reasons: [.dueToday], today: today))
        #expect(!DueText.isUrgent(due: LocalDate("2026-09-29"), reasons: [.dueSoon, .external], today: today))
        // 이유가 없는 확인 요청은 기한으로 같은 판단
        #expect(DueText.isUrgent(due: LocalDate("2026-09-27"), reasons: [], today: today))
        #expect(DueText.isUrgent(due: LocalDate("2026-09-20"), reasons: [], today: today))
        #expect(!DueText.isUrgent(due: LocalDate("2026-09-28"), reasons: [], today: today))
        #expect(!DueText.isUrgent(due: nil, reasons: [], today: today))
    }

    @Test func whenLabelKeepsTimeForTodayAndYesterday() {
        let seoul = TimeZone(identifier: "Asia/Seoul")!
        // 2026-09-27 12:00 KST
        let now = Date(timeIntervalSince1970: 1_790_478_000)
        #expect(WhenText.label(now.addingTimeInterval(-2 * 3600), now: now, timeZone: seoul) == "Today 10:00")
        #expect(WhenText.label(now.addingTimeInterval(-18 * 3600), now: now, timeZone: seoul) == "Yesterday 18:00")
        #expect(WhenText.label(now.addingTimeInterval(-5 * 86_400), now: now, timeZone: seoul) == "Sep 22")
        #expect(WhenText.label(now.addingTimeInterval(-400 * 86_400), now: now, timeZone: seoul) == "Aug 23, 2025")
    }

    @Test func relativeSyncTime() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(WhenText.relative(now.addingTimeInterval(-10), now: now) == "just now")
        #expect(WhenText.relative(now.addingTimeInterval(-300), now: now) == "5 min ago")
        #expect(WhenText.relative(now.addingTimeInterval(-7200), now: now) == "2 hr ago")
        #expect(WhenText.relative(now.addingTimeInterval(-86_400), now: now) == "1 day ago")
        #expect(WhenText.relative(now.addingTimeInterval(-3 * 86_400), now: now) == "3 days ago")
    }

    // MARK: Task row 메타 (T1 · T2)

    @Test func separatorOnlyWhenBothPartsExist() {
        let both = TaskMetaLine(due: "Mon", counterpart: "김대표", showCounterpart: true)
        #expect(both.showsSeparator)
        let dueOnly = TaskMetaLine(due: "Mon", counterpart: nil, showCounterpart: true)
        #expect(!dueOnly.showsSeparator && !dueOnly.isEmpty)
        let counterpartOnly = TaskMetaLine(due: nil, counterpart: "김대표", showCounterpart: true)
        #expect(!counterpartOnly.showsSeparator && counterpartOnly.counterpart == "김대표")
        #expect(TaskMetaLine(due: nil, counterpart: nil).isEmpty)
    }

    @Test func counterpartIsHiddenByDefaultAndBlankIsIgnored() {
        #expect(TaskMetaLine(due: "Mon", counterpart: "김대표").counterpart == nil)
        #expect(TaskMetaLine(due: "  ", counterpart: " ", showCounterpart: true).isEmpty)
    }
}
