#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 대화 머리가 보이는 "지금 폴더" (사용자 결정 2026-10-21): 이 Mac의 등록부가 **이 대화에** 적어 둔 것만 — 세션 핀(세션의 폴더, 세션을 연 뒤에는 바뀌지 않는다), 없으면 이 대화가 보내기 전에 고른 폴더.
/// 아직 아무것도 적히지 않은 대화 · 다른 Mac의 세션 · 프로젝트의 폴더만 있는 대화는 nil이다 (프로젝트의 폴더는 첫 보내기에서 세션 핀이 되어서야 이 대화의 폴더다)
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

    @Test func theSessionPinIsTheFolderOnceTheSessionExistsAndWinsOverTheConversationsChoice() throws {
        let fixture = try WorkspaceRegistryTests.Fixture()
        let registry = fixture.registry()
        let conversation = UUID()
        try registry.setPending(fixture.folder("a"), conversation: conversation)
        try registry.pin(session: session.uuidString, to: fixture.folder("b"))
        #expect(registry.folder(forSession: session, conversation: conversation) == fixture.real("b"), "세션이 실제로 쓰는 폴더")
        // 세션이 아직 핀을 받기 전(첫 보내기 직후)에는 이 대화가 고른 폴더가 곧 그 폴더다
        #expect(registry.folder(forSession: UUID(), conversation: conversation) == fixture.real("a"))
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
        // 기본 구현: 이 물음을 모르는 등록부(가짜)는 폴더가 없다고 답한다
        let folders: any AgentWorkspaceFolders = AgentWorkspaceGateTests.FakeFolders()
        #expect(folders.folder(forSession: nil, conversation: UUID()) == nil)
    }
}
#endif
