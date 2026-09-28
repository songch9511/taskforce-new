import Foundation

// Mac 런처(⌥Space)의 화면 없는 규칙. 순서 계산 · 판정은 서버에만 있고, 여기서는 받은 목록을 거르고 묶기만 한다.

/// 입력창 하나로 무엇을 할지 정한다: 빈칸 → 목록, 짧은 글 → 찾기 · 묻기, 길거나 여러 줄 → 원문으로 보내기.
public enum LauncherInput {
    /// 이보다 길면 찾는 말이 아니라 붙여 넣은 원문으로 본다
    public static let longTextThreshold = 200

    public enum Mode: Equatable, Sendable {
        case empty
        case query(String)
        case paste(String)
    }

    public static func mode(for text: String) -> Mode {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if trimmed.contains(where: \.isNewline) || trimmed.count > longTextThreshold { return .paste(trimmed) }
        return .query(trimmed)
    }
}

/// 빈 입력창에 보이는 명령
public enum LauncherCommand: String, CaseIterable, Sendable, Hashable {
    case sendClipboard
    case reportMissing
    case connections
    case settings
    case quit

    public var title: String {
        switch self {
        case .sendClipboard: "Send clipboard as source"
        case .reportMissing: "Report missing action"
        case .connections: "Connections"
        case .settings: "Settings"
        case .quit: "Quit"
        }
    }

    /// SF Symbols 이름
    public var symbolName: String {
        switch self {
        case .sendClipboard: "doc.on.clipboard"
        case .reportMissing: "text.badge.plus"
        case .connections: "link"
        case .settings: "gearshape"
        case .quit: "power"
        }
    }
}

public enum LauncherItem: Hashable, Sendable, Identifiable {
    /// 확인 요청 (Confirm · Dismiss)
    case review(ActionSummary)
    case task(RankedAction)
    case command(LauncherCommand)
    case ask(String)
    case handoff(ActionSummary)
    case sendAsSource(String)
    /// 직접 추가: 찾는 말과 맞는 할 일이 없을 때 "Add “…”" (`LauncherAdd`)
    case addAction(String)
    case signIn
    /// App Store 심사 계정용 이메일 로그인 (눈에 덜 띄게 Sign in with Apple 아래)
    case signInWithEmail
    /// 외부 AI 처리 동의 전이라 연동 원문을 읽지 못함 (목록은 그대로 보인다)
    case allowAI

    public var id: String {
        switch self {
        case .review(let action): "review-\(action.id)"
        case .task(let ranked): "task-\(ranked.id)"
        case .command(let command): "command-\(command.rawValue)"
        case .ask: "ask"
        case .handoff(let action): "handoff-\(action.id)"
        case .sendAsSource: "send-as-source"
        case .addAction: "add-action"
        case .signIn: "sign-in"
        case .signInWithEmail: "sign-in-email"
        case .allowAI: "allow-ai"
        }
    }

    /// 할 일 행이면 그 할 일 (⌘K 동작 · 펼침의 대상)
    public var action: ActionSummary? {
        switch self {
        case .review(let action), .handoff(let action): action
        case .task(let ranked): ranked.action
        default: nil
        }
    }
}

public struct LauncherSection: Hashable, Sendable, Identifiable {
    /// "Review" · "Now" · "Commands". nil이면 제목 없이
    public let title: String?
    public let items: [LauncherItem]

    public var id: String { title ?? items.first?.id ?? "empty" }

    public init(title: String?, items: [LauncherItem]) {
        self.title = title
        self.items = items
    }
}

public enum LauncherContent {
    /// `POST /api/v1/ask` 질문 최대 길이 (UTF-16, zod max)
    public static let askMaxLength = 500

    /// `needsConsent`: 동의 전이면 빈 입력창 맨 위에 "Allow AI processing" 한 줄 (목록을 막지 않는다)
    public static func sections(
        for mode: LauncherInput.Mode, now: NowResponse?, signedIn: Bool, needsConsent: Bool = false
    ) -> [LauncherSection] {
        guard signedIn else {
            return [
                LauncherSection(title: nil, items: [.signIn, .signInWithEmail]),
                LauncherSection(title: "Commands", items: [.command(.quit)]),
            ].filter { !$0.items.isEmpty }
        }
        let reviews = now?.confirmations ?? []
        let tasks = now?.now ?? []
        var sections: [LauncherSection]
        switch mode {
        case .empty:
            sections = [
                LauncherSection(title: nil, items: needsConsent ? [.allowAI] : []),
                LauncherSection(title: "Review", items: reviews.map(LauncherItem.review)),
                LauncherSection(title: "Now", items: tasks.map(LauncherItem.task)),
                LauncherSection(title: "Commands", items: LauncherCommand.allCases.map(LauncherItem.command)),
            ]
        case .query(let query):
            let matchingReviews = reviews.filter { TaskFilter.matches($0, query: query) }
            let matchingTasks = tasks.filter { TaskFilter.matches($0.action, query: query) }
            let top = matchingTasks.first?.action ?? matchingReviews.first
            var assist: [LauncherItem] = [.ask(query)]
            if let top {
                assist.append(.handoff(top))
            } else if let title = LauncherAdd.title(for: mode, now: now, signedIn: signedIn) {
                // 맞는 할 일이 없으면 추가가 맨 위 (↩ 한 번으로 시작)
                assist.insert(.addAction(title), at: 0)
            }
            let commands = LauncherCommand.allCases.filter { TaskFilter.matches(text: $0.title, query: query) }
            sections = [
                LauncherSection(title: "Review", items: matchingReviews.map(LauncherItem.review)),
                LauncherSection(title: "Now", items: matchingTasks.map(LauncherItem.task)),
                LauncherSection(title: nil, items: assist),
                LauncherSection(title: "Commands", items: commands.map(LauncherItem.command)),
            ]
        case .paste(let text):
            // 물어보기는 500자까지 받는다 (contract.ts `askRequestSchema`)
            let ask: [LauncherItem] = text.utf16.count <= askMaxLength ? [.ask(text)] : []
            sections = [LauncherSection(title: nil, items: [.sendAsSource(text)] + ask)]
        }
        return sections.filter { !$0.items.isEmpty }
    }

