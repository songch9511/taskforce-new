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
    /// 확인 요청: ↩ 근거 펼치기 · ⌘↩ Confirm · ⌘⌫ Dismiss (`LauncherReturn`)
    case review(ActionSummary)
    /// 열린 할 일 (In Progress · To Do, `TaskGroup.open`)
    case task(RankedAction)
    /// 오늘 끝낸 할 일 (Reopen)
    case done(ActionSummary)
    case command(LauncherCommand)
    case ask(String)
    case handoff(ActionSummary)
    case sendAsSource(String)
    /// 직접 추가: 찾는 말과 맞는 할 일이 없을 때 "Add “…”" (`LauncherAdd`)
    case addAction(String)
    case signIn
    /// Sign in with Google (Apple 바로 아래, 설정이 있을 때만)
    case signInWithGoogle
    /// App Store 심사 계정용 이메일 로그인 (눈에 덜 띄게 Sign in with Apple 아래)
    case signInWithEmail
    /// 외부 AI 처리 동의 전이라 연동 원문을 읽지 못함 (목록은 그대로 보인다)
    case allowAI
    /// 처리방침 변경 안내: ↩ View (처리방침 페이지) · ⌘⌫ 닫기
    case policyNotice(PolicyNotice)

    public var id: String {
        switch self {
        case .review(let action): "review-\(action.id)"
        case .task(let ranked): "task-\(ranked.id)"
        case .done(let action): "done-\(action.id)"
        case .command(let command): "command-\(command.rawValue)"
        case .ask: "ask"
        case .handoff(let action): "handoff-\(action.id)"
        case .sendAsSource: "send-as-source"
        case .addAction: "add-action"
        case .signIn: "sign-in"
        case .signInWithGoogle: "sign-in-google"
        case .signInWithEmail: "sign-in-email"
        case .allowAI: "allow-ai"
        case .policyNotice: "policy-notice"
        }
    }

    /// 할 일 행이면 그 할 일 (⌘K 동작 · 펼침의 대상)
    public var action: ActionSummary? {
        switch self {
        case .review(let action), .handoff(let action), .done(let action): action
        case .task(let ranked): ranked.action
        default: nil
        }
    }

    /// 할 일 행의 구역 (왼쪽 상태 표시). 할 일 행이 아니면 nil (Hand off 행도 nil)
    public var group: TaskGroup? {
        switch self {
        case .review: .review
        case .task(let ranked): TaskGroup.open(ranked.action)
        case .done: .doneToday
        default: nil
        }
    }
}

public struct LauncherSection: Hashable, Sendable, Identifiable {
    /// "Review" · "In Progress" · "To Do" · "Done Today" · "Commands". nil이면 제목 없이
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

