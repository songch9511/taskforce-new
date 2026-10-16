#if os(macOS) && DEBUG
import Darwin
import Foundation
import Synchronization
import Testing
import TaskforceAgentWire
@testable import TaskforceKit

/// 재검토 3 반영 (OA D3a 계약 11장) — 고친 뒤의 API로 보는 시험. 재현은 `ClaudeRereview3ReproTests`. 이름 앞의 `dN`이 11장 항목 번호다
@Suite(.serialized)
struct ClaudeRereview3Tests {
    let box = ClaudeSandbox()

    /// 끝난 프로세스 하나 (지킴이 없이: 정체만)
    func spawn(_ script: String, marker: String = UUID().uuidString) throws -> (process: ClaudeSpawnedProcess, identity: AgentProcessIdentity) {
        let settings = box.root.appending(path: "config/\(marker).settings.json").path
        let process = try ClaudeSpawner.spawn(
            executable: "/bin/sh", arguments: ["-c", script, "sh", "--settings", settings], environment: ["PATH": "/usr/bin:/bin"], cwd: box.root.path
        )
        process.closeStandardStreams()
        return (process, AgentProcessIdentity(pid: Int(process.pid), startedAt: process.startedAt, processMarker: marker))
    }

    // MARK: 1 끝 기록 · purge

    @Test func d1AnEndProvenOnceStaysProvenAndAMissingFileStaysUnknown() async throws {
        let root = try box.keep("exit 0")
        let file = root.file
        #expect(await root.keeperEnded())
        let adapter = ClaudeRereview3ReproTests.adapter(box)
        #expect(await adapter.liveness(root.identity) == .ended(AgentExit(code: nil)))
        // 끝을 확정하면 따로 끝 기록이 남고 혈통 파일 · 지킴이 기록은 지운다 (12장 8): 다시 물어도 끝이다
        let boot = try #require(ClaudeProcessInspector.bootSessionID())
        let ended = ClaudeLineage.endedFile(file)
        #expect(try String(contentsOf: ended, encoding: .utf8) == "taskforce-lineage 4\nboot \(boot)\nended\n")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(await adapter.liveness(root.identity) == .ended(AgentExit(code: nil)))
        try FileManager.default.removeItem(at: ended)
        #expect(await ClaudeRereview3ReproTests.adapter(box).liveness(root.identity) == .unknown, "기록이 사라지면 다시 증명할 수 없다")
    }

