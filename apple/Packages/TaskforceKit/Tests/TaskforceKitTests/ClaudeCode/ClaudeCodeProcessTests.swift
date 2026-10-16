#if os(macOS) && DEBUG
import CryptoKit
import Darwin
import Foundation
import Testing
import TaskforceAgentWire
@testable import TaskforceKit

/// 가짜 `claude` + 실제로 빌드한 helper 둘 + 실제 소켓으로 adapter 전체를 돌린다 (OA D3a 계약 4.3 E1–E23).
/// 시험 locator는 임시 폴더 안 실행 파일만 받는다 (실제 `claude` 실행 0). HOME도 임시라 실제 `~/.claude`를 읽거나 쓰지 않는다
final class FakeClaude: @unchecked Sendable {
    let box = ClaudeSandbox()
    let server: HookSocketServer
    let socketFolder: URL
    let decider: ScriptedDecider
    let log = CapturingLog()
    let process: ClaudeCodeProcess
    let claude: URL
    let helpers: ClaudeCodeHelpers
    let environment: [String: String]
    let timing: ClaudeCodeTiming

    /// - `linked`: 후보 `~/.local/bin/claude`가 실제 파일(`~/versions/claude-fake`)을 가리키는 기호 링크다 (8장 8)
    /// - `keeper`: 지킴이 대신 쓸 실행 파일 (없는 경로 · 늦게 뜨는 감싸개, 14장 1 · 9)
    init(
        decider: ScriptedDecider = ScriptedDecider(), environment extra: [String: String] = [:], hooks: ClaudeCodeTestHooks = ClaudeCodeTestHooks(), attach: Bool = true,
        timing: ClaudeCodeTiming = .testing, linked: Bool = false, keeper: String? = nil
    ) throws {
        self.decider = decider
        claude = box.home.appending(path: ".local/bin/claude")
        try FileManager.default.createDirectory(at: claude.deletingLastPathComponent(), withIntermediateDirectories: true)
        if linked {
            let real = box.home.appending(path: "versions/claude-fake")
            try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: try BuiltProducts.url("FakeClaudeCode"), to: real)
            try FileManager.default.createSymbolicLink(at: claude, withDestinationURL: real)
        } else {
            try FileManager.default.copyItem(at: try BuiltProducts.url("FakeClaudeCode"), to: claude)
        }
        try FileManager.default.createDirectory(at: box.home.appending(path: ".fake-claude"), withIntermediateDirectories: true)
        socketFolder = URL(fileURLWithPath: ClaudeSandbox.real(NSTemporaryDirectory())).appending(path: "tfh-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        let socket = socketFolder.appending(path: "hook.sock").path
        precondition(socket.utf8.count <= 103, "socket path must fit sun_path")
        server = HookSocketServer(path: socket)
        try server.start()
        let helpers = ClaudeCodeHelpers(
            hook: try BuiltProducts.url("tf-agent-hook").path, mcp: try BuiltProducts.url("tf-agent-mcp").path, keeper: try keeper ?? BuiltProducts.url("tf-agent-keeper").path
        )
        let environment = ["HOME": box.home.path, "USER": NSUserName(), "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"].merging(extra) { _, new in new }
        self.helpers = helpers
        self.environment = environment
        self.timing = timing
        process = ClaudeCodeProcess(
            sessionsRoot: box.sessionsRoot, hookServer: server, helpers: helpers, locator: ClaudeCodeLocator(candidates: [claude.path], confinedTo: box.root.path),
            environment: environment, managedSettingsPath: box.root.appending(path: "managed-settings.json").path, timing: timing, log: log, testHooks: hooks
        )
        if attach { process.attach(AgentRuntimeServices(decideTool: decider.function)) }
    }

    deinit {
        server.stop()
        try? FileManager.default.removeItem(at: socketFolder)
    }

    var workspace: String { box.workspacePath }

    /// 다시 뜬 앱의 adapter: 같은 세션 폴더 · 소켓 · 가짜 `claude`, 메모리는 비었다 (10장 7). `keeper`: 지킴이를 바꿔 띄운다
    func restarted(keeper: String? = nil, hooks: ClaudeCodeTestHooks = ClaudeCodeTestHooks()) -> ClaudeCodeProcess {
        let adapter = ClaudeCodeProcess(
            sessionsRoot: box.sessionsRoot, hookServer: server, helpers: ClaudeCodeHelpers(hook: helpers.hook, mcp: helpers.mcp, keeper: keeper ?? helpers.keeper),
            locator: ClaudeCodeLocator(candidates: [claude.path], confinedTo: box.root.path),
            environment: environment, managedSettingsPath: box.root.appending(path: "managed-settings.json").path, timing: timing, log: log, testHooks: hooks
        )
        adapter.attach(AgentRuntimeServices(decideTool: decider.function))
        return adapter
    }

