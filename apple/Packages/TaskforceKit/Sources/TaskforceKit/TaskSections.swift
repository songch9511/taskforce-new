import Foundation

// 할 일 목록의 구역 (iPhone 한 화면 · Mac 런처 공용): Review · In Progress · To Do · Done Today.
// 순서 계산은 서버에만 있다 (GET /now). 여기서는 받은 목록을 나누고 · 거르고 · 아직 서버 목록에 반영되지 않은 내 변경을 얹기만 한다.

/// 할 일이 놓이는 구역 (위에서 아래 순서)
public enum TaskGroup: String, CaseIterable, Sendable, Hashable {
    /// 확인 요청
    case review
    /// 열림 + 착수함 (`started_at`)
    case inProgress
    /// 열림 + 착수 전
    case toDo
    /// 오늘 끝냄
    case doneToday

    public var title: String {
        switch self {
        case .review: "Review"
        case .inProgress: "In Progress"
        case .toDo: "To Do"
        case .doneToday: "Done Today"
        }
    }

    /// 확인 요청이 아닌 열린 할 일의 구역: 착수했으면 In Progress, 아니면 To Do
    public static func open(_ action: ActionSummary) -> TaskGroup {
        action.startedAt == nil ? .toDo : .inProgress
    }

    /// Delete를 보이는 구역 (In Progress · To Do · Done Today). Review는 Dismiss가 그 자리다.
    public var isDeletable: Bool { self != .review }
}

/// 할 일의 진행 상태: 구역 In Progress · To Do · Done Today와 같은 이름. `POST /actions/:id/progress`의 `state` (contract.ts `actionProgressStateSchema`).
public enum WorkState: String, Codable, CaseIterable, Sendable, Hashable {
    case toDo = "to_do"
    case inProgress = "in_progress"
    case done

    /// 화면에 쓰는 이름 (구역 이름과 같다. Done Today는 "Done")
    public var title: String {
        switch self {
        case .toDo: "To Do"
        case .inProgress: "In Progress"
        case .done: "Done"
        }
    }

    /// 그 구역에 있는 할 일의 상태. Review는 확인 전이라 없다.
    public init?(_ group: TaskGroup) {
        switch group {
        case .review: return nil
        case .inProgress: self = .inProgress
        case .toDo: self = .toDo
        case .doneToday: self = .done
        }
    }

    /// 이 상태로 옮기면 놓이는 구역
    public var group: TaskGroup {
        switch self {
        case .toDo: .toDo
        case .inProgress: .inProgress
        case .done: .doneToday
        }
    }

    /// 상태 표시를 눌렀을 때 갈 상태: 열린 할 일은 Done, 끝낸 할 일은 끝내기 전 상태.
    /// 끝내기 전 상태는 이 기기에서 끝낼 때 기억해 둔 것(`remembered`), 없으면 착수 시각이 있을 때 In Progress, 그것도 없으면 To Do.
    public static func toggled(from current: WorkState, _ action: ActionSummary, remembered: WorkState? = nil) -> WorkState {
        guard current == .done else { return .done }
        if let remembered, remembered != .done { return remembered }
        return action.startedAt == nil ? .toDo : .inProgress
    }
}

/// 서버 응답을 기다리지 않고 먼저 보여 주는 내 변경 (To Do · In Progress · Done으로 옮김 · 삭제).
/// 쓰기가 끝난 뒤 다시 읽은 목록이 반영되면 지운다 (`NowStore`).
/// - Done: Done Today 맨 위
/// - In Progress: 열린 목록의 서버 순서 자리 (착수 시각은 서버 값을 둔다). 열린 목록에 없으면 (다시 열기 · 되살리기) 끝에
/// - To Do: 착수 시각을 지운다. 자리는 In Progress와 같다
/// - 삭제 (`deleting`): 어느 목록에도 두지 않는다
public struct TaskChange: Sendable, Hashable {
    /// 옮기기 전 값 (열린 목록 · 끝낸 목록에 없으면 이 값으로 끼운다)
    public let action: ActionSummary
    /// 옮길 상태. 삭제면 nil
    public let state: WorkState?
    public let at: Date

    public init(_ action: ActionSummary, to state: WorkState, at: Date) {
        self.init(action: action, state: state, at: at)
    }

