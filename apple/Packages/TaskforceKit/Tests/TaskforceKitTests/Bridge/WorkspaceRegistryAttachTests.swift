#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 이어받기의 폴더 핀 (OA 외부 세션 PR2m, 계약 6.1-3 · 4 · 20장 2 · 3): 서버로 보낼 불투명 id를 **쓰지 않고** 미리 정하고, 서버 응답이 맞은 뒤에만 그 id로 핀을 꽂는다.
/// 이미 다른 폴더에 핀이 있으면 덮지 않는다. 가짜 임시 홈만 쓴다
struct WorkspaceRegistryAttachTests {
    typealias Fixture = WorkspaceRegistryTests.Fixture
    private let session = "5e551011-0000-4000-8000-00000000a001"

    @Test func aFolderTheRulesAcceptGetsItsRealpathAndACandidateRefThatIsNotStoredYet() throws {
        let fixture = try Fixture()
        let registry = fixture.registry()
        let before = try? Data(contentsOf: fixture.file)
        let proposal = try #require(registry.proposedRef(forPath: fixture.folder("a")))
        #expect(proposal.path == fixture.real("a"))
        #expect(WorkspaceRegistry.isOpaqueRef(proposal.ref), "서버에 가는 모양 `ws_` + 소문자 UUID")
        #expect(registry.ref(forPath: fixture.folder("a")) == nil, "아직 등록하지 않았다: 쓰지 않고 정한다")
        #expect((try? Data(contentsOf: fixture.file)) == before, "파일을 쓰지 않았다")
    }

    @Test func anAlreadyRegisteredFolderKeepsItsRef() throws {
        let fixture = try Fixture()
        let registry = fixture.registry()
        try registry.setFolder(fixture.folder("a"), forProject: UUID())
        let existing = try #require(registry.ref(forPath: fixture.folder("a")))
        #expect(registry.proposedRef(forPath: fixture.folder("a"))?.ref == existing, "같은 폴더는 같은 ws_id다 (서버의 경로 잠금이 같은 키를 본다)")
    }

    @Test func aFolderTheRulesRefuseGetsNoProposal() throws {
        let fixture = try Fixture()
        let registry = fixture.registry()
        for path in ["/", fixture.home, fixture.home + "/.ssh", "/tmp", fixture.folder("missing"), "relative", fixture.home + "/Documents/a\u{0}x"] {
            #expect(registry.proposedRef(forPath: path) == nil, "\(path)")
        }
    }

    @Test func aFolderThatOverlapsAProjectFolderGetsNoProposal() throws {
        let fixture = try Fixture()
        let registry = fixture.registry()
        let sub = fixture.folder("a") + "/sub"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        try registry.setFolder(fixture.folder("a"), forProject: UUID())
        #expect(registry.proposedRef(forPath: sub) == nil, "프로젝트 폴더의 자손 (13.13)")
        #expect(registry.proposedRef(forPath: fixture.folder("a"))?.path == fixture.real("a"), "같은 폴더는 겹침이 아니다")
    }

    @Test func thePinUsesTheProposedRefAndTheTablesAgree() throws {
        let fixture = try Fixture()
        let registry = fixture.registry()
        let proposal = try #require(registry.proposedRef(forPath: fixture.folder("a")))
        #expect(registry.attachPin(session: session, to: fixture.folder("a"), ref: proposal.ref) == .pinned(ref: proposal.ref))
        #expect(registry.pinned(session: session) == fixture.real("a"))
        #expect(registry.ref(forPath: fixture.folder("a")) == proposal.ref && registry.path(forRef: proposal.ref) == fixture.real("a"))
        // 앱을 다시 띄워도 남는다
        #expect(fixture.registry().pinned(session: session) == fixture.real("a"))
        #expect(fixture.registry().ref(forPath: fixture.folder("a")) == proposal.ref)
    }

