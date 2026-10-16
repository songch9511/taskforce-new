#if os(macOS) && DEBUG
import Darwin
import Foundation
import Synchronization
import Testing
@testable import TaskforceAgentWire
@testable import TaskforceKit

/// 재검토 6 (OA D3a 15장): 답 슬롯 · 소켓 응답 · 종료를 한 경계에서(Astra P2 세 순서), 기록 위조(앱이 부모면 거둔 종료 · 보고 줄이 이긴다), 크래시 창(`pending` +
/// 이번 부팅의 지킴이 기록), 무관한 disclaim 프로세스(sec `selfresp`), 부른 쪽 exec(sec `callerexec`). 가짜 `claude` + 실제로 빌드한 지킴이. 실제 `claude` 실행 0
@Suite(.serialized)
struct ClaudeRereview6Tests {
    typealias AnswerSlot = ClaudeCodeProcess.AnswerSlot
    let box = ClaudeSandbox()
    static let allow = HookResponse(decision: .allow, reason: "answer")
    static let deny = HookResponse(decision: .deny, reason: "answer_closed")

    static func delivered(_ slot: AnswerSlot) -> Bool {
        if case .delivered? = slot.signal { return true }
        return false
    }

    // MARK: 1 (Astra P1-1 · P1-2) 끝을 모르는 실행은 그 정체를 넘기고 세션의 지금 실행으로 남는다

    /// 답 실행의 정체를 원장에 적지 못했다: 던지는 오류가 그 실행의 정체를 넘기고(앞 질문 실행의 끝으로 덮지 않게), 끝날 때까지 세션의 지금 실행도 그것이다
    @Test func t1AnAnswerWhoseIdentityCannotBeRecordedHandsOverItsRun() async throws {
        let fake = try FakeClaude()
        try fake.scenario(["runs": [["steps": [["tool": "mcp__tf__ask_user", "id": "toolu_q", "input": FakeClaude.askColor]]], ["final_text": "Blue."]]])
        let first = EventLog()
        let asked = try await fake.turn(events: first)
        #expect(await first.wait { FakeClaude.ended($0) })
        #expect(fake.state.openDeferred != nil, "질문이 열렸다 (시험 전제: 부하로 훅 예산을 넘으면 열리지 않는다)")
        let process = fake.process
        let unrecorded = Mutex<AgentProcessIdentity?>(nil)
        let runWhileRecording = Mutex<AgentSessionRun?>(nil)
        process.attach(AgentRuntimeServices(decideTool: fake.decider.function, recordSpawn: { _, identity in
            unrecorded.withLock { $0 = identity }
            let run = await process.sessionRun(ClaudeTest.session)
            runWhileRecording.withLock { $0 = run }
            return false
        }))
        let events = EventLog()
        var thrown: AgentStartError?
        do {
            _ = try await fake.answer("toolu_q", kind: .input, value: AgentAnswerValue(answers: ["color": .one("blue")]), external: FakeClaude.providerSession(asked), events: events)
        } catch let error as AgentStartError {
            thrown = error
        }
        let spawned = try #require(unrecorded.withLock { $0 }, "답 실행이 정체 기록까지 갔다 (\(String(describing: thrown)))")
        #expect(thrown?.left?.processMarker == spawned.processMarker, "그 실행의 정체를 넘긴다")
        #expect(spawned.processMarker != asked.processMarker)
        #expect(runWhileRecording.withLock { $0 }?.identity?.processMarker == spawned.processMarker, "세션의 지금 실행 = 답 실행")
        #expect(await events.wait { FakeClaude.ended($0) })
        #expect(await process.sessionRun(ClaudeTest.session)?.liveness == .ended(AgentExit(code: nil)), "끝을 증명한 뒤")
    }

