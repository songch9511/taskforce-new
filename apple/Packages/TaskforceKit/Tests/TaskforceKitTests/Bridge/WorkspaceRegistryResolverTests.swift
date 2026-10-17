#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 세션 → 작업 폴더 찾기 순서와 `authorize` (OA D4a2-02 · 04, 계약 13.6 "찾기 순서")
struct WorkspaceRegistryResolverTests {
    static let sessionID = "5e551011-0000-4000-8000-000000000001"
    static var session: UUID { UUID(uuidString: sessionID)! }

    /// RLS 읽기의 대역: 세션 하나의 대화 · run, 프로젝트 멤버. 읽은 횟수를 센다
    final class Reads: AgentSessionGateway, ContextGateway, @unchecked Sendable {
        struct Failure: Error {}
        let lock = NSLock()
        var conversations: [AgentSessionConversationRecord] = []
        var runs: [AgentSessionRunRecord] = []
        var members: [ContextMember] = []
        var failSessionRead = false
        var failContextRead = false
        private(set) var sessionReads = 0
        private(set) var contextReads = 0

        func agentSessionSnapshot() async throws -> AgentSessionSnapshot { try await agentSessionSnapshot(sessionIDs: [WorkspaceRegistryResolverTests.session]) }

        func agentSessionSnapshot(sessionIDs: Set<UUID>) async throws -> AgentSessionSnapshot {
            try lock.withLock {
                sessionReads += 1
                if failSessionRead { throw Failure() }
                return AgentSessionSnapshot(
                    sessions: [], tasks: [], runs: runs.filter { $0.agentSessionID.map(sessionIDs.contains) ?? false }, connections: [],
                    conversations: conversations.filter { sessionIDs.contains($0.agentSessionID) }
                )
            }
        }

        func workContexts() async throws -> [WorkContext] { [] }

        func contextMembers() async throws -> [ContextMember] {
            try lock.withLock {
                contextReads += 1
                if failContextRead { throw Failure() }
                return members
            }
        }

        func changeContextMember(contextID: UUID, op: ContextMemberOp, actionID: UUID, expectedVersion: Int) async throws -> ContextMemberWriteResponse { throw Failure() }
        func moveContextMember(actionID: UUID, from fromContextID: UUID, to toContextID: UUID, expectedToVersion: Int, expectedFromVersion: Int) async throws -> ContextMemberMoveResponse { throw Failure() }
    }

    struct Fixture {
        let fixture: WorkspaceRegistryTests.Fixture
        let registry: WorkspaceRegistry
        let reads = Reads()
        let resolver: RegistryWorkspaceResolver

        init() throws {
            fixture = try WorkspaceRegistryTests.Fixture()
            registry = fixture.registry()
            resolver = RegistryWorkspaceResolver(registry: registry, sessions: reads, contexts: reads)
        }

        func link(action: UUID = UUID(), project: UUID, origin: ContextMemberOrigin = .user, removed: Bool = false, conversation: UUID? = nil) {
            reads.runs.append(AgentSessionRunRecord(id: UUID(), agentSessionID: WorkspaceRegistryResolverTests.session, actionID: action))
            reads.members.append(ContextMember(id: UUID(), contextID: project, actionID: action, origin: origin, isRemoved: removed))
            if let conversation { reads.conversations.append(AgentSessionConversationRecord(id: conversation, agentSessionID: WorkspaceRegistryResolverTests.session)) }
        }

        func found() async -> String? { await resolver.workspace(forSession: WorkspaceRegistryResolverTests.sessionID, adapter: "agent:claude-code") }
    }

    @Test func aSessionPinWinsOverEverythingAndReadsNothing() async throws {
        let f = try Fixture()
        let project = UUID()
        f.link(project: project, conversation: UUID())
        try f.registry.setFolder(f.fixture.folder("b"), forProject: project)
        try f.registry.pin(session: Self.sessionID, to: f.fixture.folder("a"))
        #expect(await f.found() == f.fixture.real("a"))
        #expect(f.reads.sessionReads == 0 && f.reads.contextReads == 0, "핀이 있으면 서버를 읽지 않는다")
    }

