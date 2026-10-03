import Foundation

/// 런처 범위 (Figma M13 `All Tasks ⌄`): 목록을 한 구역 · 바뀐 할 일로 좁힌다. 범위마다 개수를 보인다.
/// All Tasks 개수는 열린 할 일(Review + In Progress + To Do)이다 (M13 23 = 4 + 5 + 14). 목록에는 Done Today가 접힌 한 줄로 붙는다.
/// `Waiting on Someone` · `Taskforce Working`은 그 단위(U5 · U2 Mac)가 더한다.
public enum TaskScope: String, CaseIterable, Sendable, Hashable {
    case allTasks
    case review
    case inProgress
    case toDo
    case doneToday
    /// 사용자가 마지막으로 본 뒤 사용자 아닌 쪽이 바꾼 열린 할 일 (`/now` `changed`)
    case changed

    public var title: String {
        switch self {
        case .allTasks: "All Tasks"
        case .review: TaskGroup.review.title
        case .inProgress: TaskGroup.inProgress.title
        case .toDo: TaskGroup.toDo.title
        case .doneToday: TaskGroup.doneToday.title
        case .changed: "Changed Since Last Look"
        }
    }

    /// 범위 메뉴에 보일 범위. 서버가 바뀜을 보내지 않으면(예전 서버) 바뀜 범위를 숨긴다 (내용이 없는 범위는 보이지 않는다)
    public static func menu(tracksChanges: Bool) -> [TaskScope] {
        allCases.filter { $0 != .changed || tracksChanges }
    }

    /// 범위의 개수
    public func count(in sections: TaskSections, changed: Set<UUID>) -> Int {
        if self == .allTasks { return sections.openCount }
        let scoped = apply(to: sections, changed: changed)
        return scoped.openCount + scoped.doneToday.count
    }

    /// 범위로 좁힌 목록 (구역 안 순서는 그대로)
    public func apply(to sections: TaskSections, changed: Set<UUID>) -> TaskSections {
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
        case .changed:
            TaskSections(
                review: sections.review.filter { changed.contains($0.id) },
                inProgress: sections.inProgress.filter { changed.contains($0.id) },
                toDo: sections.toDo.filter { changed.contains($0.id) },
                doneToday: []
            )
        }
    }
}

extension TaskSections {
    /// 열린 할 일 수 (Review + In Progress + To Do)
    var openCount: Int { review.count + inProgress.count + toDo.count }
}
