#if os(macOS) && DEBUG
import Darwin
import Foundation
import Synchronization
import Testing
import TaskforceAgentWire
@testable import TaskforceKit

/// 외부 writer 검사를 대본으로 정하는 가짜 (마지막 값이 계속 간다). 받은 인자를 모두 적는다
final class ScriptedWriterCheck: ExternalWriterChecking, @unchecked Sendable {
    struct Call: Equatable {
        var sessionID: String
        var workspace: String
        var ownPIDs: Set<Int32>
        var ownLastActivity: Date?
    }

    private let lock = NSLock()
    private var verdicts: [ExternalWriterVerdict]
    private var recorded: [Call] = []

    init(_ verdicts: ExternalWriterVerdict...) { self.verdicts = verdicts.isEmpty ? [.free] : verdicts }

    var calls: [Call] { lock.withLock { recorded } }

    /// 끝에 붙인다 (앞의 값들이 다 나간 뒤 이 값이 계속 간다)
    func push(_ verdict: ExternalWriterVerdict) { lock.withLock { verdicts.append(verdict) } }

    /// 바로 다음 호출만 이 값을 받는다 (그 뒤는 지금까지의 값으로 돌아간다)
    func next(_ verdict: ExternalWriterVerdict) { lock.withLock { verdicts.insert(verdict, at: 0) } }

    func check(sessionID: String, workspace: String, ownPIDs: Set<Int32>, ownLastActivity: Date?) async -> ExternalWriterVerdict {
        lock.withLock {
            recorded.append(Call(sessionID: sessionID, workspace: workspace, ownPIDs: ownPIDs, ownLastActivity: ownLastActivity))
            return verdicts.count > 1 ? verdicts.removeFirst() : verdicts[0]
        }
    }
}

extension FakeClaude {
    static let claudeID = "5e5e5e5e-0000-4000-8000-0000000000a1"
    static let otherClaudeID = "5e5e5e5e-0000-4000-8000-0000000000b2"

    /// 로컬 Resume here 확인이 쓰는 상태를 그대로 쓴다 (`ClaudeSessionState.writeAttached`)
    @discardableResult
    func attach(provider: String = FakeClaude.claudeID, session: String = ClaudeTest.session, at: Date = Date()) throws -> ClaudeSessionFolder {
        let folder = try ClaudeSessionFolder.prepare(sessionsRoot: box.sessionsRoot, agentSessionID: session)
        guard ClaudeSessionState.writeAttached(providerSessionID: provider, at: at, in: folder.root) == .written else { throw CocoaError(.fileWriteUnknown) }
        return folder
    }

    func stateOf(_ session: String) -> ClaudeSessionState { ClaudeSessionState.load(from: box.sessionsRoot.appending(path: session)) }

    var realWorkspace: String { ClaudeSandbox.real(workspace) }

    /// 로그 줄 중 Claude id · 폴더 경로 · 사용자 글이 든 것: 없어야 한다 (로그는 코드뿐이다, 계약 9장)
    func leakyLogLines(_ text: String...) -> [String] {
        log.lines.filter { line in ([FakeClaude.claudeID, FakeClaude.otherClaudeID, realWorkspace, workspace] + text).contains { line.contains($0) } }
    }
}

/// 이어받은 세션의 adapter (OA 외부 세션 PR2m, 계약 ES-08 · ES-10 · ES-11 · ES-12 · ES-12b · 20장 3 · 4 · 5): 가짜 `claude` + 실제 helper + 실제 지킴이.
/// 시험 locator는 임시 폴더 안 실행 파일만 받는다 (실제 `claude` 실행 0 · 실제 `~/.claude` 0)
@Suite(.serialized)
struct ClaudeAttachAdapterTests {
    private func events() -> EventLog { EventLog() }

    // MARK: ES-11 · 12 · 12b: 인자와 cwd

