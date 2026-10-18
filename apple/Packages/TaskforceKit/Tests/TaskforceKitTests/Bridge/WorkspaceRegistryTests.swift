#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 작업 폴더 등록부 (OA D4a2-01 · 03, 계약 13.6 "등록부"): 원자적 쓰기 · 0600 · 깨진 파일 · 계정 파티션 · deletePartition · id ↔ 경로
struct WorkspaceRegistryTests {
    /// 임시 폴더 안의 홈. 시스템 폴더 목록은 비워 둔다 (임시 폴더가 `/private` 아래다)
    final class Fixture: @unchecked Sendable {
        let temp = TempDirectory()
        let home: String
        let rules: WorkspaceFolderRules
        let file: URL

        init(protectedRoots: [String] = []) throws {
            home = temp.appending("home").path
            for name in ["Documents/a", "Documents/b", "Documents/c"] {
                try FileManager.default.createDirectory(at: URL(fileURLWithPath: home + "/" + name), withIntermediateDirectories: true)
            }
            rules = WorkspaceFolderRules(home: home, systemRoots: [], protectedRoots: protectedRoots)
            file = temp.appending("partition/workspaces.json")
            // 파티션 폴더는 원장이 연다 (등록부는 만들지 않는다, 보안 F4)
            try Self.openPartition(file.deletingLastPathComponent())
        }

        static func openPartition(_ directory: URL) throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }

