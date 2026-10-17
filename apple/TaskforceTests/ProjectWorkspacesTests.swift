import Foundation
import Testing
import TaskforceKit
@testable import Taskforce

/// 프로젝트마다의 작업 폴더를 앱에 잇는 부분 (OA D4a2, 격리 호스트): 파티션마다의 등록부 · 앱 데이터 폴더 거절 · 이 Mac 확인 · 호스트의 resolver 주입 · 경로 대신 id.
/// 서버는 가짜(`FakeBridgeServer`)이고 폴더는 임시 폴더다. 실제 폴더 창 · 터미널 · `claude` 실행 · 실제 Application Support 쓰기가 0이다
@MainActor
struct ProjectWorkspacesTests {
    static let session = "5e551011-0000-4000-8000-000000000001"

    /// RLS 읽기의 대역: 세션 하나에 이어진 대화 · 이슈 · 프로젝트 멤버
    final class Reads: AgentSessionGateway, ContextGateway, @unchecked Sendable {
        struct Failure: Error {}
        var conversations: [AgentSessionConversationRecord] = []
        var runs: [AgentSessionRunRecord] = []
        var members: [ContextMember] = []

        func agentSessionSnapshot() async throws -> AgentSessionSnapshot { try await agentSessionSnapshot(sessionIDs: [UUID(uuidString: ProjectWorkspacesTests.session)!]) }

        func agentSessionSnapshot(sessionIDs: Set<UUID>) async throws -> AgentSessionSnapshot {
            AgentSessionSnapshot(sessions: [], tasks: [], runs: runs, connections: [], conversations: conversations)
        }

        func workContexts() async throws -> [WorkContext] { [] }
        func contextMembers() async throws -> [ContextMember] { members }
        func changeContextMember(contextID: UUID, op: ContextMemberOp, actionID: UUID, expectedVersion: Int) async throws -> ContextMemberWriteResponse { throw Failure() }
        func moveContextMember(actionID: UUID, from fromContextID: UUID, to toContextID: UUID, expectedToVersion: Int, expectedFromVersion: Int) async throws -> ContextMemberMoveResponse { throw Failure() }
    }

    struct Rig {
        let temp: URL
        let home: String
        let root: URL
        let support: URL
        let reads = Reads()
        let workspaces: ProjectWorkspaces
        let local = HostBox<UUID?>(UUID())
        let connections = HostBox<[UUID: UUID]>([:])

