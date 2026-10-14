#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 독립 검토 반영 3 (OA D2b 마지막 작은 커밋): security P3-1 task id를 다른 세션이 다시 쓰는 경우, code P3 열린 질문이 있는 task를 보관 정리가 지우는 경우 (검토자 E8)
struct BridgeReviewFTests {
    private static let s1 = BridgeHarness.sessionID
    private static let s2 = "5e551011-0000-4000-8000-0000000000f2"
    private static let taskT = "7a5c0001-0000-4000-8000-0000000000f1"

    private func reports(_ h: BridgeHarness, _ commandID: String) -> [String] {
        h.server.requests("ack").map(\.json).filter { $0["command_id"] as? String == commandID }.map { "\($0["op"] ?? "-") \($0["result"] ?? "-")" }
    }

    /// S1이 T로 이 Mac이 고른 폴더에서 한 턴을 끝냈다
    private func finishedTurnOfS1(_ h: BridgeHarness) async throws {
        h.workspaces = FixedWorkspace(path: "/picked/S1", authorized: [])
        try await h.restart(reopenLedger: false)
        h.agent.setScript(.normal(bind: ("ext-1", "/picked/S1")))
        await h.registerFirst()
        h.message(session: Self.s1, task: Self.taskT)
        await h.runtime.tick()
        await h.settle { h.server.taskState(Self.taskT) == "idle" }
        #expect(await h.task(Self.taskT)?.workspaceRef == "/picked/S1")
    }

    // MARK: security P3-1 — 이미 있는 task id를 다른 세션이 쓰려 한다

    @Test func aTaskIdReusedByAnotherSessionIsRefusedAndRecordsNothingForIt() async throws {
        let h = try BridgeHarness(workspace: nil)
        try await finishedTurnOfS1(h)
        h.server.ensureSession(id: Self.s2, bridgeID: h.bridgeID, externalSessionID: "ext-2", workspaceRef: "/picked/S1")
        let reuse = h.message(session: Self.s2, task: Self.taskT, turn: 2)
        h.clock.jump(by: 6)
        await h.runtime.tick()
        #expect(h.agent.startedTurns.count == 1, "다른 세션이 쓰려는 task로는 띄우지 않는다")
        #expect(await h.command(reuse.commandID)?.reason == "task_session_mismatch")
        #expect(reports(h, reuse.commandID).contains("readback not_received"), "\(reports(h, reuse.commandID))")
        let task = try #require(await h.task(Self.taskT))
        #expect(task.agentSessionID == Self.s1 && task.workspaceRef == "/picked/S1" && task.turnSeq == 1, "S1의 task 기록은 그대로다")
        let forS2 = try await h.ledger.allTasks().filter { $0.agentSessionID == Self.s2 }
        #expect(forS2.isEmpty, "S2에 기록된 폴더 · task가 없다")
    }

    @Test func aStopOrAnAnswerFromAnotherSessionNeverTouchesTheTaskOfTheFirst() async throws {
        let h = try BridgeHarness()
        let question = AgentQuestion(providerRequestID: "req-1", kind: .input, structured: false, text: "Name?", items: [AgentQuestionItem(id: "q", header: "", text: "Name?", options: [])])
        h.agent.setScript(.asking(question))
        await h.registerFirst()
        h.message(session: Self.s1, task: Self.taskT)
        await h.runtime.tick()
        await h.settle { (try? await h.ledger.task(Self.taskT))?.openRequestID == "req-1" }
        // 서버가 task T를 S2의 것으로 바꿔 말한다
        h.server.ensureSession(id: Self.s2, bridgeID: h.bridgeID)
        h.server.reassignTask(Self.taskT, toSession: Self.s2)
        let answer = try #require(h.server.enqueueAnswer(bridgeID: h.bridgeID, taskID: Self.taskT, requestID: "req-1", answerText: "x", structured: false))
        let stop = try #require(h.server.enqueueCancel(bridgeID: h.bridgeID, taskID: Self.taskT))
        h.clock.jump(by: 6)
        await h.runtime.tick()
        #expect(h.agent.deliveredAnswers.isEmpty, "다른 세션의 답을 S1의 질문에 전달하지 않는다")
        #expect(h.agent.interrupts.isEmpty, "다른 세션의 Stop이 S1의 실행을 멈추지 않는다")
        #expect(await h.command(answer.commandID)?.reason == "task_session_mismatch")
        #expect(await h.command(stop.commandID)?.reason == "task_session_mismatch")
        #expect(await h.task(Self.taskT)?.openRequestID == "req-1", "S1의 열린 질문은 그대로다")
    }

