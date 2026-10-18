#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 겹치는 작업 폴더: 상태 없는 두 규칙 (계약 13.13, Astra 재검토 1–4 이후). 핀 수명 관리는 없다 — 세션 핀은 세션의 폴더 기록일 뿐이다.
/// ① 등록(고르기 · 바꾸기)은 같은 계정 파티션의 **다른 프로젝트의 지금 폴더**하고만 겹침을 본다 (세션 핀 · 대화 폴더는 보지 않고, 같은 실제 경로는 허용 = 같은 `ws_id`).
/// ② 턴 시작은 세션 핀이 그 폴더이고 어떤 프로젝트의 지금 폴더와도 겹치지 않을 때만 (아니면 접수 전 실패 "Session didn't start", 새 문구 없음). 임시 폴더 · 가짜 서버 · 가짜 agent만 쓴다
struct WorkspaceOverlapRuleTests {
    private let overlapping = WorkspaceRegistry.RegistryError.rejected(.overlapsRegisteredFolder)
    private let sessionA = "5e551011-0000-4000-8000-0000000000a1"
    private let sessionB = "5e551011-0000-4000-8000-0000000000b1"

    private func nested(_ fixture: WorkspaceRegistryTests.Fixture) throws {
        try FileManager.default.createDirectory(atPath: fixture.folder("a") + "/sub/deep", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: fixture.folder("a-other"), withIntermediateDirectories: true)
    }

    // MARK: ① 등록

    @Test func aFolderThatContainsOrIsInsideAnotherProjectsFolderIsRefused() throws {
        let fixture = try WorkspaceRegistryTests.Fixture()
        try nested(fixture)
        let registry = fixture.registry()
        try registry.setFolder(fixture.folder("a"), forProject: UUID())
        #expect(throws: overlapping) { try registry.setFolder(fixture.folder("a") + "/sub", forProject: UUID()) }
        #expect(throws: overlapping) { try registry.setFolder(fixture.folder("a") + "/sub/deep", forProject: UUID()) }
        #expect(throws: overlapping) { try registry.setFolder(fixture.home + "/Documents", forProject: UUID()) }
        #expect(registry.projectFolders().count == 1, "거절한 폴더는 표에 없다")
    }

