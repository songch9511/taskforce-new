#if os(macOS) && DEBUG
import Darwin
import Foundation
import Synchronization
import Testing
@testable import TaskforceKit

/// 재검토 반영 (OA D3a 계약 9장) — 가리개 범위 1 · 분리된 자손 4 · 일반 Stop 6 · 비동기 판정 뒤 7 · 정체 먼저 8 · 답 대기 9 · 닫기 동안 자리 10.
/// 가짜 `claude` + 실제 helper + 실제 소켓. 이름 앞의 `bN`이 9장 항목 번호다
@Suite(.serialized)
struct ClaudeRereviewProcessTests {
    static let secret = "CANARY-SECRET-7f3a"
    static let allow = AgentAnswerValue(answers: ["approval": .one("allow")])
    static var askSecret: [String: Any] { ["questions": [["id": "key", "header": "Key", "text": "Paste the API key", "secret": true]]] }

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

    static func texts(_ events: [AgentEvent]) -> [String] {
        events.flatMap { event -> [String] in
            switch event {
            case .message(let text): [text]
            case .question(let question): [question.text] + question.items.map(\.text)
            default: []
            }
        }
    }

    // MARK: 1 가리개의 범위 = agent 세션

    @Test func b1ASecretStaysRedactedInLaterSpawnsOfTheSameSession() async throws {
        let fake = try FakeClaude()
        try fake.scenario(["runs": [
            ["steps": [["tool": "mcp__tf__ask_user", "id": "toolu_secret", "input": Self.askSecret]]],
            // 답 resume: 값을 되말하고 명령에 넣는다 → 가린 명령은 승인 카드
            ["steps": [["text": "Your key \(Self.secret) works."], ["tool": "Bash", "id": "toolu_c1", "input": ["command": "printf %s \(Self.secret) >/dev/null"]]]],
            // 승인 resume: 두 번째 명령 · 메시지
            ["steps": [["text": "Second \(Self.secret)"], ["tool": "Bash", "id": "toolu_c2", "input": ["command": "echo \(Self.secret) >/dev/null"]]]],
            // 거절 resume
            ["final_text": "Declined \(Self.secret)"],
            // 다음 턴
            ["final_text": "Again \(Self.secret)"],
        ]])
        let first = EventLog()
        let identity = try await fake.turn(events: first)
        #expect(await first.wait { FakeClaude.ended($0) })
        let session = FakeClaude.providerSession(identity)
        var all: [AgentEvent] = []
        for (request, value) in [("toolu_secret", AgentAnswerValue(text: Self.secret)), ("toolu_c1", Self.allow), ("toolu_c2", AgentAnswerValue(answers: ["approval": .one("deny")]))] {
            let events = EventLog()
            let kind: BridgeV1PendingQuestionKind = request == "toolu_secret" ? .input : .approval
            let result = try await fake.answer(request, kind: kind, value: value, external: session, events: events)
            guard case .delivered = result else {
                Issue.record("\(request): \(result)")
                return
            }
            #expect(await events.wait { FakeClaude.ended($0) })
            all += events.all
        }
        let next = EventLog()
        _ = try await fake.turn("Next", task: "7a5c0001-0000-4000-8000-000000000002", external: session, events: next)
        #expect(await next.wait { FakeClaude.ended($0) })
        all += next.all
        let texts = Self.texts(all)
        #expect(texts.contains("Second [redacted]"), "승인 resume의 메시지")
        #expect(texts.contains { $0.hasPrefix("Run: echo [redacted]") }, "두 번째 명령의 카드")
        #expect(texts.contains("Declined [redacted]"))
        #expect(texts.contains("Again [redacted]"), "다음 턴")
        #expect(!texts.contains { $0.contains(Self.secret) })
        #expect(fake.decider.calls.isEmpty, "가린 명령은 서버에 묻지 않는다")
        #expect(!fake.log.lines.contains { $0.contains(Self.secret) })
    }

    // MARK: 4 세션을 떠난(setsid) 자손

