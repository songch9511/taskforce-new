#if os(macOS) && DEBUG
import Darwin
import Foundation
import Testing
import TaskforceAgentWire
@testable import TaskforceKit

/// 지킴이 (OA D3a 13장, 사용자 결정 2026-10-17) · 재검토 4 반영 (12장 5–13) — 고친 뒤의 API로 보는 시험. 재현은 `ClaudeRereview4ReproTests`,
/// 지킴이 실행 파일 자체는 `TaskforceAgentKeeperTests`. 이름 앞의 `kN`이 13장(코디네이터가 고른 여섯 · 물러남), `rN`이 12장 항목 번호다
@Suite(.serialized)
struct ClaudeRereview4Tests {
    let box = ClaudeSandbox()
    let timing = ClaudeCodeTiming.ci

    // MARK: 13장 — 가짜 claude의 setsid 자손

    /// `claude`(가짜)가 살아 있는 동안 남긴 setsid 자손: 지킴이의 구성원이고, 끝내기는 그것까지 끝낸 뒤 지킴이가 끝나야 `ended`
    @Test func k1AFakeClaudesSetsidChildIsAMemberAndIsEndedBeforeTheEnd() async throws {
        let pidFile = box.root.appending(path: "setsid.pid").path
        let root = try box.keep("/usr/bin/perl -e 'use POSIX; POSIX::setsid(); open(F, q(>\(pidFile))); print F $$; close F; sleep 600;' & while :; do sleep 0.2; done")
        defer { killpg(root.kept.claudePID, SIGKILL) }
        // 자손은 setsid 뒤에 pid를 적는다: 읽었으면 세션을 떠났다
        let child = try await ClaudeProcessIdentityTests.readPID(pidFile)
        defer { kill(child, SIGKILL) }
        #expect(getsid(child) == child)
        #expect(ClaudeProcessInspector.members(root.keeper)?.contains { $0.pid == child } == true)
        let timing = self.timing
        let identity = root.identity
        let lineage = root.lineage
        let result = try await offPool { ClaudeProcessInspector.terminate(identity, timing: timing, lineage: lineage) }
        guard case .ended = result else {
            Issue.record("\(result)")
            return
        }
        #expect(await ClaudeProcessIdentityTests.vanished(child))
        // 거두기는 감독 스레드가 한다 (지킴이 기록은 그 전에 이미 있다)
        #expect(await ClaudeProcessIdentityTests.within { root.lineage.provenEnded }, "지킴이 정상 종료를 부모로서 받았다")
    }

    // MARK: 13장 — 뿌리가 먼저 끝남

    /// `claude`가 먼저 끝나도 구성원이 남아 있는 동안 지킴이는 산다(살아 있음). 구성원이 끝나면 지킴이가 스스로 증명하고 끝난다 (끝)
    @Test func k2WhenTheRootExitsFirstTheKeeperStaysUntilTheLastMemberEnds() async throws {
        let pidFile = box.root.appending(path: "left.pid").path
        let root = try box.keep("/bin/sleep 600 </dev/null >/dev/null 2>&1 & echo $! > '\(pidFile)'; exit 0")
        let member = try await ClaudeProcessIdentityTests.readPID(pidFile)
        defer { kill(member, SIGKILL) }
        #expect(await ClaudeProcessIdentityTests.within { ClaudeProcessIdentityTests.ended(root.identity) }, "뿌리가 끝났다")
        #expect(!(await root.keeperEnded(timeout: 0.8)), "구성원이 남았다: 지킴이는 산다")
        #expect(ClaudeProcessInspector.liveness(root.identity, lineage: root.lineage) == .alive)
        kill(member, SIGKILL)
        #expect(await root.keeperEnded())
        #expect(await ClaudeProcessIdentityTests.within { root.lineage.provenEnded })
        #expect(ClaudeProcessInspector.liveness(root.identity, lineage: root.lineage) == .ended(AgentExit(code: nil)))
    }

