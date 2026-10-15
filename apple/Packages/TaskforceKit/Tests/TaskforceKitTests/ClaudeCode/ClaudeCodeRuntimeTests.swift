#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 런타임(D2b) + Claude Code adapter + 가짜 `claude` + 가짜 bridge 서버 (OA D3a 계약 4.3 E13 · E15, Q5 · 2.11).
/// 원장 · 세션 폴더 · 로그 · 서버 요청을 함께 본다
@Suite(.serialized)
struct ClaudeCodeRuntimeTests {
    func harness(_ fake: FakeClaude) async throws -> BridgeHarness {
        let harness = try BridgeHarness(withAdapter: false, workspace: fake.workspace)
        try await harness.restart(adapters: [fake.process], reopenLedger: false)
        // 런타임이 붙인 결정기(가짜 서버는 tool-decision을 모른다) 대신 대본 결정기
        fake.process.attach(AgentRuntimeServices(decideTool: fake.decider.function))
        await harness.registerFirst()
        return harness
    }

    // MARK: E13 init 전 · 뒤 죽음 (Q5, G31)

    func deathReadback(_ die: String) async throws -> (ReadbackDecision, BridgeCommandRecord?) {
        let fake = try FakeClaude()
        try fake.scenario(["runs": [["die": die, "steps": [["text": "never"]]]]])
        let h = try await harness(fake)
        let created = h.message("Hi")
        await h.runtime.tick()
        #expect(await h.eventually { fake.runCount == 1 })
        #expect(await h.eventually {
            let alive = await h.task(created.taskID)?.alive
            let rank = await h.command(created.commandID)?.state.rank
            return alive == false && (rank ?? 0) >= (BridgeCommandState.ended.rank ?? 7)
        })
        let command = await h.command(created.commandID)
        let facts = await h.runtime.readbackFacts(source: .readbackList, command: command)
        return (Reconcile.readback(facts), command)
    }

    @Test func e13ADeathBeforeInitIsNotReceived() async throws {
        let (decision, command) = try await deathReadback("before_init")
        #expect(command?.inputAt == nil)
        #expect(decision == .report(.notReceived, processEnded: true))
    }

    @Test func e13ADeathAfterInitIsUnknownBecauseTheCLIMayHaveTheMessage() async throws {
        let (decision, command) = try await deathReadback("after_init")
        #expect(command?.inputAt != nil, "init을 본 시각이 명령 inputAt에 적힌다 (inputReached)")
        #expect(command?.spawnAt != nil)
        #expect(decision == .report(.unknown, processEnded: false))
    }

    @Test func inputReachedIsLocalOnlyAndNeverAServerEvent() async throws {
        let fake = try FakeClaude()
        try fake.scenario(["runs": [["steps": [["text": "Done"]]]]])
        let h = try await harness(fake)
        let created = h.message("Hi")
        await h.runtime.tick()
        await h.settle { h.server.taskState(created.taskID) == "idle" }
        let types = h.server.requests("events").flatMap { ($0.json["events"] as? [[String: Any]]) ?? [] }.compactMap { $0["type"] as? String }
        #expect(types.contains("accepted") && types.contains("session_bound") && types.contains("turn_completed"))
        #expect(!types.contains("input_reached") && !types.contains("inputReached"))
        #expect(await h.command(created.commandID)?.inputAt != nil)
    }

    // MARK: E15 비밀값 카나리 (G30)

    @Test func e15ASecretAnswerReachesTheModelButNeverTheSessionFolderLedgerLogsOrServer() async throws {
        let fake = try FakeClaude()
        let ask: [String: Any] = ["questions": [["id": "key", "header": "Key", "text": "Paste the API key", "secret": true]]]
        // 답 뒤에 모델이 값을 되말하고, 그 값을 명령에 넣는다 (8장 11 · 9장 1 · 2): 밖으로 나가는 글에서는 가리고, 가린 명령은 서버에 묻지 않고 승인 카드로.
        // 승인 → 두 번째 명령 · 메시지 → 다음 턴까지 같은 세션의 가리개가 덮는다
        try fake.scenario(["runs": [
            ["steps": [["tool": "mcp__tf__ask_user", "id": "toolu_secret", "input": ask]]],
            ["steps": [["text": "Your key CANARY-SECRET-7f3a works."], ["tool": "Bash", "id": "toolu_c1", "input": ["command": "printf %s 'X-Key: CANARY-SECRET-7f3a' >/dev/null"]]]],
            ["steps": [["text": "Second CANARY-SECRET-7f3a"], ["tool": "Bash", "id": "toolu_c2", "input": ["command": "echo CANARY-SECRET-7f3a >/dev/null"]]]],
            ["final_text": "Again CANARY-SECRET-7f3a"],
        ]])
        let h = try await harness(fake)
        let created = h.message("SENTINEL-USER-MESSAGE-d3a")
        await h.runtime.tick()
        await h.settle { (try? await h.ledger.task(created.taskID))?.openRequestID == "toolu_secret" }
        #expect(try await h.ledger.task(created.taskID)?.openRequestSecret == true)
        await h.secrets.put(requestID: "toolu_secret", value: AgentAnswerValue(text: "CANARY-SECRET-7f3a"))
        h.server.enqueueAnswer(bridgeID: h.bridgeID, taskID: created.taskID, requestID: "toolu_secret", locally: true, structured: true)
        h.clock.jump(by: 6)
        await h.runtime.tick()
        await h.settle { h.server.requests.contains { $0.bodyJSON.contains("Run: printf") } }
        // 모델에는 닿았다 (가짜의 MCP 결과 = Claude Code transcript 쪽, Q9)
        #expect((fake.report(1)?["mcp_results"] as? [String])?.first == #"The user answered: {"key":"CANARY-SECRET-7f3a"}"#)
        // 승인 → 두 번째 명령 · 메시지
        await h.settle { (try? await h.ledger.task(created.taskID))?.openRequestID == "toolu_c1" }
        h.server.enqueueAnswer(bridgeID: h.bridgeID, taskID: created.taskID, requestID: "toolu_c1", answers: ["approval": "Allow"], questionKind: "approval")
        h.clock.jump(by: 6)
        await h.runtime.tick()
        await h.settle { h.server.requests.contains { $0.bodyJSON.contains("Second ") } && h.server.requests.contains { $0.bodyJSON.contains("Run: echo") } }
        // 거절로 닫고 다음 턴
        await h.settle { (try? await h.ledger.task(created.taskID))?.openRequestID == "toolu_c2" }
        h.server.enqueueAnswer(bridgeID: h.bridgeID, taskID: created.taskID, requestID: "toolu_c2", answers: ["approval": "Deny"], questionKind: "approval")
        h.clock.jump(by: 6)
        await h.runtime.tick()
        await h.settle(timeout: 15) { h.server.taskState(created.taskID) == "idle" }
        let next = h.message("Next", task: "7a5c0001-0000-4000-8000-0000000000e2", turn: 2)
        h.clock.jump(by: 6)
        await h.runtime.tick()
        await h.settle(timeout: 15) { h.server.taskState(next.taskID) == "idle" }
        // 되말한 글 · 승인 카드 글에서는 가렸고, 가린 명령은 서버에 묻지 않았다
        let bodies = h.server.requests.map(\.bodyJSON).joined(separator: "\n")
        #expect(bodies.contains("Your key [redacted] works."))
        #expect(bodies.contains(#"Run: printf %s 'X-Key: [redacted]' >\/dev\/null\n"# + ClaudeCardReason.secretInCommand), "JSON 본문은 /를 \\/로, 줄바꿈을 \\n으로 쓴다")
        #expect(bodies.contains("Second [redacted]"), "승인 resume의 메시지")
        #expect(bodies.contains(#"Run: echo [redacted] >\/dev\/null"#), "두 번째 명령의 카드")
        #expect(bodies.contains("Again [redacted]"), "다음 턴")
        #expect(fake.decider.calls.isEmpty, "가린 명령은 서버에 묻지 않는다")
        await h.ledger.checkpoint()
        for sentinel in ["CANARY-SECRET-7f3a", "SENTINEL-USER-MESSAGE-d3a"] {
            #expect(!Self.treeContains(sentinel, fake.box.sessionsRoot), "세션 폴더에 \(sentinel) 0")
            #expect(!Self.treeContains(sentinel, h.ledger.directory), "원장에 \(sentinel) 0")
            #expect(!(h.log.lines + fake.log.lines).contains { $0.contains(sentinel) }, "로그에 \(sentinel) 0")
        }
        #expect(!h.server.requests.contains { $0.bodyJSON.contains("CANARY-SECRET-7f3a") }, "서버 요청에 비밀값 0")
        #expect(await h.secrets.hasPending == false)
    }

    /// 폴더 아래 모든 파일 바이트에 글이 있나
    static func treeContains(_ needle: String, _ root: URL) -> Bool {
        let target = Data(needle.utf8)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return false }
        for case let url as URL in walker {
            if let data = try? Data(contentsOf: url), data.range(of: target) != nil { return true }
        }
        return false
    }
}
#endif