    /// 서버가 `cat <name>`을 읽기 명령으로 허용한다 (작업 폴더의 파일을 만든다). 오래 도는 Bash는 대본의 `sleep`으로 흉내 낸다
    func allowReadonlyCat(_ name: String) {
        box.file(name)
        decider.push(.success(ScriptedDecider.response(.allow, .readonlyCommand, parse: BridgeV1ToolDecisionParse(
            wrapper: "none", argv: ["cat", name], paths: [.init(index: 1, absolute: workspace + "/" + name)], implicitCwd: false
        ))))
    }

    func scenario(_ value: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: value).write(to: box.home.appending(path: ".fake-claude/scenario.json"))
    }

    func report(_ number: Int) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: box.home.appending(path: ".fake-claude/report-\(number).json")))) as? [String: Any]
    }

    var runCount: Int { Int((try? String(contentsOf: box.home.appending(path: ".fake-claude/count"), encoding: .utf8)) ?? "0") ?? 0 }

    func turn(_ text: String = "Please help.", task: String = ClaudeTest.task, external: String? = nil, access: AgentAccess = .write, events: EventLog) async throws -> AgentProcessIdentity {
        try await process.startTurn(AgentTurnStart(
            taskID: task, sessionID: ClaudeTest.session, turnSeq: 1, adapter: "agent:claude-code", externalSessionID: external, workspaceRef: workspace, resume: external != nil,
            access: access, policyMode: .manual, marker: UUID().uuidString.lowercased(), text: text
        ), events: events.sink)
    }

    func answer(_ requestID: String, kind: BridgeV1PendingQuestionKind, value: AgentAnswerValue, external: String, task: String = ClaudeTest.task, events: EventLog) async throws -> AgentAnswerResult {
        try await process.deliverAnswer(AgentAnswerDelivery(
            taskID: task, sessionID: ClaudeTest.session, turnSeq: 1, adapter: "agent:claude-code", externalSessionID: external, workspaceRef: workspace,
            marker: UUID().uuidString.lowercased(), access: .write, policyMode: .manual, requestID: requestID, kind: kind, structured: true, value: value
        ), events: events.sink)
    }

    /// 그 실행의 Claude Code 세션 id (`<session>:<turn>`의 앞)
    static func providerSession(_ identity: AgentProcessIdentity) -> String {
        String(identity.externalTaskID?.split(separator: ":").first ?? "")
    }

    var state: ClaudeSessionState { ClaudeSessionState.load(from: box.sessionsRoot.appending(path: ClaudeTest.session)) }

    static func ended(_ events: [AgentEvent]) -> Bool { events.contains { if case .ended = $0 { true } else { false } } }

    static var askColor: [String: Any] { ["questions": [["id": "color", "header": "Color", "text": "Which color?", "options": [["label": "red"], ["label": "blue"]]]]] }
}

@Suite(.serialized)
struct ClaudeCodeProcessTests {
    // MARK: E1 정상 턴