    /// 닫기 실행이 띄운 뒤 끝을 증명하지 못했다(지킴이 대조 실패 · 0 종료 못 받음): 닫기도 그 실행의 정체를 넘기고 세션의 지금 실행으로 남는다
    @Test func t1ACloseRunWhoseEndCannotBeProvenHandsOverItsRun() async throws {
        let timing = ClaudeCodeTiming(
            orphanInterruptGrace: 0.5, orphanKillGrace: 1, closeTimeout: 1, exitAfterResult: 3, drainAfterExit: 1, probeTimeout: 5, serverTimeout: 5, keeperExit: 0.01
        )
        let fake = try FakeClaude(timing: timing)
        try fake.scenario(["runs": [["steps": [["tool": "mcp__tf__ask_user", "id": "toolu_q", "input": FakeClaude.askColor]]], ["final_text": "x"]]])
        let first = EventLog()
        let asked = try await fake.turn(events: first)
        #expect(await first.wait { FakeClaude.ended($0) })
        let me = getpid()
        var failing = KeeperMembers.Lookups.live
        failing.generation = { pid in
            let read = AgentProcesses.generation(pid: pid)
            if case .present(let value) = read, value.parentPID == me { return .failed }
            return read
        }
        let ref = AgentRequestRef(
            taskID: ClaudeTest.task, sessionID: ClaudeTest.session, requestID: "toolu_q", externalSessionID: FakeClaude.providerSession(asked), workspaceRef: fake.workspace
        )
        let process = fake.process
        var thrown: AgentStartError?
        do {
            try await ClaudeProcessInspector.$lookups.withValue(failing) { try await process.closeRequest(ref) }
        } catch let error as AgentStartError {
            thrown = error
        }
        let left = try #require(thrown?.left, "닫기도 정체를 넘긴다")
        #expect(left.processMarker != asked.processMarker)
        let run = await process.sessionRun(ClaudeTest.session)
        #expect(run?.identity?.processMarker == left.processMarker)
        #expect(run?.liveness == .unknown)
    }

    // MARK: 2 (Astra P2) 답 결과와 Claude가 받은 것이 늘 같다

    /// ① 소켓이 먼저 시간 초과로 정했다(Claude는 deny) → 종료가 먼저 슬롯에 온다 → 늦은 정산: 결과는 `lost` 하나 (끝 = 전달 안 함)
    @Test func t2OrderOneATimedOutAnswerHookThenTheEndIsLost() {
        let slot = AnswerSlot(AgentAnswerValue(text: "blue"))
        let hook = HookCommit()
        #expect(hook.timeOut() == nil, "소켓 시간 초과")
        slot.end()
        #expect(slot.commitAnswer(Self.allow, closed: Self.deny, to: hook, at: Date()) == .timedOut, "Claude는 시간 초과 deny를 받았다")
        #expect(!slot.lose(), "이미 정했다")
        #expect(slot.signal == .lost && slot.value.text == nil)
        #expect(hook.timeOut() == nil, "답도 닫힘 응답도 확정되지 않았다")
        // 정산이 종료보다 먼저여도 같다
        let early = AnswerSlot(AgentAnswerValue(text: "blue"))
        let timedOut = HookCommit()
        #expect(timedOut.timeOut() == nil)
        #expect(early.commitAnswer(Self.allow, closed: Self.deny, to: timedOut, at: Date()) == .timedOut)
        #expect(early.signal == .lost, "시간 초과를 본 그 자리에서 정한다")
        early.end()
        #expect(!early.lose())
        #expect(early.signal == .lost && early.value.text == nil)
        #expect(timedOut.timeOut() == nil, "답 응답은 확정되지 않았다")
    }

