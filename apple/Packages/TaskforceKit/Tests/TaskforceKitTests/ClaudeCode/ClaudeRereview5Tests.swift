#if os(macOS) && DEBUG
import Darwin
import Foundation
import Synchronization
import Testing
import TaskforceAgentWire
@testable import TaskforceKit

/// 재검토 5 반영 (OA D3a 14장) — 새 모양: 세션 잠금 · 정체 자리 · `left` · 세션의 지금 실행(`sessionRun`, 15장) · 답 칸 · 해석들의 합. 재현은 `ClaudeRereview5ReproTests`
@Suite(.serialized)
struct ClaudeRereview5Tests {
    let box = ClaudeSandbox()

    var lockFile: URL { box.sessionsRoot.appending(path: "lineage/\(ClaudeTest.session).lock") }

    // MARK: 1 먼저 쓰는 잠금

    /// 도는 동안 세션 잠금(0600)이 이번 spawn을 가리키고, 끝을 증명하면 풀린다
    @Test func t1TheLockNamesTheSpawnWhileItRunsAndIsReleasedOnAProvenEnd() async throws {
        // 가짜는 결과 뒤 시험이 표시 파일을 만들 때까지 머문다 (1초 머물기 대신): 그 사이 잠금을 본다. 결과 뒤 SIGINT 유예도 그동안 넉넉히
        var timing = ClaudeCodeTiming.ci
        timing.exitAfterResult = 60
        let fake = try FakeClaude(timing: timing)
        let gate = fake.box.root.appending(path: "after-result-go").path
        try fake.scenario(["runs": [["steps": [["text": "ok"]], "wait_for_file_after_result": gate]]])
        let events = EventLog()
        let identity = try await fake.turn(events: events)
        let lock = fake.box.sessionsRoot.appending(path: "lineage/\(ClaudeTest.session).lock")
        #expect(ClaudeSessionLock.read(lock) == .spawn(identity.processMarker))
        let attributes = try FileManager.default.attributesOfItem(atPath: lock.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(await fake.process.sessionRun(ClaudeTest.session)?.liveness == .alive)
        FileManager.default.createFile(atPath: gate, contents: Data())
        #expect(await events.wait { FakeClaude.ended($0) })
        #expect(!FileManager.default.fileExists(atPath: lock.path), "끝을 증명하면 잠금을 푼다")
        #expect(await fake.process.sessionRun(ClaudeTest.session)?.liveness == .ended(AgentExit(code: nil)))
    }

    /// 띄운 뒤 실패해 끝을 모른다: 잠금 · 정체 자리(`pending` 또는 정체)가 남고, 런타임에 그 정체를 `left`로 알린다
    @Test func t1AStartThatCannotProveItsEndReportsWhatItLeft() async throws {
        let timing = ClaudeCodeTiming(
            orphanInterruptGrace: 0.5, orphanKillGrace: 1, closeTimeout: 1, exitAfterResult: 3, drainAfterExit: 1, probeTimeout: 5, serverTimeout: 5, keeperExit: 0.01
        )
        let fake = try FakeClaude(timing: timing)
        try fake.scenario(["runs": [["steps": [["text": "ok"]]]]])
        let me = getpid()
        var failing = KeeperMembers.Lookups.live
        failing.generation = { pid in
            let read = AgentProcesses.generation(pid: pid)
            if case .present(let value) = read, value.parentPID == me { return .failed }
            return read
        }
        var thrown: AgentStartError?
        do {
            _ = try await ClaudeProcessInspector.$lookups.withValue(failing) { try await fake.turn(events: EventLog()) }
        } catch let error as AgentStartError {
            thrown = error
        }
        let left = try #require(thrown?.left)
        #expect(thrown?.reason == .spawnFailed)
        let lock = fake.box.sessionsRoot.appending(path: "lineage/\(ClaudeTest.session).lock")
        #expect(ClaudeSessionLock.read(lock) == .spawn(left.processMarker))
        let lineage = ClaudeLineage(file: fake.box.sessionsRoot.appending(path: "lineage/\(left.processMarker).lineage"))
        #expect(ClaudeProcessInspector.liveness(left, lineage: lineage) == .unknown, "정체 자리만 있다: 끝을 모른다")
        #expect(await fake.process.sessionRun(ClaudeTest.session)?.liveness == .unknown)
        #expect(await fake.restarted().sessionRun(ClaudeTest.session)?.liveness == .unknown)
        #expect(fake.log.lines.contains { $0.hasPrefix("claude_start_unproven") })
    }

    /// 지킴이가 기한 안에 끝났지만 0이 아니다 (여기서는 부른 쪽 확인 실패 = 6): 끝을 증명하지 않았다 → 잠금이 남는다 (14장 1 · 12)
    @Test func t1AKeeperThatExitsNonZeroLeavesTheSessionLocked() async throws {
        let wrapper = box.root.appending(path: "refusing-keeper")
        try "#!/bin/sh\nTF_KEEPER_CALLER_REQUIREMENT='identifier \"dev.taskforcelabs.not-this-host\"' exec '\(try BuiltProducts.url("tf-agent-keeper").path)' \"$@\"\n"
            .write(to: wrapper, atomically: true, encoding: .utf8)
        #expect(chmod(wrapper.path, 0o755) == 0)
        let fake = try FakeClaude(keeper: wrapper.path)
        try fake.scenario(["runs": [["steps": [["text": "ok"]]]]])
        var thrown: AgentStartError?
        do {
            _ = try await fake.turn(events: EventLog())
        } catch let error as AgentStartError {
            thrown = error
        }
        #expect(thrown?.left != nil, "띄운 뒤의 실패: 미실행이 아니다")
        #expect(fake.runCount == 0, "부모가 앱이 아니면 claude를 띄우지 않는다")
        let lock = fake.box.sessionsRoot.appending(path: "lineage/\(ClaudeTest.session).lock")
        #expect(ClaudeSessionLock.read(lock) == thrown?.left.map { .spawn($0.processMarker) })
        await #expect(throws: (any Error).self) { _ = try await fake.restarted().startTurn(ClaudeRereview5ReproTests.turn(fake), events: EventLog().sink) }
    }

    /// 잠금 읽기: 형식이 맞는 것만, 다른 부팅은 끝, 기호 링크 · 잘린 줄 · 이상한 id는 읽지 못함(unknown)
    @Test func t1TheLockFileHasOneShape() throws {
        try FileManager.default.createDirectory(at: lockFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let boot = try #require(AgentProcesses.bootSessionID())
        let spawn = UUID().uuidString
        #expect(ClaudeSessionLock.write(lockFile, spawnID: spawn))
        #expect(try String(contentsOf: lockFile, encoding: .utf8) == "taskforce-session-lock 1\nboot \(boot)\nspawn \(spawn)\n")
        ClaudeSessionLock.release(lockFile, spawnID: UUID().uuidString)
        #expect(ClaudeSessionLock.read(lockFile) == .spawn(spawn), "다른 spawn의 해제는 지우지 않는다")
        for (text, expected) in [
            ("taskforce-session-lock 1\nboot \(UUID().uuidString)\nspawn \(spawn)\n", ClaudeSessionLock.Read.otherBoot),
            ("taskforce-session-lock 1\nboot \(boot)\nspawn \(spawn)", .unreadable), ("taskforce-session-lock 1\nboot \(boot)\nspawn x\n", .unreadable),
            ("nonsense\n", .unreadable),
        ] {
            try text.write(to: lockFile, atomically: true, encoding: .utf8)
            #expect(ClaudeSessionLock.read(lockFile) == expected, "\(text.debugDescription)")
        }
        try FileManager.default.removeItem(at: lockFile)
        #expect(ClaudeSessionLock.read(lockFile) == .none)
        let planted = box.root.appending(path: "planted.lock")
        try "taskforce-session-lock 1\nboot \(boot)\nspawn \(spawn)\n".write(to: planted, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: lockFile, withDestinationURL: planted)
        #expect(ClaudeSessionLock.read(lockFile) == .unreadable, "기호 링크는 따라가지 않는다")
    }

    /// 지킴이가 기록 없이 사라져 끝을 증명하지 못한 spawn: 이 앱의 세션 상태도 unknown (등록부에 남아 세션을 막는다)
    @Test func t2AnUnprovenEndIsUnknownForTheSession() async throws {
        let fake = try FakeClaude()
        try fake.scenario(["runs": [["steps": [["text": "ok"]], "linger_after_result": 1.5]]])
        let identity = try await fake.turn(events: EventLog())
        guard case .present(let claude) = AgentProcesses.generation(pid: pid_t(try #require(identity.pid))) else {
            Issue.record("claude generation")
            return
        }
        kill(claude.parentPID, SIGKILL)
        #expect(await ClaudeRereview5ReproTests.waitUntil(60) { fake.log.lines.contains { $0.hasPrefix("claude_end_unproven") } })
        #expect(await fake.process.sessionRun(ClaudeTest.session)?.liveness == .unknown)
        #expect(await fake.restarted().sessionRun(ClaudeTest.session)?.liveness == .unknown)
    }

    /// 앱이 뜰 때: 다른 부팅의 잠금은 지우고 정체 자리는 끝 기록으로, 이번 부팅 것은 그대로
    @Test func t1APurgeClearsOnlyOtherBootLocksAndPlaceholders() throws {
        let directory = box.sessionsRoot.appending(path: "lineage", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let boot = try #require(AgentProcesses.bootSessionID())
        let old = directory.appending(path: "\(UUID().uuidString.lowercased()).lock")
        let current = directory.appending(path: "\(UUID().uuidString.lowercased()).lock")
        let placeholder = directory.appending(path: "\(UUID().uuidString).lineage")
        try "taskforce-session-lock 1\nboot \(UUID().uuidString)\nspawn \(UUID().uuidString)\n".write(to: old, atomically: true, encoding: .utf8)
        #expect(ClaudeSessionLock.write(current, spawnID: UUID().uuidString))
        try "taskforce-lineage 4\nboot \(UUID().uuidString)\npending\n".write(to: placeholder, atomically: true, encoding: .utf8)
        ClaudeLineage.purge(directory: directory, boot: boot)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: current.path))
        #expect(ClaudeLineage.load(placeholder, boot: boot) == .ended, "다른 부팅의 정체 자리는 끝")
    }

    // MARK: 2 답 정산과 프로세스 끝

    /// 런타임: 띄운 뒤 실패해 끝을 모르는 시작은 `failed`를 알리되 그 task를 끝났다고 적지 않는다 (정체를 적고 확인 안 된 고아)
    @Test func t2AStartThatLeftAProcessIsAnUnverifiedOrphan() async throws {
        let left = AgentProcessIdentity(pid: nil, startedAt: Date(), processMarker: UUID().uuidString)
        let adapter = LeavingStartAdapter(left: left)
        let h = try BridgeHarness(withAdapter: false)
        try await h.restart(adapters: [adapter], reopenLedger: false)
        await h.registerFirst()
        let created = h.message("Hi")
        await h.runtime.tick()
        #expect(await h.eventually { await h.task(created.taskID)?.lastState == "failed" })
        let task = await h.task(created.taskID)
        #expect(task?.alive == true)
        #expect(task?.processMarker == left.processMarker, "다시 뜬 앱이 그 실행의 혈통을 찾게")
        #expect(await h.runtime.processFact(for: created.taskID, task: task) == .unverifiedOrphan)
        try await h.restart(adapters: [adapter], reopenLedger: false)
        await h.runtime.recover()
        #expect(await h.task(created.taskID)?.alive == true)
        #expect(adapter.checked.withLock { $0 }.contains(left.processMarker))
    }

    // MARK: 7 답 칸

    @Test func t7TheAnswerSlotSettlesOnceAndWipesTheValue() {
        let answer = HookResponse(decision: .allow, reason: "answer")
        let slot = ClaudeCodeProcess.AnswerSlot(AgentAnswerValue(text: "hunter2-secret"))
        #expect(slot.value.text == "hunter2-secret")
        #expect(slot.lose())
        #expect(!slot.lose(), "한 번만 정한다")
        #expect(slot.signal == .lost && slot.value.text == nil)
        let late = HookCommit()
        let closed = HookResponse(decision: .deny, reason: "closed")
        #expect(slot.commitAnswer(answer, closed: closed, to: late, at: Date()) == .alreadyClosed, "먼저 정한 것이 이긴다")
        #expect(late.timeOut() == closed, "답 응답이 아니라 닫힘 응답을 확정했다")
        let delivered = ClaudeCodeProcess.AnswerSlot(AgentAnswerValue(text: "x"))
        #expect(delivered.commitAnswer(answer, closed: closed, to: HookCommit(), at: Date(timeIntervalSince1970: 1)) == .delivered)
        #expect(!delivered.lose())
        #expect(delivered.signal == .delivered(Date(timeIntervalSince1970: 1)) && delivered.value.text == nil)
        let ended = ClaudeCodeProcess.AnswerSlot(AgentAnswerValue(text: "x"))
        ended.end()
        #expect(ended.signal == .lost && ended.value.text == nil, "끝났는데 전달하지 않았다 = lost (15장 2)")
    }

    // MARK: 8 해석들의 합 · 단어 경계

    @Test func t8TheCommentAwareUnquotingUsesRealWordBoundaries() {
        let bs = "\\"
        #expect(SecretRedactor.shellUnquoted("echo prefix" + bs + " #CANARY-\"\"SECRET") == "echo prefix #CANARY-SECRET", "이스케이프된 빈칸 뒤의 #는 단어 안")
        #expect(SecretRedactor.shellUnquoted("echo " + bs + " #CANARY-\"\"SECRET") == "echo  #CANARY-SECRET", "단어를 여는 이스케이프된 빈칸 뒤도 단어 안")
        #expect(SecretRedactor.shellUnquoted("echo pre" + bs + "\n#CANARY-\"\"SECRET") == "echo pre#CANARY-SECRET", "단어 중간 줄 이음 뒤")
        #expect(SecretRedactor.shellUnquoted("echo a" + bs + ";#b 'c'") == "echo a;#b c")
        #expect(SecretRedactor.shellUnquoted("echo a;#b 'c'") == nil, "이스케이프되지 않은 ; 뒤는 주석 (바뀐 것 없음)")
        #expect(SecretRedactor.shellUnquoted("x " + bs + "\n#b 'c'") == "x #b 'c'", "단어 첫머리의 줄 이음 뒤는 주석")
        #expect(SecretRedactor.shellUnquoted("# it's\necho 'a'", comments: false) == "# its\necho a", "주석 처리 안 함: 작은따옴표를 셸로")
        let redactor = SecretRedactor(["CANARY-SECRET-7f3a"])
        #expect(redactor.detects("# it's\necho CANARY-\"\"SECRET-7f3a"), "주석 처리함 쪽이 찾는다")
        #expect(redactor.detects("echo x" + bs + " #CANARY-\"\"SECRET-7f3a # it's"))
        #expect(redactor.detects("echo a #CANARY-\"\"SECRET-7f3a"), "주석 안의 값도 서버로 가는 글이다: 주석 처리 안 함 쪽이 합에 든다")
    }
}

/// 띄운 뒤 실패해 끝을 모르는 시작 (`left`)과, 다시 뜬 앱의 확인을 적어 두는 adapter
final class LeavingStartAdapter: AgentProcess, @unchecked Sendable {
    let adapter = "agent:claude-code"
    let left: AgentProcessIdentity
    let checked = Mutex<[String]>([])

    init(left: AgentProcessIdentity) {
        self.left = left
    }

    func probe() async -> BridgeV1AdapterReport {
        BridgeV1AdapterReport(adapter: adapter, installed: true, version: "2.1.241", signedIn: .yes, managedSettings: false)
    }

    func startTurn(_ turn: AgentTurnStart, events: AgentEventSink) async throws -> AgentProcessIdentity {
        throw AgentStartError(.spawnFailed, left: left)
    }

    func deliverAnswer(_ answer: AgentAnswerDelivery, events: AgentEventSink) async throws -> AgentAnswerResult { .requestClosed }
    func closeRequest(_ request: AgentRequestRef) async throws {}
    func interrupt(_ target: AgentTurnRef, scope: AgentCancelScope) async -> AgentInterruptResult { .signalled }

    func liveness(_ identity: AgentProcessIdentity) async -> AgentLiveness {
        checked.withLock { $0.append(identity.processMarker) }
        return .unknown
    }

    func terminateOrphan(_ identity: AgentProcessIdentity) async -> AgentLiveness { .unknown }
}
#endif
