#if os(macOS) && DEBUG
import Foundation
import Synchronization
import Testing
@testable import TaskforceKit

/// 재검토 6 — 런타임 쪽 (OA D3a 15장 1, Astra P1-1 · P1-2): 디스크 잠금이 유일한 생존 진실이다. 세션의 지금 실행(턴 · 답 · 닫기 · 내부 닫기)이 끝을 증명하지 못하면
/// 원장 marker · 앞 실행의 끝으로 `alive=false`를 쓰지 않고, Stop · 고아 정리 · 앱 종료가 그 실행을 대상으로 한다. 실제 프로세스 없이 잠금이 말하는 것을 시험이 정한다
final class LockTruthAdapter: AgentProcess, @unchecked Sendable {
    enum AnswerPlan {
        /// `requestClosed` (띄운 실행이 있으면 그것이 세션의 지금 실행)
        case closed(AgentSessionRun?)
        /// 띄운 뒤 정체를 원장에 적지 못하고 던진다 (`left`를 넘기는지)
        case throwing(AgentSessionRun, left: Bool)
    }

    static let none = AgentSessionRun(liveness: .ended(AgentExit(code: nil)), identity: nil)
    let adapter = "agent:claude-code"
    /// 세션의 지금 실행 (잠금이 말하는 것)
    let current = Mutex<AgentSessionRun>(LockTruthAdapter.none)
    /// 닫기가 띄운 실행이 끝을 증명하지 못하고 실패한다 (nil이면 닫기는 성공)
    let closeLeaves = Mutex<AgentSessionRun?>(nil)
    let answer = Mutex<AnswerPlan>(.closed(nil))
    /// 턴의 끝 사건 직전에 띄운 내부 닫기 (끝을 증명하지 못했다)
    let internalClose = Mutex<AgentSessionRun?>(nil)
    /// 내부 닫기로 바뀌고 끝 사건을 내는 때: 런타임이 턴의 정체를 적은 뒤 시험이 연다 (잠깐 쉬기 대신)
    let turnEnds = OrderGate()
    let terminateResult: AgentLiveness
    let interrupts = Mutex<[String]>([])
    let terminatedSessions = Mutex<[String]>([])
    let terminatedOrphans = Mutex<[String]>([])
    let turn = AgentProcessIdentity(pid: nil, startedAt: Date(timeIntervalSince1970: 1), processMarker: UUID().uuidString)

    init(terminateResult: AgentLiveness = .unknown) {
        self.terminateResult = terminateResult
    }

    static func run(_ liveness: AgentLiveness) -> AgentSessionRun {
        AgentSessionRun(liveness: liveness, identity: AgentProcessIdentity(pid: nil, startedAt: Date(timeIntervalSince1970: 2), processMarker: UUID().uuidString))
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
        var identity = self.turn
        identity.externalTaskID = "s:1"
        if let close = internalClose.withLock({ $0 }) {
            // 턴이 돌다가(정체를 적은 뒤) 끝나며 내부 닫기를 띄운다: 지금 실행이 닫기로 바뀐 뒤 턴의 끝 사건
            current.withLock { $0 = AgentSessionRun(liveness: .alive, identity: identity) }
            Task {
                await self.turnEnds.wait()
                self.current.withLock { $0 = close }
                await events.emit(.ended(AgentExit(code: 0)))
            }
            return identity
        }
        await events.emit(.ended(AgentExit(code: 0)))
        return identity
    }

    func deliverAnswer(_ answer: AgentAnswerDelivery, events: AgentEventSink) async throws -> AgentAnswerResult {
        switch self.answer.withLock({ $0 }) {
        case .closed(let run):
            if let run { current.withLock { $0 = run } }
            return .requestClosed
        case .throwing(let run, let left):
            current.withLock { $0 = run }
            throw AgentStartError(.agentError, left: left ? run.identity : nil)
        }
    }

    func closeRequest(_ request: AgentRequestRef) async throws {
        guard let leaves = closeLeaves.withLock({ $0 }) else { return }
        current.withLock { $0 = leaves }
        throw AgentStartError(.agentError, left: leaves.identity)
    }