    @Test func anAttachedTurnRunsInTheOriginalFolderWithEmptySettingSourcesAndSnapshotOff() async throws {
        let writers = ScriptedWriterCheck(.free)
        let fake = try FakeClaude(externalWriters: writers)
        try fake.scenario(["runs": [["steps": [["text": "Resumed"]]]]])
        try fake.attach()
        let log = events()
        _ = try await fake.turn("Next", external: FakeClaude.claudeID, events: log)
        #expect(await log.wait { FakeClaude.ended($0) })
        #expect(log.contains(.turnCompleted))
        let report = try #require(fake.report(0))
        #expect(report["resume"] as? Bool == true && report["session_id"] as? String == FakeClaude.claudeID)
        #expect(report["cwd"] as? String == fake.realWorkspace, "ES-11 A: cwd는 그 세션의 원래 폴더")
        #expect(report["setting_sources"] as? String == "", "ES-12 B: 빈 sources — 저장소 · 사용자 훅과 env가 들어오지 않는다")
        #expect(report["snapshot_off"] as? Bool == true, "ES-12b")
        #expect(!FileManager.default.fileExists(atPath: fake.box.sessionsRoot.appending(path: "\(ClaudeTest.session)/cwd").path), "빈 세션 cwd를 쓰지 않는다")
        #expect(fake.state.origin == .attached && fake.state.bound && fake.state.providerSessionID == FakeClaude.claudeID, "턴이 상태를 바꾸지 않는다")
        #expect(fake.leakyLogLines("Next", "Resumed").isEmpty, "이어받은 턴이 도는 동안에도 로그에 id · 경로 · 글 0")
    }

    @Test func aTaskforceSessionKeepsItsPrivateCwdAndTheProjectSource() async throws {
        let writers = ScriptedWriterCheck(.held(.claudeApp))
        let fake = try FakeClaude(externalWriters: writers)
        try fake.scenario(["runs": [["steps": [["text": "One"]]], ["steps": [["text": "Two"]]]]])
        let first = events()
        let identity = try await fake.turn(events: first)
        #expect(await first.wait { FakeClaude.ended($0) })
        let second = events()
        _ = try await fake.turn("Next", task: "7a5c0001-0000-4000-8000-000000000002", external: FakeClaude.providerSession(identity), events: second)
        #expect(await second.wait { FakeClaude.ended($0) })
        for number in 0...1 {
            let report = try #require(fake.report(number))
            #expect(report["setting_sources"] as? String == "project" && report["snapshot_off"] as? Bool == false)
            #expect(report["cwd"] as? String == ClaudeSandbox.real(fake.box.sessionsRoot.appending(path: "\(ClaudeTest.session)/cwd").path), "빈 세션 cwd")
        }
        #expect(writers.calls.isEmpty, "Taskforce가 시작한 세션은 외부 writer 검사를 부르지 않는다")
        #expect(fake.state.origin == nil)
    }

    @Test func theAttachedTurnCarriesTheWorkspaceInstructionsBecauseTheEmptySourcesKeepTheRepoFileOut() async throws {
        // 빈 `--setting-sources`라 CLI는 저장소의 CLAUDE.md를 읽지 않는다: Taskforce가 읽어 붙인다 (계약 19장: 새 세션 · 이어받은 세션 모두 같은 규칙)
        let fake = try FakeClaude(externalWriters: ScriptedWriterCheck(.free))
        fake.box.file("CLAUDE.md", "Always say PROJECT-RULE-91c2.")
        try fake.scenario(["runs": [["steps": [["text": "Resumed"]]]]])
        try fake.attach()
        let log = events()
        _ = try await fake.turn("Next", external: FakeClaude.claudeID, events: log)
        #expect(await log.wait { FakeClaude.ended($0) })
        let report = try #require(fake.report(0))
        #expect(report["setting_sources"] as? String == "" && report["project_instructions"] as? Bool == true && report["prompt_shell_in_workspace"] as? Bool == true)
        #expect(report["argv_has_prompt_text"] as? Bool == false, "프롬프트 글은 인자(ps)에 없다: 0600 파일로만")
    }

    @Test func theAttachedPromptSaysTheShellStartsInTheWorkspace() async throws {
        let fake = try FakeClaude(externalWriters: ScriptedWriterCheck(.free))
        try fake.scenario(["runs": [["steps": [["text": "Resumed"]]]]])
        try fake.attach()
        let log = events()
        _ = try await fake.turn("Next", external: FakeClaude.claudeID, events: log)
        #expect(await log.wait { FakeClaude.ended($0) })
        let report = try #require(fake.report(0))
        #expect(report["prompt_shell_in_workspace"] as? Bool == true)
    }

    // MARK: ES-08 · 20장 4: 묶은 id만, 상태 없으면 띄우지 않는다

