#if os(macOS) && DEBUG
import Darwin
import Foundation
import Testing
@testable import TaskforceKit

/// Claude Code adapter의 D4a-2 몫: 증명 못 한 중단은 `.unknown` (D4a2-09) · `terminalSession` (D4a2-06) · `forgetSession` (D4a2-08). 가짜 `claude`만 쓴다 (실제 `claude` 실행 0)
struct ClaudeD4a2AdapterTests {
    // MARK: .unknown

    @Test func anInterruptThatCannotProveTheSignalIsUnknownNeverSignalled() async throws {
        let fake = try FakeClaude()
        let restarted = fake.restarted()
        // 1) 세션 잠금을 읽지 못한다 (UUID 세션): 끝을 증명할 수 없다
        let lock = try #require(ClaudeSessionLock.file(sessionsRoot: fake.box.sessionsRoot, session: ClaudeTest.session))
        try FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a lock\n".utf8).write(to: lock)
        let target = AgentTurnRef(taskID: ClaudeTest.task, sessionID: ClaudeTest.session, identity: nil)
        #expect(await restarted.interrupt(target, scope: .turnAndProcesses) == .unknown, "잠금을 읽지 못하면 보냈다고 적지 않는다")
        // 2) 잠금 자리가 없는 세션 id에 정체도 없다
        let noLockNoIdentity = AgentTurnRef(taskID: ClaudeTest.task, sessionID: "not-a-uuid", identity: nil)
        #expect(await restarted.interrupt(noLockNoIdentity, scope: .turnAndProcesses) == .unknown)
        // 3) 정체를 증명할 수 없다 (pid 없음 · 모르는 marker): 신호도 보내지 않는다
        let unprovable = AgentProcessIdentity(pid: nil, startedAt: .distantPast, processMarker: "not-a-marker")
        let noLockUnprovable = AgentTurnRef(taskID: ClaudeTest.task, sessionID: "not-a-uuid", identity: unprovable)
        #expect(await restarted.interrupt(noLockUnprovable, scope: .turnAndProcesses) == .unknown)
    }

    @Test func aRunTheAdapterSupervisesStillAnswersSignalled() async throws {
        let fake = try FakeClaude()
        try fake.scenario(["runs": [["ignore_sigint": true, "steps": [["text": "working"]], "linger_after_result": 30.0]]])
        let events = EventLog()
        let identity = try await fake.turn(events: events)
        #expect(await events.wait { $0.contains(.message(text: "working")) })
        let result = await fake.process.interrupt(AgentTurnRef(taskID: ClaudeTest.task, sessionID: ClaudeTest.session, identity: identity), scope: .turnAndProcesses)
        #expect(result == .signalled)
        #expect(await events.wait(timeout: 60) { FakeClaude.ended($0) })
    }

    // MARK: terminalSession

    @Test func theTerminalSessionIsTheBoundIDAndTheRealExecutablePath() async throws {
        let fake = try FakeClaude(linked: true)
        try fake.scenario(["runs": [["steps": [["text": "hello"]]]]])
        let events = EventLog()
        let identity = try await fake.turn(events: events)
        #expect(await events.wait { FakeClaude.ended($0) })
        let terminal = try #require(await fake.process.terminalSession(ClaudeTest.session))
        #expect(terminal.providerSessionID == FakeClaude.providerSession(identity))
        #expect(terminal.executableRealPath == GateFileSystem.realpath(fake.claude.path), "기호 링크가 아니라 realpath다")
        #expect(terminal.executableRealPath != fake.claude.path)
        #expect(await fake.process.terminalSession(ClaudeTest.session.uppercased()) == terminal, "세션 id는 대소문자를 가리지 않는다")
    }

