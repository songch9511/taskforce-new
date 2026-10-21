#if os(macOS) && DEBUG
import Darwin
import Foundation
import Synchronization
import Testing
import TaskforceAgentWire
@testable import TaskforceKit

/// 작업 폴더의 CLAUDE.md가 **띄운 `claude`가 받는 프롬프트 파일**(`--append-system-prompt-file`, 0600)로 가는가 (가짜 `claude`가 받은 파일을 읽어 보고서에 남긴다).
/// 새 세션 · 다음 턴 · 답 resume · 닫기 모두 같다. 읽을 수 없는 파일은 조용히 건너뛰고 턴은 그대로 돈다. 글 · 경로는 로그에 남지 않고 인자에도 없다
@Suite(.serialized)
struct ClaudeProjectInstructionsRuntimeTests {
    static let marker = "PROJECT-RULE-4f9c"

    @Test func aNewTurnAndAResumedTurnBothCarryTheWorkspaceInstructions() async throws {
        let fake = try FakeClaude()
        fake.box.file("CLAUDE.md", "Always say \(Self.marker).")
        try fake.scenario(["runs": [["steps": [["text": "One"]]], ["steps": [["text": "Two"]]]]])
        let first = EventLog()
        let identity = try await fake.turn(events: first)
        #expect(await first.wait { FakeClaude.ended($0) })
        let second = EventLog()
        _ = try await fake.turn("Next", task: "7a5c0001-0000-4000-8000-000000000002", external: FakeClaude.providerSession(identity), events: second)
        #expect(await second.wait { FakeClaude.ended($0) })
        #expect(second.contains(.turnCompleted))
        #expect(fake.report(0)?["project_instructions"] as? Bool == true, "새 세션")
        #expect(fake.report(1)?["resume"] as? Bool == true && fake.report(1)?["project_instructions"] as? Bool == true, "다음 턴(resume)")
    }

    @Test func anAnswerResumeCarriesThemToo() async throws {
        let fake = try FakeClaude()
        fake.box.file(".claude/CLAUDE.md", "Always say \(Self.marker).")
        try fake.scenario(["runs": [
            ["steps": [["tool": "mcp__tf__ask_user", "id": "toolu_q1", "input": FakeClaude.askColor]]],
            ["final_text": "Blue it is."],
        ]])
        let first = EventLog()
        let identity = try await fake.turn(events: first)
        #expect(await first.wait { FakeClaude.ended($0) })
        let second = EventLog()
        _ = try await fake.answer("toolu_q1", kind: .input, value: AgentAnswerValue(answers: ["color": .one("blue")]), external: FakeClaude.providerSession(identity), events: second)
        #expect(await second.wait { FakeClaude.ended($0) })
        #expect(second.contains(.turnCompleted))
        #expect(fake.report(0)?["project_instructions"] as? Bool == true)
        #expect(fake.report(1)?["stdin_bytes"] as? Int == 0 && fake.report(1)?["project_instructions"] as? Bool == true, "답 resume")
    }

    @Test func aWorkspaceWithoutInstructionsRunsTheSameTurnWithoutThem() async throws {
        let fake = try FakeClaude()
        try fake.scenario(["runs": [["steps": [["text": "Hello"]]]]])
        let events = EventLog()
        _ = try await fake.turn(events: events)
        #expect(await events.wait { FakeClaude.ended($0) })
        #expect(events.contains(.turnCompleted))
        #expect(fake.report(0)?["project_instructions"] as? Bool == false)
        #expect(!fake.log.events.contains("claude_instructions_skipped"), "없는 파일은 로그에도 남지 않는다")
    }

