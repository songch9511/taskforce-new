#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import TaskforceKit

/// 버전 · 로그인 · managed settings (OA D3a 계약 2.15 · 4.1, G21 · G22). 자격 값은 읽지 않는다 (I16): `auth status`에서 `loggedIn`만 본다
struct ClaudeCodeProbeTests {
    let box = ClaudeSandbox()

    final class Runner: @unchecked Sendable {
        let calls = Shared<[[String]]>([])
        let replies: Shared<[String: ClaudeCommandOutput?]>

        init(version: String? = "2.1.241 (Claude Code)\n", auth: String? = #"{"loggedIn":true,"authMethod":"claude.ai","email":"someone@example.com","orgName":"Org"}"#) {
            replies = Shared([
                "--version": version.map { ClaudeCommandOutput(exitCode: 0, stdout: Data($0.utf8)) },
                "auth status": auth.map { ClaudeCommandOutput(exitCode: 0, stdout: Data($0.utf8)) },
            ])
        }

        func set(_ key: String, _ text: String?) {
            replies.mutate { $0[key] = text.map { ClaudeCommandOutput(exitCode: 0, stdout: Data($0.utf8)) } }
        }

        var function: ClaudeCommandRunner {
            { [self] _, arguments, _ in
                calls.mutate { $0.append(arguments) }
                return replies.mutate { $0[arguments.joined(separator: " ")] ?? nil }
            }
        }

        func count(_ key: String) -> Int { calls.value.filter { $0.joined(separator: " ") == key }.count }
    }

