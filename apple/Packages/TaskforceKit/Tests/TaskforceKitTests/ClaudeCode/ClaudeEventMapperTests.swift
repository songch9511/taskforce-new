#if os(macOS)
import Foundation
import Testing
import TaskforceAgentWire
@testable import TaskforceKit

/// stream-json → 형태 있는 사건 + 자체 점검 (OA D3a 계약 2.8 · 2.9 · 4.2). S0(2.1.241) 실측 줄을 그대로 먹인다.
/// run 2 파일은 `--tools` 없이 · SessionStart 훅 없이 돌아서 ② · ③은 run 3 파일(`r3-cc11-1` 등)로 본다
struct ClaudeEventMapperTests {
    static let workspace = "$SCR/proj"
    static let cwd = "$SCR/tf-cwd"

    struct Run {
        var actions: [ClaudeMapperAction] = []
        var events: [AgentEvent] { actions.compactMap { if case .emit(let event) = $0 { event } else { nil } } }
        var interrupts: [ClaudeInterruptCause] { actions.compactMap { if case .interrupt(let cause) = $0 { cause } else { nil } } }
    }

    /// 픽스처를 처음부터 끝까지 먹인다. `answered`는 bridge가 소켓으로 답한 id (기본: 파일의 모든 tool_use id와 `extraAnswered`)
    static func run(
        _ name: String, mode: ClaudeMapperConfig.Mode = .turn(newSessionID: nil), tools: Set<String>? = nil, sessionStart: Bool = false, cwd: String? = nil,
        answered: Set<String>? = nil, extraAnswered: [String: String] = [:], filePaths: [String: String] = [:], pending: ClaudePendingDeferred? = nil, sessionID: String? = nil,
        interruptRequested: Bool = false, start: Date = Date(timeIntervalSince1970: 1000), step: TimeInterval = 0.1
    ) throws -> Run {
        let lines = try ClaudeTest.fixture(name)
        let uses = ClaudeTest.toolUses(in: lines).merging(extraAnswered) { first, _ in first }
        var facts = ClaudeSpawnFacts()
        facts.answered = answered ?? Set(uses.keys)
        facts.toolNames = uses
        facts.filePaths = filePaths
        facts.pending = pending
        let config = ClaudeMapperConfig(
            mode: mode, expectedSessionID: sessionID, expectedTools: tools, expectedCwd: cwd, requireSessionStart: sessionStart, workspaceRealPath: workspace,
            versionSupported: { ClaudeCodeSupport.supports($0) }
        )
        var mapper = ClaudeEventMapper(config: config)
        if interruptRequested { mapper.markInterruptRequested() }
        var run = Run()
        var now = start
        for line in lines {
            now = now.addingTimeInterval(step)
            guard let event = ClaudeStreamParser.parse(line) else { continue }
            run.actions += mapper.consume(event, facts: facts, now: now)
        }
        run.actions += mapper.finish()
        return run
    }

    static func question(_ id: String, kind: BridgeV1PendingQuestionKind = .input) -> ClaudePendingDeferred {
        let question = AgentQuestion(providerRequestID: id, kind: kind, structured: true, text: "Which color?", items: [AgentQuestionItem(id: "color", header: "", text: "Which color?", options: [])])
        return ClaudePendingDeferred(id: id, kind: kind, inputSHA256: "d", toolName: "mcp__tf__ask_user", question: question)
    }

    // MARK: 정상 턴 (r2-lt1)

    @Test func aTrivialTurnIsAcceptedMessagedAndCompleted() throws {
        for name in ["r2-lt1-trivial-1", "r2-lt1-trivial-2", "r2-lt1-trivial-3"] {
            let run = try Self.run(name)
            #expect(run.events == [.inputReached, .accepted, .message(text: "OK"), .turnCompleted], "\(name)")
            #expect(run.interrupts.isEmpty)
        }
    }

    @Test func aNewSessionIsBoundAtInitWithTheWorkspace() throws {
        let run = try Self.run("r2-lt1-trivial-1", mode: .turn(newSessionID: "2c4bde0f-3c30-4976-80df-ce1603668f72"), sessionID: "2c4bde0f-3c30-4976-80df-ce1603668f72")
        #expect(Array(run.events.prefix(2)) == [.inputReached, .sessionBound(externalSessionID: "2c4bde0f-3c30-4976-80df-ce1603668f72", workspaceRef: Self.workspace)])
    }

