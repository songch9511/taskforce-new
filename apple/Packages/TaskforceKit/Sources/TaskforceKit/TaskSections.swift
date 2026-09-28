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
}

/// 서버 응답을 기다리지 않고 먼저 보여 주는 내 변경. 쓰기가 끝난 뒤 다시 읽은 목록이 반영되면 지운다 (`NowStore`).
public enum TaskChange: Sendable, Hashable {
    /// Start → In Progress (서버 순서 그대로의 자리)
    case started(at: Date)
    /// Complete → Done Today 맨 위
    case completed(ActionSummary, at: Date)
    /// Reopen → 열린 목록 끝 (다시 읽으면 서버 순서로)
    case reopened(ActionSummary, at: Date)

    public var at: Date {
        switch self {
        case .started(let at), .completed(_, let at), .reopened(_, let at): at
        }
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
            switch change {
            case .started(let at):
                if let index = open.firstIndex(where: { $0.id == id }), open[index].action.startedAt == nil {
                    open[index] = open[index].replacing(action: open[index].action.replacing(startedAt: at))
                }
            case .completed(let action, _):
                open.removeAll { $0.id == id }
                reviews.removeAll { $0.id == id }
                done.removeAll { $0.id == id }
                done.insert(action.replacing(status: .done), at: 0)
            case .reopened(let action, _):
                done.removeAll { $0.id == id }
                if !open.contains(where: { $0.id == id }), !reviews.contains(where: { $0.id == id }) {
                    open.append(RankedAction(action: action.replacing(status: .open), score: 0, reasons: [], daysUntilDue: nil))
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
    func replacing(status: ActionStatus? = nil, startedAt: Date? = nil) -> ActionSummary {
        ActionSummary(
            id: id, title: title, owner: owner, status: status ?? self.status, dueDate: dueDate, counterpart: counterpart,
            needsConfirmation: needsConfirmation, confirmReasons: confirmReasons, startedAt: startedAt ?? self.startedAt,
            lastActivityAt: lastActivityAt
        )
    }
}

extension RankedAction {
    func replacing(action: ActionSummary) -> RankedAction {
        RankedAction(action: action, score: score, reasons: reasons, daysUntilDue: daysUntilDue)
    }
}
