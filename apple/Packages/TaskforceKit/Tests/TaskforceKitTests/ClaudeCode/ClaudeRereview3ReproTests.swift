#if os(macOS) && DEBUG
import Darwin
import Foundation
import Testing
import TaskforceAgentWire
@testable import TaskforceKit

/// 재검토 3의 재현 (OA D3a 계약 11장): 보안 재검토 3 `batch`와 Astra 재검토 3의 사례를 그대로 시험으로. 이름 앞의 `dN`이 11장 항목 번호다.
/// 고치기 전 코드에서 실패하는 것을 본다 (notes 재검토 3 반영: `fresh:` 인자 하나만 고치기 전 이름으로 바꿔 돌렸다)
@Suite(.serialized)
struct ClaudeRereview3ReproTests {
    let box = ClaudeSandbox()
    static let secret = "CANARY-SECRET-7f3a"
    /// 백슬래시 (시험 글에 `\` 이스케이프를 그대로 넣는다)
    static let bs = String(UnicodeScalar(UInt8(0x5C)))

    static func adapter(_ box: ClaudeSandbox) -> ClaudeCodeProcess {
        ClaudeCodeProcess(sessionsRoot: box.sessionsRoot, hookServer: nil, helpers: ClaudeCodeHelpers(hook: "/x", mcp: "/y"),
                          locator: ClaudeCodeLocator(candidates: [], confinedTo: box.root.path), timing: .testing)
    }

    /// 실제 adapter처럼 띄운다 (새 그룹 · argv의 `--settings …/config/<marker>.settings.json`)
    func spawn(_ script: String, marker: String = UUID().uuidString) throws -> (process: ClaudeSpawnedProcess, identity: AgentProcessIdentity) {
        let settings = box.root.appending(path: "config/\(marker).settings.json").path
        let process = try ClaudeSpawner.spawn(
            executable: "/bin/sh", arguments: ["-c", script, "sh", "--settings", settings], environment: ["PATH": "/usr/bin:/bin"], cwd: box.root.path
        )
        process.closeStandardStreams()
        return (process, AgentProcessIdentity(pid: Int(process.pid), startedAt: process.startedAt, processMarker: marker))
    }

    // MARK: 3 (batch) 묶어 쓰기 틈

