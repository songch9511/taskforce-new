import Foundation

// 0.2.0 All work의 실제 범위(프로젝트) 멤버십 (S3b). 묶음 · Project 칩 · 검색 · ProjectLink가 같은 사실을 본다:
// 서버 `work_contexts` · `context_members`를 RLS로 읽은 것뿐이다. 표시 문자열 · `actions.project` · 이름 일치 · 견본으로 짐작하지 않는다.
// - 확인된 멤버 = 지금 멤버(`removed_at` 없음)이고 origin이 user · auto. 한 할 일이 여러 범위의 멤버일 수 있고, 하나로 합치지 않는다
// - inferred(모델 후보)는 확인된 멤버처럼 묶지 않는다: 후보로 따로 보인다 (사용자 선택처럼 꾸미지 않는다)
// - 멤버십이 없는 할 일 = Ungrouped. 멤버십을 아직 읽지 못했으면 Ungrouped라고도 말하지 않는다 (`WorkMemberships.unknown`)

/// 실제 범위 하나 (`work_contexts` 행). 보관된 범위는 읽기 전용이다
public struct WorkProject: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let name: String
    public let isArchived: Bool

    public init(id: UUID, name: String, isArchived: Bool = false) {
        self.id = id
        self.name = name
        self.isArchived = isArchived
    }

    public static let archivedSuffix = " · Archived"

    /// 묶음 이름 · 칩 글자: 보관된 범위는 그렇게 적는다
    public var title: String { isArchived ? name + Self.archivedSuffix : name }
}

/// 이 할 일이 이 범위의 **확인된** 멤버다. `origin`: user(Set by you) · auto(Auto-linked)
public struct WorkLink: Sendable, Hashable, Identifiable {
    public let project: WorkProject
    public let origin: ContextMemberOrigin

    public var id: UUID { project.id }

    public init(project: WorkProject, origin: ContextMemberOrigin) {
        self.project = project
        self.origin = origin
    }
}

/// 이 범위가 이 할 일의 **확인되지 않은 후보**다 (inferred). 묶음에 들이지 않는다
public struct WorkCandidate: Sendable, Hashable, Identifiable {
    public let project: WorkProject
    public let confidence: Double?

    public var id: UUID { project.id }

    public init(project: WorkProject, confidence: Double?) {
        self.project = project
        self.confidence = confidence
    }
}

/// 한 할 일의 멤버십. `unknown`: 아직 읽지 못했다 (읽는 중 · 오프라인 · 실패): 묶음 주장이 없다
public enum WorkMemberships: Sendable, Hashable {
    case unknown
    case known(links: [WorkLink], candidates: [WorkCandidate])

    /// 읽었고 확인된 멤버십도 후보도 없다
    public static let none = WorkMemberships.known(links: [], candidates: [])

    public var isKnown: Bool {
        if case .known = self { true } else { false }
    }

    public var links: [WorkLink] {
        if case .known(let links, _) = self { links } else { [] }
    }

    public var candidates: [WorkCandidate] {
        if case .known(_, let candidates) = self { candidates } else { [] }
    }

    /// 읽었고 확인된 멤버십이 없다 (후보만 있어도 Ungrouped)
    public var isUngrouped: Bool {
        if case .known(let links, _) = self { links.isEmpty } else { false }
    }
}

/// 읽은 범위 · 멤버에서 만든 색인 (순수 규칙)
public struct WorkMembershipIndex: Equatable, Sendable {
    private let isKnown: Bool
    private let links: [UUID: [WorkLink]]
    private let candidates: [UUID: [WorkCandidate]]

    /// 아직 읽지 못했다: 어떤 할 일도 묶지 않는다
    public static let unknown = WorkMembershipIndex(isKnown: false, links: [:], candidates: [:])
    /// 읽었고 멤버십이 없다 (서버에 범위 기능이 없을 때도 같다)
    public static let empty = WorkMembershipIndex(isKnown: true, links: [:], candidates: [:])

    private init(isKnown: Bool, links: [UUID: [WorkLink]], candidates: [UUID: [WorkCandidate]]) {
        self.isKnown = isKnown
        self.links = links
        self.candidates = candidates
    }

    /// - 범위를 읽지 못한 멤버(지워졌거나 읽는 사이 사라진 범위)는 묶지 않는다
    /// - 보관된 범위의 확인된 멤버는 묶는다 (읽기 전용으로 표시). 보관된 범위의 후보는 보이지 않는다
    /// - 같은 (할 일, 범위)가 겹쳐 오면 확인된 멤버가 후보보다 앞선다
    public init(contexts: [WorkContext], members: [ContextMember]) {
        let byID = Dictionary(contexts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var links: [UUID: [WorkLink]] = [:]
        var candidates: [UUID: [WorkCandidate]] = [:]
        for member in members where !member.isRemoved {
            guard let actionID = member.actionID, let context = byID[member.contextID] else { continue }
            let project = WorkProject(id: context.id, name: context.name, isArchived: context.status == .archived)
            if member.origin.isConfirmed {
                guard !(links[actionID] ?? []).contains(where: { $0.id == project.id }) else { continue }
                links[actionID, default: []].append(WorkLink(project: project, origin: member.origin))
            } else if !project.isArchived {
                guard !(candidates[actionID] ?? []).contains(where: { $0.id == project.id }) else { continue }
                candidates[actionID, default: []].append(WorkCandidate(project: project, confidence: member.confidence))
            }
        }
        func order(_ a: WorkProject, _ b: WorkProject) -> Bool { (a.name, a.id.uuidString) < (b.name, b.id.uuidString) }
        self.init(
            isKnown: true,
            links: links.mapValues { $0.sorted { order($0.project, $1.project) } },
            candidates: candidates.mapValues { $0.sorted { order($0.project, $1.project) } }
        )
    }

    public func memberships(of actionID: UUID) -> WorkMemberships {
        guard isKnown else { return .unknown }
        let confirmed = links[actionID] ?? []
        let ids = Set(confirmed.map(\.id))
        return .known(links: confirmed, candidates: (candidates[actionID] ?? []).filter { !ids.contains($0.id) })
    }
}