    // MARK: 자체 점검 ② ③ (r3-cc11-1, G18 · G19)

    @Test func theRestrictedToolSetWithTfConnectedPassesTheInitChecksAndDefersAQuestion() throws {
        let pending = Self.question("toolu_01BHLsvBzENgVdhX2qSAFRSm")
        let run = try Self.run("r3-cc11-1-tools-allowlist-mcp", tools: ClaudeCodeSupport.initTools(for: .write), sessionStart: true, cwd: Self.cwd, pending: pending)
        #expect(run.interrupts.isEmpty)
        #expect(run.events.contains(.accepted))
        #expect(run.actions.contains(.confirmQuestion(pending)))
        #expect(!run.events.contains(.turnCompleted), "보류는 턴 끝이 아니다")
    }

    @Test func aDifferentToolSetFailsCheckTwoBeforeAcceptance() throws {
        let run = try Self.run("r3-cc11-1-tools-allowlist-mcp", tools: ClaudeCodeSupport.initTools(for: .readOnly), sessionStart: true, cwd: Self.cwd)
        #expect(run.interrupts == [.selfCheck(2)])
        #expect(run.events == [.inputReached, .failed(.spawnFailed)])
    }

    @Test func aWrongCwdOrSessionAlsoFailsCheckTwo() throws {
        let cwd = try Self.run("r3-cc11-1-tools-allowlist-mcp", tools: ClaudeCodeSupport.initTools(for: .write), sessionStart: true, cwd: "/elsewhere")
        #expect(cwd.interrupts == [.selfCheck(2)])
        let session = try Self.run("r3-cc11-1-tools-allowlist-mcp", tools: ClaudeCodeSupport.initTools(for: .write), sessionStart: true, cwd: Self.cwd, sessionID: "00000000-0000-4000-8000-000000000000")
        #expect(session.interrupts == [.selfCheck(2)])
    }

    @Test func aMissingSessionStartMarkerFailsCheckThree() throws {
        // run 2 파일에는 SessionStart 훅이 없다
        let run = try Self.run("r2-lt1-trivial-1", sessionStart: true)
        #expect(run.interrupts == [.selfCheck(3)])
        #expect(run.events == [.inputReached, .failed(.spawnFailed)])
        let badJSON = try Self.run("r3-cc13-settings-badjson", sessionStart: true)
        #expect(badJSON.interrupts == [.selfCheck(3)], "깨진 settings는 훅 사건이 하나도 없다")
    }

    @Test func aBadSchemaSettingsFileStillShowsTheSessionStartMarkerWhichIsWhyCheckOneExists() throws {
        // SessionStart만 살아남고 PreToolUse는 조용히 빠진다 (CC-13). 이 턴은 도구를 쓰지 않아 ③ · ④로는 잡히지 않는다 → spawn 전 ① 검증이 막는다
        let run = try Self.run("r3-cc13-settings-badschema", sessionStart: true)
        #expect(run.interrupts.isEmpty)
        #expect(run.events.contains(.turnCompleted))
    }

    // MARK: ④ (r3-cc12, r3-cc10, G20)

    @Test func everyToolResultFollowsItsOwnPreToolUseHookAndABridgeAnswer() throws {
        let pending = Self.question("toolu_01AznNjyxvdfHgjtxkZgZvXQ")
        let run = try Self.run("r3-cc12-default-deny-matrix", pending: pending)
        #expect(run.interrupts.isEmpty)
        #expect(run.actions.contains(.confirmQuestion(pending)))
        #expect(run.events.filter { $0 == .accepted }.count == 1)
    }

    @Test func aToolResultWithoutABridgeAnswerStopsTheSpawn() throws {
        // 훅 사건은 있으나 bridge는 답하지 않았다 (S0 silent hook)
        let run = try Self.run("r3-cc10-bash-manual-silent-hook", answered: [])
        #expect(run.interrupts == [.selfCheck(4)])
        #expect(run.events.last == .failed(.agentError))
        #expect(!run.events.contains(.turnCompleted))
    }