    @Test func theSameRealPathForTwoProjectsIsAllowedAndSharesOneID() throws {
        let fixture = try WorkspaceRegistryTests.Fixture()
        let registry = fixture.registry()
        try registry.setFolder(fixture.folder("a"), forProject: UUID())
        let alias = fixture.home + "/Documents/alias-of-a"
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: fixture.folder("a"))
        try registry.setFolder(alias, forProject: UUID()) // 기호 링크 별칭도 같은 실제 경로다
        try registry.setPending(fixture.folder("a"), conversation: UUID())
        #expect(Set(registry.projectFolders().values) == [fixture.real("a")] && registry.projectFolders().count == 2)
        let ref = try #require(registry.ref(forPath: fixture.real("a")))
        #expect(WorkspaceRegistry.isOpaqueRef(ref))
    }

    @Test func siblingsAndFoldersWithTheSameNamePrefixAreNotOverlapping() throws {
        let fixture = try WorkspaceRegistryTests.Fixture()
        try nested(fixture)
        let registry = fixture.registry()
        try registry.setFolder(fixture.folder("a"), forProject: UUID())
        try registry.setFolder(fixture.folder("b"), forProject: UUID())
        try registry.setFolder(fixture.folder("a-other"), forProject: UUID())
        #expect(registry.projectFolders().count == 3)
    }

    @Test func changingToTheParentFolderIsAllowedWhateverOldSessionPinsAndConversationFoldersSay() throws {
        let fixture = try WorkspaceRegistryTests.Fixture()
        try nested(fixture)
        let registry = fixture.registry()
        let project = UUID()
        let sub = fixture.folder("a") + "/sub"
        try registry.setFolder(sub, forProject: project)
        try registry.pin(session: sessionA, to: sub) // 옛 세션 (끝났든 폐기됐든 상관없다)
        try registry.setPending(sub, conversation: UUID())
        try registry.setFolder(fixture.folder("a"), forProject: project)
        #expect(registry.folder(forProject: project) == fixture.real("a"), "옛 세션 핀과 상관없이 상위 폴더로 바꿀 수 있다")
        #expect(registry.pinned(session: sessionA) == fixture.real("a") + "/sub", "핀은 그대로다 (수명 관리 대상이 아니다)")
    }

    @Test func anotherProjectsCurrentFolderStillBlocksTheChangeAndAProjectMayMoveWithinItsOwnOldFolder() throws {
        let fixture = try WorkspaceRegistryTests.Fixture()
        try nested(fixture)
        let registry = fixture.registry()
        let project = UUID()
        let other = UUID()
        try registry.setFolder(fixture.folder("a") + "/sub", forProject: project)
        try FileManager.default.createDirectory(atPath: fixture.folder("a") + "/second", withIntermediateDirectories: true)
        try registry.setFolder(fixture.folder("a") + "/second", forProject: other)
        #expect(throws: overlapping) { try registry.setFolder(fixture.folder("a"), forProject: project) } // 다른 프로젝트 폴더를 품는다
        #expect(registry.folder(forProject: project) == fixture.real("a") + "/sub", "거절하면 그대로다")
        // 자기 옛 폴더 안으로 · 밖으로는 된다 (자기 폴더는 겹침이 아니다)
        try registry.setFolder(fixture.folder("a") + "/sub/deep", forProject: project)
        try registry.setFolder(fixture.folder("a") + "/sub", forProject: project)
        // 다른 프로젝트가 폴더를 지우면 그 폴더는 더 겹치지 않는다
        registry.removeFolder(forProject: other)
        try registry.setFolder(fixture.folder("a"), forProject: project)
    }

    @Test func aConversationFolderIsCheckedAgainstProjectsButNotAgainstPinsOrOtherConversations() throws {
        let fixture = try WorkspaceRegistryTests.Fixture()
        try nested(fixture)
        let registry = fixture.registry()
        try registry.setFolder(fixture.folder("b"), forProject: UUID())
        #expect(throws: overlapping) { try registry.setPending(fixture.home + "/Documents", conversation: UUID()) } // b를 품는다
        try registry.pin(session: sessionA, to: fixture.folder("a") + "/sub")
        try registry.setPending(fixture.folder("a"), conversation: UUID()) // 세션 핀과는 겹쳐도 된다
        try registry.setPending(fixture.folder("a") + "/sub", conversation: UUID()) // 다른 대화 폴더와도
        #expect(registry.pinned(session: sessionA) != nil)
    }

    @Test func thePickerChecksTheScopeItRegistersForAndShowsTheApprovedSentences() throws {
        let fixture = try WorkspaceRegistryTests.Fixture()
        try nested(fixture)
        try FileManager.default.createDirectory(atPath: fixture.folder("b") + "/.git", withIntermediateDirectories: true)
        let registry = fixture.registry()
        let project = UUID()
        try registry.setFolder(fixture.folder("a") + "/sub", forProject: project)
        let sub = fixture.folder("a") + "/sub"
        let parent = fixture.folder("a")
        #expect(registry.accepts(path: parent, scope: .project(project)), "자기 프로젝트의 옛 폴더만 있으면 겹침이 아니다")
        #expect(!registry.accepts(path: parent, scope: .project(UUID())) && !registry.accepts(path: parent, scope: .conversation(UUID())) && !registry.accepts(path: parent))
        #expect(registry.accepts(path: sub, scope: .project(UUID())), "같은 폴더는 겹침이 아니다")
        #expect(registry.rejectionMessage(forPath: parent, scope: .project(UUID())) == "Another project already uses this folder or one inside it.")
        #expect(registry.rejectionMessage(forPath: fixture.folder("b") + "/.git", scope: .project(UUID())) == "Choose a project folder, not a .git or settings folder.")
        #expect(registry.rejectionMessage(forPath: fixture.home, scope: .conversation(UUID())) == AgentWorkspaceCopy.rejected)
        // "폴더가 있다"는 규칙 통과 여부만 본다 (겹침은 등록할 때의 물음이다)
        #expect(registry.hasFolder(forProject: project))
    }

    /// 이유별 문장 · 범위를 받는 폴더 창 대역
    @MainActor
    private final class ScopedPicker: AgentWorkspacePicking {
        var reason: (@Sendable (String) -> String)?
        var accepts: (@Sendable (String) -> Bool)?

        func pickFolder(message: String, prompt: String, rejection: String, accepts: @escaping @Sendable (String) -> Bool) async -> String? { nil }

        func pickFolder(
            message: String, prompt: String, rejection: String, accepts: @escaping @Sendable (String) -> Bool, reason: @escaping @Sendable (String) -> String
        ) async -> String? {
            self.reason = reason
            self.accepts = accepts
            return nil
        }
    }

    @MainActor
    @Test func theSendGateHandsThePickerTheScopedCheckAndTheRegistrysReason() async throws {
        let fixture = try WorkspaceRegistryTests.Fixture()
        try nested(fixture)
        let registry = fixture.registry()
        let own = UUID()
        try registry.setFolder(fixture.folder("a") + "/sub", forProject: own) // 이 프로젝트의 지금 폴더가 규칙에서 빠졌다고 치고 다시 묻는 경우는 아래 hasFolder가 아니라 범위로 본다
        try registry.setFolder(fixture.folder("b"), forProject: UUID())
        let picker = ScopedPicker()
        let gate = AgentWorkspaceSendGate(folders: registry, picker: picker, isThisMac: { _ in true })
        // 다른 프로젝트(Acme)의 첫 보내기: a/sub(다른 프로젝트 own의 폴더)를 품은 a는 겹친다
        _ = await gate.prepare(
            conversationID: UUID(), hasSession: false, target: .agent(adapter: "agent:claude-code", connectionID: UUID()), projects: [.init(id: UUID(), name: "Acme")]
        )
        let accepts = try #require(picker.accepts)
        let reason = try #require(picker.reason)
        let parent = fixture.folder("a")
        #expect(accepts(parent) == false && reason(parent) == AgentWorkspaceCopy.overlappingFolder)
        #expect(accepts(fixture.folder("a") + "/sub"), "같은 폴더는 겹침이 아니다")
    }

    @MainActor
    @Test func aProjectWhoseOwnFolderIsGoneMayPickItsParentThroughTheGate() async throws {
        let fixture = try WorkspaceRegistryTests.Fixture()
        try nested(fixture)
        let registry = fixture.registry()
        let project = UUID()
        try registry.setFolder(fixture.folder("a") + "/sub", forProject: project)
        try FileManager.default.removeItem(atPath: fixture.folder("a") + "/sub/deep")
        try FileManager.default.removeItem(atPath: fixture.folder("a") + "/sub") // 프로젝트의 폴더가 사라졌다: "폴더가 있다"가 아니라 다시 묻는다
        #expect(!registry.hasFolder(forProject: project))
        let picker = ScopedPicker()
        let gate = AgentWorkspaceSendGate(folders: registry, picker: picker, isThisMac: { _ in true })
        _ = await gate.prepare(
            conversationID: UUID(), hasSession: false, target: .agent(adapter: "agent:claude-code", connectionID: UUID()), projects: [.init(id: project, name: "Acme")]
        )
        let accepts = try #require(picker.accepts)
        let parent = fixture.folder("a")
        #expect(accepts(parent), "자기 프로젝트의 사라진 옛 폴더는 겹침이 아니다 (게이트가 등록할 범위를 넘긴다)")
    }
}

