#if os(macOS) && DEBUG
import Darwin
import Foundation
import Testing
import TaskforceAgentWire
@testable import TaskforceKit

/// R1-01 실패(`start_error:spawn_failed`, 로그 `reason=root_id`)의 진단: 지킴이의 첫 보고를 받지 못한 시작이 뿌리 id 대조 실패로 적혔다.
/// 원인은 고정 코드로 가르고, 보고를 받지 못한 경우의 `claude_start_unproven` reason은 그 원인 코드다 (정체 대조 실패만 문서대로 `root_id`)
@Suite(.serialized)
struct ClaudeStartDiagnosticTests {
    let box = ClaudeSandbox()

    /// 지킴이 대신 띄울 대본 (보고 fd는 3)
    func keeper(_ body: String) throws -> String {
        let url = box.root.appending(path: "keeper-\(UUID().uuidString.prefix(6))")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(chmod(url.path, 0o755) == 0)
        return url.path
    }

    /// 시험의 기한은 넉넉하다 (제품 기본은 보고 5초 · 거두기 3초): 붐비는 기계에서 `/bin/sh`가 뜨고 첫 줄을 쓰는 데 걸리는 시간이 원인 판정을 바꾸면 안 된다.
    /// 기다림은 일이 정해지면 바로 돌아오므로 통과 시간은 같다. 기한이 짧아야 하는 시험(`report_timeout`)만 자기 값을 넘긴다
    static let generousReport: TimeInterval = 30
    static let generousAbort: TimeInterval = 20

    func spawn(keeper path: String, reportTimeout: TimeInterval = generousReport, abortTimeout: TimeInterval = generousAbort) -> Result<ClaudeKeptSpawn, ClaudeKeptFailure> {
        ClaudeSpawner.spawnKept(
            keeper: path, ended: box.root.appending(path: "k.keeper"), executable: "/bin/sh", argv0: "/bin/sh", arguments: ["-c", "exit 0"],
            environment: ["PATH": "/usr/bin:/bin"], cwd: box.root.path, reportTimeout: reportTimeout, abortTimeout: abortTimeout
        )
    }

    func cause(_ result: Result<ClaudeKeptSpawn, ClaudeKeptFailure>) -> ClaudeStartDiagnostic? {
        if case .failure(.stopped(_, let diagnostic)) = result { return diagnostic }
        return nil
    }

    // MARK: 보고를 받지 못한 원인은 서로 다른 코드다

    /// 지킴이가 첫 보고를 기한 안에 쓰지 못했다(R1-01: 지킴이가 권한 확인 · 첫 실행 검사에 막혀 5초를 넘겼다): `report_timeout` + 기다린 시간
    @Test func aKeeperThatDoesNotReportInTimeIsAReportTimeout() throws {
        let diagnostic = try #require(cause(spawn(keeper: try keeper("exec /bin/sleep 30"), reportTimeout: 0.4)))
        #expect(diagnostic.cause == .reportTimeout)
        #expect(diagnostic.waitMilliseconds >= 350, "기한만큼 기다렸다")
        #expect(!diagnostic.abort.forcedKill)
        #expect(!diagnostic.abort.ended, "끝을 증명하지 못했다")
    }

    /// 보고 없이 보고 fd를 닫고 끝났다: `report_eof` — 기한을 기다리지 않는다
    @Test func aKeeperThatClosesTheReportWithoutALineIsReportEOF() throws {
        let diagnostic = try #require(cause(spawn(keeper: try keeper("exit 0"))))
        #expect(diagnostic.cause == .reportEOF)
        // EOF는 기한을 기다리지 않는다: 기한(30초)의 절반 안에 돌아왔다 (붐비는 기계에서 /bin/sh가 뜨는 시간은 넉넉히 허용)
        #expect(diagnostic.waitMilliseconds < Int(Self.generousReport * 500))
    }

    @Test func aKeeperThatReportsFailureIsKeeperFailed() throws {
        #expect(cause(spawn(keeper: try keeper("echo failed >&3; exit 3")))?.cause == .keeperFailed)
    }

    /// 붐비는 기계에서는 `/bin/sh`가 뜨고 첫 줄을 쓰는 데 시험의 짧은 기한을 넘기기도 한다 (전체 시험을 부하 아래 돌리면 이 시험들이 간헐적으로 실패했다).
    /// 늦게 쓴 줄도 기한 안이면 그 줄의 원인으로 가른다: 늦음이 `report_timeout`으로 둔갑하면 안 된다. 늦게 뜨는 지킴이를 1초 늦춘 대본으로 흉내 낸다
    @Test func aKeeperThatReportsLateIsStillNamedByWhatItReported() throws {
        let diagnostic = try #require(cause(spawn(keeper: try keeper("sleep 1; echo failed >&3; exit 3"))))
        #expect(diagnostic.cause == .keeperFailed)
        #expect(diagnostic.waitMilliseconds >= 900, "정말 늦게 보고했다")
    }

    @Test func aKeeperThatReportsTheWrongLineIsUnexpected() throws {
        #expect(cause(spawn(keeper: try keeper("echo ended >&3; exec /bin/sleep 30")))?.cause == .unexpectedReport)
    }

    @Test func aGarbledOrOverlongReportLineIsNamedNotTreatedAsAnIdentity() throws {
        #expect(cause(spawn(keeper: try keeper("echo nonsense >&3; exec /bin/sleep 30")))?.cause == .reportMalformed)
        #expect(cause(spawn(keeper: try keeper("printf '%0300d' 0 >&3; exec /bin/sleep 30")))?.cause == .reportTooLong)
    }

    // MARK: 정체 대조 순서 (안전 검사는 그대로, 실패한 항목만 이름이 붙는다)