    @Test func aToolResultWithoutAHookStartedEventStopsTheSpawn() throws {
        // r2-cc3-allow는 PreToolUse 훅 사건이 있다: 훅 사건을 지운 줄로 ④를 깬다
        var lines = try ClaudeTest.fixture("r2-cc3-allow")
        lines.removeAll { String(decoding: $0, as: UTF8.self).contains("\"hook_started\"") }
        var facts = ClaudeSpawnFacts()
        facts.toolNames = ClaudeTest.toolUses(in: lines)
        facts.answered = Set(facts.toolNames.keys)
        var mapper = ClaudeEventMapper(config: ClaudeMapperConfig(mode: .turn(newSessionID: nil), expectedSessionID: nil, expectedTools: nil, expectedCwd: nil, requireSessionStart: false,
                                                                   workspaceRealPath: Self.workspace, versionSupported: { _ in true }))
        var actions: [ClaudeMapperAction] = []
        for line in lines { if let event = ClaudeStreamParser.parse(line) { actions += mapper.consume(event, facts: facts, now: Date()) } }
        #expect(actions.contains(.interrupt(.selfCheck(4))))
    }

    // MARK: 보류 · 답 resume (r3-cc9, r2-cc2mcp, r2-cc5b)

    @Test func onlyTheLastDeferredCallIsReportedAndConfirmed() throws {
        let reported = Self.question("toolu_01RT8MqssFmM3xiqAbQwBWp5", kind: .approval)
        let run = try Self.run("r3-cc9-1-two-deferred-writes", pending: reported)
        #expect(run.actions.contains(.confirmQuestion(reported)))
        let other = Self.question("toolu_014WYFaGC39PcnsiQu9PBP7m", kind: .approval)
        let mismatch = try Self.run("r3-cc9-1-two-deferred-writes", pending: other)
        #expect(mismatch.actions.contains(.unexpectedDeferred("toolu_01RT8MqssFmM3xiqAbQwBWp5")))
        #expect(mismatch.events.last == .failed(.agentError))
    }

    @Test func anAnswerResumeRunsTheDeferredHookAndToolResultBeforeInit() throws {
        // 계약 침묵을 실측으로 고정: SessionStart:resume → command_lifecycle → 보류 id의 PreToolUse 훅 → tool_result → **그 뒤에** system/init
        let lines = try ClaudeTest.fixture("r3-cc9-2-resume-answer-reported-only")
        let kinds = lines.compactMap { ClaudeStreamParser.parse($0) }.map(\.kindName)
        let initIndex = try #require(kinds.firstIndex(of: "init"))
        let hookIndex = try #require(kinds.firstIndex(of: "hook_started:PreToolUse:Write"))
        let resultIndex = try #require(kinds.firstIndex(of: "tool_result"))
        #expect(hookIndex < resultIndex && resultIndex < initIndex)
        let next = Self.question("toolu_01Tg84VW6s17yCKJDPhfrrwD", kind: .approval)
        // 보류 id의 tool_use는 앞 프로세스에 있었다: 이름 · 대상 경로는 bridge가 훅 요청에서 본 값을 쓴다
        let run = try Self.run("r3-cc9-2-resume-answer-reported-only", mode: .answer(requestID: "toolu_01RT8MqssFmM3xiqAbQwBWp5"), sessionStart: true,
                               extraAnswered: ["toolu_01RT8MqssFmM3xiqAbQwBWp5": "Write"], filePaths: ["toolu_01RT8MqssFmM3xiqAbQwBWp5": "$SCR/proj/b.txt"], pending: next)
        #expect(run.interrupts.isEmpty)
        #expect(!run.events.contains(.accepted), "답 resume는 접수를 다시 내지 않는다")
        #expect(!run.events.contains(.inputReached))
        #expect(run.actions.contains(.confirmQuestion(next)))
        #expect(run.actions.contains(.artifacts([ClaudeArtifactCandidate(tool: "Write", filePath: "$SCR/proj/b.txt")])))
    }

    @Test func anAnswerResumeWhoseInitArrivesBeforeTheDeferredHookIsTreatedAsLost() throws {
        let run = try Self.run("r2-lt1-trivial-1", mode: .answer(requestID: "toolu_gone"), answered: [])
        #expect(run.interrupts == [.answerLost])
    }