/// 턴 시작 규칙 (레지스트리 단위): 세션 핀이 그 폴더이고 어떤 프로젝트의 지금 폴더와도 겹치지 않을 때만
struct WorkspaceTurnRuleTests {
    private let session = "5e551011-0000-4000-8000-0000000000a1"

    private func nested(_ fixture: WorkspaceRegistryTests.Fixture) throws {
        try FileManager.default.createDirectory(atPath: fixture.folder("a") + "/sub/deep", withIntermediateDirectories: true)
    }

    @Test func aSessionWhosePinIsItsProjectsCurrentFolderMayRun() throws {
        let fixture = try WorkspaceRegistryTests.Fixture()
        let registry = fixture.registry()
        try registry.setFolder(fixture.folder("a"), forProject: UUID())
        try registry.pin(session: session, to: fixture.folder("a"))
        #expect(registry.sessionMayRun(in: fixture.real("a"), session: session))
        #expect(!registry.sessionMayRun(in: fixture.real("b"), session: session), "핀이 아닌 폴더에서는 띄우지 않는다")
    }

    @Test func aPinThatNestsWithAProjectsCurrentFolderEitherWayMayNotRun() throws {
        let fixture = try WorkspaceRegistryTests.Fixture()
        try nested(fixture)
        let registry = fixture.registry()
        let project = UUID()
        try registry.setFolder(fixture.folder("a") + "/sub", forProject: project)
        try registry.pin(session: session, to: fixture.folder("a") + "/sub")
        #expect(registry.sessionMayRun(in: fixture.real("a") + "/sub", session: session))
        try registry.setFolder(fixture.folder("a"), forProject: project) // 프로젝트가 상위로 옮겼다 → 옛 세션(핀이 자손)
        #expect(!registry.sessionMayRun(in: fixture.real("a") + "/sub", session: session))
        try registry.setFolder(fixture.folder("a") + "/sub/deep", forProject: project) // 하위로 옮겼다 → 옛 세션(핀이 조상)
        #expect(!registry.sessionMayRun(in: fixture.real("a") + "/sub", session: session))
        // 상태가 없다: 프로젝트가 핀 폴더로 돌아오면 다시 된다
        try registry.setFolder(fixture.folder("a") + "/sub", forProject: project)
        #expect(registry.sessionMayRun(in: fixture.real("a") + "/sub", session: session))
    }