        func folder(_ name: String) -> String { home + "/Documents/" + name }
        func registry() -> WorkspaceRegistry { WorkspaceRegistry(file: file, rules: rules) }
        /// 등록부가 적는 realpath
        func real(_ name: String) -> String { GateFileSystem.realpath(folder(name)) ?? folder(name) }
    }

    @Test func aProjectFolderIsStoredAndComesBackAfterARestart() throws {
        let fixture = try Fixture()
        let project = UUID()
        let registry = fixture.registry()
        #expect(registry.folder(forProject: project) == nil)
        let stored = try registry.setFolder(fixture.folder("a"), forProject: project)
        #expect(stored == fixture.real("a"))
        #expect(registry.folder(forProject: project) == fixture.real("a"))
        // 새 인스턴스 = 앱 재시작
        #expect(fixture.registry().folder(forProject: project) == fixture.real("a"))
        #expect(fixture.registry().projectFolders() == [project: fixture.real("a")])
        registry.removeFolder(forProject: project)
        #expect(fixture.registry().folder(forProject: project) == nil)
    }

    @Test func theFileIsWrittenWithOwnerOnlyPermissionsAndNoTemporaryFileIsLeft() throws {
        let fixture = try Fixture()
        try fixture.registry().setFolder(fixture.folder("a"), forProject: UUID())
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.file.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.file.deletingLastPathComponent().path)
        #expect(names == ["workspaces.json"], "임시 파일이 남지 않는다: \(names)")
    }

    @Test func aSessionPinKeepsTheFirstFolderAndTheConversationFolderIsSeparate() throws {
        let fixture = try Fixture()
        let registry = fixture.registry()
        let session = "5e551011-0000-4000-8000-000000000001"
        try registry.pin(session: session, to: fixture.folder("a"))
        try registry.pin(session: session, to: fixture.folder("b"))
        #expect(registry.pinned(session: session) == fixture.real("a"), "세션을 연 뒤에는 폴더가 따라 움직이지 않는다")
        #expect(registry.pinned(session: session.uppercased()) == fixture.real("a"), "세션 id는 대소문자를 가리지 않는다")
        let conversation = UUID()
        try registry.setPending(fixture.folder("c"), conversation: conversation)
        #expect(registry.pending(conversation: conversation) == fixture.real("c"))
        #expect(fixture.registry().pending(conversation: conversation) == fixture.real("c"))
        registry.removePending(conversation: conversation)
        #expect(registry.pending(conversation: conversation) == nil)
    }

    @Test func aBrokenFileReadsAsEmptyTablesAndIsMovedAsideBeforeItIsOverwritten() throws {
        let fixture = try Fixture()
        try FileManager.default.createDirectory(at: fixture.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: fixture.file)
        let registry = fixture.registry()
        #expect(registry.projectFolders().isEmpty, "깨진 파일은 빈 표다")
        // 읽는 것만으로는 옮기지 않는다
        #expect(try Data(contentsOf: fixture.file) == Data("{ not json".utf8))
        try registry.setFolder(fixture.folder("a"), forProject: UUID())
        let aside = fixture.file.deletingLastPathComponent().appending(path: "workspaces.json.corrupt")
        #expect(try Data(contentsOf: aside) == Data("{ not json".utf8), "덮어쓰기 전에 옆으로 옮긴다")
        #expect(fixture.registry().projectFolders().count == 1)
    }

    @Test func aFileOfAnotherVersionOrWithABadIDIsTreatedAsBroken() throws {
        let fixture = try Fixture()
        try FileManager.default.createDirectory(at: fixture.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        for text in [#"{"v":2,"refs":{},"projects":{},"sessions":{},"pending":{}}"#, #"{"v":1,"refs":{"/Users/x/secret":"/Users/x/secret"},"projects":{},"sessions":{},"pending":{}}"#, #"{"v":1,"refs":[]}"#] {
            try Data(text.utf8).write(to: fixture.file)
            #expect(fixture.registry().projectFolders().isEmpty, "\(text)")
        }
    }

    @Test func aTableLineThatPointsAtAnUnknownIDIsDropped() throws {
        let fixture = try Fixture()
        let project = UUID()
        try FileManager.default.createDirectory(at: fixture.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = #"{"v":1,"refs":{},"projects":{"\#(project.uuidString.lowercased())":"ws_3f1c2c52-1111-4222-8333-444455556666"},"sessions":{},"pending":{}}"#
        try Data(text.utf8).write(to: fixture.file)
        #expect(fixture.registry().folder(forProject: project) == nil)
    }

    @Test func eachAccountPartitionHasItsOwnRegistry() throws {
        let fixture = try Fixture()
        try Fixture.openPartition(fixture.temp.appending("partition-1"))
        try Fixture.openPartition(fixture.temp.appending("partition-2"))
        let first = WorkspaceRegistry(file: fixture.temp.appending("partition-1/workspaces.json"), rules: fixture.rules)
        let second = WorkspaceRegistry(file: fixture.temp.appending("partition-2/workspaces.json"), rules: fixture.rules)
        let project = UUID()
        try first.setFolder(fixture.folder("a"), forProject: project)
        #expect(second.folder(forProject: project) == nil)
        #expect(first.folder(forProject: project) == fixture.real("a"))
    }

    @Test func deletingThePartitionRemovesTheRegistryWithIt() async throws {
        let temp = TempDirectory()
        let partition = BridgePartition(apiOrigin: "https://x.test", userID: UUID())
        let home = temp.appending("home/Documents/a")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let rules = WorkspaceFolderRules(home: temp.appending("home").path, systemRoots: [])
        let file = partition.directory(in: temp.url).appending(path: WorkspaceRegistry.fileName)
        try Fixture.openPartition(partition.directory(in: temp.url))
        try WorkspaceRegistry(file: file, rules: rules).setFolder(home.path, forProject: UUID())
        #expect(FileManager.default.fileExists(atPath: file.path))
        let result = await BridgeStorage.deletePartition(partition, root: temp.url, credentials: InMemoryBridgeCredentialStore())
        #expect(result.folderRemoved)
        #expect(!FileManager.default.fileExists(atPath: file.path), "계정 삭제가 등록부를 같이 지운다")
    }

    // MARK: 경로 ↔ 불투명 id (D4a2-03)

    @Test func thePathAndItsOpaqueIDRoundTripAndUnknownValuesAreNil() throws {
        let fixture = try Fixture()
        let registry = fixture.registry()
        #expect(registry.ref(forPath: fixture.real("a")) == nil, "등록하지 않은 경로에는 id를 만들지 않는다")
        try registry.setFolder(fixture.folder("a"), forProject: UUID())
        let ref = try #require(registry.ref(forPath: fixture.real("a")))
        #expect(WorkspaceRegistry.isOpaqueRef(ref) && ref.count == 39 && !ref.contains("/"))
        #expect(registry.path(forRef: ref) == fixture.real("a"))
        #expect(registry.path(forRef: "ws_3f1c2c52-1111-4222-8333-444455556666") == nil, "모르는 id")
        #expect(registry.path(forRef: fixture.real("a")) == nil, "경로를 id로 쓰지 못한다")
        // 같은 폴더는 프로젝트가 달라도 같은 id다. 다른 폴더는 다른 id
        try registry.setFolder(fixture.folder("a"), forProject: UUID())
        try registry.setFolder(fixture.folder("b"), forProject: UUID())
        #expect(registry.ref(forPath: fixture.real("a")) == ref)
        #expect(registry.ref(forPath: fixture.real("b")) != ref)
        // 재시작해도 같은 id
        #expect(fixture.registry().ref(forPath: fixture.real("a")) == ref)
    }

    @Test func theOpaqueIDShapeIsAPrefixAndALowercaseUUIDOnly() {
        #expect(WorkspaceRegistry.isOpaqueRef("ws_3f1c2c52-1111-4222-8333-444455556666"))
        #expect(!WorkspaceRegistry.isOpaqueRef("ws_3F1C2C52-1111-4222-8333-444455556666"))
        #expect(!WorkspaceRegistry.isOpaqueRef("/Users/me/work"))
        #expect(!WorkspaceRegistry.isOpaqueRef("workspace-fake"))
        #expect(!WorkspaceRegistry.isOpaqueRef("ws_"))
        #expect(!WorkspaceRegistry.isOpaqueRef("ws_3f1c2c52-1111-4222-8333-444455556666/../x"))
    }

    @Test func anIDNoTableUsesAnymoreIsDropped() throws {
        let fixture = try Fixture()
        let registry = fixture.registry()
        let project = UUID()
        try registry.setFolder(fixture.folder("a"), forProject: project)
        let ref = try #require(registry.ref(forPath: fixture.real("a")))
        registry.removeFolder(forProject: project)
        #expect(registry.path(forRef: ref) == nil)
        // 세션 핀이 쓰는 동안은 남는다
        try registry.setFolder(fixture.folder("b"), forProject: project)
        try registry.pin(session: "5e551011-0000-4000-8000-000000000002", to: fixture.folder("b"))
        let kept = try #require(registry.ref(forPath: fixture.real("b")))
        registry.removeFolder(forProject: project)
        #expect(registry.path(forRef: kept) == fixture.real("b"))
    }

    // MARK: 규칙이 한 곳에서 걸러 준다

    @Test func aFolderTheRulesRejectIsNeverRegisteredAndNothingIsWritten() throws {
        let fixture = try Fixture()
        let registry = fixture.registry()
        #expect(throws: WorkspaceRegistry.RegistryError.rejected(.homeOrAncestor)) { try registry.setFolder(fixture.home, forProject: UUID()) }
        #expect(throws: WorkspaceRegistry.RegistryError.rejected(.notFound)) { try registry.setPending(fixture.folder("missing"), conversation: UUID()) }
        let elsewhere = fixture.temp.appending("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        #expect(throws: WorkspaceRegistry.RegistryError.rejected(.outsideAllowedAreas)) { try registry.pin(session: "5e551011-0000-4000-8000-000000000003", to: elsewhere.path) }
        #expect(!FileManager.default.fileExists(atPath: fixture.file.path), "거절한 폴더로는 파일도 만들지 않는다")
    }

    @Test func theRegistryFacesTheSendGateWithFoldersThatStillPassTheRules() throws {
        let fixture = try Fixture()
        let registry = fixture.registry()
        let project = UUID()
        let conversation = UUID()
        try registry.register(path: fixture.folder("a"), scope: .project(project))
        try registry.register(path: fixture.folder("b"), scope: .conversation(conversation))
        #expect(registry.hasFolder(forProject: project) && registry.hasFolder(forConversation: conversation))
        #expect(!registry.hasFolder(forProject: UUID()))
        // 폴더가 지워지면 "폴더가 있다"가 아니다 (다시 묻는다)
        try FileManager.default.removeItem(atPath: fixture.folder("a"))
        #expect(!registry.hasFolder(forProject: project))
        #expect(registry.accepts(path: fixture.folder("c")) && !registry.accepts(path: fixture.home))
    }
}
#endif