    @Test func b4ARunEndsOnlyAfterItsDetachedDescendantIsGone() async throws {
        let fake = try FakeClaude()
        try fake.scenario(["runs": [["detached_child": true, "steps": [["text": "bye"]]]]])
        let events = EventLog()
        _ = try await fake.turn(events: events)
        #expect(await events.wait { FakeClaude.ended($0) })
        let child = try #require(fake.report(0)?["detached_child_pid"] as? Int)
        #expect(Self.gone(child), "ended를 내기 전에 혈통으로 찾은 자손을 끝냈다")
        // 끝을 증명한 뒤 혈통 파일에는 id가 없고 끝 기록만 남는다 (11장 1)
        let folder = fake.box.sessionsRoot.appending(path: "lineage")
        let records = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(!records.isEmpty && records.allSatisfy { ClaudeLineage.load(folder.appending(path: $0)) == .ended }, "끝 기록만")
    }

    /// 0.3초만 사는 중간 셸의 setsid 손자: 감독이 그 셸을 살아 있을 때 혈통에 넣어 두어, CLI가 끝난 뒤 손자까지 끝낸 다음에 `ended`를 낸다
    @Test func b4ARunEndsOnlyAfterTheDetachedGrandchildOfAnEndedShellIsGone() async throws {
        let fake = try FakeClaude()
        try fake.scenario(["runs": [["detached_grandchild": true, "steps": [["text": "bye"]], "linger_after_result": 1.0]]])
        let events = EventLog()
        _ = try await fake.turn(events: events)
        #expect(await events.wait(timeout: 10) { FakeClaude.ended($0) })
        let grandchild = try #require(fake.report(0)?["detached_grandchild_pid"] as? Int)
        defer { kill(pid_t(grandchild), SIGKILL) }
        #expect(Self.gone(grandchild), "ended를 내기 전에 끝난 셸의 손자까지 끝냈다")
    }

    /// 다시 뜬 앱(새 adapter): 혈통 파일과 원장의 정체로 setsid 자손을 찾아 끝낸다
    @Test func b4AnOrphanCleanupFindsTheDetachedDescendantByItsLineage() async throws {
        let fake = try FakeClaude()
        fake.allowReadonlyCat("notes.md")
        try fake.scenario(["runs": [["detached_child_early": true, "steps": [["tool": "Bash", "id": "toolu_b", "input": ["command": "cat notes.md"], "sleep": 30]]]]])
        let events = EventLog()
        let identity = try await fake.turn(events: events)
        for _ in 0..<500 where fake.report(0)?["sleep_pid"] == nil { try await Task.sleep(for: .milliseconds(20)) }
        let child = try #require(fake.report(0)?["detached_child_pid"] as? Int)
        // 감독하는 동안 혈통 파일이 있다 (다시 뜬 앱이 읽는다)
        let lineageFile = fake.box.sessionsRoot.appending(path: "lineage/\(identity.processMarker).lineage")
        #expect(await Self.waitUntil { FileManager.default.fileExists(atPath: lineageFile.path) })
        let restarted = ClaudeCodeProcess(sessionsRoot: fake.box.sessionsRoot, hookServer: nil, helpers: ClaudeCodeHelpers(hook: "/x", mcp: "/y", keeper: "/z"),
                                          locator: ClaudeCodeLocator(candidates: [], confinedTo: fake.box.root.path), timing: .testing)
        let ended = await restarted.terminateOrphan(identity)
        guard case .ended = ended else {
            Issue.record("\(ended)")
            return
        }
        #expect(Self.gone(child))
        #expect(await restarted.liveness(identity) == .ended(AgentExit(code: nil)))
        #expect(await events.wait { FakeClaude.ended($0) })
    }

    // MARK: 6 일반 Stop도 SIGKILL까지