    // lease를 거치지 않고 실행 함수를 바로 부른다: 실행 쪽에도 같은 검사가 있다 (applyLease가 먼저 막으므로 따로 시험한다)

    private func message(session: String, task: String) throws -> BridgeV1MessageCommand {
        let json = """
        {"id":"c2222222-2222-4222-8222-2222222222f1","kind":"message","agent_session_id":"\(session)","agent_task_id":"\(task)","turn_seq":2,"step_id":"57e90001-0000-4000-8000-000000000001",
         "adapter":"agent:claude-code","marker":"\(UUID().uuidString.lowercased())","session":{"external_session_id":null,"workspace_ref":null,"resume":false},
         "access":"write","policy_mode":"manual","message":{"id":"3e550001-0000-4000-8000-000000000001","text":"hi"},"close_before":null}
        """
        return try TaskforceJSON.decoder().decode(BridgeV1MessageCommand.self, from: Data(json.utf8))
    }

    private func answer(session: String, task: String) throws -> BridgeV1AnswerCommand {
        let json = """
        {"id":"c2222222-2222-4222-8222-2222222222f2","kind":"answer","agent_session_id":"\(session)","agent_task_id":"\(task)","turn_seq":2,"step_id":"57e90001-0000-4000-8000-000000000002",
         "adapter":"agent:claude-code","marker":"\(UUID().uuidString.lowercased())","session":{"external_session_id":null,"workspace_ref":null,"resume":false},
         "access":"write","policy_mode":"manual","provider_request_id":"req-1","question_kind":"input","structured":false,"answers":null,"answer_text":"x","answered_locally":false}
        """
        return try TaskforceJSON.decoder().decode(BridgeV1AnswerCommand.self, from: Data(json.utf8))
    }