    @Test func aNonEmptyResumePromptRanASecondTurnWhichIsWhyResumesAreEmpty() throws {
        // r2-cc2mcp-2: "Continue." 프롬프트로 resume → 결과 둘, 같은 Write가 두 번 보류됐다 (CC-2). 첫 result 뒤의 사건은 무시한다
        let pending = Self.question("toolu_01JWAKhGVERhpHexg9EArH1K", kind: .approval)
        let run = try Self.run("r2-cc2mcp-2-resume-answered", mode: .answer(requestID: "toolu_01WVNZfPnvLJDCokBagvQEVT"), extraAnswered: ["toolu_01WVNZfPnvLJDCokBagvQEVT": "mcp__tf__ask_user"], pending: pending)
        #expect(run.actions.filter { if case .confirmQuestion = $0 { true } else { false } }.count == 1)
    }

    @Test func aDeferSurvivesAKillAndTheSameIDIsAnsweredOnResume() throws {
        let pending = Self.question("toolu_019g3R9JKbKQq6QaFHaPMU3J")
        let before = try Self.run("r2-cc5b-kill9-after-defer", pending: pending)
        #expect(before.actions.contains(.confirmQuestion(pending)))
        let next = Self.question("toolu_01RT1ftcZcpvGqDqMkNGaaAK", kind: .approval)
        let after = try Self.run("r2-cc5b-resume-after-kill9", mode: .answer(requestID: "toolu_019g3R9JKbKQq6QaFHaPMU3J"), extraAnswered: ["toolu_019g3R9JKbKQq6QaFHaPMU3J": "mcp__tf__ask_user"], pending: next)
        #expect(after.interrupts.isEmpty)
        #expect(after.actions.contains(.confirmQuestion(next)))
    }

    @Test func aDeniedStaleQuestionEndsTheTurnCleanly() throws {
        let run = try Self.run("r3-cc9-3-resume-deny-stale-question", mode: .answer(requestID: "toolu_015m7x9cBb7pQSBmH54iJqch"), sessionStart: true, extraAnswered: ["toolu_015m7x9cBb7pQSBmH54iJqch": "mcp__tf__ask_user"])
        #expect(run.events.last == .turnCompleted)
        #expect(run.interrupts.isEmpty)
    }

    // MARK: 닫기 모드 (G29)

    @Test func closeModeEmitsNothingAndInterruptsAtTheClosingResult() throws {
        let run = try Self.run("r3-cc9-3-resume-deny-stale-question", mode: .close(requestID: "toolu_015m7x9cBb7pQSBmH54iJqch"), extraAnswered: ["toolu_015m7x9cBb7pQSBmH54iJqch": "mcp__tf__ask_user"])
        #expect(run.events.isEmpty)
        #expect(run.interrupts.first == .closeDone)
    }

    @Test func closeModeInterruptsAtTheFirstEventWhenTheClosingHookNeverCame() throws {
        let run = try Self.run("r2-lt1-trivial-1", mode: .close(requestID: "toolu_gone"), answered: [])
        #expect(run.events.isEmpty)
        #expect(run.interrupts.first == .closeDone)
    }

    // MARK: 중단 · 로그인 · 강제 종료

    @Test func aRequestedInterruptMapsTheAbortedResultToCancelled() throws {
        let run = try Self.run("r2-cc4-sigint-sleep", interruptRequested: true)
        #expect(run.events.last == .cancelled)
        #expect(run.events.contains(.accepted))
    }

    @Test func anAbortedResultWeDidNotAskForIsAnAgentError() throws {
        let run = try Self.run("r2-cc4-sigint-sleep")
        #expect(run.events.last == .failed(.agentError))
    }

    @Test func aSyntheticNotLoggedInTurnIsSignInNeededAndNeverAccepted() throws {
        let run = try Self.run("r2-cc8-empty-home-after-login")
        #expect(run.events == [.inputReached, .failed(.signInNeeded)])
        #expect(run.actions.contains(.signInNeeded))
    }

    @Test func aKillAfterInitLeavesNoResultAndNoTerminalEvent() throws {
        let run = try Self.run("r2-cc5a-kill9-in-hook-wait")
        #expect(run.events.contains(.inputReached))
        #expect(!run.events.contains(.turnCompleted))
        #expect(run.events.allSatisfy { if case .failed = $0 { false } else { $0 != .cancelled } })
    }

