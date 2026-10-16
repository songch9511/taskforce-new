#if os(macOS) && DEBUG
import Darwin
import Foundation
import Synchronization
import Testing
import TaskforceAgentWire
@testable import TaskforceKit

/// 재검토 4의 재현 (OA D3a 계약 12장): 보안 재검토 4의 `sup` · `unseen` · `SecReview4Tests`(F2–F4)와 Astra 재검토 4의 사례를 그대로 시험으로.
/// 이름 앞의 `fN` · `aN` · `sN`이 보안 F 번호 · Astra 번호 · 보안 재현 이름이다. 고치기 전 코드에서 실패하는 것을 본다 (notes 재검토 4 반영)
@Suite(.serialized)
struct ClaudeRereview4ReproTests {
    let box = ClaudeSandbox()
    static let secret = ClaudeRereview3ReproTests.secret
    static let bs = ClaudeRereview3ReproTests.bs

    /// 남은 배경 프로세스를 찾을 `sleep` 인자 (실행마다 다르다)
    static func tag() -> String { "620.\(Int.random(in: 10000...99999))" }

    static func pids(matching tag: String) -> [pid_t] {
        (ClaudeProcessInspector.userProcessInfos() ?? []).map(\.kp_proc.p_pid).filter { ClaudeProcessInspector.arguments(pid: $0)?.contains(tag) == true }
    }

    static func kill(matching tag: String) {
        for pid in pids(matching: tag) { Darwin.kill(pid, SIGKILL) }
    }

    // MARK: F1 sup — 감독 중, 못 본 짧은 중간 프로세스

    /// 뿌리 R이 짧은 중간 sh로 배경 D를 남기고 바로 끝난다. D가 살아 있는 동안 끝이라 하면 안 된다 (보안 재현 10/10 → 13장: 지킴이가 산다)
    @Test func f1SupervisedShortIntermediateNeverProvesAFalseEnd() async throws {
        for _ in 0..<3 {
            let tag = Self.tag()
            defer { Self.kill(matching: tag) }
            let root = try box.keep("/bin/sleep 0.2; /bin/sh -c '/bin/sleep \(tag) >/dev/null 2>&1 &'; exit 0")
            for _ in 0..<150 where ClaudeProcessInspector.check(root.identity) == .same { try await Task.sleep(for: .milliseconds(20)) }
            try await Task.sleep(for: .milliseconds(500))
            let d = try #require(Self.pids(matching: tag).first, "D가 살아 있다")
            #expect(ClaudeProcessInspector.liveness(root.identity, lineage: root.lineage) == .alive, "살아 있는 D를 두고 끝이라 했다")
            #expect(ClaudeProcessInspector.members(root.keeper)?.contains { $0.pid == d } == true)
        }
    }

    // MARK: F1 unseen — 앱이 띄운 직후 죽었다

    /// 혈통 파일만 적은 뒤 앱이 죽었다. 그동안 R이 짧은 중간 sh로 배경 D를 남기고 끝났다. 다시 뜬 앱은 D를 두고 `ended`라 하면 안 된다
    @Test func f1UnseenIntermediateAfterACrashIsNotEnded() async throws {
        let tag = Self.tag()
        defer { Self.kill(matching: tag) }
        let root = try box.keep("/bin/sleep 0.3; /bin/sh -c '/bin/sleep \(tag) >/dev/null 2>&1 &'; /bin/sleep 0.3; exit 0")
        for _ in 0..<150 where ClaudeProcessInspector.check(root.identity) == .same { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!Self.pids(matching: tag).isEmpty, "D가 살아 있다")
        #expect(await ClaudeRereview3ReproTests.adapter(box).liveness(root.identity) == .alive)
    }

    // MARK: Astra P1-1 잘린 줄

    @Test func a1ACutLastLineMakesTheFileIncomplete() async throws {
        let root = try box.keep("/bin/sleep 0.2; exit 0")
        #expect(await root.keeperEnded())
        // 쓰다 끊긴 줄: 지킴이 기록이 있어도 그 파일의 지킴이를 믿지 않는다
        let handle = try FileHandle(forWritingTo: root.file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("4559".utf8))
        try handle.close()
        #expect(await ClaudeRereview3ReproTests.adapter(box).liveness(root.identity) == .unknown, "잘린 줄을 버리고 믿지 않는다")
    }

