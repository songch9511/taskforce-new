#if os(macOS) && DEBUG
import Darwin
import Foundation
import Testing
import TaskforceAgentWire
@testable import TaskforceKit

/// 재검토 4 반영 (OA D3a 계약 12장) — 고친 뒤의 API로 보는 시험. 재현은 `ClaudeRereview4ReproTests`. 이름 앞의 `rN`이 12장 항목 번호다
@Suite(.serialized)
struct ClaudeRereview4Tests {
    let box = ClaudeSandbox()
    let timing = ClaudeCodeTiming.testing

    func spawn(_ script: String, marker: String = UUID().uuidString) throws -> (process: ClaudeSpawnedProcess, identity: AgentProcessIdentity) {
        let settings = box.root.appending(path: "config/\(marker).settings.json").path
        let process = try ClaudeSpawner.spawn(
            executable: "/bin/sh", arguments: ["-c", script, "sh", "--settings", settings], environment: ["PATH": "/usr/bin:/bin"], cwd: box.root.path
        )
        process.closeStandardStreams()
        return (process, AgentProcessIdentity(pid: Int(process.pid), startedAt: process.startedAt, processMarker: marker))
    }

    // MARK: 1 책임 프로세스

    /// 뿌리가 살아 있는 동안: 못 본 중간 sh가 남긴 setsid 자손 D도 책임 프로세스가 뿌리라 구성원이다 (그 부모 id · 그룹 · 환경으로는 찾지 못한다).
    /// 그때 혈통에 적어 두어 뿌리가 끝난 뒤에도 살아 있음으로 보고, 끝낸다
    @Test func r1WhileTheRootLivesAnUnseenSetsidDescendantIsAMemberByResponsibility() async throws {
        let tag = ClaudeRereview4ReproTests.tag()
        defer { ClaudeRereview4ReproTests.kill(matching: tag) }
        let root = try spawn("/bin/sh -c \"/usr/bin/perl -e 'use POSIX; POSIX::setsid(); sleep 600;' \(tag) &\"; exec /bin/sleep 30")
        defer { _ = ClaudeProcessInspector.forceKill(root.process) }
        #expect(root.process.disclaimed)
        let lineage = ClaudeLineage()
        lineage.seed(root.process.pid, disclaimed: root.process.disclaimed)
        var orphan: pid_t?
        for _ in 0..<250 where orphan == nil {
            try await Task.sleep(for: .milliseconds(20))
            orphan = ClaudeRereview4ReproTests.pids(matching: tag).first.flatMap { getpgid($0) == $0 ? $0 : nil }
        }
        let d = try #require(orphan, "D가 세션을 떠났다")
        // 중간 sh가 끝나기를 기다린다 (D의 부모가 launchd 밑으로)
        func adopted() -> Bool {
            if case .present(let generation) = ClaudeProcessInspector.generation(pid: d) { return generation.parentPID == 1 }
            return false
        }
        for _ in 0..<250 where !adopted() { try await Task.sleep(for: .milliseconds(20)) }
        let parent = try #require(ClaudeProcessInspector.uniqueIDs(pid: d)?.parent)
        #expect(!lineage.contains(parent), "D의 부모(중간 sh)는 본 적이 없다")
        #expect(ClaudeProcessInspector.descendants(root.identity, lineage: lineage)?.contains { $0.pid == d } == true, "책임 프로세스로 찾았다")
        // 뿌리가 끝났다: 그 뒤 D는 스스로의 책임 프로세스지만 혈통에 적혀 있다
        kill(root.process.pid, SIGKILL)
        _ = try await offPool { root.process.waitForExit() }
        #expect(ClaudeProcessInspector.liveness(root.identity, lineage: lineage) == .alive, "뿌리가 끝난 뒤에는 혈통이 D를 안다")
        let lineageForTerminate = lineage
        let timing = self.timing
        let result = try await offPool { ClaudeProcessInspector.terminate(root.identity, timing: timing, lineage: lineageForTerminate) }
        guard case .ended = result else {
            Issue.record("\(result)")
            return
        }
        #expect(await ClaudeProcessIdentityTests.vanished(d))
    }

