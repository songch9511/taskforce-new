import Foundation

// 레일 맨 위 Review 타일 (OA U1, DS ReviewTile). 판정은 서버가 한 것을 모아 보일 뿐이다:
// - needs-you: 지금 Review 항목이 있다 (v1 확인 요청, 뒤에 D4b-s 입력이 더해진다). 노랑 `marker` 타일
// - changes: 복귀 요약에 읽음 처리할 변화가 있다 (`hasChangesToClear`). 조용한 `bezel-hover` 타일. Clear로만 끝난다 (보는 것만으로 해제되지 않는다, DS D-12)
// - 둘 다 없으면 타일이 없다 (비활성이 아니다). needs-you가 changes보다 앞선다
// 타일은 Review(`S4`)와 복귀 요약(`C3`) 표면이 둘 다 켜졌을 때만 있다 (U1-23).

public enum ReviewTileContent: Equatable, Sendable {
    case needsYou(count: Int)
    case changes(since: Date?, count: Int)
}

public enum ReviewTileRules {
    public enum Destination: Equatable, Sendable {
        /// 가장 새 Review 항목 (목록 화면 `ReviewList`는 D4b-m)
        case newestReview
        /// 복귀 요약 (지금은 All work 위 카드)
        case returnSummary
    }

    /// 타일에 보일 것 (없으면 nil)
    /// - reviewCount: 지금 Review 큐의 항목 수
    /// - summary: 복귀 요약 응답 (읽기 전이면 nil)
    public static func content(reviewCount: Int, summary: ReturnSummaryResponse?, reviewEnabled: Bool, summaryEnabled: Bool) -> ReviewTileContent? {
        guard reviewEnabled, summaryEnabled else { return nil }
        if reviewCount > 0 { return .needsYou(count: reviewCount) }
        guard let summary, summary.hasChangesToClear else { return nil }
        // "Since"는 마지막 Clear의 시각이다. 기준점만 있거나 한 번도 Clear하지 않았으면 시각을 지어내지 않는다 (복귀 요약 카드 캡션과 같은 규칙)
        let since = summary.baseline == .cleared ? summary.since : nil
        return .changes(since: since, count: summary.items.filter { !$0.changes.isEmpty }.count)
    }

    public static func destination(for content: ReviewTileContent) -> Destination {
        switch content {
        case .needsYou: .newestReview
        case .changes: .returnSummary
        }
    }

    /// 툴팁: 화면에는 개수가 없다
    public static func tooltip(_ content: ReviewTileContent, now: Date = Date(), calendar: Calendar = .current) -> String {
        switch content {
        case .needsYou:
            "Review · Needs your answer"
        case .changes(let since, _):
            since.map { "Review · Changes since \(timeLabel($0, now: now, calendar: calendar))" } ?? "Review · Changes"
        }
    }

    /// 접근성 이름: 툴팁 + 개수 (개수는 읽어 주는 데만 쓴다)
    public static func accessibilityName(_ content: ReviewTileContent, now: Date = Date(), calendar: Calendar = .current) -> String {
        let count: Int
        switch content {
        case .needsYou(let n): count = n
        case .changes(_, let n): count = n
        }
        return "\(tooltip(content, now: now, calendar: calendar)), \(count) \(count == 1 ? "item" : "items")"
    }

    /// 오늘 "6:40 PM" · 어제 "Yesterday, 6:40 PM" · 그 전 "Oct 12, 6:40 PM" (올해가 아니면 "Dec 31, 2025, 9:05 AM"). 날짜는 달력의 시간대 기준이다
    public static func timeLabel(_ date: Date, now: Date, calendar: Calendar) -> String {
        let clock = format("h:mm a", calendar)
        let time = clock.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday, \(time)"
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return "\(format(sameYear ? "MMM d" : "MMM d, yyyy", calendar).string(from: date)), \(time)"
    }

    private static func format(_ pattern: String, _ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter
    }
}