    @Test func anUnreadableFileIsSkippedSilentlyAndTheTurnStillRuns() async throws {
        let fake = try FakeClaude()
        fake.box.file("secret.md", in: fake.box.outside, "OUTSIDE-\(Self.marker)")
        fake.box.link("CLAUDE.md", to: fake.box.outside.appending(path: "secret.md"))
        try fake.scenario(["runs": [["steps": [["text": "Hello"]]]]])
        let events = EventLog()
        _ = try await fake.turn(events: events)
        #expect(await events.wait { FakeClaude.ended($0) })
        #expect(events.contains(.turnCompleted))
        #expect(fake.report(0)?["project_instructions"] as? Bool == false)
        #expect(fake.log.lines.contains("claude_instructions_skipped count=count(1) why=code(\"unusable\")"), "고정 코드 하나 · 건너뛴 수만")
        for line in fake.log.lines {
            #expect(!line.contains(Self.marker) && !line.contains("CLAUDE") && !line.contains(fake.workspace) && !line.contains("secret"), "\(line)")
        }
    }

    @Test func aFullSizeFilePassesThroughTheKeeperAsOneArgumentAndTheCutIsLogged() async throws {
        let fake = try FakeClaude()
        fake.box.file("CLAUDE.md", String(repeating: "x", count: 70_000))
        fake.box.file(".claude/CLAUDE.md", "second")
        try fake.scenario(["runs": [["steps": [["text": "Hello"]]]]])
        let events = EventLog()
        _ = try await fake.turn(events: events)
        #expect(await events.wait { FakeClaude.ended($0) })
        #expect(events.contains(.turnCompleted))
        #expect(fake.report(0)?["project_instructions"] as? Bool == true)
        #expect(fake.log.lines.contains("claude_instructions bytes=count(65536) cut=count(1) files=count(1)"), "64 KiB에서 잘렸고 둘째 파일은 못 들어왔다")
    }

    @Test func theLogNeverHoldsTheFileTextTheNameOrThePath() async throws {
        let fake = try FakeClaude()
        fake.box.file("CLAUDE.md", "Always say \(Self.marker).")
        fake.box.file("secret.md", in: fake.box.outside, "OUTSIDE-\(Self.marker)")
        fake.box.link(".claude", to: fake.box.outside)
        try fake.scenario(["runs": [["steps": [["text": "Hello"]]]]])
        let events = EventLog()
        _ = try await fake.turn(events: events)
        #expect(await events.wait { FakeClaude.ended($0) })
        #expect(fake.report(0)?["project_instructions"] as? Bool == true)
        #expect(fake.log.events.contains("claude_instructions"), "읽은 수만 남긴다")
        for line in fake.log.lines {
            #expect(!line.contains(Self.marker) && !line.contains("CLAUDE") && !line.contains(fake.workspace) && !line.contains("secret"), "\(line)")
        }
        // 서버로 가는 사건에도 글이 없다
        for event in events.all {
            #expect(!"\(event)".contains(Self.marker), "\(event)")
        }
    }

    // MARK: 프롬프트는 0600 파일로, 인자에는 없다 (검토 보안 P2)

    @Test func theSpawnGetsThePromptAsAPrivateFileBesideTheSettingsAndNeverInTheArguments() async throws {
        let fake = try FakeClaude()
        fake.box.file("CLAUDE.md", "Always say \(Self.marker).")
        try fake.scenario(["runs": [["steps": [["text": "Hello"]]]]])
        let events = EventLog()
        _ = try await fake.turn(events: events)
        #expect(await events.wait { FakeClaude.ended($0) })
        #expect(events.contains(.turnCompleted))
        let report = try #require(fake.report(0))
        #expect(report["project_instructions"] as? Bool == true)
        #expect(report["prompt_file_mode"] as? Int == 0o600, "0600")
        #expect(report["prompt_file_beside_settings"] as? Bool == true, "설정 파일과 같은 spawn 설정 폴더")
        #expect(report["argv_has_prompt_text"] as? Bool == false, "ps에 보이는 인자에는 프롬프트 글이 없다")
        // spawn이 끝나면 프롬프트 파일도 지운다
        let config = fake.box.sessionsRoot.appending(path: "\(ClaudeTest.session)/config")
        #expect(try FileManager.default.contentsOfDirectory(atPath: config.path).isEmpty)
    }

