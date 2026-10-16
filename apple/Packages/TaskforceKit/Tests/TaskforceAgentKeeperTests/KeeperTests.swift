#if os(macOS)
import Darwin
import Foundation
import MachO
import Testing
@testable import TaskforceAgentWire

/// 지킴이 helper (OA D3a 13장): 실제로 빌드한 `tf-agent-keeper`를 앱처럼 disclaim해서 띄우고, 가짜 `claude`(`/bin/sh -c`)로 본다. 실제 `claude` 실행 0.
/// 이름 앞의 `kN`: 1 구성원 0 → 정상 종료 · 끝 기록, 2 setsid 자손 · 뿌리가 먼저 끝남, 3 못 본 중간 프로세스, 4 띄우기 실패, 5 stdio, 6 인자, 7 훑기 3상태, 8 기록 · 보고 형식
@Suite(.serialized)
struct KeeperTests {
    let folder: URL

    init() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "tf-keeper-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    static func keeperURL() throws -> URL {
        for index in 0..<_dyld_image_count() {
            guard let raw = _dyld_get_image_name(index) else { continue }
            let path = String(cString: raw)
            guard let range = path.range(of: ".xctest/") else { continue }
            let candidate = URL(fileURLWithPath: String(path[..<range.lowerBound]) + ".xctest").deletingLastPathComponent().appending(path: "tf-agent-keeper")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw CancellationError()
    }

    /// 앱처럼 띄운 지킴이 하나: 파이프 넷 (claude의 stdin · stdout · stderr, 지킴이 보고)
    struct Kept {
        let pid: pid_t
        let disclaimed: Bool
        let stdinWrite: Int32
        let stdoutRead: Int32
        let reportRead: Int32
        let ended: URL

        /// 보고 한 줄 (기한 안에서)
        func nextReport(timeout: TimeInterval = 5) -> KeeperReport? {
            var line = Data()
            let deadline = Date().addingTimeInterval(timeout)
            var byte: UInt8 = 0
            while Date() < deadline {
                var item = pollfd(fd: reportRead, events: Int16(POLLIN), revents: 0)
                guard poll(&item, 1, 100) > 0 else { continue }
                guard read(reportRead, &byte, 1) == 1 else { return nil }
                if byte == 0x0A { return KeeperReport(line: String(decoding: line, as: UTF8.self)) }
                line.append(byte)
            }
            return nil
        }

        /// 끝날 때까지 기다려 거둔다 (기한을 넘기면 nil)
        func exitCode(timeout: TimeInterval) -> Int32? {
            let deadline = Date().addingTimeInterval(timeout)
            var status: Int32 = 0
            repeat {
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid { return (status & 0x7f) == 0 ? (status >> 8) & 0xff : -(status & 0x7f) }
                Thread.sleep(forTimeInterval: 0.05)
            } while Date() < deadline
            return nil
        }
    }

