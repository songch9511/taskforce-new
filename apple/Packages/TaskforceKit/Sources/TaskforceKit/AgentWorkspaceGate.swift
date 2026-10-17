import Foundation

// 처음 한 번 묻기 (OA D4a2-05, 사용자 결정 11.1 "작업 폴더 = 프로젝트마다"): 에이전트 대화의 **첫 보내기 직전에** 작업 폴더를 묻는다.
// 세션은 첫 보내기에서 생긴다 — 그래서 "처음 세션을 열 때 한 번"이 이 자리다. 같은 프로젝트의 다음 세션은 묻지 않는다. Ungrouped는 그때마다 묻는다.
//
// 묻는 조건 (모두 참일 때만):
// 1. 대화에 세션이 아직 없다
// 2. 대상이 에이전트이고, 그 연결이 **이 Mac**이다 (다른 Mac이면 묻지 않는다: 그 Mac이 정한다)
// 3. 보내는 글이 속한 프로젝트에 폴더가 없다 (프로젝트를 모르는 Ungrouped면, 이 대화가 보내기 전에 고른 폴더가 없다)
// 고르면 등록하고 보낸다. 취소하면 보내지 않고 글은 입력 칸에 그대로 둔다. 순수 규칙(`AgentWorkspaceGate`)과 순서를 지키는 일(`AgentWorkspaceSendGate`)만 여기 있다 —
// 시스템 폴더 창은 앱이 `AgentWorkspacePicking`으로 넣는다 (시험은 가짜 패널).
//
// "보내는 글이 속한 프로젝트"는 서버가 세션을 이슈에 잇는 규칙(`start_agent_turn`)을 따른다: 이슈 칩(added)이 하나면 그 이슈의 프로젝트, 이슈 칩이 없고 프로젝트 칩(added)이 하나면 그 프로젝트
// (서버가 새 이슈를 그 프로젝트에 넣는다). 이슈 칩이 여럿이면 후보 고르기(needs_referent)가 뒤따르므로 프로젝트를 모른다 → Ungrouped처럼 묻는다.

/// 승인된 문구 (2026-10-18, 사용자 결정): 폴더 창 메시지 · 버튼 · 거절 문구
public enum AgentWorkspaceCopy {
    public static func chooseFolder(forProject name: String) -> String { "Choose a folder for \(name)" }
    /// Ungrouped
    public static let chooseFolderForSession = "Choose a folder for this session"
    public static let choose = "Choose"
    /// 고른 폴더가 거절일 때 폴더 창 안에 보이는 검증 문구
    public static let rejected = "Choose a folder inside your home folder or on an external drive."
}

public enum AgentWorkspaceGate {
    public struct Project: Equatable, Sendable {
        public let id: UUID
        public let name: String

        public init(id: UUID, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// 물을 폴더가 어디에 적히나
    public enum Scope: Equatable, Sendable {
        /// 그 프로젝트의 폴더 (다음 세션부터는 묻지 않는다)
        case project(UUID)
        /// 이 대화의 폴더 (Ungrouped: 대화마다)
        case conversation(UUID)
    }

    public struct Ask: Equatable, Sendable {
        public let scope: Scope
        /// 폴더 창 메시지
        public let message: String
        /// 폴더 창 버튼
        public let prompt: String

        public init(scope: Scope, message: String, prompt: String = AgentWorkspaceCopy.choose) {
            self.scope = scope
            self.message = message
            self.prompt = prompt
        }
    }

    public enum Decision: Equatable, Sendable {
        case send
        case ask(Ask)
    }

    /// 보내기 직전의 사실
    public struct Facts: Sendable {
        public var conversationID: UUID
        public var conversationHasSession: Bool
        public var targetIsAgent: Bool
        /// 대상 연결이 이 Mac이다 (확인된 것만 true)
        public var targetIsThisMac: Bool
        /// 보내는 글이 속한 프로젝트 (이름 순, 없으면 Ungrouped)
        public var projects: [Project]
        /// 위 프로젝트 중 폴더가 있는 것 (규칙을 지금도 통과하는 폴더)
        public var projectsWithFolder: Set<UUID>
        /// 이 대화가 보내기 전에 고른 폴더가 있다 (규칙을 지금도 통과한다)
        public var conversationHasFolder: Bool

        public init(
            conversationID: UUID, conversationHasSession: Bool, targetIsAgent: Bool, targetIsThisMac: Bool, projects: [Project], projectsWithFolder: Set<UUID>,
            conversationHasFolder: Bool
        ) {
            self.conversationID = conversationID
            self.conversationHasSession = conversationHasSession
            self.targetIsAgent = targetIsAgent
            self.targetIsThisMac = targetIsThisMac
            self.projects = projects
            self.projectsWithFolder = projectsWithFolder
            self.conversationHasFolder = conversationHasFolder
        }
    }

    public static func decide(_ facts: Facts) -> Decision {
        guard facts.targetIsAgent, !facts.conversationHasSession, facts.targetIsThisMac else { return .send }
        if let first = facts.projects.first {
            // 프로젝트가 여럿이면 하나라도 폴더가 있으면 묻지 않는다 (resolver가 폴더가 있는 프로젝트를 쓴다). 없으면 이름 순 첫 프로젝트의 폴더를 묻는다
            if facts.projects.contains(where: { facts.projectsWithFolder.contains($0.id) }) { return .send }
            return .ask(Ask(scope: .project(first.id), message: AgentWorkspaceCopy.chooseFolder(forProject: first.name)))
        }
        if facts.conversationHasFolder { return .send }
        return .ask(Ask(scope: .conversation(facts.conversationID), message: AgentWorkspaceCopy.chooseFolderForSession))
    }

    /// 보내는 글의 칩에서 프로젝트를 정한다 (위 규칙). 멤버십을 아직 읽지 못했으면(`unknown`) 프로젝트를 모른다 → 비어 있다 (Ungrouped처럼 묻는다)
    public static func projects(chips: [AssistantChip], index: WorkMembershipIndex?) -> [Project] {
        let added = chips.filter { $0.origin == .added }
        let issues = added.filter { if case .action = $0.kind { true } else { false } }
        if issues.count == 1, let index {
            let links = index.memberships(of: issues[0].itemID).links
            return links.map { Project(id: $0.project.id, name: $0.project.name) }
        }
        guard issues.isEmpty else { return [] }
        let contexts = added.filter { if case .context = $0.kind { true } else { false } }
        guard contexts.count == 1 else { return [] }
        return [Project(id: contexts[0].itemID, name: contexts[0].title)]
    }
}

/// 이 Mac의 폴더 등록부가 보이는 면 (실제는 `WorkspaceRegistry`)
public protocol AgentWorkspaceFolders: Sendable {
    /// 그 프로젝트에 연결된, 지금도 받아 줄 폴더가 있나
    func hasFolder(forProject id: UUID) -> Bool
    /// 이 대화가 보내기 전에 고른, 지금도 받아 줄 폴더가 있나
    func hasFolder(forConversation id: UUID) -> Bool
    /// 폴더 창 안 검증: 받아 줄 폴더인가 (거절 규칙은 `WorkspaceFolderRules`)
    func accepts(path: String) -> Bool
    /// 등록한다. 규칙을 통과하지 못하면 던진다
    func register(path: String, scope: AgentWorkspaceGate.Scope) throws
}

/// 시스템 폴더 창 (앱은 `NSOpenPanel`, 폴더만 · 한 개). 거절되는 폴더를 고르면 창 안에서 `rejection` 문구를 보이고 창을 닫지 않는다. 취소하면 nil
@MainActor
public protocol AgentWorkspacePicking {
    func pickFolder(message: String, prompt: String, rejection: String, accepts: @escaping @Sendable (String) -> Bool) async -> String?
}

/// 보내기 전에 묻는 순서 (D4a2-05). 보내기 입구가 `prepare`를 먼저 부르고 `.proceed`일 때만 보낸다
@MainActor
public final class AgentWorkspaceSendGate {
    public enum Outcome: Equatable, Sendable {
        /// 보내도 된다 (묻지 않았거나, 골라서 등록했다)
        case proceed
        /// 보내지 않는다 (취소했거나, 이미 묻는 중이다). 글은 입력 칸에 그대로 둔다
        case cancelled
    }

