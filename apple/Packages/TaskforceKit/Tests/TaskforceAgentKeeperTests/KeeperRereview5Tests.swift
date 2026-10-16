#if os(macOS)
import Darwin
import Foundation
import Security
import Testing
@testable import TaskforceAgentWire

/// 재검토 5 재현 (OA D3a 14장 3 · 10 · 12): 실제로 빌드한 `tf-agent-keeper`를 앱처럼 disclaim해서 띄운다. 실제 `claude` 실행 0 (가짜 = `/bin/sh` · `/usr/bin/env` · `touch`).
/// `kN`: 9 SIGTERM 창, 10 `claude` 환경 다섯 키, 11 부른 쪽 확인
@Suite(.serialized)
struct KeeperRereview5Tests {
    let folder: URL

    init() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "tf-keeper5-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    struct Kept {
        let pid: pid_t
        let stdinWrite: Int32
        let stdoutRead: Int32
        let reportRead: Int32
        let ended: URL

        func exitCode(timeout: TimeInterval) -> Int32? {
            let deadline = Date().addingTimeInterval(timeout)
            var status: Int32 = 0
            repeat {
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid { return (status & 0x7f) == 0 ? (status >> 8) & 0xff : -(status & 0x7f) }
                Thread.sleep(forTimeInterval: 0.02)
            } while Date() < deadline
            return nil
        }