    func installClaude() -> URL {
        let url = box.home.appending(path: ".local/bin/claude")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("#!/bin/sh\n".utf8).write(to: url)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func probe(_ runner: Runner, managed: String? = nil, now: @escaping @Sendable () -> Date = { Date() }, installed: Bool = true) -> ClaudeCodeProbe {
        let claude = installed ? installClaude() : box.home.appending(path: ".local/bin/claude")
        return ClaudeCodeProbe(
            locator: ClaudeCodeLocator(candidates: [claude.path], confinedTo: box.root.path), runner: runner.function,
            managedSettingsPath: managed ?? box.root.appending(path: "managed-settings.json").path, now: now
        )
    }

    // MARK: 버전

    @Test func theVersionIsTheFirstWordWhenItIsThreeNumbers() {
        #expect(ClaudeCodeProbe.parseVersion(Data("2.1.241 (Claude Code)\n".utf8)) == "2.1.241")
        #expect(ClaudeCodeProbe.parseVersion(Data("2.2.0\n".utf8)) == "2.2.0")
        for bad in ["v2.1.241", "2.1", "abc", "", "2.1.241-beta", " \n"] {
            #expect(ClaudeCodeProbe.parseVersion(Data(bad.utf8)) == nil, "\(bad)")
        }
    }

    @Test func theSupportedRangeIsAtLeast2_1_241AndBelow2_2() {
        #expect(ClaudeCodeSupport.versionRange == ">=2.1.241 <2.2")
        for ok in ["2.1.241", "2.1.242", "2.1.1000"] { #expect(ClaudeCodeSupport.supports(ok), "\(ok)") }
        for bad in ["2.1.240", "2.2.0", "3.0.0", "1.9.999", "2.1", "x", nil] as [String?] { #expect(!ClaudeCodeSupport.supports(bad), "\(String(describing: bad))") }
    }

    // MARK: 로그인 (`loggedIn`만)

    @Test func loginReadsOnlyLoggedIn() {
        #expect(ClaudeCodeProbe.parseLoggedIn(Data(#"{"loggedIn":true,"email":"a@b.c"}"#.utf8)) == .yes)
        #expect(ClaudeCodeProbe.parseLoggedIn(Data(#"{"loggedIn":false}"#.utf8)) == .no)
        for bad in ["{", "", #"{"loggedIn":"true"}"#, #"{"status":"ok"}"#, "[true]"] {
            #expect(ClaudeCodeProbe.parseLoggedIn(Data(bad.utf8)) == .unknown, "\(bad)")
        }
    }

    @Test func aReportIsInstalledVersionLoginAndManagedSettings() async {
        let runner = Runner()
        let report = await probe(runner).report()
        #expect(report == BridgeV1AdapterReport(adapter: "agent:claude-code", installed: true, version: "2.1.241", signedIn: .yes, managedSettings: false))
        let encoded = String(decoding: (try? TaskforceJSON.encoder().encode(report)) ?? Data(), as: UTF8.self)
        #expect(!encoded.contains("example.com") && !encoded.contains("Org"))
    }

    @Test func notInstalledSkipsTheCommands() async {
        let runner = Runner()
        let report = await probe(runner, installed: false).report()
        #expect(report == BridgeV1AdapterReport(adapter: "agent:claude-code", installed: false, version: nil, signedIn: .unknown, managedSettings: false))
        #expect(runner.calls.value.isEmpty)
    }

    @Test func aTimeoutOrBrokenAnswerIsUnknownNotNo() async {
        let report = await probe(Runner(version: nil, auth: nil)).report()
        #expect(report.version == nil)
        #expect(report.signedIn == .unknown)
        #expect(report.installed)
    }

    @Test func aManagedSettingsFileMarksTheReport() async {
        let managed = box.root.appending(path: "Library/Application Support/ClaudeCode/managed-settings.json")
        try? FileManager.default.createDirectory(at: managed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("{}".utf8).write(to: managed)
        #expect(await probe(Runner(), managed: managed.path).report().managedSettings)
    }

    // MARK: 캐시 (Q10)

    @Test func theVersionIsCachedUntilTheExecutableChanges() async throws {
        let runner = Runner()
        let probe = probe(runner)
        _ = await probe.report()
        _ = await probe.report()
        #expect(runner.count("--version") == 1)
        let claude = box.home.appending(path: ".local/bin/claude")
        try Data("#!/bin/sh\n# updated\n".utf8).write(to: claude)
        runner.set("--version", "2.1.250 (Claude Code)")
        #expect(await probe.report().version == "2.1.250")
        #expect(runner.count("--version") == 2)
    }

    @Test func loginIsCachedForFiveMinutesAndDroppedAfterSignInNeeded() async {
        let runner = Runner()
        let clock = Shared(Date(timeIntervalSince1970: 1_000_000))
        let probe = probe(runner, now: { clock.value })
        _ = await probe.report()
        clock.mutate { $0 = $0.addingTimeInterval(299) }
        _ = await probe.report()
        #expect(runner.count("auth status") == 1)
        clock.mutate { $0 = $0.addingTimeInterval(2) }
        _ = await probe.report()
        #expect(runner.count("auth status") == 2)
        runner.set("auth status", #"{"loggedIn":false}"#)
        await probe.invalidateLogin()
        #expect(await probe.report().signedIn == .no)
        #expect(runner.count("auth status") == 3)
    }

    // MARK: 실제 프로세스 (가짜 claude): 표준 출력을 닫고도 끝나지 않는 자식 (보안 검토 P2)

    /// 임시 폴더의 가짜 `claude`
    private func fakeClaude(_ body: String) throws -> ClaudeCodeExecutable {
        let url = box.root.appending(path: "bin/claude")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return ClaudeCodeExecutable(path: url.path, realPath: url.path, directory: url.deletingLastPathComponent().path)
    }

    private final class RunResult: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: ClaudeCommandOutput??
        func set(_ value: ClaudeCommandOutput?) { lock.withLock { stored = .some(value) } }
        var value: ClaudeCommandOutput?? { lock.withLock { stored } }
    }

    /// 막힘이 곧 실패로 드러나게 다른 스레드에서 돌리고 기다림에 상한을 둔다 (막히는 코드가 시험 전체를 멈추지 않는다)
    private func runBounded(_ executable: ClaudeCodeExecutable, timeout: TimeInterval, within: TimeInterval) -> (finished: Bool, output: ClaudeCommandOutput?, seconds: TimeInterval) {
        let result = RunResult()
        let done = DispatchSemaphore(value: 0)
        let cwd = box.workspace.path
        let started = Date()
        DispatchQueue.global().async {
            result.set(ClaudeCodeProbe.run(executable: executable, arguments: ["x"], environment: ["PATH": "/usr/bin:/bin"], cwd: cwd, timeout: timeout))
            done.signal()
        }
        let finished = done.wait(timeout: .now() + within) == .success
        return (finished, result.value ?? nil, Date().timeIntervalSince(started))
    }

    @Test func aChildThatClosesStdoutButNeverExitsIsStoppedAtTheDeadlineAndReaped() throws {
        let pidFile = box.root.appending(path: "pid.txt").path
        let executable = try fakeClaude("echo $$ > '\(pidFile)'\nexec 1>&-\nsleep 30")
        // 새로 쓴 스크립트의 첫 실행은 시스템 검사로 느릴 수 있다: 기한은 그 위에 넉넉히 (자식이 pid를 적고 표준 출력을 닫을 때까지)
        let run = runBounded(executable, timeout: 2, within: 10)
        #expect(run.finished, "표준 출력이 닫혔다고 끝나기를 끝없이 기다리지 않는다")
        #expect(run.output == nil, "기한을 넘기면 답이 아니다")
        #expect(run.seconds < 6, "자식은 30초 잠들어 있다: 기한(2초) 근처에서 돌아온다")
        guard run.finished, let pid = (try? String(contentsOfFile: pidFile, encoding: .utf8)).flatMap({ Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }), pid > 1 else {
            Issue.record("자식의 pid를 읽지 못했다: finished=\(run.finished) file=\((try? String(contentsOfFile: pidFile, encoding: .utf8)) ?? "nil")")
            return
        }
        // 죽이고 거뒀다: 좀비도 남지 않는다 (거둔 자식에게 신호 0은 ESRCH)
        var gone = false
        for _ in 0..<100 {
            if kill(pid, 0) != 0, errno == ESRCH {
                gone = true
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(gone)
    }

    @Test func theRunnerKeepsExactlyTheFirst64KiBOfALongAnswer() throws {
        // `claude agents --json`의 읽는 쪽 상한(64 KiB)과 같아야 한다: 읽은 덩어리째 붙여 64 KiB를 넘기지 않는다
        // 10007바이트씩 열두 번(약 120 KB): 읽은 덩어리째 붙이면 64 KiB 경계를 넘겨 담는다 (덩어리 크기가 64 KiB를 나누어떨어지지 않는다)
        let executable = try fakeClaude("i=0; while [ $i -lt 12 ]; do head -c 10007 /dev/zero | tr '\\0' 'a'; sleep 0.03; i=$((i+1)); done")
        let run = runBounded(executable, timeout: 5, within: 10)
        #expect(run.finished)
        #expect(run.output?.exitCode == 0)
        #expect(run.output?.stdout.count == 64 * 1024)
    }

    @Test func aChildThatClosesStdoutAndExitsRightAwayKeepsItsAnswerWithoutWaitingForTheDeadline() throws {
        let executable = try fakeClaude("printf '[]'\nexec 1>&-\nexit 0")
        let run = runBounded(executable, timeout: 5, within: 8)
        #expect(run.finished)
        #expect(run.output == ClaudeCommandOutput(exitCode: 0, stdout: Data("[]".utf8)))
        #expect(run.seconds < 2.5, "곧 끝난 자식은 기한까지 기다리지 않는다")
    }
}
#endif
