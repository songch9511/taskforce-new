#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import TaskforceKit

/// probe 새로 고침의 adapter 쪽 (OA Settings › Your agents 8장 · SA-06): `refreshProbe()`는 로그인 캐시(5분)만 비운다. 버전은 실행 파일이 같으면 그대로다.
/// 실제 `claude`는 띄우지 않는다: 명령 실행기는 가짜 대본이고 실행 파일은 임시 폴더의 빈 파일이다
struct AgentSettingsProbeTests {
    final class Script: @unchecked Sendable {
        let calls = Mutex<[String]>([])
        let loggedIn = Mutex(true)

        var runner: ClaudeCommandRunner {
            { [self] _, arguments, _ in
                let key = arguments.joined(separator: " ")
                calls.withLock { $0.append(key) }
                if key == "--version" { return ClaudeCommandOutput(exitCode: 0, stdout: Data("2.1.241 (Claude Code)\n".utf8)) }
                return ClaudeCommandOutput(exitCode: 0, stdout: Data(#"{"loggedIn":\#(loggedIn.withLock { $0 })}"#.utf8))
            }
        }

        func count(_ key: String) -> Int { calls.withLock { $0.filter { $0 == key }.count } }
    }

    private func process(_ script: Script, box: ClaudeSandbox) -> ClaudeCodeProcess {
        let claude = box.home.appending(path: ".local/bin/claude")
        try? FileManager.default.createDirectory(at: claude.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("#!/bin/sh\n".utf8).write(to: claude)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        return ClaudeCodeProcess(
            sessionsRoot: box.sessionsRoot, hookServer: nil, helpers: ClaudeCodeHelpers(hook: "/x", mcp: "/y", keeper: "/z"),
            locator: ClaudeCodeLocator(candidates: [claude.path], confinedTo: box.root.path), environment: ["HOME": box.home.path, "PATH": "/usr/bin:/bin"],
            managedSettingsPath: box.root.appending(path: "managed-settings.json").path, runner: script.runner
        )
    }

    @Test func refreshProbeMakesTheNextProbeAskTheLoginAgainButNotTheVersion() async {
        let box = ClaudeSandbox()
        let script = Script()
        let adapter = process(script, box: box)
        let first = await adapter.probe()
        #expect(first.signedIn == .yes && first.version == "2.1.241")
        // Terminal에서 로그아웃했다: 캐시(5분) 안에서는 낡은 값이 그대로다
        script.loggedIn.withLock { $0 = false }
        #expect(await adapter.probe().signedIn == .yes, "5분 캐시가 낡은 말을 보인다 (그래서 새로 고침이 있다)")
        await adapter.refreshProbe()
        let refreshed = await adapter.probe()
        #expect(refreshed.signedIn == .no, "새로 고침 뒤에는 다시 묻는다")
        #expect(script.count("auth status") == 2 && script.count("--version") == 1, "버전은 실행 파일이 같으면 다시 묻지 않는다")
    }

    @Test func refreshProbeNeverReadsAnythingButTheLoggedInFlag() async {
        let box = ClaudeSandbox()
        let script = Script()
        let adapter = process(script, box: box)
        await adapter.refreshProbe()
        let report = await adapter.probe()
        let sent = String(decoding: (try? TaskforceJSON.encoder().encode(report)) ?? Data(), as: UTF8.self)
        #expect(!sent.contains("email") && !sent.contains("authMethod") && !sent.contains("orgName"), "자격 · 계정 이메일 · authMethod는 읽지도 보이지도 않는다 (I16)")
    }

    @Test func theDefaultRefreshProbeDoesNothing() async {
        let fake = FakeAgentProcess()
        await fake.refreshProbe()
        #expect(await fake.probe().signedIn == .yes)
    }
}
#endif
