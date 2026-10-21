#if os(macOS)
import Foundation

/// 외부 세션 목록의 승인된 문구 (OA 외부 세션 PR1, DZ 승인 2026-10-21 · 계약 17장). 화면은 이 상수만 쓴다
public enum ExternalSessionCopy {
    public static let sectionTitle = "On this Mac"
    public static let accessibilityNewSessions = "On this Mac — new sessions"
    public static let runningInClaude = "Running in Claude"
    public static let runningInTerminal = "Running in Terminal"
    public static let runningElsewhere = "Running elsewhere"
    public static let couldNotCheck = "Couldn't check"
    public static let cannotResume = "Can't resume here"
    public static let idle = "Idle"
    public static let inTaskforce = "In Taskforce"
    public static let worktree = "Worktree"
    public static let folderNotAllowed = "Folder isn't allowed"
    public static let unreadable = "Unreadable"
    public static let updateClaudeCode = "Update Claude Code"
    public static let claudeDesktop = "Claude desktop"
    public static let terminal = "Terminal"
    public static let untitled = "Untitled"
    public static let openInClaude = "Open in Claude"
    public static let showAll = "Show all"
    public static let showLess = "Show less"
    public static let checking = "Checking…"
    public static let empty = "No recent Claude Code sessions"
    public static let notInstalled = "Claude Code isn't installed"
    public static let getClaudeCode = "Get Claude Code"
    public static let couldNotCheckSessions = "Couldn't check sessions"
    public static let tryAgain = "Try again"
}

/// 줄 하나의 말 (DZ 승인): 제목(없으면 폴더 이름, 그것도 없으면 "Untitled"), 둘째 줄 = 상태 말(굵게는 막힌 이유 · 돌고 있음 · 확인 못 함의 첫 말) · 이유 · 시각 · 출처
public struct ExternalSessionLineContent: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// 데스크톱 앱만 앞으로 (인자 0)
        case openInClaude
    }

    public var title: String
    public var statusWord: String
    /// 굵은 상태 말인가 (돌고 있음 · 확인 못 함 · 이어받을 수 없음). Idle · In Taskforce는 보통 굵기
    public var statusIsEmphasis: Bool
    /// 상태 말 뒤에 오는 조각 (이유 · 시각 · 출처), `·`로 이어 쓴다
    public var detail: [String]
    public var action: Action?

    public init(title: String, statusWord: String, statusIsEmphasis: Bool, detail: [String], action: Action?) {
        self.title = title
        self.statusWord = statusWord
        self.statusIsEmphasis = statusIsEmphasis
        self.detail = detail
        self.action = action
    }

    /// "상태 · 조각 · 조각"
    public var metaText: String { ([statusWord] + detail).joined(separator: " · ") }

    /// "{제목} — {둘째 줄}"
    public var accessibilityName: String { "\(title) — \(metaText)" }
}

public enum ExternalSessionLineText {
    public static func make(_ row: ExternalSessionRow, now: Date, timeZone: TimeZone = .current) -> ExternalSessionLineContent {
        let time = timeLabel(row.lastActivity, now: now, timeZone: timeZone)
        let source: String? = switch row.client {
        case .claudeDesktop?: ExternalSessionCopy.claudeDesktop
        case .terminal?: ExternalSessionCopy.terminal
        case .other?, nil: nil
        }
        let word: String
        var emphasis = true
        var detail: [String]
        var action: ExternalSessionLineContent.Action?
        switch row.status {
        case .held(.claudeApp):
            word = ExternalSessionCopy.runningInClaude
            detail = [time]
            action = .openInClaude
        case .held(.terminal):
            word = ExternalSessionCopy.runningInTerminal
            detail = [time]
        case .held(.background), .held(.unknown):
            word = ExternalSessionCopy.runningElsewhere
            detail = [time]
        case .couldNotCheck:
            word = ExternalSessionCopy.couldNotCheck
            detail = [time] + (source.map { [$0] } ?? [])
        case .cannotResume(let reason):
            word = ExternalSessionCopy.cannotResume
            detail = [reasonText(reason), time]
        case .available:
            word = ExternalSessionCopy.idle
            emphasis = false
            detail = [time] + (source.map { [$0] } ?? [])
        case .inTaskforce:
            word = ExternalSessionCopy.inTaskforce
            emphasis = false
            detail = [time]
        }
        return ExternalSessionLineContent(title: title(row), statusWord: word, statusIsEmphasis: emphasis, detail: detail, action: action)
    }

    public static func reasonText(_ reason: ExternalSessionBlock) -> String {
        switch reason {
        case .worktree: ExternalSessionCopy.worktree
        case .folderNotAllowed: ExternalSessionCopy.folderNotAllowed
        case .unreadable: ExternalSessionCopy.unreadable
        case .updateClaudeCode: ExternalSessionCopy.updateClaudeCode
        }
    }

    /// 제목이 없으면 폴더 이름, 그것도 모르면 "Untitled"
    public static func title(_ row: ExternalSessionRow) -> String {
        if let title = row.title, !title.isEmpty { return title }
        if let folder = row.folderPath, case let name = (folder as NSString).lastPathComponent, !name.isEmpty, name != "/" { return name }
        return ExternalSessionCopy.untitled
    }

    /// 시각 (DZ): 방금 → `now` · 한 시간 안 → `N min ago` · 오늘 → `N hr ago` · 어제 → `Yesterday` · 6일 안 → `Mon` · 그 밖 → `Oct 3`.
    /// 문구가 아니라 날짜 서식이다 (`DueText`와 같은 요일 · 달 이름)
    public static func timeLabel(_ date: Date, now: Date, timeZone: TimeZone = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        let day = LocalDate(date: date, timeZone: timeZone)
        let today = LocalDate(date: now, timeZone: timeZone)
        switch day.days(since: today) {
        case 0: return "\(max(1, Int(seconds / 3600))) hr ago"
        case -1: return "Yesterday"
        case -6 ... -2: return DueText.weekdays[day.weekday - 1]
        default: return DueText.date(day, today: today)
        }
    }
}
#endif
