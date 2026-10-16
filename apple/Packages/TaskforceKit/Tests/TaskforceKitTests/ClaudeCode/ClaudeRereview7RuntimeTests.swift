#if os(macOS) && DEBUG
import Foundation
import Synchronization
import Testing
@testable import TaskforceKit

/// 재검토 7 — 런타임 쪽 (OA D3a 16장 1 · 4 · 6, Astra P1 · sec F1 · F3): 닫기 spawn은 시작부터 생존 판단에 들고, Quit · 앱 종료는 감독 밖 실행까지 세션마다 잠금의
/// 지금 실행을 끝내며, 종료 뒤에는 띄우지 않는다. 접수 전 실패도 잠금으로 정하고, 끝난 고아는 다음 tick에 끝 정산한다. 잠금이 말하는 것을 시험이 정한다
final class GatedRunAdapter: AgentProcess, @unchecked Sendable {
    static let none = AgentSessionRun(liveness: .ended(AgentExit(code: nil)), identity: nil)
    let adapter = "agent:claude-code"
    let current = Mutex<AgentSessionRun>(GatedRunAdapter.none)
    /// 닫기가 띄우는 실행과 그 결과: `hold`면 끝날 때까지(앱이 끝내거나 시험이 풀 때까지) 기다린다
    enum ClosePlan { case succeed, fail, hold }
    let closePlan = Mutex<ClosePlan>(.succeed)
    let closeGate = Mutex<CheckedContinuation<Void, Never>?>(nil)
    let closeStarted = Mutex(0)
    /// 턴이 정체 없이 실패한다 (잠금이 끝나지 않았으면 다음 writer를 띄우지 않는 adapter처럼)
    let turnFailsWithoutLeft = Mutex(false)
    let internalClose = Mutex<AgentSessionRun?>(nil)
    let startedTurns = Mutex(0)
    let interrupts = Mutex<[String]>([])
    let terminatedSessions = Mutex<[String]>([])
    let spawningStopped = Mutex(false)
    let turn = AgentProcessIdentity(pid: nil, startedAt: Date(timeIntervalSince1970: 1), processMarker: UUID().uuidString)

    static func run(_ liveness: AgentLiveness) -> AgentSessionRun {
        AgentSessionRun(liveness: liveness, identity: AgentProcessIdentity(pid: nil, startedAt: Date(timeIntervalSince1970: 2), processMarker: UUID().uuidString))
    }

    func probe() async -> BridgeV1AdapterReport {
        BridgeV1AdapterReport(adapter: adapter, installed: true, version: "2.1.241", signedIn: .yes, managedSettings: false)
    }