    @Test func aPinThatNestsWithAnotherProjectsCurrentFolderMayNotRunAndAnUnrelatedOneMay() throws {
        let fixture = try WorkspaceRegistryTests.Fixture()
        try nested(fixture)
        let registry = fixture.registry()
        let project = UUID()
        try registry.setFolder(fixture.folder("a") + "/sub", forProject: project)
        try registry.pin(session: session, to: fixture.folder("a") + "/sub")
        try registry.setFolder(fixture.folder("b"), forProject: project) // 프로젝트가 관계 없는 폴더로 옮겼다: 옛 세션은 옛 폴더에서 계속 된다
        #expect(registry.sessionMayRun(in: fixture.real("a") + "/sub", session: session))
        try registry.setFolder(fixture.folder("a"), forProject: UUID()) // 다른 프로젝트가 옛 폴더를 품는 폴더를 쓴다
        #expect(!registry.sessionMayRun(in: fixture.real("a") + "/sub", session: session))
    }

    @Test func twoProjectsOnTheSameRealPathAndTheirSessionsAllMayRun() throws {
        let fixture = try WorkspaceRegistryTests.Fixture()
        let registry = fixture.registry()
        try registry.setFolder(fixture.folder("a"), forProject: UUID())
        try registry.setFolder(fixture.folder("a"), forProject: UUID())
        try registry.pin(session: session, to: fixture.folder("a"))
        try registry.pin(session: "5e551011-0000-4000-8000-0000000000a2", to: fixture.folder("a"))
        #expect(registry.sessionMayRun(in: fixture.real("a"), session: session) && registry.sessionMayRun(in: fixture.real("a"), session: "5e551011-0000-4000-8000-0000000000a2"))
    }

    @Test func aConversationFolderSessionIsCheckedAgainstProjectFoldersToo() throws {
        let fixture = try WorkspaceRegistryTests.Fixture()
        try nested(fixture)
        let registry = fixture.registry()
        try registry.setPending(fixture.folder("a") + "/sub", conversation: UUID())
        try registry.pin(session: session, to: fixture.folder("a") + "/sub")
        #expect(registry.sessionMayRun(in: fixture.real("a") + "/sub", session: session), "프로젝트 폴더가 없으면 된다")
        try registry.setFolder(fixture.folder("a"), forProject: UUID()) // 대화 폴더는 등록할 때 프로젝트만 보므로 이 순서는 받아 준다
        #expect(!registry.sessionMayRun(in: fixture.real("a") + "/sub", session: session), "그러나 이 세션은 더는 띄우지 않는다")
    }

    @Test func aRegistryThatCannotBeReadFailsClosed() throws {
        let fixture = try WorkspaceRegistryTests.Fixture()
        let registry = fixture.registry()
        try registry.setFolder(fixture.folder("a"), forProject: UUID())
        try registry.pin(session: session, to: fixture.folder("a"))
        #expect(registry.sessionMayRun(in: fixture.real("a"), session: session))
        // 다시 시작한 앱이 읽는 파일이 깨졌다: 핀을 모르니 띄우지 않는다 (겹침 없음으로 읽지 않는다)
        try Data("{ not json".utf8).write(to: fixture.file)
        let restarted = fixture.registry()
        #expect(!restarted.sessionMayRun(in: fixture.real("a"), session: session))
        #expect(!restarted.sessionMayRun(in: fixture.real("a"), session: "5e551011-0000-4000-8000-0000000000ff"), "핀 없는 세션")
    }
}
#endif