    /// ② 다른 훅의 시간 초과가 미전달 답을 닫았다 → 그 뒤 답 훅의 allow: 답을 주지 않고 deny를 확정한다 (결과 `lost` = Claude도 deny)
    @Test func t2OrderTwoALostAnswerIsNeverCommittedLater() {
        let slot = AnswerSlot(AgentAnswerValue(text: "blue"))
        let hook = HookCommit()
        #expect(slot.lose(), "다른 훅의 시간 초과")
        #expect(slot.commitAnswer(Self.allow, closed: Self.deny, to: hook, at: Date()) == .alreadyClosed)
        #expect(hook.timeOut() == Self.deny, "답 대신 answers 없는 deny를 확정했다")
        #expect(slot.signal == .lost)
    }

    /// ③ 답 훅의 allow를 확정했다 → 그 뒤 다른 훅의 시간 초과: 이미 전달이다 (결과 `delivered` = Claude도 allow)
    @Test func t2OrderThreeACommittedAnswerStaysDelivered() {
        let slot = AnswerSlot(AgentAnswerValue(text: "blue"))
        let hook = HookCommit()
        let at = Date(timeIntervalSince1970: 7)
        #expect(slot.commitAnswer(Self.allow, closed: Self.deny, to: hook, at: at) == .delivered)
        #expect(!slot.lose(), "다른 훅의 시간 초과는 늦었다")
        slot.end()
        #expect(slot.signal == .delivered(at) && slot.value.text == nil)
        #expect(hook.timeOut()?.decision == .allow)
    }

    /// 셋이 동시에 (답 정산 · 다른 훅의 닫기 · 소켓 시간 초과 · 종료): 슬롯이 `delivered`인 것과 Claude가 allow를 받은 것이 늘 같다
    @Test func t2TheSlotAndTheHookResponseNeverDisagreeUnderRaces() {
        var mismatches = 0
        for round in 0..<4000 {
            let slot = AnswerSlot(AgentAnswerValue(text: "blue"))
            let hook = HookCommit()
            DispatchQueue.concurrentPerform(iterations: 3) { racer in
                switch (racer + round) % 3 {
                case 0: _ = slot.commitAnswer(Self.allow, closed: Self.deny, to: hook, at: Date())
                case 1: if round % 2 == 0 { slot.lose() } else { slot.end() }
                default: _ = hook.timeOut()
                }
            }
            if Self.delivered(slot) != (hook.timeOut()?.decision == .allow) { mismatches += 1 }
        }
        #expect(mismatches == 0)
    }

    // MARK: 4 (sec F4b) 기록 위조

    /// 앱이 부모로서 지킴이의 비정상 종료(SIGKILL)를 받았다: 그 사이 같은 uid가 쓴 끝 기록이 있어도 unknown
    @Test func t4AKilledKeeperWithAForgedRecordIsUnknownForTheAppThatSpawnedIt() async throws {
        let child = try box.keep("exec /bin/sleep 30")
        #expect(ClaudeProcessInspector.liveness(child.identity, lineage: child.lineage) == .alive)
        let boot = try #require(AgentProcesses.bootSessionID())
        #expect(KeeperRecord.write(ClaudeLineage.keeperFile(child.file), keeperID: child.kept.keeperID, boot: boot), "위조한 끝 기록")
        kill(child.kept.keeper.pid, SIGKILL)
        if let pid = child.identity.pid { kill(pid_t(pid), SIGKILL) }
        #expect(await child.keeperEnded())
        #expect(child.lineage.endAfterKeeperGone() == .unknown)
        #expect(ClaudeProcessInspector.liveness(child.identity, lineage: child.lineage) == .unknown, "기록보다 거둔 비정상 종료가 이긴다")
    }

