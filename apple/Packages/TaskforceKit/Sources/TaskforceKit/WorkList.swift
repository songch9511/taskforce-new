import Foundation

// 0.2.0 All work (디자인 WorkList): 기존 목록(GET /now의 확인 요청 · 열린 할 일 + 오늘 끝낸 할 일)을
// 프로젝트 묶음 → Ungrouped → Done today로, 검색 · 필터 · 고정과 함께 보인다 (화면 없는 순수 규칙).
// 순서 계산은 서버에만 있다: 묶음 안의 순서는 받은 그대로이고, 고정한 일만 그 묶음 앞으로 올린다. 활동이 바뀌어도 줄 순서는 그대로다.
// 데이터에 없는 의미는 만들지 않는다 (`WorkItem`의 필드마다 무엇에서 왔는지 적는다).

/// 행의 활동 글 (디자인 ActivityRing · WorkRow와 같은 말)
public enum WorkActivity {
    /// 확인 요청 (Review): 사용자의 답을 기다린다
    public static let needsAnswer = "Needs your answer"
    /// 끝나지 않은 run이 있다
    public static let running = "Running"
    /// 멈춤을 요청했고 아직 끝나지 않았다 (디자인 D-5)
    public static let stopRequested = "Stop requested · not confirmed"
}

/// All work의 한 줄
public struct WorkItem: Sendable, Hashable, Identifiable {
    public let action: ActionSummary
    /// 세 상태(디자인 StatusMark ○ ◉ ✓). 확인 요청(Review)은 상태가 아니라 활동이다: 착수 시각으로 To Do · In Progress
    public let state: WorkState
    /// 프로젝트. 지금 `actions`에는 프로젝트가 없어 늘 nil(Ungrouped). S3b가 `work_contexts` 멤버십으로 채운다
    public let project: String?
    /// 수행자. 담당이 나(`owner = me`)면 "You", 모름(`unknown`)이면 없음 (지어내지 않는다)
    public let performer: String?
    /// 지금 하는 일 (`WorkActivity`). 없으면 nil
    public let activity: String?
    /// 남(사람 · 답)을 기다림. 지금 데이터에는 근거가 없어 늘 false: Waiting 필터는 아무것도 고르지 않는다
    public let waiting: Bool
    /// 서버의 순서 이유 (기한 빨강 `DueText.isUrgent`). 확인 요청 · 끝낸 일은 없음
    public let reasons: [RankReason]

    public var id: UUID { action.id }

    public init(
        action: ActionSummary, state: WorkState, project: String? = nil, performer: String? = nil, activity: String? = nil,
        waiting: Bool = false, reasons: [RankReason] = []
    ) {
        self.action = action
        self.state = state
        self.project = project
        self.performer = performer
        self.activity = activity
        self.waiting = waiting
        self.reasons = reasons
    }

    /// 수행자: 담당이 나면 "You"
    public static func performer(_ owner: ActionOwner) -> String? {
        owner == .me ? "You" : nil
    }

    /// 받은 목록을 줄로: 확인 요청(서버 순서) → 열린 할 일(서버 순서) → 오늘 끝낸 할 일(최근 것이 위).
    /// `working`: 끝나지 않은 run이 있는 할 일, `stopping`: 그중 멈춤을 요청한 할 일, `reasons`: 열린 할 일의 서버 순서 이유
    public static func list(
        reviews: [ActionSummary], open: [ActionSummary], doneToday: [ActionSummary],
        working: Set<UUID> = [], stopping: Set<UUID> = [], reasons: [UUID: [RankReason]] = [:]
    ) -> [WorkItem] {
        var seen = Set<UUID>()
        var items: [WorkItem] = []
        for action in reviews where seen.insert(action.id).inserted {
            items.append(WorkItem(
                action: action, state: openState(action), performer: performer(action.owner), activity: WorkActivity.needsAnswer
            ))
        }
        for action in open where seen.insert(action.id).inserted {
            let activity: String? = working.contains(action.id)
                ? (stopping.contains(action.id) ? WorkActivity.stopRequested : WorkActivity.running)
                : nil
            items.append(WorkItem(
                action: action, state: openState(action), performer: performer(action.owner), activity: activity,
                reasons: reasons[action.id] ?? []
            ))
        }
        for action in doneToday where seen.insert(action.id).inserted {
            items.append(WorkItem(action: action, state: .done, performer: performer(action.owner)))
        }
        return items
    }

    private static func openState(_ action: ActionSummary) -> WorkState {
        action.startedAt == nil ? .toDo : .inProgress
    }