    @Test func aFolderThatGotAnotherRefInTheMeantimeKeepsThatRefAndTheCallerSeesIt() throws {
        let fixture = try Fixture()
        let registry = fixture.registry()
        let proposal = try #require(registry.proposedRef(forPath: fixture.folder("a")))
        // 제안과 핀 사이에 프로젝트가 같은 폴더를 등록했다: 그 폴더의 ws_id는 이미 정해졌다
        try registry.setFolder(fixture.folder("a"), forProject: UUID())
        let other = try #require(registry.ref(forPath: fixture.folder("a")))
        #expect(other != proposal.ref)
        #expect(registry.attachPin(session: session, to: fixture.folder("a"), ref: proposal.ref) == .pinned(ref: other), "서버에 보낸 id와 다르다: 부른 쪽이 거절한다")
    }

    @Test func aSecondPinOfTheSameSessionAndFolderIsHarmless() throws {
        let fixture = try Fixture()
        let registry = fixture.registry()
        let proposal = try #require(registry.proposedRef(forPath: fixture.folder("a")))
        _ = registry.attachPin(session: session, to: fixture.folder("a"), ref: proposal.ref)
        let before = try Data(contentsOf: fixture.file)
        #expect(registry.attachPin(session: session, to: fixture.folder("a"), ref: proposal.ref) == .samePin(ref: proposal.ref))
        #expect(try Data(contentsOf: fixture.file) == before, "다시 쓰지 않는다")
    }

    @Test func aSessionPinnedToAnotherFolderIsNeverMoved() throws {
        let fixture = try Fixture()
        let registry = fixture.registry()
        try registry.pin(session: session, to: fixture.folder("a"))
        let proposal = try #require(registry.proposedRef(forPath: fixture.folder("b")))
        #expect(registry.attachPin(session: session, to: fixture.folder("b"), ref: proposal.ref) == .pinnedElsewhere)
        #expect(registry.pinned(session: session) == fixture.real("a"))
        #expect(registry.ref(forPath: fixture.folder("b")) == nil, "거절한 폴더의 id를 남기지 않는다")
    }

    @Test func aRefThatIsNotAnOpaqueIdOrIsTakenByAnotherFolderIsRefused() throws {
        let fixture = try Fixture()
        let registry = fixture.registry()
        for bad in ["../x", "ws_ABC", "/taskforce/ws_x", "", "ws_" + UUID().uuidString] {
            #expect(registry.attachPin(session: session, to: fixture.folder("a"), ref: bad) == .rejected, "\(bad)")
        }
        #expect(registry.pinned(session: session) == nil)
        try registry.setFolder(fixture.folder("b"), forProject: UUID())
        let takenRef = try #require(registry.ref(forPath: fixture.folder("b")))
        #expect(registry.attachPin(session: session, to: fixture.folder("a"), ref: takenRef) == .refTaken, "다른 폴더의 id를 이 폴더에 쓰지 않는다")
        #expect(registry.pinned(session: session) == nil)
    }

    @Test func aFolderTheRulesRefuseOrThatOverlapsIsNotPinned() throws {
        let fixture = try Fixture()
        let registry = fixture.registry()
        let ref = "ws_" + UUID().uuidString.lowercased()
        #expect(registry.attachPin(session: session, to: fixture.home + "/.ssh", ref: ref) == .rejected)
        let sub = fixture.folder("a") + "/sub"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        try registry.setFolder(fixture.folder("a"), forProject: UUID())
        #expect(registry.attachPin(session: session, to: sub, ref: ref) == .rejected)
        #expect(registry.pinned(session: session) == nil)
    }

    @Test func twoPinsAtOnceLeaveOneSessionPinOnce() async throws {
        let fixture = try Fixture()
        let registry = fixture.registry()
        let proposal = try #require(registry.proposedRef(forPath: fixture.folder("a")))
        let folder = fixture.folder("a")
        let session = self.session
        let results = await withTaskGroup(of: WorkspaceRegistry.AttachPinResult.self) { group in
            for _ in 0..<8 { group.addTask { registry.attachPin(session: session, to: folder, ref: proposal.ref) } }
            var all: [WorkspaceRegistry.AttachPinResult] = []
            for await result in group { all.append(result) }
            return all
        }
        #expect(results.filter { $0 == .pinned(ref: proposal.ref) }.count == 1 && results.filter { $0 == .samePin(ref: proposal.ref) }.count == 7)
        #expect(registry.pinned(session: session) == fixture.real("a"))
    }
}
#endif
