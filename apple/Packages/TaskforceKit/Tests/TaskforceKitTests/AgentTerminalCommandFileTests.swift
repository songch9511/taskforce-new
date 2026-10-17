#if os(macOS) && DEBUG
import Darwin
import Foundation
import Testing
@testable import TaskforceKit

/// Open in Terminal의 `.command` 파일 · launcher · 프로세스 검사기 (OA D4a2-06 · 07, 계약 13.6 "launcher" · "검사기"). 실제 터미널 · `claude` 실행 0: 열기는 가짜다
struct AgentTerminalCommandFileTests {
    static let target = AgentTerminalTarget(
        providerSessionID: "c0ffee00-0000-4000-8000-000000000001", folder: "/Users/tester/Documents/client-a", executableRealPath: "/Users/tester/.local/share/claude/versions/2.1.241",
        sessionCwd: "/Users/tester/Library/Application Support/dev.taskforcelabs.taskforce/Bridge/v1/p/claude-code/5e551011-0000-4000-8000-000000000001/cwd"
    )

    final class FakeOpener: AgentTerminalOpening, @unchecked Sendable {
        private let lock = NSLock()
        private var _opened: [URL] = []
        var result = true
        var opened: [URL] { lock.withLock { _opened } }
        func open(_ file: URL) async -> Bool {
            lock.withLock { _opened.append(file) }
            return result
        }
    }