    @Test func aServerIdThatIsNotTheBoundOneStartsNothing() async throws {
        let writers = ScriptedWriterCheck(.free)
        let fake = try FakeClaude(externalWriters: writers)
        try fake.scenario(["runs": [["steps": [["text": "x"]]]]])
        try fake.attach()
        let log = events()
        await #expect(throws: AgentStartError.self) { _ = try await fake.turn("Next", external: FakeClaude.otherClaudeID, events: log) }
        #expect(fake.runCount == 0 && log.all.isEmpty && writers.calls.isEmpty, "T6: 서버가 다른 UUID를 보냈다 → 띄우기 0, 검사도 하지 않는다")
        #expect(fake.state.providerSessionID == FakeClaude.claudeID, "상태는 그대로")
    }

    @Test func aSessionNobodyAttachedStartsNothingEvenWithARealLookingId() async throws {
        let writers = ScriptedWriterCheck(.free)
        let fake = try FakeClaude(externalWriters: writers)
        try fake.scenario(["runs": [["steps": [["text": "x"]]]]])
        let log = events()
        await #expect(throws: AgentStartError.self) { _ = try await fake.turn("Next", external: FakeClaude.claudeID, events: log) }
        #expect(fake.runCount == 0, "이 Mac이 이어받은 적 없다: 서버가 고른 id를 이어 띄우지 않는다")
        #expect(fake.state.providerSessionID == nil && !fake.state.bound)
    }

    @Test func aBoundFlagWithoutTheAttachedOriginOfAnotherIdStillStartsNothing() async throws {
        let fake = try FakeClaude(externalWriters: ScriptedWriterCheck(.free))
        try fake.scenario(["runs": [["steps": [["text": "x"]]]]])
        let folder = try ClaudeSessionFolder.prepare(sessionsRoot: fake.box.sessionsRoot, agentSessionID: ClaudeTest.session)
        var state = ClaudeSessionState()
        state.providerSessionID = FakeClaude.otherClaudeID
        state.bound = true
        try state.save(in: folder.root)
        let log = events()
        await #expect(throws: AgentStartError.self) { _ = try await fake.turn("Next", external: FakeClaude.claudeID, events: log) }
        #expect(fake.runCount == 0)
    }

    @Test func anAttachedFolderNeverStartsANewSessionOverTheBoundOne() async throws {
        let fake = try FakeClaude(externalWriters: ScriptedWriterCheck(.free))
        try fake.scenario(["runs": [["steps": [["text": "x"]]]]])
        try fake.attach()
        let log = events()
        // 서버가 외부 id 없이(첫 턴처럼) 명령을 보냈다: 새 세션 갈래가 묶인 상태를 덮는다
        await #expect(throws: AgentStartError.self) { _ = try await fake.turn("Next", external: nil, events: log) }
        #expect(fake.runCount == 0)
        let state = fake.state
        #expect(state.bound && state.providerSessionID == FakeClaude.claudeID && state.origin == .attached, "묶인 상태를 다른 id로 덮지 않는다 (20장 3)")
    }

    // MARK: ES-10: 턴마다 외부 writer 검사

    @Test func aSessionHeldByTheClaudeAppIsNotResumedAndTheReasonIsRemembered() async throws {
        let writers = ScriptedWriterCheck(.held(.claudeApp))
        let fake = try FakeClaude(externalWriters: writers)
        try fake.scenario(["runs": [["steps": [["text": "x"]]]]])
        try fake.attach()
        let log = events()
        await #expect(throws: AgentStartError.self) { _ = try await fake.turn("Next", external: FakeClaude.claudeID, events: log) }
        #expect(fake.runCount == 0, "접수 전 실패: 프로세스 0")
        #expect(await fake.process.externalHold(forAgentSession: ClaudeTest.session) == .held(.claudeApp), "이 Mac이 이유를 기억한다 (세션 패널 DZ-8)")
        #expect(writers.calls.count == 1 && writers.calls[0].sessionID == FakeClaude.claudeID && writers.calls[0].workspace == fake.realWorkspace)
        #expect(fake.log.events.contains("claude_external_writer"), "막은 이유를 코드로 남긴다")
        #expect(fake.leakyLogLines("Next").isEmpty, "로그에 id · 경로 · 글 0")
    }