    func startTurn(_ turn: AgentTurnStart, events: AgentEventSink) async throws -> AgentProcessIdentity {
        startedTurns.withLock { $0 += 1 }
        if turnFailsWithoutLeft.withLock({ $0 }) { throw AgentStartError(.spawnFailed) }
        await events.emit(.sessionBound(externalSessionID: "c0ffee00-0000-4000-8000-000000000001", workspaceRef: turn.workspaceRef))
        await events.emit(.accepted)
        await events.emit(.question(AgentQuestion(providerRequestID: "req-1", kind: .input, structured: false, text: "Name?", items: [
            AgentQuestionItem(id: "q", header: "", text: "Name?", options: []),
        ])))
        var identity = self.turn
        identity.externalTaskID = "s:1"
        if let close = internalClose.withLock({ $0 }) {
            current.withLock { $0 = AgentSessionRun(liveness: .alive, identity: identity) }
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                self.current.withLock { $0 = close }
                await events.emit(.ended(AgentExit(code: 0)))
            }
            return identity
        }
        await events.emit(.ended(AgentExit(code: 0)))
        return identity
    }

    let deliveredAnswers = Mutex(0)

    func deliverAnswer(_ answer: AgentAnswerDelivery, events: AgentEventSink) async throws -> AgentAnswerResult {
        deliveredAnswers.withLock { $0 += 1 }
        return .requestClosed
    }

    func closeRequest(_ request: AgentRequestRef) async throws {
        let close = Self.run(.alive)
        current.withLock { $0 = close }
        closeStarted.withLock { $0 += 1 }
        switch closePlan.withLock({ $0 }) {
        case .succeed:
            current.withLock { $0 = Self.none }
        case .fail:
            // 끝내지 못한 닫기 실행이 살아 남았다
            throw AgentStartError(.agentError, left: close.identity)
        case .hold:
            await withCheckedContinuation { continuation in closeGate.withLock { $0 = continuation } }
            throw AgentStartError(.agentError)
        }
    }

    /// 닫기가 기다리고 있으면 풀어 준다 (그 실행이 끝났다)
    func releaseClose() {
        closeGate.withLock {
            $0?.resume()
            $0 = nil
        }
    }

    func interrupt(_ target: AgentTurnRef, scope: AgentCancelScope) async -> AgentInterruptResult {
        interrupts.withLock { $0.append(target.sessionID) }
        return .signalled
    }

    func liveness(_ identity: AgentProcessIdentity) async -> AgentLiveness {
        let run = current.withLock { $0 }
        return run.identity?.processMarker == identity.processMarker ? run.liveness : .ended(AgentExit(code: nil))
    }

    func terminateOrphan(_ identity: AgentProcessIdentity) async -> AgentLiveness { await liveness(identity) }
    func sessionRun(_ sessionID: String) async -> AgentSessionRun? { current.withLock { $0 } }

    /// 앱이 그 세션의 지금 실행을 끝냈다: 끝을 증명한다 (기다리던 닫기도 끝난다)
    func terminateSessionRun(_ sessionID: String) async -> AgentLiveness {
        terminatedSessions.withLock { $0.append(sessionID) }
        current.withLock { $0 = Self.none }
        releaseClose()
        return .ended(AgentExit(code: nil))
    }

    func stopSpawning() async { spawningStopped.withLock { $0 = true } }
}

@Suite(.serialized)
struct ClaudeRereview7RuntimeTests {
    func harness(_ adapter: GatedRunAdapter) async throws -> BridgeHarness {
        let harness = try BridgeHarness(withAdapter: false)
        try await harness.restart(adapters: [adapter], reopenLedger: false)
        await harness.registerFirst()
        return harness
    }

    func ask(_ h: BridgeHarness) async -> String {
        let created = h.message("Hi")
        await h.runtime.tick()
        await h.settle { let t = try? await h.ledger.task(created.taskID); return t?.openRequestID == "req-1" && t?.alive == false }
        return created.taskID
    }

    /// 비밀 답이 메모리에 없어 그 요청을 닫는다 (닫기 spawn 하나). 닫기가 기다리면(`hold`) 그 tick은 따로 돈다
    @discardableResult
    func closeLostSecret(_ h: BridgeHarness, _ task: String, holding: Bool = false) async throws -> FakeBridgeServer.Created {
        let answer = try #require(h.server.enqueueAnswer(bridgeID: h.bridgeID, taskID: task, requestID: "req-1", locally: true, structured: false))
        h.clock.jump(by: 6)
        if holding {
            let runtime = h.runtime
            Task { await runtime.tick() }
        } else {
            await h.runtime.tick()
        }
        return answer
    }

    /// 3초 유예를 실제 시간 안에 넘기도록 시계를 민다
    func advancing(_ h: BridgeHarness) -> Task<Void, Never> {
        Task {
            for _ in 0..<200 {
                if Task.isCancelled { return }
                await h.clock.advance(by: 0.25)
                try? await Task.sleep(for: .milliseconds(3))
            }
        }
    }

    // MARK: 1 (Astra P1) 닫기 spawn은 시작부터 · Quit은 잠금의 지금 실행까지