    /// 그 pid가 지금 뿌리(같은 unique id)가 아니면 책임 pid로 가르지 않는다: 뿌리가 끝난 뒤 같은 pid를 받은 다른 프로세스의 자손을 구성원으로 보지 않는다
    @Test func r1AResponsiblePIDCountsOnlyWhileThatPIDIsStillTheRoot() async throws {
        let root = try spawn("exec /bin/sleep 30")
        defer { _ = ClaudeProcessInspector.forceKill(root.process) }
        func fresh() -> ClaudeLineage {
            let lineage = ClaudeLineage()
            lineage.seed(root.process.pid)
            return lineage
        }
        let rootID = try #require(fresh().rootID)
        let other = try ClaudeSpawner.spawn(executable: "/bin/sleep", arguments: ["30"], environment: ["PATH": "/bin"], cwd: box.root.path)
        other.closeStandardStreams()
        defer { _ = ClaudeProcessInspector.forceKill(other) }
        let rootPID = root.process.pid
        let otherPID = other.pid
        var reused = ClaudeProcessInspector.Lookups.live
        // 모든 프로세스가 그 pid를 책임 프로세스로 돌려준다
        reused.responsible = { _ in .present(rootPID) }
        let attributed = fresh()
        ClaudeProcessInspector.$lookups.withValue(reused) {
            #expect(ClaudeProcessInspector.descendants(root.identity, lineage: attributed)?.contains { $0.pid == otherPID } == true, "뿌리가 그대로면 책임 pid로 가른다")
        }
        // 그 pid의 지금 프로세스가 다른 unique id다 (뿌리가 끝난 뒤 다시 쓰였다)
        reused.generation = { pid in
            guard pid == rootPID, case .present(let now) = ClaudeProcessInspector.generation(pid: pid) else { return ClaudeProcessInspector.generation(pid: pid) }
            return .present(ClaudeProcessInspector.Generation(
                pid: now.pid, startSeconds: now.startSeconds, startMicros: now.startMicros, parentPID: now.parentPID, group: now.group, uid: now.uid, zombie: now.zombie,
                own: rootID + 1_000_000, parent: now.parent
            ))
        }
        let replaced = fresh()
        ClaudeProcessInspector.$lookups.withValue(reused) {
            #expect(ClaudeProcessInspector.descendants(root.identity, lineage: replaced)?.contains { $0.pid == otherPID } == false)
        }
    }

    // MARK: 2 물러남 = 잠금

    /// disclaim 없이 띄운 spawn: 구성원을 증명할 수 없다. 혈통으로 본 자식은 살아 있음이지만 신호는 보내지 않고, 끝을 확정하지 않는다
    @Test func r2WithoutDisclaimTheEndIsNeverProvenAndNoDescendantIsSignalled() async throws {
        let pidFile = box.root.appending(path: "child.pid").path
        let root = try spawn("/bin/sleep 30 & echo $! > '\(pidFile)'; /bin/sleep 0.2; exit 0")
        let lineage = ClaudeLineage()
        lineage.seed(root.process.pid, disclaimed: false)
        #expect(!lineage.provable)
        let child = try await ClaudeProcessIdentityTests.readPID(pidFile)
        defer { kill(child, SIGKILL) }
        _ = try await offPool { root.process.waitForExit() }
        #expect(ClaudeProcessInspector.liveness(root.identity, lineage: lineage) == .alive)
        let unprovable = lineage
        let timing = self.timing
        #expect(try await offPool { ClaudeProcessInspector.terminate(root.identity, timing: timing, lineage: unprovable) } == .alive)
        #expect(kill(child, 0) == 0, "구성원을 증명할 수 없으면 신호 0")
        #expect(!ClaudeProcessInspector.endDescendants(root.identity, lineage: lineage, timing: timing))
        #expect(kill(child, 0) == 0)
        kill(child, SIGKILL)
        _ = await ClaudeProcessIdentityTests.vanished(child)
        #expect(ClaudeProcessInspector.liveness(root.identity, lineage: lineage) == .unknown, "자손이 없어도 끝을 확정하지 않는다")
    }

    /// 뿌리가 살아 있는데 자기 책임 프로세스가 아니다 (disclaim이 듣지 않았다): 그 spawn은 증명할 수 없음으로 바뀌고 파일에도 남는다
    @Test func r2ARootThatIsNotItsOwnResponsibleProcessMakesTheSpawnUnprovable() throws {
        let marker = UUID().uuidString
        let file = box.sessionsRoot.appending(path: "lineage/\(marker).lineage")
        let root = try spawn("/bin/sleep 5", marker: marker)
        defer { _ = ClaudeProcessInspector.forceKill(root.process) }
        let lineage = ClaudeLineage(file: file, fresh: true)
        lineage.seed(root.process.pid, disclaimed: root.process.disclaimed)
        lineage.save(force: true)
        #expect(lineage.provable)
        var lookups = ClaudeProcessInspector.Lookups.live
        lookups.responsible = { _ in .present(1) }
        ClaudeProcessInspector.$lookups.withValue(lookups) { _ = ClaudeProcessInspector.scan(root.identity, lineage: lineage) }
        #expect(!lineage.provable)
        #expect(!ClaudeLineage(file: file).attributable, "파일: responsible no")
    }

