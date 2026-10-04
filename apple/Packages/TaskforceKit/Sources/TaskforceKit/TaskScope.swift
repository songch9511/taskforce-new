import Foundation

/// 런처 범위 (Figma M13 `All Tasks ⌄`): 목록을 한 구역 · 바뀐 할 일로 좁힌다. 범위마다 개수를 보인다.
/// All Tasks 개수는 열린 할 일(Review + In Progress + To Do)이다 (M13 23 = 4 + 5 + 14). 목록에는 Done Today가 접힌 한 줄로 붙는다.
/// `Waiting on Someone`은 U5가 더한다 (M13 순서: … Done Today | Waiting on Someone · Taskforce Working · Changed Since Last Look).
public enum TaskScope: String, CaseIterable, Sendable, Hashable {
    case allTasks
    case review
    case inProgress
    case toDo
    case doneToday
    /// 끝나지 않은 run이 있는 열린 할 일 (U2 Mac, `RunSummary.isOpen`). 실행을 쓸 수 없는 계정에는 보이지 않는다
    case taskforceWorking
    /// 사용자가 마지막으로 본 뒤 사용자 아닌 쪽이 바꾼 열린 할 일 (`/now` `changed`)
    case changed

    public var title: String {
        switch self {
        case .allTasks: "All Tasks"
        case .review: TaskGroup.review.title
        case .inProgress: TaskGroup.inProgress.title
        case .toDo: TaskGroup.toDo.title
        case .doneToday: TaskGroup.doneToday.title
        case .taskforceWorking: "Taskforce Working"
        case .changed: "Changed Since Last Look"
        }
    }

    /// 범위 메뉴에 보일 범위. 서버가 바뀜을 보내지 않으면(예전 서버) 바뀜 범위를 숨긴다 (내용이 없는 범위는 보이지 않는다).
    /// `Taskforce Working`은 실행을 쓸 수 있을 때만 (`showsTaskforce`, credits 200)
    public static func menu(tracksChanges: Bool, showsTaskforce: Bool = false) -> [TaskScope] {
        allCases.filter { ($0 != .changed || tracksChanges) && ($0 != .taskforceWorking || showsTaskforce) }
    }

    /// 범위의 개수. `working`: 끝나지 않은 run이 있는 할 일
    public func count(in sections: TaskSections, changed: Set<UUID>, working: Set<UUID> = []) -> Int {
        if self == .allTasks { return sections.openCount }
        let scoped = apply(to: sections, changed: changed, working: working)
        return scoped.openCount + scoped.doneToday.count
    }

    /// 범위로 좁힌 목록 (구역 안 순서는 그대로). `working`: 끝나지 않은 run이 있는 할 일
    public func apply(to sections: TaskSections, changed: Set<UUID>, working: Set<UUID> = []) -> TaskSections {
        switch self {
        case .allTasks:
            sections
        case .review:
            TaskSections(review: sections.review, inProgress: [], toDo: [], doneToday: [])
        case .inProgress:
            TaskSections(review: [], inProgress: sections.inProgress, toDo: [], doneToday: [])
        case .toDo:
            TaskSections(review: [], inProgress: [], toDo: sections.toDo, doneToday: [])
        case .doneToday:
            TaskSections(review: [], inProgress: [], toDo: [], doneToday: sections.doneToday)
        case .taskforceWorking:
            Self.openTasks(in: sections, matching: working)
        case .changed:
            Self.openTasks(in: sections, matching: changed)
        }
    }

    /// 열린 할 일(Review · In Progress · To Do) 중 `ids`에 든 것
    private static func openTasks(in sections: TaskSections, matching ids: Set<UUID>) -> TaskSections {
        TaskSections(
            review: sections.review.filter { ids.contains($0.id) },
            inProgress: sections.inProgress.filter { ids.contains($0.id) },
            toDo: sections.toDo.filter { ids.contains($0.id) },
            doneToday: []
        )
    }
}

extension TaskScope {
    /// 범위가 보이는 구역 (All Tasks는 네 구역 모두, Done Today는 접힌 한 줄)
    public var groups: [TaskGroup] {
        switch self {
        case .allTasks: TaskGroup.allCases
        case .review: [.review]
        case .inProgress: [.inProgress]
        case .toDo: [.toDo]
        case .doneToday: [.doneToday]
        case .taskforceWorking, .changed: [.review, .inProgress, .toDo]
        }
    }

    /// 저장본(오프라인 · 새로고침 실패)에서 그 구역의 행. 저장본에는 바뀜 · run이 없어(제목 · 기한 · 상태만) 두 범위는 비어 있다
    public func rows(in saved: SavedNow, group: TaskGroup, now: Date, timeZone: TimeZone = .current) -> [SavedNow.Row] {
        guard self != .changed, self != .taskforceWorking, groups.contains(group) else { return [] }
        return saved.rows(in: group, now: now, timeZone: timeZone)
    }

    /// 저장본의 범위 개수 (All Tasks = Review + In Progress + To Do, `count(in:changed:)`와 같은 규칙)
    public func count(in saved: SavedNow, now: Date, timeZone: TimeZone = .current) -> Int {
        let counted = self == .allTasks ? [TaskGroup.review, .inProgress, .toDo] : groups
        return counted.reduce(0) { $0 + rows(in: saved, group: $1, now: now, timeZone: timeZone).count }
    }
}

extension TaskSections {
    /// 열린 할 일 수 (Review + In Progress + To Do)
    var openCount: Int { review.count + inProgress.count + toDo.count }
}
