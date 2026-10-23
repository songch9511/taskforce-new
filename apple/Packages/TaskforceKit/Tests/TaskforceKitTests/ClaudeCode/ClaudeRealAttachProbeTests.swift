#if os(macOS) && DEBUG
import Darwin
import Foundation
import Synchronization
import Testing
import TaskforceAgentWire
@testable import TaskforceKit

/// 실제 `claude` 한 번 (OA 외부 세션 PR2m, "일회용 세션만"): 이어받은 세션의 resume 인자(빈 `--setting-sources` · `--system-prompt-snapshot off` · `--append-system-prompt-file` · cwd = 원래 폴더)가
/// 실제 CLI에서 같은 세션을 이어 쓰는지 본다. **평소에는 돌지 않는다**: `TF_REAL_CLAUDE_PROBE_DIR`에 `~/tf-attach-probe-*` 이름의 **새 일회용 폴더**를 줄 때만 돈다.
/// 일회용 세션을 이 시험이 직접 만들고(모델 호출 1) 그것을 이어 쓴다(모델 호출 1). 사용자의 실제 세션은 읽지도 말을 걸지도 않는다:
/// 등록 폴더 · 프로세스 목록 읽기를 이 시험의 프로세스 하나로 좁혀 쓴다 (`restricted…`). 글(응답 · 대화)은 어디에도 찍지 않는다 — 사실(같은 id · 줄 수 · 표지 여부)만 본다
@Suite(.serialized)
struct ClaudeRealAttachProbeTests {
    private static let home = NSHomeDirectory()
    private static let claude = home + "/.local/bin/claude"
    private static var folder: String? {
        guard let path = ProcessInfo.processInfo.environment["TF_REAL_CLAUDE_PROBE_DIR"], path.hasPrefix(home + "/tf-attach-probe-"), !path.dropFirst(home.count + 1).contains("/"),
              FileManager.default.isExecutableFile(atPath: claude) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return path
    }

    static let marker = "MARK-7f3a"

