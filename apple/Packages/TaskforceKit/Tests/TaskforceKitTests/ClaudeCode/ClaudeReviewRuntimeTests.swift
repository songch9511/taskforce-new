#if os(macOS) && DEBUG
import Darwin
import Foundation
import Synchronization
import Testing
@testable import TaskforceKit

/// 검토 반영 (OA D3a 계약 8장 · 5.2) — 런타임 쪽: `inputAt`(5.2 · 16)과 `close_before` 호출부(15). 실제 프로세스 없이 시작 순서를 결정적으로 만드는 adapter로 본다

/// 시작 중에 사건을 내는 adapter: init → 끝이 `recordStarted`보다 먼저 오는 경쟁을 결정적으로 만든다 (8장 16, 5.2)
final class EarlyEventsAdapter: AgentProcess, @unchecked Sendable {
    let adapter = "agent:claude-code"
    let endBeforeReturn: Bool

    init(endBeforeReturn: Bool) {
        self.endBeforeReturn = endBeforeReturn
    }

    func probe() async -> BridgeV1AdapterReport {
        BridgeV1AdapterReport(adapter: adapter, installed: true, version: "2.1.241", signedIn: .yes, managedSettings: false)
    }

    func startTurn(_ turn: AgentTurnStart, events: AgentEventSink) async throws -> AgentProcessIdentity {
        await events.emit(.inputReached)
        if endBeforeReturn { await events.emit(.ended(AgentExit(code: nil, signal: Int(SIGKILL)))) }
        return AgentProcessIdentity(pid: 999_999, startedAt: Date(), processMarker: UUID().uuidString, externalTaskID: "s:1")
    }

    func deliverAnswer(_ answer: AgentAnswerDelivery, events: AgentEventSink) async throws -> AgentAnswerResult { .requestClosed }
    func closeRequest(_ request: AgentRequestRef) async throws {}
    func interrupt(_ target: AgentTurnRef, scope: AgentCancelScope) async -> AgentInterruptResult { .signalled }
    func liveness(_ identity: AgentProcessIdentity) async -> AgentLiveness { endBeforeReturn ? .ended(AgentExit(code: nil)) : .alive }
    func terminateOrphan(_ identity: AgentProcessIdentity) async -> AgentLiveness { .ended(AgentExit(code: nil)) }
}

/// `closeRequest`가 실패하는 adapter (8장 15 호출부)
final class CloseFailsAdapter: AgentProcess, @unchecked Sendable {
    let adapter = "agent:claude-code"
    let started = Mutex(0)

    func probe() async -> BridgeV1AdapterReport {
        BridgeV1AdapterReport(adapter: adapter, installed: true, version: "2.1.241", signedIn: .yes, managedSettings: false)
    }

    func startTurn(_ turn: AgentTurnStart, events: AgentEventSink) async throws -> AgentProcessIdentity {
        started.withLock { $0 += 1 }
        return AgentProcessIdentity(pid: 999_998, startedAt: Date(), processMarker: UUID().uuidString, externalTaskID: "s:1")
    }

    func deliverAnswer(_ answer: AgentAnswerDelivery, events: AgentEventSink) async throws -> AgentAnswerResult { .requestClosed }
    func closeRequest(_ request: AgentRequestRef) async throws { throw AgentStartError(.spawnFailed) }
    func interrupt(_ target: AgentTurnRef, scope: AgentCancelScope) async -> AgentInterruptResult { .signalled }
    func liveness(_ identity: AgentProcessIdentity) async -> AgentLiveness { .alive }
    func terminateOrphan(_ identity: AgentProcessIdentity) async -> AgentLiveness { .ended(AgentExit(code: nil)) }
}

@Suite(.serialized)
struct ClaudeReviewRuntimeTests {
    func harness(_ adapter: any AgentProcess) async throws -> BridgeHarness {
        let harness = try BridgeHarness(withAdapter: false)
        try await harness.restart(adapters: [adapter], reopenLedger: false)
        await harness.registerFirst()
        return harness
    }

    func endedCommand(_ h: BridgeHarness, _ created: FakeBridgeServer.Created) async -> BridgeCommandRecord? {
        _ = await h.eventually {
            let alive = await h.task(created.taskID)?.alive
            let rank = await h.command(created.commandID)?.state.rank
            return alive == false && (rank ?? 0) >= (BridgeCommandState.ended.rank ?? 7)
        }
        return await h.command(created.commandID)
    }

    // MARK: 16 init → 끝이 시작 기록보다 먼저 와도 inputAt이 남는다 (A9)

    @Test func a16AnInitThatEndsBeforeTheStartRecordStillLeavesInputAt() async throws {
        let h = try await harness(EarlyEventsAdapter(endBeforeReturn: true))
        let created = h.message("Hi")
        await h.runtime.tick()
        let command = await endedCommand(h, created)
        #expect(command?.inputAt != nil)
        let facts = await h.runtime.readbackFacts(source: .readbackList, command: command)
        #expect(Reconcile.readback(facts) == .report(.unknown, processEnded: false))
    }

    /// 5.2: 먼저 찍힌 inputAt을 시작 기록(`recordStarted`)이 지우지 않는다
    @Test func a16AnInputAtWrittenBeforeTheStartRecordIsKept() async throws {
        let h = try await harness(EarlyEventsAdapter(endBeforeReturn: false))
        let created = h.message("Hi")
        await h.runtime.tick()
        #expect(await h.eventually { await h.command(created.commandID)?.spawnAt != nil })
        #expect(await h.command(created.commandID)?.inputAt != nil)
    }

    // MARK: 15 호출부: close_before 실패를 버리지 않는다 (A8)

    @Test func a15ACloseBeforeThatFailsDoesNotStartTheNextTurn() async throws {
        let adapter = CloseFailsAdapter()
        let h = try await harness(adapter)
        let created = h.message(closeBefore: "req-old")
        await h.runtime.tick()
        #expect(await h.eventually { await h.task(created.taskID)?.lastState == "failed" })
        #expect(adapter.started.withLock { $0 } == 0)
        #expect(await h.task(created.taskID)?.closedRequestIDs.contains("req-old") == false)
        #expect(h.log.lines.contains { $0.hasPrefix("adapter_close_failed") })
    }
}
#endif