    /// 앱이 부모면 정상 끝 = 0 종료 ∧ 보고 `ended` 줄. 하나라도 없으면 unknown, 아직 거두는 중이면 정하지 않는다 (기록 파일은 보지 않는다)
    @Test func t4AnAppParentedKeeperEndsOnlyWithExitZeroAndTheEndedLine() throws {
        let file = box.sessionsRoot.appending(path: "lineage/\(UUID().uuidString.lowercased()).lineage")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let boot = try #require(AgentProcesses.bootSessionID())
        func lineage(_ exit: ClaudeExitStatus?, _ sawEnded: Bool?) -> ClaudeLineage {
            let made = ClaudeLineage(file: file, fresh: true)
            made.adopt(ClaudeLineage.Record(keeper: ClaudeLineage.Keeper(pid: 999_999, uniqueID: 4242), root: 4243, rootPID: 999_998, attributable: true))
            if let exit { made.keeperExited(exit) }
            if let sawEnded { made.reportClosed(sawEnded: sawEnded) }
            return made
        }
        #expect(KeeperRecord.write(ClaudeLineage.keeperFile(file), keeperID: 4242, boot: boot), "기록 파일이 있어도")
        let zero = ClaudeExitStatus(code: KeeperMain.Exit.ended.rawValue, signal: nil)
        #expect(lineage(zero, true).endAfterKeeperGone() == .ended(AgentExit(code: nil)))
        #expect(lineage(zero, true).provenEnded)
        #expect(lineage(zero, false).endAfterKeeperGone() == .unknown, "0 종료인데 `ended` 줄 없이 닫혔다")
        #expect(!lineage(zero, false).provenEnded)
        #expect(lineage(ClaudeExitStatus(code: 4, signal: nil), true).endAfterKeeperGone() == .unknown)
        #expect(lineage(ClaudeExitStatus(code: nil, signal: SIGKILL), nil).endAfterKeeperGone() == .unknown)
        #expect(lineage(zero, nil).endAfterKeeperGone() == nil, "보고를 아직 읽는 중")
        #expect(lineage(nil, nil).endAfterKeeperGone() == nil, "아직 거두지 않았다")
        #expect(!lineage(nil, true).provenEnded)
        // 앱이 죽어 있던 동안이면(파일에서 읽은 혈통) 그 지킴이의 이번 부팅 기록이 끝이다
        #expect(lineage(nil, nil).save())
        #expect(ClaudeLineage(file: file).endAfterKeeperGone() == .ended(AgentExit(code: nil)))
    }

    /// 지킴이를 안 뒤(혈통에 적은 뒤) 정체 파일을 쓰지 못해 멈춘 시작: 앱이 지킴이의 정상 끝을 받지 못했다 → 그 spawn은 unknown이다 (사라진 지킴이를 살아 있다고 하지 않는다)
    @Test func t4AStartStoppedAfterTheKeeperIsKnownIsUnknownNotAlive() async throws {
        let go = box.root.appending(path: "go")
        let slow = box.root.appending(path: "slow-keeper")
        try "#!/bin/sh\nwhile [ ! -e '\(go.path)' ]; do /bin/sleep 0.02; done\nexec '\(try BuiltProducts.url("tf-agent-keeper").path)' \"$@\"\n"
            .write(to: slow, atomically: true, encoding: .utf8)
        #expect(chmod(slow.path, 0o755) == 0)
        let fake = try FakeClaude(keeper: slow.path)
        try fake.scenario(["runs": [["steps": [["text": "ok"]]]]])
        let lineage = fake.box.sessionsRoot.appending(path: "lineage")
        let lock = try #require(ClaudeSessionLock.file(sessionsRoot: fake.box.sessionsRoot, session: ClaudeTest.session))
        let starting = Task { try await fake.turn(events: EventLog()) }
        // 잠금 · 정체 자리를 쓰고 지킴이를 기다리는 동안 혈통 폴더를 읽기 전용으로: 정체 파일 저장 · 지킴이 끝 기록이 실패한다
        #expect(await ClaudeRereview5ReproTests.waitUntil(5) { ClaudeSessionLock.read(lock) != .none })
        #expect(chmod(lineage.path, 0o500) == 0)
        defer { chmod(lineage.path, 0o700) }
        FileManager.default.createFile(atPath: go.path, contents: Data())
        var thrown: AgentStartError?
        do {
            _ = try await starting.value
        } catch let error as AgentStartError {
            thrown = error
        }
        #expect(thrown?.left != nil, "띄운 뒤 멈췄다")
        #expect(await fake.process.sessionRun(ClaudeTest.session)?.liveness == .unknown)
    }