    @Test func everyKindOfHolderAndAFailedCheckBlock() async throws {
        for verdict in [ExternalWriterVerdict.held(.terminal), .held(.background), .held(.unknown), .unknown] {
            let fake = try FakeClaude(externalWriters: ScriptedWriterCheck(verdict))
            try fake.scenario(["runs": [["steps": [["text": "x"]]]]])
            try fake.attach()
            let log = events()
            await #expect(throws: AgentStartError.self) { _ = try await fake.turn("Next", external: FakeClaude.claudeID, events: log) }
            #expect(fake.runCount == 0, "\(verdict)")
            #expect(fake.leakyLogLines("Next").isEmpty, "\(verdict): 로그에 id · 경로 · 글 0")
        }
    }

    @Test func withoutACheckerAnAttachedSessionIsNeverResumed() async throws {
        let fake = try FakeClaude()
        try fake.scenario(["runs": [["steps": [["text": "x"]]]]])
        try fake.attach()
        let log = events()
        await #expect(throws: AgentStartError.self) { _ = try await fake.turn("Next", external: FakeClaude.claudeID, events: log) }
        #expect(fake.runCount == 0, "검사할 길이 없으면 모른다 → 막는다 (fail-closed)")
    }

    @Test func theCheckRunsOnEveryTurnAndTheReasonClearsWhenTheOwnerIsGone() async throws {
        let writers = ScriptedWriterCheck(.held(.terminal), .free)
        let fake = try FakeClaude(externalWriters: writers)
        try fake.scenario(["runs": [["steps": [["text": "One"]]], ["steps": [["text": "Two"]]]]])
        try fake.attach()
        let blocked = events()
        await #expect(throws: AgentStartError.self) { _ = try await fake.turn("Next", external: FakeClaude.claudeID, events: blocked) }
        #expect(await fake.process.externalHold(forAgentSession: ClaudeTest.session) == .held(.terminal))
        let first = events()
        _ = try await fake.turn("Again", task: "7a5c0001-0000-4000-8000-000000000002", external: FakeClaude.claudeID, events: first)
        #expect(await first.wait { FakeClaude.ended($0) })
        #expect(first.contains(.turnCompleted))
        #expect(await fake.process.externalHold(forAgentSession: ClaudeTest.session) == nil, "닫힌 뒤에는 이유가 사라진다")
        let third = events()
        writers.push(.free)
        _ = try await fake.turn("Third", task: "7a5c0001-0000-4000-8000-000000000003", external: FakeClaude.claudeID, events: third)
        #expect(await third.wait { FakeClaude.ended($0) })
        #expect(writers.calls.count == 3, "턴마다 본다")
    }

    @Test func ourOwnLastActivityIsHandedToTheCheckSoOurWriteIsNotAnotherWriter() async throws {
        let writers = ScriptedWriterCheck(.free)
        let fake = try FakeClaude(externalWriters: writers)
        try fake.scenario(["runs": [["steps": [["text": "One"]]], ["steps": [["text": "Two"]]]]])
        try fake.attach()
        let before = Date()
        let first = events()
        _ = try await fake.turn("Next", external: FakeClaude.claudeID, events: first)
        #expect(await first.wait { FakeClaude.ended($0) })
        let second = events()
        _ = try await fake.turn("Again", task: "7a5c0001-0000-4000-8000-000000000002", external: FakeClaude.claudeID, events: second)
        #expect(await second.wait { FakeClaude.ended($0) })
        let calls = writers.calls
        #expect(calls.count == 2 && calls[0].ownLastActivity == nil)
        let last = try #require(calls[1].ownLastActivity)
        #expect(last >= before && last <= Date(), "앞 턴이 끝난 때")
    }

