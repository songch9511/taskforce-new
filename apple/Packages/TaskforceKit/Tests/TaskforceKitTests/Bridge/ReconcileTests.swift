#if os(macOS)
import Foundation
import Testing
@testable import TaskforceKit

/// 결과 확인(readback) · 재시작 판정 (OA D2b 계약 2.8 · 4.1 K5). 순수 함수라 표의 칸마다 하나씩 시험한다
struct ReconcileTests {
    private let t0 = BridgeTest.t0

    private func command(
        _ state: BridgeCommandState, signal: Bool = false, ackOp: String? = nil, ackResult: String? = nil, ackFinal: Bool = false
    ) -> BridgeCommandRecord {
        var record = BridgeTest.command(state: state)
        record.signalAt = signal ? t0 : nil
        record.ackOp = ackOp
        record.ackResult = ackResult
        record.ackFinalAt = ackFinal ? t0 : nil
        return record
    }

    private func decide(
        _ source: ReadbackFacts.Source, _ command: BridgeCommandRecord?, _ process: ReadbackProcess = .ended, outbox: Bool = false,
        preAcceptFailure: Bool = false, adapter: AgentReadback = .unsupported
    ) -> ReadbackDecision {
        Reconcile.readback(ReadbackFacts(source: source, command: command, process: process, outboxPending: outbox, preAcceptFailureQueued: preAcceptFailure, adapterReadback: adapter))
    }

    // MARK: 원장에 기록이 없다 (손실 · 격리)

    @Test func withNoLedgerRecordTheOnlyHonestAnswerIsUnknown() {
        #expect(decide(.commandList, nil) == .report(.unknown, processEnded: false))
        #expect(decide(.readbackList, nil) == .report(.unknown, processEnded: false))
    }

    // MARK: 띄운 적이 없다 (start_intent 앞)

    @Test func leasedWithoutStartIntentInTheCommandListLeasesAgainAndRunsFirstTime() {
        for state in [BridgeCommandState.seen, .leaseRequested, .leased] {
            #expect(decide(.commandList, command(state)) == .leaseAgain, "\(state)")
        }
    }

    @Test func leasedWithoutStartIntentInTheReadbackListIsProvenNotReceivedBecauseNothingWasEverStarted() {
        for state in [BridgeCommandState.seen, .leaseRequested, .leased] {
            #expect(decide(.readbackList, command(state)) == .report(.notReceived, processEnded: true), "\(state)")
        }
    }

    @Test func aCommandWeDecidedNotToRunReportsNotReceivedUnlessAlreadyReported() {
        #expect(decide(.readbackList, command(.declined)) == .report(.notReceived, processEnded: true))
        #expect(decide(.readbackList, command(.stale)) == .report(.notReceived, processEnded: true))
        #expect(decide(.readbackList, command(.declined, ackOp: "readback", ackResult: "not_received")) == .none)
        #expect(decide(.readbackList, command(.withdrawn)) == .none)
        #expect(decide(.readbackList, command(.gone)) == .none)
    }

    // MARK: start_intent 이상