    func interrupt(_ target: AgentTurnRef, scope: AgentCancelScope) async -> AgentInterruptResult {
        interrupts.withLock { $0.append(target.sessionID) }
        return .signalled
    }

    /// 원장의 정체로 묻는 쪽 (세션 단위 상태를 보지 않는 옛 경로): 지금 실행의 정체가 아니면 끝난 실행이다
    func liveness(_ identity: AgentProcessIdentity) async -> AgentLiveness {
        let run = current.withLock { $0 }
        return run.identity?.processMarker == identity.processMarker ? run.liveness : .ended(AgentExit(code: nil))
    }

    func terminateOrphan(_ identity: AgentProcessIdentity) async -> AgentLiveness {
        terminatedOrphans.withLock { $0.append(identity.processMarker) }
        return await liveness(identity)
    }

    func sessionRun(_ sessionID: String) async -> AgentSessionRun? { current.withLock { $0 } }

    func terminateSessionRun(_ sessionID: String) async -> AgentLiveness {
        terminatedSessions.withLock { $0.append(sessionID) }
        if case .ended = terminateResult { current.withLock { $0 = Self.none } }
        return terminateResult
    }
}

@Suite(.serialized)
struct ClaudeRereview6RuntimeTests {
    func harness(_ adapter: any AgentProcess) async throws -> BridgeHarness {
        let harness = try BridgeHarness(withAdapter: false)
        try await harness.restart(adapters: [adapter], reopenLedger: false)
        await harness.registerFirst()
        return harness
    }

    /// 질문을 내고 끝난 task 하나 (그 실행은 끝났다)
    func ask(_ h: BridgeHarness) async -> String {
        let created = h.message("Hi")
        await h.runtime.tick()
        await h.settle { let t = try? await h.ledger.task(created.taskID); return t?.openRequestID == "req-1" && t?.alive == false }
        return created.taskID
    }

    /// 명령 하나를 받아 끝날 때까지
    func run(_ h: BridgeHarness, _ created: FakeBridgeServer.Created?) async throws {
        let command = try #require(created)
        h.clock.jump(by: 6)
        await h.runtime.tick()
        _ = await h.eventually { (await h.command(command.commandID)?.state.rank ?? 0) >= (BridgeCommandState.ended.rank ?? 7) }
    }

    func answer(_ h: BridgeHarness, _ task: String, locally: Bool = false) async throws {
        try await run(h, h.server.enqueueAnswer(bridgeID: h.bridgeID, taskID: task, requestID: "req-1", answerText: locally ? nil : "x", locally: locally, structured: false))
    }

    /// 끝을 증명하지 못한 실행을 맡은 task: 원장 `alive`와 그 실행의 정체, 결과 확인은 확인 안 된 고아
    func expectUnverified(_ h: BridgeHarness, _ task: String, run: AgentSessionRun, _ comment: Comment) async {
        let record = await h.task(task)
        #expect(record?.alive == true, comment)
        #expect(record?.processMarker == run.identity?.processMarker, comment)
        #expect(await h.runtime.processFact(for: task, task: record) == .unverifiedOrphan, comment)
    }

    // MARK: P1-1 닫기 실행

    /// 접수 전 닫기(`close_before`)가 끝을 증명하지 못했다: 새 task는 `failed`지만 그 닫기 실행의 고아다. Stop이 그 실행을 대상으로 한다
    @Test func p11ACloseBeforeThatCannotProveItsEndLeavesTheNewTaskAliveForStop() async throws {
        let adapter = LockTruthAdapter()
        let h = try await harness(adapter)
        _ = await ask(h)
        let close = LockTruthAdapter.run(.unknown)
        adapter.closeLeaves.withLock { $0 = close }
        let next = h.message("Next", task: UUID().uuidString.lowercased(), turn: 2, closeBefore: "req-1")
        await h.runtime.tick()
        #expect(await h.eventually { await h.task(next.taskID)?.lastState == "failed" })
        await expectUnverified(h, next.taskID, run: close, "닫기 실행")
        try await run(h, h.server.enqueueCancel(bridgeID: h.bridgeID, taskID: next.taskID))
        #expect(adapter.interrupts.withLock { $0 } == [BridgeHarness.sessionID], "Stop이 그 실행에 간다")
    }