    // MARK: 13장 — 앱이 다시 떠 지킴이로 찾기

    /// 앱이 죽어 있던 동안(감독 없음) 생긴 자손도 다시 뜬 앱이 지킴이로 찾는다: 살아 있음 → 끝내기 → 지킴이 기록 → 끝
    @Test func k3ARelaunchedAppFindsTheMembersThroughTheKeeper() async throws {
        let pidFile = box.root.appending(path: "relaunch.pid").path
        // 뿌리는 0.3초 뒤에야 setsid 자손을 (짧은 중간 sh로) 남기고 끝난다: 앱은 그 전에 죽었다
        let root = try box.keep("/bin/sleep 0.3; /bin/sh -c \"/usr/bin/perl -e 'use POSIX; POSIX::setsid(); open(F, q(>\(pidFile))); print F \\$\\$; close F; sleep 600;' &\"; exit 0")
        let member = try await ClaudeProcessIdentityTests.readPID(pidFile)
        defer { kill(member, SIGKILL) }
        let relaunched = ClaudeRereview3ReproTests.adapter(box)
        #expect(await relaunched.liveness(root.identity) == .alive)
        let ended = await relaunched.terminateOrphan(root.identity)
        guard case .ended = ended else {
            Issue.record("\(ended)")
            return
        }
        #expect(await ClaudeProcessIdentityTests.vanished(member))
        #expect(ClaudeLineage.load(root.file) == .ended)
        #expect(await ClaudeRereview3ReproTests.adapter(box).liveness(root.identity) == .ended(AgentExit(code: nil)))
    }

    // MARK: 13장 — 지킴이 SIGKILL = unknown

    /// 구성원 0을 증명하기 전에 지킴이가 SIGKILL됐다: 앱(부모)도 다시 뜬 앱도 끝을 증명하지 못한다 (unknown, 잠금). 남은 구성원에는 신호를 보내지 않는다
    @Test func k4AKeeperKilledBeforeItProvedTheEndLeavesTheSpawnUnknown() async throws {
        let pidFile = box.root.appending(path: "killed.pid").path
        let root = try box.keep("/bin/sleep 600 </dev/null >/dev/null 2>&1 & echo $! > '\(pidFile)'; exit 0")
        let member = try await ClaudeProcessIdentityTests.readPID(pidFile)
        defer { kill(member, SIGKILL) }
        kill(root.kept.keeper.pid, SIGKILL)
        #expect(await root.keeperEnded())
        #expect(await ClaudeProcessIdentityTests.within { !root.lineage.provable }, "비정상 종료를 받았다")
        #expect(ClaudeProcessInspector.liveness(root.identity, lineage: root.lineage) == .unknown)
        #expect(await ClaudeRereview3ReproTests.adapter(box).liveness(root.identity) == .unknown)
        let timing = self.timing
        let identity = root.identity
        let lineage = root.lineage
        #expect(try await offPool { ClaudeProcessInspector.terminate(identity, timing: timing, lineage: lineage) } == .unknown)
        #expect(kill(member, 0) == 0, "구성원을 증명할 수 없으면 신호 0")
    }

    // MARK: 13장 — 끝 기록 없음 = unknown

    /// 지킴이가 정상 종료했어도 다시 뜬 앱은 그 지킴이의 끝 기록이 있어야 끝이다 (부모로서 받은 정상 종료는 그 앱 실행 안에서만 증거다)
    @Test func k5AMissingKeeperRecordIsUnknownAfterARelaunch() async throws {
        let root = try box.keep("exit 0")
        #expect(await root.keeperEnded())
        #expect(await ClaudeProcessIdentityTests.within { root.lineage.provenEnded }, "부모로서 정상 종료를 받았다")
        try FileManager.default.removeItem(at: ClaudeLineage.keeperFile(root.file))
        #expect(await ClaudeRereview3ReproTests.adapter(box).liveness(root.identity) == .unknown)
        // 다른 지킴이의 기록은 증거가 아니다
        let boot = try #require(ClaudeProcessInspector.bootSessionID())
        #expect(KeeperRecord.write(ClaudeLineage.keeperFile(root.file), keeperID: root.kept.keeperID + 1, boot: boot))
        #expect(await ClaudeRereview3ReproTests.adapter(box).liveness(root.identity) == .unknown)
        #expect(KeeperRecord.write(ClaudeLineage.keeperFile(root.file), keeperID: root.kept.keeperID, boot: UUID().uuidString))
        #expect(await ClaudeRereview3ReproTests.adapter(box).liveness(root.identity) == .unknown, "다른 부팅의 기록")
    }