    @Test func aSessionThatIsNotBoundYetOrHasAnUnsafeIDOrNoExecutableHasNoTerminalSession() async throws {
        let fake = try FakeClaude()
        // 세션 폴더가 없다: 만들지 않고 nil
        #expect(await fake.process.terminalSession(ClaudeTest.session) == nil)
        #expect(!FileManager.default.fileExists(atPath: fake.box.sessionsRoot.appending(path: ClaudeTest.session).path), "읽기만 한다: 폴더를 만들지 않는다")
        let folder = fake.box.sessionsRoot.appending(path: ClaudeTest.session, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // 묶이지 않았다 (init이 id를 돌려주기 전)
        var state = ClaudeSessionState()
        state.providerSessionID = "c0ffee00-0000-4000-8000-000000000001"
        state.bound = false
        try state.save(in: folder)
        #expect(await fake.process.terminalSession(ClaudeTest.session) == nil)
        // 묶였지만 id가 명령줄 옵션처럼 읽힌다
        state.bound = true
        state.providerSessionID = "--dangerously-skip-permissions"
        try state.save(in: folder)
        #expect(await fake.process.terminalSession(ClaudeTest.session) == nil)
        state.providerSessionID = "c0ffee00-0000-4000-8000-000000000001"
        try state.save(in: folder)
        let ok = await fake.process.terminalSession(ClaudeTest.session)
        #expect(ok?.providerSessionID == "c0ffee00-0000-4000-8000-000000000001")
        // 세션 id가 UUID가 아니면 (경로로 읽히지 못하게) nil
        #expect(await fake.process.terminalSession("../escape") == nil)
        // 실행 파일을 못 찾는다
        let lost = ClaudeCodeProcess(
            sessionsRoot: fake.box.sessionsRoot, hookServer: nil, helpers: fake.helpers, locator: ClaudeCodeLocator(candidates: [], confinedTo: fake.box.root.path), timing: .ci
        )
        #expect(await lost.terminalSession(ClaudeTest.session) == nil)
    }

    // MARK: forgetSession

    @Test func forgettingASessionKeepsItsRedactorWhileAProcessOfThatSessionStillLives() async throws {
        let fake = try FakeClaude()
        fake.allowReadonlyCat("notes.md")
        try fake.scenario(["runs": [["steps": [["tool": "Bash", "id": "toolu_b", "input": ["command": "cat notes.md"], "sleep": 30]]]]])
        await fake.process.seedRedactorForTest(SecretRedactor(["a-secret-value-123"]), for: ClaudeTest.session)
        #expect(await !fake.process.redactor(ClaudeTest.session).isEmpty)
        let events = EventLog()
        let identity = try await fake.turn(events: events)
        #expect(await ClaudeReviewProcessTests.waitUntil { fake.report(0)?["sleep_pid"] != nil })
        await fake.process.forgetSession(ClaudeTest.session)
        #expect(await !fake.process.redactor(ClaudeTest.session).isEmpty, "돌고 있는 프로세스의 출력이 비밀값을 되말하면 가려야 한다")
        _ = await fake.process.interrupt(AgentTurnRef(taskID: ClaudeTest.task, sessionID: ClaudeTest.session, identity: identity), scope: .turnAndProcesses)
        #expect(await events.wait { FakeClaude.ended($0) })
        var idle = false
        for _ in 0..<500 where !idle {
            idle = await !fake.process.hasRegisteredRuns()
            if !idle { try? await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(idle, "끝을 증명하면 등록부에서 빠진다")
        await fake.process.forgetSession(ClaudeTest.session)
        #expect(await fake.process.redactor(ClaudeTest.session).isEmpty, "프로세스가 없으면 잊는다")
    }

    @Test func forgettingAnIdleSessionClearsItsRedactor() async throws {
        let fake = try FakeClaude()
        await fake.process.seedRedactorForTest(SecretRedactor(["a-secret-value-123"]), for: ClaudeTest.session)
        await fake.process.forgetSession(ClaudeTest.session)
        #expect(await fake.process.redactor(ClaudeTest.session).isEmpty)
    }
}
#endif