    /// 비밀 답이 메모리에 없어 닫는데 그 닫기가 끝을 증명하지 못했다: 다시 뜬 앱도 그 실행을 고아로 본다
    @Test func p11ALostSecretWhoseCloseFailsStaysAnOrphanAcrossARelaunch() async throws {
        let adapter = LockTruthAdapter()
        let h = try await harness(adapter)
        let task = await ask(h)
        let close = LockTruthAdapter.run(.unknown)
        adapter.closeLeaves.withLock { $0 = close }
        try await answer(h, task, locally: true)
        await expectUnverified(h, task, run: close, "닫기 실행")
        try await h.restart(adapters: [adapter], reopenLedger: false)
        await h.runtime.recover()
        await expectUnverified(h, task, run: close, "다시 뜬 앱")
    }

    /// 답이 던지고(정체를 적지 못함) 그 뒤 닫기도 끝을 증명하지 못했다: 지금 실행은 닫기다 (답 실행의 정체로 덮지 않는다)
    @Test func p11AFailedAnswerThenAFailedCloseKeepsTheCloseRun() async throws {
        let adapter = LockTruthAdapter()
        let h = try await harness(adapter)
        let task = await ask(h)
        adapter.answer.withLock { $0 = .throwing(LockTruthAdapter.run(.unknown), left: true) }
        let close = LockTruthAdapter.run(.unknown)
        adapter.closeLeaves.withLock { $0 = close }
        try await answer(h, task)
        await expectUnverified(h, task, run: close, "닫기 실행")
        try await h.restart(adapters: [adapter], reopenLedger: false)
        await h.runtime.recover()
        await expectUnverified(h, task, run: close, "다시 뜬 앱")
    }

    /// 질문을 기다리는 task의 Stop: 버린 요청의 닫기가 끝을 증명하지 못해도 그 실행을 멈춘다 (닫기 실패로 Stop을 건너뛰지 않는다)
    @Test func p11ACancelWhoseCloseFailsStillStopsTheCloseRun() async throws {
        let adapter = LockTruthAdapter()
        let h = try await harness(adapter)
        let task = await ask(h)
        let close = LockTruthAdapter.run(.alive)
        adapter.closeLeaves.withLock { $0 = close }
        let cancel = h.server.enqueueCancel(bridgeID: h.bridgeID, taskID: task, abandoned: "req-1")
        try await run(h, cancel)
        #expect(adapter.interrupts.withLock { $0 } == [BridgeHarness.sessionID])
        #expect(await h.task(task)?.alive == true)
        #expect(await h.task(task)?.processMarker == close.identity?.processMarker)
    }