    /// 구역은 `TaskBoard.sections` (Review · In Progress · To Do · Done Today). 내 변경을 얹은 목록을 넘긴다.
    /// 찾는 중에는 네 구역을 모두 거르고, Done Today는 Ask · Add 아래에 둔다 (맞는 열린 할 일이 없으면 Add가 맨 위라 ↩ 한 번으로 시작).
    /// `needsConsent`: 동의 전이면 빈 입력창 맨 위에 "Allow AI processing" 한 줄 (목록을 막지 않는다)
    /// `policyNotice`: 처리방침 변경 안내가 있으면 빈 입력창 맨 위에 한 줄 (동의 줄 아래)
    /// `googleSignIn`: 로그인 전 목록에 Sign in with Google을 둘지 (앱에 Google 클라이언트 설정이 있을 때)
    public static func sections(
        for mode: LauncherInput.Mode, now: NowResponse?, doneToday: [ActionSummary] = [], signedIn: Bool, needsConsent: Bool = false,
        policyNotice: PolicyNotice? = nil, googleSignIn: Bool = false
    ) -> [LauncherSection] {
        guard signedIn else {
            return [
                LauncherSection(title: nil, items: [.signIn] + (googleSignIn ? [.signInWithGoogle] : []) + [.signInWithEmail]),
                LauncherSection(title: "Commands", items: [.command(.quit)]),
            ].filter { !$0.items.isEmpty }
        }
        let board = TaskBoard(now: now, doneToday: doneToday)
        var sections: [LauncherSection]
        switch mode {
        case .empty:
            let tasks = board.sections()
            let notices: [LauncherItem] = (needsConsent ? [.allowAI] : []) + (policyNotice.map { [.policyNotice($0)] } ?? [])
            sections = [LauncherSection(title: nil, items: notices)]
                + taskSections(tasks, includingDone: true)
                + [LauncherSection(title: "Commands", items: LauncherCommand.allCases.map(LauncherItem.command))]
        case .query(let query):
            let tasks = board.sections(matching: query)
            // 맞는 열린 할 일 중 맨 위 (보이는 순서: In Progress → To Do → Review)
            let top = tasks.inProgress.first?.action ?? tasks.toDo.first?.action ?? tasks.review.first
            var assist: [LauncherItem] = [.ask(query)]
            if let top {
                assist.append(.handoff(top))
            } else if let title = LauncherAdd.title(for: mode, now: now, signedIn: signedIn) {
                // 맞는 열린 할 일이 없으면 추가가 맨 위 (↩ 한 번으로 시작). 끝낸 할 일은 보지 않는다.
                assist.insert(.addAction(title), at: 0)
            }
            let commands = LauncherCommand.allCases.filter { TaskFilter.matches(text: $0.title, query: query) }
            sections = taskSections(tasks, includingDone: false)
                + [
                    LauncherSection(title: nil, items: assist),
                    LauncherSection(title: TaskGroup.doneToday.title, items: tasks.doneToday.map(LauncherItem.done)),
                    LauncherSection(title: "Commands", items: commands.map(LauncherItem.command)),
                ]
        case .paste(let text):
            // 물어보기는 500자까지 받는다 (contract.ts `askRequestSchema`)
            let ask: [LauncherItem] = text.utf16.count <= askMaxLength ? [.ask(text)] : []
            sections = [LauncherSection(title: nil, items: [.sendAsSource(text)] + ask)]
        }
        return sections.filter { !$0.items.isEmpty }
    }

    private static func taskSections(_ tasks: TaskSections, includingDone: Bool) -> [LauncherSection] {
        var sections = [
            LauncherSection(title: TaskGroup.review.title, items: tasks.review.map(LauncherItem.review)),
            LauncherSection(title: TaskGroup.inProgress.title, items: tasks.inProgress.map(LauncherItem.task)),
            LauncherSection(title: TaskGroup.toDo.title, items: tasks.toDo.map(LauncherItem.task)),
        ]
        if includingDone {
            sections.append(LauncherSection(title: TaskGroup.doneToday.title, items: tasks.doneToday.map(LauncherItem.done)))
        }
        return sections
    }

    /// 목록이 새로 왔을 때 고를 줄: 전에 고른 행(`id`)이 아직 있으면 그 행, 없으면 같은 자리(끝을 넘지 않게).
    public static func reselect(_ id: String?, in items: [LauncherItem], at index: Int) -> Int {
        if let id, let found = items.firstIndex(where: { $0.id == id }) { return found }
        return move(index, by: 0, count: items.count)
    }

    /// 펼침 · ⌘K 패널(과 거기서 연 Working… · 알림)에서 목록으로 돌아올 때 고를 줄. nil이면 고른 줄 없이 둔다.
    /// - 본 할 일(`id`)의 행이 있으면 그 행이다(Hand off 행이 아니라 그 할 일의 행). 그사이 목록이 새로 와 자리가 바뀌어도 그 행.
    /// - 사라졌으면(다른 기기에서 확정 · 지움) 떠난 자리(`index`)에서 가장 가까운 할 일 행(In Progress · To Do · Done Today, 같은 거리면 아래).
    ///   Review · 명령 · 안내 줄은 고르지 않는다: ↩ · ⌘↩ · ⌘⌫ 한 번에 보지 않은 Review가 확정 · 넘겨지거나 명령이 실행되지 않게. 할 일 행이 없으면 nil.
    /// - 본 할 일이 없으면(물어보기 답 · 원문 보내기 등) 맨 위.
    public static func rowAfterBack(viewing id: UUID?, in items: [LauncherItem], near index: Int) -> Int? {
        guard let id else { return 0 }
        if let row = items.firstIndex(where: { $0.group != nil && $0.action?.id == id }) { return row }
        return items.indices
            .filter { items[$0].group != nil && items[$0].group != .review }
            .min { lhs, rhs in
                let (left, right) = (abs(lhs - index), abs(rhs - index))
                return left < right || (left == right && lhs > rhs)
            }
    }