    @Test func deniedCallsComeBackAsErrorResultsAndTheTurnStillCompletes() throws {
        let run = try Self.run("r2-cc3-deny")
        #expect(run.events.last == .turnCompleted)
        #expect(!run.actions.contains { if case .artifacts(let list) = $0 { !list.isEmpty } else { false } }, "거절된 Write는 산출물이 아니다")
        let allow = try Self.run("r2-cc3-allow")
        #expect(allow.actions.contains(.artifacts([ClaudeArtifactCandidate(tool: "Write", filePath: "$SCR/proj/hello.txt")])))
    }

    // MARK: 묶기 · 상한

    @Test func progressIsBatchedToOneEveryTwoSeconds() throws {
        let fast = try Self.run("r3-cc12-default-deny-matrix", pending: Self.question("toolu_01AznNjyxvdfHgjtxkZgZvXQ"), step: 0.01)
        let slow = try Self.run("r3-cc12-default-deny-matrix", pending: Self.question("toolu_01AznNjyxvdfHgjtxkZgZvXQ"), step: 3)
        let fastCount = fast.events.filter { $0 == .progress }.count
        let slowCount = slow.events.filter { $0 == .progress }.count
        #expect(fastCount == 1)
        #expect(slowCount > 5)
    }

    @Test func textBlocksOfOneMessageAreJoinedAndThinkingIsDropped() throws {
        let run = try Self.run("r3-cc12-default-deny-matrix", pending: Self.question("toolu_01AznNjyxvdfHgjtxkZgZvXQ"))
        let messages = run.events.compactMap { if case .message(let text) = $0 { text } else { nil } }
        #expect(messages.first == "Step 1 worked \u{2014} read README.md successfully.")
        #expect(messages.count == 4)
    }

    @Test func anOversizedLineStopsTheSpawn() {
        var mapper = ClaudeEventMapper(config: ClaudeMapperConfig(mode: .turn(newSessionID: nil), expectedSessionID: nil, expectedTools: nil, expectedCwd: nil, requireSessionStart: false,
                                                                  workspaceRealPath: "/w", versionSupported: { _ in true }))
        #expect(mapper.oversizedLine() == [.interrupt(.selfCheck(6)), .emit(.failed(.agentError))])
        #expect(mapper.oversizedLine().isEmpty, "끝난 뒤에는 아무것도 내지 않는다")
    }

    @Test func aVersionOutsideTheRangeAtInitIsVersionUnsupported() throws {
        var lines = try ClaudeTest.fixture("r3-cc11-1-tools-allowlist-mcp")
        lines = lines.map { Data(String(decoding: $0, as: UTF8.self).replacingOccurrences(of: "\"claude_code_version\":\"2.1.241\"", with: "\"claude_code_version\":\"2.2.0\"").utf8) }
        var facts = ClaudeSpawnFacts()
        facts.toolNames = ClaudeTest.toolUses(in: lines)
        facts.answered = Set(facts.toolNames.keys)
        var mapper = ClaudeEventMapper(config: ClaudeMapperConfig(mode: .turn(newSessionID: nil), expectedSessionID: nil, expectedTools: ClaudeCodeSupport.initTools(for: .write), expectedCwd: Self.cwd,
                                                                  requireSessionStart: true, workspaceRealPath: Self.workspace, versionSupported: { ClaudeCodeSupport.supports($0) }))
        var actions: [ClaudeMapperAction] = []
        for line in lines { if let event = ClaudeStreamParser.parse(line) { actions += mapper.consume(event, facts: facts, now: Date()) } }
        #expect(actions.contains(.interrupt(.selfCheck(2))))
        #expect(actions.contains(.emit(.failed(.versionUnsupported))))
    }

    @Test func initRecordsOnlyWhetherPluginsSkillsAndAMessagingSocketExist() throws {
        let lines = try ClaudeTest.fixture("r3-cc12-default-deny-matrix")
        let infos = lines.compactMap { line -> ClaudeInitInfo? in
            if case .systemInit(let info)? = ClaudeStreamParser.parse(line) { info } else { nil }
        }
        let info = try #require(infos.first)
        #expect(info.hasMessagingSocket)
        #expect(info.hasSkills)
        #expect(!info.hasPlugins)
    }
}
#endif
