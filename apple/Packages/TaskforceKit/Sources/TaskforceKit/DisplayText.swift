import Foundation

// 화면 틀의 짧은 영어 표기 (docs/BRAND.md "UI 문구": Today · Yesterday 18:00 · Sep 22).
// 사용자 내용(제목 · 인용 · 문서 이름)은 원문 그대로 두고, 날짜 · 기한 같은 틀만 여기서 만든다.

/// 기한 표기. 기한은 시각 없는 날짜라 오늘(한국 시간, `DueDateFormat.today`)과 날짜로 비교한다.
public enum DueText {
    static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// "Sep 30", 올해가 아니면 "Sep 30, 2027"
    public static func date(_ date: LocalDate, today: LocalDate) -> String {
        let base = "\(months[date.month - 1]) \(date.day)"
        return date.year == today.year ? base : "\(base), \(date.year)"
    }

    /// Task row · Review card: "Today" · "Tomorrow" · "Yesterday" · 6일 안이면 "Wed" · 그 밖은 "Sep 30"
    public static func short(_ due: LocalDate, today: LocalDate) -> String {
        let days = due.days(since: today)
        switch days {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case 2...6: return weekdays[due.weekday - 1]
        default: return date(due, today: today)
        }
    }

    /// Launcher row 오른쪽 한 단어: 지났으면 "Overdue", 아니면 `short`
    public static func accessory(_ due: LocalDate, today: LocalDate) -> String {
        due < today ? "Overdue" : short(due, today: today)
    }

    public static func isOverdue(_ due: LocalDate, today: LocalDate) -> Bool {
        due < today
    }

    /// 빨강으로 보일지. 서버 이유가 있으면 `RankReason.isUrgent`(기한 지남 · 오늘)와 같은 기준, 없으면 기한으로 같은 판단을 한다.
    public static func isUrgent(due: LocalDate?, reasons: [RankReason], today: LocalDate) -> Bool {
        if reasons.contains(where: \.isUrgent) { return true }
        guard let due else { return false }
        return due <= today
    }
}

/// 원문 시점 표기 (Evidence의 When): "Today 14:05" · "Yesterday 18:00" · "Sep 22" · "Sep 22, 2025". 절대 줄이지 않는다 (E2).
public enum WhenText {
    public static func label(_ date: Date, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let day = LocalDate(date: date, timeZone: timeZone)
        let today = LocalDate(date: now, timeZone: timeZone)
        switch day.days(since: today) {
        case 0: return "Today \(time(date, timeZone: timeZone))"
        case -1: return "Yesterday \(time(date, timeZone: timeZone))"
        default: return DueText.date(day, today: today)
        }
    }

    /// 24시간제 "18:00"
    static func time(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// 연결 목록의 "Synced 5 min ago" 같은 상대 표기
    public static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60)) min ago"
        case ..<86_400: return "\(Int(seconds / 3600)) hr ago"
        default:
            let days = Int(seconds / 86_400)
            return days == 1 ? "1 day ago" : "\(days) days ago"
        }
    }
}

/// Task row의 한 줄 메타 "due · counterpart" (Figma 4:34, 스트레스 T1 · T2).
/// 구분점은 둘 다 있을 때만, 상대 이름은 기본으로 끈다.
public struct TaskMetaLine: Equatable, Sendable {
    public let due: String?
    public let counterpart: String?

    public var showsSeparator: Bool { due != nil && counterpart != nil }
    public var isEmpty: Bool { due == nil && counterpart == nil }

    public init(due: String?, counterpart: String? = nil, showCounterpart: Bool = false) {
        self.due = due.flatMap(Self.nonEmpty)
        self.counterpart = showCounterpart ? counterpart.flatMap(Self.nonEmpty) : nil
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