    /// 선택 이동. 끝에서 멈춘다 (돌아가지 않는다).
    public static func move(_ index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index + delta, 0), count - 1)
    }
}

/// 직접 추가 ("Add “…”"). 짧은 한 줄을 찾았는데 Review · Now에 맞는 할 일이 없을 때만 보인다.
/// 빈칸 · 붙여 넣은 원문(길거나 여러 줄) · 로그아웃이면 보이지 않는다. 목록을 아직 못 읽었으면 이미 있는 할 일인지 모르니 보이지 않는다.
public enum LauncherAdd {
    /// 서버 제목 최대 길이 (UTF-16, zod max)
    public static let maxTitleLength = 200

    /// 추가할 제목. 보이지 않으면 nil
    public static func title(for mode: LauncherInput.Mode, now: NowResponse?, signedIn: Bool) -> String? {
        guard signedIn, let now, case .query(let query) = mode else { return nil }
        guard existing(matching: query, in: now).isEmpty else { return nil }
        let title = capped(query)
        return title.isEmpty ? nil : title
    }

    /// 그 말과 맞는 열린 할 일 (`TaskFilter`): Review 먼저, 그다음 Now, 받은 순서 그대로. 같은 할 일은 한 번만.
    /// iPhone New Task의 "In Now" 힌트 (추가는 막지 않는다). 빈칸이거나 목록을 아직 못 읽었으면 없음.
    public static func existing(matching text: String, in now: NowResponse?) -> [ActionSummary] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let now, !query.isEmpty else { return [] }
        var seen = Set<UUID>()
        return (now.confirmations + now.now.map(\.action))
            .filter { TaskFilter.matches($0, query: query) && seen.insert($0.id).inserted }
    }

    /// 앞뒤 공백을 빼고 `maxTitleLength`(UTF-16)까지. 글자를 중간에서 자르지 않는다.
    public static func capped(_ text: String) -> String {
        var title = ""
        var length = 0
        for character in text.trimmingCharacters(in: .whitespacesAndNewlines) {
            length += character.utf16.count
            guard length <= maxTitleLength else { break }
            title.append(character)
        }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 기한 고르기의 줄: 오늘부터 7일 + "No due date". 추가할 때는 기한 없음이 기본이라 맨 위 (↩ 세 번이면 제목만으로 추가).
/// 이미 고른 기한이 7일 밖이면(Other date) 그 날짜 줄을 날짜 순서대로 끼워서, 원문 고르기에서 돌아와도 그대로 남게 한다.
public enum LauncherDue {
    public enum Choice: Hashable, Sendable {
        case date(LocalDate)
        case clear
    }

    public static func choices(today: LocalDate, adding: Bool, keeping due: LocalDate? = nil) -> [Choice] {
        var dates = (0...6).map { today.adding(days: $0) }
        if let due, !dates.contains(due) {
            dates.append(due)
            dates.sort()
        }
        let rows = dates.map(Choice.date)
        return adding ? [.clear] + rows : rows + [.clear]
    }

    /// 그 기한의 줄 (없으면 맨 위)
    public static func index(of due: LocalDate?, in choices: [Choice]) -> Int {
        choices.firstIndex(of: due.map(Choice.date) ?? .clear) ?? 0
    }
}

/// 받은 목록을 앱에서 거른다 (순서는 그대로 — 거르기는 순서 계산이 아니다).
/// 띄어 쓴 낱말이 모두 제목이나 상대 이름에 들어 있으면 맞는 것으로 본다. 대소문자 · 전각 · 발음 기호는 무시한다.
public enum TaskFilter {
    public static func matches(_ action: ActionSummary, query: String) -> Bool {
        let haystack = [action.title, action.counterpart ?? ""].joined(separator: " ")
        return matches(text: haystack, query: query)
    }

    public static func matches(text: String, query: String) -> Bool {
        let tokens = query.split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return true }
        return tokens.allSatisfy { token in
            text.range(of: token, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
        }
    }
}

/// 붙여 넣은 글 → `POST /api/v1/sources` 본문. 여러 줄은 메모(note), 한 줄은 메시지(message), 제목은 첫 줄.
public enum PastedSource {
    public static let maxTitleLength = 80

    public static func request(for text: String) -> CreateSourceRequest? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= CreateSourceRequest.maxTextLength else { return nil }
        let firstLine = trimmed
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? trimmed
        let kind: SourceKind = trimmed.contains(where: \.isNewline) ? .note : .message
        return CreateSourceRequest(kind: kind, text: trimmed, title: String(firstLine.prefix(maxTitleLength)))
    }
}

/// Mac: 런처를 띄울 때마다 `app_opened`를 보내면 지표가 부풀어서, 30분에 한 번만 보낸다 (지표 2 · 3).
public struct LauncherOpenThrottle: Sendable, Equatable {
    public static let interval: TimeInterval = 30 * 60

    private var lastSent: Date?

    public init() {}

    /// 런처가 나타날 때마다 부른다. true면 `app_opened`를 보낸다.
    public mutating func shouldSend(at now: Date) -> Bool {
        if let lastSent, now >= lastSent, now.timeIntervalSince(lastSent) < Self.interval { return false }
        lastSent = now
        return true
    }
}