    @Test func theConversationFolderIsUsedBeforeTheProjectFolderAndPinsTheSession() async throws {
        let f = try Fixture()
        let project = UUID()
        let conversation = UUID()
        f.link(project: project, conversation: conversation)
        try f.registry.setFolder(f.fixture.folder("b"), forProject: project)
        try f.registry.setPending(f.fixture.folder("c"), conversation: conversation)
        #expect(await f.found() == f.fixture.real("c"))
        #expect(f.registry.pinned(session: Self.sessionID) == f.fixture.real("c"), "찾으면 세션에 핀을 꽂는다")
        #expect(f.reads.contextReads == 0, "대화 핀에서 찾았으면 프로젝트는 읽지 않는다")
    }

    @Test func theProjectFolderIsFoundThroughTheIssueTheSessionRunsOn() async throws {
        let f = try Fixture()
        let project = UUID()
        f.link(project: project)
        try f.registry.setFolder(f.fixture.folder("b"), forProject: project)
        #expect(await f.found() == f.fixture.real("b"))
        #expect(f.registry.pinned(session: Self.sessionID) == f.fixture.real("b"))
    }

    @Test func aSessionOfAProjectWithoutAFolderAndWithoutAnyLinkFindsNothing() async throws {
        let f = try Fixture()
        // 폴더 없는 프로젝트
        let project = UUID()
        f.link(project: project)
        #expect(await f.found() == nil)
        #expect(f.registry.pinned(session: Self.sessionID) == nil, "찾지 못하면 핀도 없다")
        // 연결 자체가 없는 세션
        let empty = try Fixture()
        try empty.registry.setFolder(empty.fixture.folder("a"), forProject: UUID())
        #expect(await empty.found() == nil, "아무 프로젝트의 폴더나 짐작해 쓰지 않는다")
    }

    @Test func aPinnedSessionKeepsItsFolderAfterTheIssueMovedToAnotherProject() async throws {
        let f = try Fixture()
        let first = UUID()
        let second = UUID()
        let action = UUID()
        f.link(action: action, project: first)
        try f.registry.setFolder(f.fixture.folder("a"), forProject: first)
        try f.registry.setFolder(f.fixture.folder("b"), forProject: second)
        #expect(await f.found() == f.fixture.real("a"))
        // 이슈가 다른 프로젝트로 옮겨졌다
        f.reads.members = [ContextMember(id: UUID(), contextID: second, actionID: action, origin: .user)]
        #expect(await f.found() == f.fixture.real("a"), "세션은 핀 폴더를 그대로 쓴다 (맥락 유지)")
    }

    @Test func aModelGuessedMembershipAndARemovedMembershipAreIgnored() async throws {
        let f = try Fixture()
        let guessed = UUID()
        let removed = UUID()
        f.link(project: guessed, origin: .other("inferred"))
        f.link(project: removed, removed: true)
        try f.registry.setFolder(f.fixture.folder("a"), forProject: guessed)
        try f.registry.setFolder(f.fixture.folder("b"), forProject: removed)
        #expect(await f.found() == nil)
        // inferred를 기본값으로도 확인
        let g = try Fixture()
        let project = UUID()
        g.link(project: project, origin: .inferred)
        try g.registry.setFolder(g.fixture.folder("a"), forProject: project)
        #expect(await g.found() == nil)
    }

    @Test func anAutoMembershipCounts() async throws {
        let f = try Fixture()
        let project = UUID()
        f.link(project: project, origin: .auto)
        try f.registry.setFolder(f.fixture.folder("a"), forProject: project)
        #expect(await f.found() == f.fixture.real("a"))
    }

    @Test func whenTheIssueBelongsToSeveralProjectsTheOneWithAFolderIsUsed() async throws {
        let f = try Fixture()
        let withoutFolder = UUID()
        let withFolder = UUID()
        let action = UUID()
        f.link(action: action, project: withoutFolder)
        f.reads.members.append(ContextMember(id: UUID(), contextID: withFolder, actionID: action, origin: .auto))
        try f.registry.setFolder(f.fixture.folder("c"), forProject: withFolder)
        #expect(await f.found() == f.fixture.real("c"))
    }

