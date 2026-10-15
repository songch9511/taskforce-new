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
}
#endif
