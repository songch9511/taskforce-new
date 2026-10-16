#if os(macOS) && DEBUG
import Darwin
import Foundation
import Testing
import TaskforceAgentWire
@testable import TaskforceKit

/// 재검토 5 재현 (OA D3a 14장): Astra `oa-d3a-codex-rereview5.md` P1 셋 · P2 하나와 sec 재검토 5(`d3a-sec6`)의 재현을 시험으로 옮긴 것.
/// 가짜 `claude` + 실제로 빌드한 helper · 지킴이. 실제 `claude` 실행 0
@Suite(.serialized)
struct ClaudeRereview5ReproTests {
    let box = ClaudeSandbox()

    static func waitUntil(_ seconds: TimeInterval, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    static func turn(_ fake: FakeClaude, task: String = ClaudeTest.task) -> AgentTurnStart {
        AgentTurnStart(
            taskID: task, sessionID: ClaudeTest.session, turnSeq: 1, adapter: "agent:claude-code", externalSessionID: nil, workspaceRef: fake.workspace, resume: false,
            access: .write, policyMode: .manual, marker: UUID().uuidString.lowercased(), text: "Again."
        )
    }

    static func pidAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    // MARK: Astra P1-1 띄운 뒤 실패해도 잠금이 남는다

    /// 지킴이가 `claude`를 띄운 뒤 앱의 대조(세대 조회)가 실패하고, 지킴이가 기한 안에 0으로 끝나지 못했다: 끝을 모른다 → 다시 뜬 앱도 그 세션의 다음 실행을 띄우지 않는다
    @Test func p11AStartThatFailsAfterTheSpawnLeavesTheSessionLockedForARelaunchedApp() async throws {
        let timing = ClaudeCodeTiming(
            orphanInterruptGrace: 0.5, orphanKillGrace: 1, closeTimeout: 1, exitAfterResult: 3, drainAfterExit: 1, probeTimeout: 5, serverTimeout: 5, keeperExit: 0.01
        )
        let fake = try FakeClaude(timing: timing)
        try fake.scenario(["runs": [["steps": [["text": "ok"]]]]])
        let me = getpid()
        var failing = KeeperMembers.Lookups.live
        // 지킴이(이 시험 프로세스의 자식)의 세대를 읽지 못한다
        failing.generation = { pid in
            let read = AgentProcesses.generation(pid: pid)
            if case .present(let value) = read, value.parentPID == me { return .failed }
            return read
        }
        let events = EventLog()
        await #expect(throws: (any Error).self) {
            try await ClaudeProcessInspector.$lookups.withValue(failing) { _ = try await fake.turn(events: events) }
        }
        let relaunched = fake.restarted()
        await #expect(throws: (any Error).self, "다시 뜬 앱도 끝을 모르는 세션에 두 번째 writer를 만들지 않는다") {
            _ = try await relaunched.startTurn(Self.turn(fake), events: EventLog().sink)
        }
        await #expect(throws: (any Error).self, "지금 앱도") { _ = try await fake.process.startTurn(Self.turn(fake), events: EventLog().sink) }
    }

    /// 지킴이 spawn 자체가 실패했다 (미실행 = 프로세스 0): 잠금 없이 실패하고 다음 실행은 뜬다
    @Test func p11AKeeperThatNeverRanLeavesTheSessionFree() async throws {
        let fake = try FakeClaude(keeper: box.root.appending(path: "no-such-keeper").path)
        try fake.scenario(["runs": [["steps": [["text": "ok"]]]]])
        await #expect(throws: (any Error).self) { _ = try await fake.turn(events: EventLog()) }
        let relaunched = fake.restarted(keeper: try BuiltProducts.url("tf-agent-keeper").path)
        let events = EventLog()
        _ = try await relaunched.startTurn(Self.turn(fake), events: events.sink)
        #expect(await events.wait { FakeClaude.ended($0) })
    }

    // MARK: Astra P1-2 끝을 모르는 실행은 앱이 다시 떠도 세션을 막는다

    /// 지킴이가 기록 없이 사라져 끝을 증명하지 못했다 (13장 3): 원장 alive와 무관하게 다시 뜬 앱의 다음 실행도 띄우지 않는다
    @Test func p12AnUnprovenEndStillLocksTheSessionAfterARelaunch() async throws {
        let fake = try FakeClaude()
        try fake.scenario(["runs": [["steps": [["text": "ok"]], "linger_after_result": 1.5]]])
        let events = EventLog()
        let identity = try await fake.turn(events: events)
        guard case .present(let claude) = AgentProcesses.generation(pid: pid_t(try #require(identity.pid))) else {
            Issue.record("claude generation")
            return
        }
        kill(claude.parentPID, SIGKILL)
        #expect(await Self.waitUntil(20) { fake.log.lines.contains { $0.hasPrefix("claude_end_unproven") } })
        await #expect(throws: (any Error).self) { _ = try await fake.restarted().startTurn(Self.turn(fake), events: EventLog().sink) }
    }

    // MARK: Astra P1-3 주석 판정은 실제 단어 경계로

    static let secret = "CANARY-SECRET-7f3a"
    static let split = "CANARY-\"\"SECRET-7f3a"

    @Test func p13ACommentIsOnlyAtARealWordStart() async throws {
        let redactor = SecretRedactor([Self.secret])
        let bs = "\\"
        let commands = [
            "echo prefix" + bs + " #" + Self.split, "echo prefix" + bs + "\t#" + Self.split, "echo a" + bs + ";#" + Self.split, "echo a" + bs + "&#" + Self.split,
            "echo a" + bs + "|#" + Self.split, "echo a" + bs + "(#" + Self.split, "echo a" + bs + ")#" + Self.split, "echo pre" + bs + "\n#" + Self.split,
            "echo a''#" + Self.split,
        ]
        for command in commands {
            #expect(redactor.detects(command), "\(command.debugDescription)")
            #expect(!redactor.redact(command).contains("SECRET"), "\(command.debugDescription)")
        }
        // 결정 입력이면 서버에 묻지 않는다
        let cwd = box.sessionsRoot.appending(path: "\(ClaudeTest.session)/cwd", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let decider = ScriptedDecider([.success(ScriptedDecider.response(.allow, .policyAuto))])
        let context = ClaudeGateContext(
            mode: .normal, access: .write, workspaceRealPath: box.workspacePath, sessionCwdRealPath: cwd.path, childPATH: "/usr/bin:/bin", agentSessionID: ClaudeTest.session,
            agentTaskID: ClaudeTest.task, turnSeq: 1, deferIssued: false, answerDelivered: false, secrets: redactor
        )
        let outcome = await ClaudeToolGate(fileSystem: .live, decide: decider.function, serverTimeout: .seconds(30))
            .evaluate(ClaudeTest.request("Bash", .object(["command": .string(commands[0])]), cwd: cwd.path), context: context)
        #expect(outcome.code == "secret_in_command")
        #expect(decider.calls.isEmpty, "원문 명령이 서버로 나갔다")
    }

    // MARK: Astra P2-4 Stop · 시간 초과 전이에서 바로 정산

    /// 답 훅이 시간 초과 deny로 끝나고 프로세스가 그 결과를 정하기 전에 끝났다: 그래도 닫힘(`requestClosed`)이다
    @Test func p24aATimedOutAnswerHookIsClosedEvenIfTheProcessEndsFirst() async throws {
        let delay = Shared(false)
        let fake = try FakeClaude(hooks: ClaudeCodeTestHooks(beforeHookReturn: { if delay.value { try? await Task.sleep(for: .seconds(2.5)) } }))
        try fake.scenario(["runs": [["steps": [["tool": "mcp__tf__ask_user", "id": "toolu_q", "input": FakeClaude.askColor]]], ["final_text": "Blue."]]])
        let first = EventLog()
        let identity = try await fake.turn(events: first)
        #expect(await first.wait { FakeClaude.ended($0) })
        delay.mutate { $0 = true }
        let result = try? await fake.answer(
            "toolu_q", kind: .input, value: AgentAnswerValue(answers: ["color": .one("blue")]), external: FakeClaude.providerSession(identity), events: EventLog()
        )
        #expect(result == .requestClosed)
    }

    /// 답 훅이 오기 전에 Stop, 프로세스는 훅 없이 끝난다: 닫힘(`requestClosed`)이다
    @Test func p24bAStopBeforeTheAnswerHookClosesTheRequest() async throws {
        let fake = try FakeClaude()
        try fake.scenario(["runs": [["steps": [["tool": "mcp__tf__ask_user", "id": "toolu_q", "input": FakeClaude.askColor]]], ["pause_before_resume_hook": 6.0, "final_text": "x"]]])
        let first = EventLog()
        let identity = try await fake.turn(events: first)
        #expect(await first.wait { FakeClaude.ended($0) })
        let session = FakeClaude.providerSession(identity)
        let answering = Task { try await fake.answer("toolu_q", kind: .input, value: AgentAnswerValue(answers: ["color": .one("blue")]), external: session, events: EventLog()) }
        #expect(await Self.waitUntil(8) { fake.report(1) != nil })
        _ = await fake.process.interrupt(AgentTurnRef(taskID: ClaudeTest.task, sessionID: ClaudeTest.session, identity: nil), scope: .turn)
        let result = try? await answering.value
        #expect(result == .requestClosed)
    }

    /// 보류 id가 아닌 다른 tool id의 훅이 시간 초과 deny로 끝났다: 그 전이에서 답을 닫고 그 spawn을 멈춘다 (늦은 판정 · init을 기다리지 않는다)
    @Test func p24cAnotherToolIDsTimedOutHookStopsTheAnswerSpawnAtOnce() async throws {
        let delay = Shared(false)
        let fake = try FakeClaude(hooks: ClaudeCodeTestHooks(beforeHookReturn: { if delay.value { try? await Task.sleep(for: .seconds(2.5)) } }))
        try fake.scenario(["runs": [
            ["steps": [["tool": "mcp__tf__ask_user", "id": "toolu_q", "input": FakeClaude.askColor]]],
            ["resume_id_override": "toolu_other", "pause_after_resume_hook": 8.0, "final_text": "x"],
        ]])
        let first = EventLog()
        let identity = try await fake.turn(events: first)
        #expect(await first.wait { FakeClaude.ended($0) })
        delay.mutate { $0 = true }
        let started = Date()
        let result = try? await fake.answer(
            "toolu_q", kind: .input, value: AgentAnswerValue(answers: ["color": .one("blue")]), external: FakeClaude.providerSession(identity), events: EventLog()
        )
        #expect(result == .requestClosed)
        #expect(Date().timeIntervalSince(started) < 5, "시간 초과 전이에서 바로 멈춘다")
    }

    // MARK: sec P2-1 실효 사용자가 바뀐 자손

    /// 구성원이 setuid 프로그램(`login`, 실효 사용자 root)을 남기고 끝났다: 그것이 사는 동안 끝이 아니다
    @Test func s21ASetuidDescendantKeepsTheKeeperAlive() async throws {
        let fifo = box.root.appending(path: "ff").path
        #expect(mkfifo(fifo, 0o600) == 0)
        // fd는 한 번만 닫는다 (두 번 닫으면 같은 프로세스에서 도는 다른 시험의 fd를 닫을 수 있다)
        let holder = Shared(open(fifo, O_RDWR | O_CLOEXEC))
        func release() {
            holder.mutate { fd in
                if fd >= 0 { close(fd) }
                fd = -1
            }
        }
        defer { release() }
        let out = box.root.appending(path: "login.pid").path
        let root = try box.keep("/usr/bin/login < \(fifo) >/dev/null 2>&1 & echo $! > \(out); exit 0")
        let login = try await ClaudeProcessIdentityTests.readPID(out)
        try await Task.sleep(for: .milliseconds(1500))
        let live = ClaudeProcessInspector.liveness(root.identity, lineage: root.lineage)
        let relaunched = await ClaudeRereview3ReproTests.adapter(box).liveness(root.identity)
        let alive = Self.pidAlive(login)
        #expect(alive, "login이 살아 있다 (시험 전제)")
        #expect(live != .ended(AgentExit(code: nil)), "거짓 끝")
        #expect(relaunched != .ended(AgentExit(code: nil)), "다시 뜬 앱의 거짓 끝")
        release()
        #expect(await root.keeperEnded(timeout: 8), "login이 끝나면 지킴이도 끝을 증명한다")
    }

    // MARK: sec P2-2 다시 disclaim한 자손

    @Test func s22ARedisclaimedDescendantKeepsTheKeeperAlive() async throws {
        let fake = try BuiltProducts.url("FakeClaudeCode").path
        let out = box.root.appending(path: "dspawn.pid").path
        let tag = "618.\(Int.random(in: 10000...99999))"
        let root = try box.keep("'\(fake)' --disclaim-spawn /bin/sleep \(tag) > '\(out)'; exit 0")
        let child = try await ClaudeProcessIdentityTests.readPID(out)
        defer { kill(child, SIGKILL) }
        try await Task.sleep(for: .milliseconds(1500))
        let live = ClaudeProcessInspector.liveness(root.identity, lineage: root.lineage)
        let relaunched = await ClaudeRereview3ReproTests.adapter(box).liveness(root.identity)
        #expect(Self.pidAlive(child))
        #expect(live != .ended(AgentExit(code: nil)), "거짓 끝")
        #expect(relaunched != .ended(AgentExit(code: nil)), "다시 뜬 앱의 거짓 끝")
        kill(child, SIGKILL)
        #expect(await root.keeperEnded(timeout: 8))
    }

    // MARK: sec P3-3 fork 사슬

    /// 목록과 조회 사이에 fork하고 끝나는 사슬: 사슬이 도는 동안 끝을 확정하지 않는다 (세 번)
    @Test func s33AForkChainIsNeverEndedWhileItRuns() async throws {
        var falseEnds = 0
        for _ in 0..<3 {
            let tag = "619.\(Int.random(in: 10000...99999))"
            let root = try box.keep("/usr/bin/perl -e 'my $t=time; while(time-$t<3){ exit 0 if fork; }' \(tag) </dev/null >/dev/null 2>&1 & exit 0")
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                if root.lineage.provenEnded, !KeeperRereviewTag.pids(tag).isEmpty { falseEnds += 1; break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            _ = await root.keeperEnded(timeout: 10)
        }
        #expect(falseEnds == 0)
    }

    // MARK: sec P3-5 띄우기는 actor 밖

    /// 지킴이가 뜨기를 기다리는 동안(시험이 놓아 줄 때까지) adapter의 다른 호출은 막히지 않는다
    @Test func s35TheKeeperSpawnDoesNotHoldTheActor() async throws {
        let go = box.root.appending(path: "go")
        let slow = box.root.appending(path: "slow-keeper")
        try "#!/bin/sh\nwhile [ ! -e '\(go.path)' ]; do /bin/sleep 0.02; done\nexec '\(try BuiltProducts.url("tf-agent-keeper").path)' \"$@\"\n"
            .write(to: slow, atomically: true, encoding: .utf8)
        #expect(chmod(slow.path, 0o755) == 0)
        let fake = try FakeClaude(keeper: slow.path)
        try fake.scenario(["runs": [["steps": [["text": "ok"]]]]])
        let events = EventLog()
        let starting = Task { try await fake.turn(events: events) }
        try await Task.sleep(for: .milliseconds(200))
        let returned = Shared(false)
        let process = fake.process
        let probe = Task {
            _ = await process.liveness(AgentProcessIdentity(pid: nil, startedAt: Date(), processMarker: UUID().uuidString))
            returned.mutate { $0 = true }
        }
        let answered = await Self.waitUntil(3) { returned.value }
        FileManager.default.createFile(atPath: go.path, contents: Data())
        #expect(answered, "띄우는 동안 actor가 막혔다")
        await probe.value
        _ = try await starting.value
        #expect(await events.wait { FakeClaude.ended($0) })
    }

    // MARK: sec P3-7 cwd는 lstat로

    @Test func s37ACwdThatIsALinkOrAFileIsQuarantinedAndRecreated() async throws {
        for kind in ["link", "file"] {
            let fake = try FakeClaude()
            try fake.scenario(["runs": [["steps": [["text": "ok"]]]]])
            let session = fake.box.sessionsRoot.appending(path: ClaudeTest.session, directoryHint: .isDirectory)
            let cwd = session.appending(path: "cwd")
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
            #expect(chmod(fake.box.outside.path, 0o755) == 0)
            if kind == "link" {
                try FileManager.default.createSymbolicLink(at: cwd, withDestinationURL: fake.box.outside)
            } else {
                try Data("x".utf8).write(to: cwd)
            }
            let events = EventLog()
            _ = try await fake.turn(events: events)
            #expect(await events.wait { FakeClaude.ended($0) }, "\(kind)")
            var info = stat()
            #expect(lstat(cwd.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR && (info.st_mode & 0o7777) == 0o700, "\(kind): 새 cwd는 0700 실제 폴더")
            var outside = stat()
            #expect(stat(fake.box.outside.path, &outside) == 0 && (outside.st_mode & 0o7777) == 0o755, "\(kind): 링크 너머 폴더의 모드를 바꾸지 않는다")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: session.path)) ?? []
            #expect(names.contains { $0.hasPrefix("cwd.quarantine-") }, "\(kind): 옮겨 둔다")
            #expect(fake.report(0)?["cwd"] as? String == ClaudeSandbox.real(cwd.path), "\(kind): claude는 세션 cwd에서 돈다")
        }
    }
}

/// 태그로 프로세스 찾기 (argv)
enum KeeperRereviewTag {
    static func pids(_ tag: String) -> [pid_t] {
        (AgentProcesses.userPIDs() ?? []).filter { pid in
            guard let arguments = ClaudeProcessInspector.arguments(pid: pid) else { return false }
            return arguments.contains { $0.contains(tag) }
        }
    }
}
#endif