    @Test func b6AStopOfACLIThatIgnoresSIGINTStillEnds() async throws {
        let fake = try FakeClaude()
        // SIGINT를 듣지 않고 결과 뒤에도 30초 머무는 CLI (자식이 없어 다른 길로 끝나지 않는다)
        try fake.scenario(["runs": [["ignore_sigint": true, "steps": [["text": "working"]], "linger_after_result": 30.0]]])
        let events = EventLog()
        let identity = try await fake.turn(events: events)
        #expect(await events.wait { $0.contains(.message(text: "working")) })
        let result = await fake.process.interrupt(AgentTurnRef(taskID: ClaudeTest.task, sessionID: ClaudeTest.session, identity: identity), scope: .turnAndProcesses)
        #expect(result == .signalled)
        #expect(await events.wait(timeout: 12) { FakeClaude.ended($0) })
        #expect(events.ended?.signal == Int(SIGKILL))
        #expect(Self.gone(try #require(fake.report(0)?["pid"] as? Int)))
    }

    // MARK: 7 서버를 기다리는 동안 Stop

    @Test func b7AStopWhileTheServerDecidesTurnsTheAllowIntoADeny() async throws {
        let fake = try FakeClaude(decider: ScriptedDecider([.success(ScriptedDecider.response(.allow, .policyAuto))], delay: .milliseconds(600)))
        try fake.scenario(["runs": [["steps": [["tool": "Write", "id": "toolu_w", "input": ["file_path": fake.workspace + "/late.txt", "content": "x"]]], "final_text": "ok"]]])
        let events = EventLog()
        let identity = try await fake.turn(events: events)
        #expect(await Self.waitUntil { !fake.decider.calls.isEmpty })
        _ = await fake.process.interrupt(AgentTurnRef(taskID: ClaudeTest.task, sessionID: ClaudeTest.session, identity: identity), scope: .turnAndProcesses)
        #expect(await events.wait { FakeClaude.ended($0) })
        #expect((fake.report(0)?["decisions"] as? [[String: Any]])?.first?["decision"] as? String == "deny")
        #expect(!FileManager.default.fileExists(atPath: fake.workspace + "/late.txt"))
    }

    // MARK: 8 새 정체를 원장에 적어야 답을 준다

    func askedOnce() async throws -> (FakeClaude, String) {
        let fake = try FakeClaude()
        try fake.scenario(["runs": [["steps": [["tool": "mcp__tf__ask_user", "id": "toolu_q", "input": FakeClaude.askColor]]], ["final_text": "Blue."]]])
        let first = EventLog()
        let identity = try await fake.turn(events: first)
        #expect(await first.wait { FakeClaude.ended($0) })
        return (fake, FakeClaude.providerSession(identity))
    }

