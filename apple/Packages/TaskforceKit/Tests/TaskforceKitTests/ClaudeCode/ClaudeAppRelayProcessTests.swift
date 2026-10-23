#if os(macOS) && DEBUG
import Darwin
import Foundation
import Testing
@testable import TaskforceKit

/// 실제 지킴이 + 가짜 `claude`(셸 스크립트)로 본 중계 띄우기 (PR-D3k, 계약 25.4.1 · 위협 DT4 · DT6 · DT13): 인자 바이트 · 환경 · 글이 stdin으로만 가는 것 · 끝내면 프로세스가 사라지는 것.
/// 이름이 `Claude…`로 시작해 CI의 "프로세스 시험" 묶음에서 돈다. 실제 `claude` · 사용자의 세션은 0
@Suite(.serialized)
struct ClaudeAppRelayProcessTests {
    let target = "5e5e5e5e-0000-4000-8000-0000000000f1"
    let secret = "SENTINEL-PROCESS-TEXT-한글"

    /// 가짜 `claude`: argv · 환경 · pid를 파일로 남기고, stdin 줄마다 `/tfping`은 nonce를 되돌리고 `/tfsend`는 전달됐다고 답한다. `exit-now`가 있으면 곧 끝난다
    private static let script = #"""
    #!/bin/sh
    dir="$HOME"
    printf '%s\n' "$@" > "$dir/argv.txt"
    env | sort > "$dir/env.txt"
    echo $$ > "$dir/pid.txt"
    pwd > "$dir/cwd.txt"
    printf '%s\n' '{"type":"system","subtype":"init","model":"claude-opus-5-5"}'
    while IFS= read -r line; do
      printf '%s\n' "$line" >> "$dir/stdin.txt"
      case "$line" in
        *'exit-now'*) exit 0 ;;
        *'/tfping '*)
          n=${line#*/tfping }; n=${n%%\"*}
          printf '%s\n' '{"type":"assistant","message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"x"}]}}'
          printf '{"type":"result","subtype":"success","is_error":false,"result":"tf-relay: {\\"mod\\":\\"tf-relay\\",\\"version\\":\\"1\\",\\"ok\\":true,\\"nonce\\":\\"%s\\"}","local_command":"custom","num_turns":0,"total_cost_usd":0,"modelUsage":{}}\n' "$n"
          ;;
        *'/tfsend '*)
          printf '%s\n' '{"type":"assistant","message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"x"}]}}'
          printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"tf-relay: {\"mod\":\"tf-relay\",\"version\":\"1\",\"ok\":true,\"isDelivered\":true,\"reason\":null}","local_command":"custom","num_turns":0,"total_cost_usd":0,"modelUsage":{}}'
          ;;
      esac
    done
    """#

    private struct Fixture {
        let root: String
        let home: String
        let work: String
        let claude: ClaudeCodeExecutable
        let mod: String

        func read(_ name: String) -> String { (try? String(contentsOfFile: home + "/" + name, encoding: .utf8)) ?? "" }
    }

    private func fixture() throws -> Fixture {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tf-relay-proc-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = GateFileSystem.realpath(base.path) ?? base.path
        let home = root + "/home"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let bin = root + "/bin"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let claude = bin + "/claude"
        try Self.script.write(toFile: claude, atomically: false, encoding: .utf8)
        chmod(claude, 0o755)
        return Fixture(root: root, home: home, work: root + "/work", claude: ClaudeCodeExecutable(path: claude, realPath: claude, directory: bin), mod: try ClaudeAppModFixture.copy())
    }

    private func relay(_ fixture: Fixture, trusted: Bool = true) throws -> ClaudeAppRelay {
        let launcher = KeptClaudeAppRelayLauncher(
            executable: fixture.claude, keeper: try BuiltProducts.url("tf-agent-keeper").path, endedFile: URL(fileURLWithPath: fixture.root + "/state/relay.ended"),
            appEnvironment: [
                "HOME": fixture.home, "USER": "tester", "LANG": "en_US.UTF-8", "PATH": "/usr/bin:/bin", "ANTHROPIC_API_KEY": "SENTINEL-API-KEY", "CLAUDE_CODE_OAUTH_TOKEN": "SENTINEL-TOKEN",
                "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib", "SENTINEL_OTHER": "SENTINEL-OTHER-VALUE",
            ],
            isTrustedExecutable: { _ in trusted }
        )
        return ClaudeAppRelay(configuration: ClaudeAppRelay.Configuration(modDirectory: fixture.mod, workDirectory: fixture.work, commandTimeout: 15, startTimeout: 20), launcher: launcher)
    }

    private func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    private func waitGone(_ pid: Int32, timeout: TimeInterval = 8) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if !alive(pid) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !alive(pid)
    }

    private func cleanup(_ fixture: Fixture) {
        ClaudeAppModFixture.cleanup(fixture.mod)
        try? FileManager.default.removeItem(atPath: fixture.root)
    }

    @Test func theRealKeeperStartsTheRelayWithTheFixedArgumentsAFourVariableEnvironmentAndAnEmptyWorkFolder() async throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        let relay = try relay(fixture)
        let result = await relay.send(sessionID: target, text: secret)
        guard case .delivered(let pid) = result else {
            Issue.record("전달되지 않았다: \(result)")
            return
        }
        #expect(String(fixture.read("pid.txt").trimmingCharacters(in: .whitespacesAndNewlines)) == String(pid), "알린 pid는 실제 `claude` 프로세스다")
        // 인자: 바이트 고정 (한 줄에 하나, 빈 글 인자는 빈 줄)
        let argv = fixture.read("argv.txt")
        #expect(argv == ClaudeAppRelay.arguments(modDirectory: fixture.mod).joined(separator: "\n") + "\n")
        // 환경: 넷 + 셸이 스스로 더하는 것뿐. 위험한 이름 · 시험 값은 하나도 없다 (AC-42)
        let env = fixture.read("env.txt")
        let keys = Set(env.split(separator: "\n").compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) })
        #expect(["HOME", "USER", "LANG", "PATH"].allSatisfy(keys.contains))
        #expect(keys.allSatisfy { !($0.hasPrefix("ANTHROPIC_") || $0.hasPrefix("CLAUDE_") || $0.hasPrefix("DYLD_") || $0.hasPrefix("SENTINEL")) }, "\(keys.sorted())")
        #expect(!env.contains("SENTINEL"))
        // DT6: 글은 stdin으로만 갔다
        #expect(fixture.read("stdin.txt").contains("SENTINEL-PROCESS-TEXT"))
        #expect(!argv.contains("SENTINEL") && !env.contains("SENTINEL-PROCESS") && !fixture.read("cwd.txt").contains("SENTINEL"))
        // cwd: 앱 데이터의 빈 폴더
        #expect(fixture.read("cwd.txt").trimmingCharacters(in: .whitespacesAndNewlines) == fixture.work)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.work).isEmpty)
        #expect(relay.pids.current == [pid])
        #expect(alive(pid))
        await relay.shutdown()
        #expect(await waitGone(pid), "끝내면 프로세스가 사라진다")
        #expect(relay.pids.current.isEmpty)
    }

    @Test func anExecutableThatIsNotTrustedIsNeverLaunched() async throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        let relay = try relay(fixture, trusted: false)
        #expect(await relay.send(sessionID: target, text: secret) == .notDelivered(.relayFailed))
        #expect(!FileManager.default.fileExists(atPath: fixture.home + "/argv.txt"), "서명이 Anthropic이 아니면 사용자의 글이 갈 프로세스를 띄우지 않는다")
        #expect(relay.pids.current.isEmpty)
    }

    @Test func aRelayThatExitsOnItsOwnIsNoticedAndTheNextSendStartsANewOne() async throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        let relay = try relay(fixture)
        guard case .delivered(let first) = await relay.send(sessionID: target, text: "one") else {
            Issue.record("처음 보내기가 전달되지 않았다")
            return
        }
        // 가짜 `claude`는 이 글을 보면 스스로 끝난다 (답 없이)
        _ = await relay.send(sessionID: target, text: "exit-now please")
        #expect(await waitGone(first))
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, !relay.pids.current.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        #expect(relay.pids.current.isEmpty, "끝난 중계의 pid는 비운다")
        guard case .delivered(let second) = await relay.send(sessionID: target, text: "two") else {
            Issue.record("다시 띄운 중계가 전달하지 않았다")
            return
        }
        #expect(second != first)
        await relay.shutdown()
        #expect(await waitGone(second))
    }

    @Test func theLocatingLauncherFindsTheClaudeAtEachLaunchAndRefusesWhenThereIsNone() async throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        let keeper = try BuiltProducts.url("tf-agent-keeper").path
        let environment = ["HOME": fixture.home, "USER": "tester", "LANG": "en_US.UTF-8", "PATH": "/usr/bin:/bin"]
        let configuration = ClaudeAppRelay.Configuration(modDirectory: fixture.mod, workDirectory: fixture.work, commandTimeout: 15, startTimeout: 20)
        let missing = ClaudeAppRelay(
            configuration: configuration,
            launcher: LocatingClaudeAppRelayLauncher(
                locator: ClaudeCodeLocator(candidates: [fixture.root + "/nowhere/claude"], confinedTo: fixture.root), keeper: keeper, endedFile: URL(fileURLWithPath: fixture.root + "/state/missing.ended"),
                appEnvironment: environment, isTrustedExecutable: { _ in true }
            )
        )
        #expect(await missing.send(sessionID: target, text: "hello") == .notDelivered(.relayFailed), "`claude`가 없으면 띄우지 않는다")
        let found = ClaudeAppRelay(
            configuration: configuration,
            launcher: LocatingClaudeAppRelayLauncher(
                locator: ClaudeCodeLocator(candidates: [fixture.claude.path], confinedTo: fixture.root), keeper: keeper, endedFile: URL(fileURLWithPath: fixture.root + "/state/found.ended"),
                appEnvironment: environment, isTrustedExecutable: { _ in true }
            )
        )
        guard case .delivered(let pid) = await found.send(sessionID: target, text: "hello") else {
            Issue.record("찾은 `claude`로 전달되지 않았다")
            return
        }
        #expect(alive(pid))
        await found.shutdown()
        #expect(await waitGone(pid))
    }

    @Test func theLauncherRefusesAWorkFolderThatIsNotAPlainOwnedDirectory() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tf-relay-dir-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = GateFileSystem.realpath(base.path) ?? base.path
        #expect(KeptClaudeAppRelayLauncher.prepareFolder(root + "/new/work"), "없으면 0700으로 만든다")
        #expect(KeptClaudeAppRelayLauncher.prepareFolder(root + "/new/work"), "있으면 그대로")
        try FileManager.default.createSymbolicLink(atPath: root + "/link", withDestinationPath: root + "/new/work")
        #expect(!KeptClaudeAppRelayLauncher.prepareFolder(root + "/link"), "기호 링크는 안 된다")
        try "x".write(toFile: root + "/file", atomically: false, encoding: .utf8)
        #expect(!KeptClaudeAppRelayLauncher.prepareFolder(root + "/file"))
        chmod(root + "/new/work", 0o777)
        #expect(!KeptClaudeAppRelayLauncher.prepareFolder(root + "/new/work"), "다른 사용자가 쓸 수 있는 폴더는 안 된다")
        #expect(!KeptClaudeAppRelayLauncher.prepareFolder("relative/path") && !KeptClaudeAppRelayLauncher.prepareFolder("/a/../b"))
    }

    /// OA PR-D3 검토 P3-8: 끝낸 뒤에는 stdin fd에 쓰지 않는다. 끝나면서 닫힌 fd 번호를 다른 파일이 곧바로 쓰므로(fd 재사용), 앞서 줄 서 있던 쓰기가 그 번호로 가면 글이 엉뚱한 파일에 들어간다
    @Test func aWriteAfterTheStopNeverReachesAFileDescriptorThatWasReusedByAnotherFile() async throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        let keeper = try BuiltProducts.url("tf-agent-keeper").path
        let launcher = KeptClaudeAppRelayLauncher(
            executable: fixture.claude, keeper: keeper, endedFile: URL(fileURLWithPath: fixture.root + "/state/stale.ended"),
            appEnvironment: ["HOME": fixture.home, "USER": "tester", "LANG": "en_US.UTF-8", "PATH": "/usr/bin:/bin"], isTrustedExecutable: { _ in true }
        )
        let process = try await launcher.launch(arguments: ClaudeAppRelay.arguments(modDirectory: fixture.mod), cwd: fixture.work)
        await process.stop()
        // 닫힌 fd 번호를 다른 파일이 쓴다 (낮은 번호부터 재사용된다)
        let paths = (0..<64).map { fixture.root + "/reused-\($0).txt" }
        let descriptors = paths.map { open($0, O_CREAT | O_WRONLY, 0o600) }
        defer { for descriptor in descriptors where descriptor >= 0 { close(descriptor) } }
        let wrote = await process.write(Data("SENTINEL-STALE-WRITE\n".utf8))
        #expect(!wrote, "끝난 프로세스에는 쓰지 않는다")
        let leaked = paths.filter { ((try? String(contentsOfFile: $0, encoding: .utf8)) ?? "").contains("SENTINEL") }
        #expect(leaked.isEmpty, "글이 다른 파일에 들어갔다: \(leaked.count)개")
    }

    @Test func aScriptIsNotSignedByAnthropicAndTheRealClaudeBinaryIfPresentIs() throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        #expect(!ClaudeAppExecutableTrust.isSignedByAnthropic(path: fixture.claude.realPath))
        #expect(!ClaudeAppExecutableTrust.isSignedByAnthropic(path: "/nonexistent/claude"))
        #expect(!ClaudeAppExecutableTrust.isSignedByAnthropic(path: "/bin/sh"), "Apple 서명은 Anthropic 팀이 아니다")
    }
}
#endif