    /// 보고 `ended` 없이 0으로 끝난 지킴이(끝 증명을 하지 않은 다른 실행 파일): 끝이 아니다 — 시작 실패는 정체를 넘기고 잠금을 남긴다
    @Test func t4AKeeperThatExitsZeroWithoutTheEndedLineIsNotAnEnd() async throws {
        let quiet = box.root.appending(path: "quiet-keeper")
        try "#!/bin/sh\nexit 0\n".write(to: quiet, atomically: true, encoding: .utf8)
        #expect(chmod(quiet.path, 0o755) == 0)
        let fake = try FakeClaude(keeper: quiet.path)
        try fake.scenario(["runs": [["steps": [["text": "ok"]]]]])
        let lock = try #require(ClaudeSessionLock.file(sessionsRoot: fake.box.sessionsRoot, session: ClaudeTest.session))
        var thrown: AgentStartError?
        do {
            _ = try await fake.turn(events: EventLog())
        } catch let error as AgentStartError {
            thrown = error
        }
        #expect(thrown?.left != nil, "끝을 모르는 시작")
        #expect(ClaudeSessionLock.read(lock) != .none, "잠금이 남는다")
    }

    // MARK: 5 (sec F4c) 크래시 창

    /// 정체를 적기 전에 앱이 죽었다 (잠금 → `pending` → 지킴이): 그 spawn 경로에 묶인 이번 부팅의 지킴이 기록이면 끝, 다른 부팅 · 없음이면 unknown
    @Test func t5APendingSpawnIsEndedByThisBootsKeeperRecordForItsPath() async throws {
        let spawnID = UUID().uuidString.lowercased()
        let file = box.sessionsRoot.appending(path: "lineage/\(spawnID).lineage")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(ClaudeLineage(file: file, fresh: true).savePending())
        let lock = try #require(ClaudeSessionLock.file(sessionsRoot: box.sessionsRoot, session: ClaudeTest.session))
        #expect(ClaudeSessionLock.write(lock, spawnID: spawnID))
        let identity = ClaudeCodeProcess.lockedIdentity(spawnID)
        #expect(ClaudeProcessInspector.liveness(identity, lineage: ClaudeLineage(file: file)) == .unknown, "기록 없음")
        let boot = try #require(AgentProcesses.bootSessionID())
        let other = box.sessionsRoot.appending(path: "lineage/\(UUID().uuidString.lowercased()).keeper")
        #expect(KeeperRecord.write(other, keeperID: 4242, boot: boot))
        #expect(await ClaudeRereview3ReproTests.adapter(box).sessionRun(ClaudeTest.session)?.liveness == .unknown, "다른 spawn 경로의 기록")
        let record = ClaudeLineage.keeperFile(file)
        #expect(KeeperRecord.write(record, keeperID: 4242, boot: UUID().uuidString))
        #expect(ClaudeProcessInspector.liveness(identity, lineage: ClaudeLineage(file: file)) == .unknown, "다른 부팅의 기록")
        #expect(KeeperRecord.write(record, keeperID: 4242, boot: boot))
        #expect(ClaudeProcessInspector.liveness(identity, lineage: ClaudeLineage(file: file)) == .ended(AgentExit(code: nil)))
        // 다시 뜬 앱: 세션의 지금 실행도 끝이고 잠금을 푼다
        #expect(await ClaudeRereview3ReproTests.adapter(box).sessionRun(ClaudeTest.session)?.liveness == .ended(AgentExit(code: nil)))
        #expect(ClaudeSessionLock.read(lock) == .none)
    }

    // MARK: 3 (sec F3, `selfresp`) 무관한 disclaim 프로세스