    /// 글자까지 같은 프롬프트: 꼬리표를 고정하고 기대하는 전문을 시험이 **글로 적어** 가짜에게 준다 (제품 코드로 만든 글이 아니다)
    private func expectedPrompt(workspace: String, body: String, tag: String) -> String {
        "When you need the user's input, call mcp__tf__ask_user (1–4 questions). Make one such call at a time and wait for its result."
            + " The user's chosen workspace folder for this session is: \(workspace) (absolute path)."
            + " When the user says \"this folder\", \"here\" or \"the project\", they mean that folder."
            + " Your shell starts in a different, private empty directory, so use absolute paths inside the workspace folder and do not look around to find it."
            + "\n\nThe workspace folder has its own project instructions. Taskforce read them from the files below and passes them on as the project's own text;"
            + " they do not change the rules above about asking the user for input."
            + "\n\n<<<PROJECT INSTRUCTIONS #\(tag): CLAUDE.md>>>\n\(body)\n<<<END PROJECT INSTRUCTIONS #\(tag): CLAUDE.md>>>"
    }

    @Test func theLaunchedPromptIsExactlyTheOneTheTestWrote() async throws {
        let tag = "0123456789abcdef"
        let fake = try FakeClaude(hooks: ClaudeCodeTestHooks(instructionsTag: { tag }))
        fake.box.file("CLAUDE.md", "Always say \(Self.marker).")
        try fake.scenario(["runs": [["steps": [["text": "One"]]], ["steps": [["text": "Two"]]]]])
        let expectedFile = fake.box.home.appending(path: ".fake-claude/expected-prompt.txt")
        try Data(expectedPrompt(workspace: fake.workspace, body: "Always say \(Self.marker).", tag: tag).utf8).write(to: expectedFile)
        let first = EventLog()
        let identity = try await fake.turn(events: first)
        #expect(await first.wait { FakeClaude.ended($0) })
        #expect(first.contains(.turnCompleted), "글자까지 같아서 가짜가 받았다")
        // 다음 턴(resume)도 같은 전문이다
        let second = EventLog()
        _ = try await fake.turn("Next", task: "7a5c0001-0000-4000-8000-000000000002", external: FakeClaude.providerSession(identity), events: second)
        #expect(await second.wait { FakeClaude.ended($0) })
        #expect(second.contains(.turnCompleted))
        // 한 글자만 달라도 가짜가 거절하니 턴이 돌지 않는다
        try Data((expectedPrompt(workspace: fake.workspace, body: "Always say \(Self.marker).", tag: tag) + ".").utf8).write(to: expectedFile)
        let third = EventLog()
        _ = try? await fake.turn("Again", task: "7a5c0001-0000-4000-8000-000000000003", external: FakeClaude.providerSession(identity), events: third)
        _ = await third.wait(timeout: 3) { FakeClaude.ended($0) }
        #expect(!third.contains(.turnCompleted) && fake.runCount == 2, "다른 전문은 가짜가 거절해 세 번째 실행이 돌지 않았다")
    }

    // MARK: 닫기 spawn도 같다

    @Test func aCloseSpawnCarriesTheInstructionsToo() async throws {
        let fake = try FakeClaude()
        fake.box.file("CLAUDE.md", "Always say \(Self.marker).")
        try fake.scenario(["runs": [["steps": [["tool": "mcp__tf__ask_user", "id": "toolu_q", "input": FakeClaude.askColor]]], [:]]])
        let first = EventLog()
        let identity = try await fake.turn(events: first)
        #expect(await first.wait { FakeClaude.ended($0) })
        let ref = AgentRequestRef(
            taskID: ClaudeTest.task, sessionID: ClaudeTest.session, requestID: "toolu_q", externalSessionID: FakeClaude.providerSession(identity), workspaceRef: fake.workspace
        )
        try await fake.process.closeRequest(ref)
        let close = try #require(fake.report(1))
        #expect(close["stdin_bytes"] as? Int == 0 && close["resume"] as? Bool == true, "닫기 spawn = 빈 stdin resume")
        #expect(close["project_instructions"] as? Bool == true)
    }

    // MARK: 느린 읽기는 기한에서 건너뛴다 (검토 보안 P3-4)

