#if os(macOS) && DEBUG
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import TaskforceKit

/// 검토 반영 (OA D3a 계약 8장) — 실행 파일 8 · resume id 10 · 프로세스 감독 12–18 · 승인 대상 2의 상태 파일.
/// 가짜 `claude` + 실제 helper + (런타임 항목은) 가짜 bridge 서버. 이름 앞의 `aN`이 8장 항목 번호다
@Suite(.serialized)
struct ClaudeReviewProcessTests {
    static let allow = AgentAnswerValue(answers: ["approval": .one("allow")])

    /// 프로세스가 없거나 좀비다 (launchd가 거두기 전)
    static func gone(_ pid: Int) -> Bool {
        switch ClaudeProcessInspector.kernel(pid: pid_t(pid)) {
        case .gone: true
        case .present(let listed): listed.zombie
        case .failed: false
        }
    }

    static func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    // MARK: 2 승인 대상 지문은 상태 파일에 해시로만

    @Test func a2TheApprovedTargetIsCheckedOnResumeAndKeptAsAHashOnly() async throws {
        let fake = try FakeClaude(decider: ScriptedDecider([.success(ScriptedDecider.response(.defer, .manualWrite))]))
        fake.box.file("other.txt", "other")
        try fake.scenario(["runs": [
            ["steps": [["tool": "Write", "id": "toolu_w1", "input": ["file_path": fake.workspace + "/out.txt", "content": "hello"]]]],
            ["final_text": "Done."],
        ]])
        let first = EventLog()
        let identity = try await fake.turn(events: first)
        #expect(await first.wait { FakeClaude.ended($0) })
        let digest = try #require(fake.state.openDeferred?.targetSHA256)
        #expect(digest.count == 64)
        let stateText = try String(contentsOf: fake.box.sessionsRoot.appending(path: "\(ClaudeTest.session)/state.json"), encoding: .utf8)
        #expect(!stateText.contains(fake.workspace) && !stateText.contains("out.txt"), "상태 파일에 경로 0")
        // 기다리는 동안 out.txt 자리에 다른 파일을 가리키는 링크가 생겼다
        fake.box.link("out.txt", to: fake.box.workspace.appending(path: "other.txt"))
        let result = try await fake.answer("toolu_w1", kind: .approval, value: Self.allow, external: FakeClaude.providerSession(identity), events: EventLog())
        #expect(result == .requestClosed)
        #expect((try? String(contentsOfFile: fake.workspace + "/other.txt", encoding: .utf8)) == "other")
    }

    // MARK: 8 검사한 실제 경로로 띄운다

    @Test func a8TheCheckedRealPathIsWhatRunsWhileArgv0StaysTheCandidate() async throws {
        let fake = try FakeClaude(linked: true)
        try fake.scenario(["runs": [["steps": [["text": "ok"]]]]])
        let events = EventLog()
        _ = try await fake.turn(events: events)
        #expect(await events.wait { FakeClaude.ended($0) })
        let report = try #require(fake.report(0))
        #expect(report["exec_path"] as? String == fake.box.home.appending(path: "versions/claude-fake").path)
        #expect(report["argv0"] as? String == fake.claude.path)
    }

    // MARK: 10 묶인 세션 id만 resume