    // MARK: 13장 — 구성원 0 → 지킴이 정상 종료 = 끝

    @Test func k6WithNoMembersTheKeeperExitsNormallyAndTheSpawnIsEnded() async throws {
        let root = try box.keep("exit 0")
        #expect(await root.keeperEnded())
        #expect(await ClaudeProcessIdentityTests.within { root.kept.keeper.exitStatus != nil })
        #expect(root.kept.keeper.exitStatus == ClaudeExitStatus(code: KeeperMain.Exit.ended.rawValue, signal: nil))
        #expect(KeeperRecord.read(ClaudeLineage.keeperFile(root.file))?.keeperID == root.kept.keeperID)
        #expect(ClaudeProcessInspector.liveness(root.identity, lineage: root.lineage) == .ended(AgentExit(code: nil)))
        #expect(await ClaudeRereview3ReproTests.adapter(box).liveness(root.identity) == .ended(AgentExit(code: nil)))
    }

    // MARK: 13장 5 물러남

    /// 지킴이가 자기 책임 프로세스가 아니다(혈통 `responsible no`): 구성원을 증명할 수 없다 → 끝을 확정하지 않고, 정체를 확인한 `claude`에만 신호
    @Test func k7WithoutResponsibilityOnlyTheVerifiedClaudeIsSignalled() async throws {
        let pidFile = box.root.appending(path: "fallback.pid").path
        let root = try box.keep("/bin/sleep 600 </dev/null >/dev/null 2>&1 & echo $! > '\(pidFile)'; while :; do sleep 0.2; done")
        let member = try await ClaudeProcessIdentityTests.readPID(pidFile)
        defer {
            kill(member, SIGKILL)
            killpg(root.kept.claudePID, SIGKILL)
        }
        let fallback = ClaudeLineage(file: box.root.appending(path: "fallback.lineage"), fresh: true)
        fallback.adopt(ClaudeLineage.Record(keeper: root.keeper, root: root.kept.claudeID, rootPID: root.kept.claudePID, attributable: false))
        #expect(!fallback.provable)
        let timing = self.timing
        let identity = root.identity
        let result = try await offPool { ClaudeProcessInspector.terminate(identity, timing: timing, lineage: fallback) }
        #expect(result == .unknown)
        #expect(await ClaudeProcessIdentityTests.within { ClaudeProcessIdentityTests.ended(root.identity) }, "claude는 끝냈다")
        #expect(kill(member, 0) == 0, "구성원에는 신호 0")
    }

    // MARK: 12장 6 뿌리 id가 전제