    // MARK: 4 보조 규칙

    /// 귀속되지 않은 살아 있는 프로세스(뿌리보다 뒤)가 혈통에 적힌 pid의 그룹에 있으면 그 훑기는 불완전이다 (뿌리 pid의 그룹은 `f1Unseen` 재현)
    @Test func r4AnUnattributedProcessInTheGroupOfALineagePIDMakesTheScanIncomplete() async throws {
        let root = try spawn("/bin/sleep 0.1; exit 0")
        let lineage = ClaudeLineage()
        lineage.seed(root.process.pid)
        _ = try await offPool { root.process.waitForExit() }
        let group = try ClaudeSpawner.spawn(executable: "/bin/sh", arguments: ["-c", "/bin/sleep 30 & /bin/sleep 30"], environment: ["PATH": "/bin:/usr/bin"], cwd: box.root.path)
        group.closeStandardStreams()
        defer { _ = ClaudeProcessInspector.forceKill(group) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(ClaudeProcessInspector.scan(root.identity, lineage: lineage)?.complete == true, "무관한 그룹")
        // 혈통에 그 pid가 적혔다 (그 pid의 구성원이 자기 그룹을 만들었다)
        lineage.insert(2, pid: group.pid)
        let scan = try #require(ClaudeProcessInspector.scan(root.identity, lineage: lineage))
        #expect(!scan.complete && scan.members.isEmpty)
        #expect(ClaudeProcessInspector.liveness(root.identity, lineage: lineage) == .unknown)
    }

    // MARK: 6 뿌리 id가 전제

    /// 첫 세대 조회로 뿌리 id를 못 얻으면: 정체 commit · stdin 전에 SIGKILL하고 `spawnFailed`
    @Test func r6ASpawnWhoseRootIDCannotBeReadIsKilledBeforeItsIdentityIsKept() async throws {
        let fake = try FakeClaude()
        try fake.scenario(["runs": [["steps": [["text": "hi"]], "linger_after_result": 5.0]]])
        var failing = ClaudeProcessInspector.Lookups.live
        failing.generation = { _ in .failed }
        await #expect(throws: AgentStartError.self) {
            try await ClaudeProcessInspector.$lookups.withValue(failing) { _ = try await fake.turn(events: EventLog()) }
        }
        #expect(fake.log.lines.contains { $0.hasPrefix("claude_lineage_unrecorded") && $0.contains("root_id") })
        #expect(!fake.log.events.contains("claude_spawn"))
        try await Task.sleep(for: .milliseconds(300))
        if let pid = fake.report(0)?["pid"] as? Int {
            #expect(ClaudeRereviewProcessTests.gone(pid), "띄운 프로세스는 멈췄다")
        }
    }

    // MARK: 7 조회 3상태

    /// 살아 있는 프로세스의 세대 조회 · 목록 재확인이 모두 실패: 사라짐으로 읽지 않고 불완전 (Astra P1-3)
    @Test func r7AFailedLookupIsNeverReadAsGone() async throws {
        let root = try spawn("/bin/sleep 0.1; exit 0")
        let lineage = ClaudeLineage()
        lineage.seed(root.process.pid)
        _ = try await offPool { root.process.waitForExit() }
        let other = try ClaudeSpawner.spawn(executable: "/bin/sleep", arguments: ["30"], environment: ["PATH": "/bin"], cwd: box.root.path)
        other.closeStandardStreams()
        defer { _ = ClaudeProcessInspector.forceKill(other) }
        #expect(ClaudeProcessInspector.scan(root.identity, lineage: lineage)?.complete == true)
        let pid = other.pid
        var failing = ClaudeProcessInspector.Lookups.live
        failing.generation = { $0 == pid ? .failed : ClaudeProcessInspector.generation(pid: $0) }
        failing.listed = { $0.pid == pid ? .failed : ClaudeProcessInspector.listed($0) }
        ClaudeProcessInspector.$lookups.withValue(failing) {
            #expect(ClaudeProcessInspector.scan(root.identity, lineage: lineage)?.complete == false, "세대 조회 실패")
            #expect(ClaudeProcessInspector.descendantsProvenGone(root.identity, lineage) == nil)
        }
        // 세대가 사라진 것으로 읽혀도 목록 재확인이 실패하면 불완전
        failing.generation = { $0 == pid ? .gone : ClaudeProcessInspector.generation(pid: $0) }
        ClaudeProcessInspector.$lookups.withValue(failing) {
            #expect(ClaudeProcessInspector.scan(root.identity, lineage: lineage)?.complete == false, "목록 재확인 실패")
        }
        // 세대 조회 실패는 목록이 사라졌다고 해도 불완전 (실패는 사라짐이 아니다)
        failing.generation = { $0 == pid ? .failed : ClaudeProcessInspector.generation(pid: $0) }
        failing.listed = { $0.pid == pid ? .gone : ClaudeProcessInspector.listed($0) }
        ClaudeProcessInspector.$lookups.withValue(failing) {
            #expect(ClaudeProcessInspector.scan(root.identity, lineage: lineage)?.complete == false, "세대 조회 실패 + 목록 없음")
        }
    }