        init() throws {
            temp = FileManager.default.temporaryDirectory.appending(path: "project-workspaces-\(UUID().uuidString)", directoryHint: .isDirectory)
            home = temp.appending(path: "home").path
            support = temp.appending(path: "home/AppData", directoryHint: .isDirectory)
            root = support.appending(path: "dev.taskforcelabs.unittest.taskforce/Bridge/v1", directoryHint: .isDirectory)
            for name in ["Documents/client-a", "Documents/client-b"] {
                try FileManager.default.createDirectory(atPath: home + "/" + name, withIntermediateDirectories: true)
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let home = self.home
            let reads = self.reads
            let local = self.local
            let connections = self.connections
            workspaces = ProjectWorkspaces(
                root: root, home: home, protectedRoots: [support.appending(path: "dev.taskforcelabs.unittest.taskforce"), root],
                rules: { WorkspaceFolderRules(home: home, systemRoots: [], protectedRoots: $0) }, sessions: reads, contexts: reads,
                localBridgeID: { local.value }, connectionBridgeID: { connections.value[$0] }
            )
        }

        func folder(_ name: String) -> String { home + "/Documents/" + name }
        func real(_ name: String) -> String { GateFileSystem.realpath(folder(name)) ?? folder(name) }
        func cleanup() { try? FileManager.default.removeItem(at: temp) }

        /// 파티션 폴더는 원장이 연다 (등록부는 만들지 않는다, 보안 F4): 원장 없이 등록부만 쓰는 시험이 대신 연다
        func openPartition(_ partition: BridgePartition) throws {
            try FileManager.default.createDirectory(at: partition.directory(in: root), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    private func partition(_ id: UUID = UUID()) -> BridgePartition { BridgePartition(apiOrigin: "http://localhost:3000", userID: id) }

    // MARK: 등록부

    @Test func theRegistryLivesInThePartitionFolderAndIsTheSameObjectForOnePartitionOnly() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let one = partition()
        let two = partition()
        try rig.openPartition(one)
        let registry = rig.workspaces.registry(for: one)
        #expect(rig.workspaces.registry(for: one) === registry, "런타임(resolver)과 화면이 같은 등록부를 본다")
        #expect(rig.workspaces.registry(for: two) !== registry)
        #expect(registry.file == one.directory(in: rig.root).appending(path: "workspaces.json"))
        try registry.setFolder(rig.folder("client-a"), forProject: UUID())
        #expect(FileManager.default.fileExists(atPath: registry.file.path))
        #expect(!FileManager.default.fileExists(atPath: rig.workspaces.registry(for: two).file.path), "계정마다 갈린다")
    }

    @Test func theAppDataFoldersAndTheFoldersContainingThemAreRefusedAsWorkFolders() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let registry = rig.workspaces.registry(for: partition())
        let bundle = rig.support.appending(path: "dev.taskforcelabs.unittest.taskforce")
        for refused in [rig.root.path, bundle.path, rig.support.path, rig.root.appending(path: "x").path] {
            try? FileManager.default.createDirectory(atPath: refused, withIntermediateDirectories: true)
            #expect(!registry.accepts(path: refused), "\(refused)")
        }
        #expect(registry.accepts(path: rig.folder("client-a")))
        #expect(throws: WorkspaceRegistry.RegistryError.rejected(.appData)) { try registry.setFolder(bundle.path, forProject: UUID()) }
    }

    // MARK: 이 Mac의 연결인가

    @Test func aConnectionIsThisMacOnlyWhenItsBridgeIsOurs() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let mine = try #require(rig.local.value)
        let ours = UUID()
        let theirs = UUID()
        let unknown = UUID()
        rig.connections.value = [ours: mine, theirs: UUID()]
        #expect(await rig.workspaces.isThisMac(connectionID: ours))
        #expect(await !rig.workspaces.isThisMac(connectionID: theirs), "다른 Mac의 연결")
        #expect(await !rig.workspaces.isThisMac(connectionID: unknown), "읽지 못한 연결 (모르는 것을 같다고 하지 않는다)")
        rig.local.value = nil
        #expect(await !rig.workspaces.isThisMac(connectionID: ours), "이 Mac이 등록 전이면 같다고 하지 않는다")
    }

    // MARK: resolver

    @Test func theResolverFindsTheProjectFolderThroughTheIssueAndMapsItToAnOpaqueID() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let p = partition()
        try rig.openPartition(p)
        let project = UUID()
        let action = UUID()
        let sessionUUID = try #require(UUID(uuidString: Self.session))
        rig.reads.runs = [AgentSessionRunRecord(id: UUID(), agentSessionID: sessionUUID, actionID: action)]
        rig.reads.members = [ContextMember(id: UUID(), contextID: project, actionID: action, origin: .user)]
        try rig.workspaces.registry(for: p).setFolder(rig.folder("client-a"), forProject: project)
        let resolver = rig.workspaces.resolver(for: p)
        #expect(await resolver.workspace(forSession: Self.session, adapter: "agent:claude-code") == rig.real("client-a"))
        let ref = try #require(await resolver.workspaceRef(forPath: rig.real("client-a")))
        #expect(WorkspaceRegistry.isOpaqueRef(ref) && !ref.contains("/"))
        #expect(await resolver.workspacePath(forRef: ref) == rig.real("client-a"))
        #expect(await resolver.authorize(workspaceRef: rig.real("client-a"), session: Self.session, adapter: "agent:claude-code"))
        #expect(!resolver.recognizesRecordedPaths)
    }

    // MARK: 호스트: 런타임에 등록부 resolver가 들어가고 서버에는 id만 간다