    @Test func aReadThatStallsPastTheDeadlineIsSkippedAndTheTurnStillStarts() async throws {
        let hooks = ClaudeCodeTestHooks(readInstructions: { _ in
            Thread.sleep(forTimeInterval: 3)
            return ClaudeProjectInstructions.Outcome(instructions: ClaudeProjectInstructions(files: [.init(name: "CLAUDE.md", text: "late", truncated: false)]), skipped: 0)
        })
        var timing = ClaudeCodeTiming.ci
        timing.instructionsDeadline = 0.3
        let fake = try FakeClaude(hooks: hooks, timing: timing)
        try fake.scenario(["runs": [["steps": [["text": "Hello"]]]]])
        let started = Date()
        let events = EventLog()
        _ = try await fake.turn(events: events)
        #expect(await events.wait { FakeClaude.ended($0) })
        #expect(Date().timeIntervalSince(started) < 2.5, "막힌 읽기를 기다리지 않고 기한(0.3초)에서 넘어갔다")
        #expect(events.contains(.turnCompleted))
        #expect(fake.report(0)?["project_instructions"] as? Bool == false, "늦게 온 글은 쓰지 않는다")
        #expect(fake.log.lines.contains("claude_instructions_skipped count=count(1) why=code(\"timeout\")"))
    }

    // MARK: 작업 폴더마다 읽기는 하나 (막힌 읽기가 쌓이지 않는다)

    @Test func aStuckReadBlocksFurtherReadsOfTheSameWorkspaceUntilItsWorkerActuallyReturns() async throws {
        let gate = DispatchSemaphore(value: 0)
        let calls = Mutex<Int>(0)
        let hooks = ClaudeCodeTestHooks(readInstructions: { _ in
            let n = calls.withLock { count -> Int in
                count += 1
                return count
            }
            if n == 1 { gate.wait() }
            return ClaudeProjectInstructions.Outcome(instructions: ClaudeProjectInstructions(files: [.init(name: "CLAUDE.md", text: "Rule from the worker", truncated: false)]), skipped: 0)
        })
        var timing = ClaudeCodeTiming.ci
        timing.instructionsDeadline = 0.3
        let fake = try FakeClaude(hooks: hooks, timing: timing)
        try fake.scenario(["runs": [["steps": [["text": "One"]]], ["steps": [["text": "Two"]]], ["steps": [["text": "Three"]]]]])
        // 첫 턴: 읽기가 막혀 기한(0.3초)에서 건너뛴다
        let first = EventLog()
        let identity = try await fake.turn(events: first)
        #expect(await first.wait { FakeClaude.ended($0) })
        #expect(fake.report(0)?["project_instructions"] as? Bool == false)
        #expect(fake.log.lines.contains("claude_instructions_skipped count=count(1) why=code(\"timeout\")"))
        #expect(fake.process.instructionReadInFlight(fake.workspace), "기한이 지나도 일꾼이 돌아오기 전까지는 읽는 중이다")
        // 둘째 턴: 같은 작업 폴더의 읽기가 아직 막혀 있다 → 새 일꾼을 띄우지 않고 바로 건너뛴다 (busy)
        let second = EventLog()
        _ = try await fake.turn("Next", task: "7a5c0001-0000-4000-8000-000000000002", external: FakeClaude.providerSession(identity), events: second)
        #expect(await second.wait { FakeClaude.ended($0) })
        #expect(fake.report(1)?["project_instructions"] as? Bool == false)
        #expect(fake.log.lines.contains("claude_instructions_skipped count=count(1) why=code(\"busy\")"))
        #expect(calls.withLock { $0 } == 1, "막힌 일꾼이 더 쌓이지 않았다")
        // 일꾼이 돌아오면 다시 읽는다
        gate.signal()
        #expect(await ClaudeRereview5ReproTests.waitUntil(10) { !fake.process.instructionReadInFlight(fake.workspace) })
        let third = EventLog()
        _ = try await fake.turn("Again", task: "7a5c0001-0000-4000-8000-000000000003", external: FakeClaude.providerSession(identity), events: third)
        #expect(await third.wait { FakeClaude.ended($0) })
        #expect(fake.report(2)?["project_instructions"] as? Bool == true)
        #expect(calls.withLock { $0 } == 2)
    }