    /// 검색이 보는 글: 제목 · 프로젝트 · 수행자 · 활동 (디자인 WorkList)
    var searchText: String {
        [action.title, project ?? WorkListGroup.ungroupedTitle, performer ?? "", activity ?? ""].joined(separator: " ")
    }
}

/// Project 필터의 값
public enum WorkProjectFilter: Sendable, Hashable {
    case all
    case project(String)
    case ungrouped

    /// 칩 글자
    public var title: String {
        switch self {
        case .all: "All"
        case .project(let name): name
        case .ungrouped: WorkListGroup.ungroupedTitle
        }
    }

    func matches(_ item: WorkItem) -> Bool {
        switch self {
        case .all: true
        case .project(let name): item.project == name
        case .ungrouped: item.project == nil
        }
    }
}

/// Status 필터의 값 (디자인 순서: All · In Progress · To Do · Waiting · Done). Waiting은 상태가 아니라 기다림 조건이다
public enum WorkStatusFilter: String, CaseIterable, Sendable, Hashable {
    case all, inProgress, toDo, waiting, done

    public var title: String {
        switch self {
        case .all: "All"
        case .inProgress: WorkState.inProgress.title
        case .toDo: WorkState.toDo.title
        case .waiting: "Waiting"
        case .done: WorkState.done.title
        }
    }

    func matches(_ item: WorkItem) -> Bool {
        switch self {
        case .all: true
        case .inProgress: item.state == .inProgress
        case .toDo: item.state == .toDo
        case .waiting: item.waiting
        case .done: item.state == .done
        }
    }
}

/// 검색어 + 두 필터. 셋은 함께 건다 (AND)
public struct WorkFilter: Sendable, Hashable {
    public var query: String
    public var project: WorkProjectFilter
    public var status: WorkStatusFilter

    public init(query: String = "", project: WorkProjectFilter = .all, status: WorkStatusFilter = .all) {
        self.query = query
        self.project = project
        self.status = status
    }

    /// 고른 필터의 이름 (검색어는 빼고): 닫혀 있을 때 한 줄 요약 "Shape launch · Waiting", 필터 버튼의 접근성 이름
    public var activeLabels: [String] {
        var labels: [String] = []
        if project != .all { labels.append(project.title) }
        if status != .all { labels.append(status.title) }
        return labels
    }

    public var hasActiveFilters: Bool { project != .all || status != .all }

    /// Clear: 두 필터만 비운다 (검색어는 둔다)
    public mutating func clearFilters() {
        project = .all
        status = .all
    }

    public func matches(_ item: WorkItem) -> Bool {
        project.matches(item) && status.matches(item) && TaskFilter.matches(text: item.searchText, query: query)
    }
}

/// 한 묶음: 프로젝트 · Ungrouped · Done today. 묶음 이름에 개수를 쓰지 않는다
public struct WorkListGroup: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case project(String)
        case ungrouped
        case doneToday
    }

    public static let ungroupedTitle = "Ungrouped"
    public static let doneTodayTitle = "Done today"

    public let kind: Kind
    public let items: [WorkItem]

    public init(kind: Kind, items: [WorkItem]) {
        self.kind = kind
        self.items = items
    }

    public var title: String {
        switch kind {
        case .project(let name): name
        case .ungrouped: Self.ungroupedTitle
        case .doneToday: Self.doneTodayTitle
        }
    }

    public var id: String {
        switch kind {
        case .project(let name): "project:\(name)"
        case .ungrouped: "ungrouped"
        case .doneToday: "done-today"
        }
    }
}

public enum WorkListLayout {
    /// 묶음: 프로젝트(처음 나온 차례) → Ungrouped → Done today(끝낸 일 전부, 프로젝트와 상관없이). 빈 묶음은 뺀다.
    /// 고정한 일은 그 묶음 맨 앞(고정한 일끼리 · 나머지끼리는 받은 순서)
    public static func groups(_ items: [WorkItem], filter: WorkFilter, pinned: Set<UUID>) -> [WorkListGroup] {
        let shown = items.filter(filter.matches)
        let open = shown.filter { $0.state != .done }
        var groups = projects(items).map { name in
            WorkListGroup(kind: .project(name), items: open.filter { $0.project == name })
        }
        groups.append(WorkListGroup(kind: .ungrouped, items: open.filter { $0.project == nil }))
        groups.append(WorkListGroup(kind: .doneToday, items: shown.filter { $0.state == .done }))
        return groups.filter { !$0.items.isEmpty }.map { group in
            WorkListGroup(kind: group.kind, items: group.items.filter { pinned.contains($0.id) } + group.items.filter { !pinned.contains($0.id) })
        }
    }