    @Test func e1ANormalTurnIsBoundAcceptedMessagedAndCompleted() async throws {
        let fake = try FakeClaude()
        try fake.scenario(["runs": [["steps": [["text": "Hello there"]]]]])
        let events = EventLog()
        let identity = try await fake.turn("Summarize the notes.", events: events)
        #expect(await events.wait { FakeClaude.ended($0) })
        let session = FakeClaude.providerSession(identity)
        #expect(UUID(uuidString: session) != nil)
        #expect(events.all == [
            .inputReached, .sessionBound(externalSessionID: session, workspaceRef: fake.workspace), .accepted, .message(text: "Hello there"), .turnCompleted, .ended(AgentExit(code: 0)),
        ])
        #expect(identity.processMarker == identity.processMarker.uppercased() && UUID(uuidString: identity.processMarker) != nil)
        #expect(identity.externalTaskID == "\(session):1")
        let report = try #require(fake.report(0))
        #expect(report["stdin_bytes"] as? Int == "Summarize the notes.".utf8.count)
        #expect(report["resume"] as? Bool == false)
        #expect(report["tools"] as? String == "Read,Glob,Grep,Edit,Write,Bash")
        #expect(report["session_start_stdout"] as? String == String(decoding: HookOutput.sessionStart(), as: UTF8.self))
        #expect(fake.state.bound && fake.state.providerSessionID == session)
        // spawn이 끝나면 설정 파일은 지운다. 세션 폴더에는 상태 파일과 빈 cwd만
        let config = fake.box.sessionsRoot.appending(path: "\(ClaudeTest.session)/config")
        #expect(try FileManager.default.contentsOfDirectory(atPath: config.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fake.box.sessionsRoot.appending(path: "\(ClaudeTest.session)/cwd").path).isEmpty)
        // 로그에 글 · 경로 · 세션 id 원문 0
        for line in fake.log.lines {
            #expect(!line.contains("Summarize") && !line.contains("Hello there") && !line.contains(fake.workspace) && !line.contains(session), "\(line)")
        }
    }

    @Test func e1bAResumedTurnUsesTheSameSessionWithoutBindingAgain() async throws {
        let fake = try FakeClaude()
        try fake.scenario(["runs": [["steps": [["text": "One"]]], ["steps": [["text": "Two"]]]]])
        let first = EventLog()
        let identity = try await fake.turn(events: first)
        #expect(await first.wait { FakeClaude.ended($0) })
        let session = FakeClaude.providerSession(identity)
        let second = EventLog()
        _ = try await fake.turn("Next", task: "7a5c0001-0000-4000-8000-000000000002", external: session, events: second)
        #expect(await second.wait { FakeClaude.ended($0) })
        #expect(second.all == [.inputReached, .accepted, .message(text: "Two"), .turnCompleted, .ended(AgentExit(code: 0))])
        #expect(fake.report(1)?["resume"] as? Bool == true)
        #expect(fake.report(1)?["session_id"] as? String == session)
    }

    // MARK: E2 질문 → 답 resume

    @Test func e2AnAskUserCallBecomesOneInputQuestionAndTheAnswerResumesWithEmptyStdin() async throws {
        let fake = try FakeClaude()
        try fake.scenario(["runs": [
            ["steps": [["tool": "mcp__tf__ask_user", "id": "toolu_q1", "input": FakeClaude.askColor]]],
            ["final_text": "Blue it is."],
        ]])
        let first = EventLog()
        let identity = try await fake.turn(events: first)
        #expect(await first.wait { FakeClaude.ended($0) })
        #expect(first.questions == [AgentQuestion(providerRequestID: "toolu_q1", kind: .input, structured: true, text: "Which color?", items: [
            AgentQuestionItem(id: "color", header: "Color", text: "Which color?", options: [AgentQuestionOption(label: "red", description: ""), AgentQuestionOption(label: "blue", description: "")]),
        ])])
        #expect(!first.contains(.turnCompleted))
        #expect(fake.state.openDeferred?.id == "toolu_q1")
        #expect(fake.decider.calls.isEmpty, "질문은 서버를 부르지 않는다")
        let second = EventLog()
        let result = try await fake.answer("toolu_q1", kind: .input, value: AgentAnswerValue(answers: ["color": .one("blue")]), external: FakeClaude.providerSession(identity), events: second)
        guard case .delivered(let delivered) = result else {
            Issue.record("expected delivered, got \(result)")
            return
        }
        #expect(delivered.inputSentAt != nil)
        #expect(await second.wait { FakeClaude.ended($0) })
        #expect(second.all.first == .progress)
        #expect(!second.contains(.accepted))
        #expect(second.contains(.message(text: "Blue it is.")) && second.contains(.turnCompleted))
        let report = try #require(fake.report(1))
        #expect(report["stdin_bytes"] as? Int == 0, "답 resume는 빈 stdin (G34)")
        #expect((report["mcp_results"] as? [String])?.first == #"The user answered: {"color":"blue"}"#)
        #expect(fake.state.openDeferred == nil)
    }

    // MARK: E3 · E4 승인

    func approvalFlow(_ answer: String) async throws -> (FakeClaude, EventLog, AgentAnswerResult) {
        let fake = try FakeClaude(decider: ScriptedDecider([.success(ScriptedDecider.response(.defer, .manualWrite))]))
        let target = fake.workspace + "/out.txt"
        try fake.scenario(["runs": [
            ["steps": [["tool": "Write", "id": "toolu_w1", "input": ["file_path": target, "content": "hello"]]]],
            ["final_text": "Done."],
        ]])
        let first = EventLog()
        let identity = try await fake.turn(events: first)
        #expect(await first.wait { FakeClaude.ended($0) })
        #expect(first.questions.first?.kind == .approval)
        #expect(first.questions.first?.text == "Write out.txt")
        #expect(!FileManager.default.fileExists(atPath: target))
        let second = EventLog()
        let result = try await fake.answer("toolu_w1", kind: .approval, value: AgentAnswerValue(answers: ["approval": .one(answer)]), external: FakeClaude.providerSession(identity), events: second)
        #expect(await second.wait { FakeClaude.ended($0) })
        return (fake, second, result)
    }

    @Test func e3AnApprovedWriteRunsWithoutAskingTheServerAgainAndReportsAnArtifact() async throws {
        let (fake, events, result) = try await approvalFlow("allow")
        guard case .delivered = result else {
            Issue.record("\(result)")
            return
        }
        #expect(fake.decider.calls.count == 1, "resume 때 서버 호출 0")
        let target = fake.workspace + "/out.txt"
        #expect((try? String(contentsOfFile: target, encoding: .utf8)) == "hello")
        let hash = "sha256:" + SHA256.hash(data: Data("hello".utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(events.contains(.artifact(path: "out.txt", hash: hash, summary: "Wrote out.txt")))
        #expect(events.contains(.turnCompleted))
    }

    @Test func e4ADeniedWriteWritesNothingAndTellsTheModelWhy() async throws {
        let (fake, events, result) = try await approvalFlow("deny")
        guard case .delivered = result else {
            Issue.record("\(result)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: fake.workspace + "/out.txt"))
        let results = fake.report(1)?["tool_results"] as? [[String: Any]] ?? []
        #expect(results.first?["is_error"] as? Bool == true)
        #expect(results.first?["text"] as? String == ClaudeGateReason.declined)
        #expect(!events.all.contains { if case .artifact = $0 { true } else { false } })
    }

    // MARK: E5 한 응답에 질문 + 쓰기 (L6)

    @Test func e5OnlyOneDeferPerSpawnSoTheSecondCallIsDenied() async throws {
        let fake = try FakeClaude(decider: ScriptedDecider([.success(ScriptedDecider.response(.defer, .manualWrite))]))
        try fake.scenario(["runs": [["steps": [
            ["tool": "mcp__tf__ask_user", "id": "toolu_q", "input": FakeClaude.askColor, "same_response": true],
            ["tool": "Write", "id": "toolu_w", "input": ["file_path": fake.workspace + "/a.txt", "content": "A"]],
        ]]]])
        let events = EventLog()
        _ = try await fake.turn(events: events)
        #expect(await events.wait { FakeClaude.ended($0) })
        #expect(events.questions.map(\.providerRequestID) == ["toolu_q"])
        let decisions = fake.report(0)?["decisions"] as? [[String: Any]] ?? []
        #expect(decisions.map { $0["decision"] as? String } == ["defer", "deny"])
        #expect(fake.decider.calls.isEmpty, "L6은 서버 전에 막는다")
    }

    // MARK: E6 Bash 중 SIGINT

    @Test func e6StopDuringBashCancelsAndLeavesNoProcessGroup() async throws {
        let fake = try FakeClaude()
        fake.allowReadonlyCat("notes.md")
        try fake.scenario(["runs": [["steps": [["tool": "Bash", "id": "toolu_b", "input": ["command": "cat notes.md"], "sleep": 30]]]]])
        let events = EventLog()
        let identity = try await fake.turn(events: events)
        var sleepPID: Int?
        for _ in 0..<500 {
            sleepPID = fake.report(0)?["sleep_pid"] as? Int
            if sleepPID != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(sleepPID != nil)
        #expect((fake.report(0)?["bash_commands"] as? [String])?.first == "'/bin/cat' '\(fake.workspace)/notes.md'", "실행되는 것 = 판정한 것 (재구성 명령)")
        let result = await fake.process.interrupt(AgentTurnRef(taskID: ClaudeTest.task, sessionID: ClaudeTest.session, identity: identity), scope: .turnAndProcesses)
        #expect(result == .signalled)
        #expect(await events.wait { FakeClaude.ended($0) })
        #expect(events.contains(.cancelled))
        #expect(events.ended == AgentExit(code: 0))
        let group = pid_t(try #require(identity.pid))
        try await Task.sleep(for: .milliseconds(200))
        #expect(killpg(group, 0) != 0, "프로세스 그룹에 남은 것 0")
        #expect(kill(pid_t(try #require(sleepPID)), 0) != 0)
    }

    // MARK: E7 닫기 모드

    @Test func e7CloseModeDeniesEverythingInterruptsAtTheClosingResultAndEmitsNothing() async throws {
        let fake = try FakeClaude()
        try fake.scenario(["runs": [
            ["steps": [["tool": "mcp__tf__ask_user", "id": "toolu_q", "input": FakeClaude.askColor]]],
            ["steps": [["tool": "Write", "id": "toolu_w", "input": ["file_path": fake.workspace + "/late.txt", "content": "x"]]], "final_text": "Will not ask again."],
        ]])
        let first = EventLog()
        let identity = try await fake.turn(events: first)
        #expect(await first.wait { FakeClaude.ended($0) })
        let started = Date()
        try await fake.process.closeRequest(AgentRequestRef(taskID: ClaudeTest.task, sessionID: ClaudeTest.session, requestID: "toolu_q", externalSessionID: FakeClaude.providerSession(identity), workspaceRef: fake.workspace))
        #expect(Date().timeIntervalSince(started) < 5, "끝날 때까지 기다린 뒤 돌아온다")
        let report = try #require(fake.report(1))
        #expect(report["stdin_bytes"] as? Int == 0)
        let decisions = report["decisions"] as? [[String: Any]] ?? []
        #expect(decisions.first?["id"] as? String == "toolu_q" && decisions.first?["decision"] as? String == "deny")
        #expect(decisions.allSatisfy { $0["decision"] as? String == "deny" })
        #expect((report["tool_results"] as? [[String: Any]])?.first?["text"] as? String == ClaudeGateReason.closedRequest)
        #expect(report["interrupted"] as? Bool == true)
        #expect(!FileManager.default.fileExists(atPath: fake.workspace + "/late.txt"))
        #expect(fake.state.openDeferred == nil)
    }

    // MARK: E8 ① 설정 변조

    @Test func e8ATamperedSettingsFileRefusesTheSpawn() async throws {
        let fake = try FakeClaude(hooks: ClaudeCodeTestHooks(afterConfigWrite: { url in try? Data(#"{"hooks":{"PreToolUse":"this-should-be-an-array"}}"#.utf8).write(to: url) }))
        try fake.scenario(["runs": [["steps": [["text": "x"]]]]])
        await #expect(throws: AgentStartError(.spawnFailed)) { try await fake.turn(events: EventLog()) }
        #expect(fake.runCount == 0, "spawn 0")
        let config = fake.box.sessionsRoot.appending(path: "\(ClaudeTest.session)/config")
        #expect(try FileManager.default.contentsOfDirectory(atPath: config.path).isEmpty)
        #expect(fake.log.lines.contains("claude_selfcheck_failed check=count(1)"))
    }

    // MARK: E9 ④ 훅 없이 실행된 도구

    @Test func e9AToolThatRanWithoutThePreToolUseHookStopsTheTurn() async throws {
        let fake = try FakeClaude()
        fake.box.file("a.txt")
        try fake.scenario(["runs": [["steps": [["tool": "Read", "id": "toolu_r", "input": ["file_path": fake.workspace + "/a.txt"], "skip_hook": true], ["text": "never"]]]]])
        let events = EventLog()
        _ = try await fake.turn(events: events)
        #expect(await events.wait { FakeClaude.ended($0) })
        #expect(events.contains(.failed(.agentError)))
        #expect(!events.contains(.turnCompleted))
        #expect(fake.log.lines.contains("claude_selfcheck_failed check=count(4)"))
    }

    // MARK: E10 로그인 없음

    @Test func e10ASyntheticNotLoggedInTurnIsSignInNeededAndNeverAccepted() async throws {
        let fake = try FakeClaude()
        try fake.scenario(["runs": [["synthetic_login_error": true]]])
        let events = EventLog()
        _ = try await fake.turn(events: events)
        #expect(await events.wait { FakeClaude.ended($0) })
        #expect(events.contains(.failed(.signInNeeded)))
        #expect(!events.contains(.accepted))
        #expect(!events.all.contains { if case .message = $0 { true } else { false } })
        #expect(events.ended == AgentExit(code: 1))
    }

    // MARK: E11 · E12 probe

    @Test func e11AVersionOutsideTheRangeIsUnsupportedAtProbeAndAtInit() async throws {
        let fake = try FakeClaude()
        try fake.scenario(["version": "2.2.0 (Claude Code)", "runs": [["init_version": "2.2.0", "steps": [["text": "x"]]]]])
        let report = await fake.process.probe()
        #expect(report.version == "2.2.0")
        #expect(!fake.process.supportsVersion(report.version))
        let events = EventLog()
        _ = try await fake.turn(events: events)
        #expect(await events.wait { FakeClaude.ended($0) })
        #expect(events.contains(.failed(.versionUnsupported)))
        #expect(!events.contains(.accepted))
    }

    @Test func e12AuthStatusLoggedOutIsNo() async throws {
        let fake = try FakeClaude()
        try fake.scenario(["auth": ["loggedIn": false, "email": "a@b.c"], "runs": [["steps": []]]])
        let report = await fake.process.probe()
        #expect(report == BridgeV1AdapterReport(adapter: "agent:claude-code", installed: true, version: "2.1.241", signedIn: .no, managedSettings: false))
        #expect(fake.runCount == 0, "probe는 턴을 띄우지 않는다")
    }

    // MARK: E14 고아

    @Test func e14AnOrphanLeftByAnAbandonedRuntimeIsFoundAliveAndTerminated() async throws {
        let fake = try FakeClaude()
        fake.allowReadonlyCat("notes.md")
        try fake.scenario(["runs": [["steps": [["tool": "Bash", "id": "toolu_b", "input": ["command": "cat notes.md"], "sleep": 30]]]]])
        let events = EventLog()
        let identity = try await fake.turn(events: events)
        for _ in 0..<500 where fake.report(0)?["sleep_pid"] == nil { try await Task.sleep(for: .milliseconds(20)) }
        // 앱이 다시 떴다: 새 adapter가 원장의 정체만 들고 확인한다
        let restarted = ClaudeCodeProcess(sessionsRoot: fake.box.sessionsRoot, hookServer: nil, helpers: ClaudeCodeHelpers(hook: "/x", mcp: "/y", keeper: "/z"),
                                          locator: ClaudeCodeLocator(candidates: [], confinedTo: fake.box.root.path), timing: .testing)
        #expect(await restarted.liveness(identity) == .alive)
        let ended = await restarted.terminateOrphan(identity)
        guard case .ended = ended else {
            Issue.record("\(ended)")
            return
        }
        #expect(await restarted.liveness(identity) == .ended(AgentExit(code: nil)))
        #expect(await events.wait { FakeClaude.ended($0) })
    }

    // MARK: E16 · E23 환경 · fd

    @Test func e16AndE23TheChildGetsFourEnvironmentKeysAndOnlyStandardStreams() async throws {
        let fake = try FakeClaude(environment: [
            "ANTHROPIC_API_KEY": "sk-ant-canary", "CLAUDE_CODE_OAUTH_TOKEN": "canary", "DYLD_INSERT_LIBRARIES": "/tmp/nope.dylib", "NODE_OPTIONS": "--require /tmp/x",
        ])
        try fake.scenario(["runs": [["steps": [["text": "ok"]]]]])
        let events = EventLog()
        _ = try await fake.turn(events: events)
        #expect(await events.wait { FakeClaude.ended($0) })
        let report = try #require(fake.report(0))
        // 가짜는 exec 때 받은 환경(`KERN_PROCARGS2`)을 알린다: 지킴이가 명시해서 넘긴 정확히 다섯 키 (14장 10, 넷 + spawn marker — 9장 4).
        // 지킴이 자신이 더한 값(`__CF_USER_TEXT_ENCODING`)도 앱 환경의 다른 값도 없다
        let keys = report["env_keys"] as? [String] ?? []
        #expect(keys == ["HOME", "LANG", "PATH", ClaudeProcessInspector.markerKey, "USER"])
        #expect(KeeperMain.childEnvironmentKeys == Set(keys))
        #expect(report["fds"] as? [Int] == [0, 1, 2], "앱의 소켓 · SQLite fd를 물려주지 않는다 (CLOEXEC)")
    }

    @Test func theSpawnerPassesExactlyTheGivenEnvironment() throws {
        let app = ["HOME": "/Users/u", "USER": "u", "PATH": "/usr/bin:/bin", "ANTHROPIC_API_KEY": "sk-ant-canary", "CLAUDE_CODE_OAUTH_TOKEN": "canary", "DYLD_INSERT_LIBRARIES": "/tmp/x.dylib"]
        let environment = ClaudeCodeEnvironment.child(app: app, executable: ClaudeCodeExecutable(path: "/usr/bin/env", realPath: "/usr/bin/env", directory: "/usr/bin"))
        let process = try ClaudeSpawner.spawn(executable: "/usr/bin/env", arguments: [], environment: environment, cwd: "/")
        close(process.stdinFD)
        close(process.stderrFD)
        let output = FileHandle(fileDescriptor: process.stdoutFD, closeOnDealloc: true).readDataToEndOfFile()
        _ = process.waitForExit()
        let keys = String(decoding: output, as: UTF8.self).split(separator: "\n").map { String($0.prefix { $0 != "=" }) }.sorted()
        #expect(keys == ["HOME", "LANG", "PATH", "USER"])
    }

    // MARK: E17 훅 예산

    @Test func e17ABridgeSlowerThanTheHookBudgetIsADenyAndTheLateDecisionIsIgnored() async throws {
        let fake = try FakeClaude(decider: ScriptedDecider([.success(ScriptedDecider.response(.defer, .manualWrite))]), hooks: ClaudeCodeTestHooks(gateDelay: .seconds(2)))
        try fake.scenario(["runs": [["steps": [["tool": "Write", "id": "toolu_w", "input": ["file_path": fake.workspace + "/a.txt", "content": "A"]]], "final_text": "ok"]]])
        let events = EventLog()
        _ = try await fake.turn(events: events)
        #expect(await events.wait { FakeClaude.ended($0) })
        let report = try #require(fake.report(0))
        #expect((report["decisions"] as? [[String: Any]])?.first?["decision"] as? String == "deny")
        let hookMS = (report["hook_ms"] as? [Int])?.first ?? 0
        #expect(hookMS < 1700, "\(hookMS)")
        #expect(events.questions.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fake.workspace + "/a.txt"))
        try await Task.sleep(for: .seconds(1))
        #expect(fake.state.openDeferred == nil, "늦은 결정은 보류를 만들지 않는다")
    }

    // MARK: E18 · E19 · E20 · E21

    @Test func e18AndE19ModeTamperingAndForbiddenToolsAreDenied() async throws {
        let fake = try FakeClaude()
        fake.box.file("a.txt")
        try fake.scenario(["runs": [["steps": [
            ["tool": "Read", "id": "toolu_r", "input": ["file_path": fake.workspace + "/a.txt"], "permission_mode": "acceptEdits"],
            ["tool": "mcp__evil__ask_user", "id": "toolu_e", "input": FakeClaude.askColor],
            ["tool": "Agent", "id": "toolu_a", "input": ["prompt": "hi"]],
        ], "final_text": "done"]]])
        let events = EventLog()
        _ = try await fake.turn(events: events)
        #expect(await events.wait { FakeClaude.ended($0) })
        let decisions = fake.report(0)?["decisions"] as? [[String: Any]] ?? []
        #expect(decisions.map { $0["decision"] as? String } == ["deny", "deny", "deny"])
        #expect(events.contains(.turnCompleted))
    }

    @Test func e20ReadOnlyLimitsTheToolsAndDeniesAWriteEvenIfTheModelTries() async throws {
        let fake = try FakeClaude()
        try fake.scenario(["runs": [["steps": [["tool": "Write", "id": "toolu_w", "input": ["file_path": fake.workspace + "/a.txt", "content": "A"]]], "final_text": "ok"]]])
        let events = EventLog()
        _ = try await fake.turn(access: .readOnly, events: events)
        #expect(await events.wait { FakeClaude.ended($0) })
        #expect(fake.report(0)?["tools"] as? String == "Read,Glob,Grep")
        #expect((fake.report(0)?["tool_results"] as? [[String: Any]])?.first?["text"] as? String == ClaudeGateReason.readOnly)
        #expect(!FileManager.default.fileExists(atPath: fake.workspace + "/a.txt"))
        #expect(fake.decider.calls.isEmpty)
        #expect(events.contains(.turnCompleted))
    }

    @Test func e21AToolConfigWriteDeferredByTheServerIsAnApprovalQuestion() async throws {
        let fake = try FakeClaude(decider: ScriptedDecider([.success(ScriptedDecider.response(.defer, .toolConfigWrite))]))
        try fake.scenario(["runs": [["steps": [["tool": "Write", "id": "toolu_w", "input": ["file_path": fake.workspace + "/.mcp.json", "content": "{}"]]]]]])
        let events = EventLog()
        _ = try await fake.turn(events: events)
        #expect(await events.wait { FakeClaude.ended($0) })
        #expect(events.questions.map(\.text) == ["Write .mcp.json"])
        #expect(fake.decider.calls.first?.call == .claudeWrite(toolUseID: "toolu_w", permissionMode: "default", tool: "Write",
                                                             target: BridgeV1ToolTarget(realPath: fake.workspace + "/.mcp.json", relPath: ".mcp.json")))
    }

    // MARK: E22 열린 보류가 아닌 답 (G28)

    @Test func e22AnAnswerToARequestThatIsNotOpenSpawnsNothing() async throws {
        let fake = try FakeClaude()
        try fake.scenario(["runs": [["steps": [["tool": "mcp__tf__ask_user", "id": "toolu_q", "input": FakeClaude.askColor]]]]])
        let first = EventLog()
        let identity = try await fake.turn(events: first)
        #expect(await first.wait { FakeClaude.ended($0) })
        let before = fake.runCount
        let result = try await fake.answer("toolu_other", kind: .input, value: AgentAnswerValue(text: "x"), external: FakeClaude.providerSession(identity), events: EventLog())
        #expect(result == .requestClosed)
        let kind = try await fake.answer("toolu_q", kind: .approval, value: AgentAnswerValue(answers: ["approval": .one("allow")]), external: FakeClaude.providerSession(identity), events: EventLog())
        #expect(kind == .requestClosed, "종류가 다른 답도 닫힘")
        #expect(fake.runCount == before, "spawn 0")
    }

    // MARK: G16 resume 입력이 보류 때와 다르다

    @Test func g16AResumedCallWhoseInputChangedIsDeniedAndTheAnswerIsClosed() async throws {
        let fake = try FakeClaude(decider: ScriptedDecider([.success(ScriptedDecider.response(.defer, .manualWrite))]))
        try fake.scenario(["runs": [
            ["steps": [["tool": "Write", "id": "toolu_w", "input": ["file_path": fake.workspace + "/a.txt", "content": "A"]]]],
            ["resume_input_override": ["file_path": fake.workspace + "/a.txt", "content": "CHANGED"], "final_text": "x"],
        ]])
        let first = EventLog()
        let identity = try await fake.turn(events: first)
        #expect(await first.wait { FakeClaude.ended($0) })
        let result = try await fake.answer("toolu_w", kind: .approval, value: AgentAnswerValue(answers: ["approval": .one("allow")]), external: FakeClaude.providerSession(identity), events: EventLog())
        #expect(result == .requestClosed)
        #expect(!FileManager.default.fileExists(atPath: fake.workspace + "/a.txt"))
        // 바뀐 입력은 deny로 답하고 그 spawn을 멈춘다 (SIGINT가 훅이 끝나기 전에 닿아 도구 결과 없이 끝난다)
        let report = try #require(fake.report(1))
        #expect((report["decisions"] as? [[String: Any]])?.first?["decision"] as? String == "deny")
        #expect(report["interrupted"] as? Bool == true)
    }

    // MARK: 작업 폴더 · 소켓이 없으면 띄우지 않는다

    @Test func withoutAWorkspaceOrSocketNothingIsSpawned() async throws {
        let fake = try FakeClaude()
        try fake.scenario(["runs": [["steps": [["text": "x"]]]]])
        let turn = AgentTurnStart(taskID: ClaudeTest.task, sessionID: ClaudeTest.session, turnSeq: 1, adapter: "agent:claude-code", externalSessionID: nil, workspaceRef: nil, resume: false,
                                  access: .write, policyMode: .manual, marker: UUID().uuidString, text: "x")
        await #expect(throws: AgentStartError(.spawnFailed)) { try await fake.process.startTurn(turn, events: EventLog().sink) }
        var notADirectory = turn
        notADirectory.workspaceRef = fake.box.file("plain.txt").path
        await #expect(throws: AgentStartError(.spawnFailed)) { try await fake.process.startTurn(notADirectory, events: EventLog().sink) }
        let noSocket = ClaudeCodeProcess(sessionsRoot: fake.box.sessionsRoot, hookServer: nil, helpers: ClaudeCodeHelpers(hook: "/x", mcp: "/y", keeper: "/z"),
                                         locator: ClaudeCodeLocator(candidates: [fake.claude.path], confinedTo: fake.box.root.path), timing: .testing)
        var withWorkspace = turn
        withWorkspace.workspaceRef = fake.workspace
        await #expect(throws: AgentStartError(.spawnFailed)) { try await noSocket.startTurn(withWorkspace, events: EventLog().sink) }
        #expect(fake.runCount == 0)
        await #expect(throws: AgentStartError(.spawnFailed)) {
            try await fake.process.closeRequest(AgentRequestRef(taskID: ClaudeTest.task, sessionID: ClaudeTest.session, requestID: "x", externalSessionID: "abc", workspaceRef: nil))
        }
    }
}
#endif
