import Foundation
import Testing
import TaskforceKit
@testable import Taskforce

/// 앱의 실제 launcher · 검사기 연결 (OA D4a2-06 · 07, 격리 호스트). 터미널 열기는 가짜다 — 실제 Terminal · `claude` 실행이 0이고, `.command`는 임시 폴더에만 만든다
struct AgentTerminalLauncherTests {
    final class Opener: AgentTerminalOpening, @unchecked Sendable {
        private let lock = NSLock()
        private var _opened: [URL] = []
        var opened: [URL] { lock.withLock { _opened } }
        func open(_ file: URL) async -> Bool {
            lock.withLock { _opened.append(file) }
            return true
        }
    }

    @Test func theCommandFilesLiveInATerminalFolderUnderTheAppsOwnSupportFolder() throws {
        let directory = try #require(AgentTerminalLauncherLive.commandDirectory())
        let bundle = try #require(Bundle.main.bundleIdentifier)
        #expect(directory.path.hasSuffix("/\(bundle)/Terminal"))
        #expect(bundle.hasPrefix("dev.taskforcelabs.unittest"), "시험은 격리된 번들 id로만 돈다: 실사용 폴더를 건드리지 않는다")
    }

    @Test func withoutAnActiveRuntimeTheLauncherCannotOpenAndNothingIsWritten() async throws {
        let temp = FileManager.default.temporaryDirectory.appending(path: "terminal-launcher-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temp) }
        let opener = Opener()
        let launcher = try #require(AgentTerminalLauncherLive.launcher(directory: temp, opener: opener))
        #expect(await !launcher.canOpen(sessionID: UUID()), "이 Mac이 모르는 세션: 서버 호출 전에 막힌다")
        await #expect(throws: AgentTerminalCommandError.self) { try await launcher.open(sessionID: UUID()) }
        #expect(opener.opened.isEmpty && !FileManager.default.fileExists(atPath: temp.path))
    }

    @Test func withNoDirectoryThereIsNoLauncherSoNoPillIsDrawn() {
        #expect(AgentTerminalLauncherLive.launcher(directory: nil) == nil)
    }

    @Test func theInspectorFindsNothingForASessionTheMacDoesNotKnow() async {
        #expect(await !AgentTerminalLauncherLive.inspector().hasProcess(resuming: UUID()))
    }
}
