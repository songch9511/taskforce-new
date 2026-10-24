#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 목록이 빼는 id와 "In Taskforce"로 남기는 id (OA 외부 세션 PR2m): 세션 폴더 상태만 읽는다
struct ExternalSessionBoundIDsTests {
    private let attached = "5e5e5e5e-0000-4000-8000-0000000000a1"
    private let started = "5e5e5e5e-0000-4000-8000-0000000000b2"
    private let unbound = "5e5e5e5e-0000-4000-8000-0000000000c3"

    private func folder(_ root: TempDirectory, _ name: String = UUID().uuidString) throws -> URL {
        let url = root.url.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func attachedSessionsStayInTheListAsInTaskforceAndStartedOnesAreLeftOut() throws {
        let root = TempDirectory()
        _ = ClaudeSessionState.writeAttached(providerSessionID: attached, at: Date(), in: try folder(root))
        var state = ClaudeSessionState()
        state.providerSessionID = started
        state.bound = true
        try state.save(in: try folder(root))
        var half = ClaudeSessionState()
        half.providerSessionID = unbound
        try half.save(in: try folder(root))
        let ids = ExternalSessionBoundIDs.read(sessionsRoot: root.url)
        #expect(ids.attached == [attached] && ids.taskforce == [started, unbound], "묶이지 않은 id도 Taskforce가 만든 것이라 목록에서 뺀다 (기존 동작)")
    }

    @Test func foldersThatAreNotSessionFoldersAndFilesWithoutStateAreIgnored() throws {
        let root = TempDirectory()
        _ = try folder(root, "lineage")
        _ = try folder(root, "probe-cwd")
        _ = try folder(root)
        #expect(ExternalSessionBoundIDs.read(sessionsRoot: root.url) == (taskforce: [], attached: []))
        #expect(ExternalSessionBoundIDs.read(sessionsRoot: root.url.appending(path: "missing")) == (taskforce: [], attached: []))
    }

    @Test func idsAreLowercased() throws {
        let root = TempDirectory()
        var state = ClaudeSessionState()
        state.providerSessionID = started.uppercased()
        state.bound = true
        try state.save(in: try folder(root))
        #expect(ExternalSessionBoundIDs.read(sessionsRoot: root.url).taskforce == [started])
    }
}
#endif
