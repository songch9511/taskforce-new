#if os(macOS) && DEBUG
import Foundation
import Synchronization
import Testing
@testable import TaskforceKit

/// 재검토 8 — 런타임 쪽 (OA D3a 17장 1 · 4 · 5): 닫기 실패는 고아 기록을 마친 뒤에 `closing`에서 빠지고, adapter 실행 등록부가 비지 않았으면 살아 있는 프로세스이며,
/// 종료가 시작된 뒤 마지막 await을 지난 명령도 띄우지 않고(`failed` 0), 서버 모양에 못 담은 질문의 닫기 실패도 그 실행을 고아로 둔다. 실제 프로세스 없이 시험이 정한다
final class ScriptedRunAdapter: AgentProcess, @unchecked Sendable {
    static let none = AgentSessionRun(liveness: .ended(AgentExit(code: nil)), identity: nil)
    let adapter = "agent:claude-code"
    let current = Mutex<AgentSessionRun>(ScriptedRunAdapter.none)
    /// 세션 실행 조회를 잡아 둔다 (그 사이 런타임의 생존 판단을 본다)
    let holdSessionRun = Mutex(false)
    let sessionGate = Mutex<CheckedContinuation<Void, Never>?>(nil)
    let registered = Mutex(false)
    /// 턴의 질문 (없으면 보통 질문). 턴은 끝 사건을 내지 않는다 (감독 중)
    let question = Mutex<AgentQuestion?>(nil)
    let endsTurn = Mutex(true)
    /// 도는 턴이 질문을 내는 때: 런타임이 턴의 정체를 적은 뒤 시험이 연다 (잠깐 쉬기 대신)
    let asks = OrderGate()
    let probeGate = Mutex<CheckedContinuation<Void, Never>?>(nil)
    let holdProbe = Mutex(false)
    let startedTurns = Mutex(0)
    let deliveredAnswers = Mutex(0)
    let closeRun = AgentSessionRun(liveness: .unknown, identity: AgentProcessIdentity(pid: nil, startedAt: Date(timeIntervalSince1970: 3), processMarker: UUID().uuidString))
    let turn = AgentProcessIdentity(pid: nil, startedAt: Date(timeIntervalSince1970: 1), processMarker: UUID().uuidString)

    func probe() async -> BridgeV1AdapterReport {
        if holdProbe.withLock({ $0 }) { await withCheckedContinuation { continuation in probeGate.withLock { $0 = continuation } } }
        return BridgeV1AdapterReport(adapter: adapter, installed: true, version: "2.1.241", signedIn: .yes, managedSettings: false)
    }

    func releaseProbe() {
        probeGate.withLock {
            $0?.resume()
            $0 = nil
        }
    }

    func releaseSessionRun() {
        sessionGate.withLock {
            $0?.resume()
            $0 = nil
        }
    }

    func startTurn(_ turn: AgentTurnStart, events: AgentEventSink) async throws -> AgentProcessIdentity {
        startedTurns.withLock { $0 += 1 }
        await events.emit(.sessionBound(externalSessionID: "c0ffee00-0000-4000-8000-000000000001", workspaceRef: turn.workspaceRef))
        await events.emit(.accepted)
        let asked = question.withLock { $0 } ?? AgentQuestion(providerRequestID: "req-1", kind: .input, structured: false, text: "Name?", items: [
            AgentQuestionItem(id: "q", header: "", text: "Name?", options: []),
        ])
        var identity = self.turn
        identity.externalTaskID = "s:1"
        guard endsTurn.withLock({ $0 }) else {
            // 정체를 적은 뒤 도는 턴이 질문을 낸다 (끝 사건 없음: 감독 중)
            Task {
                await self.asks.wait()
                await events.emit(.question(asked))
            }
            return identity
        }
        await events.emit(.question(asked))
        await events.emit(.ended(AgentExit(code: 0)))
        return identity
    }

    func deliverAnswer(_ answer: AgentAnswerDelivery, events: AgentEventSink) async throws -> AgentAnswerResult {
        deliveredAnswers.withLock { $0 += 1 }
        return .requestClosed
    }

    /// 닫기는 끝을 증명하지 못하고 그 실행을 남긴다
    func closeRequest(_ request: AgentRequestRef) async throws {
        current.withLock { $0 = closeRun }
        throw AgentStartError(.agentError, left: closeRun.identity)
    }

    func interrupt(_ target: AgentTurnRef, scope: AgentCancelScope) async -> AgentInterruptResult { .signalled }
    func liveness(_ identity: AgentProcessIdentity) async -> AgentLiveness { .ended(AgentExit(code: nil)) }
    func terminateOrphan(_ identity: AgentProcessIdentity) async -> AgentLiveness { .ended(AgentExit(code: nil)) }