    @Test func runMessageItselfRefusesATaskOfAnotherSession() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        var task = BridgeTest.task(Self.taskT, session: Self.s1, at: h.clock.now)
        task.workspaceRef = "workspace-test"
        try await h.ledger.saveTask(task)
        let command = try message(session: Self.s2, task: Self.taskT)
        let record = BridgeTest.command("c2222222-2222-4222-8222-2222222222f1", session: Self.s2, task: Self.taskT, state: .leased, at: h.clock.now)
        await h.runtime.runMessage(command, record: record)
        #expect(h.agent.startedTurns.isEmpty)
        // 서버는 이 명령을 모르므로 거절 이유는 ack 정산(404)이 덮는다: 거절했다는 증거는 결과 확인 ack다
        #expect(reports(h, record.commandID) == ["readback not_received"], "\(reports(h, record.commandID))")
    }

    @Test func runAnswerItselfRefusesATaskOfAnotherSession() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        var task = BridgeTest.task(Self.taskT, session: Self.s1, at: h.clock.now)
        task.workspaceRef = "workspace-test"
        task.openRequestID = "req-1"
        task.openRequestKind = "input"
        task.lastState = "awaiting_answer"
        try await h.ledger.saveTask(task)
        let command = try answer(session: Self.s2, task: Self.taskT)
        let record = BridgeTest.command("c2222222-2222-4222-8222-2222222222f2", kind: "answer", session: Self.s2, task: Self.taskT, state: .leased, at: h.clock.now)
        await h.runtime.runAnswer(command, record: record)
        #expect(h.agent.deliveredAnswers.isEmpty)
        #expect(reports(h, record.commandID) == ["readback not_received"], "\(reports(h, record.commandID))")
    }

    @Test func aTaskOfTheSameSessionIsStillRun() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        h.message(session: Self.s1, task: Self.taskT)
        await h.runtime.tick()
        await h.settle { h.server.taskState(Self.taskT) == "idle" }
        h.message(session: Self.s1, task: Self.taskT, turn: 2)
        h.clock.jump(by: 6)
        await h.runtime.tick()
        #expect(await h.eventually { h.agent.startedTurns.count == 2 }, "같은 세션이 같은 task로 이어 가는 것은 막지 않는다")
    }

    // MARK: code P3 — 열린 질문이 있는 task는 보관 정리가 지우지 않는다 (E8)

    @Test func aQuestionAnsweredAfterEightDaysIsStillDelivered() async throws {
        let h = try BridgeHarness()
        let question = AgentQuestion(providerRequestID: "req-1", kind: .input, structured: false, text: "Name?", items: [AgentQuestionItem(id: "q", header: "", text: "Name?", options: [])])
        h.agent.setScript(FakeAgentProcess.Script([.sessionBound(external: "fake-session-1", workspace: "workspace-fake"), .accepted, .question(question), .end(AgentExit(code: 0))]))
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        await h.settle { let t = try? await h.ledger.task(created.taskID); return t?.openRequestID == "req-1" && t?.alive == false }
        h.clock.jump(by: 1)
        await h.runtime.tick()
        // 한 주 내내 켜져 있었다: 8일째 보관 정리가 돈다
        let report = try await h.ledger.prune(now: h.clock.now.addingTimeInterval(8 * 86400))
        #expect(report.tasks == 0, "열린 질문이 있는 task는 지우지 않는다")
        #expect(await h.task(created.taskID)?.openRequestID == "req-1")
        _ = h.server.enqueueAnswer(bridgeID: h.bridgeID, taskID: created.taskID, requestID: "req-1", answerText: "x", structured: false)
        h.clock.jump(by: 6)
        await h.runtime.tick()
        #expect(await h.eventually { h.agent.deliveredAnswers.count == 1 }, "일주일 넘게 열려 있던 질문의 답도 전달된다 (request_closed가 아니다)")
    }

    @Test func pruneKeepsAnAwaitingAnswerTaskWithAnOpenRequestButNotOneWithout() async throws {
        let dir = TempDirectory()
        let ledger = try BridgeLedger(directory: dir.appending("p"), now: { BridgeTest.t0 })
        let old = BridgeTest.t0.addingTimeInterval(-8 * 86400)
        var open = BridgeTest.task("7a5c0001-0000-4000-8000-000000000021", session: "5e551011-0000-4000-8000-000000000021", at: old)
        open.lastState = "awaiting_answer"
        open.openRequestID = "req-1"
        var closed = BridgeTest.task("7a5c0001-0000-4000-8000-000000000022", session: "5e551011-0000-4000-8000-000000000022", at: old)
        closed.lastState = "awaiting_answer"
        var cancelledWithOpen = BridgeTest.task("7a5c0001-0000-4000-8000-000000000023", session: "5e551011-0000-4000-8000-000000000023", at: old)
        cancelledWithOpen.lastState = "cancelled"
        cancelledWithOpen.openRequestID = "req-2"
        for task in [open, closed, cancelledWithOpen] { try await ledger.saveTask(task) }
        let report = try await ledger.prune(now: BridgeTest.t0)
        #expect(report.tasks == 2, "열린 질문이 없는 것과 취소로 닫은 것은 지운다")
        #expect(try await ledger.allTasks().map(\.agentTaskID) == [open.agentTaskID])
    }
}
#endif