    private init(action: ActionSummary, state: WorkState?, at: Date) {
        self.action = action
        self.state = state
        self.at = at
    }

    /// 삭제 (`DELETE /actions/:id`, 서버는 취소로 두고 이력을 남긴다)
    public static func deleting(_ action: ActionSummary, at: Date) -> TaskChange {
        TaskChange(action: action, state: nil, at: at)
    }

    /// 옮긴 뒤 착수 시각: To Do는 없음, In Progress는 있던 값(없으면 옮긴 시각)
    func startedAt(keeping current: Date?) -> Date? {
        switch state {
        case .toDo: nil
        case .inProgress: current ?? at
        case .done, nil: current
        }
    }
}

/// 잠시 되돌릴 수 있는 방금 한 변경 (Mac "Undo ⌘Z" · iPhone "Deleted  Undo"): 그 할 일의 바꾸기 전 값과 상태
public struct TaskUndo: Sendable, Hashable {
    public enum Change: Sendable, Hashable {
        /// 진행 상태를 옮김 → 그 전 상태로 옮긴다 (`POST progress`)
        case moved
        /// 삭제함 → 지우기 전 구역으로 되살린다 (`restoreEdit`)
        case deleted
    }

    public let action: ActionSummary
    /// 바꾸기 전 상태
    public let state: WorkState
    public let change: Change

    public init(_ action: ActionSummary, was state: WorkState, change: Change) {
        self.action = action
        self.state = state
        self.change = change
    }

    /// 삭제 되돌리기의 서버 쓰기 (`PATCH /actions/:id`): Done Today였으면 done, 아니면 open.
    /// 삭제는 착수 시각을 지우지 않아서, 착수했던 할 일은 다시 열면 In Progress로 돌아온다 (`TaskGroup.open`).
    public var restoreEdit: ActionEdit {
        ActionEdit(status: state == .done ? .done : .open)
    }

    /// 먼저 보여 줄 되살리기: 지우기 전 구역 (열린 할 일은 그 구역 끝, Done은 Done Today 맨 위. 다시 읽으면 서버 자리로)
    public func restoring(at date: Date) -> TaskChange {
        TaskChange(action, to: state, at: date)
    }
}

/// 되돌리기를 잠시(`window`) 둔다. 새로 두면 전 것은 사라지고, 시간이 다 되어 거둘 때는 그때 둔 것일 때만 거둔다
/// (그사이 새로 둔 되돌리기를 지우지 않게).
public struct UndoOffer: Sendable, Hashable {
    /// 되돌리기를 보여 주는 시간
    public static let window: Duration = .seconds(5)

    public private(set) var pending: TaskUndo?
    /// 둘 때마다 오른다 (`expire`에 넘긴다)
    public private(set) var serial = 0

    public init() {}

    public mutating func offer(_ undo: TaskUndo) {
        pending = undo
        serial += 1
    }

    /// 시간이 다 됨: 그 번호가 아직 지금 것이면 거둔다
    public mutating func expire(_ serial: Int) {
        if serial == self.serial { pending = nil }
    }

    /// 되돌리기: 꺼내고 비운다 (한 번만)
    public mutating func take() -> TaskUndo? {
        defer { pending = nil }
        return pending
    }

    public mutating func clear() {
        pending = nil
    }
}

/// 서버에서 읽은 두 목록: GET /now (열린 할 일 · 확인 요청) + 오늘 끝낸 할 일 (`TaskforceReads.doneToday`, 최근 것이 위)
public struct TaskBoard: Sendable, Hashable {
    public var now: NowResponse?
    public var doneToday: [ActionSummary]

    public init(now: NowResponse?, doneToday: [ActionSummary] = []) {
        self.now = now
        self.doneToday = doneToday
    }

