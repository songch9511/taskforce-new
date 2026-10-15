import Darwin
import Foundation
import Testing
import TaskforceKit
@testable import Taskforce

/// Claude Code adapter의 앱 쪽 (OA D3a 계약 4.4 M1–M5, 격리 `Debug-Test` 호스트). 실제 `claude` · 실사용 `~/.claude` · Application Support 0:
/// 가짜 `claude`(Xcode 시험 전용 tool 타깃)는 임시 홈에 복사하고, 소켓은 임시 폴더에 연다
@MainActor
@Suite(.serialized)
struct ClaudeCodeHostTests {
    /// 이 시험 호스트(Debug-Test로 빌드한 Taskforce.app)
    static var app: URL { Bundle.main.bundleURL }
    static var helpers: URL { app.appending(path: "Contents/Helpers", directoryHint: .isDirectory) }

    // MARK: M1 · M2 번들에 helper 둘

    @Test func theBuiltHostCarriesBothHelpersAsExecutables() throws {
        for name in ["tf-agent-hook", "tf-agent-mcp"] {
            let path = Self.helpers.appending(path: name).path
            #expect(FileManager.default.isExecutableFile(atPath: path), "\(path)")
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            #expect((attributes[.posixPermissions] as? Int ?? 0) & 0o111 != 0)
        }
        #expect(ClaudeCodeHelpers.inBundle(.main) == ClaudeCodeHelpers(hook: Self.helpers.appending(path: "tf-agent-hook").path, mcp: Self.helpers.appending(path: "tf-agent-mcp").path))
    }

