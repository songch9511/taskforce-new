#if os(macOS)
import Foundation
import Testing
import TaskforceAgentWire
@testable import TaskforceKit

/// 결정표 (OA D3a 계약 2.7): 로컬 정적 행 L1–L10 → 서버 행 S → 서버 뒤 로컬 확인 P1–P5. 처음 맞는 행이 이긴다.
/// L 행은 서버를 부르지 않는다 (로컬이 뒤집을 결정으로 서버 예약을 만들지 않게, D3c-2 6.4). 적대적 사례 7-01–7-10 · 8-01 · 8-04 · 8-09
struct ClaudeToolGateTests {
    let box = ClaudeSandbox()
    let cwd: URL
    let config: URL

    init() {
        cwd = box.sessionsRoot.appending(path: "\(ClaudeTest.session)/cwd", directoryHint: .isDirectory)
        config = box.sessionsRoot.appending(path: "\(ClaudeTest.session)/config", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    }

    func context(_ mode: ClaudeGateContext.Mode = .normal, access: AgentAccess = .write, deferIssued: Bool = false, answerDelivered: Bool = false, path: String = "/usr/bin:/bin") -> ClaudeGateContext {
        ClaudeGateContext(
            mode: mode, access: access, workspaceRealPath: box.workspacePath, sessionCwdRealPath: cwd.path, childPATH: path, agentSessionID: ClaudeTest.session,
            agentTaskID: ClaudeTest.task, turnSeq: 3, deferIssued: deferIssued, answerDelivered: answerDelivered
        )
    }

    /// 서버 예산은 시험마다 넉넉히 둔다 (시험 전체가 동시에 돌 때 대본 결정기의 응답이 늦어 시간 초과로 보이지 않게). 시간 초과 시험만 실제 1.0초
    func gate(_ decider: ScriptedDecider?, timeout: Duration = .seconds(30)) -> ClaudeToolGate {
        ClaudeToolGate(fileSystem: .live, decide: decider?.function, serverTimeout: timeout)
    }

    func evaluate(
        _ tool: String, _ input: String, id: String = "toolu_1", mode: String = "default", context: ClaudeGateContext? = nil, decider: ScriptedDecider? = nil,
        timeout: Duration = .seconds(30)
    ) async -> ClaudeGateOutcome {
        await gate(decider, timeout: timeout).evaluate(ClaudeTest.request(tool, ClaudeTest.json(input), id: id, mode: mode, cwd: cwd.path), context: context ?? self.context())
    }

    // MARK: L1 닫기 모드 (G29)

    @Test func closeModeDeniesEveryCallAndTellsTheModelTheTaskStoppedOnTheClosingID() async {
        let decider = ScriptedDecider([.success(ScriptedDecider.response(.allow, .policyAuto))])
        let closing = await evaluate("mcp__tf__ask_user", #"{"questions":[{"id":"a","text":"?"}]}"#, id: "toolu_closing", context: context(.close(requestID: "toolu_closing")), decider: decider)
        #expect(closing.response == HookResponse(decision: .deny, reason: ClaudeGateReason.closedRequest))
        let other = await evaluate("Read", #"{"file_path":"\#(box.workspacePath)/a"}"#, id: "toolu_other", context: context(.close(requestID: "toolu_closing")), decider: decider)
        #expect(other.response == HookResponse(decision: .deny, reason: ClaudeGateReason.turnStopped))
        #expect(decider.calls.isEmpty)
    }

    // MARK: L2 권한 모드 (G5, 8-09)

    @Test func aNonDefaultPermissionModeDeniesEveryToolWithoutAskingTheServer() async {
        let decider = ScriptedDecider()
        for mode in ["acceptEdits", "bypassPermissions", "plan", "auto", ""] {
            for (tool, input) in [("Read", #"{"file_path":"\#(box.workspacePath)/a"}"#), ("Write", #"{"file_path":"\#(box.workspacePath)/a","content":"x"}"#), ("Bash", #"{"command":"ls"}"#)] {
                let outcome = await evaluate(tool, input, mode: mode, decider: decider)
                #expect(outcome.response.decision == .deny, "\(mode) \(tool)")
                #expect(outcome.code == "permission_mode")
            }
        }
        #expect(decider.calls.isEmpty)
    }

    // MARK: L3 답 모드 (G15 · G16)

    func binding(_ kind: BridgeV1PendingQuestionKind, _ value: AgentAnswerValue, digest input: String, id: String = "toolu_q") -> ClaudeGateContext.Mode {
        .answer(ClaudeAnswerBinding(requestID: id, kind: kind, inputSHA256: HookWire.inputDigest(ClaudeTest.json(input)), value: value))
    }

    @Test func anInputAnswerAllowsTheDeferredCallWithTheBridgesAnswersOnly() async {
        let input = #"{"questions":[{"id":"color","text":"Which?","options":[{"label":"red"},{"label":"blue"}]},{"id":"langs","text":"Which?","options":[{"label":"a"},{"label":"b"}],"multi_select":true}],"answers":{"color":"model"}}"#
        let mode = binding(.input, AgentAnswerValue(answers: ["color": .one("blue"), "langs": .many(["a", "b"])]), digest: input)
        let outcome = await evaluate("mcp__tf__ask_user", input, id: "toolu_q", context: context(mode))
        #expect(outcome.response.decision == .allow)
        #expect(outcome.response.answers == ["color": .string("blue"), "langs": .array([.string("a"), .string("b")])])
        #expect(outcome.answeredPending)
    }

    @Test func aFreeTextAnswerGoesToTheOnlyQuestion() async {
        let input = #"{"questions":[{"id":"name","text":"Your name?","allow_other":true}]}"#
        let outcome = await evaluate("mcp__tf__ask_user", input, id: "toolu_q", context: context(binding(.input, AgentAnswerValue(text: "Ada"), digest: input)))
        #expect(outcome.response.answers == ["name": .string("Ada")])
    }

    @Test func aChangedInputOnResumeIsDenied() async {
        let asked = #"{"file_path":"\#(box.workspacePath)/a.txt","content":"A"}"#
        let resumed = #"{"file_path":"\#(box.workspacePath)/a.txt","content":"B"}"#
        let outcome = await evaluate("Write", resumed, id: "toolu_q", context: context(binding(.approval, AgentAnswerValue(answers: ["approval": .one("allow")]), digest: asked)))
        #expect(outcome.response.decision == .deny)
        #expect(outcome.code == "input_changed")
    }

    @Test func approvalAllowAndDenyFollowTheUser() async {
        let input = #"{"file_path":"\#(box.workspacePath)/a.txt","content":"A"}"#
        let decider = ScriptedDecider()
        // 보류 때 적은 대상 지문 (8장 2): 그대로면 승인을 따른다
        let target = GateFileSystem.live.resolve(box.workspacePath + "/a.txt").flatMap(ClaudeToolGate.targetFingerprint)
        var approved = ClaudeAnswerBinding(requestID: "toolu_q", kind: .approval, inputSHA256: HookWire.inputDigest(ClaudeTest.json(input)), value: AgentAnswerValue(answers: ["approval": .one("allow")]))
        approved.targetSHA256 = target
        let allow = await evaluate("Write", input, id: "toolu_q", context: context(.answer(approved)), decider: decider)
        #expect(allow.response == HookResponse(decision: .allow, reason: ClaudeGateReason.approved))
        let deny = await evaluate("Write", input, id: "toolu_q", context: context(binding(.approval, AgentAnswerValue(answers: ["approval": .one("deny")]), digest: input)), decider: decider)
        #expect(deny.response == HookResponse(decision: .deny, reason: ClaudeGateReason.declined))
        let odd = await evaluate("Write", input, id: "toolu_q", context: context(binding(.approval, AgentAnswerValue(answers: ["approval": .one("maybe")]), digest: input)), decider: decider)
        #expect(odd.response.decision == .deny)
        #expect(decider.calls.isEmpty, "resume 때 서버를 다시 부르지 않는다 (D3c-2 3.6-5)")
    }

    @Test func anApprovedWriteThatNowPointsOutsideIsStillDenied() async {
        box.link("escape", to: box.outside)
        let input = #"{"file_path":"\#(box.workspacePath)/escape/a.txt","content":"A"}"#
        let outcome = await evaluate("Write", input, id: "toolu_q", context: context(binding(.approval, AgentAnswerValue(answers: ["approval": .one("allow")]), digest: input)))
        #expect(outcome.response.decision == .deny)
    }

    @Test func theAnswerIsGivenOnlyOnce() async {
        let input = #"{"questions":[{"id":"key","text":"Key?","secret":true}]}"#
        let mode = binding(.input, AgentAnswerValue(text: "CANARY-SECRET"), digest: input)
        let second = await evaluate("mcp__tf__ask_user", input, id: "toolu_q", context: context(mode, answerDelivered: true))
        #expect(second.response.decision == .deny)
        #expect(second.response.answers == nil)
    }

    // MARK: L4 답 모드에서 다른 호출이 먼저 옴

    @Test func anotherCallBeforeThePendingIDDeniesAndStopsTheSpawn() async {
        let input = #"{"questions":[{"id":"a","text":"?"}]}"#
        let outcome = await evaluate("Read", #"{"file_path":"\#(box.workspacePath)/a"}"#, id: "toolu_new", context: context(binding(.input, AgentAnswerValue(text: "x"), digest: input)))
        #expect(outcome.response.decision == .deny)
        #expect(outcome.abortSpawn)
    }

    // MARK: L5 도구 집합 (G6, 7-01–7-04)

    @Test func toolsOutsideTheSetAreDeniedLocally() async {
        let decider = ScriptedDecider()
        for tool in ["Agent", "Task", "Skill", "NotebookEdit", "MultiEdit", "mcp__evil__ask_user", "ToolSearch", "WebFetch", "TodoWrite", "CronCreate", "mcp__tf__other"] {
            let outcome = await evaluate(tool, #"{}"#, decider: decider)
            #expect(outcome.response.decision == .deny, "\(tool)")
            #expect(outcome.code == "tool_not_allowed", "\(tool)")
        }
        #expect(decider.calls.isEmpty)
    }

    @Test func readOnlyAccessDeniesEditWriteAndBashLocally() async {
        let decider = ScriptedDecider()
        for (tool, input) in [("Write", #"{"file_path":"\#(box.workspacePath)/a","content":"x"}"#), ("Edit", #"{"file_path":"\#(box.workspacePath)/a","old_string":"x","new_string":"y"}"#), ("Bash", #"{"command":"ls"}"#)] {
            let outcome = await evaluate(tool, input, context: context(access: .readOnly), decider: decider)
            #expect(outcome.response == HookResponse(decision: .deny, reason: ClaudeGateReason.readOnly), "\(tool)")
        }
        #expect(await evaluate("Read", #"{"file_path":"\#(box.workspacePath)/a"}"#, context: context(access: .readOnly)).response.decision == .allow)
        #expect(decider.calls.isEmpty)
    }

    // MARK: L6 spawn당 defer 하나 (G7, 8-04)

    @Test func aSecondDeferInTheSameSpawnIsDenied() async {
        let decider = ScriptedDecider([.success(ScriptedDecider.response(.defer, .manualWrite))])
        let ask = await evaluate("mcp__tf__ask_user", #"{"questions":[{"id":"a","text":"?"}]}"#, context: context(deferIssued: true), decider: decider)
        #expect(ask.response == HookResponse(decision: .deny, reason: ClaudeGateReason.oneAtATime))
        let write = await evaluate("Write", #"{"file_path":"\#(box.workspacePath)/a","content":"x"}"#, context: context(deferIssued: true), decider: decider)
        #expect(write.response.decision == .deny)
        #expect(decider.calls.isEmpty)
    }

    // MARK: L7 읽기 범위 (G8, 6-08)

    @Test func readsInsideTheWorkspaceOrTheSessionFolderAreAllowed() async {
        box.file("src/a.txt")
        for input in [#"{"file_path":"\#(box.workspacePath)/src/a.txt"}"#, #"{"file_path":"\#(box.workspacePath)/src/new-file.txt"}"#, #"{"file_path":"\#(cwd.path)/x"}"#] {
            #expect(await evaluate("Read", input).response == HookResponse(decision: .allow, reason: ClaudeGateReason.inside), "\(input)")
        }
        #expect(await evaluate("Grep", #"{"pattern":"x"}"#).response.decision == .allow, "경로가 없으면 cwd")
        #expect(await evaluate("Glob", #"{"pattern":"**/*.swift","path":"\#(box.workspacePath)/src"}"#).response.decision == .allow)
        #expect(await evaluate("Glob", #"{"pattern":"\#(box.workspacePath)/src/*.txt"}"#).response.decision == .allow)
    }

    @Test func readsOutsideTheWorkspaceAreDenied() async {
        box.file("secret.txt", in: box.outside)
        box.link("escape", to: box.outside)
        let cases = [
            ("Read", #"{"file_path":"/etc/hosts"}"#),
            ("Read", #"{"file_path":"\#(box.workspacePath)/escape/secret.txt"}"#),
            ("Read", #"{"file_path":"\#(box.workspacePath)/missing/../../outside/secret.txt"}"#),
            ("Read", #"{"file_path":"\#(config.path)/x.settings.json"}"#),
            ("Read", #"{"file_path":"~/.ssh/id_rsa"}"#),
            ("Read", #"{"file_path":"relative/../../x"}"#),
            ("Read", #"{}"#),
            ("Glob", #"{"pattern":"/etc/*"}"#),
            ("Glob", #"{"pattern":"../../*","path":"\#(box.workspacePath)"}"#),
            ("Glob", #"{"pattern":"*","path":"\#(box.outside.path)"}"#),
            ("Grep", #"{"pattern":"x","path":"\#(box.workspacePath)/escape"}"#),
        ]
        for (tool, input) in cases {
            let outcome = await evaluate(tool, input)
            #expect(outcome.response.decision == .deny, "\(tool) \(input)")
        }
    }

    // MARK: L8 ask_user (7-05)

    @Test func askUserDefersWithAQuestionAndIgnoresTheModelsAnswers() async throws {
        let decider = ScriptedDecider()
        let input = #"{"questions":[{"id":"color","header":"Color","text":"Which color?","options":[{"label":"red"},{"label":"blue","description":"cool"}]}],"answers":{"color":"red"}}"#
        let outcome = await evaluate("mcp__tf__ask_user", input, id: "toolu_q", decider: decider)
        #expect(outcome.response.decision == .defer)
        #expect(outcome.response.answers == nil)
        let pending = try #require(outcome.deferred)
        #expect(pending.id == "toolu_q")
        #expect(pending.kind == .input)
        #expect(pending.inputSHA256 == HookWire.inputDigest(ClaudeTest.json(input)))
        #expect(pending.question == AgentQuestion(providerRequestID: "toolu_q", kind: .input, structured: true, text: "Which color?", items: [
            AgentQuestionItem(id: "color", header: "Color", text: "Which color?", options: [AgentQuestionOption(label: "red", description: ""), AgentQuestionOption(label: "blue", description: "cool")]),
        ]))
        #expect(decider.calls.isEmpty)
    }

    @Test func anAskUserCallTheServerCannotHoldIsDeniedWithWhatToFix() async {
        let outcome = await evaluate("mcp__tf__ask_user", #"{"questions":[]}"#)
        #expect(outcome.response.decision == .deny)
        #expect(outcome.response.reason.contains("Ask 1 to 4 questions"))
        #expect(outcome.deferred == nil)
    }

    // MARK: L9 · L10 (G9 · G10, 7-09 · 7-10)

    @Test func writesOutsideTheWorkspaceAreDeniedWithoutTheServer() async {
        box.link("escape", to: box.outside)
        let decider = ScriptedDecider([.success(ScriptedDecider.response(.allow, .policyAuto))])
        for (tool, input) in [("Write", #"{"file_path":"\#(box.outside.path)/a","content":"x"}"#), ("Write", #"{"file_path":"\#(box.workspacePath)/escape/a","content":"x"}"#),
                              ("Edit", #"{"file_path":"/etc/hosts","old_string":"a","new_string":"b"}"#), ("Write", #"{"file_path":"\#(cwd.path)/a","content":"x"}"#),
                              ("Write", #"{"file_path":"\#(box.workspacePath)/new/../../outside/a","content":"x"}"#)] {
            let outcome = await evaluate(tool, input, decider: decider)
            #expect(outcome.response == HookResponse(decision: .deny, reason: ClaudeGateReason.outsideFile), "\(input)")
        }
        #expect(decider.calls.isEmpty)
    }

    @Test func backgroundAndSandboxBypassBashAreDeniedWithoutTheServer() async {
        let decider = ScriptedDecider([.success(ScriptedDecider.response(.allow, .policyAuto))])
        let background = await evaluate("Bash", #"{"command":"ls","run_in_background":true}"#, decider: decider)
        #expect(background.response == HookResponse(decision: .deny, reason: ClaudeGateReason.background))
        let sandbox = await evaluate("Bash", #"{"command":"echo hi > b.txt","dangerouslyDisableSandbox":true}"#, decider: decider)
        #expect(sandbox.response == HookResponse(decision: .deny, reason: ClaudeGateReason.sandboxDisabled))
        #expect(decider.calls.isEmpty)
    }

    // MARK: S · P (서버 행)

    @Test func bashGoesToTheServerWithTheHookCwdAndWritesWithRealAndRelativePaths() async throws {
        box.file("src/a.txt")
        let decider = ScriptedDecider([.success(ScriptedDecider.response(.defer, .commandNotReadonly)), .success(ScriptedDecider.response(.defer, .manualWrite))])
        _ = await evaluate("Bash", #"{"command":"npm test","timeout":1000}"#, id: "toolu_b", decider: decider)
        _ = await evaluate("Write", #"{"file_path":"\#(box.workspacePath)/src/new.txt","content":"x"}"#, id: "toolu_w", decider: decider)
        let calls = decider.calls
        try #require(calls.count == 2)
        #expect(calls[0] == BridgeV1ToolDecisionQuery(agentSessionID: ClaudeTest.session, agentTaskID: ClaudeTest.task, turnSeq: 3, workspaceRealPath: box.workspacePath,
                                                     call: .claudeBash(toolUseID: "toolu_b", permissionMode: "default", cwd: cwd.path, command: "npm test", runInBackground: false, dangerouslyDisableSandbox: false)))
        #expect(calls[1].call == .claudeWrite(toolUseID: "toolu_w", permissionMode: "default", tool: "Write", target: BridgeV1ToolTarget(realPath: box.workspacePath + "/src/new.txt", relPath: "src/new.txt")))
    }

    @Test func aSlowServerBecomesALocalDeferWithinTheBudget() async {
        let decider = ScriptedDecider([.success(ScriptedDecider.response(.allow, .policyAuto))], delay: .seconds(3))
        let started = Date()
        let outcome = await evaluate("Write", #"{"file_path":"\#(box.workspacePath)/a","content":"x"}"#, decider: decider, timeout: .seconds(1))
        // 서버 예산(1.0초)에서 끊었다: 3초 걸리는 결정기를 기다리지 않는다. 훅이 받는 답의 상한은 소켓 서버(스레드 시계 1.2초)가 따로 지킨다
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed >= 0.99 && elapsed < 2.5, "\(elapsed)")
        #expect(outcome.response.decision == .defer)
        #expect(outcome.code == "server_timeout")
        #expect(outcome.deferred?.kind == .approval)
    }

    @Test func serverFailuresDeferExceptARevokedMacWhichDenies() async {
        let unavailable = await evaluate("Write", #"{"file_path":"\#(box.workspacePath)/a","content":"x"}"#, decider: ScriptedDecider([.failure(.unavailable)]))
        #expect(unavailable.response.decision == .defer)
        let notAttached = await evaluate("Write", #"{"file_path":"\#(box.workspacePath)/a","content":"x"}"#, decider: nil)
        #expect(notAttached.response.decision == .defer)
        let revoked = await evaluate("Write", #"{"file_path":"\#(box.workspacePath)/a","content":"x"}"#, decider: ScriptedDecider([.failure(.revoked)]))
        #expect(revoked.response.decision == .deny)
    }

    @Test func requestsOverTheServerLimitsDeferWithoutCallingIt() async {
        let decider = ScriptedDecider()
        let long = String(repeating: "a", count: 4097)
        let outcome = await evaluate("Bash", #"{"command":"echo \#(long)"}"#, decider: decider)
        #expect(outcome.response.decision == .defer)
        #expect(decider.calls.isEmpty)
        // 서버 상한(1000자)은 넘고 OS 경로 상한(1024)은 넘지 않는 경로: 서버를 부르지 않고 defer
        let deep = (0..<((1010 - box.workspacePath.count) / 7)).map { _ in "abcdef" }.joined(separator: "/")
        let path = await evaluate("Write", #"{"file_path":"\#(box.workspacePath)/\#(deep)","content":"x"}"#, decider: decider)
        #expect(path.response.decision == .defer)
        // OS가 풀 수 없는 경로(ENAMETOOLONG)는 확인할 수 없으니 밖으로 본다 (8장 1)
        let tooDeep = (0..<200).map { _ in "abcdef" }.joined(separator: "/")
        let unresolvable = await evaluate("Write", #"{"file_path":"\#(box.workspacePath)/\#(tooDeep)","content":"x"}"#, decider: decider)
        #expect(unresolvable.response.decision == .deny)
        #expect(decider.calls.isEmpty)
    }

    func readonly(_ argv: [String], paths: [(Int?, String)]) -> BridgeV1ToolDecisionResponse {
        ScriptedDecider.response(.allow, .readonlyCommand, parse: BridgeV1ToolDecisionParse(wrapper: "none", argv: argv, paths: paths.map { .init(index: $0.0, absolute: $0.1) }, implicitCwd: paths.contains { $0.0 == nil }))
    }

    @Test func aReadOnlyCommandIsRebuiltFromTheCheckedExecutableAndPaths() async {
        box.file("src/my file's 한글.txt")
        let decider = ScriptedDecider([.success(readonly(["cat", "src/my file's 한글.txt"], paths: [(1, box.workspacePath + "/src/my file's 한글.txt")]))])
        let outcome = await evaluate("Bash", #"{"command":"cat \"src/my file's 한글.txt\""}"#, decider: decider)
        #expect(outcome.response.decision == .allow)
        #expect(outcome.response.command == "'/bin/cat' '\(box.workspacePath)/src/my file'\\''s 한글.txt'")
    }

    @Test func anImplicitCwdIsAppendedAsAnExplicitArgument() async {
        let decider = ScriptedDecider([.success(readonly(["ls", "-la"], paths: [(nil, box.workspacePath)]))])
        let outcome = await evaluate("Bash", #"{"command":"ls -la"}"#, decider: decider)
        #expect(outcome.response.command == "'/bin/ls' '-la' '\(box.workspacePath)'")
    }

    @Test func aLookalikeExecutableEarlierInPathDefers() async {
        // PATH 앞쪽 임시 폴더의 `bin/ls` 링크가 가짜 프로그램을 가리킨다: 찾은 실행 파일의 실제 경로가 /bin · /usr/bin 바로 아래가 아니다 → 로컬 defer (G12)
        let fakeProgram = box.root.appending(path: "fake-ls")
        try? FileManager.default.copyItem(atPath: "/bin/echo", toPath: fakeProgram.path)
        let bin = box.root.appending(path: "bin", directoryHint: .isDirectory)
        box.link("ls", in: bin, to: fakeProgram)
        let fake = await evaluate("Bash", #"{"command":"ls"}"#, context: context(path: bin.path + ":/usr/bin:/bin"), decider: ScriptedDecider([.success(readonly(["ls"], paths: [(nil, box.workspacePath)]))]))
        #expect(fake.response.decision == .defer)
        #expect(fake.code == "parse_check_failed")
        // 같은 이름의 복사본도 마찬가지
        let copy = box.root.appending(path: "bin2", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(atPath: "/bin/echo", toPath: copy.appending(path: "ls").path)
        let copied = await evaluate("Bash", #"{"command":"ls"}"#, context: context(path: copy.path + ":/usr/bin:/bin"), decider: ScriptedDecider([.success(readonly(["ls"], paths: [(nil, box.workspacePath)]))]))
        #expect(copied.response.decision == .defer)
        // 링크가 /bin/ls 자체를 가리키면 실행되는 것은 /bin/ls다: 재구성 명령은 실제 경로로 시작한다
        let systemLink = box.root.appending(path: "bin3", directoryHint: .isDirectory)
        box.link("ls", in: systemLink, to: URL(fileURLWithPath: "/bin/ls"))
        let linked = await evaluate("Bash", #"{"command":"ls"}"#, context: context(path: systemLink.path + ":/usr/bin:/bin"), decider: ScriptedDecider([.success(readonly(["ls"], paths: [(nil, box.workspacePath)]))]))
        #expect(linked.response.command == "'/bin/ls' '\(box.workspacePath)'")
        let real = await evaluate("Bash", #"{"command":"ls"}"#, context: context(path: "/usr/bin:/bin"), decider: ScriptedDecider([.success(readonly(["ls"], paths: [(nil, box.workspacePath)]))]))
        #expect(real.response.decision == .allow)
    }

    @Test func aParsedPathWhoseRealPathLeavesTheWorkspaceDefers() async {
        box.file("secret.txt", in: box.outside)
        box.link("escape", to: box.outside)
        let decider = ScriptedDecider([.success(readonly(["cat", "escape/secret.txt"], paths: [(1, box.workspacePath + "/escape/secret.txt")]))])
        let outcome = await evaluate("Bash", #"{"command":"cat escape/secret.txt"}"#, decider: decider)
        #expect(outcome.response.decision == .defer)
        #expect(outcome.code == "parse_check_failed")
    }

    @Test func policyAutoAllowsWritesButNeverABashCommand() async {
        let write = await evaluate("Write", #"{"file_path":"\#(box.workspacePath)/a","content":"x"}"#, decider: ScriptedDecider([.success(ScriptedDecider.response(.allow, .policyAuto))]))
        #expect(write.response == HookResponse(decision: .allow, reason: ClaudeGateReason.policy))
        let bash = await evaluate("Bash", #"{"command":"rm -rf x"}"#, decider: ScriptedDecider([.success(ScriptedDecider.response(.allow, .policyAuto))]))
        #expect(bash.response.decision == .defer)
        let noParse = await evaluate("Bash", #"{"command":"ls"}"#, decider: ScriptedDecider([.success(ScriptedDecider.response(.allow, .readonlyCommand))]))
        #expect(noParse.response.decision == .defer)
    }

    @Test func serverDenyCarriesTheAgentNote() async {
        let note = await evaluate("Write", #"{"file_path":"\#(box.workspacePath)/a","content":"x"}"#, decider: ScriptedDecider([.success(ScriptedDecider.response(.deny, .pathInUse, note: "a is being changed by another task (#139). Do other work first or wait."))]))
        #expect(note.response == HookResponse(decision: .deny, reason: "a is being changed by another task (#139). Do other work first or wait."))
        let plain = await evaluate("Write", #"{"file_path":"\#(box.workspacePath)/a","content":"x"}"#, decider: ScriptedDecider([.success(ScriptedDecider.response(.deny, .writeGateClosed))]))
        #expect(plain.response == HookResponse(decision: .deny, reason: ClaudeGateReason.policyDenied))
    }

    @Test func aServerDeferBecomesAnApprovalQuestionThatShowsWhatRuns() async throws {
        box.file("src/a.txt")
        let write = await evaluate("Edit", #"{"file_path":"\#(box.workspacePath)/src/a.txt","old_string":"x","new_string":"y"}"#, id: "toolu_e", decider: ScriptedDecider([.success(ScriptedDecider.response(.defer, .manualWrite))]))
        #expect(write.response.decision == .defer)
        let pending = try #require(write.deferred)
        #expect(pending.question == AgentQuestion(providerRequestID: "toolu_e", kind: .approval, structured: true, text: "Edit src/a.txt", items: [
            AgentQuestionItem(id: "approval", header: "Edit file", text: "Edit src/a.txt", options: [AgentQuestionOption(label: "Allow", description: ""), AgentQuestionOption(label: "Deny", description: "")]),
        ]))
        let command = "npm   run\n build " + String(repeating: "x", count: 400)
        let bash = await evaluate("Bash", WireJSON.object(["command": .string(command)]).canonicalText, id: "toolu_b", decider: ScriptedDecider([.success(ScriptedDecider.response(.defer, .commandNotReadonly))]))
        // 줄바꿈은 ⏎, 공백 여럿은 ␠×N, 길면 앞부분 + …(+숨긴 수)… + 마지막 80 스칼라 (8장 4 · 9장 11 · 10장 9)
        let text = try #require(bash.deferred).question.text
        // 원래 417 스칼라. 앞부분 212 = "npm␠×3run⏎ build " 17 + x 195, 끝 x 80, 숨긴 수 417 − 212 − 80 = 125
        #expect(text == "Run: npm␠×3run⏎ build " + String(repeating: "x", count: 195) + "…(+125)…" + String(repeating: "x", count: 80))
        let config = await evaluate("Write", #"{"file_path":"\#(box.workspacePath)/.mcp.json","content":"{}"}"#, decider: ScriptedDecider([.success(ScriptedDecider.response(.defer, .toolConfigWrite))]))
        #expect(config.deferred?.question.text == "Write .mcp.json")
    }

    @Test func unknownServerValuesDefer() async {
        for response in [ScriptedDecider.response(.unknown("maybe"), .policyAuto), ScriptedDecider.response(.allow, .unknown("new_reason")), ScriptedDecider.response(.deny, .unknown("new_reason")),
                         ScriptedDecider.response(.allow, .policyAuto, flags: ["new_flag"])] {
            let outcome = await evaluate("Write", #"{"file_path":"\#(box.workspacePath)/a","content":"x"}"#, decider: ScriptedDecider([.success(response)]))
            #expect(outcome.response.decision == .defer, "\(response)")
        }
    }
}
#endif