    func generation(pid: pid_t, own: UInt64, parentPID: pid_t, zombie: Bool = false) -> ProcessGeneration {
        ProcessGeneration(pid: pid, startSeconds: 1, startMicros: 1, parentPID: parentPID, group: pid, uid: getuid(), zombie: zombie, own: own, parent: 1)
    }

    func lookups(_ table: [pid_t: ProcessLookup<ProcessGeneration>]) -> KeeperMembers.Lookups {
        var lookups = KeeperMembers.Lookups.live
        lookups.generation = { table[$0] ?? .gone }
        return lookups
    }

    @Test func theRootIdentityChecksKeepTheirOrderAndEachOneIsNamed() {
        let keeper = generation(pid: 100, own: 10, parentPID: 1)
        let root = generation(pid: 200, own: 20, parentPID: 100)
        func check(_ table: [pid_t: ProcessLookup<ProcessGeneration>], keeperID: UInt64 = 10, rootID: UInt64 = 20) -> ClaudeStartFailureCause? {
            if case .failure(let cause) = ClaudeSpawner.verifiedRootStart(keeperPID: 100, keeperID: keeperID, rootPID: 200, rootID: rootID, lookups: lookups(table)) { return cause }
            return nil
        }
        #expect(check([100: .present(keeper), 200: .present(root)]) == nil)
        #expect(check([200: .present(root)]) == .keeperGeneration)
        #expect(check([100: .present(keeper), 200: .present(root)], keeperID: 11) == .keeperID)
        #expect(check([100: .present(generation(pid: 100, own: 10, parentPID: 1, zombie: true)), 200: .present(root)]) == .keeperZombie)
        #expect(check([100: .present(keeper)]) == .rootGeneration)
        #expect(check([100: .present(keeper), 200: .present(root)], rootID: 21) == .rootID)
        #expect(check([100: .present(keeper), 200: .present(generation(pid: 200, own: 20, parentPID: 1))]) == .rootParent, "부모가 지킴이가 아니면 받지 않는다")
        #expect(check([100: .present(keeper), 200: .present(generation(pid: 200, own: 20, parentPID: 100, zombie: true))]) == .rootZombie)
        #expect(check([100: .present(keeper), 200: .failed]) == .rootGeneration, "조회 실패를 값으로 바꾸지 않는다")
    }

    // MARK: 로그 reason

    /// 지킴이가 보고 없이 0으로 끝났다(보고 `ended` 없음): 시작 실패의 reason은 `report_eof` — `root_id`가 아니다. 진단 줄에는 원인 · 시간 · 종료 상태가 고정 코드로만 있다
    @Test func aStartWithoutAReportNamesTheReportNotTheRootID() async throws {
        let fake = try FakeClaude(keeper: try keeper("exit 0"))
        try fake.scenario(["runs": [["steps": [["text": "ok"]]]]])
        await #expect(throws: AgentStartError.self) { _ = try await fake.turn(events: EventLog()) }
        let lines = fake.log.lines
        #expect(lines.contains { $0.hasPrefix("claude_start_unproven") && $0.contains("reason=code(\"report_eof\")") }, "\(lines)")
        #expect(!lines.contains { $0.hasPrefix("claude_start_unproven") && $0.contains("root_id") })
        let diagnostic = try #require(lines.first { $0.hasPrefix("claude_start_diagnostic") })
        #expect(diagnostic.contains("cause=code(\"report_eof\")"))
        // 글 · 경로 · 환경은 진단에 없다
        for text in [fake.workspace, fake.box.root.path, "PATH", "HOME"] { #expect(!diagnostic.contains(text), "\(text)") }
    }

    /// 종료 코드 · 신호가 없으면 -1이라는 숫자로 위장하지 않고 고정 코드 `none`으로 적는다
    @Test func aMissingExitCodeOrSignalIsLoggedAsNoneNotMinusOne() async throws {
        let killed = try FakeClaude(keeper: try keeper("kill -9 $$"))
        try killed.scenario(["runs": [["steps": [["text": "ok"]]]]])
        await #expect(throws: AgentStartError.self) { _ = try await killed.turn(events: EventLog()) }
        let signalled = try #require(killed.log.lines.first { $0.hasPrefix("claude_start_diagnostic") })
        #expect(signalled.contains("exit_code=code(\"none\")") && signalled.contains("signal=count(9)"), "\(signalled)")
        #expect(!signalled.contains("count(-1)"))
        let exited = try FakeClaude(keeper: try keeper("exit 0"))
        try exited.scenario(["runs": [["steps": [["text": "ok"]]]]])
        await #expect(throws: AgentStartError.self) { _ = try await exited.turn(events: EventLog()) }
        let normal = try #require(exited.log.lines.first { $0.hasPrefix("claude_start_diagnostic") })
        #expect(normal.contains("exit_code=count(0)") && normal.contains("signal=code(\"none\")"), "\(normal)")
    }

    /// 지킴이가 알린 뿌리를 앱이 다시 읽지 못하면(조회 실패) 문서대로 `root_id`다 (`claude_lineage_unrecorded {reason: root_id}`)
    @Test func anIdentityMismatchKeepsTheDocumentedRootIDReason() {
        #expect(ClaudeStartFailureCause.rootGeneration.launchReason == "root_id")
        #expect(ClaudeStartFailureCause.keeperID.launchReason == "root_id")
        #expect(ClaudeStartFailureCause.rootParent.launchReason == "root_id")
        #expect(ClaudeStartFailureCause.reportTimeout.launchReason == "report_timeout")
        #expect(ClaudeStartFailureCause.keeperFailed.launchReason == "keeper_failed")
    }
}
#endif