    /// 닫기가 도는 동안(원장 `alive=false` · 감독 0)에도 살아 있는 프로세스가 있다고 알린다: Quit이 확인 없이 바로 끝내지 않는다
    @Test func p1ACloseInFlightCountsAsALiveProcess() async throws {
        let adapter = GatedRunAdapter()
        let h = try await harness(adapter)
        let task = await ask(h)
        adapter.closePlan.withLock { $0 = .hold }
        try await closeLostSecret(h, task, holding: true)
        #expect(await h.eventually { adapter.closeStarted.withLock { $0 } == 1 })
        #expect(await h.task(task)?.alive == false, "시험 전제: 원장은 끝났다고 한다")
        #expect(await h.runtime.hasLiveProcess(), "닫기 spawn은 시작부터 생존 판단에 든다")
        adapter.releaseClose()
    }

    /// Quit: 도는 닫기는 유예 뒤 세션의 지금 실행으로 끝내고 끝을 증명한다. 종료가 시작되면 adapter도 띄우기를 멈춘다
    @Test func p1QuitEndsACloseInFlight() async throws {
        let adapter = GatedRunAdapter()
        let h = try await harness(adapter)
        let task = await ask(h)
        adapter.closePlan.withLock { $0 = .hold }
        try await closeLostSecret(h, task, holding: true)
        #expect(await h.eventually { adapter.closeStarted.withLock { $0 } == 1 })
        let worker = advancing(h)
        await h.runtime.shutdown(interrupt: true)
        worker.cancel()
        adapter.releaseClose()
        #expect(adapter.spawningStopped.withLock { $0 })
        #expect(adapter.terminatedSessions.withLock { $0 } == [BridgeHarness.sessionID])
        #expect(await h.task(task)?.alive == false)
    }

    /// Quit: 닫기가 끝을 증명하지 못해 남긴 고아(감독 밖)도 끝낸다
    @Test func p1QuitEndsAnOrphanLeftByAFailedClose() async throws {
        let adapter = GatedRunAdapter()
        let h = try await harness(adapter)
        let task = await ask(h)
        adapter.closePlan.withLock { $0 = .fail }
        _ = try await closeLostSecret(h, task)
        #expect(await h.eventually { await h.task(task)?.alive == true }, "시험 전제: 고아")
        let worker = advancing(h)
        await h.runtime.shutdown(interrupt: true)
        worker.cancel()
        #expect(adapter.terminatedSessions.withLock { $0 } == [BridgeHarness.sessionID])
        #expect(await h.task(task)?.alive == false)
    }