    // MARK: Astra P1-2 뿌리 id가 전제

    @Test func a2ALineageWithoutARootIDIsNotRecorded() {
        let lineage = ClaudeLineage(file: box.sessionsRoot.appending(path: "lineage/\(UUID().uuidString).lineage"), fresh: true)
        #expect(!lineage.save())
        #expect(!lineage.isRecorded, "지킴이 · 뿌리 id 없이 적은 혈통을 기록으로 쳤다")
    }

    // MARK: Astra P1-4 앞선 작은따옴표 뒤의 ANSI-C

    @Test func a4AnApostropheBeforeAnANSICValueDoesNotHideIt() async throws {
        let value = "$'CANARY-" + Self.bs + "x53ECRET-7f3a'"
        let redactor = SecretRedactor([Self.secret])
        #expect(redactor.detects("Here's the value: " + value + "."), "자연어의 작은따옴표")
        #expect(redactor.detects("# user's setup\necho " + value), "Bash 주석의 작은따옴표")
        let cwd = box.sessionsRoot.appending(path: "\(ClaudeTest.session)/cwd", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let decider = ScriptedDecider([.success(ScriptedDecider.response(.allow, .policyAuto))])
        let context = ClaudeGateContext(
            mode: .normal, access: .write, workspaceRealPath: box.workspacePath, sessionCwdRealPath: cwd.path, childPATH: "/usr/bin:/bin", agentSessionID: ClaudeTest.session,
            agentTaskID: ClaudeTest.task, turnSeq: 1, deferIssued: false, answerDelivered: false, secrets: redactor
        )
        let outcome = await ClaudeToolGate(fileSystem: .live, decide: decider.function, serverTimeout: .seconds(30))
            .evaluate(ClaudeTest.request("Bash", .object(["command": .string("# user's setup\necho " + value)]), cwd: cwd.path), context: context)
        #expect(outcome.code == "secret_in_command")
        #expect(decider.calls.isEmpty, "원문 명령이 서버로 나갔다")
    }

    // MARK: Astra P2-5 판정 뒤 Stop: Deny 답

    @Test func a5AStopAfterADenyAnswerIsDecidedClosesTheRequest() async throws {
        let armed = Mutex(false)
        let holder = Mutex<ClaudeCodeProcess?>(nil)
        let hooks = ClaudeCodeTestHooks(beforeHookReturn: {
            guard armed.withLock({ value in
                defer { value = false }
                return value
            }), let process = holder.withLock({ $0 }) else { return }
            _ = await process.interrupt(AgentTurnRef(taskID: ClaudeTest.task, sessionID: ClaudeTest.session, identity: nil), scope: .turnAndProcesses)
        })
        let fake = try FakeClaude(decider: ScriptedDecider([.success(ScriptedDecider.response(.defer, .manualWrite))]), hooks: hooks)
        holder.withLock { $0 = fake.process }
        try fake.scenario(["runs": [
            ["steps": [["tool": "Write", "id": "toolu_w", "input": ["file_path": fake.workspace + "/late.txt", "content": "x"]]]],
            ["final_text": "Done."],
        ]])
        let first = EventLog()
        let identity = try await fake.turn(events: first)
        #expect(await first.wait { FakeClaude.ended($0) })
        armed.withLock { $0 = true }
        let events = EventLog()
        let result = try await fake.answer(
            "toolu_w", kind: .approval, value: AgentAnswerValue(answers: ["approval": .one("deny")]), external: FakeClaude.providerSession(identity), events: events
        )
        #expect(result == .requestClosed, "Stop이 이겼다: 사용자의 Deny도 전달로 적지 않는다")
        #expect(await events.wait { FakeClaude.ended($0) })
    }

    // MARK: F2 (s4B) 소켓 시간 초과와 `.delivered`

    /// 훅이 소켓 예산(1.2초)을 넘기면 소켓은 deny를 쓴다. adapter가 그 뒤에 `.delivered`를 적으면 안 된다
    @Test func s4BASocketTimeoutIsNotRecordedAsDelivered() async throws {
        let fake = try FakeClaude()
        try fake.scenario(["runs": [
            ["steps": [["tool": "mcp__tf__ask_user", "id": "toolu_q", "input": FakeClaude.askColor]]],
            ["final_text": "Got it."],
        ]])
        let first = EventLog()
        let identity = try await fake.turn(events: first)
        #expect(await first.wait { FakeClaude.ended($0) })
        let events = EventLog()
        events.before { event in if case .progress = event { try? await Task.sleep(for: .milliseconds(1500)) } }
        let result = try await fake.answer(
            "toolu_q", kind: .input, value: AgentAnswerValue(answers: ["color": .one("red")]), external: FakeClaude.providerSession(identity), events: events
        )
        #expect(result == .requestClosed, "Claude는 deny를 받았다")
        #expect(await events.wait { FakeClaude.ended($0) })
        #expect((fake.report(1)?["decisions"] as? [[String: Any]])?.first?["decision"] as? String == "deny")
    }

    // MARK: F3 (s4A) 짧은 비밀값

    /// 8자 미만 비밀 답은 가리개에 들지 않는다: 표식도 켜지 않는다 (같은 앱 실행에서 다음 턴이 막히면 안 된다)
    @Test func s4AShortSecretDoesNotMarkTheSession() async throws {
        let fake = try FakeClaude()
        try fake.scenario(["runs": [
            ["steps": [["tool": "mcp__tf__ask_user", "id": "toolu_secret", "input": ["questions": [["id": "pin", "header": "PIN", "text": "Enter the 6-digit code", "secret": true]]]]]],
            ["final_text": "Stored."],
            ["final_text": "Next ok."],
        ]])
        let first = EventLog()
        let identity = try await fake.turn(events: first)
        #expect(await first.wait { FakeClaude.ended($0) })
        let session = FakeClaude.providerSession(identity)
        let answered = EventLog()
        _ = try await fake.answer("toolu_secret", kind: .input, value: AgentAnswerValue(text: "482913"), external: session, events: answered)
        #expect(await answered.wait { FakeClaude.ended($0) })
        #expect(!fake.state.secretAnswered)
        let next = EventLog()
        _ = try await fake.turn(external: session, events: next)
        #expect(await next.wait { FakeClaude.ended($0) })
        #expect(fake.runCount == 3)
    }

    // MARK: F4 (s4C) 비지 않은 cwd

    /// 승인된 Bash가 세션 cwd에 파일을 남겼다(흉내): 다음 턴 · 닫기가 영구히 막히면 안 된다. 그 파일은 격리 폴더로 옮겨지고 cwd는 다시 빈다
    @Test func s4CANonEmptyCwdIsQuarantinedAndTheSessionGoesOn() async throws {
        let fake = try FakeClaude()
        try fake.scenario(["runs": [["final_text": "ok"], ["final_text": "ok2"], ["final_text": "ok3"]]])
        let first = EventLog()
        let identity = try await fake.turn(events: first)
        #expect(await first.wait { FakeClaude.ended($0) })
        let folder = fake.box.sessionsRoot.appending(path: ClaudeTest.session, directoryHint: .isDirectory)
        try "x".write(to: folder.appending(path: "cwd/out.txt"), atomically: true, encoding: .utf8)
        let session = FakeClaude.providerSession(identity)
        let next = EventLog()
        _ = try await fake.turn(external: session, events: next)
        #expect(await next.wait { FakeClaude.ended($0) })
        // 닫기 spawn 앞에서도 같다
        try "y".write(to: folder.appending(path: "cwd/again.txt"), atomically: true, encoding: .utf8)
        try await fake.process.closeRequest(AgentRequestRef(
            taskID: ClaudeTest.task, sessionID: ClaudeTest.session, requestID: "toolu_x", externalSessionID: session, workspaceRef: fake.workspace
        ))
        #expect(fake.runCount == 3)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "cwd").path).isEmpty)
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("cwd.quarantine-") }
        #expect(quarantined.count == 2)
        let moved = quarantined.flatMap { (try? FileManager.default.contentsOfDirectory(atPath: folder.appending(path: $0).path)) ?? [] }
        #expect(Set(moved) == ["out.txt", "again.txt"])
    }
}
#endif