    /// Project 칩: All · 프로젝트(처음 나온 차례) · Ungrouped
    public static func projectOptions(_ items: [WorkItem]) -> [WorkProjectFilter] {
        [.all] + projects(items).map(WorkProjectFilter.project) + [.ungrouped]
    }

    /// 프로젝트 이름 (처음 나온 차례, 겹침 없음). 필터와 상관없이 전체 목록에서 정해 묶음 순서가 흔들리지 않는다
    static func projects(_ items: [WorkItem]) -> [String] {
        var seen = Set<String>()
        return items.compactMap(\.project).filter { seen.insert($0).inserted }
    }
}

/// 고정 (디자인: 셋까지, 그 묶음 맨 앞). 서버에 자리가 없어 이 Mac에 계정별로 둔다 (`WorkPinStore`)
public struct WorkPins: Sendable, Hashable {
    public static let limit = 3

    /// 고정한 차례
    public private(set) var ids: [UUID]

    /// 겹침을 빼고 셋까지만 (저장본이 어긋나도)
    public init(_ ids: [UUID] = []) {
        var seen = Set<UUID>()
        self.ids = Array(ids.filter { seen.insert($0).inserted }.prefix(Self.limit))
    }

    public func isPinned(_ id: UUID) -> Bool { ids.contains(id) }

    /// 지금 목록에 있는 고정 (목록에서 사라진 일의 고정은 화면에 없다)
    public func shown(in items: [WorkItem]) -> Set<UUID> {
        Set(ids).intersection(items.map(\.id))
    }

    /// 더 고정할 수 있나. `known`: 지금 목록의 모든 일 (목록에서 사라진 옛 고정은 자리를 차지하지 않는다)
    public func canPin(_ id: UUID, known: Set<UUID>) -> Bool {
        isPinned(id) || (known.contains(id) && ids.filter(known.contains).count < Self.limit)
    }

    /// 고정. 이미 고정이면 그대로(겹치지 않는다). 목록에서 사라진 옛 고정은 먼저 비운다. 셋이 차 있거나 목록에 없는 일이면 false
    @discardableResult
    public mutating func pin(_ id: UUID, known: Set<UUID>) -> Bool {
        if isPinned(id) { return true }
        guard canPin(id, known: known) else { return false }
        ids = ids.filter(known.contains) + [id]
        return true
    }

    public mutating func unpin(_ id: UUID) {
        ids.removeAll { $0 == id }
    }
}

/// 목록을 보일 수 있는 상태 (디자인 D-14: 오프라인 · 읽기 실패 · 업무 없음은 다른 화면).
/// 이번 실행에서 받은 목록이 없으면 "할 일이 없다"고 말하지 않는다: 읽는 중이면 아무것도 보이지 않고, 오프라인 · 실패면 그 화면이다.
public enum WorkLoad: Sendable, Hashable {
    /// 받은 목록 뒤에 생긴 문제 (목록은 그대로 두고 위에 Notice 하나)
    public enum Problem: Sendable, Hashable {
        case offline, failed
    }

    /// 이번 실행의 목록이 아직 없음 (로그아웃 · 처음 불러오는 중)
    case loading
    /// 목록 있음. 그 뒤 끊겼거나 다시 읽지 못했으면 `problem`
    case loaded(problem: Problem?)
    /// 목록 없이 오프라인: "You're offline"
    case offline
    /// 목록 없이 읽기 실패: "Couldn't load your work"
    case failed

    /// `refresh`: 연결 · 불러오기 상태 (`RefreshTracker`), `hasList`: 이번 실행에서 서버로부터 받은 목록이 있나 (저장본은 아니다)
    public static func from(refresh: RefreshState, hasList: Bool) -> WorkLoad {
        switch refresh {
        case .offlineSaved, .offlineEmpty:
            hasList ? .loaded(problem: .offline) : .offline
        case .refreshFailed:
            hasList ? .loaded(problem: .failed) : .failed
        case .live, .loading:
            hasList ? .loaded(problem: nil) : .loading
        }
    }
}

/// Done today의 날짜 경계 (앱의 표시 규칙: 기기 시간대의 오늘 끝낸 할 일)
public enum DoneTodayWindow {
    /// Done today 목록은 `since`(그 목록을 읽은 기기 시간대의 그날 0시) 뒤에 끝낸 것이다.
    /// 지금 기기 시간대의 오늘 0시와 같을 때만 "오늘"이다: 자정이 지났거나 시간대가 바뀌면 다시 읽을 때까지 비운다 (어제 끝낸 일을 오늘이라 하지 않는다)
    public static func isCurrent(since: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let since else { return false }
        return calendar.startOfDay(for: now) == since
    }
}