    func sessionRun(_ sessionID: String) async -> AgentSessionRun? {
        if holdSessionRun.withLock({ $0 }) { await withCheckedContinuation { continuation in sessionGate.withLock { $0 = continuation } } }
        return current.withLock { $0 }
    }

    func terminateSessionRun(_ sessionID: String) async -> AgentLiveness { .unknown }
    func hasRegisteredRuns() async -> Bool { registered.withLock { $0 } }
}

@Suite(.serialized)
struct ClaudeRereview8RuntimeTests {
    func harness(_ adapter: ScriptedRunAdapter) async throws -> BridgeHarness {
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

    // MARK: 1 (Astra P1-1) 닫기 실패의 틈

    /// 닫기 실패를 정산하는 동안(그 세션 잠금을 조회 중) 다른 알림이 "살아 있는 것 없음"을 내지 않는다: `closing`은 고아 기록을 마친 뒤에 빠진다
    @Test func r1ACloseFailureStaysLiveUntilTheOrphanIsRecorded() async throws {
        let adapter = ScriptedRunAdapter()
        let h = try await harness(adapter)
        let task = await ask(h)
        adapter.holdSessionRun.withLock { $0 = true }
        let answer = try #require(h.server.enqueueAnswer(bridgeID: h.bridgeID, taskID: task, requestID: "req-1", locally: true, structured: false))
        h.clock.jump(by: 6)
        let runtime = h.runtime
        let ticking = Task { await runtime.tick() }
        #expect(await h.eventually { adapter.sessionGate.withLock { $0 != nil } }, "닫기 실패를 정산하며 세션 잠금을 조회 중")
        #expect(await h.runtime.hasLiveProcess(), "그 사이에도 살아 있다")
        adapter.holdSessionRun.withLock { $0 = false }
        adapter.releaseSessionRun()
        await ticking.value
        #expect(await h.eventually { (await h.command(answer.commandID)?.state.rank ?? 0) >= (BridgeCommandState.ended.rank ?? 7) })
        #expect(await h.task(task)?.alive == true, "고아로 남았다")
    }

    /// adapter 실행 등록부가 비지 않았으면(시작 중 · 내부 닫기) 런타임 상태가 비어도 살아 있는 프로세스다 (Quit이 `terminateNow`로 빠지지 않는다)
    @Test func r1ANonEmptyAdapterRegistryIsALiveProcess() async throws {
        let adapter = ScriptedRunAdapter()
        let h = try await harness(adapter)
        #expect(await !h.runtime.hasLiveProcess())
        adapter.registered.withLock { $0 = true }
        #expect(await h.runtime.hasLiveProcess())
    }

    // MARK: 4 (sec S8-4) 종료가 시작된 뒤 마지막 await을 지난 명령

    /// probe에서 멈춰 있던 message: 그 사이 Quit이 시작됐다. probe가 돌아온 뒤에도 띄우지 않고 `leased`로 둔다 (`failed` 사건 0)
    @Test func s4AMessageWaitingAtProbeIsNotStartedAfterShutdown() async throws {
        let adapter = ScriptedRunAdapter()
        let h = try await harness(adapter)
        adapter.holdProbe.withLock { $0 = true }
        let created = h.message("Hi")
        let runtime = h.runtime
        let ticking = Task { await runtime.tick() }
        #expect(await h.eventually { adapter.probeGate.withLock { $0 != nil } })
        // 종료가 끝날 때까지 시계를 민다 (정해진 횟수로 멈추면 늦게 잠든 런타임이 깨지 않는다)
        let worker = Task {
            while !Task.isCancelled {
                await h.clock.advance(by: 0.25)
                try? await Task.sleep(for: .milliseconds(3))
            }
        }
        await h.runtime.shutdown(interrupt: true)
        worker.cancel()
        adapter.holdProbe.withLock { $0 = false }
        adapter.releaseProbe()
        await ticking.value
        #expect(adapter.startedTurns.withLock { $0 } == 0, "띄우지 않았다")
        #expect(await h.command(created.commandID)?.state == .leased, "lease 그대로")
        #expect(await h.task(created.taskID)?.lastState != "failed", "failed 0")
        #expect(await h.task(created.taskID)?.alive != true)
    }

    /// 명령의 시작 의도를 적은 뒤(마지막 확인 바로 전, DEBUG 시험 지점) Quit을 시작하고, 종료 표시를 본 뒤 놓는다. 끝내기 유예는 시계를 밀어 마친다
    func shutDownAtStartIntent(_ h: BridgeHarness, commandID: String) async {
        let gate = Mutex<CheckedContinuation<Void, Never>?>(nil)
        let held = Mutex(false)
        let runtime = h.runtime
        await runtime.setAfterStartIntent {
            guard await h.command(commandID)?.state == .startIntent, !held.withLock({ $0 }) else { return }
            held.withLock { $0 = true }
            await withCheckedContinuation { continuation in gate.withLock { $0 = continuation } }
        }
        let ticking = Task { await runtime.tick() }
        #expect(await h.eventually { gate.withLock { $0 != nil } }, "시작 의도를 적은 뒤 멈췄다")
        let stopping = Task { await runtime.shutdown(interrupt: true) }
        #expect(await h.eventually { await runtime.shuttingDown }, "종료 시작")
        gate.withLock {
            $0?.resume()
            $0 = nil
        }
        await ticking.value
        await runtime.setAfterStartIntent(nil)
        let worker = Task {
            while !Task.isCancelled {
                await h.clock.advance(by: 0.25)
                try? await Task.sleep(for: .milliseconds(3))
            }
        }
        await stopping.value
        worker.cancel()
    }

    /// message의 시작 의도를 적은 뒤 Quit이 시작됐다: 턴을 띄우지 않고 명령을 `leased`로, task · 감독을 전으로 되돌린다 (`failed` 0)
    @Test func s4AMessagePastItsStartIntentIsAbandonedOnShutdown() async throws {
        let adapter = ScriptedRunAdapter()
        let h = try await harness(adapter)
        let created = h.message("Hi")
        await shutDownAtStartIntent(h, commandID: created.commandID)
        #expect(adapter.startedTurns.withLock { $0 } == 0, "띄우지 않았다")
        #expect(await h.command(created.commandID)?.state == .leased, "lease로 되돌렸다")
        #expect(await h.task(created.taskID)?.lastState != "failed", "failed 0")
        #expect(await h.task(created.taskID)?.alive != true, "전 상태로")
        #expect(await h.runtime.supervised[created.taskID] == nil, "감독도 되돌렸다")
    }

    /// 답의 시작 의도를 적은 뒤 Quit이 시작됐다: 답을 건네지 않고 명령을 `leased`로, task를 전으로 되돌린다 (질문은 열린 채, `failed` 0)
    @Test func s4AnAnswerPastItsStartIntentIsNotDeliveredAfterShutdown() async throws {
        let adapter = ScriptedRunAdapter()
        let h = try await harness(adapter)
        let task = await ask(h)
        let answer = try #require(h.server.enqueueAnswer(bridgeID: h.bridgeID, taskID: task, requestID: "req-1", answerText: "Ada", structured: false))
        await shutDownAtStartIntent(h, commandID: answer.commandID)
        #expect(adapter.deliveredAnswers.withLock { $0 } == 0, "건네지 않았다")
        #expect(await h.command(answer.commandID)?.state == .leased, "lease로 되돌렸다")
        #expect(await h.task(task)?.lastState != "failed", "failed 0")
        #expect(await h.task(task)?.alive != true, "전 상태로")
        #expect(await h.task(task)?.openRequestID == "req-1", "질문은 열린 채")
        #expect(await h.runtime.supervised[task] == nil, "감독도 되돌렸다")
    }

    // MARK: 5 (sec S8-5-2) 서버 모양에 못 담은 질문의 닫기 실패

    /// 질문 다섯 개(서버 모양 밖)를 닫다가 끝을 증명하지 못했다: 그 닫기 실행을 이 task가 맡는다 (정체 · 고아)
    @Test func s5AFailedCloseOfAnUnrepresentableQuestionKeepsItsRun() async throws {
        let adapter = ScriptedRunAdapter()
        adapter.endsTurn.withLock { $0 = false }
        let items = (1...5).map { AgentQuestionItem(id: "q\($0)", header: "", text: "Name?", options: []) }
        adapter.question.withLock { $0 = AgentQuestion(providerRequestID: "req-1", kind: .input, structured: false, text: "Name?", items: items) }
        let h = try await harness(adapter)
        let created = h.message("Hi")
        await h.runtime.tick()
        // tick은 턴을 띄우고 그 정체를 적은 뒤 돌아온다: 그 뒤에 도는 턴의 질문
        adapter.asks.open()
        #expect(await h.eventually(timeout: 60) { await h.task(created.taskID)?.processMarker == adapter.closeRun.identity?.processMarker }, "닫기 실행의 정체를 적었다")
        #expect(await h.task(created.taskID)?.alive == true)
    }
}
#endif