    private let folders: any AgentWorkspaceFolders
    private let picker: any AgentWorkspacePicking
    private let isThisMac: @Sendable (UUID) async -> Bool
    private var asking = false

    /// - isThisMac: 연결이 이 Mac의 것인가 (서버를 읽는다). 묻게 될 때만 부른다
    public init(folders: any AgentWorkspaceFolders, picker: any AgentWorkspacePicking, isThisMac: @escaping @Sendable (UUID) async -> Bool) {
        self.folders = folders
        self.picker = picker
        self.isThisMac = isThisMac
    }

    /// - Parameters:
    ///   - target: 이 대화의 대상. 연결 없이 고른 에이전트는 이 Mac의 것이 아니다
    ///   - projects: 보내는 글이 속한 프로젝트 (`AgentWorkspaceGate.projects`)
    public func prepare(conversationID: UUID, hasSession: Bool, target: AssistantTargetPick, projects: [AgentWorkspaceGate.Project]) async -> Outcome {
        let withFolder = Set(projects.filter { folders.hasFolder(forProject: $0.id) }.map(\.id))
        var facts = AgentWorkspaceGate.Facts(
            conversationID: conversationID, conversationHasSession: hasSession, targetIsAgent: target.isAgent, targetIsThisMac: true, projects: projects,
            projectsWithFolder: withFolder, conversationHasFolder: folders.hasFolder(forConversation: conversationID)
        )
        // 묻지 않을 일이면 서버를 읽지 않는다. 묻게 될 때만 이 Mac의 연결인지 확인한다
        guard case .ask(let ask) = AgentWorkspaceGate.decide(facts) else { return .proceed }
        guard let connection = Self.connectionID(of: target) else { return .proceed }
        if asking { return .cancelled }
        asking = true
        facts.targetIsThisMac = await isThisMac(connection)
        let outcome = await askAndRegister(facts: facts, ask: ask)
        asking = false
        return outcome
    }

    private func askAndRegister(facts: AgentWorkspaceGate.Facts, ask: AgentWorkspaceGate.Ask) async -> Outcome {
        // 다른 Mac의 연결이면 묻지 않는다 (그 Mac이 정한다)
        guard AgentWorkspaceGate.decide(facts) != .send else { return .proceed }
        let registry = folders
        let accepts: @Sendable (String) -> Bool = { registry.accepts(path: $0) }
        guard let path = await picker.pickFolder(message: ask.message, prompt: ask.prompt, rejection: AgentWorkspaceCopy.rejected, accepts: accepts) else { return .cancelled }
        do {
            try folders.register(path: path, scope: ask.scope)
        } catch {
            return .cancelled
        }
        return .proceed
    }

    private static func connectionID(of target: AssistantTargetPick) -> UUID? {
        switch target {
        case .taskforce: nil
        case .agent(_, let connectionID): connectionID
        }
    }
}