    /// 내 변경을 얹은 목록. 변경은 시각 순서로 얹는다 (나중에 끝낸 것이 Done Today 위).
    /// 목록을 아직 못 읽었으면 그대로 둔다.
    public func applying(_ changes: [UUID: TaskChange]) -> TaskBoard {
        guard let now, !changes.isEmpty else { return self }
        var open = now.now
        var reviews = now.confirmations
        var done = doneToday
        for (id, change) in changes.sorted(by: { $0.value.at < $1.value.at }) {
            guard let state = change.state else {
                open.removeAll { $0.id == id }
                reviews.removeAll { $0.id == id }
                done.removeAll { $0.id == id }
                continue
            }
            switch state {
            case .done:
                open.removeAll { $0.id == id }
                reviews.removeAll { $0.id == id }
                done.removeAll { $0.id == id }
                done.insert(change.action.replacing(status: .done, startedAt: change.action.startedAt), at: 0)
            case .toDo, .inProgress:
                done.removeAll { $0.id == id }
                if let index = open.firstIndex(where: { $0.id == id }) {
                    let current = open[index].action
                    open[index] = open[index].replacing(
                        action: current.replacing(status: .open, startedAt: change.startedAt(keeping: current.startedAt))
                    )
                } else if !reviews.contains(where: { $0.id == id }) {
                    let action = change.action.replacing(status: .open, startedAt: change.startedAt(keeping: change.action.startedAt))
                    open.append(RankedAction(action: action, score: 0, reasons: [], daysUntilDue: nil))
                }
            }
        }
        return TaskBoard(now: NowResponse(now: open, confirmations: reviews, weeklyCheck: now.weeklyCheck), doneToday: done)
    }

    /// 구역으로 나눈다. `query`가 있으면 네 구역 모두 그 말로 거른다 (`TaskFilter`, 순서는 그대로).
    public func sections(matching query: String? = nil) -> TaskSections {
        let query = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let matches: (ActionSummary) -> Bool = { query.isEmpty || TaskFilter.matches($0, query: query) }
        let reviews = (now?.confirmations ?? []).filter { $0.status == .open && matches($0) }
        let open = (now?.now ?? []).filter { $0.action.status == .open && !$0.action.needsConfirmation && matches($0.action) }
        // 열린 목록과 끝낸 목록에 같은 할 일이 있으면 열린 쪽을 믿는다 (다른 기기에서 다시 연 것)
        var seen = Set(reviews.map(\.id) + open.map(\.id))
        let done = doneToday.filter { $0.status == .done && matches($0) && seen.insert($0.id).inserted }
        return TaskSections(
            review: reviews,
            inProgress: open.filter { TaskGroup.open($0.action) == .inProgress },
            toDo: open.filter { TaskGroup.open($0.action) == .toDo },
            doneToday: done
        )
    }
}

/// 구역으로 나눈 목록. 각 구역 안의 순서는 받은 그대로 (In Progress · To Do는 서버 순서, Done Today는 최근 것이 위).
public struct TaskSections: Sendable, Hashable {
    public let review: [ActionSummary]
    public let inProgress: [RankedAction]
    public let toDo: [RankedAction]
    public let doneToday: [ActionSummary]

    public init(review: [ActionSummary], inProgress: [RankedAction], toDo: [RankedAction], doneToday: [ActionSummary]) {
        self.review = review
        self.inProgress = inProgress
        self.toDo = toDo
        self.doneToday = doneToday
    }

    public var isEmpty: Bool { review.isEmpty && inProgress.isEmpty && toDo.isEmpty && doneToday.isEmpty }

    /// 구역의 할 일 (받은 순서)
    public func actions(in group: TaskGroup) -> [ActionSummary] {
        switch group {
        case .review: review
        case .inProgress: inProgress.map(\.action)
        case .toDo: toDo.map(\.action)
        case .doneToday: doneToday
        }
    }

    /// 그 할 일이 있는 구역과 지금 값
    public func find(_ id: UUID) -> (group: TaskGroup, action: ActionSummary)? {
        for group in TaskGroup.allCases {
            if let action = actions(in: group).first(where: { $0.id == id }) { return (group, action) }
        }
        return nil
    }
}

extension ActionSummary {
    /// 서버 응답을 기다리지 않고 보여 줄 값 (`TaskBoard.applying`)
    func replacing(status: ActionStatus, startedAt: Date?) -> ActionSummary {
        ActionSummary(
            id: id, title: title, owner: owner, status: status, dueDate: dueDate, counterpart: counterpart,
            needsConfirmation: needsConfirmation, confirmReasons: confirmReasons, startedAt: startedAt,
            lastActivityAt: lastActivityAt
        )
    }
}

extension RankedAction {
    func replacing(action: ActionSummary) -> RankedAction {
        RankedAction(action: action, score: score, reasons: reasons, daysUntilDue: daysUntilDue)
    }
}
