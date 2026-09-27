import Foundation
import Testing
@testable import TaskforceKit

struct LabelsTests {
    @Test func reasonLabelsMatchLab() {
        #expect(RankReason.allCases.map(\.label) == ["기한 지남", "오늘 마감", "곧 마감", "상대가 기다림", "오래 방치", "진행 중"])
        #expect(RankReason.allCases.filter(\.isUrgent) == [.overdue, .dueToday])
    }

    @Test func ownerLabels() {
        #expect(ActionOwner.allCases.map(\.label) == ["나", "다른 사람", "미정"])
    }

    @Test func dueLabelWithKoreanWeekday() {
        let today = LocalDate("2026-09-27")!
        #expect(DueDateFormat.label(LocalDate("2026-09-28")!, today: today) == "9월 28일(월)")
        #expect(DueDateFormat.label(LocalDate("2026-10-04")!, today: today) == "10월 4일(일)")
        #expect(DueDateFormat.label(LocalDate("2027-01-01")!, today: today) == "2027년 1월 1일(금)")
    }

    @Test(arguments: [
        ("2026-09-27", "오늘 · 9월 27일(일)"),
        ("2026-09-28", "내일 · 9월 28일(월)"),
        ("2026-09-29", "모레 · 9월 29일(화)"),
        ("2026-10-01", "4일 남음 · 10월 1일(목)"),
        ("2026-09-24", "3일 지남 · 9월 24일(목)"),
        ("2026-10-20", "10월 20일(화)"),
    ])
    func dueSummary(_ due: String, _ expected: String) {
        #expect(DueDateFormat.summary(LocalDate(due)!, today: LocalDate("2026-09-27")!) == expected)
    }

    @Test func todayIsSeoulDate() {
        // 2026-09-27 15:30 UTC = 2026-09-28 00:30 KST
        let instant = Date(timeIntervalSince1970: 1_790_523_000)
        #expect(DueDateFormat.today(now: instant) == LocalDate("2026-09-28"))
    }
}
