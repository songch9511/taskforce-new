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

/// Review 항목(iPhone Review card · Mac 런처 Review 행) 제목 아래 한 줄: 서버가 남긴 확인 이유
/// ("판정 확인: NOT_MY_ACTION", "병합 확인 (55%)", "기한 확인" 등)를 짧은 영어 표기 하나로.
/// 이유가 여럿이면 가장 중요한 하나만 보인다(`Kind` 순서, 담당이 먼저). 모르는 이유는 내부 코드를 보이지 않게 "Needs review".
/// 서버의 핸드오프 번들(src/lib/actions/handoff.ts)은 이 표기를 쓰지 않고 따로 한국어 문장으로 옮긴다.
/// 서버가 남기는 이유 이름이 여기 모두 있는지는 src/lib/actions/confirm-reasons.test.ts가 본다 (이름이 바뀌면 그 테스트가 깨진다).
public enum ConfirmReasonText {
    /// 확인 이유의 종류. 앞일수록 중요하다 (확정하기 전에 먼저 알아야 할 것)
    enum Kind: Int, Comparable {
        case owner, done, notTask, tentative, uncertainMerge, duplicate, due, scope, status

        var label: String {
            switch self {
            case .owner: "Not sure it's yours"
            case .done: "May be done already"
            case .notTask: "May not be a task"
            case .tentative: "May not be a firm commitment"
            case .uncertainMerge: "Update may not belong here"
            case .duplicate: "May duplicate another task"
            case .due: "Due date unclear"
            case .scope: "Scope unclear"
            case .status: "Status unclear"
            }
        }

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    static let fallback = "Needs review"

    /// 판정 단계(Jev)의 코드: "판정 확인: NOT_MY_ACTION, TENTATIVE" (src/lib/pipeline/judge.ts `RejectReason`)
    private static let judge: [String: Kind] = [
        "NOT_MY_ACTION": .owner,
        "ALREADY_DONE": .done,
        "INFO_ONLY": .notTask,
        "TENTATIVE": .tentative,
    ]
    /// Claim에서 다시 계산하는 이유 (src/lib/actions/project.ts `projectAction`)
    private static let derived: [String: Kind] = [
        "담당 확인": .owner,
        "기한 확인": .due,
        "내용 확인": .scope,
        "상태 확인": .status,
    ]

    /// 가장 중요한 이유 하나. 이유가 없거나 모르는 이유뿐이면 "Needs review"
    public static func label(_ reasons: [String]) -> String {
        reasons.flatMap(kinds).min()?.label ?? fallback
    }

    static func kinds(_ reason: String) -> [Kind] {
        if let kind = derived[reason] { return [kind] }
        if reason.hasPrefix("판정 확인:") {
            return reason.dropFirst("판정 확인:".count).split(separator: ",").compactMap { judge[$0.trimmingCharacters(in: .whitespaces)] }
        }
        // "병합 확인 (55%)": 기존 할 일에 새 원문을 붙였지만 같은 일인지 확신이 낮다 (src/lib/pipeline/merge.ts).
        // 이 할 일은 원래 있던 것이라, 새로 붙은 내용이 여기 속하는지를 묻는다
        if reason.hasPrefix("병합 확인") { return [.uncertainMerge] }
        // "중복 확인 (72%): 제목": Notion 할 일 DB 항목이 비슷한 할 일과 따로 만들어졌다 (src/lib/pipeline/merge-task.ts)
        if reason.hasPrefix("중복 확인") { return [.duplicate] }
        return []
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
