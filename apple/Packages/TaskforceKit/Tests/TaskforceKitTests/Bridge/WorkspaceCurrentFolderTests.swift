#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 대화 머리가 보이는 "지금 폴더" (사용자 결정 2026-10-21): 이 Mac의 등록부가 **이 대화에** 적어 둔 것만.
/// - 세션이 **있으면** 그 세션의 로컬 핀뿐이다 (세션을 연 뒤에는 바뀌지 않는다). 핀이 없으면 nil — 다른 Mac의 세션이거나 이 Mac이 아직 핀을 꽂기 전이다. 대화 폴더로 대신하지 않는다
///   (코드 검토 P2: 다른 Mac 에이전트 대화에 이 Mac의 폴더를 보이지 않게)
/// - 세션이 **없으면** 이 대화가 보내기 전에 고른 폴더
/// - 프로젝트의 폴더만 있는 대화는 nil이다 (그 폴더가 이 Mac의 연결 것인지 모르고, 첫 보내기에서 세션 핀이 되어서야 이 대화의 폴더다)
struct WorkspaceCurrentFolderTests {
    private let session = UUID(uuidString: "5e551011-0000-4000-8000-0000000000c1")!

    @Test func aConversationWithNothingRecordedHasNoFolder() throws {
        let fixture = try WorkspaceRegistryTests.Fixture()
        let registry = fixture.registry()
        #expect(registry.folder(forSession: nil, conversation: UUID()) == nil)
        #expect(registry.folder(forSession: session, conversation: UUID()) == nil)
    }

    @Test func theFolderChosenBeforeTheFirstSendIsTheConversationsFolder() throws {
        let fixture = try WorkspaceRegistryTests.Fixture()
        let registry = fixture.registry()
        let conversation = UUID()
        try registry.setPending(fixture.folder("a"), conversation: conversation)
        #expect(registry.folder(forSession: nil, conversation: conversation) == fixture.real("a"))
        #expect(registry.folder(forSession: nil, conversation: UUID()) == nil, "다른 대화의 폴더가 아니다")
    }

    @Test func onceASessionExistsOnlyItsLocalPinCountsAndTheConversationsChoiceNeverStandsIn() throws {
        let fixture = try WorkspaceRegistryTests.Fixture()
        let registry = fixture.registry()
        let conversation = UUID()
        try registry.setPending(fixture.folder("a"), conversation: conversation)
        // 세션은 있는데 이 Mac에 핀이 없다 (다른 Mac의 세션이거나 핀을 꽂기 전): 대화 폴더로 대신하지 않는다
        #expect(registry.folder(forSession: session, conversation: conversation) == nil, "핀이 없는 세션 → nil")
        try registry.pin(session: session.uuidString, to: fixture.folder("b"))
        #expect(registry.folder(forSession: session, conversation: conversation) == fixture.real("b"), "세션이 실제로 쓰는 폴더")
        #expect(registry.folder(forSession: nil, conversation: conversation) == fixture.real("a"), "세션이 없는 동안은 대화 폴더")
    }

    @Test func aSessionWithoutALocalPinIsNilEvenWhenTheConversationHasNothing() throws {
        let fixture = try WorkspaceRegistryTests.Fixture()
        let registry = fixture.registry()
        try registry.pin(session: UUID().uuidString, to: fixture.folder("a")) // 다른 세션의 핀
        #expect(registry.folder(forSession: session, conversation: UUID()) == nil)
    }

    @Test func aProjectsFolderAloneIsNotShownBeforeTheSessionPinsIt() throws {
        let fixture = try WorkspaceRegistryTests.Fixture()
        let registry = fixture.registry()
        let project = UUID()
        try registry.setFolder(fixture.folder("a"), forProject: project)
        #expect(registry.folder(forSession: nil, conversation: UUID()) == nil, "프로젝트의 폴더가 어느 Mac의 연결 것인지 알 수 없다")
        try registry.pin(session: session.uuidString, to: fixture.folder("a"))
        #expect(registry.folder(forSession: session, conversation: UUID()) == fixture.real("a"), "세션이 핀을 받으면 그 폴더가 이 대화의 폴더다")
    }

    @Test func theAnswerSurvivesARestartAndNeverChangesWhenAProjectsFolderMoves() throws {
        let fixture = try WorkspaceRegistryTests.Fixture()
        let registry = fixture.registry()
        let project = UUID()
        try registry.setFolder(fixture.folder("a"), forProject: project)
        try registry.pin(session: session.uuidString, to: fixture.folder("a"))
        try registry.setFolder(fixture.folder("b"), forProject: project)
        #expect(fixture.registry().folder(forSession: session, conversation: UUID()) == fixture.real("a"), "세션을 연 뒤에는 폴더가 따라 움직이지 않는다")
    }

    @Test func aFakeRegistryThatDoesNotKnowTheQuestionAnswersNothing() {
        // 기본 구현: 이 물음을 모르는 등록부(가짜)는 폴더가 없다고 답하고, 잊기는 아무 일도 하지 않는다
        let folders: any AgentWorkspaceFolders = AgentWorkspaceGateTests.FakeFolders()
        #expect(folders.folder(forSession: nil, conversation: UUID()) == nil)
        folders.forgetFolder(forConversation: UUID())
    }

    // MARK: 잊기 (코드 검토 P3: 다시 쓰인 빈 대화 · 버려진 대화 · 대상이 바뀐 대화에 옛 폴더가 남지 않게)

    @Test func forgettingAConversationsFolderRemovesOnlyItsPendingChoice() throws {
        let fixture = try WorkspaceRegistryTests.Fixture()
        let registry = fixture.registry()
        let kept = UUID()
        let forgotten = UUID()
        try registry.setPending(fixture.folder("a"), conversation: kept)
        try registry.setPending(fixture.folder("b"), conversation: forgotten)
        try registry.pin(session: session.uuidString, to: fixture.folder("c"))
        registry.forgetFolder(forConversation: forgotten)
        #expect(registry.folder(forSession: nil, conversation: forgotten) == nil)
        #expect(registry.folder(forSession: nil, conversation: kept) == fixture.real("a"), "다른 대화의 폴더는 그대로")
        #expect(registry.folder(forSession: session, conversation: UUID()) == fixture.real("c"), "세션 핀은 안 건드린다")
        #expect(fixture.registry().folder(forSession: nil, conversation: forgotten) == nil, "다시 읽어도 없다")
    }

    @Test func forgettingAConversationThatHasNoFolderWritesNothing() throws {
        let fixture = try WorkspaceRegistryTests.Fixture()
        let registry = fixture.registry()
        registry.forgetFolder(forConversation: UUID())
        #expect(!FileManager.default.fileExists(atPath: fixture.file.path), "바뀐 것이 없으면 파일을 만들지 않는다")
        try registry.setPending(fixture.folder("a"), conversation: UUID())
        let before = try Data(contentsOf: fixture.file)
        registry.forgetFolder(forConversation: UUID())
        #expect(try Data(contentsOf: fixture.file) == before)
    }
}
#endif