    @Test func d1PurgeEndsOnlyConfirmedOtherBootFilesAndNothingWithoutABootID() throws {
        let folder = box.sessionsRoot.appending(path: "lineage", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let boot = try #require(ClaudeProcessInspector.bootSessionID())
        let mine = folder.appending(path: "\(UUID().uuidString).lineage")
        try "taskforce-lineage 4\nboot \(boot)\nkeeper 7 70\nroot 8 80\nresponsible yes\n".write(to: mine, atomically: true, encoding: .utf8)
        let other = folder.appending(path: "\(UUID().uuidString).lineage")
        try "taskforce-lineage 4\nboot \(UUID().uuidString)\nkeeper 7 70\nroot 8 80\nresponsible yes\n".write(to: other, atomically: true, encoding: .utf8)
        let broken = folder.appending(path: "\(UUID().uuidString).lineage")
        try "nonsense\n".write(to: broken, atomically: true, encoding: .utf8)
        ClaudeLineage.purge(directory: folder, boot: nil)
        #expect([mine, other, broken].allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "부팅 id를 못 읽으면 아무것도 바꾸지 않는다")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).allSatisfy { $0.hasSuffix(".lineage") })
        ClaudeLineage.purge(directory: folder)
        #expect(ClaudeLineage.load(mine) == .thisBoot(ClaudeLineage.Record(keeper: ClaudeLineage.Keeper(pid: 70, uniqueID: 7), root: 8, rootPID: 80, attributable: true)))
        #expect(try String(contentsOf: ClaudeLineage.endedFile(other), encoding: .utf8) == "taskforce-lineage 4\nboot \(boot)\nended\n", "다른 부팅 = 끝 기록 (결정 11-1)")
        #expect(!FileManager.default.fileExists(atPath: other.path) && ClaudeLineage.load(other) == .ended)
        #expect(try String(contentsOf: broken, encoding: .utf8) == "nonsense\n", "읽지 못하는 파일은 다른 부팅으로 확인되지 않았다: 그대로")
    }

    // MARK: 결정 11-1 다른 부팅 = 끝

    /// 다시 부팅했다는 것은 그 부팅의 프로세스가 모두 끝났다는 증명이다: 앱이 다시 떠 정리한 뒤에도 그 spawn은 끝이다 (unknown이 아니다)
    @Test func e1AnOtherBootLineageIsEndedAfterARelaunch() async throws {
        let marker = UUID().uuidString
        let root = try spawn("exit 0", marker: marker)
        _ = try await offPool { root.process.waitForExit() }
        let file = box.sessionsRoot.appending(path: "lineage/\(marker).lineage")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "taskforce-lineage 4\nboot \(UUID().uuidString)\nkeeper 7 70\nroot 8 80\nresponsible yes\n".write(to: file, atomically: true, encoding: .utf8)
        let adapter = ClaudeRereview3ReproTests.adapter(box)
        adapter.purgeLineageOfOtherBoots()
        #expect(await adapter.liveness(root.identity) == .ended(AgentExit(code: nil)))
        #expect(await adapter.terminateOrphan(root.identity) == .ended(AgentExit(code: nil)))
        #expect(await adapter.liveness(root.identity) == .ended(AgentExit(code: nil)), "다시 물어도 끝")
    }

    /// 부팅 id를 읽지 못하면 아무것도 바꾸지 않고, 그 파일로는 끝을 증명하지 못한다 (unknown 그대로)
    @Test func e2WithoutABootIDNothingChangesAndUnknownStays() async throws {
        let marker = UUID().uuidString
        let root = try spawn("exit 0", marker: marker)
        _ = try await offPool { root.process.waitForExit() }
        let file = box.sessionsRoot.appending(path: "lineage/\(marker).lineage")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = "taskforce-lineage 4\nboot \(UUID().uuidString)\nkeeper 7 70\nroot 8 80\nresponsible yes\n"
        try text.write(to: file, atomically: true, encoding: .utf8)
        ClaudeLineage.purge(directory: file.deletingLastPathComponent(), boot: nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == text, "바꾼 것 0")
        #expect(ClaudeProcessInspector.liveness(root.identity, lineage: ClaudeLineage(file: file, boot: { nil })) == .unknown)
    }

    // MARK: 3 잘린 줄

    @Test func d3ACutLastLineIsNotTrusted() throws {
        let file = box.root.appending(path: "lineage/cut.lineage")
        let lineage = ClaudeLineage(file: file, fresh: true)
        lineage.adopt(ClaudeLineage.Record(keeper: ClaudeLineage.Keeper(pid: 70, uniqueID: 7), root: 8, rootPID: 80, attributable: true))
        #expect(lineage.save() && ClaudeLineage(file: file).hasEvidence)
        // 쓰다 끊긴 마지막 줄(줄바꿈 없음): 파일 전체가 증거 없음 (12장 5, 잘린 줄을 버리고 믿지 않는다)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("4559".utf8))
        try handle.close()
        let loaded = ClaudeLineage(file: file)
        #expect(!loaded.hasEvidence && loaded.keeper == nil)
    }

    // MARK: 6 마지막 await 뒤 확정

    @Test func d6AStopAtTheFinalReturnBoundaryDeniesWithoutAnswersAndClosesTheRequest() async throws {
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
            "toolu_w", kind: .approval, value: AgentAnswerValue(answers: ["approval": .one("allow")]), external: FakeClaude.providerSession(identity), events: events
        )
        #expect(result == .requestClosed, "Stop이 이겼다: 전달로 적지 않는다")
        #expect(await events.wait { FakeClaude.ended($0) })
        #expect((fake.report(1)?["decisions"] as? [[String: Any]])?.first?["decision"] as? String == "deny")
    }

    // MARK: 8 셸 풀기 한 번

    @Test func d8OnePassJoinsContinuationsOutsideAndInsideDoubleQuotesAndDecodesANSIC() {
        let bs = ClaudeRereview3ReproTests.bs
        #expect(SecretRedactor.shellUnquoted("a" + bs + "\nb") == "ab", "따옴표 밖 줄 이음")
        #expect(SecretRedactor.shellUnquoted("\"a" + bs + "\nb\"") == "ab", "큰따옴표 안 줄 이음")
        #expect(SecretRedactor.shellUnquoted("'a" + bs + "\nb'") == "a" + bs + "\nb", "작은따옴표 안은 그대로")
        #expect(SecretRedactor.shellUnquoted("$'" + bs + "x41" + bs + "102" + bs + "u0043" + bs + "U00000044" + bs + "t'") == "ABCD\t", "ANSI-C")
        #expect(SecretRedactor.shellUnquoted("$'" + bs + "xC3" + bs + "xA9'") == "é", "ANSI-C 바이트는 UTF-8로 읽는다")
    }

    // MARK: 7 결정표: 정규화 전 글자

    @Test func d7ACommandWithTheSecretFollowedByACombiningMarkGoesToTheLocalCard() async throws {
        let cwd = box.sessionsRoot.appending(path: "\(ClaudeTest.session)/cwd", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let decider = ScriptedDecider([.success(ScriptedDecider.response(.allow, .policyAuto))])
        let context = ClaudeGateContext(
            mode: .normal, access: .write, workspaceRealPath: box.workspacePath, sessionCwdRealPath: cwd.path, childPATH: "/usr/bin:/bin", agentSessionID: ClaudeTest.session,
            agentTaskID: ClaudeTest.task, turnSeq: 1, deferIssued: false, answerDelivered: false, secrets: SecretRedactor(["password-é"])
        )
        let outcome = await ClaudeToolGate(fileSystem: .live, decide: decider.function, serverTimeout: .seconds(30))
            .evaluate(ClaudeTest.request("Bash", .object(["command": .string("curl -u admin:password-é\u{0323} https://x.example")]), cwd: cwd.path), context: context)
        #expect(outcome.code == "secret_in_command")
        #expect(decider.calls.isEmpty)
    }
}
#endif
