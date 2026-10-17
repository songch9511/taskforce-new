#if os(macOS) && DEBUG
import Darwin
import Foundation
import Synchronization
import Testing
import TaskforceAgentWire
@testable import TaskforceKit

/// 18장 (CI 안정화 2): 같은 사용자의 무관한 프로세스가 짧은 프로세스를 쉬지 않고 띄워도(빌드처럼) 지킴이는 끝을 증명한다. 구성원 사슬은 그대로 끝이 아니다.
/// 20장: 지킴이 **전에** 시작한 생멸은 끝 증명을 막지 않고, 지킴이 **뒤에** 시작한 생멸(세션 중에 시작한 빌드)은 멈춘 뒤에 끝을 증명한다.
/// 실제로 빌드한 지킴이 + 가짜 `claude`. 실제 `claude` 실행 0
@Suite(.serialized)
struct ClaudeKeeperChurnTests {
    let box = ClaudeSandbox()

    /// 지킴이 밖의 오래 사는 부모 넷 (시험 프로세스의 자식, 책임 프로세스 ≠ 지킴이): 셸 반복이 `/usr/bin/true`를 쉬지 않고 다섯씩 띄운다 (빌드처럼 짧은 프로세스가 끊이지 않는다).
    /// 끝 증명 동안만 돌리고 가장 낮은 우선순위(`nice 20`)로 둔다: 이렇게 센 생멸이 Kit 전체 실행 내내 돌면 함께 도는 다른 시험 묶음(Bridge 깨우기 루프 등)이 기한을 넘겼다
    final class Churn {
        let loops: [ClaudeSpawnedProcess]
        /// 한 번만 끝낸다: 거둔 셸의 pid는 다른 프로세스가 다시 쓸 수 있다
        private let stopped = Mutex(false)

        init(count: Int = 4, cwd: String) throws {
            loops = try (0..<count).map { _ in
                let script = "while :; do /usr/bin/true & /usr/bin/true & /usr/bin/true & /usr/bin/true & /usr/bin/true; wait; done"
                let process = try ClaudeSpawner.spawn(
                    executable: "/usr/bin/nice", arguments: ["-n", "20", "/bin/sh", "-c", script], environment: ["PATH": "/usr/bin:/bin"], cwd: cwd
                )
                process.closeStandardStreams()
                return process
            }
        }

        /// 그룹째 끝내고 거둔다 (셸과 그 자식 `true`)
        func stop() {
            let first = stopped.withLock { already in
                let first = !already
                already = true
                return first
            }
            guard first else { return }
            for loop in loops { _ = ClaudeProcessInspector.forceKill(loop) }
        }
    }

    /// 지킴이(턴) 전에 시작한 생멸: 셸이 지킴이보다 먼저 생겼으니 목록과 조회 사이에 거둬진 `true`도 무해하다 — 생멸이 도는 동안 끝을 증명한다
    @Test func aNormalTurnEndsWhileUnrelatedProcessesChurn() async throws {
        var timing = ClaudeCodeTiming.ci
        timing.exitAfterResult = 30
        let fake = try FakeClaude(timing: timing)
        let gate = fake.box.root.appending(path: "exit-gate").path
        try fake.scenario(["runs": [["steps": [["text": "Hello there"]], "wait_for_file_after_result": gate]]])
        let churn = try Churn(cwd: box.root.path)
        defer { churn.stop() }
        let events = EventLog()
        _ = try await fake.turn("Summarize the notes.", events: events)
        #expect(await events.wait { $0.contains(.turnCompleted) }, "결과까지 왔다 (시험 전제)")
        FileManager.default.createFile(atPath: gate, contents: Data())
        #expect(await events.wait { FakeClaude.ended($0) }, "턴이 끝을 증명했다")
        #expect(events.ended == AgentExit(code: 0))
        #expect(await fake.process.sessionRun(ClaudeTest.session)?.liveness == .ended(AgentExit(code: nil)))
    }