    @Test func startIntentWithoutAnIdentityAsksTheAdapterOtherwiseUnknown() {
        let started = command(.startIntent)
        #expect(decide(.readbackList, started, .unknown, adapter: .received) == .report(.received, processEnded: false))
        #expect(decide(.readbackList, started, .ended, adapter: .notReceived(processEnded: true)) == .report(.notReceived, processEnded: true))
        #expect(decide(.readbackList, started, .unknown, adapter: .notReceived(processEnded: false)) == .report(.unknown, processEnded: false),
                "끝났다는 확인이 없으면 not_received를 보내지 않는다")
        #expect(decide(.readbackList, started, .unknown, adapter: .unsupported) == .report(.unknown, processEnded: false))
        #expect(decide(.readbackList, started, .unknown, adapter: .unknown) == .report(.unknown, processEnded: false))
    }

    @Test func aliveAndAcceptedReplaysTheOutboxFirstThenReportsReceived() {
        let live = command(.accepted, signal: true)
        #expect(decide(.readbackList, live, .alive, outbox: true) == .replayOutboxFirst)
        #expect(decide(.readbackList, live, .alive, outbox: false) == .report(.received, processEnded: false))
    }

    @Test func aliveWithoutAnAcceptSignalReportsUnknownOnceAndKeepsSupervising() {
        #expect(decide(.readbackList, command(.started), .alive) == .report(.unknown, processEnded: false))
        let alreadyReported = command(.started, ackOp: "readback", ackResult: "unknown")
        #expect(decide(.readbackList, alreadyReported, .alive) == .none, "같은 명령에 unknown을 두 번 보내지 않는다")
    }

    @Test func aMoreDefiniteAnswerAfterAnEarlierUnknownIsStillReported() {
        let alreadyReported = command(.started, signal: true, ackOp: "readback", ackResult: "unknown")
        #expect(decide(.readbackList, alreadyReported, .alive) == .report(.received, processEnded: false))
    }

    @Test func endedAndAcceptedReplaysThenReportsReceivedWithTheProcessEnded() {
        let done = command(.ended, signal: true)
        #expect(decide(.readbackList, done, .ended, outbox: true) == .replayOutboxFirst)
        #expect(decide(.readbackList, done, .ended, outbox: false) == .report(.received, processEnded: true))
    }

    @Test func endedWithoutAnAcceptSignalIsNotReceivedOnlyWhenNoPreAcceptFailureIsQueued() {
        let silent = command(.ended)
        #expect(decide(.readbackList, silent, .ended) == .report(.notReceived, processEnded: true))
        #expect(decide(.readbackList, silent, .ended, preAcceptFailure: true) == .replayOutboxFirst, "접수 전 failed 사건이 정산한다")
    }

    @Test func notReceivedIsNeverReportedWhileTheProcessMightStillBeRunning() {
        for process in [ReadbackProcess.alive, .unknown, .orphanAlive] {
            for state in [BridgeCommandState.startIntent, .started, .accepted, .ended] {
                let decision = decide(.readbackList, command(state), process)
                if case .report(.notReceived, _) = decision { Issue.record("\(process) \(state): \(decision)") }
            }
        }
    }

    @Test func anUnknownLivenessWithAnAcceptSignalReportsReceivedWithoutClaimingTheProcessEnded() {
        #expect(decide(.readbackList, command(.accepted, signal: true), .unknown) == .report(.received, processEnded: false))
        #expect(decide(.readbackList, command(.started), .unknown) == .report(.unknown, processEnded: false))
    }

    @Test func anOrphanIsEndedBeforeAnythingIsDecided() {
        #expect(decide(.readbackList, command(.accepted, signal: true), .orphanAlive) == .terminateOrphanFirst)
        #expect(decide(.commandList, command(.started), .orphanAlive) == .terminateOrphanFirst)
    }

    @Test func startedOrBeyondInTheCommandListNeverRunsAgain() {
        for state in [BridgeCommandState.startIntent, .started, .inputSent, .accepted, .ended] {
            #expect(decide(.commandList, command(state, signal: true), .alive) != .leaseAgain, "\(state)")
        }
    }

    @Test func aSettledCommandStillGetsItsReadbackAnswered() {
        #expect(decide(.readbackList, command(.settled, signal: true), .ended) == .report(.received, processEnded: true))
    }

    @Test func anAlreadyFinalAckIsNotSentAgain() {
        #expect(decide(.readbackList, command(.settled, signal: true, ackOp: "readback", ackResult: "received", ackFinal: true), .ended) == .none)
    }

    // MARK: 끝남 판정

    private func task(lastState: String = "running", cancel: String? = nil, terminal: String? = nil) -> BridgeTaskRecord {
        var record = BridgeTest.task()
        record.lastState = lastState
        record.cancelState = cancel
        record.segmentTerminal = terminal
        return record
    }

    @Test func aProcessThatEndedWithoutATerminalEventAfterAcceptanceIsAnAgentError() {
        #expect(Reconcile.endedOutcome(task: task(), hasAcceptSignal: true, terminatedByUs: false) == .failedAgentError)
    }

    @Test func aProcessThatEndedBeforeAcceptanceIsLeftToTheReadbackPath() {
        #expect(Reconcile.endedOutcome(task: task(lastState: "dispatched"), hasAcceptSignal: false, terminatedByUs: false) == .nothing)
    }

    @Test func aProcessWeStoppedAfterAcceptanceIsCancelledAndBeforeAcceptanceLeftAlone() {
        #expect(Reconcile.endedOutcome(task: task(), hasAcceptSignal: true, terminatedByUs: true) == .cancelled)
        #expect(Reconcile.endedOutcome(task: task(lastState: "dispatched"), hasAcceptSignal: false, terminatedByUs: true) == .nothing)
    }

    @Test func aRequestedCancelMakesTheEndACancelledEvent() {
        #expect(Reconcile.endedOutcome(task: task(cancel: "signalled"), hasAcceptSignal: true, terminatedByUs: false) == .cancelled)
        #expect(Reconcile.endedOutcome(task: task(cancel: "requested"), hasAcceptSignal: false, terminatedByUs: false) == .cancelled)
    }

    @Test func aTerminalEventAlreadySentOrAWaitingQuestionNeedsNoSyntheticEvent() {
        #expect(Reconcile.endedOutcome(task: task(terminal: "completed"), hasAcceptSignal: true, terminatedByUs: false) == .nothing)
        #expect(Reconcile.endedOutcome(task: task(terminal: "failed"), hasAcceptSignal: true, terminatedByUs: true) == .nothing)
        #expect(Reconcile.endedOutcome(task: task(lastState: "awaiting_answer"), hasAcceptSignal: true, terminatedByUs: false) == .nothing)
    }

    // MARK: reconcile 사건

    @Test func reconcileFollowsAGapLongerThanNinetySecondsOrNoHeartbeatAtAll() {
        #expect(Reconcile.needsReconcileAfterGap(lastHeartbeatOKAt: nil, now: t0))
        #expect(Reconcile.needsReconcileAfterGap(lastHeartbeatOKAt: t0.addingTimeInterval(-91), now: t0))
        #expect(!Reconcile.needsReconcileAfterGap(lastHeartbeatOKAt: t0.addingTimeInterval(-90), now: t0))
        #expect(!Reconcile.needsReconcileAfterGap(lastHeartbeatOKAt: t0.addingTimeInterval(-5), now: t0))
    }

    @Test func reconcileCoversTasksWeStillBelieveAreLiveAndNoOthers() {
        func record(_ id: String, state: String, alive: Bool = false) -> BridgeTaskRecord {
            var task = BridgeTest.task(id)
            task.lastState = state
            task.alive = alive
            return task
        }
        let tasks = [
            record("a", state: "running", alive: true), record("b", state: "idle"), record("c", state: "failed"), record("d", state: "cancelled"),
            record("e", state: "awaiting_answer"), record("f", state: "accepted"), record("g", state: "dispatched"), record("h", state: "idle", alive: true),
        ]
        #expect(Reconcile.reconcileTargets(tasks).map(\.agentTaskID) == ["a", "e", "f", "h"], "접수 전(dispatched)인 task는 readback 경로를 막지 않게 제외")
    }

    // MARK: 입력이 CLI에 닿은 뒤의 결과 불명 (OA D3a Q5, 계약 13.2 :519 · G31)

    /// 접수 신호 없이 끝났어도 `inputAt`(Claude Code `system/init` · Codex `turn/start`)이 있으면 CLI가 글을 받았을 수 있다:
    /// adapter가 받지 않았다고 확인할 때만 `not_received`, 아니면 `unknown` (Send again이 같은 글을 transcript에 두 번 넣지 않게)
    @Test func anInputThatReachedTheCLIIsUnknownUnlessTheAdapterProvesOtherwise() {
        let adapters: [AgentReadback] = [.received, .notReceived(processEnded: true), .notReceived(processEnded: false), .unknown, .unsupported]
        for adapter in adapters {
            var reached = command(.started)
            reached.inputAt = t0
            let expected: ReadbackDecision = adapter == .notReceived(processEnded: true) ? .report(.notReceived, processEnded: true) : .report(.unknown, processEnded: false)
            #expect(decide(.readbackList, reached, .ended, adapter: adapter) == expected, "\(adapter)")
            // 끝나지 않았으면 지금과 같다 (살아 있는 프로세스는 늦게 받을 수 있다)
            #expect(decide(.readbackList, reached, .alive, adapter: adapter) == .report(.unknown, processEnded: false), "\(adapter)")
        }
    }

    @Test func withoutInputAtAnEndedSilentCommandIsStillNotReceived() {
        let adapters: [AgentReadback] = [.received, .notReceived(processEnded: true), .notReceived(processEnded: false), .unknown, .unsupported]
        for adapter in adapters {
            #expect(decide(.readbackList, command(.started), .ended, adapter: adapter) == .report(.notReceived, processEnded: true), "\(adapter)")
            #expect(decide(.readbackList, command(.started), .alive, adapter: adapter) == .report(.unknown, processEnded: false), "\(adapter)")
        }
    }

    @Test func aQueuedPreAcceptFailureStillReplaysFirstAfterInputReached() {
        var reached = command(.started)
        reached.inputAt = t0
        #expect(decide(.readbackList, reached, .ended, preAcceptFailure: true) == .replayOutboxFirst)
        var reported = command(.started, ackOp: "readback", ackResult: "unknown")
        reported.inputAt = t0
        #expect(decide(.readbackList, reported, .ended) == .none, "unknown은 한 번만")
    }
}
#endif