    /// 지킴이 뒤에 뜬 다른 앱(지킴이의 자손이 아니다)이 disclaim으로 띄운 자식을 두고 살아 있다: 끝 증명은 평소 시간 안에 끝난다
    @Test func s3AnUnrelatedDisclaimedProcessDoesNotHoldTheEndProof() async throws {
        let fake = try BuiltProducts.url("FakeClaudeCode").path
        let tag = "623.\(Int.random(in: 10000...99999))"
        let root = try box.keep("/bin/sleep 1; exit 0")
        let app = Process()
        app.executableURL = URL(fileURLWithPath: fake)
        app.arguments = ["--disclaim-spawn-stay", "/bin/sleep", tag]
        app.standardOutput = FileHandle.nullDevice
        try app.run()
        defer {
            app.terminate()
            for pid in KeeperRereviewTag.pids(tag) { kill(pid, SIGKILL) }
        }
        let started = Date()
        #expect(await ClaudeRereview5ReproTests.waitUntil(5) { !KeeperRereviewTag.pids(tag).isEmpty }, "무관한 자식이 떴다 (시험 전제)")
        #expect(await root.keeperEnded(timeout: 12))
        #expect(root.lineage.endAfterKeeperGone() == .ended(AgentExit(code: nil)))
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(!KeeperRereviewTag.pids(tag).isEmpty, "무관한 자식은 그대로 (신호 0)")
    }

    // MARK: 6 (sec F2, `callerexec`) 부른 쪽이 지킴이를 띄운 뒤 exec

    /// 부른 쪽이 지킴이를 띄워 멈춰 두고 Apple 서명 `/bin/sleep`으로 exec한다: 서명 확인은 통과하지만 부모가 지킴이 뒤에 exec했으므로 아무것도 띄우지 않는다
    @Test func s6ACallerThatExecsAfterSpawningTheKeeperSpawnsNothing() async throws {
        let fake = try BuiltProducts.url("FakeClaudeCode").path
        let keeper = try BuiltProducts.url("tf-agent-keeper").path
        let marker = box.root.appending(path: "PWNED")
        let requirement = "identifier \"com.apple.sleep\" and anchor apple"
        var report: [Int32] = [-1, -1]
        #expect(pipe(&report) == 0)
        let null = open("/dev/null", O_RDWR)
        let (readEnd, writeEnd) = (report[0], report[1])
        let fds: [(child: Int32, parent: Int32)] = [(0, null), (1, null), (2, null), (3, writeEnd)]
        let spawned = try #require(AgentSpawn.spawn(
            executable: fake,
            arguments: ["--spawn-then-exec", keeper, "--report-fd", "3", "--ended", box.root.appending(path: "x.keeper").path, "--cwd", box.root.path, "--", "/usr/bin/touch", "touch", marker.path],
            environment: ["PATH": "/usr/bin:/bin", "TF_KEEPER_CALLER_REQUIREMENT": requirement], cwd: box.root.path, fds: fds, disclaim: false
        ))
        close(writeEnd)
        close(null)
        let execed = await ClaudeRereview5ReproTests.waitUntil(3) { KeeperCaller.satisfies(pid: spawned.pid, requirement: requirement) }
        #expect(execed, "서명 확인만으로는 통과하는 부모다 (시험 전제)")
        let reported = try await offPool { Self.readAll(readEnd, timeout: 10) }
        #expect(!reported.contains("started"), "claude를 띄우지 않았다")
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        var status: Int32 = 0
        _ = waitpid(spawned.pid, &status, 0)
    }

    /// EOF(또는 기한)까지 읽고 fd를 닫는다
    static func readAll(_ fd: Int32, timeout: TimeInterval) -> String {
        defer { close(fd) }
        var data = Data()
        var byte: UInt8 = 0
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&item, 1, 50) > 0 else { continue }
            guard read(fd, &byte, 1) == 1 else { break }
            data.append(byte)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
