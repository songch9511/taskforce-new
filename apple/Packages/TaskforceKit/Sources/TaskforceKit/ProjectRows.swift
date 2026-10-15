import Foundation

// OA U2: Issues 첫 화면(Projects 목록, M1)의 규칙 (화면 없는 순수 함수). 활성 프로젝트(이름순, 대소문자 무시 · 같으면 id) → Ungrouped → Done today.
// 보관한 프로젝트는 목록에 없고 그 이슈는 Ungrouped다. 빈 Ungrouped · Done today 행은 그리지 않는다 (빈 프로젝트는 행이다).
// 행의 meta는 "가장 행동할 한 줄"이고 개수를 쓰지 않는다 (DS ProjectRow). " · " 뒤 진행 세부 글("Editing pricing.mdx")은 서버에 원천이 없어 쓰지 않는다.

public enum ProjectRowKind: Hashable, Sendable {
    case project(UUID)
    case ungrouped
    case doneToday
}

/// ProjectRow 한 줄
public struct ProjectRowContent: Identifiable, Hashable, Sendable {
    public let kind: ProjectRowKind
    public let name: String
    /// 프로젝트의 아이콘. Ungrouped · Done today는 없다 (행 종류가 고정된 조용한 아이콘을 정한다)
    public let icon: ProjectIconName?
    /// 한 줄. 줄 것이 없으면 ""
    public let meta: String

    public var id: String {
        switch kind {
        case .project(let id): "project:\(id.uuidString)"
        case .ungrouped: "ungrouped"
        case .doneToday: "done-today"
        }
    }

    /// 접근성 이름 "{name} — {meta}" (meta가 없으면 이름만)
    public var accessibilityName: String { meta.isEmpty ? name : "\(name) — \(meta)" }

    public init(kind: ProjectRowKind, name: String, icon: ProjectIconName?, meta: String) {
        self.kind = kind
        self.name = name
        self.icon = icon
        self.meta = meta
    }
}

public enum ProjectListRules {
    public static let ungroupedTitle = "Ungrouped"
    public static let doneTodayTitle = "Done today"

    /// 프로젝트 목록의 행. 멤버십을 아직 모르는 이슈는 어느 행에도 없다
    public static func rows(items: [WorkItem], contexts: [WorkContext], sessions: [AgentSessionItem], today: LocalDate) -> [ProjectRowContent] {
        let projects = contexts.filter(\.isActive).sorted { (lower($0.name), $0.id.uuidString) < (lower($1.name), $1.id.uuidString) }
        var rows = projects.map { context in
            ProjectRowContent(
                kind: .project(context.id), name: context.name, icon: context.icon,
                meta: meta(members: Self.items(of: context.id, in: items), sessions: sessions, today: today)
            )
        }
        let ungrouped = ungroupedItems(in: items)
        if !ungrouped.isEmpty {
            rows.append(ProjectRowContent(kind: .ungrouped, name: ungroupedTitle, icon: nil, meta: meta(members: ungrouped, sessions: sessions, today: today)))
        }
        if let latest = items.first(where: { $0.state == .done }) {
            rows.append(ProjectRowContent(kind: .doneToday, name: doneTodayTitle, icon: nil, meta: latest.action.title))
        }
        return rows
    }

    /// 이 프로젝트의 이슈 (확인된 멤버, 서버 순서). 끝낸 이슈도 들어 있다
    static func items(of project: UUID, in items: [WorkItem]) -> [WorkItem] {
        items.filter { item in item.memberships.links.contains { $0.project.id == project } }
    }

    /// Ungrouped의 이슈 (끝낸 이슈도): 멤버십을 알고, 활성 프로젝트에 확인된 멤버가 아니다 (보관한 프로젝트만 있는 이슈 포함)
    static func ungroupedItems(in items: [WorkItem]) -> [WorkItem] {
        items.filter { $0.memberships.isKnown && $0.memberships.links.allSatisfy(\.project.isArchived) }
    }

    /// 가장 행동할 한 줄. 서버 순서의 첫 이슈를 단계마다 고른다:
    /// 답을 기다림 → 에이전트가 하는 것(세션 running · stopping · unreachable) → (누구를 기다림: 데이터 없음, 건너뜀) → 기한 → 오늘 끝낸 것 → 첫 열린 이슈 → 빈 줄
    static func meta(members: [WorkItem], sessions: [AgentSessionItem], today: LocalDate) -> String {
        let open = members.filter { $0.state != .done }
        let done = members.filter { $0.state == .done }
        if let item = open.first(where: { IssueListRules.ring(of: $0, sessions: sessions) == .needsYou }) {
            return "Needs your answer · \(item.action.title)"
        }
        for item in open {
            let active = AgentSessionRules.sessions(of: [item.id], in: sessions).first { [.running, .stopping, .unreachable].contains($0.ring) }
            if let active { return "\(active.agentName) · \(item.action.title)" }
        }
        if let item = open.first(where: { $0.action.dueDate != nil }), let due = item.action.dueDate {
            return "Due \(DueText.short(due, today: today)) · \(item.action.title)"
        }
        if let item = done.first { return "Done today · \(item.action.title)" }
        return open.first?.action.title ?? ""
    }

    private static func lower(_ name: String) -> String { name.lowercased() }
}