    @Test func theHostGivesTheRuntimeTheRegistryResolverAndTheServerOnlySeesTheOpaqueID() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let fixture = HostFixture(workspaces: rig.workspaces)
        defer { fixture.cleanup() }
        let userID = try #require(fixture.user.value)
        let p = BridgePartition(apiBaseURL: fixture.server.baseURL, userID: userID)
        try rig.openPartition(p)
        let registry = rig.workspaces.registry(for: p)
        try registry.pin(session: Self.session, to: rig.folder("client-a"))
        fixture.agent.setScript(FakeAgentProcess.Script([.sessionBound(external: "ext-1", workspace: rig.real("client-a")), .accepted, .turnCompleted, .end(AgentExit(code: 0))]))
        await fixture.start()
        let ticker = fixture.advancingClock()
        defer { ticker.cancel() }
        #expect(fixture.host.activeWorkspaceRegistry === registry)
        let created = try #require(await fixture.message())
        #expect(await fixture.eventually { fixture.agent.startedTurns.count == 1 })
        #expect(fixture.agent.startedTurns.first?.workspaceRef == rig.real("client-a"), "adapter는 경로를 받는다")
        #expect(await fixture.eventually { fixture.server.taskState(created.taskID) == "idle" })
        let wireRef = try #require(fixture.server.sessionState(Self.session)?.workspaceRef)
        let ref = try #require(VirtualWorkspacePaths.ref(fromVirtualRoot: wireRef), "서버에는 가상 루트 `/taskforce/<ws_id>`가 간다: \(wireRef)")
        #expect(WorkspaceRegistry.isOpaqueRef(ref) && registry.path(forRef: ref) == rig.real("client-a"))
        let wire = fixture.server.requests.map(\.bodyJSON).joined(separator: "\n")
        for needle in [rig.home, "client-a", "/private/var", "/Users/"] { #expect(!wire.contains(needle), "서버 본문에 \(needle)가 있다") }
    }

    @Test func aHostWithoutWorkspacesAsksNothingAndAnAccountDeletionTakesTheRegistryAlong() async throws {
        let off = HostFixture()
        defer { off.cleanup() }
        await off.start()
        #expect(off.host.workspaceAsking == nil && off.host.activeWorkspaceRegistry == nil)

        let rig = try Rig()
        defer { rig.cleanup() }
        let fixture = HostFixture(workspaces: rig.workspaces)
        defer { fixture.cleanup() }
        await fixture.start()
        let userID = try #require(fixture.user.value)
        let p = BridgePartition(apiBaseURL: fixture.server.baseURL, userID: userID)
        // 이 호스트의 저장 뿌리는 시험 뿌리와 다르다: 등록부를 호스트 뿌리의 파티션에 만들어 계정 삭제가 지우는지 본다
        try FileManager.default.createDirectory(at: p.directory(in: fixture.root), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let hostRegistry = WorkspaceRegistry(file: p.directory(in: fixture.root).appending(path: WorkspaceRegistry.fileName), rules: WorkspaceFolderRules(home: rig.home, systemRoots: []))
        try hostRegistry.setFolder(rig.folder("client-b"), forProject: UUID())
        #expect(FileManager.default.fileExists(atPath: hostRegistry.file.path))
        #expect(fixture.host.workspaceAsking != nil)
        let result = await fixture.host.accountDeleted(userID: userID)
        #expect(result.folderRemoved)
        #expect(!FileManager.default.fileExists(atPath: hostRegistry.file.path), "계정 삭제가 등록부를 같이 지운다")
    }

    // MARK: Release · Debug 둘 다 등록부 resolver (Debug 덮어쓰기만 R2용)

    @Test func theRegistryResolverIsUsedUnlessDebugOverridesItForR2() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let p = partition()
        let registered: () -> (any WorkspaceResolver)? = { rig.workspaces.resolver(for: p) }
        let local = URL(string: "http://localhost:3000")!
        // 인자가 없으면 (Release는 늘 이 경우다) 등록부 resolver
        let normal = BridgeHost.claudeCodeWorkspaces(disposable: nil, apiBaseURL: local, home: rig.home, registered: registered)
        #expect(normal is RegistryWorkspaceResolver)
        #if DEBUG
        // Debug의 일회용 폴더 인자: 조건을 못 채우면 등록부로 넘어가지 않는다 (resolver 없음)
        let missing = BridgeHost.claudeCodeWorkspaces(disposable: rig.folder("client-a"), apiBaseURL: local, home: rig.home, registered: registered)
        #expect(missing == nil, "표식 파일이 없는 폴더는 R2용으로도 받지 않는다")
        let marked = rig.folder("client-b")
        FileManager.default.createFile(atPath: marked + "/" + DisposableWorkspaces.marker, contents: Data())
        let overridden = BridgeHost.claudeCodeWorkspaces(disposable: marked, apiBaseURL: local, home: rig.home, registered: registered)
        #expect(overridden is DisposableWorkspaces)
        #endif
    }
}