    /// 선택 이동. 끝에서 멈춘다 (돌아가지 않는다).
    public static func move(_ index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index + delta, 0), count - 1)
    }
}

/// 직접 추가 ("Add “…”"). 짧은 한 줄을 찾았는데 열린 할 일(Review · In Progress · To Do)에 맞는 것이 없을 때만 보인다.
/// 오늘 끝낸 할 일(Done Today)은 보지 않는다.
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

    /// 그 말과 맞는 열린 할 일 (`TaskFilter`): Review 먼저, 그다음 GET /now 목록(In Progress · To Do), 받은 순서 그대로. 같은 할 일은 한 번만.
    /// iPhone New Task의 "Existing" 힌트 (추가는 막지 않는다). 빈칸이거나 목록을 아직 못 읽었으면 없음.
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

/// ⌘⌫ (Review Dismiss · 할 일 Delete · 처리방침 안내 닫기)는 되돌리기 어려운 키라, 누르고 있어 반복된 입력은 무시한다.
/// 안내 줄을 닫으면 다음 줄(Review 카드 · 할 일)이 골라지므로, 닫은 직후 잠깐 들어온 ⌘⌫(두 번 누름)도 무시한다.
public struct LauncherDeleteGuard: Sendable, Equatable {
    /// 안내를 닫은 뒤 ⌘⌫를 받지 않는 시간
    public static let settle: TimeInterval = 0.6

    private var quietUntil: Date?

    public init() {}

    /// 이 ⌘⌫를 실행해도 되는지
    public func allows(isRepeat: Bool, at now: Date) -> Bool {
        if isRepeat { return false }
        if let quietUntil, now < quietUntil { return false }
        return true
    }

    /// 처리방침 안내 줄을 ⌘⌫로 닫았을 때
    public mutating func noticeDismissed(at now: Date) {
        quietUntil = now.addingTimeInterval(Self.settle)
    }
}

/// ↩ · ⌘↩. Review는 제목만 보고 확정하지 않게 ↩로 확정하지 않는다: 목록의 Review 행에서 ↩는 근거(Sources 묶음)를 펼치고,
/// 확정은 ⌘↩다(목록 · 펼침 · ⌘K 패널 어디서든 고른 줄과 상관없이, ⌘K 패널의 Confirm도 그대로). Dismiss는 ⌘⌫(`LauncherDeleteGuard`).
/// 누르고 있어 반복된 ↩ · ⌘↩는 어느 화면에서나 먹고 아무것도 하지 않는다: 펼침 → ⌘K 패널로 이어지거나, 확정 뒤 누르고 있던 키가
/// 다음 화면 · 목록 첫 줄(안내 · 다른 Review · 할 일)을 실행하지 않게. 런처에 키 반복이 필요한 곳은 없다.
/// ⌘K 패널은 Review면 Confirm이 아니라 Open source를 고른 채 연다(앱 `LauncherModel`).
/// 다른 행 · 화면은 지금까지처럼 그 화면의 기본 동작이다(⌘↩도 ↩와 같고, 줄 고르기의 ⌘↩는 보내기).
public enum LauncherReturn {
    /// ↩를 받은 곳
    public enum Place: Equatable, Sendable {
        /// 목록: 고른 행 (없으면 nil)
        case list(LauncherItem?)
        /// 펼침 · ⌘K 패널: 그 할 일의 (지금) 구역
        case task(TaskGroup)
        /// 그 밖의 화면 (기한 · 원문 · 줄 고르기, 물어보기 답 등)
        case other
    }

    public enum Effect: Equatable, Sendable {
        /// 그 화면의 기본 동작 (행 실행 · ⌘K 패널 열기 · 고른 줄 실행)
        case primary
        /// Review 행의 근거 펼치기
        case showSources
        /// Review 확정
        case confirm
        /// 먹고 아무것도 하지 않는다
        case ignore
    }

    public static func effect(at place: Place, command: Bool, isRepeat: Bool) -> Effect {
        if isRepeat { return .ignore }
        let onList: Bool
        switch place {
        case .list(let item) where item?.group == .review: onList = true
        case .task(.review): onList = false
        default: return .primary
        }
        if command { return .confirm }
        return onList ? .showSources : .primary
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