    /// Quit: 내부 닫기가 끝을 증명하지 못해 턴의 끝 사건 뒤에 남은 실행도 끝낸다
    @Test func p1QuitEndsARunLeftByAnInternalClose() async throws {
        let adapter = GatedRunAdapter()
        adapter.internalClose.withLock { $0 = GatedRunAdapter.run(.unknown) }
        let h = try await harness(adapter)
        let created = h.message("Hi")
        await h.runtime.tick()
        #expect(await h.eventually {
            let record = await h.task(created.taskID)
            let fact = await h.runtime.processFact(for: created.taskID, task: record)
            return record?.openRequestID == "req-1" && fact == .unverifiedOrphan
        })
        let worker = advancing(h)
        await h.runtime.shutdown(interrupt: true)
        worker.cancel()
        #expect(adapter.terminatedSessions.withLock { $0 } == [BridgeHarness.sessionID])
        #expect(await h.task(created.taskID)?.alive == false)
    }

    /// 종료가 시작된 뒤에는 새 실행을 띄우지 않는다 (명령은 lease하지 않고, 닫기도 하지 않는다)
    @Test func p1NothingIsSpawnedAfterShutdownBegins() async throws {
        let adapter = GatedRunAdapter()
        let h = try await harness(adapter)
        let task = await ask(h)
        let worker = advancing(h)
        await h.runtime.shutdown(interrupt: true)
        worker.cancel()
        await h.runtime.resume()
        let next = h.message("Again", task: UUID().uuidString.lowercased(), turn: 2)
        try await closeLostSecret(h, task)
        _ = h.server.enqueueCancel(bridgeID: h.bridgeID, taskID: task, abandoned: "req-1")
        h.clock.jump(by: 6)
        await h.runtime.tick()
        try await Task.sleep(for: .milliseconds(200))
        #expect(adapter.startedTurns.withLock { $0 } == 1, "첫 턴만")
        #expect(adapter.closeStarted.withLock { $0 } == 0, "닫기 0 (Stop의 버린 요청 닫기도)")
        #expect(await h.command(next.commandID)?.leasedAt == nil, "새 실행을 낳는 명령은 lease하지 않는다")
    }

    /// 종료가 시작되기 전에 lease된 명령도 종료 뒤에는 띄우지 않는다 (`leased`로 남는다)
    @Test func p1ALeasedCommandIsNotRunAfterShutdownBegins() async throws {
        let adapter = GatedRunAdapter()
        let h = try await harness(adapter)
        let task = await ask(h)
        await h.runtime.shutdown(interrupt: false)
        let session = BridgeHarness.sessionID
        let message = try TaskforceJSON.decoder().decode(BridgeV1MessageCommand.self, from: Data("""
        {"id":"c3333333-3333-4333-8333-3333333333f1","kind":"message","agent_session_id":"\(session)","agent_task_id":"\(UUID().uuidString.lowercased())","turn_seq":2,
         "step_id":"57e90001-0000-4000-8000-000000000003","adapter":"agent:claude-code","marker":"\(UUID().uuidString.lowercased())",
         "session":{"external_session_id":null,"workspace_ref":null,"resume":false},"access":"write","policy_mode":"manual",
         "message":{"id":"3e550001-0000-4000-8000-000000000003","text":"hi"},"close_before":null}
        """.utf8))
        // lease가 적어 두는 것(명령 `leased` · task)은 그대로 둔다: 종료가 아니었으면 띄웠을 명령이다
        let messageRecord = BridgeTest.command("c3333333-3333-4333-8333-3333333333f1", session: session, task: message.common.agentTaskID, state: .leased, at: h.clock.now)
        try await h.ledger.saveCommand(messageRecord)
        try await h.ledger.saveTask(BridgeTest.task(message.common.agentTaskID, session: session, at: h.clock.now))
        await h.runtime.runMessage(message, record: messageRecord)
        let answer = try TaskforceJSON.decoder().decode(BridgeV1AnswerCommand.self, from: Data("""
        {"id":"c3333333-3333-4333-8333-3333333333f2","kind":"answer","agent_session_id":"\(session)","agent_task_id":"\(task)","turn_seq":1,
         "step_id":"57e90001-0000-4000-8000-000000000004","adapter":"agent:claude-code","marker":"\(UUID().uuidString.lowercased())",
         "session":{"external_session_id":null,"workspace_ref":null,"resume":false},"access":"write","policy_mode":"manual","provider_request_id":"req-1",
         "question_kind":"input","structured":false,"answers":null,"answer_text":"x","answered_locally":false}
        """.utf8))
        let answerRecord = BridgeTest.command("c3333333-3333-4333-8333-3333333333f2", kind: "answer", session: session, task: task, state: .leased, at: h.clock.now)
        try await h.ledger.saveCommand(answerRecord)
        await h.runtime.runAnswer(answer, record: answerRecord)
        #expect(adapter.startedTurns.withLock { $0 } == 1)
        #expect(adapter.deliveredAnswers.withLock { $0 } == 0)
    }

    // MARK: 4 (sec F1) 접수 전 실패도 잠금으로 · 실행을 맡은 task에 새 message

    /// 정체 없이 실패한 시작이라도 그 세션의 지금 실행이 끝을 증명하지 못했으면(맡은 다른 task 없음) 이 task가 맡는다 (`alive=false`를 쓰지 않는다)
    @Test func p4AStartFailureWithoutLeftIsDecidedByTheLock() async throws {
        let adapter = GatedRunAdapter()
        let h = try await harness(adapter)
        let leftover = GatedRunAdapter.run(.unknown)
        adapter.current.withLock { $0 = leftover }
        adapter.turnFailsWithoutLeft.withLock { $0 = true }
        let created = h.message("Hi")
        await h.runtime.tick()
        #expect(await h.eventually { await h.task(created.taskID)?.lastState == "failed" })
        let record = await h.task(created.taskID)
        #expect(record?.alive == true)
        #expect(record?.processMarker == leftover.identity?.processMarker)
        #expect(await h.runtime.processFact(for: created.taskID, task: record) == .unverifiedOrphan)
    }

    /// 실행 기록이 있는 task의 id로 새 message가 왔는데 그 세션의 지금 실행이 끝을 증명하지 못했다(원장은 끝났다고 한다): 띄우지 않고 거절한다
    @Test func p4AMessageForATaskWhoseRunIsUnprovenIsRefused() async throws {
        let adapter = GatedRunAdapter()
        let h = try await harness(adapter)
        let task = await ask(h)
        adapter.current.withLock { $0 = GatedRunAdapter.run(.unknown) }
        let again = h.message("Again", task: task, turn: 2)
        h.clock.jump(by: 6)
        await h.runtime.tick()
        #expect(await h.eventually { await h.command(again.commandID)?.reason == "task_reused" })
        #expect(adapter.startedTurns.withLock { $0 } == 1, "다시 띄우지 않았다")
    }

    /// 끝을 증명한 task를 같은 id로 이어 쓰는 것은 막지 않는다
    @Test func p4AMessageForATaskWhoseRunEndedStillRuns() async throws {
        let adapter = GatedRunAdapter()
        let h = try await harness(adapter)
        let task = await ask(h)
        h.message("Again", task: task, turn: 2)
        h.clock.jump(by: 6)
        await h.runtime.tick()
        #expect(await h.eventually { adapter.startedTurns.withLock { $0 } == 2 })
    }

    // MARK: 6 (sec F3) 끝난 고아

    /// 감독 밖 고아의 실행이 끝을 증명하면 다음 tick이 끝 정산한다 (heartbeat `process_alive`가 계속 켜져 있지 않게)
    @Test func p6AnOrphanWhoseRunEndsIsSettledOnTheNextTick() async throws {
        let adapter = GatedRunAdapter()
        let h = try await harness(adapter)
        let task = await ask(h)
        adapter.closePlan.withLock { $0 = .fail }
        _ = try await closeLostSecret(h, task)
        #expect(await h.eventually { await h.task(task)?.alive == true })
        #expect(await h.runtime.buildHeartbeatTasks().first { $0.taskID == task }?.processAlive == true, "시험 전제: 살아 있는 고아")
        adapter.current.withLock { $0 = GatedRunAdapter.none }
        await h.runtime.tick()
        #expect(await h.task(task)?.alive == false)
        #expect(await h.runtime.buildHeartbeatTasks().first { $0.taskID == task }?.processAlive != true)
    }

    /// 깨어난 뒤의 생존 확인도 고아를 다시 본다
    @Test func p6RefreshingAfterWakeSettlesAnEndedOrphan() async throws {
        let adapter = GatedRunAdapter()
        let h = try await harness(adapter)
        let task = await ask(h)
        adapter.closePlan.withLock { $0 = .fail }
        _ = try await closeLostSecret(h, task)
        #expect(await h.eventually { await h.task(task)?.alive == true })
        adapter.current.withLock { $0 = GatedRunAdapter.none }
        await h.runtime.refreshLiveness()
        #expect(await h.task(task)?.alive == false)
    }
}
#endif