    private final class Pid: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int32?
        var current: Int32? { lock.withLock { value } }
        func set(_ pid: Int32) { lock.withLock { value = pid } }
    }

    /// 이 시험이 띄운 프로세스 하나의 등록 파일만 보이는 파일 시스템 · 프로세스 사실 (다른 세션의 등록 파일 · argv는 읽지 않는다)
    private static func restricted(pid: Pid) -> (ExternalSessionFileSystem, ExternalSessionProcessFacts) {
        let base = ExternalSessionFileSystem.live
        let fileSystem = ExternalSessionFileSystem(
            userID: base.userID, realpath: base.realpath, lstat: base.lstat,
            list: { path, limit in
                let result = base.list(path, limit)
                guard path.hasSuffix("/.claude/sessions"), case .entries(let items) = result else { return result }
                return .entries(items.filter { item in pid.current.map { item.name == "\($0).json" } ?? false })
            },
            read: { path, offset, length in
                if path.contains("/.claude/sessions/") { return pid.current.flatMap { path.hasSuffix("/\($0).json") ? base.read(path, offset, length) : nil } }
                return base.read(path, offset, length)
            }
        )
        let facts = ExternalSessionProcessFacts(
            userID: getuid(), lookup: ExternalSessionProcessFacts.live.lookup, argumentSessionIDs: { _ in [] }, unregisteredClaudeFolders: { _, _ in [] }
        )
        return (fileSystem, facts)
    }

    @Test(.enabled(if: ClaudeRealAttachProbeTests.folder != nil)) func aThrowawayClaudeSessionIsResumedInItsOriginalFolderWithTheIsolatedArguments() async throws {
        let folder = try #require(Self.folder)
        let id = UUID().uuidString.lowercased()
        let executable = try #require(ClaudeCodeLocator.standard(home: Self.home).locate())
        let childEnvironment = ClaudeCodeEnvironment.child(app: ProcessInfo.processInfo.environment, executable: executable)
        try Data("Always end every reply with the exact word \(Self.marker).\n".utf8).write(to: URL(fileURLWithPath: folder + "/CLAUDE.md"))
        let pid = Pid()
        let (fileSystem, facts) = Self.restricted(pid: pid)
        let live = LiveExternalWriterCheck(claudeDirectory: Self.home + "/.claude", facts: facts, fileSystem: fileSystem)

        // 1) 일회용 세션을 만든다 (모델 호출 1): 도는 동안 실제 등록 파일로 외부 writer 검사가 쥔 곳을 보는지 본다
        var seen = Set<String>()
        let creator = Task.detached { [claude = Self.claude] () -> Int32 in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: claude)
            process.arguments = ["-p", "--session-id", id, "--max-budget-usd", "1", "--output-format", "json", "Reply with exactly: PONG-CREATE"]
            process.currentDirectoryURL = URL(fileURLWithPath: folder)
            process.environment = childEnvironment
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { return -1 }
            pid.set(process.processIdentifier)
            process.waitUntilExit()
            return process.terminationStatus
        }
        let started = Date()
        while Date().timeIntervalSince(started) < 90 {
            if let value = pid.current, kill(value, 0) != 0 { break }
            if pid.current != nil {
                switch await live.check(sessionID: id, workspace: folder, ownPIDs: [], ownLastActivity: nil) {
                case .free: seen.insert("free")
                case .held: seen.insert("held")
                case .unknown: seen.insert("unknown")
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(await creator.value == 0, "일회용 세션을 만들었다")
        let transcript = Self.home + "/.claude/projects/" + (ExternalSessionRules.projectDirectoryName(forCwd: folder) ?? "-") + "/" + id + ".jsonl"
        #expect(FileManager.default.fileExists(atPath: transcript), "기록이 원래 폴더의 프로젝트 디렉터리에 생겼다")
        #expect(seen.contains("held"), "도는 동안 실제 등록 파일로 그 세션을 쥔 곳이 보였다: \(seen.sorted())")
        let linesBefore = Self.lineCount(transcript)
        // 프로세스가 끝난 뒤 기록이 방금 쓰였다: 60초 창 안이라 지금은 쥔 곳이 있다(unknown holder)고 본다 — 우리 쓰기가 아님을 모를 때의 fail-closed
        #expect(await live.check(sessionID: id, workspace: folder, ownPIDs: [], ownLastActivity: nil) == .held(.unknown), "방금 쓰인 기록은 주인을 몰라도 막는다")
        #expect(await live.check(sessionID: id, workspace: folder, ownPIDs: [], ownLastActivity: Date()) == .free, "그 쓰기가 우리 것이라고 알리면(우리 마지막 활동) 쥔 곳이 없다")

        // 2) 같은 세션을 이어받은 세션으로 이어 쓴다 (모델 호출 1): 실제 어댑터 · 지킴이 · helper · 훅 소켓
        let root = FileManager.default.temporaryDirectory.appending(path: "tfrp-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        let sessionsRoot = root.appending(path: "claude-code", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let agentSession = "5e551011-0000-4000-8000-0000000000f1"
        let sessionFolder = try ClaudeSessionFolder.prepare(sessionsRoot: sessionsRoot, agentSessionID: agentSession)
        #expect(ClaudeSessionState.writeAttached(providerSessionID: id, at: Date(), in: sessionFolder.root) == .written)
        let socketFolder = URL(fileURLWithPath: ClaudeSandbox.real(NSTemporaryDirectory())).appending(path: "tfh-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        let server = HookSocketServer(path: socketFolder.appending(path: "hook.sock").path, responseBudget: ClaudeTest.socketBudgets.response, readBudget: ClaudeTest.socketBudgets.read)
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: socketFolder)
        }
        let log = CapturingLog()
        let adapter = ClaudeCodeProcess(
            sessionsRoot: sessionsRoot, hookServer: server,
            helpers: ClaudeCodeHelpers(hook: try BuiltProducts.url("tf-agent-hook").path, mcp: try BuiltProducts.url("tf-agent-mcp").path, keeper: try BuiltProducts.url("tf-agent-keeper").path),
            locator: .standard(home: Self.home), log: log, externalWriters: live
        )
        adapter.attach(AgentRuntimeServices(decideTool: ScriptedDecider().function))
        // 이 시험의 첫 프로세스가 끝났다: 우리 마지막 활동은 그 시각이다 (런타임 밖이라 어댑터의 기억이 없다 → 60초 창이 지나기를 기다린다)
        let waitUntil = Date().addingTimeInterval(65)
        while Date() < waitUntil { try await Task.sleep(for: .seconds(1)) }
        let events = EventLog()
        _ = try await adapter.startTurn(AgentTurnStart(
            taskID: "7a5c0001-0000-4000-8000-0000000000f1", sessionID: agentSession, turnSeq: 1, adapter: "agent:claude-code", externalSessionID: id, workspaceRef: folder, resume: true,
            access: .readOnly, policyMode: .manual, marker: UUID().uuidString.lowercased(), text: "Say hello in one short sentence and follow the project instructions you were given."
        ), events: events.sink)
        #expect(await events.wait(timeout: 120) { FakeClaude.ended($0) })
        #expect(events.contains(.turnCompleted), "이어 쓴 턴이 끝났다")
        #expect(!events.all.contains { if case .sessionBound = $0 { true } else { false } }, "R9: init id가 같아 갈래(session_bound)가 없다")
        let reply = events.all.compactMap { event -> String? in if case .message(let text) = event { text } else { nil } }.joined()
        #expect(!reply.isEmpty, "응답을 받았다 (글은 찍지 않는다)")
        #expect(reply.contains(Self.marker), "Taskforce가 읽어 붙인 CLAUDE.md(빈 sources라 CLI는 읽지 않는다)가 --append-system-prompt-file + snapshot off로 먹었다")
        #expect(Self.lineCount(transcript) > linesBefore, "같은 기록 파일에 줄이 붙었다")
        let siblings = (try? FileManager.default.contentsOfDirectory(atPath: Self.home + "/.claude/projects/" + (ExternalSessionRules.projectDirectoryName(forCwd: folder) ?? "-"))) ?? []
        #expect(siblings.filter { $0.hasSuffix(".jsonl") } == [id + ".jsonl"], "갈래 파일이 없다")
        #expect(!FileManager.default.fileExists(atPath: sessionFolder.cwd.path), "빈 세션 cwd를 만들지 않았다")
        for line in log.lines { #expect(!line.contains(id) && !line.contains(folder), "로그에 id · 경로 0") }
        try? FileManager.default.removeItem(atPath: Self.home + "/.claude/projects/" + (ExternalSessionRules.projectDirectoryName(forCwd: folder) ?? "-"))
    }

    private static func lineCount(_ path: String) -> Int {
        guard let data = FileManager.default.contents(atPath: path) else { return 0 }
        return data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
    }
}
#endif
