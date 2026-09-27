import Foundation

// 화면에 보이는 짧은 한국어 표기. 웹 /lab과 같은 말을 쓴다.

extension RankReason {
    public var label: String {
        switch self {
        case .overdue: "기한 지남"
        case .dueToday: "오늘 마감"
        case .dueSoon: "곧 마감"
        case .external: "상대가 기다림"
        case .neglected: "오래 방치"
        case .started: "진행 중"
        }
    }

    /// 눈에 띄게 보여줄 이유 (기한 관련)
    public var isUrgent: Bool {
        self == .overdue || self == .dueToday
    }
}

extension ActionOwner {
    public var label: String {
        switch self {
        case .me: "나"
        case .other: "다른 사람"
        case .unknown: "미정"
        }
    }
}

extension ActionStatus {
    public var label: String {
        switch self {
        case .open: "진행 전"
        case .done: "완료"
        case .dropped: "삭제됨"
        }
    }
}

extension SourceKind {
    public var label: String {
        switch self {
        case .meeting: "회의록"
        case .message: "메시지"
        case .email: "메일"
        case .doc: "문서"
        case .note: "메모"
        case .task: "할 일 도구"
        }
    }

    /// SF Symbols 이름
    public var symbolName: String {
        switch self {
        case .meeting: "person.2"
        case .message: "bubble.left"
        case .email: "envelope"
        case .doc: "doc.text"
        case .note: "note.text"
        case .task: "checklist"
        }
    }
}

extension ProcessingStatus {
    public var label: String {
        switch self {
        case .pending: "대기 중"
        case .processing: "읽는 중"
        case .done: "완료"
        case .failed: "실패"
        }
    }
}

/// 기한 표기. 날짜는 한국 시간(Asia/Seoul) 기준으로 오늘과 비교한다.
public enum DueDateFormat {
    public static let seoul = TimeZone(identifier: "Asia/Seoul")!

    private static let weekdays = ["일", "월", "화", "수", "목", "금", "토"]

    /// 한국 시간으로 오늘
    public static func today(now: Date = Date()) -> LocalDate {
        LocalDate(date: now, timeZone: seoul)
    }

    /// "월"
    public static func weekday(_ date: LocalDate) -> String {
        weekdays[date.weekday - 1]
    }

    /// "9월 29일(월)". 올해가 아니면 연도를 붙인다.
    public static func label(_ date: LocalDate, today: LocalDate) -> String {
        let base = "\(date.month)월 \(date.day)일(\(weekday(date)))"
        return date.year == today.year ? base : "\(date.year)년 \(base)"
    }

    /// "오늘" · "내일" · "모레" · "3일 지남" · "5일 남음"
    public static func relative(_ date: LocalDate, today: LocalDate) -> String {
        let days = date.days(since: today)
        switch days {
        case 0: return "오늘"
        case 1: return "내일"
        case 2: return "모레"
        case ..<0: return "\(-days)일 지남"
        default: return "\(days)일 남음"
        }
    }

    /// 목록 · 상세의 기한 한 줄: "오늘 · 9월 27일(일)", "3일 지남 · 9월 24일(목)", 멀면 "10월 20일(화)"
    public static func summary(_ date: LocalDate, today: LocalDate) -> String {
        let days = date.days(since: today)
        let label = label(date, today: today)
        return days <= 6 ?"\(relative(date, today: today)) · \(label)" : label
    }
}