    @Test func a10OnlyTheSessionIDBoundInTheSessionFolderIsResumed() async throws {
        let fake = try FakeClaude()
        try fake.scenario(["runs": [["steps": [["text": "x"]]]]])
        let stranger = "0e09f680-f476-4f2e-96d9-670f24599f6d"
        await #expect(throws: AgentStartError(.spawnFailed)) { _ = try await fake.turn(external: stranger, events: EventLog()) }
        // 상태 파일에 그 id가 있어도 init이 돌려준 적이 없으면(묶이지 않음) resume하지 않는다
        let folder = try ClaudeSessionFolder.prepare(sessionsRoot: fake.box.sessionsRoot, agentSessionID: ClaudeTest.session)
        var state = ClaudeSessionState()
        state.providerSessionID = stranger
        state.bound = false
        state.openDeferred = ClaudeSessionState.OpenDeferred(id: "toolu_q", kind: "input", inputSHA256: "d", spawnID: UUID().uuidString, at: Date())
        try state.save(in: folder.root)
        await #expect(throws: AgentStartError(.spawnFailed)) { _ = try await fake.turn(external: stranger, events: EventLog()) }
        await #expect(throws: AgentStartError(.spawnFailed)) {
            _ = try await fake.answer("toolu_q", kind: .input, value: AgentAnswerValue(text: "x"), external: stranger, events: EventLog())
        }
        await #expect(throws: AgentStartError(.spawnFailed)) {
            try await fake.process.closeRequest(AgentRequestRef(taskID: ClaudeTest.task, sessionID: ClaudeTest.session, requestID: "toolu_q", externalSessionID: stranger, workspaceRef: fake.workspace))
        }
        #expect(fake.runCount == 0)
    }

    // MARK: 12 Stop: 확인 못 하면 끝났다고 하지 않는다

    @Test func a12AStopWithoutARegisteredRunNeverClaimsAnUnprovenEnd() async throws {
        let fake = try FakeClaude()
        fake.allowReadonlyCat("notes.md")
        try fake.scenario(["runs": [["steps": [["tool": "Bash", "id": "toolu_b", "input": ["command": "cat notes.md"], "sleep": 30]]]]])
        let events = EventLog()
        let identity = try await fake.turn(events: events)
        for _ in 0..<500 where fake.report(0)?["sleep_pid"] == nil { try await Task.sleep(for: .milliseconds(20)) }
        // 앱이 다시 떴다: 새 adapter의 등록부는 비어 있다
        let restarted = ClaudeCodeProcess(sessionsRoot: fake.box.sessionsRoot, hookServer: nil, helpers: ClaudeCodeHelpers(hook: "/x", mcp: "/y", keeper: "/z"),
                                          locator: ClaudeCodeLocator(candidates: [], confinedTo: fake.box.root.path), timing: .testing)
        var unprovable = identity
        unprovable.processMarker = "not-a-marker"
        for target in [nil, unprovable] as [AgentProcessIdentity?] {
            let result = await restarted.interrupt(AgentTurnRef(taskID: ClaudeTest.task, sessionID: ClaudeTest.session, identity: target), scope: .turnAndProcesses)
            #expect(result != .notRunning, "\(String(describing: target))")
        }
        #expect(ClaudeProcessInspector.liveness(identity) == .alive, "확인 못 한 정체에는 신호 0")
        // 원장의 정체로 확인하고 끝까지 끝냈을 때만 "돌고 있지 않다"
        let proven = await restarted.interrupt(AgentTurnRef(taskID: ClaudeTest.task, sessionID: ClaudeTest.session, identity: identity), scope: .turnAndProcesses)
        #expect(proven == .notRunning)
        #expect(await restarted.liveness(identity) == .ended(AgentExit(code: nil)))
        #expect(await events.wait { FakeClaude.ended($0) })
    }

    // MARK: 13 자손까지 끝나야 끝

    @Test func a13ARunEndsOnlyAfterTheDescendantsInItsGroupAreGone() async throws {
        let fake = try FakeClaude()
        try fake.scenario(["runs": [["leave_child": true, "steps": [["text": "bye"]]]]])
        let events = EventLog()
        let identity = try await fake.turn(events: events)
        #expect(await events.wait { FakeClaude.ended($0) })
        let child = try #require(fake.report(0)?["left_child_pid"] as? Int)
        #expect(Self.gone(child), "ended를 내기 전에 남은 자손을 끝냈다")
        let group = pid_t(try #require(identity.pid))
        #expect(await Self.waitUntil(2) { killpg(group, 0) != 0 })
        #expect(events.contains(.turnCompleted))
    }

    // MARK: 15 끝이 증명돼야 다음 writer

    @Test func a15TheNextWriterStartsOnlyAfterTheLastOneIsProvenEnded() async throws {
        let timing = ClaudeCodeTiming(orphanInterruptGrace: 0.3, orphanKillGrace: 0.3, closeTimeout: 1, exitAfterResult: 3, drainAfterExit: 1, probeTimeout: 5, serverTimeout: 5)
        let fake = try FakeClaude(hooks: ClaudeCodeTestHooks(terminateOverride: { _ in .unknown }), timing: timing)
        fake.allowReadonlyCat("notes.md")
        try fake.scenario(["runs": [["steps": [["tool": "Bash", "id": "toolu_b", "input": ["command": "cat notes.md"], "sleep": 30]]], ["steps": [["text": "second"]]]]])
        let events = EventLog()
        let identity = try await fake.turn(events: events)
        for _ in 0..<500 where fake.report(0)?["sleep_pid"] == nil { try await Task.sleep(for: .milliseconds(20)) }
        let session = FakeClaude.providerSession(identity)
        await #expect(throws: AgentStartError(.spawnFailed)) {
            _ = try await fake.turn("next", task: "7a5c0001-0000-4000-8000-000000000002", external: session, events: EventLog())
        }
        await #expect(throws: AgentStartError(.spawnFailed)) {
            try await fake.process.closeRequest(AgentRequestRef(taskID: ClaudeTest.task, sessionID: ClaudeTest.session, requestID: "toolu_x", externalSessionID: session, workspaceRef: fake.workspace))
        }
        #expect(fake.runCount == 1, "끝을 증명하지 못했으면 다음 프로세스 0")
        // 정리: 진짜로 끝낸다
        let lineage = ClaudeLineage(file: fake.box.sessionsRoot.appending(path: "lineage/\(identity.processMarker).lineage"))
        _ = try await offPool { ClaudeProcessInspector.terminate(identity, timing: timing, lineage: lineage) }
        #expect(await events.wait { FakeClaude.ended($0) })
    }

    // MARK: 17 상태 저장이 질문의 전제

    @Test func a17AQuestionIsNotSentWhenItsOpenRequestCannotBeSaved() async throws {
        let fake = try FakeClaude()
        try fake.scenario(["runs": [["steps": [["tool": "mcp__tf__ask_user", "id": "toolu_q", "input": FakeClaude.askColor]]], ["steps": []]]])
        // state.json 자리에 폴더: 저장이 실패한다
        let folder = try ClaudeSessionFolder.prepare(sessionsRoot: fake.box.sessionsRoot, agentSessionID: ClaudeTest.session)
        try FileManager.default.createDirectory(at: folder.root.appending(path: "state.json"), withIntermediateDirectories: true)
        let events = EventLog()
        _ = try await fake.turn(events: events)
        #expect(await events.wait { FakeClaude.ended($0) })
        #expect(events.questions.isEmpty, "답할 수 없는 질문을 내지 않는다")
        #expect(events.contains(.failed(.agentError)))
        // 보류한 호출은 닫기 모드로 거절했다
        #expect(fake.runCount == 2)
        let decisions = fake.report(1)?["decisions"] as? [[String: Any]] ?? []
        #expect(decisions.first?["id"] as? String == "toolu_q" && decisions.first?["decision"] as? String == "deny")
    }

    // MARK: 18 산출물 해시

    @Test func a18ArtifactHashesReadOnlyRegularFilesUnderTheCap() async throws {
        let box = ClaudeSandbox()
        let small = box.file("a.txt", "hello")
        let expected = "sha256:" + SHA256.hash(data: Data("hello".utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(ClaudeCodeProcess.artifactHash(atPath: small.path, limit: 1024) == expected)
        #expect(ClaudeCodeProcess.artifactHash(atPath: small.path, limit: 4) == nil, "상한을 넘으면 해시하지 않는다")
        #expect(ClaudeCodeProcess.artifactHash(atPath: box.workspacePath, limit: 1024) == nil, "폴더")
        let fifo = box.workspace.appending(path: "pipe").path
        #expect(mkfifo(fifo, 0o600) == 0)
        // 일반 파일이 아니면 읽지 않는다 (FIFO 열기에서 멈추지 않는다). 옛 동작이면 2초 뒤 쓰는 쪽을 열어 풀어 준다
        let unblock = Task.detached {
            try? await Task.sleep(for: .seconds(2))
            let fd = open(fifo, O_WRONLY | O_NONBLOCK)
            if fd >= 0 { close(fd) }
        }
        let started = Date()
        let hash = try await offPool { ClaudeCodeProcess.artifactHash(atPath: fifo, limit: 1024) }
        unblock.cancel()
        #expect(hash == nil)
        #expect(Date().timeIntervalSince(started) < 1.5)
    }
}

// MARK: 런타임과 함께 (14)

@Suite(.serialized)
struct ClaudeReviewAnswerRuntimeTests {
    /// 결정기는 대본으로 바꾸고, 새 프로세스 정체 기록은 런타임 것을 그대로 쓴다
    func harness(_ fake: FakeClaude) async throws -> BridgeHarness {
        let harness = try BridgeHarness(withAdapter: false, workspace: fake.workspace)
        try await harness.restart(adapters: [fake.process], reopenLedger: false)
        let runtime = harness.runtime
        fake.process.attach(AgentRuntimeServices(decideTool: fake.decider.function, recordSpawn: { taskID, identity in
            await runtime.recordSpawnIdentity(taskID: taskID, identity: identity)
        }))
        await harness.registerFirst()
        return harness
    }

    // MARK: 14 답 resume의 새 프로세스는 답 전달 전에 원장에 (A7)

    @Test func a14TheAnswerProcessIsInTheLedgerBeforeTheAnswerReachesIt() async throws {
        let fake = try FakeClaude()
        try fake.scenario(["runs": [
            ["steps": [["tool": "mcp__tf__ask_user", "id": "toolu_q", "input": FakeClaude.askColor]]],
            ["pause_before_resume_hook": 3.0, "final_text": "Blue."],
        ]])
        let h = try await harness(fake)
        let created = h.message("Hi")
        await h.runtime.tick()
        await h.settle { (try? await h.ledger.task(created.taskID))?.openRequestID == "toolu_q" }
        let before = await h.task(created.taskID)?.pid
        let answer = try #require(h.server.enqueueAnswer(bridgeID: h.bridgeID, taskID: created.taskID, requestID: "toolu_q", answers: ["color": "blue"]))
        h.clock.jump(by: 6)
        let ticking = Task { await h.runtime.tick() }
        #expect(await h.eventually { fake.report(1) != nil })
        let spawned = try #require(fake.report(1)?["pid"] as? Int)
        #expect(spawned != before)
        // 가짜가 답 훅 전에 3초 기다린다: 그 사이 원장에는 새 pid가 있고, 답 전달은 아직 적히지 않았다
        #expect(await h.eventually(timeout: 2.5) { await h.task(created.taskID)?.pid == spawned }, "답을 전달하기 전에 새 pid가 원장에 있다")
        #expect(await h.command(answer.commandID)?.answerSentAt == nil)
        await ticking.value
        #expect(await h.command(answer.commandID)?.answerSentAt != nil)
        #expect(await h.command(answer.commandID)?.inputAt != nil)
    }
}
#endif
