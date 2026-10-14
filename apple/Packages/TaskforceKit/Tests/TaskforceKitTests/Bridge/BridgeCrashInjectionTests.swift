#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 효과 사이 죽음 주입 (OA D2b 계약 4.1 K3): 각 단계 뒤 원장을 닫고 새로 열어 2.8 판정이 맞는지 본다. 어느 단계에서 죽어도 명령은 두 번 실행되지 않는다
struct BridgeCrashInjectionTests {
    private struct CrashingWorkspace: WorkspaceResolver {
        let onResolve: @Sendable () async -> Void

        func workspace(forSession sessionID: String, adapter: String) async -> String? {
            await onResolve()
            return "workspace-crash"
        }
    }

    @Test func aCrashAfterLeasedAndBeforeStartIntentNeverRunsAndTheNextRunStartsExactlyOnce() async throws {
        let h = try BridgeHarness(workspace: nil)
        h.workspaces = CrashingWorkspace { [h] in
            // 막 죽은 것처럼 런타임을 버린다: 원장이 닫혀 이후의 쓰기는 모두 실패한다
            await h.runtime.abandonForTest()
        }
        try await h.restart() // resolver를 바꾼 런타임
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        #expect(h.agent.startedTurns.isEmpty, "죽었으니 시작하지 못했다")
        // 새 앱: 같은 파티션, 정상 resolver
        h.workspaces = FixedWorkspace(path: "workspace-ok")
        try await h.restart()
        h.clock.jump(by: 6)
        await h.runtime.tick()
        #expect(await h.eventually { h.agent.startedTurns.count == 1 })
        h.clock.jump(by: 6)
        await h.runtime.tick()
        #expect(h.agent.startedTurns.count == 1)
        #expect(h.server.commandLeaseCount(created.commandID) == 2, "leased 이후 죽었으므로 replay로 첫 실행")
    }

    @Test func aCrashAfterStartIntentAndBeforeTheIdentityIsRecordedFindsTheOrphanByItsMarkerAndNeverRunsAgain() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        await h.registerFirst()
        let created = h.message()
        h.agent.onStart { [h] _ in await h.runtime.abandonForTest() }
        await h.runtime.tick()
        #expect(await h.eventually { h.agent.startedTurns.count == 1 })
        h.agent.onStart(nil)
        // 원장에는 start_intent만 있다 (정체를 적기 전에 죽었다)
        try await h.restart()
        let record = try #require(await h.command(created.commandID))
        #expect(record.state == .startIntent)
        h.clock.jump(by: 6)
        await h.runtime.tick()
        await h.runtime.tick()
        #expect(h.agent.startedTurns.count == 1, "두 번째 실행 0")
        #expect(h.server.commandLeaseCount(created.commandID) == 1)
        #expect(h.agent.terminatedOrphans.count == 1, "marker로 찾은 고아를 끝냈다")
    }

    @Test func aCrashRightAfterAnEventWasAppendedStillDeliversItOnceAfterTheRestart() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(FakeAgentProcess.Script([.accepted, .progress, .wait(100_000)]))
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        #expect(await h.eventually { (try? await h.ledger.task(created.taskID))?.lastSeq == 2 })
        await h.runtime.abandonForTest()
        _ = h.agent.abandon()
        try await h.restart(adapters: [FakeAgentProcess(clock: h.clock.clock)])
        h.clock.jump(by: 6)
        await h.runtime.tick()
        await h.runtime.tick()
        let types = h.server.eventResults.map(\.type)
        #expect(types.filter { $0 == "accepted" }.count == 1 && types.filter { $0 == "progress" }.count == 1, "한 번씩만: \(types)")
        #expect(h.server.commandLeaseCount(created.commandID) == 1)
    }

    @Test func theLedgerIsPrunedAtStartAndHourly() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        var old = BridgeTest.command("c0000000-0000-4000-8000-0000000000aa", state: .settled, at: h.clock.now.addingTimeInterval(-8 * 86400))
        old.reason = "old"
        try await h.ledger.saveCommand(old)
        try await h.restart()
        await h.runtime.tick()
        #expect(try await h.ledger.command(old.commandID) == nil, "시작 때 보관 기한이 지난 끝난 명령을 지운다")
        var older = BridgeTest.command("c0000000-0000-4000-8000-0000000000ab", state: .gone, at: h.clock.now.addingTimeInterval(-8 * 86400 - 3600))
        older.reason = "old"
        try await h.ledger.saveCommand(older)
        await h.runtime.tick()
        #expect(try await h.ledger.command(older.commandID) != nil, "한 시간 안에는 다시 정리하지 않는다")
        h.clock.jump(by: 3601)
        await h.runtime.tick()
        #expect(try await h.ledger.command(older.commandID) == nil)
    }

    // MARK: 모르는 payload 값 (3.3)

    @Test func anUnknownCancelScopeStopsWiderThanLessNeverNarrower() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        await h.registerFirst()
        let running = h.message()
        await h.runtime.tick()
        #expect(await h.eventually { (await h.command(running.commandID))?.state == .accepted })
        h.server.enqueueCancel(bridgeID: h.bridgeID, taskID: running.taskID, scope: "galaxy")
        h.clock.jump(by: 6)
        await h.runtime.tick()
        #expect(await h.eventually { !h.agent.interrupts.isEmpty })
        #expect(h.agent.interrupts.first?.1 == .turnAndProcesses)
    }

    @Test func anUnknownQuestionKindOnAnAnswerIsNotDeliveredAndReportedNotReceived() async throws {
        let h = try BridgeHarness()
        let question = AgentQuestion(providerRequestID: "req-1", kind: .input, structured: false, text: "Name?", items: [AgentQuestionItem(id: "q", header: "", text: "Name?", options: [])])
        h.agent.setScript(.asking(question))
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        await h.settle { (try? await h.ledger.task(created.taskID))?.openRequestID == "req-1" }
        let answer = try #require(h.server.enqueueAnswer(bridgeID: h.bridgeID, taskID: created.taskID, requestID: "req-1", answerText: "x", structured: false, questionKind: "riddle"))
        h.clock.jump(by: 6)
        await h.runtime.tick()
        let acks = h.server.requests("ack").map(\.json).filter { $0["command_id"] as? String == answer.commandID }
        #expect(acks.map { $0["op"] as? String } == ["lease", "readback"])
        #expect(acks.last?["result"] as? String == "not_received" && acks.last?["process_ended"] as? Bool == true)
        #expect(h.agent.deliveredAnswers.isEmpty)
    }
}
#endif