        /// 보고 fd에 온 것 (기한 안에서, EOF까지)
        func report(timeout: TimeInterval) -> String {
            var data = Data()
            var byte: UInt8 = 0
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                var item = pollfd(fd: reportRead, events: Int16(POLLIN), revents: 0)
                guard poll(&item, 1, 50) > 0 else { continue }
                guard read(reportRead, &byte, 1) == 1 else { break }
                data.append(byte)
            }
            return String(decoding: data, as: UTF8.self)
        }

        func output() -> String {
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(stdoutRead, &buffer, buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer[0..<count])
            }
            return String(decoding: data, as: UTF8.self)
        }

        /// 막히는 기다림은 협력 스레드 밖에서 (`KeeperTests.blocking`): 같은 시험 프로세스의 다른 시험을 굶기지 않는다
        func exited(within seconds: TimeInterval = KeeperTests.proofCeiling) async -> Int32? {
            let me = self
            return await KeeperTests.blocking { me.exitCode(timeout: seconds) }
        }

        func reported(within seconds: TimeInterval) async -> String {
            let me = self
            return await KeeperTests.blocking { me.report(timeout: seconds) }
        }

        func allOutput() async -> String {
            let me = self
            return await KeeperTests.blocking { me.output() }
        }

        /// stdin 말고 남은 둘을 닫는다 (stdin은 시험이 한 번만 닫는다: 두 번 닫으면 같은 프로세스에서 도는 다른 시험의 fd를 닫을 수 있다)
        func closeOutputs() {
            close(stdoutRead)
            close(reportRead)
        }
    }

    /// 앱처럼 띄운다 (disclaim · 파이프 넷). `executable`이 지킴이가 아니면(셸을 거쳐 지킴이를 exec) 그 인자를 그대로
    func launch(_ command: [String], environment: [String: String] = ["PATH": "/usr/bin:/bin"], through shell: String? = nil) throws -> Kept {
        var input: [Int32] = [-1, -1]
        var output: [Int32] = [-1, -1]
        var errors: [Int32] = [-1, -1]
        var report: [Int32] = [-1, -1]
        #expect(pipe(&input) == 0 && pipe(&output) == 0 && pipe(&errors) == 0 && pipe(&report) == 0)
        for fd in input + output + errors + report { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        let ended = folder.appending(path: "\(UUID().uuidString).keeper")
        let keeper = try KeeperTests.keeperURL().path
        let keeperArguments = ["--report-fd", "3", "--ended", ended.path, "--cwd", folder.path, "--"] + command
        let executable = shell == nil ? keeper : "/bin/sh"
        let arguments = shell.map { ["-c", $0, keeper] + keeperArguments } ?? keeperArguments
        let fds: [(child: Int32, parent: Int32)] = [(0, input[0]), (1, output[1]), (2, errors[1]), (3, report[1])]
        let spawned = try #require(AgentSpawn.spawn(executable: executable, arguments: arguments, environment: environment, cwd: folder.path, fds: fds, disclaim: true))
        close(input[0])
        close(output[1])
        close(errors[1])
        close(report[1])
        close(errors[0])
        return Kept(pid: spawned.pid, stdinWrite: input[1], stdoutRead: output[0], reportRead: report[0], ended: ended)
    }

    static func children(of pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 64)
        let count = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        return count > 0 ? Array(buffer.prefix(Int(count)).filter { $0 > 0 }) : []
    }

    // MARK: 9 SIGTERM 창 (sec P3-4)

    /// 지킴이가 `claude`를 띄운 바로 그 순간(자식이 보이자마자)의 SIGTERM: 처리기가 생기기 전의 창이다. 지킴이는 그래도 `claude`를 끝내고 구성원 0을 증명하고 0으로 끝난다
    @Test func k9ASigtermRightAfterTheSpawnNeverOrphansClaude() async throws {
        var orphans = 0
        var unproven = 0
        var neverSpawned = 0
        for _ in 0..<12 {
            let tag = KeeperTests.tag()
            let kept = try launch(["/bin/sh", "sh", "-c", "exec /bin/sleep \(tag)"])
            // 자식이 보이는 그 순간을 기다려 바로 SIGTERM (포기 상한만, 코어를 다 쓰지 않게 잠깐씩 양보, 협력 스레드 밖에서). 끝내 보이지 않으면 SIGTERM을 보내지 않는다:
            // 띄우기 전의 SIGTERM은 이 시험이 보는 창이 아니다
            let keeperPID = kept.pid
            let signalled = await KeeperTests.blocking { () -> Bool in
                let deadline = Date().addingTimeInterval(KeeperTests.proofCeiling)
                while Date() < deadline, Self.children(of: keeperPID).isEmpty { usleep(200) }
                guard !Self.children(of: keeperPID).isEmpty else { return false }
                kill(keeperPID, SIGTERM)
                return true
            }
            guard signalled else {
                neverSpawned += 1
                kill(kept.pid, SIGKILL)
                _ = await kept.exited()
                close(kept.stdinWrite)
                kept.closeOutputs()
                continue
            }
            // 시험 전체가 함께 돌면 짧은 프로세스가 많아 증명이 늦을 수 있다(포기 상한). 지킴이 자신(인자에 태그가 있다)은 고아로 세지 않는다.
            // 지킴이는 claude를 거둔 뒤에 끝나므로, 끝난 뒤 남은 태그 프로세스가 고아다
            let code = await kept.exited()
            if !KeeperTests.pids(matching: tag).filter({ $0 != kept.pid }).isEmpty { orphans += 1 }
            if code != 0 { unproven += 1 }
            KeeperTests.kill(matching: tag)
            if code == nil {
                kill(kept.pid, SIGKILL)
                _ = await kept.exited()
            }
            close(kept.stdinWrite)
            kept.closeOutputs()
            // 한 번이라도 남겼거나 끝을 증명하지 못했으면 이미 실패다: 남은 회차를 포기 상한까지 기다리지 않는다
            if orphans > 0 || unproven > 0 { break }
        }
        #expect(neverSpawned == 0, "지킴이가 claude를 띄웠다 (시험 전제)")
        #expect(orphans == 0, "SIGTERM이 처리기보다 먼저 와도 claude를 남기지 않는다")
        #expect(unproven == 0, "SIGTERM 뒤에도 지킴이는 구성원 0을 증명하고 0으로 끝난다")
    }

    // MARK: 10 claude 환경 (sec P3-6)

    /// 지킴이는 앱이 준 환경에서 다섯 키만 명시해서 넘긴다: 그 밖의 값 · 지킴이 자신이 더한 값(`__CF_USER_TEXT_ENCODING`)은 넘기지 않는다
    @Test func k10ClaudeGetsExactlyTheFiveKeys() async throws {
        let environment = [
            "HOME": folder.path, "USER": "u", "LANG": "en_US.UTF-8", "PATH": "/usr/bin:/bin", "TASKFORCE_SPAWN_ID": UUID().uuidString,
            "ANTHROPIC_API_KEY": "sk-ant-canary", "CLAUDE_CODE_OAUTH_TOKEN": "canary", "NODE_OPTIONS": "--require /tmp/x",
        ]
        let kept = try launch(["/usr/bin/env", "env"], environment: environment)
        close(kept.stdinWrite)
        let keys = await kept.allOutput().split(separator: "\n").map { String($0.prefix { $0 != "=" }) }.sorted()
        #expect(keys == ["HOME", "LANG", "PATH", "TASKFORCE_SPAWN_ID", "USER"])
        #expect(await kept.exited() == 0)
        kept.closeOutputs()
    }

    // MARK: 11 부른 쪽 확인 (sec 기준 밖, 14장 12)

    /// 시험 프로세스 자신의 서명 identifier
    static func ownIdentifier() -> String? {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var code: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess, let values = info as? [String: Any] else { return nil }
        return values[kSecCodeInfoIdentifier as String] as? String
    }

    @Test func k11AKeeperWhoseParentFailsTheRequirementSpawnsNothing() async throws {
        let marker = folder.appending(path: "ran")
        let kept = try launch(["/usr/bin/touch", "touch", marker.path], environment: ["PATH": "/usr/bin:/bin", "TF_KEEPER_CALLER_REQUIREMENT": "identifier \"dev.taskforcelabs.not-this-host\""])
        close(kept.stdinWrite)
        #expect(await kept.exited() == 6, "부모가 요구사항을 만족하지 않으면 6")
        #expect(await kept.reported(within: 0.3).isEmpty, "보고 0")
        #expect(!FileManager.default.fileExists(atPath: marker.path), "claude를 띄우지 않았다")
        kept.closeOutputs()
    }

    @Test func k11AKeeperWhoseParentSatisfiesTheRequirementRuns() async throws {
        let identifier = try #require(Self.ownIdentifier())
        let marker = folder.appending(path: "ran")
        let kept = try launch(["/usr/bin/touch", "touch", marker.path], environment: ["PATH": "/usr/bin:/bin", "TF_KEEPER_CALLER_REQUIREMENT": "identifier \"\(identifier)\""])
        close(kept.stdinWrite)
        #expect(await kept.exited() == 0)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        kept.closeOutputs()
    }

    /// 부모가 먼저 끝나 launchd(1)의 자식이 된 지킴이는 아무것도 띄우지 않는다
    @Test func k11AnOrphanedKeeperSpawnsNothing() async throws {
        let marker = folder.appending(path: "ran-orphan")
        // 셸이 끝나 launchd(1) 밑으로 옮겨진 것을 본 뒤에 지킴이를 exec한다 (0.5초 기다리기 대신 그 사건으로)
        let gate = "(exec /usr/bin/perl -e 'select(undef, undef, undef, 0.01) while getppid() != 1; exec @ARGV or exit 127' \"$0\" \"$@\") & exit 0"
        let kept = try launch(["/usr/bin/touch", "touch", marker.path], through: gate)
        close(kept.stdinWrite)
        #expect(await kept.exited() == 0, "셸은 바로 끝난다")
        // 보고 fd를 마지막으로 쥔 것은 지킴이다: EOF = 지킴이가 끝났다 (2초 기다리기 대신, 포기 상한만)
        _ = await kept.reported(within: KeeperTests.proofCeiling)
        #expect(!FileManager.default.fileExists(atPath: marker.path), "ppid 1이면 claude를 띄우지 않는다")
        #expect(!FileManager.default.fileExists(atPath: kept.ended.path))
        kept.closeOutputs()
    }
}
#endif