    @Test func aFailedReadFindsNothingAndGuessesNothing() async throws {
        let f = try Fixture()
        let project = UUID()
        f.link(project: project)
        try f.registry.setFolder(f.fixture.folder("a"), forProject: project)
        f.reads.failSessionRead = true
        #expect(await f.found() == nil)
        f.reads.failSessionRead = false
        f.reads.failContextRead = true
        #expect(await f.found() == nil)
        #expect(f.registry.pinned(session: Self.sessionID) == nil, "읽기 실패로 핀이 꽂히지 않는다")
        f.reads.failContextRead = false
        #expect(await f.found() == f.fixture.real("a"), "읽기가 돌아오면 찾는다")
    }

    @Test func aPinnedFolderThatNoLongerPassesTheRulesIsNotReplacedByAnotherFolder() async throws {
        let f = try Fixture()
        let project = UUID()
        f.link(project: project)
        try f.registry.setFolder(f.fixture.folder("b"), forProject: project)
        try f.registry.pin(session: Self.sessionID, to: f.fixture.folder("a"))
        try FileManager.default.removeItem(atPath: f.fixture.folder("a"))
        #expect(await f.found() == nil, "핀 폴더가 사라졌으면 다른 폴더로 넘어가지 않고 시작하지 않는다")
    }

    // MARK: authorize

    @Test func authorizeApprovesOnlyTheFolderPinnedToThatSession() async throws {
        let f = try Fixture()
        try f.registry.pin(session: Self.sessionID, to: f.fixture.folder("a"))
        try f.registry.setFolder(f.fixture.folder("b"), forProject: UUID())
        let other = "5e551011-0000-4000-8000-0000000000b2"
        try f.registry.pin(session: other, to: f.fixture.folder("c"))
        func ask(_ path: String, session: String = Self.sessionID) async -> Bool {
            await f.resolver.authorize(workspaceRef: path, session: session, adapter: "agent:claude-code")
        }
        #expect(await ask(f.fixture.real("a")))
        #expect(await ask(f.fixture.folder("a")), "같은 폴더면 표기가 달라도 realpath로 같다")
        #expect(await !ask(f.fixture.real("b")), "등록부에 있어도 이 세션의 폴더가 아니면 거절")
        #expect(await !ask(f.fixture.real("c")), "다른 세션의 폴더는 옮겨 가지 않는다")
        #expect(await !ask(f.fixture.real("a"), session: other))
        #expect(await !ask("/Users/someone/.ssh"))
        #expect(await !ask(f.fixture.real("a"), session: "5e551011-0000-4000-8000-0000000000b3"), "핀이 없는 세션")
    }

    @Test func authorizeSeesTheRulesAgainAtUseTime() async throws {
        let f = try Fixture()
        try f.registry.pin(session: Self.sessionID, to: f.fixture.folder("a"))
        #expect(await f.resolver.authorize(workspaceRef: f.fixture.folder("a"), session: Self.sessionID, adapter: "agent:claude-code"))
        // 등록한 뒤에 폴더가 홈 밖(규칙 밖)을 가리키는 기호 링크로 바뀌었다
        let outside = f.fixture.temp.appending("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.removeItem(atPath: f.fixture.folder("a"))
        try FileManager.default.createSymbolicLink(atPath: f.fixture.folder("a"), withDestinationPath: outside.path)
        #expect(await !f.resolver.authorize(workspaceRef: f.fixture.folder("a"), session: Self.sessionID, adapter: "agent:claude-code"))
        #expect(await f.found() == nil)
    }

    @Test func theResolverClosesTheRecordedPathFallbackAndMapsPathsToOpaqueIDs() async throws {
        let f = try Fixture()
        #expect(!f.resolver.recognizesRecordedPaths)
        #expect(await f.resolver.workspaceRef(forPath: f.fixture.real("a")) == nil, "등록하지 않은 폴더에는 id가 없다")
        try f.registry.pin(session: Self.sessionID, to: f.fixture.folder("a"))
        let ref = try #require(await f.resolver.workspaceRef(forPath: f.fixture.real("a")))
        #expect(await f.resolver.workspacePath(forRef: ref) == f.fixture.real("a"))
        #expect(await f.resolver.workspacePath(forRef: "ws_3f1c2c52-1111-4222-8333-444455556666") == nil)
    }
}
#endif