    @Test func b8WhenTheNewIdentityCannotBeRecordedTheAnswerIsNotGiven() async throws {
        let (fake, session) = try await askedOnce()
        // 적지 못한 정체 (그 프로세스가 끝났는지 보려고 받아 둔다: SIGINT가 가짜의 보고보다 먼저 닿을 수 있다)
        let unrecorded = Mutex<AgentProcessIdentity?>(nil)
        fake.process.attach(AgentRuntimeServices(decideTool: fake.decider.function, recordSpawn: { _, identity in
            unrecorded.withLock { $0 = identity }
            return false
        }))
        let events = EventLog()
        await #expect(throws: AgentStartError.self) {
            _ = try await fake.answer("toolu_q", kind: .input, value: AgentAnswerValue(answers: ["color": .one("blue")]), external: session, events: events)
        }
        #expect(await events.wait { FakeClaude.ended($0) })
        #expect((fake.report(1)?["mcp_results"] as? [String]) == nil, "답이 모델에 닿지 않았다")
        #expect(!events.contains(.message(text: "Blue.")))
        let pid = try #require(unrecorded.withLock { $0 }?.pid)
        #expect(Self.gone(pid), "그 프로세스를 끝냈다")
    }

    @Test func b8TheAnswerWaitsForTheIdentityToBeRecorded() async throws {
        let (fake, session) = try await askedOnce()
        let decisionsBeforeRecord = Mutex<Int?>(nil)
        fake.process.attach(AgentRuntimeServices(decideTool: fake.decider.function, recordSpawn: { _, _ in
            try? await Task.sleep(for: .milliseconds(600))
            decisionsBeforeRecord.withLock { $0 = (fake.report(1)?["decisions"] as? [Any])?.count ?? 0 }
            return true
        }))
        let events = EventLog()
        let result = try await fake.answer("toolu_q", kind: .input, value: AgentAnswerValue(answers: ["color": .one("blue")]), external: session, events: events)
        #expect(result != .requestClosed)
        #expect(await events.wait { FakeClaude.ended($0) })
        #expect(decisionsBeforeRecord.withLock { $0 } == 0, "기록이 끝나기 전에는 훅에 답하지 않는다")
        #expect((fake.report(1)?["mcp_results"] as? [String])?.first == #"The user answered: {"color":"blue"}"#)
    }

    // MARK: 9 답 대기에 시간 제한 · 거둔 직후 신호

    @Test func b9AnAnswerResumeThatNeverAsksIsStoppedAfterTheTimeout() async throws {
        let timing = ClaudeCodeTiming(orphanInterruptGrace: 0.5, orphanKillGrace: 1, closeTimeout: 5, exitAfterResult: 3, drainAfterExit: 1, probeTimeout: 5, serverTimeout: 5, answerTimeout: 1.5)
        let fake = try FakeClaude(timing: timing)
        try fake.scenario(["runs": [["steps": [["tool": "mcp__tf__ask_user", "id": "toolu_q", "input": FakeClaude.askColor]]], ["pause_before_resume_hook": 20.0, "final_text": "x"]]])
        let first = EventLog()
        let identity = try await fake.turn(events: first)
        #expect(await first.wait { FakeClaude.ended($0) })
        let started = Date()
        let process = fake.process
        let session = FakeClaude.providerSession(identity)
        let workspace = fake.workspace
        let answer = Task {
            try await process.deliverAnswer(AgentAnswerDelivery(
                taskID: ClaudeTest.task, sessionID: ClaudeTest.session, turnSeq: 1, adapter: "agent:claude-code", externalSessionID: session, workspaceRef: workspace,
                marker: UUID().uuidString.lowercased(), access: .write, policyMode: .manual, requestID: "toolu_q", kind: .input, structured: true, value: AgentAnswerValue(text: "blue")
            ), events: EventLog().sink)
        }
        #expect(await Self.waitUntil(8) { fake.report(1) != nil })
        // 시간 제한이 없으면 가짜가 20초 기다리는 동안 돌아오지 않는다: 8초 안에 못 오면 멈추고 실패로 적는다
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(8))
            if let pid = fake.report(1)?["pid"] as? Int { kill(pid_t(pid), SIGKILL) }
        }
        let result = try? await answer.value
        watchdog.cancel()
        #expect(Date().timeIntervalSince(started) < 8, "답 대기는 시간 제한이 있다")
        #expect(result == .requestClosed)
        if let pid = fake.report(1)?["pid"] as? Int { #expect(await Self.waitUntil(5) { Self.gone(pid) }) }
    }

    @Test func b9TheAnswerWaitEndsWhenTheProcessIsReapedNotWhenItsCleanupEnds() async throws {
        let timing = ClaudeCodeTiming(orphanInterruptGrace: 2, orphanKillGrace: 1, closeTimeout: 5, exitAfterResult: 3, drainAfterExit: 0.3, probeTimeout: 5, serverTimeout: 5)
        let fake = try FakeClaude(timing: timing)
        try fake.scenario(["runs": [["steps": [["tool": "mcp__tf__ask_user", "id": "toolu_q", "input": FakeClaude.askColor]]], ["detached_child_early": true, "die": "before_init"]]])
        let first = EventLog()
        let identity = try await fake.turn(events: first)
        #expect(await first.wait { FakeClaude.ended($0) })
        let events = EventLog()
        let started = Date()
        // 답 훅 전에 끝났다 = 전달하지 않았다 → `lost` (15장 2: 결과는 delivered · lost 둘뿐)
        let result = try await fake.answer("toolu_q", kind: .input, value: AgentAnswerValue(text: "blue"), external: FakeClaude.providerSession(identity), events: events)
        #expect(result == .requestClosed)
        // 자손 정리(SIGINT → 2초 → SIGKILL)를 기다리지 않고 돌아온다. 세션 자리는 정리가 끝날 때까지 잡혀 있다
        #expect(Date().timeIntervalSince(started) < 1.5)
        #expect(!FakeClaude.ended(events.all), "정리는 아직이다 (그동안 세션 자리를 잡고 있다)")
        #expect(await events.wait(timeout: 10) { FakeClaude.ended($0) })
        if let child = fake.report(1)?["detached_child_pid"] as? Int { #expect(Self.gone(child)) }
    }

    // MARK: 10 닫기 동안 세션 자리

    @Test func b10AnotherTurnWaitsWhileTheFinishingSpawnClosesItsRequest() async throws {
        // 끝나는 spawn이 자기 닫기를 띄우기 바로 전에 다음 턴을 부른다 (그 사이가 두 번째 writer가 생길 수 있는 틈이다)
        let nextTurn = Mutex<Task<Void, Never>?>(nil)
        let holder = Mutex<FakeClaude?>(nil)
        let second = EventLog()
        let hooks = ClaudeCodeTestHooks(beforeFinishClose: {
            guard let fake = holder.withLock({ $0 }) else { return }
            nextTurn.withLock { $0 = Task { _ = try? await fake.turn("Next", task: "7a5c0001-0000-4000-8000-000000000002", events: second) } }
            try? await Task.sleep(for: .milliseconds(400))
        })
        let fake = try FakeClaude(hooks: hooks)
        holder.withLock { $0 = fake }
        try fake.scenario(["runs": [
            ["steps": [["tool": "mcp__tf__ask_user", "id": "toolu_q", "input": FakeClaude.askColor]]],
            ["steps": [["text": "next or close"]]],
            ["steps": [["text": "next or close"]]],
        ]])
        // state.json 자리에 폴더: 열린 요청을 적지 못해 끝날 때 그 요청을 닫기 모드로 닫는다 (8장 17)
        let folder = try ClaudeSessionFolder.prepare(sessionsRoot: fake.box.sessionsRoot, agentSessionID: ClaudeTest.session)
        try FileManager.default.createDirectory(at: folder.root.appending(path: "state.json"), withIntermediateDirectories: true)
        let first = EventLog()
        _ = try await fake.turn(events: first)
        #expect(await second.wait(timeout: 15) { FakeClaude.ended($0) })
        await nextTurn.withLock { $0 }?.value
        // 닫기 spawn = 빈 stdin resume, 다음 턴 = 글이 있는 stdin
        let reports = (1...2).compactMap { fake.report($0) }
        let close = try #require(reports.first { $0["stdin_bytes"] as? Int == 0 })
        let next = try #require(reports.first { ($0["stdin_bytes"] as? Int ?? 0) > 0 })
        let closeEnded = try #require(close["ended_at"] as? Double)
        let nextStarted = try #require(next["started_at"] as? Double)
        #expect(nextStarted >= closeEnded, "닫기가 끝난 뒤에 다음 writer")
    }
}

/// 런타임 쪽 (9장 8): 정체 기록이 원장 commit에 실패하면 false
@Suite(.serialized)
struct ClaudeRereviewRuntimeTests {
    @Test func b8RecordingTheIdentityOfAnUnknownRunFails() async throws {
        let harness = try BridgeHarness(withAdapter: false)
        try await harness.restart(adapters: [EarlyEventsAdapter(endBeforeReturn: false)], reopenLedger: false)
        await harness.registerFirst()
        let identity = AgentProcessIdentity(pid: 4242, startedAt: Date(), processMarker: UUID().uuidString)
        #expect(await harness.runtime.recordSpawnIdentity(taskID: "7a5c0001-0000-4000-8000-00000000dead", identity: identity) == false)
    }
}
#endif