    @Test func theLivePidsOfOurOtherProcessesAreHandedToTheCheckAsOurs() async throws {
        let writers = ScriptedWriterCheck(.free)
        let fake = try FakeClaude(externalWriters: writers)
        // 첫 실행(다른 세션의 턴)은 결과 뒤에도 잠시 산다: 그 pid는 우리 혈통이다
        try fake.scenario(["runs": [["steps": [["text": "slow"]], "linger_after_result": 6.0], ["steps": [["text": "Two"]]]]])
        try fake.attach()
        let otherSession = "5e551011-0000-4000-8000-0000000000e2"
        let logOther = events()
        let identity = try await fake.process.startTurn(AgentTurnStart(
            taskID: "7a5c0001-0000-4000-8000-0000000000e2", sessionID: otherSession, turnSeq: 1, adapter: "agent:claude-code", externalSessionID: nil, workspaceRef: fake.workspace,
            resume: false, access: .write, policyMode: .manual, marker: UUID().uuidString.lowercased(), text: "slow"
        ), events: logOther.sink)
        let log = events()
        _ = try await fake.turn("Next", external: FakeClaude.claudeID, events: log)
        #expect(await log.wait { FakeClaude.ended($0) })
        let pid = try #require(identity.pid)
        #expect(writers.calls.first?.ownPIDs.contains(Int32(pid)) == true, "같은 adapter가 띄워 살아 있는 프로세스는 외부 writer가 아니다")
        _ = await logOther.wait { FakeClaude.ended($0) }
    }

    // MARK: 답 · 닫기도 같은 길

