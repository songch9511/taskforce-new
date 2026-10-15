import Foundation

// OA U2: Issues 패널(레일 첫 칸)의 화면 이동 규칙 (U2-01 · 24). Projects 목록 → 프로젝트 · Ungrouped · Done today 이슈 목록 → 이슈 상세.
// 뒤로 = 머리 `chevron-left`. 이슈 상세의 뒤로는 연 목록으로, 목록 밖(레일 · ⌘1 · 칩)에서 열었으면 그 이슈의 첫 프로젝트(이름순) 목록 또는 Ungrouped로 간다.
// ⌘2는 Projects 첫 화면(쌓인 화면을 비운다).

public enum IssueScreen: Hashable, Sendable {
    case projects
    case list(IssueListScope)
    case detail(UUID)
}

public struct IssueNavigation: Equatable, Sendable {
    /// 맨 아래는 늘 Projects
    public private(set) var stack: [IssueScreen] = [.projects]

    public init() {}

    public var current: IssueScreen { stack.last ?? .projects }
    public var canGoBack: Bool { stack.count > 1 }

    /// 지금 열린 이슈 상세
    public var detailID: UUID? {
        if case .detail(let id) = current { id } else { nil }
    }

    /// SessionTab이 보는 범위: 열린 이슈 상세는 그 이슈, 프로젝트 · Ungrouped 목록은 그 목록. Projects · Done today에는 탭이 없다
    public var tabScope: IssueScreen? {
        switch current {
        case .detail: current
        case .list(.doneToday), .projects: nil
        case .list: current
        }
    }

    /// ⌘2 · 레일 첫 칸: Projects 첫 화면
    public mutating func reset() {
        stack = [.projects]
    }

    /// Projects에서 목록을 연다 (더 깊이 쌓인 것은 비운다)
    public mutating func open(_ scope: IssueListScope) {
        stack = [.projects, .list(scope)]
    }

    /// 목록에서 이슈 상세를 연다 (이미 상세가 열려 있으면 그 자리를 바꾼다). 뒤로는 연 목록
    public mutating func openDetail(_ id: UUID) {
        if case .detail = current { stack.removeLast() }
        stack.append(.detail(id))
    }

    /// 목록 밖(레일 · ⌘1 · 칩)에서 연다: 뒤로는 `fallback` 목록 (`fallbackScope(for:)`)
    public mutating func openDetail(_ id: UUID, outside fallback: IssueListScope) {
        stack = [.projects, .list(fallback), .detail(id)]
    }

    public mutating func back() {
        guard canGoBack else { return }
        stack.removeLast()
    }

    /// 열어 둔 것이 사라졌다: 없는 프로젝트의 목록은 빼고, 없는 이슈의 상세는 그 아래 화면으로 돌아간다 (그 위에 쌓인 것과 함께)
    public mutating func reconcile(listExists: (IssueListScope) -> Bool, issueExists: (UUID) -> Bool) {
        var kept: [IssueScreen] = []
        for screen in stack {
            switch screen {
            case .projects:
                kept.append(screen)
            case .list(let scope):
                if listExists(scope) { kept.append(screen) }
            case .detail(let id):
                guard issueExists(id) else {
                    stack = kept
                    return
                }
                kept.append(screen)
            }
        }
        stack = kept
    }

    /// 목록 밖에서 이슈를 열 때의 뒤로 갈 목록: 그 이슈의 첫 프로젝트(이름순, 대소문자 무시, 보관한 프로젝트는 뺀다), 없으면 Ungrouped
    public static func fallbackScope(for item: WorkItem) -> IssueListScope {
        let live = item.memberships.links.map(\.project).filter { !$0.isArchived }
        let first = live.min { ($0.name.lowercased(), $0.id.uuidString) < ($1.name.lowercased(), $1.id.uuidString) }
        return first.map { .project($0.id) } ?? .ungrouped
    }
}