    /// 뿌리가 살아 있는 동안 후보의 책임 프로세스 조회가 실패하면 불완전
    @Test func r7AFailedResponsibilityLookupMakesTheScanIncomplete() throws {
        let root = try spawn("/bin/sleep 30 & /bin/sleep 30")
        defer { _ = ClaudeProcessInspector.forceKill(root.process) }
        let lineage = ClaudeLineage()
        lineage.seed(root.process.pid)
        Thread.sleep(forTimeInterval: 0.2)
        let rootPID = root.process.pid
        var failing = ClaudeProcessInspector.Lookups.live
        failing.responsible = { $0 == rootPID ? .present(rootPID) : .failed }
        ClaudeProcessInspector.$lookups.withValue(failing) {
            #expect(ClaudeProcessInspector.scan(root.identity, lineage: lineage)?.complete == false)
        }
        #expect(ClaudeProcessInspector.scan(root.identity, lineage: lineage)?.complete == true)
    }

    // MARK: 8 marker마다 혈통 객체 하나 · 따로 둔 끝 기록

    @Test func r8OneLineageObjectPerMarkerAndAStaleWriterCannotUndoTheEndRecord() async throws {
        let marker = UUID().uuidString
        let file = box.sessionsRoot.appending(path: "lineage/\(marker).lineage")
        let root = try spawn("/bin/sleep 0.1; exit 0", marker: marker)
        let first = ClaudeLineage(file: file, fresh: true)
        first.seed(root.process.pid)
        first.save(force: true)
        _ = try await offPool { root.process.waitForExit() }
        let adapter = ClaudeRereview3ReproTests.adapter(box)
        #expect(await adapter.sharedLineage(marker) === adapter.sharedLineage(marker))
        // 같은 marker의 다른 객체 (옛 방식: 부를 때마다 새로 읽었다)
        let stale = ClaudeLineage(file: file)
        #expect(await adapter.liveness(root.identity) == .ended(AgentExit(code: nil)))
        #expect(await adapter.sharedLineage(marker).provenEnded)
        stale.insert(99, pid: 9)
        stale.save(force: true)
        #expect(ClaudeLineage.load(file) == .ended, "끝 기록이 먼저다")
        #expect(await ClaudeRereview3ReproTests.adapter(box).liveness(root.identity) == .ended(AgentExit(code: nil)))
    }

    // MARK: 9 요청마다 한 번 정해지는 상태

    @Test func r9TheFirstOfCommitAndTimeoutWins() {
        let committed = HookCommit()
        #expect(committed.commit(HookResponse(decision: .allow, reason: "ok")))
        #expect(committed.timeOut() == HookResponse(decision: .allow, reason: "ok"), "처리기가 먼저: 소켓은 확정된 응답을 쓴다")
        let timedOut = HookCommit()
        #expect(timedOut.timeOut() == nil)
        #expect(!timedOut.commit(HookResponse(decision: .allow, reason: "late")), "소켓이 먼저: 늦은 응답은 확정되지 않는다")
        #expect(timedOut.timeOut() == nil)
    }

    // MARK: 11 국소 인코딩 탐지

    @Test func r11ANSICFragmentsAreDecodedOneByOneAndBashCommentsStayLiteral() {
        let bs = ClaudeRereview3ReproTests.bs
        #expect(SecretRedactor.ansiCFragmentsDecoded("It's $'" + bs + "x41" + bs + "x42' and $'C'") == "It's AB and C")
        #expect(SecretRedactor.ansiCFragmentsDecoded("no fragment's here") == nil)
        #expect(SecretRedactor.ansiCFragmentsDecoded("open $'" + bs + "x41") == nil, "닫히지 않은 조각은 그대로")
        #expect(SecretRedactor.shellUnquoted("# user's setup\necho 'a b'") == "# user's setup\necho a b", "주석 안의 작은따옴표")
        #expect(SecretRedactor.shellUnquoted("echo a#b 'c'") == "echo a#b c", "단어 가운데 #는 주석이 아니다")
    }
}
#endif
