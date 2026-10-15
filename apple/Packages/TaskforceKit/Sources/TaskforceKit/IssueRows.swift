import Foundation

// OA U2: 이슈 목록(M3)의 규칙 (화면 없는 순수 함수). 프로젝트 · Ungrouped 안은 상태별 그룹 In Progress → To Do → Done today(빈 그룹은 그리지 않고 라벨에 개수 없음),
// 그룹 안 순서는 받은 서버 순서(`GET /api/v1/now`)이고 Done today는 최근에 끝낸 것이 위(`WorkItem.list`가 정한 순서 그대로)다. 한 이슈가 여러 프로젝트에 속하면 각 목록에 나온다.
// Done today 목록은 라벨 없는 한 목록이다. 행은 번호가 없고(번호는 상세 머리 · 세션 머리 · 칩) meta 하나(활동 → 기한 → 없음)만 오른쪽에 둔다.
// 보관한 프로젝트는 Projects에 없고 그 이슈는 Ungrouped다. 멤버십을 아직 모르는 이슈는 어느 목록에도 없다 (Ungrouped라고도 말하지 않는다).

/// 이슈 목록이 무엇의 목록인가
public enum IssueListScope: Hashable, Sendable {
    case project(UUID)
    case ungrouped
    case doneToday
}

/// IssueRow 한 줄
public struct IssueRowContent: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let title: String
    public let state: WorkState
    /// 지금 하는 일 (`WorkActivity`와 세션 링의 말). 없으면 nil
    public let activity: String?
    /// 기한 (`DueText.short`). 없으면 nil
    public let due: String?
    /// 기한이 오늘이거나 지났다 (빨강, 앱 표시 규칙 `DueText.isUrgent`). 끝낸 일은 아니다
    public let urgent: Bool
    /// 기한이 지났다 (접근성 이름에 "overdue")
    public let overdue: Bool

    /// 오른쪽 meta 하나: 활동이 먼저, 없으면 기한. 줄이지 않는다
    public var metaText: String? { activity ?? due }
    public var metaIsDue: Bool { activity == nil && due != nil }

    /// "Title — State · Activity, due Day" (기한이 지났으면 ", overdue, due Day"). 화면에 meta 하나만 보여도 읽는 이름은 둘 다 담는다
    public var accessibilityLabel: String {
        var label = "\(title) — \(state.title)"
        if let activity { label += " · \(activity)" }
        if let due { label += overdue ? ", overdue, due \(due)" : ", due \(due)" }
        return label
    }

    public init(id: UUID, title: String, state: WorkState, activity: String?, due: String?, urgent: Bool, overdue: Bool) {
        self.id = id
        self.title = title
        self.state = state
        self.activity = activity
        self.due = due
        self.urgent = urgent
        self.overdue = overdue
    }
}

public struct IssueListGroup: Identifiable, Hashable, Sendable {
    /// "In Progress" · "To Do" · "Done today". Done today 목록은 라벨이 없다
    public let label: String?
    public let rows: [IssueRowContent]

    public var id: String { label ?? "all" }
}

public struct IssueListContent: Hashable, Sendable {
    /// 머리 제목: 프로젝트 이름 · "Ungrouped" · "Done today"
    public let title: String
    public let groups: [IssueListGroup]
    /// 머리 `+`(직접 추가, 런처)가 있나: Done today 목록에는 없다
    public let allowsAdd: Bool
    /// 이 목록의 이슈 전부 (SessionTab이 보는 범위: 그 이슈들의 세션)
    public let issueIDs: [UUID]

    public var isEmpty: Bool { groups.isEmpty }
}

public enum IssueListRules {
    public static let inProgress = "In Progress"
    public static let toDo = "To Do"
    public static let doneToday = "Done today"

    /// 이 범위의 목록. 프로젝트가 없거나 보관됐으면 nil (열어 둔 목록은 Projects로 돌아간다)
    public static func content(
        scope: IssueListScope, items: [WorkItem], contexts: [WorkContext], sessions: [AgentSessionItem], today: LocalDate
    ) -> IssueListContent? {
        func rows(_ items: [WorkItem]) -> [IssueRowContent] { items.map { row($0, sessions: sessions, today: today) } }
        switch scope {
        case .doneToday:
            let done = items.filter { $0.state == .done }
            return IssueListContent(
                title: doneToday, groups: done.isEmpty ? [] : [IssueListGroup(label: nil, rows: rows(done))], allowsAdd: false, issueIDs: done.map(\.id)
            )
        case .project(let id):
            guard let context = contexts.first(where: { $0.id == id }), context.isActive else { return nil }
            return list(title: context.name, members: ProjectListRules.items(of: id, in: items), rows: rows)
        case .ungrouped:
            return list(title: ProjectListRules.ungroupedTitle, members: ProjectListRules.ungroupedItems(in: items), rows: rows)
        }
    }

    private static func list(title: String, members: [WorkItem], rows: ([WorkItem]) -> [IssueRowContent]) -> IssueListContent {
        let groups = [
            (inProgress, members.filter { $0.state == .inProgress }),
            (toDo, members.filter { $0.state == .toDo }),
            (doneToday, members.filter { $0.state == .done }),
        ]
        return IssueListContent(
            title: title, groups: groups.filter { !$0.1.isEmpty }.map { IssueListGroup(label: $0.0, rows: rows($0.1)) }, allowsAdd: true,
            issueIDs: members.map(\.id)
        )
    }

    /// IssueRow: 활동은 v1 run · 확인 요청의 말과 그 이슈 세션들의 링 중 먼저인 것 (needs-you → unreachable → stopping → running), 기한은 `DueText.short`
    static func row(_ item: WorkItem, sessions: [AgentSessionItem], today: LocalDate) -> IssueRowContent {
        let done = item.state == .done
        let due = item.action.dueDate
        return IssueRowContent(
            id: item.id, title: item.action.title, state: item.state, activity: done ? nil : activity(of: item, sessions: sessions),
            due: due.map { DueText.short($0, today: today) },
            urgent: !done && due != nil && DueText.isUrgent(due: due, reasons: item.reasons, today: today),
            overdue: !done && due.map { DueText.isOverdue($0, today: today) } == true
        )
    }

    /// 이 이슈가 지금 하는 일의 말 (없으면 nil)
    static func activity(of item: WorkItem, sessions: [AgentSessionItem]) -> String? {
        ring(of: item, sessions: sessions)?.activityLine
    }

    /// 이 이슈의 활동 링 (끝낸 이슈는 없다)
    static func ring(of item: WorkItem, sessions: [AgentSessionItem]) -> AgentSessionRing? {
        guard item.state != .done else { return nil }
        return AgentSessionRules.issueRing(
            v1: AgentSessionRing(v1Activity: item.activity), sessions: AgentSessionRules.sessions(of: [item.id], in: sessions)
        )
    }
}