    @Test func anAnswerResumeOfAnAttachedSessionIsCheckedAndRunsInTheSameIsolation() async throws {
        let writers = ScriptedWriterCheck(.free, .held(.claudeApp), .free)
        let fake = try FakeClaude(externalWriters: writers)
        try fake.scenario(["runs": [
            ["steps": [["tool": "mcp__tf__ask_user", "id": "toolu_q1", "input": FakeClaude.askColor]]],
            ["final_text": "Blue it is."],
        ]])
        try fake.attach()
        let first = events()
        _ = try await fake.turn("Ask me", external: FakeClaude.claudeID, events: first)
        #expect(await first.wait { FakeClaude.ended($0) })
        #expect(fake.state.openDeferred?.id == "toolu_q1")
        let blocked = events()
        await #expect(throws: AgentStartError.self) {
            _ = try await fake.answer("toolu_q1", kind: .input, value: AgentAnswerValue(answers: ["color": .one("blue")]), external: FakeClaude.claudeID, events: blocked)
        }
        #expect(fake.runCount == 1, "데스크톱이 쥐었다: 답 resume도 띄우지 않는다")
        let second = events()
        let result = try await fake.answer("toolu_q1", kind: .input, value: AgentAnswerValue(answers: ["color": .one("blue")]), external: FakeClaude.claudeID, events: second)
        guard case .delivered = result else {
            Issue.record("\(result)")
            return
        }
        #expect(await second.wait { FakeClaude.ended($0) })
        let report = try #require(fake.report(1))
        #expect(report["cwd"] as? String == fake.realWorkspace && report["setting_sources"] as? String == "" && report["snapshot_off"] as? Bool == true)
    }

    @Test func closingAnAttachedSessionsRequestIsCheckedToo() async throws {
        let writers = ScriptedWriterCheck(.free, .held(.terminal))
        let fake = try FakeClaude(externalWriters: writers)
        try fake.scenario(["runs": [
            ["steps": [["tool": "mcp__tf__ask_user", "id": "toolu_q1", "input": FakeClaude.askColor]]],
            ["final_text": "closed"],
        ]])
        try fake.attach()
        let first = events()
        _ = try await fake.turn("Ask me", external: FakeClaude.claudeID, events: first)
        #expect(await first.wait { FakeClaude.ended($0) })
        await #expect(throws: AgentStartError.self) {
            try await fake.process.closeRequest(AgentRequestRef(
                taskID: ClaudeTest.task, sessionID: ClaudeTest.session, requestID: "toolu_q1", externalSessionID: FakeClaude.claudeID, workspaceRef: fake.workspace
            ))
        }
        #expect(fake.runCount == 1, "터미널이 쥐었다: 닫기 spawn도 없다")
    }

    /// 계약 20장 4: `requireBound`는 모든 길에서 적용된다 — 서버가 준 id가 묶인 id와 다르면 답 · 닫기도 띄우지 않는다 (이어받은 세션 · Taskforce가 시작한 세션 모두)
    @Test func anAnswerOrACloseNamingAnotherClaudeIdThanTheBoundOneStartsNothing() async throws {
        for attached in [false, true] {
            let fake = try FakeClaude(externalWriters: ScriptedWriterCheck(.free))
            try fake.scenario(["runs": [["steps": [["tool": "mcp__tf__ask_user", "id": "toolu_q1", "input": FakeClaude.askColor]]]]])
            if attached { try fake.attach() }
            let first = events()
            _ = try await fake.turn("Ask me", external: attached ? FakeClaude.claudeID : nil, events: first)
            #expect(await first.wait { FakeClaude.ended($0) }, "attached=\(attached)")
            #expect(fake.runCount == 1 && fake.state.openDeferred?.id == "toolu_q1", "attached=\(attached)")
            let answered = events()
            await #expect(throws: AgentStartError.self) {
                _ = try await fake.answer("toolu_q1", kind: .input, value: AgentAnswerValue(answers: ["color": .one("blue")]), external: FakeClaude.otherClaudeID, events: answered)
            }
            await #expect(throws: AgentStartError.self) {
                try await fake.process.closeRequest(AgentRequestRef(
                    taskID: ClaudeTest.task, sessionID: ClaudeTest.session, requestID: "toolu_q1", externalSessionID: FakeClaude.otherClaudeID, workspaceRef: fake.workspace
                ))
            }
            #expect(fake.runCount == 1, "attached=\(attached): 다른 id로는 답도 닫기도 띄우지 않는다")
        }
    }

    @Test func aProcessOfOursThatIsStillEndingIsNotAnExternalWriterAndItsWritesAreOurs() async throws {
        let writers = ScriptedWriterCheck(.free)
        let fake = try FakeClaude(externalWriters: writers)
        // 결과 뒤에도 잠시 사는 첫 턴: 다음 턴을 시작할 때 그 프로세스는 아직 등록부에 있다
        try fake.scenario(["runs": [["steps": [["text": "One"]], "linger_after_result": 2.0], ["steps": [["text": "Two"]]]]])
        try fake.attach()
        let first = events()
        let identity = try await fake.turn("Next", external: FakeClaude.claudeID, events: first)
        #expect(await first.wait { $0.contains(.turnCompleted) })
        let second = events()
        let before = Date()
        _ = try await fake.turn("Again", task: "7a5c0001-0000-4000-8000-000000000002", external: FakeClaude.claudeID, events: second)
        #expect(await second.wait { FakeClaude.ended($0) })
        // 첫 턴 · 둘째 턴(앞 프로세스를 기다리기 전) · 둘째 턴(기다린 뒤 다시): 기다렸으므로 한 번 더 본다
        #expect(writers.calls.count == 3)
        guard writers.calls.count == 3 else { return }
        let call = writers.calls[1]
        #expect(call.ownPIDs.contains(Int32(try #require(identity.pid))), "아직 끝나는 중인 우리 프로세스의 pid")
        let last = try #require(call.ownLastActivity)
        #expect(abs(last.timeIntervalSince(before)) < 5, "그 프로세스가 도는 동안의 기록 쓰기는 우리 쓰기다 (지금까지)")
        let recheck = writers.calls[2]
        let ended = try #require(recheck.ownLastActivity)
        #expect(ended >= before && abs(ended.timeIntervalSince(before)) < 6, "기다린 뒤에는 앞 프로세스가 끝난 때까지의 쓰기가 우리 쓰기다")
        _ = await first.wait { FakeClaude.ended($0) }
    }

    // MARK: 기다린 뒤 다시 본다 (코드 검토 P2 · 보안 P3-1: 앞 spawn을 기다리는 동안 외부 writer가 생길 수 있다)

    @Test func aWriterThatAppearsWhileWeWaitForOurOwnPreviousProcessStopsTheTurn() async throws {
        // 첫 턴 · 둘째 턴의 기다리기 전 · 기다린 뒤: 기다린 사이 터미널이 그 세션을 열었다
        let writers = ScriptedWriterCheck(.free, .free, .held(.terminal))
        let fake = try FakeClaude(externalWriters: writers)
        try fake.scenario(["runs": [["steps": [["text": "One"]], "linger_after_result": 2.0], ["steps": [["text": "Two"]]]]])
        try fake.attach()
        let first = events()
        _ = try await fake.turn("Next", external: FakeClaude.claudeID, events: first)
        #expect(await first.wait { $0.contains(.turnCompleted) })
        let second = events()
        await #expect(throws: AgentStartError.self) {
            _ = try await fake.turn("Again", task: "7a5c0001-0000-4000-8000-000000000002", external: FakeClaude.claudeID, events: second)
        }
        #expect(fake.runCount == 1, "기다린 사이 쥔 곳이 생겼다: 둘째 프로세스를 띄우지 않는다")
        #expect(writers.calls.count == 3)
        #expect(await fake.process.externalHold(forAgentSession: ClaudeTest.session) == .held(.terminal), "이유를 기억한다 (세션 패널)")
        _ = await first.wait { FakeClaude.ended($0) }
    }

    @Test func aWriterThatAppearsWhileAnAnswerOrACloseWaitsStopsThemToo() async throws {
        let ask: [String: Any] = ["steps": [["tool": "mcp__tf__ask_user", "id": "toolu_q1", "input": FakeClaude.askColor]], "linger_after_result": 2.0]
        for closing in [false, true] {
            let writers = ScriptedWriterCheck(.free, .free, .held(.claudeApp))
            let fake = try FakeClaude(externalWriters: writers)
            try fake.scenario(["runs": [ask, ["final_text": "never"]]])
            try fake.attach()
            let first = events()
            _ = try await fake.turn("Ask me", external: FakeClaude.claudeID, events: first)
            // 열린 질문이 적혔을 때 첫 프로세스는 아직 산다 (결과 뒤 linger): 답 · 닫기는 그 프로세스를 기다린다
            #expect(await first.wait { _ in fake.state.openDeferred?.id == "toolu_q1" }, "closing=\(closing)")
            let answered = events()
            await #expect(throws: AgentStartError.self) {
                if closing {
                    try await fake.process.closeRequest(AgentRequestRef(
                        taskID: ClaudeTest.task, sessionID: ClaudeTest.session, requestID: "toolu_q1", externalSessionID: FakeClaude.claudeID, workspaceRef: fake.workspace
                    ))
                } else {
                    _ = try await fake.answer("toolu_q1", kind: .input, value: AgentAnswerValue(answers: ["color": .one("blue")]), external: FakeClaude.claudeID, events: answered)
                }
            }
            #expect(fake.runCount == 1 && writers.calls.count == 3, "closing=\(closing): 기다린 뒤에 다시 보고 막힌다")
            _ = await first.wait { FakeClaude.ended($0) }
        }
    }

    /// 코드 검토 M1b: 로컬 확인이 외부 writer 검사 뒤 · 상태를 읽기 전에(기다리는 동안) 이어받음 상태를 썼다. 외부 id 없는 시작(서버가 먼저 쌓아 둔 새 세션 명령)은 그 상태를 새 id로 덮지 않는다.
    /// 같은 id · 다른 id의 턴도 이어받음 상태를 검사 없이 띄우지 않는다
    @Test func aTurnThatRacesTheLocalAttachNeverOverwritesTheStateTheAttachJustWrote() async throws {
        for external in [String?.none, FakeClaude.otherClaudeID, FakeClaude.claudeID] {
            let holder = FakeHolder()
            let fake = try FakeClaude(
                hooks: ClaudeCodeTestHooks(beforeSessionIdleWait: {
                    guard let fake = holder.fake, let folder = try? ClaudeSessionFolder.prepare(sessionsRoot: fake.box.sessionsRoot, agentSessionID: ClaudeTest.session) else { return }
                    _ = ClaudeSessionState.writeAttached(providerSessionID: FakeClaude.claudeID, at: Date(), in: folder.root)
                }),
                externalWriters: ScriptedWriterCheck(.free)
            )
            holder.fake = fake
            try fake.scenario(["runs": [["steps": [["text": "x"]]]]])
            // 이 세션은 아직 이어받기 전이다 (검사는 이어받은 세션이 아니라고 보고 지나간다)
            let log = events()
            await #expect(throws: AgentStartError.self, "external=\(external ?? "nil")") { _ = try await fake.turn("Next", external: external, events: log) }
            let state = fake.state
            #expect(fake.runCount == 0, "external=\(external ?? "nil"): 띄우지 않는다")
            #expect(state.origin == .attached && state.bound && state.providerSessionID == FakeClaude.claudeID, "external=\(external ?? "nil"): 이어받음 상태가 그대로다 (새 id로 덮지 않는다)")
        }
    }

    final class FakeHolder: @unchecked Sendable { var fake: FakeClaude? }

    // MARK: 로컬 확인이 쓰는 면 (AttachableSessionAdapter)

    @Test func bindingWritesTheAttachedStateAndReadsBackWhatTheCommandPathSees() async throws {
        let fake = try FakeClaude(externalWriters: ScriptedWriterCheck(.free))
        let at = Date()
        #expect(await fake.process.bindAttached(agentSessionID: ClaudeTest.session, providerSessionID: FakeClaude.claudeID, at: at) == .written)
        #expect(fake.state.origin == .attached && fake.state.bound && fake.state.providerSessionID == FakeClaude.claudeID)
        #expect(await fake.process.isAttached(agentSession: ClaudeTest.session))
        let since = try #require(await fake.process.attachedSince(agentSession: ClaudeTest.session))
        #expect(abs(since.timeIntervalSince(at)) < 0.01)
        // 다시 묶으면 멱등 · 다른 id는 거절
        #expect(await fake.process.bindAttached(agentSessionID: ClaudeTest.session, providerSessionID: FakeClaude.claudeID, at: at.addingTimeInterval(100)) == .alreadyAttached)
        #expect(await fake.process.bindAttached(agentSessionID: ClaudeTest.session, providerSessionID: FakeClaude.otherClaudeID, at: at) == .refused)
        #expect(fake.state.providerSessionID == FakeClaude.claudeID)
    }

    @Test func aClaudeSessionAnotherTaskforceSessionAlreadyHoldsIsNeverBoundTwice() async throws {
        let fake = try FakeClaude(externalWriters: ScriptedWriterCheck(.free))
        try fake.attach(provider: FakeClaude.claudeID, session: ClaudeTest.session)
        let other = "5e551011-0000-4000-8000-0000000000e2"
        #expect(await fake.process.bindAttached(agentSessionID: other, providerSessionID: FakeClaude.claudeID, at: Date()) == .refused, "한 Claude 세션에 writer 하나")
        #expect(!(await fake.process.isAttached(agentSession: other)))
        #expect(fake.stateOf(other).providerSessionID == nil)
        #expect(await fake.process.bindAttached(agentSessionID: other, providerSessionID: FakeClaude.otherClaudeID, at: Date()) == .written, "다른 Claude 세션은 된다")
    }

    @Test func bindingRefusesAnIdThatCouldBeAnArgumentOrAPathAndAnAgentSessionThatIsNotAUUID() async throws {
        let fake = try FakeClaude(externalWriters: ScriptedWriterCheck(.free))
        for bad in [FakeClaude.claudeID.uppercased(), "-r", "../x", "/tmp/a.jsonl", ""] {
            #expect(await fake.process.bindAttached(agentSessionID: ClaudeTest.session, providerSessionID: bad, at: Date()) == .refused, "\(bad)")
        }
        #expect(await fake.process.bindAttached(agentSessionID: "../escape", providerSessionID: FakeClaude.claudeID, at: Date()) == .refused)
        #expect(fake.state.providerSessionID == nil)
    }

    @Test func probingTheWriterUsesTheSameCheckerAndFailsClosedWithoutOne() async throws {
        let writers = ScriptedWriterCheck(.held(.terminal))
        let fake = try FakeClaude(externalWriters: writers)
        #expect(await fake.process.probeExternalWriter(providerSessionID: FakeClaude.claudeID, workspace: fake.realWorkspace) == .held(.terminal))
        #expect(writers.calls.count == 1 && writers.calls[0].ownLastActivity == nil)
        let bare = try FakeClaude()
        #expect(await bare.process.probeExternalWriter(providerSessionID: FakeClaude.claudeID, workspace: bare.realWorkspace) == .unknown)
    }

    // MARK: 터미널 · 보기

    @Test func theTerminalValuesOfAnAttachedSessionDoNotNeedTheEmptyCwd() async throws {
        let fake = try FakeClaude(externalWriters: ScriptedWriterCheck(.free))
        try fake.attach()
        let session = try #require(await fake.process.terminalSession(ClaudeTest.session))
        #expect(session.providerSessionID == FakeClaude.claudeID, "묶은 id만 (서버 값이 아니다)")
        // 새 세션 · 묶이지 않은 세션과 달리 빈 cwd가 없어도 값을 준다 (원래 폴더에서 이어받는다: 런타임이 폴더로 바꾼다)
        #expect(await fake.process.isAttached(agentSession: ClaudeTest.session))
        #expect(!(await fake.process.isAttached(agentSession: "5e551011-0000-4000-8000-0000000000ff")))
    }
}
#endif