    /// 턴이 끝 사건을 내기 전에 띄운 내부 닫기가 끝을 증명하지 못했다: 그 턴의 끝 사건이 task를 끝났다고 적지 않는다
    @Test func p11AnInternalCloseThatCannotProveItsEndIsNotCoveredByTheTurnsEnd() async throws {
        let adapter = LockTruthAdapter()
        let close = LockTruthAdapter.run(.unknown)
        adapter.internalClose.withLock { $0 = close }
        let h = try await harness(adapter)
        let created = h.message("Hi")
        await h.runtime.tick()
        // tick은 턴을 띄우고 그 정체를 적은 뒤 돌아온다: 그 뒤에 내부 닫기 · 끝 사건
        adapter.turnEnds.open()
        #expect(await h.eventually(timeout: 60) {
            let task = await h.task(created.taskID)
            return task?.openRequestID == "req-1" && task?.processMarker == close.identity?.processMarker
        })
        await expectUnverified(h, created.taskID, run: close, "내부 닫기")
        try await h.restart(adapters: [adapter], reopenLedger: false)
        await h.runtime.recover()
        await expectUnverified(h, created.taskID, run: close, "다시 뜬 앱")
        #expect(adapter.terminatedOrphans.withLock { $0 }.isEmpty, "원장의 오래된 정체로 끝내지 않는다")
    }

    /// 닫기 실행 중에 앱이 죽었다 (원장에는 그 실행이 없다): 다시 뜬 앱이 잠금에서 찾아 그 세션의 마지막 task의 고아로 둔다
    @Test func p11ACloseRunLeftByACrashIsFoundThroughTheLock() async throws {
        let adapter = LockTruthAdapter()
        let h = try await harness(adapter)
        let task = await ask(h)
        let close = LockTruthAdapter.run(.unknown)
        adapter.current.withLock { $0 = close }
        try await h.restart(adapters: [adapter], reopenLedger: false)
        await h.runtime.recover()
        await expectUnverified(h, task, run: close, "잠금의 지금 실행")
    }

    // MARK: P1-2 답 실행의 정체를 적기 전

    /// 답 실행을 띄운 뒤 그 정체를 원장에 적기 전에 앱이 죽었다: 다시 뜬 앱은 원장의 질문 실행 marker(끝)가 아니라 잠금의 지금 실행을 정산한다
    @Test func p12ACrashBeforeTheAnswerIdentityIsWrittenIsSettledByTheLock() async throws {
        let adapter = LockTruthAdapter()
        let h = try await harness(adapter)
        let task = await ask(h)
        // 답 명령의 start_intent(alive)까지 적었고 답 실행이 떴다
        _ = try await h.ledger.updateTask(task) { $0.alive = true }
        let answerRun = LockTruthAdapter.run(.alive)
        adapter.current.withLock { $0 = answerRun }
        try await h.restart(adapters: [adapter], reopenLedger: false)
        await h.runtime.recover()
        #expect(adapter.terminatedSessions.withLock { $0 } == [BridgeHarness.sessionID], "그 세션의 지금 실행을 끝낸다")
        #expect(adapter.terminatedOrphans.withLock { $0 }.isEmpty, "질문 실행의 오래된 정체로 끝내지 않는다")
        await expectUnverified(h, task, run: answerRun, "끝내지 못했다")
    }

    /// 정체를 적지 못한 답이 `left` 없이 던졌다: 지금 실행(잠금)의 정체를 적는다. 다시 뜬 앱도 그것으로 본다
    @Test func p12AnAnswerThatThrowsWithoutLeftIsSettledByTheLock() async throws {
        let adapter = LockTruthAdapter()
        let h = try await harness(adapter)
        let task = await ask(h)
        let answerRun = LockTruthAdapter.run(.unknown)
        adapter.answer.withLock { $0 = .throwing(answerRun, left: false) }
        try await answer(h, task)
        await expectUnverified(h, task, run: answerRun, "답 실행")
        try await h.restart(adapters: [adapter], reopenLedger: false)
        await h.runtime.recover()
        await expectUnverified(h, task, run: answerRun, "다시 뜬 앱")
    }

    /// 앱 종료 · 계정 삭제: 감독 중인 답 실행은 원장 marker가 아니라 그 세션의 지금 실행으로 끝낸다
    @Test func p12EndingRemainingRunsTargetsTheSessionsCurrentRun() async throws {
        let adapter = LockTruthAdapter(terminateResult: .ended(AgentExit(code: nil)))
        let h = try await harness(adapter)
        let task = await ask(h)
        adapter.answer.withLock { $0 = .closed(LockTruthAdapter.run(.alive)) }
        try await answer(h, task)
        #expect(await h.task(task)?.alive == true, "답 실행이 돈다")
        // 기다리는 쪽이 끝날 때까지 시계를 민다 (정해진 횟수로 멈추면 늦게 잠든 런타임이 깨지 않는다)
        let worker = Task {
            while !Task.isCancelled {
                await h.clock.advance(by: 0.25)
                try? await Task.sleep(for: .milliseconds(3))
            }
        }
        let unresolved = await h.runtime.interruptLiveTurns()
        worker.cancel()
        #expect(unresolved == 0)
        #expect(adapter.terminatedSessions.withLock { $0 }.contains(BridgeHarness.sessionID))
        #expect(adapter.terminatedOrphans.withLock { $0 }.isEmpty)
        #expect(await h.task(task)?.alive == false)
    }
}
#endif
