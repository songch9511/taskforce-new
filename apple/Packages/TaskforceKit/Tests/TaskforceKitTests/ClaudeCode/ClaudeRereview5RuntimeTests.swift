#if os(macOS) && DEBUG
import Foundation
import Synchronization
import Testing
@testable import TaskforceKit

/// 재검토 5 — 런타임 쪽 (OA D3a 14장 2, Astra P1-2): 답 정산(`request_closed` · 실패)은 프로세스의 끝이 아니다. 끝 증명 없이 `alive=false`를 적지 않고,
/// 다시 뜬 앱도 그 task를 끝났다고 하지 않는다. 실제 프로세스 없이 세션 상태를 정해 두는 adapter로 본다

/// 질문을 내고 끝나는 턴 · `requestClosed`를 돌려주는 답. 답 정산 뒤의 세션 상태(`sessionLiveness`)와 다시 뜬 앱의 확인(`liveness`)을 시험이 정한다
final class ClosingAnswerAdapter: AgentProcess, @unchecked Sendable {
    let adapter = "agent:claude-code"
    let session: AgentLiveness
    let relaunched: AgentLiveness
    let answerSink = Mutex<AgentEventSink?>(nil)

    init(session: AgentLiveness, relaunched: AgentLiveness = .unknown) {
        self.session = session
        self.relaunched = relaunched
    }

    func probe() async -> BridgeV1AdapterReport {
        BridgeV1AdapterReport(adapter: adapter, installed: true, version: "2.1.241", signedIn: .yes, managedSettings: false)
    }

    func startTurn(_ turn: AgentTurnStart, events: AgentEventSink) async throws -> AgentProcessIdentity {
        await events.emit(.sessionBound(externalSessionID: "c0ffee00-0000-4000-8000-000000000001", workspaceRef: turn.workspaceRef))
        await events.emit(.accepted)
        await events.emit(.question(AgentQuestion(providerRequestID: "req-1", kind: .input, structured: false, text: "Name?", items: [
            AgentQuestionItem(id: "q", header: "", text: "Name?", options: []),
        ])))
        await events.emit(.ended(AgentExit(code: 0)))
        return AgentProcessIdentity(pid: nil, startedAt: Date(), processMarker: UUID().uuidString, externalTaskID: "s:1")
    }

    func deliverAnswer(_ answer: AgentAnswerDelivery, events: AgentEventSink) async throws -> AgentAnswerResult {
        answerSink.withLock { $0 = events }
        return .requestClosed
    }

    func sessionLiveness(_ sessionID: String) async -> AgentLiveness { session }
    func closeRequest(_ request: AgentRequestRef) async throws {}
    func interrupt(_ target: AgentTurnRef, scope: AgentCancelScope) async -> AgentInterruptResult { .signalled }
    func liveness(_ identity: AgentProcessIdentity) async -> AgentLiveness { relaunched }
    func terminateOrphan(_ identity: AgentProcessIdentity) async -> AgentLiveness { relaunched }
}

@Suite(.serialized)
struct ClaudeRereview5RuntimeTests {
    func harness(_ adapter: any AgentProcess) async throws -> BridgeHarness {
        let harness = try BridgeHarness(withAdapter: false)
        try await harness.restart(adapters: [adapter], reopenLedger: false)
        await harness.registerFirst()
        return harness
    }

    /// 질문까지 간 task 하나와 그 답 명령
    func askAndAnswer(_ h: BridgeHarness) async throws -> (task: String, answer: String) {
        let created = h.message("Hi")
        await h.runtime.tick()
        await h.settle { let t = try? await h.ledger.task(created.taskID); return t?.openRequestID == "req-1" && t?.alive == false }
        let answer = try #require(h.server.enqueueAnswer(bridgeID: h.bridgeID, taskID: created.taskID, requestID: "req-1", answerText: "x", structured: false))
        h.clock.jump(by: 6)
        await h.runtime.tick()
        _ = await h.eventually { (await h.command(answer.commandID)?.state.rank ?? 0) >= (BridgeCommandState.ended.rank ?? 7) }
        return (created.taskID, answer.commandID)
    }

    // MARK: Astra P1-2 답 정산 뒤 끝을 모르면 unknown

    @Test func p12AClosedAnswerWhoseProcessEndIsUnprovenStaysAnUnverifiedOrphanAcrossARelaunch() async throws {
        let adapter = ClosingAnswerAdapter(session: .unknown)
        let h = try await harness(adapter)
        let (task, _) = try await askAndAnswer(h)
        #expect(await h.task(task)?.alive == true, "끝 증명 없이 alive=false를 적지 않는다")
        #expect(await h.runtime.processFact(for: task, task: h.task(task)) == .unverifiedOrphan)
        #expect(await h.runtime.buildHeartbeatTasks().first { $0.taskID == task }?.processAlive == false, "확인 안 된 고아의 lease를 늘리지 않는다")
        // 다시 뜬 앱: 원장의 alive와 adapter의 확인(잠금)으로 본다
        try await h.restart(adapters: [adapter], reopenLedger: false)
        await h.runtime.recover()
        #expect(await h.task(task)?.alive == true)
        #expect(await h.runtime.processFact(for: task, task: h.task(task)) == .unverifiedOrphan)
    }

    @Test func p12AClosedAnswerWhoseProcessStillRunsEndsSilentlyWhenItsEndArrives() async throws {
        let adapter = ClosingAnswerAdapter(session: .alive)
        let h = try await harness(adapter)
        let (task, _) = try await askAndAnswer(h)
        #expect(await h.task(task)?.alive == true, "아직 돈다")
        let stateBefore = await h.task(task)?.lastState
        let sink = try #require(adapter.answerSink.withLock { $0 })
        await sink.emit(.message(text: "late"))
        await sink.emit(.ended(AgentExit(code: 0)))
        #expect(await h.eventually { await h.task(task)?.alive == false }, "끝 사건이 끝을 적는다")
        #expect(await h.task(task)?.lastState == stateBefore, "닫은 답의 실행은 끝 사건만 받는다 (실패 · 중단 · 글 사건 0)")
    }

    @Test func p12AClosedAnswerWhoseSessionIsProvenEndedIsEnded() async throws {
        let h = try await harness(ClosingAnswerAdapter(session: .ended(AgentExit(code: nil))))
        let (task, _) = try await askAndAnswer(h)
        #expect(await h.task(task)?.alive == false)
        #expect(await h.runtime.processFact(for: task, task: h.task(task)) == .ended)
    }
}
#endif