    @Test func theEmbeddedHookDeniesWithinTheBudgetWhenThereIsNoSocket() async throws {
        let process = Process()
        process.executableURL = Self.helpers.appending(path: "tf-agent-hook")
        process.arguments = ["pre-tool-use", "--socket", "/tmp/tf-none-\(UUID().uuidString.prefix(6))/hook.sock", "--session", "5e551011-0000-4000-8000-000000000001", "--nonce", "Zm9v"]
        process.environment = ["HOME": NSTemporaryDirectory(), "PATH": "/usr/bin:/bin"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let started = Date()
        try process.run()
        input.fileHandleForWriting.write(Data(#"{"session_id":"s","cwd":"/c","permission_mode":"default","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"/w/a","content":"x"},"tool_use_id":"toolu_1"}"#.utf8))
        try input.fileHandleForWriting.close()
        let box = HostProcessBox(process)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                box.process.waitUntilExit()
                continuation.resume()
            }
        }
        #expect(Date().timeIntervalSince(started) < 1.6)
        #expect(process.terminationStatus == 0)
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(text.contains(#""permissionDecision":"deny""#), "\(text)")
    }

    // MARK: M3 내장 helper + 가짜 claude로 E2 · E3

    @Test func embeddedHelpersCarryAQuestionAndAnApprovalThroughTheAdapter() async throws {
        let world = try HostClaudeWorld()
        defer { world.cleanup() }
        try world.scenario(["runs": [
            ["steps": [["tool": "mcp__tf__ask_user", "id": "toolu_q", "input": ["questions": [["id": "color", "text": "Which color?", "options": [["label": "red"], ["label": "blue"]]]]]]]],
            ["steps": [["tool": "Write", "id": "toolu_w", "input": ["file_path": world.workspace + "/out.txt", "content": "hi"]]]],
            ["final_text": "Done."],
        ]])
        // E2: 질문 → 답
        let first = HostEvents()
        let identity = try await world.process.startTurn(world.turn("Ask me", external: nil), events: first.sink)
        #expect(await first.waitEnded())
        #expect(first.questions.map(\.providerRequestID) == ["toolu_q"])
        let session = String(identity.externalTaskID?.split(separator: ":").first ?? "")
        let second = HostEvents()
        let answered = try await world.process.deliverAnswer(world.answer("toolu_q", .input, AgentAnswerValue(answers: ["color": .one("blue")]), external: session), events: second.sink)
        guard case .delivered = answered else {
            Issue.record("\(answered)")
            return
        }
        #expect(await second.waitEnded())
        // 답 resume에서 모델이 Write를 냈다 → 서버(대본)가 defer → 승인 질문
        #expect(second.questions.map(\.kind) == [.approval])
        #expect(world.mcpResults.first == #"The user answered: {"color":"blue"}"#)
        // E3: 승인 → 쓰기
        let third = HostEvents()
        let approved = try await world.process.deliverAnswer(world.answer("toolu_w", .approval, AgentAnswerValue(answers: ["approval": .one("allow")]), external: session), events: third.sink)
        guard case .delivered = approved else {
            Issue.record("\(approved)")
            return
        }
        #expect(await third.waitEnded())
        #expect((try? String(contentsOfFile: world.workspace + "/out.txt", encoding: .utf8)) == "hi")
        #expect(third.all.contains { if case .artifact(let path, _, _) = $0 { path == "out.txt" } else { false } })
        #expect(third.all.contains(.turnCompleted))
        #expect(world.decisionCalls == 1, "승인 resume에서 서버 호출 0")
    }

    // MARK: M4 adapter 선택 · 소켓 수명

    @Test func adaptersFollowTheBuildAndTheDebugArguments() {
        let local = URL(string: "http://localhost:3000")!
        let production = URL(string: "https://api.taskforcelabs.dev")!
        let everything: [String: Any] = ["TF_BRIDGE_REAL_AGENT": "YES", "TF_BRIDGE_FAKE_AGENT": "YES", "TF_BRIDGE_WORKSPACE": "/tmp/x"]
        #expect(BridgeHost.agentChoice(isDebugBuild: false, arguments: everything, apiBaseURL: production) == .claudeCode(disposableWorkspace: nil), "Release: 실제 adapter 하나, 인자 무시")
        #expect(BridgeHost.agentChoice(isDebugBuild: false, arguments: [:], apiBaseURL: local) == .claudeCode(disposableWorkspace: nil))
        #expect(BridgeHost.agentChoice(isDebugBuild: true, arguments: [:], apiBaseURL: local) == .none)
        #expect(BridgeHost.agentChoice(isDebugBuild: true, arguments: ["TF_BRIDGE_FAKE_AGENT": "YES"], apiBaseURL: local) == .fake)
        #expect(BridgeHost.agentChoice(isDebugBuild: true, arguments: ["TF_BRIDGE_REAL_AGENT": "YES", "TF_BRIDGE_WORKSPACE": "/tmp/x"], apiBaseURL: local) == .claudeCode(disposableWorkspace: "/tmp/x"))
        #expect(BridgeHost.agentChoice(isDebugBuild: true, arguments: ["TF_BRIDGE_REAL_AGENT": "YES"], apiBaseURL: production) == .none, "Debug 실제 adapter는 loopback 서버에서만")
    }

    @Test func aDisabledBridgeOpensNoSocketAndAnEnabledOneOpensAPrivateSocket() throws {
        let folder = URL(fileURLWithPath: ClaudeHostPaths.real(NSTemporaryDirectory())).appending(path: "tfm-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appending(path: "hook.sock").path
        #expect(BridgeHost.startHookServer(enabled: false, path: path, log: NoBridgeLog()) == nil)
        #expect(!FileManager.default.fileExists(atPath: path), "꺼진 bridge는 소켓 파일 0")
        let server = try #require(BridgeHost.startHookServer(enabled: true, path: path, log: NoBridgeLog()))
        var info = stat()
        #expect(lstat(path, &info) == 0 && info.st_mode & 0o777 == 0o600)
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func theHostClosesItsSocketWhenItStopsObserving() throws {
        let folder = URL(fileURLWithPath: ClaudeHostPaths.real(NSTemporaryDirectory())).appending(path: "tfm-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appending(path: "hook.sock").path
        let server = try #require(BridgeHost.startHookServer(enabled: true, path: path, log: NoBridgeLog()))
        let fixture = HostFixture(enabled: true)
        defer { fixture.cleanup() }
        let host = BridgeHost(
            enabled: true, apiBaseURL: fixture.server.baseURL, storageRoot: fixture.root, credentials: fixture.credentials, currentUser: { nil },
            factory: { _, _, _, _ in throw CancellationError() }, quitPrompt: fixture.prompt, reply: { _ in }, notificationCenter: NotificationCenter(), hookServer: server
        )
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(host.terminationReply() == .terminateNow)
        #expect(!FileManager.default.fileExists(atPath: path), "앱 종료 때 소켓을 닫는다")
    }

    // MARK: M5 일회용 작업 폴더

    @Test func theDisposableResolverAcceptsOnlyAMarkedFolderOutsideAnyRepositoryOrClaudeHome() throws {
        let root = URL(fileURLWithPath: ClaudeHostPaths.real(NSTemporaryDirectory())).appending(path: "tfd-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        let local = URL(string: "http://localhost:3000")!
        func folder(_ relative: String, marker: Bool = true) throws -> String {
            let url = root.appending(path: relative, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            if marker { try Data().write(to: url.appending(path: ".taskforce-disposable")) }
            return url.path
        }
        let good = try folder("tf-d3a/proj")
        #expect(DisposableWorkspaces.make(path: good, apiBaseURL: local, home: home.path)?.path == good)
        #expect(DisposableWorkspaces.make(path: good, apiBaseURL: URL(string: "https://api.taskforcelabs.dev")!, home: home.path) == nil, "loopback 서버만")
        #expect(DisposableWorkspaces.make(path: try folder("plain", marker: false), apiBaseURL: local, home: home.path) == nil, "표식 없는 폴더")
        let repo = try folder("repo/sub")
        try FileManager.default.createDirectory(at: root.appending(path: "repo/.git", directoryHint: .isDirectory), withIntermediateDirectories: true)
        #expect(DisposableWorkspaces.make(path: repo, apiBaseURL: local, home: home.path) == nil, "저장소 안")
        let claude = try folder("home/.claude/projects/x")
        #expect(DisposableWorkspaces.make(path: claude, apiBaseURL: local, home: home.path) == nil, "~/.claude 안")
        #expect(DisposableWorkspaces.make(path: nil, apiBaseURL: local, home: home.path) == nil)
        #expect(DisposableWorkspaces.make(path: "relative/proj", apiBaseURL: local, home: home.path) == nil)
    }
}

enum ClaudeHostPaths {
    static func real(_ path: String) -> String { GateFileSystem.realpath(path) ?? path }
}

final class HostProcessBox: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }
}

/// 사건을 모으는 싱크 (M3)
final class HostEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AgentEvent] = []

    var sink: AgentEventSink { AgentEventSink { [self] event, _ in lock.withLock { events.append(event) } } }
    var all: [AgentEvent] { lock.withLock { events } }
    var questions: [AgentQuestion] { all.compactMap { if case .question(let question) = $0 { question } else { nil } } }

    func waitEnded(timeout: TimeInterval = 20) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if all.contains(where: { if case .ended = $0 { true } else { false } }) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

/// 내장 helper + 가짜 `claude` + 임시 홈 · 작업 폴더 · 소켓 (M3)
final class HostClaudeWorld: @unchecked Sendable {
    let root: URL
    let home: URL
    let workspace: String
    let socketFolder: URL
    let server: HookSocketServer
    let process: ClaudeCodeProcess
    private let lock = NSLock()
    private var calls = 0

    init() throws {
        root = URL(fileURLWithPath: ClaudeHostPaths.real(NSTemporaryDirectory())).appending(path: "tfw-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        home = root.appending(path: "home", directoryHint: .isDirectory)
        let work = root.appending(path: "work", directoryHint: .isDirectory)
        workspace = work.path
        for folder in [home.appending(path: ".local/bin"), home.appending(path: ".fake-claude"), work] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        // Xcode가 시험 의존으로 빌드한 가짜 `claude` (앱 번들 밖, 같은 빌드 폴더)
        let fake = Bundle.main.bundleURL.deletingLastPathComponent().appending(path: "FakeClaudeCode")
        let claude = home.appending(path: ".local/bin/claude")
        try FileManager.default.copyItem(at: fake, to: claude)
        socketFolder = URL(fileURLWithPath: ClaudeHostPaths.real(NSTemporaryDirectory())).appending(path: "tfh-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        server = HookSocketServer(path: socketFolder.appending(path: "hook.sock").path)
        try server.start()
        process = ClaudeCodeProcess(
            sessionsRoot: root.appending(path: "ledger/claude-code", directoryHint: .isDirectory), hookServer: server, helpers: .inBundle(.main),
            locator: ClaudeCodeLocator(candidates: [claude.path], confinedTo: root.path),
            environment: ["HOME": home.path, "USER": NSUserName(), "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"],
            managedSettingsPath: root.appending(path: "managed-settings.json").path
        )
        process.attach(AgentRuntimeServices { [self] _ in
            lock.withLock { calls += 1 }
            return BridgeV1ToolDecisionResponse(decision: .defer, reason: .manualWrite, parse: nil, agentNote: nil, holder: nil, cardFlags: [], serverTime: Date())
        })
    }

    var decisionCalls: Int { lock.withLock { calls } }

    func scenario(_ value: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: value).write(to: home.appending(path: ".fake-claude/scenario.json"))
    }

    var mcpResults: [String] {
        (1...4).flatMap { number -> [String] in
            let url = home.appending(path: ".fake-claude/report-\(number).json")
            let report = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any]
            return report?["mcp_results"] as? [String] ?? []
        }
    }

    func turn(_ text: String, external: String?) -> AgentTurnStart {
        AgentTurnStart(
            taskID: "7a5c0001-0000-4000-8000-000000000001", sessionID: "5e551011-0000-4000-8000-000000000001", turnSeq: 1, adapter: "agent:claude-code",
            externalSessionID: external, workspaceRef: workspace, resume: external != nil, access: .write, policyMode: .manual, marker: UUID().uuidString.lowercased(), text: text
        )
    }

    func answer(_ requestID: String, _ kind: BridgeV1PendingQuestionKind, _ value: AgentAnswerValue, external: String) -> AgentAnswerDelivery {
        AgentAnswerDelivery(
            taskID: "7a5c0001-0000-4000-8000-000000000001", sessionID: "5e551011-0000-4000-8000-000000000001", turnSeq: 1, adapter: "agent:claude-code",
            externalSessionID: external, workspaceRef: workspace, marker: UUID().uuidString.lowercased(), access: .write, policyMode: .manual, requestID: requestID, kind: kind,
            structured: true, value: value
        )
    }

    func cleanup() {
        server.stop()
        try? FileManager.default.removeItem(at: socketFolder)
        try? FileManager.default.removeItem(at: root)
    }
}