    /// 지킴이(턴) 뒤에 시작한 생멸(세션 중에 시작한 빌드): 그 `true`가 목록과 조회 사이에 거둬지면 훑기는 불완전이다(20장 생존 쪽 결과) — 생멸이 멈추면 끝을 증명한다.
    /// 도는 동안 끝을 증명했을 수도 있다(두 번 연속 거둬지는 것을 놓치지 않은 훑기): 그것도 맞으므로 도는 동안은 묻지 않는다
    @Test func aTurnWhoseChurnStartedAfterItsKeeperEndsOnceTheChurnStops() async throws {
        var timing = ClaudeCodeTiming.ci
        timing.exitAfterResult = 30
        let fake = try FakeClaude(timing: timing)
        let gate = fake.box.root.appending(path: "exit-gate").path
        try fake.scenario(["runs": [["steps": [["text": "Hello there"]], "wait_for_file_after_result": gate]]])
        let events = EventLog()
        _ = try await fake.turn("Summarize the notes.", events: events)
        #expect(await events.wait { $0.contains(.turnCompleted) }, "결과까지 왔다 (시험 전제)")
        let churn = try Churn(cwd: box.root.path)
        defer { churn.stop() }
        FileManager.default.createFile(atPath: gate, contents: Data())
        try await Task.sleep(for: .seconds(2))
        churn.stop()
        #expect(await events.wait { FakeClaude.ended($0) }, "생멸이 멈춘 뒤 끝을 증명했다")
        #expect(events.ended == AgentExit(code: 0))
        #expect(await fake.process.sessionRun(ClaudeTest.session)?.liveness == .ended(AgentExit(code: nil)))
    }

    @Test func aKeeperWithNoMembersExitsNormallyWhileUnrelatedProcessesChurn() async throws {
        let churn = try Churn(cwd: box.root.path)
        defer { churn.stop() }
        let root = try box.keep("exit 0")
        #expect(await root.keeperEnded())
        #expect(await ClaudeProcessIdentityTests.within { root.kept.keeper.exitStatus != nil })
        #expect(root.kept.keeper.exitStatus == ClaudeExitStatus(code: KeeperMain.Exit.ended.rawValue, signal: nil))
        #expect(KeeperRecord.read(ClaudeLineage.keeperFile(root.file))?.keeperID == root.kept.keeperID)
    }

    @Test func aGoneProcessIsEndedThroughItsKeeperWhileUnrelatedProcessesChurn() async throws {
        let churn = try Churn(cwd: box.root.path)
        defer { churn.stop() }
        let child = try box.keep("exit 0")
        #expect(await child.keeperEnded())
        #expect(ClaudeProcessInspector.liveness(child.identity, lineage: child.lineage) == .ended(AgentExit(code: nil)))
        #expect(ClaudeProcessInspector.liveness(child.identity, lineage: ClaudeLineage(file: child.file)) == .ended(AgentExit(code: nil)), "다시 뜬 앱: 지킴이 기록")
    }

    /// 구성원 사슬: `claude`의 자손이 자식을 띄우고 곧 끝나기를 되풀이한다 (사라진 고리의 부모는 끝났거나 launchd거나 구성원): 도는 동안은 끝이 아니고, 멈춘 뒤에 끝난다.
    /// 고리마다 2ms 쉬고 낮은 우선순위로 돈다 (쉬지 않는 fork 폭주는 함께 도는 시험 묶음을 늦췄다)
    @Test func aMemberForkChainIsNeverEndedWhileItRunsAndEndsAfterItStops() async throws {
        let stop = box.root.appending(path: "chain-stop").path
        let tag = "624.\(Int.random(in: 10000...99999))"
        let chain = "/usr/bin/nice -n 20 /usr/bin/perl -e 'until (-e q(\(stop))) { select(undef, undef, undef, 0.002); exit 0 if fork; }' \(tag)"
        let root = try box.keep("\(chain) </dev/null >/dev/null 2>&1 & exit 0")
        defer {
            FileManager.default.createFile(atPath: stop, contents: Data())
            for pid in KeeperRereviewTag.pids(tag) { kill(pid, SIGKILL) }
        }
        #expect(await ClaudeRereview5ReproTests.waitUntil(30) { !KeeperRereviewTag.pids(tag).isEmpty }, "사슬이 돈다 (시험 전제)")
        var falseEnds = 0
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if root.lineage.provenEnded || ClaudeProcessInspector.liveness(root.identity, lineage: root.lineage) == .ended(AgentExit(code: nil)) { falseEnds += 1 }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(falseEnds == 0, "사슬이 도는 동안 끝이라 하지 않는다")
        #expect(ClaudeProcessInspector.keeperState(root.keeper) == .alive, "지킴이는 산다")
        FileManager.default.createFile(atPath: stop, contents: Data())
        #expect(await root.keeperEnded(), "사슬이 멈추면 끝을 증명한다")
        #expect(ClaudeProcessInspector.liveness(root.identity, lineage: root.lineage) == .ended(AgentExit(code: nil)))
    }
}
#endif