    static func mode(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    // MARK: 내용

    @Test func theCommandFileResumesFromTheSessionCwdAndPassesTheWorkFolderAgain() throws {
        let contents = try AgentTerminalCommandFile.contents(for: Self.target)
        #expect(contents == """
        #!/bin/sh
        cd '/Users/tester/Library/Application Support/dev.taskforcelabs.taskforce/Bridge/v1/p/claude-code/5e551011-0000-4000-8000-000000000001/cwd' && exec '/Users/tester/.local/share/claude/versions/2.1.241' --resume 'c0ffee00-0000-4000-8000-000000000001' --add-dir '/Users/tester/Documents/client-a'

        """)
        #expect(contents.split(separator: "\n").count == 2)
        // 터미널은 사용자가 이어받은 것이다: Taskforce의 훅 · 설정 · MCP를 다시 주지 않는다
        for forbidden in ["--settings", "--mcp-config", "--setting-sources", "--session-id", "--permission-mode", "-p "] {
            #expect(!contents.contains(forbidden), "\(forbidden)")
        }
        // 작업 폴더가 아니라 세션 cwd에서 시작한다 (대화 기록이 cwd별이다)
        #expect(!contents.contains("cd '/Users/tester/Documents/client-a'"))
    }

    @Test func aValueTheShellCouldReadAsSomethingElseMakesNoFile() async throws {
        for bad in ["/Users/o'brien/p", "/Users/x/a\nb", "/Users/x/a\rb", "/Users/x/a\u{0}b", "/Users/x/a\tb", "", "/Users/x/a\u{7f}b"] {
            var target = Self.target
            target.folder = bad
            let broken = target
            #expect(throws: AgentTerminalCommandError.unquotable, "folder \(bad.debugDescription)") { try AgentTerminalCommandFile.contents(for: broken) }
        }
        var cwd = Self.target
        cwd.sessionCwd = "/Users/o'brien/Library/Application Support/x/cwd"
        let brokenCwd = cwd
        #expect(throws: AgentTerminalCommandError.unquotable, "세션 cwd에 작은따옴표") { try AgentTerminalCommandFile.contents(for: brokenCwd) }
        var executable = Self.target
        executable.executableRealPath = "/opt/it's/claude"
        let brokenExecutable = executable
        #expect(throws: AgentTerminalCommandError.unquotable) { try AgentTerminalCommandFile.contents(for: brokenExecutable) }
        var session = Self.target
        session.providerSessionID = "id'; rm -rf ~ #"
        let brokenSession = session
        #expect(throws: AgentTerminalCommandError.unquotable) { try AgentTerminalCommandFile.contents(for: brokenSession) }
    }

    @Test func aFolderNameWithShellSyntaxIsQuotedNotInterpreted() throws {
        var target = Self.target
        target.folder = "/Users/tester/Documents/$(touch pwned); `id` & x"
        let contents = try AgentTerminalCommandFile.contents(for: target)
        #expect(contents.hasSuffix(" --add-dir '/Users/tester/Documents/$(touch pwned); `id` & x'\n"))
    }

    // MARK: 파일

    @Test func theFileIsCreatedOwnerOnlyInAnOwnerOnlyFolderWithTheExactContents() throws {
        let temp = TempDirectory()
        let store = AgentTerminalCommandStore(directory: temp.appending("Terminal"))
        let file = try store.write("#!/bin/sh\necho hi\n")
        #expect(file.pathExtension == "command" && file.deletingLastPathComponent().lastPathComponent == "Terminal")
        #expect(UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil)
        #expect(try Self.mode(file) == 0o700, "0700")
        #expect(try Self.mode(file.deletingLastPathComponent()) == 0o700)
        #expect(try String(contentsOf: file, encoding: .utf8) == "#!/bin/sh\necho hi\n")
        #expect(FileManager.default.isExecutableFile(atPath: file.path))
    }

    @Test func aLooseFolderModeIsTightenedAndASymlinkedFolderIsRefused() throws {
        let temp = TempDirectory()
        let loose = temp.appending("Loose")
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        _ = try AgentTerminalCommandStore(directory: loose).write("x")
        #expect(try Self.mode(loose) == 0o700)
        // 폴더 자리에 기호 링크가 있다 (다른 곳에 파일을 쓰게 하려는 시도)
        let elsewhere = temp.appending("Elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let link = temp.appending("Terminal")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)
        #expect(throws: AgentTerminalCommandError.storeUnavailable) { try AgentTerminalCommandStore(directory: link).write("x") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty, "기호 링크 너머에는 쓰지 않는다")
    }

    @Test func sweepRemovesOnlyCommandFilesOlderThanTenMinutes() throws {
        let temp = TempDirectory()
        let directory = temp.appending("Terminal")
        let now = Date()
        let store = AgentTerminalCommandStore(directory: directory, now: { now })
        let fresh = try store.write("fresh")
        let old = try store.write("old")
        let stale = try store.write("stale")
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-601)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3600)], ofItemAtPath: stale.path)
        let other = directory.appending(path: "notes.txt")
        try Data("keep".utf8).write(to: other)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-9999)], ofItemAtPath: other.path)
        // 오래된 .command 이름의 기호 링크는 따라가지 않는다
        let target = temp.appending("precious")
        try Data("precious".utf8).write(to: target)
        let link = directory.appending(path: "link.command")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(store.sweep() == 2)
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(!FileManager.default.fileExists(atPath: old.path) && !FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: other.path), ".command가 아닌 파일은 남는다")
        #expect(FileManager.default.fileExists(atPath: target.path), "기호 링크 너머의 파일은 지우지 않는다")
        #expect(AgentTerminalCommandStore(directory: temp.appending("none")).sweep() == 0, "폴더가 없어도 조용하다")
    }

    // MARK: launcher

    @Test func openingWritesTheFileAndHandsItToTheDefaultAppOnce() async throws {
        let temp = TempDirectory()
        let opener = FakeOpener()
        let store = AgentTerminalCommandStore(directory: temp.appending("Terminal"))
        let launcher = CommandFileTerminalLauncher(target: { _ in Self.target }, store: store, opener: opener)
        let session = UUID()
        #expect(await launcher.canOpen(sessionID: session))
        try await launcher.open(sessionID: session)
        let file = try #require(opener.opened.first)
        #expect(opener.opened.count == 1)
        #expect(try Self.mode(file) == 0o700)
        #expect(try String(contentsOf: file, encoding: .utf8) == (try AgentTerminalCommandFile.contents(for: Self.target)))
    }

    @Test func anUnquotableFolderMakesNoFileAndNoOpenAndCanOpenIsFalse() async throws {
        let temp = TempDirectory()
        let opener = FakeOpener()
        var broken = Self.target
        broken.folder = "/Users/tester/it's here"
        let bad = broken
        let launcher = CommandFileTerminalLauncher(target: { _ in bad }, store: AgentTerminalCommandStore(directory: temp.appending("Terminal")), opener: opener)
        #expect(await !launcher.canOpen(sessionID: UUID()))
        await #expect(throws: AgentTerminalCommandError.unquotable) { try await launcher.open(sessionID: UUID()) }
        #expect(opener.opened.isEmpty, "열기 0")
        #expect(!FileManager.default.fileExists(atPath: temp.appending("Terminal").path), "파일 0 (폴더도 만들지 않는다)")
    }

    @Test func noMacStateMeansCannotOpenAndNothingHappens() async throws {
        let temp = TempDirectory()
        let opener = FakeOpener()
        let launcher = CommandFileTerminalLauncher(target: { _ in nil }, store: AgentTerminalCommandStore(directory: temp.appending("Terminal")), opener: opener)
        #expect(await !launcher.canOpen(sessionID: UUID()))
        await #expect(throws: AgentTerminalCommandError.self) { try await launcher.open(sessionID: UUID()) }
        #expect(opener.opened.isEmpty)
    }

    @Test func aFileTheTerminalCouldNotOpenIsRemoved() async throws {
        let temp = TempDirectory()
        let opener = FakeOpener()
        opener.result = false
        let directory = temp.appending("Terminal")
        let launcher = CommandFileTerminalLauncher(target: { _ in Self.target }, store: AgentTerminalCommandStore(directory: directory), opener: opener)
        await #expect(throws: AgentTerminalCommandError.openFailed) { try await launcher.open(sessionID: UUID()) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func openingSweepsOldFilesFirst() async throws {
        let temp = TempDirectory()
        let directory = temp.appending("Terminal")
        let now = Date()
        let store = AgentTerminalCommandStore(directory: directory, now: { now })
        let old = try store.write("old")
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-700)], ofItemAtPath: old.path)
        let launcher = CommandFileTerminalLauncher(target: { _ in Self.target }, store: store, opener: FakeOpener())
        try await launcher.open(sessionID: UUID())
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }

    /// 알약 흐름: launcher의 미리 조건이 false면 서버를 부르지 않는다 (D4a-15 순서)
    @MainActor
    @Test func whenTheLauncherCannotOpenTheServerIsNeverCalled() async throws {
        let requests = FakeAgentSessionRequests()
        let counter = Locked<Int>(0)
        requests.openHandler = { id in
            counter.set(counter.get() + 1)
            return AgentSessionResponse(session: FakeAgentSessionRequests.row(.external, id: id))
        }
        let temp = TempDirectory()
        let launcher = CommandFileTerminalLauncher(target: { _ in nil }, store: AgentTerminalCommandStore(directory: temp.appending("Terminal")), opener: FakeOpener())
        let flow = AgentSessionPillFlow(requests: requests, launcher: launcher, scope: ChatTestAccount.fixedScope())
        #expect(flow.offersOpenInTerminal)
        await flow.openInTerminal(SessionFx.item(SessionFx.snapshot(status: .bound, state: .idle)))
        #expect(counter.get() == 0, "서버 호출 0")
    }

    // MARK: 검사기

    @Test func withoutStateTheInspectorFindsNothingAndNeverScans() async {
        let scans = Locked<Int>(0)
        let inspector = ClaudeResumeProcessInspector(providerSession: { _ in nil }, scan: { _ in scans.set(scans.get() + 1); return true })
        #expect(await !inspector.hasProcess(resuming: UUID()), "상태가 없으면 false다 (증명이 아니다)")
        #expect(scans.get() == 0)
    }

    @Test func theInspectorScansWithTheMacStateIDOnAnInjectedRunnerOffTheMainThread() async {
        let seen = Locked<[String]>([])
        let runOnMain = Locked<[Bool]>([])
        let inspector = ClaudeResumeProcessInspector(
            providerSession: { _ in "claude-id-1" },
            scan: { id in seen.set(seen.get() + [id]); return id == "claude-id-1" },
            run: { work in
                await Task.detached { runOnMain.set(runOnMain.get() + [pthread_main_np() != 0]); return work() }.value
            }
        )
        #expect(await inspector.hasProcess(resuming: UUID()))
        #expect(seen.get() == ["claude-id-1"] && runOnMain.get() == [false])
    }
}
#endif