    @Test func d3AnIntermediateSeenBeforeACrashIsInTheFileAtOnce() async throws {
        let marker = UUID().uuidString
        let file = box.sessionsRoot.appending(path: "lineage/\(marker).lineage")
        let snapshot = box.root.appending(path: "snapshot.lineage")
        // 뿌리 R: 중간 B가 배경 D(sleep 617)를 남기고 0.15초 뒤 끝난다. R은 1초 뒤 끝난다
        let root = try spawn("/bin/sh -c '/bin/sleep 617 >/dev/null 2>&1 & /bin/sleep 0.15'; /bin/sleep 1; exit 0", marker: marker)
        let lineage = ClaudeLineage(file: file, fresh: true)
        lineage.seed(root.process.pid)
        lineage.save(force: true)
        lineage.watch(root.identity)
        try await Task.sleep(for: .milliseconds(350))
        // 앱이 여기서 죽었다 (0.5초 묶음 전): 그때 디스크에 있던 것
        try FileManager.default.copyItem(at: file, to: snapshot)
        _ = try await offPool { root.process.waitForExit() }
        lineage.forget()
        defer { Self.killSleep617() }
        // 디스크를 죽은 순간으로 되돌린다 (그 앱은 끝 기록을 쓰지 못했다)
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: ClaudeLineage.endedFile(file))
        try FileManager.default.copyItem(at: snapshot, to: file)
        // 다시 뜬 앱: 그 파일로 본다. B는 끝났고 D는 launchd 밑에 남았다
        #expect(await Self.adapter(box).liveness(root.identity) == .alive, "D가 살아 있다")
    }

    static func killSleep617() {
        for info in ClaudeProcessInspector.userProcessInfos() ?? [] where ClaudeProcessInspector.arguments(pid: info.kp_proc.p_pid)?.contains("617") == true {
            kill(info.kp_proc.p_pid, SIGKILL)
        }
    }

    // MARK: 1 혈통 파일이 없거나 읽지 못하면 unknown

    @Test func d1AMissingOrUnreadableLineageFileIsUnknownNotEnded() async throws {
        let marker = UUID().uuidString
        let root = try spawn("exit 0", marker: marker)
        _ = try await offPool { root.process.waitForExit() }
        let adapter = Self.adapter(box)
        #expect(await adapter.liveness(root.identity) == .unknown, "파일 없음: 자손이 없다는 증거가 없다")
        #expect(await adapter.terminateOrphan(root.identity) == .unknown)
        let file = box.sessionsRoot.appending(path: "lineage/\(marker).lineage")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "taskforce-lineage 2\nbroken\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(await adapter.liveness(root.identity) == .unknown, "읽지 못하는 파일")
    }

    // MARK: 5 뿌리 pid를 다시 받은 자손

    @Test func d5ADescendantThatReusedTheRootPIDIsStillFound() async throws {
        let pidFile = box.root.appending(path: "reuse.pid").path
        let root = try spawn("/usr/bin/perl -e 'use POSIX; POSIX::setsid(); open(F, q(>\(pidFile))); print F $$; close F; sleep 600;' & sleep 0.3; exit 0")
        let lineage = ClaudeLineage()
        lineage.seed(root.process.pid)
        _ = try await offPool { root.process.waitForExit() }
        let child = try await ClaudeProcessIdentityTests.readPID(pidFile)
        defer { kill(child, SIGKILL) }
        // 원장의 뿌리 pid를 그 자손이 다시 받았다고 하자 (pid 숫자만 같다)
        var identity = root.identity
        identity.pid = Int(child)
        #expect(ClaudeProcessInspector.descendants(identity, lineage: lineage)?.contains { $0.pid == child } == true, "뿌리는 pid가 아니라 뿌리 id로 뺀다")
    }

    // MARK: 7 · 8 비밀값: 정규화 전 글자 · 줄 이음 · ANSI-C

    @Test func d7AndD8TrailingMarksLineContinuationsAndANSICQuotesStillCarryTheSecret() {
        let bs = Self.bs
        let accented = SecretRedactor(["password-é"])
        #expect(accented.detects("echo password-é\u{0323} done"), "뒤에 붙은 결합 표시가 정규화로 섞여도 원래 글자에서 찾는다")
        let redactor = SecretRedactor([Self.secret])
        for text in [
            "printf %s CANARY-SEC" + bs + "\nRET-7f3a",
            "printf %s \"CANARY-SEC" + bs + "\nRET-7f3a\"",
            // 큰따옴표 안의 줄 이음 (따옴표를 벗긴 뒤 다시 풀면 `'`가 작은따옴표로 읽혀 그 뒤 줄 이음이 남는다)
            "printf %s \"it's CANARY-SEC" + bs + "\nRET-7f3a\"",
            "echo $'CANARY-" + bs + "x53ECRET-7f3a'",
            "echo $'" + bs + "103ANARY-SECRET-7f3a'",
            "echo $'CANARY-SECRET-" + bs + "u0037f3a'",
            "echo $'CANARY-SECRET-" + bs + "U00000037f3a'",
        ] {
            #expect(redactor.detects(text), "\(text)")
            #expect(redactor.redact("ran " + text).contains("[redacted]"), "사건 글도 가린다: \(text)")
        }
    }

    // MARK: 9 재시작 전에 건넨 비밀값

    @Test func d9AfterARelaunchASessionThatWasGivenASecretIsNotResumed() async throws {
        let fake = try FakeClaude()
        try fake.scenario(["runs": [
            ["steps": [["tool": "mcp__tf__ask_user", "id": "toolu_secret", "input": ["questions": [["id": "key", "header": "Key", "text": "Paste the API key", "secret": true]]]]]],
            ["final_text": "Stored."],
            ["final_text": "Your key \(Self.secret) is set."],
        ]])
        let first = EventLog()
        let identity = try await fake.turn(events: first)
        #expect(await first.wait { FakeClaude.ended($0) })
        let session = FakeClaude.providerSession(identity)
        let answered = EventLog()
        let result = try await fake.answer("toolu_secret", kind: .input, value: AgentAnswerValue(text: Self.secret), external: session, events: answered)
        guard case .delivered = result else {
            Issue.record("\(result)")
            return
        }
        #expect(await answered.wait { FakeClaude.ended($0) })
        let stateText = try String(contentsOf: fake.box.sessionsRoot.appending(path: "\(ClaudeTest.session)/state.json"), encoding: .utf8)
        #expect(!stateText.contains(Self.secret), "표식만, 값 0")
        // 앱이 다시 떴다: 가리개가 비었다 → 그 세션을 이어 띄우지 않는다
        let restarted = fake.restarted()
        let next = EventLog()
        await #expect(throws: AgentStartError.self) {
            _ = try await restarted.startTurn(AgentTurnStart(
                taskID: "7a5c0001-0000-4000-8000-000000000002", sessionID: ClaudeTest.session, turnSeq: 2, adapter: "agent:claude-code", externalSessionID: session,
                workspaceRef: fake.workspace, resume: true, access: .write, policyMode: .manual, marker: UUID().uuidString.lowercased(), text: "Next"
            ), events: next.sink)
        }
        #expect(fake.runCount == 2, "세 번째 실행은 없다")
        #expect(fake.log.lines.contains { $0.contains("claude_secret_context_lost") })
    }

    // MARK: 10 격리 cwd가 비어 있지 않으면 그대로 띄우지 않는다 (12장 13: 격리 폴더로 옮기고 빈 cwd로 띄운다)

    @Test func d10APlantedProjectSettingsAreMovedOutOfTheSessionCwdBeforeALaunch() async throws {
        let fake = try FakeClaude()
        try fake.scenario(["runs": [["final_text": "ok"]]])
        let folder = fake.box.sessionsRoot.appending(path: ClaudeTest.session, directoryHint: .isDirectory)
        let cwd = folder.appending(path: "cwd", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cwd.appending(path: ".claude"), withIntermediateDirectories: true)
        try "{}".write(to: cwd.appending(path: ".claude/settings.json"), atomically: true, encoding: .utf8)
        let events = EventLog()
        _ = try await fake.turn(events: events)
        #expect(await events.wait { FakeClaude.ended($0) })
        #expect(fake.runCount == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cwd.path).isEmpty, "Claude는 빈 cwd에서 돌았다")
        let attributes = try FileManager.default.attributesOfItem(atPath: cwd.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let quarantine = try #require(try FileManager.default.contentsOfDirectory(atPath: folder.path).first { $0.hasPrefix("cwd.quarantine-") })
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "\(quarantine)/.claude/settings.json").path))
    }

    // MARK: 2 띄운 직후 혈통 파일을 적지 못하면 띄우지 않는다

    @Test func d2ASpawnWhoseLineageFileCannotBeWrittenIsStoppedBeforeItsIdentityIsKept() async throws {
        let fake = try FakeClaude()
        try fake.scenario(["runs": [["steps": [["text": "hi"]], "linger_after_result": 5.0]]])
        // `lineage` 자리에 일반 파일: 혈통 파일을 만들 수 없다
        try FileManager.default.createDirectory(at: fake.box.sessionsRoot, withIntermediateDirectories: true)
        try "x".write(to: fake.box.sessionsRoot.appending(path: "lineage"), atomically: true, encoding: .utf8)
        await #expect(throws: AgentStartError.self) { _ = try await fake.turn(events: EventLog()) }
        try await Task.sleep(for: .milliseconds(300))
        if let pid = fake.report(0)?["pid"] as? Int {
            #expect(ClaudeRereviewProcessTests.gone(pid), "띄운 프로세스는 멈췄다")
        }
    }
}
#endif