    func launch(_ command: [String], arguments override: [String]? = nil, disclaim: Bool = true) throws -> Kept {
        var input: [Int32] = [-1, -1]
        var output: [Int32] = [-1, -1]
        var errors: [Int32] = [-1, -1]
        var report: [Int32] = [-1, -1]
        #expect(pipe(&input) == 0 && pipe(&output) == 0 && pipe(&errors) == 0 && pipe(&report) == 0)
        for fd in input + output + errors + report { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        let ended = folder.appending(path: "\(UUID().uuidString).keeper")
        let arguments = override ?? (["--report-fd", "3", "--ended", ended.path, "--cwd", folder.path, "--"] + command)
        let spawned = try #require(AgentSpawn.spawn(
            executable: try Self.keeperURL().path, arguments: arguments, environment: ["PATH": "/usr/bin:/bin"], cwd: folder.path,
            fds: [(0, input[0]), (1, output[1]), (2, errors[1]), (3, report[1])], disclaim: disclaim
        ))
        close(input[0])
        close(output[1])
        close(errors[1])
        close(report[1])
        close(errors[0])
        return Kept(pid: spawned.pid, disclaimed: spawned.disclaimed, stdinWrite: input[1], stdoutRead: output[0], reportRead: report[0], ended: ended)
    }

    static func tag() -> String { "621.\(Int.random(in: 10000...99999))" }

    static func pids(matching tag: String) -> [pid_t] {
        (AgentProcesses.userPIDs() ?? []).filter { pid in
            var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
            var size = 0
            guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return false }
            var buffer = [UInt8](repeating: 0, count: size)
            guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return false }
            return String(decoding: buffer.prefix(size).map { $0 == 0 ? 0x20 : $0 }, as: UTF8.self).contains(tag)
        }
    }

    static func kill(matching tag: String) {
        for pid in pids(matching: tag) { Darwin.kill(pid, SIGKILL) }
    }

    // MARK: 1 구성원 0 → 정상 종료 · 끝 기록

    @Test func k1WithNoMembersLeftTheKeeperWritesItsRecordAndExitsNormally() throws {
        let kept = try launch(["/bin/sh", "sh", "-c", "echo hi; exit 7"])
        close(kept.stdinWrite)
        #expect(kept.disclaimed)
        guard case .started(let claudePID, let claudeID, let keeperID, let attributable)? = kept.nextReport() else {
            Issue.record("no started report")
            return
        }
        #expect(attributable && claudePID > 1 && claudeID > keeperID, "claude는 지킴이보다 뒤에 만들어졌다")
        #expect(kept.nextReport() == .exited(code: 7, signal: nil))
        #expect(kept.exitCode(timeout: 5) == KeeperMain.Exit.ended.rawValue)
        let record = try #require(KeeperRecord.read(kept.ended))
        #expect(record.keeperID == keeperID && record.boot == AgentProcesses.bootSessionID())
        let attributes = try FileManager.default.attributesOfItem(atPath: kept.ended.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        var buffer = [UInt8](repeating: 0, count: 16)
        #expect(read(kept.stdoutRead, &buffer, 16) == 3 && Array(buffer.prefix(3)) == Array("hi\n".utf8), "claude의 stdout은 앱 파이프로 그대로")
    }

    // MARK: 2 가짜 claude의 setsid 자손 · 뿌리가 먼저 끝남

    @Test func k2TheKeeperOutlivesClaudeWhileASetsidChildLivesAndEndsAfterIt() throws {
        let tag = Self.tag()
        defer { Self.kill(matching: tag) }
        let kept = try launch(["/bin/sh", "sh", "-c", "/usr/bin/perl -e 'use POSIX; POSIX::setsid(); sleep 600;' \(tag) </dev/null >/dev/null 2>&1 & exit 0"])
        close(kept.stdinWrite)
        guard case .started(_, _, let keeperID, true)? = kept.nextReport() else {
            Issue.record("no started report")
            return
        }
        #expect(kept.nextReport() == .exited(code: 0, signal: nil), "뿌리가 먼저 끝났다")
        // 지킴이 자신도 인자에 태그가 있다 (그것을 자손으로 집지 않는다)
        let child = try #require(Self.pids(matching: tag).first { $0 != kept.pid })
        #expect(getpgid(child) == child, "세션을 떠났다")
        #expect(kept.exitCode(timeout: 1) == nil, "구성원이 살아 있는 동안 지킴이는 산다")
        // 다른 시험이 띄운 짧은 프로세스가 목록과 조회 사이에 사라지면 그 훑기는 불완전이다 (14장 6): 완전한 훑기 하나를 기한 안에서 찾는다
        // (시험 전체가 함께 돌면 짧은 프로세스가 많아 몇 초 걸릴 수 있다)
        var scan = try #require(KeeperMembers.scan(keeperPID: kept.pid, keeperID: keeperID))
        let deadline = Date().addingTimeInterval(15)
        while !scan.complete, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
            scan = try #require(KeeperMembers.scan(keeperPID: kept.pid, keeperID: keeperID))
        }
        #expect(scan.complete && scan.members.map(\.pid) == [child])
        #expect(!FileManager.default.fileExists(atPath: kept.ended.path))
        Darwin.kill(child, SIGKILL)
        #expect(kept.exitCode(timeout: 5) == KeeperMain.Exit.ended.rawValue)
        #expect(KeeperRecord.read(kept.ended)?.keeperID == keeperID)
    }

    // MARK: 3 못 본 짧은 중간 프로세스 (12-1의 틈)

    @Test func k3ASetsidGrandchildOfAnEndedIntermediateIsStillAMember() throws {
        let tag = Self.tag()
        defer { Self.kill(matching: tag) }
        let kept = try launch(["/bin/sh", "sh", "-c", "/bin/sh -c \"/usr/bin/perl -e 'use POSIX; POSIX::setsid(); sleep 600;' \(tag) </dev/null >/dev/null 2>&1 &\"; exit 0"])
        close(kept.stdinWrite)
        guard case .started(_, _, let keeperID, true)? = kept.nextReport() else {
            Issue.record("no started report")
            return
        }
        #expect(kept.nextReport() == .exited(code: 0, signal: nil))
        Thread.sleep(forTimeInterval: 0.3)
        let child = try #require(Self.pids(matching: tag).first { $0 != kept.pid })
        #expect(KeeperMembers.scan(keeperPID: kept.pid, keeperID: keeperID)?.members.map(\.pid) == [child], "중간 sh도 뿌리도 끝났지만 책임 프로세스는 지킴이 그대로")
        #expect(kept.exitCode(timeout: 0.6) == nil)
        Darwin.kill(child, SIGKILL)
        #expect(kept.exitCode(timeout: 5) == KeeperMain.Exit.ended.rawValue)
    }

    // MARK: 4 띄우기 실패

    /// 띄우지 못한 것도 알리고, 앱이 끝을 알 수 있게 구성원 0을 증명한 뒤 기록을 쓰고 0으로 끝난다 (14장 1: 앱은 지킴이의 0 종료로만 끝을 안다)
    @Test func k4AClaudeThatCannotBeSpawnedIsReportedAndTheKeeperStillProvesTheEnd() throws {
        let kept = try launch(["/nonexistent/claude", "claude", "-p"])
        close(kept.stdinWrite)
        #expect(kept.nextReport() == .failed)
        #expect(kept.exitCode(timeout: 5) == KeeperMain.Exit.ended.rawValue)
        #expect(KeeperRecord.read(kept.ended) != nil)
    }

    // MARK: 5 stdio

    /// claude가 끝나면 앱의 stdout은 EOF다 (지킴이는 자기 0 · 1 · 2를 내려놓았다). claude는 표준 셋 밖의 fd를 받지 않는다 (보고 fd 0)
    @Test func k5TheAppSeesEOFWhenClaudeEndsAndClaudeGetsOnlyTheStandardStreams() throws {
        let pidFile = folder.appending(path: "sleep.pid").path
        let probe = "for fd in 3 4 5 6 7 8 9; do if [ -e /dev/fd/$fd ]; then echo $fd; fi; done"
        let kept = try launch(["/bin/sh", "sh", "-c", "\(probe); read line; echo \"got $line\"; /bin/sleep 600 </dev/null >/dev/null 2>&1 & echo $! > '\(pidFile)'; exit 0"])
        _ = HookMain.writeAll(fd: kept.stdinWrite, Data("ping\n".utf8))
        close(kept.stdinWrite)
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let count = read(kept.stdoutRead, &buffer, buffer.count)
            if count <= 0 { break }
            output.append(contentsOf: buffer[0..<count])
        }
        let text = String(decoding: output, as: UTF8.self)
        #expect(text.hasSuffix("got ping\n"))
        #expect(text == "got ping\n", "표준 셋 밖의 fd 0 (보고 fd 3도 claude에 가지 않는다): \(text)")
        let sleeper = try #require(Int32((try? String(contentsOfFile: pidFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))
        defer { Darwin.kill(sleeper, SIGKILL) }
        #expect(kept.exitCode(timeout: 0.3) == nil, "sleep이 살아 있는 동안 지킴이는 산다")
        Darwin.kill(sleeper, SIGKILL)
        #expect(kept.exitCode(timeout: 5) == KeeperMain.Exit.ended.rawValue)
    }

    // MARK: 4 물러남 (13장 5)

    /// disclaim 없이 띄운 지킴이는 자기 책임 프로세스가 아니다: 구성원을 증명할 수 없다 → `claude`가 끝나면 기록 없이 4로 끝난다 (앱은 unknown)
    @Test func k4AKeeperThatIsNotItsOwnResponsibleProcessNeverClaimsTheEnd() throws {
        let kept = try launch(["/bin/sh", "sh", "-c", "exit 0"], disclaim: false)
        close(kept.stdinWrite)
        #expect(!kept.disclaimed)
        guard case .started(_, _, _, false)? = kept.nextReport() else {
            Issue.record("expected an unattributable start")
            return
        }
        #expect(kept.nextReport() == .exited(code: 0, signal: nil))
        #expect(kept.exitCode(timeout: 5) == KeeperMain.Exit.unprovable.rawValue)
        #expect(!FileManager.default.fileExists(atPath: kept.ended.path))
    }

    // MARK: 6 인자

    @Test func k6AMalformedInvocationSpawnsNothing() throws {
        for arguments in [[], ["--report-fd", "3", "--ended", "/tmp/x", "--cwd", "/tmp"], ["--report-fd", "1", "--ended", "/tmp/x", "--cwd", "/tmp", "--", "/bin/sh", "sh"],
                          ["--report-fd", "3", "--ended", "relative", "--cwd", "/tmp", "--", "/bin/sh", "sh"], ["--report-fd", "3", "--ended", "/tmp/x", "--cwd", "/tmp", "--", "sh"]] {
            #expect(KeeperMain.parse(arguments) == nil, "\(arguments)")
        }
        let kept = try launch([], arguments: ["--bogus"])
        close(kept.stdinWrite)
        #expect(kept.exitCode(timeout: 5) == KeeperMain.Exit.usage.rawValue)
    }

    // MARK: 7 훑기 3상태

    @Test func k7AFailedLookupIsNeverReadAsGoneAndAMissingKeeperAttributesNothing() throws {
        let me = getpid()
        guard case .present(let own) = AgentProcesses.generation(pid: me) else {
            Issue.record("own generation")
            return
        }
        // 이 시험 프로세스를 지킴이로 친다: 그 뒤에 띄운 sleep의 책임 프로세스를 이 프로세스로 돌려주는 조회
        let sleeper = try #require(AgentSpawn.spawn(executable: "/bin/sleep", arguments: ["30"], environment: [:], cwd: "/", fds: [], disclaim: false))
        defer {
            Darwin.kill(sleeper.pid, SIGKILL)
            var status: Int32 = 0
            waitpid(sleeper.pid, &status, 0)
        }
        let target = sleeper.pid
        var lookups = KeeperMembers.Lookups.live
        lookups.responsibleUniqueID = { $0 == target ? .present(own.own) : .gone }
        #expect(KeeperMembers.scan(keeperPID: me, keeperID: own.own, lookups: lookups)?.members.map(\.pid) == [target])
        var failing = lookups
        failing.generation = { $0 == target ? .failed : AgentProcesses.generation(pid: $0) }
        #expect(KeeperMembers.scan(keeperPID: me, keeperID: own.own, lookups: failing)?.complete == false, "세대 조회 실패")
        failing = lookups
        failing.responsibleUniqueID = { $0 == target ? .failed : .gone }
        #expect(KeeperMembers.scan(keeperPID: me, keeperID: own.own, lookups: failing)?.complete == false, "책임 조회 실패")
        // unique id 변형이 없으면 pid로
        failing = lookups
        failing.responsibleUniqueID = nil
        failing.responsiblePID = { $0 == target ? .present(me) : .gone }
        #expect(KeeperMembers.scan(keeperPID: me, keeperID: own.own, lookups: failing)?.members.map(\.pid) == [target])
        failing.responsiblePID = { $0 == target ? .failed : .gone }
        #expect(KeeperMembers.scan(keeperPID: me, keeperID: own.own, lookups: failing)?.complete == false)
        // 지킴이 pid의 지금 세대가 지킴이 id가 아니면 가르지 않는다
        #expect(KeeperMembers.scan(keeperPID: me, keeperID: own.own + 1, lookups: lookups) == nil)
        failing = lookups
        failing.listing = { nil }
        #expect(KeeperMembers.scan(keeperPID: me, keeperID: own.own, lookups: failing) == nil, "목록을 읽지 못함")
    }

    // MARK: 8 기록 · 보고 형식

    @Test func k8TheRecordAndTheReportLinesHaveOneShape() throws {
        let url = folder.appending(path: "r.keeper")
        let boot = UUID().uuidString
        #expect(KeeperRecord.write(url, keeperID: 42, boot: boot))
        #expect(try String(contentsOf: url, encoding: .utf8) == "taskforce-keeper 1\nboot \(boot)\nkeeper 42\nended\n")
        #expect(KeeperRecord.read(url)?.keeperID == 42)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["r.keeper"], "임시 파일이 남지 않는다")
        for broken in [
            "taskforce-keeper 1\nboot \(boot)\nkeeper 42\nended", "taskforce-keeper 1\nboot \(boot)\nkeeper 42\nended\nended", "taskforce-keeper 1\nboot x\nkeeper 42\nended\n",
            "taskforce-keeper 1\nboot \(boot)\nkeeper 1\nended\n", "nonsense\n",
        ] {
            try broken.write(to: url, atomically: true, encoding: .utf8)
            #expect(KeeperRecord.read(url) == nil, "\(broken)")
        }
        for report in [KeeperReport.started(claudePID: 77, claudeID: 9001, keeperID: 9000, attributable: true), .failed, .exited(code: 1, signal: nil), .exited(code: nil, signal: 9)] {
            #expect(KeeperReport(line: report.line) == report)
        }
        for line in ["started 1 2 3 1", "started 77 9001 9000 2", "exited", "exited x -", "bogus"] { #expect(KeeperReport(line: line) == nil, "\(line)") }
    }
}
#endif