    @Test func theInFlightRegistryAllowsOneReadPerWorkspaceAndDifferentWorkspacesDoNotBlockEachOther() {
        let reads = InstructionReads()
        #expect(reads.begin("/a") && !reads.begin("/a"), "같은 작업 폴더는 하나")
        #expect(reads.begin("/b"), "다른 작업 폴더는 따로")
        #expect(reads.isReading("/a") && reads.isReading("/b"))
        reads.end("/a")
        #expect(!reads.isReading("/a") && reads.begin("/a"), "일꾼이 돌아오면 다시 읽을 수 있다")
    }

    @Test func aReadIsStuckOnlyAfterItsDeadlinePassedAndOnlyWhileItsWorkerIsStillOut() {
        let reads = InstructionReads()
        #expect(reads.begin("/a") && !reads.isStuck("/a"), "도는 중인 읽기는 막힌 것이 아니다")
        reads.markStuck("/a")
        #expect(reads.isStuck("/a") && reads.isReading("/a"))
        reads.end("/a")
        #expect(!reads.isStuck("/a") && !reads.isReading("/a"), "일꾼이 돌아오면 막힘도 풀린다")
        reads.markStuck("/a")
        #expect(!reads.isStuck("/a"), "이미 돌아온 일꾼에는 막힘을 적지 않는다 (영원히 막히지 않게)")
    }

    @Test func anOverlappingReadThatIsStillYoungIsWaitedForNotSkipped() async throws {
        // 같은 작업 폴더를 두 세션이 거의 동시에 연다. 첫 읽기는 늦지만(기한 안) 막힌 것이 아니다: 둘째가 "busy"로 지침을 잃으면 스냅샷 때문에 그 세션은 끝내 CLAUDE.md 없이 돈다
        let calls = Mutex<Int>(0)
        let hooks = ClaudeCodeTestHooks(readInstructions: { _ in
            let n = calls.withLock { count -> Int in
                count += 1
                return count
            }
            if n == 1 { Thread.sleep(forTimeInterval: 0.4) }
            return ClaudeProjectInstructions.Outcome(instructions: ClaudeProjectInstructions(files: [.init(name: "CLAUDE.md", text: "Shared rule", truncated: false)]), skipped: 0)
        })
        let fake = try FakeClaude(hooks: hooks)
        try fake.scenario(["runs": [["steps": [["text": "One"]]], ["steps": [["text": "Two"]]]]])
        func start(_ session: String, _ task: String) -> Task<AgentProcessIdentity?, Never> {
            let workspace = fake.workspace
            let process = fake.process
            return Task {
                try? await process.startTurn(AgentTurnStart(
                    taskID: task, sessionID: session, turnSeq: 1, adapter: "agent:claude-code", externalSessionID: nil, workspaceRef: workspace, resume: false, access: .write,
                    policyMode: .manual, marker: UUID().uuidString.lowercased(), text: "Hi"
                ), events: EventLog().sink)
            }
        }
        let first = start("5e551011-0000-4000-8000-000000000001", "7a5c0001-0000-4000-8000-000000000001")
        for _ in 0..<200 where calls.withLock({ $0 }) < 1 { try await Task.sleep(for: .milliseconds(5)) }
        let second = start("5e551011-0000-4000-8000-000000000002", "7a5c0001-0000-4000-8000-000000000002")
        let firstIdentity = await first.value
        let secondIdentity = await second.value
        #expect(firstIdentity != nil && secondIdentity != nil)
        #expect(!fake.log.lines.contains("claude_instructions_skipped count=count(1) why=code(\"busy\")"))
        // (가짜 claude의 실행 번호는 동시에 뜨면 겹치므로 보고서 대신 로그로 본다) 두 세션 모두 지침을 읽었다
        #expect(fake.log.lines.filter { $0.hasPrefix("claude_instructions ") }.count == 2, "두 세션 모두 지침을 받았다")
        #expect(calls.withLock { $0 } == 2)
    }
}
#endif