    /// 지킴이 · `claude`의 세대를 앱이 다시 읽지 못하면: 정체 commit · stdin 전에 지킴이가 `claude`를 SIGKILL하고 `spawnFailed`
    @Test func r6ASpawnWhoseRootIDCannotBeReadIsKilledBeforeItsIdentityIsKept() async throws {
        let fake = try FakeClaude()
        try fake.scenario(["runs": [["steps": [["text": "hi"]], "linger_after_result": 5.0]]])
        var failing = KeeperMembers.Lookups.live
        failing.generation = { _ in .failed }
        await #expect(throws: AgentStartError.self) {
            try await ClaudeProcessInspector.$lookups.withValue(failing) { _ = try await fake.turn(events: EventLog()) }
        }
        #expect(fake.log.lines.contains { $0.hasPrefix("claude_lineage_unrecorded") && $0.contains("root_id") })
        #expect(fake.log.lines.contains { $0.hasPrefix("claude_start_diagnostic") && $0.contains("cause=code(\"keeper_generation\")") && $0.contains("ended=count(1)") })
        #expect(!fake.log.events.contains("claude_spawn"))
        if let pid = fake.report(0)?["pid"] as? Int {
            #expect(await ClaudeProcessIdentityTests.within { ClaudeRereviewProcessTests.gone(pid) }, "띄운 프로세스는 멈췄다")
        }
    }

    // MARK: 12장 7 조회 3상태

    /// 지킴이 세대를 읽지 못하면 살아 있다고도 끝났다고도 하지 않는다 (unknown). 구성원 조회 실패는 그 구성원을 신호 대상에서 빼지만 끝을 만들지 않는다
    @Test func r7AFailedKeeperLookupIsNeverReadAsGone() async throws {
        let root = try box.keep("/bin/sleep 600 </dev/null >/dev/null 2>&1 & exit 0")
        defer { killpg(root.kept.claudePID, SIGKILL) }
        #expect(await ClaudeProcessIdentityTests.within { ClaudeProcessIdentityTests.ended(root.identity) }, "뿌리가 끝났다")
        let keeperPID = root.kept.keeper.pid
        var failing = KeeperMembers.Lookups.live
        failing.generation = { $0 == keeperPID ? .failed : AgentProcesses.generation(pid: $0) }
        ClaudeProcessInspector.$lookups.withValue(failing) {
            #expect(ClaudeProcessInspector.keeperState(root.keeper) == .failed)
            #expect(ClaudeProcessInspector.liveness(root.identity, lineage: root.lineage) == .unknown)
            #expect(ClaudeProcessInspector.members(root.keeper) == nil, "지킴이를 확인하지 못하면 가르지 않는다")
        }
        #expect(ClaudeProcessInspector.liveness(root.identity, lineage: root.lineage) == .alive)
    }

    // MARK: 12장 8 marker마다 혈통 객체 하나 · 따로 둔 끝 기록

    @Test func r8OneLineageObjectPerMarkerAndAStaleWriterCannotUndoTheEndRecord() async throws {
        let root = try box.keep("/bin/sleep 0.1; exit 0")
        let marker = root.identity.processMarker
        #expect(await root.keeperEnded())
        let adapter = ClaudeRereview3ReproTests.adapter(box)
        #expect(await adapter.sharedLineage(marker) === adapter.sharedLineage(marker))
        // 같은 marker의 다른 객체 (옛 방식: 부를 때마다 새로 읽었다)
        let stale = ClaudeLineage(file: root.file)
        #expect(await adapter.liveness(root.identity) == .ended(AgentExit(code: nil)))
        #expect(await adapter.sharedLineage(marker).provenEnded)
        stale.save()
        #expect(ClaudeLineage.load(root.file) == .ended, "끝 기록이 먼저다")
        #expect(await ClaudeRereview3ReproTests.adapter(box).liveness(root.identity) == .ended(AgentExit(code: nil)))
    }

    // MARK: 12장 9 요청마다 한 번 정해지는 상태

    @Test func r9TheFirstOfCommitAndTimeoutWins() {
        let committed = HookCommit()
        #expect(committed.commit(HookResponse(decision: .allow, reason: "ok")))
        #expect(committed.timeOut() == HookResponse(decision: .allow, reason: "ok"), "처리기가 먼저: 소켓은 확정된 응답을 쓴다")
        let timedOut = HookCommit()
        #expect(timedOut.timeOut() == nil)
        #expect(!timedOut.commit(HookResponse(decision: .allow, reason: "late")), "소켓이 먼저: 늦은 응답은 확정되지 않는다")
        #expect(timedOut.timeOut() == nil)
    }

    // MARK: 12장 11 국소 인코딩 탐지

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
