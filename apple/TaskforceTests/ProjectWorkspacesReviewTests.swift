import Foundation
import Testing
import TaskforceKit
@testable import Taskforce

/// 검토 1 반영 (코디네이터 13.11, 격리 호스트): 앱 번들도 작업 폴더로 받지 않는다(보안 F2) · 계정 삭제가 등록부 캐시와 `.command` 파일을 지우고 늦은 쓰기를 거절한다(F4).
/// 서버는 가짜(`FakeBridgeServer`)이고 폴더는 임시 폴더다. 실제 폴더 창 · 터미널 · 실제 Application Support 쓰기가 0이다
@MainActor
struct ProjectWorkspacesReviewTests {
    static let bundleID = "dev.taskforcelabs.unittest.taskforce"

    // MARK: F2 앱 번들

    /// 홈 안의 `Downloads/Taskforce.app` (내려받은 앱을 `/Applications` 밖에서 실행하는 경우)
    private func bundle(_ rig: ProjectWorkspacesTests.Rig) throws -> URL {
        let bundle = URL(fileURLWithPath: rig.home + "/Downloads/Taskforce.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle.appending(path: "Contents/Helpers"), withIntermediateDirectories: true)
        return bundle
    }

    @Test func theProtectedRootsHoldTheAppDataFolderThePartitionRootAndTheBundlesRealPath() throws {
        let rig = try ProjectWorkspacesTests.Rig()
        defer { rig.cleanup() }
        let bundle = try bundle(rig)
        // 번들이 기호 링크로 닿는 경우에도 실제 경로가 들어간다
        let link = rig.temp.appending(path: "launcher.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bundle)
        let roots = ProjectWorkspaces.protectedRoots(support: rig.support, bundleID: Self.bundleID, root: rig.root, bundle: AppBundleProtection(bundleURL: link, translocation: .notTranslocated)).map(\.path)
        #expect(roots == [rig.support.appending(path: Self.bundleID).path, rig.root.path, GateFileSystem.realpath(bundle.path) ?? "-"], "\(roots)")
        // 기본값은 이 실행의 번들이다
        let current = ProjectWorkspaces.protectedRoots(support: rig.support, bundleID: Self.bundleID, root: rig.root).map(\.path)
        #expect(current.last == GateFileSystem.realpath(Bundle.main.bundleURL.path))
    }

    @Test func aFolderHoldingTheBundleOrInsideItIsRefusedAsAWorkFolder() throws {
        let rig = try ProjectWorkspacesTests.Rig()
        defer { rig.cleanup() }
        let bundle = try bundle(rig)
        let home = rig.home
        let reads = rig.reads
        let workspaces = ProjectWorkspaces(
            root: rig.root, home: home, protectedRoots: ProjectWorkspaces.protectedRoots(support: rig.support, bundleID: Self.bundleID, root: rig.root, bundle: AppBundleProtection(bundleURL: bundle, translocation: .notTranslocated)),
            rules: { WorkspaceFolderRules(home: home, systemRoots: [], protectedRoots: $0) }, sessions: reads, contexts: reads, localBridgeID: { nil }, connectionBridgeID: { _ in nil }
        )
        let p = BridgePartition(apiOrigin: "http://localhost:3000", userID: UUID())
        try rig.openPartition(p)
        let registry = workspaces.registry(for: p)
        let alias = rig.temp.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: bundle.appending(path: "Contents"))
        for refused in [rig.home + "/Downloads", bundle.path, bundle.path + "/Contents/Helpers", alias.path] {
            #expect(!registry.accepts(path: refused), "\(refused)")
        }
        #expect(throws: WorkspaceRegistry.RegistryError.rejected(.appData)) { try registry.setFolder(rig.home + "/Downloads", forProject: UUID()) }
        #expect(registry.accepts(path: rig.folder("client-a")), "관계 없는 폴더는 받는다")
    }

    // MARK: F4 계정 삭제

    @Test func forgettingAPartitionDropsTheCachedRegistryObject() throws {
        let rig = try ProjectWorkspacesTests.Rig()
        defer { rig.cleanup() }
        let p = BridgePartition(apiOrigin: "http://localhost:3000", userID: UUID())
        let other = BridgePartition(apiOrigin: "http://localhost:3000", userID: UUID())
        let registry = rig.workspaces.registry(for: p)
        let otherRegistry = rig.workspaces.registry(for: other)
        rig.workspaces.forget(p)
        #expect(rig.workspaces.registry(for: p) !== registry, "다시 부르면 새 객체다")
        #expect(rig.workspaces.registry(for: other) === otherRegistry, "다른 계정은 그대로")
    }

    @Test func deletingTheAccountRemovesTheCommandFilesDropsTheRegistryAndRefusesALateWrite() async throws {
        let rig = try ProjectWorkspacesTests.Rig()
        defer { rig.cleanup() }
        let terminal = rig.temp.appending(path: "Terminal")
        let store = AgentTerminalCommandStore(directory: terminal)
        let command = try store.write("#!/bin/sh\necho hi\n")
        let note = terminal.appending(path: "notes.txt")
        try Data("keep".utf8).write(to: note)
        let fixture = HostFixture(root: rig.root, workspaces: rig.workspaces, terminalDirectory: terminal)
        defer { fixture.cleanup() }
        await fixture.start()
        _ = await fixture.waitForBridge()
        let userID = try #require(fixture.user.value)
        let p = BridgePartition(apiBaseURL: fixture.server.baseURL, userID: userID)
        let registry = rig.workspaces.registry(for: p)
        try registry.setFolder(rig.folder("client-a"), forProject: UUID())
        #expect(FileManager.default.fileExists(atPath: registry.file.path))

        let result = await fixture.host.accountDeleted(userID: userID)
        #expect(result.folderRemoved)
        #expect(!FileManager.default.fileExists(atPath: command.path), "세션 id · 경로가 적힌 `.command` 파일도 계정과 함께 지운다")
        #expect(FileManager.default.fileExists(atPath: note.path), ".command가 아닌 파일은 남는다")
        #expect(rig.workspaces.registry(for: p) !== registry, "등록부 캐시를 비웠다")
        // 지워진 파티션의 옛 등록부에 늦게 온 쓰기: 거절되고 폴더도 옛 표도 되살아나지 않는다
        #expect(throws: WorkspaceRegistry.RegistryError.writeFailed) { try registry.setFolder(rig.folder("client-b"), forProject: UUID()) }
        #expect(!FileManager.default.fileExists(atPath: p.directory(in: rig.root).path))
    }

    @Test func aHostWithoutATerminalFolderStillDeletesTheAccount() async throws {
        let rig = try ProjectWorkspacesTests.Rig()
        defer { rig.cleanup() }
        let fixture = HostFixture(root: rig.root, workspaces: rig.workspaces)
        defer { fixture.cleanup() }
        await fixture.start()
        _ = await fixture.waitForBridge()
        let result = await fixture.host.accountDeleted(userID: try #require(fixture.user.value))
        #expect(result.folderRemoved)
    }
}
