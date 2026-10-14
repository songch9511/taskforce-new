#if os(macOS)
import Foundation

// 결과 확인(readback) · 재시작 판정 (OA D2b 계약 2.8). 부수 효과 없는 순수 함수라 표의 칸마다 시험한다.
// 판정은 하나뿐이다: 서버가 "결과를 모른다"고 물으면 원장 · 프로세스 · 접수 신호로 bridge가 실제로 한 일만 답한다.
// 원칙: `not_received`는 **앞 실행이 끝난 것을 확인한 뒤에만** 보낸다 (살아 있는 프로세스는 늦게 받을 수 있다, 계약 13.1).

/// 그 task의 프로세스에 대해 지금 아는 것
public enum ReadbackProcess: Sendable, Equatable {
    /// 감독 중이고 살아 있다
    case alive
    /// 끝난 것을 확인했다 (또는 원장이 끝났다고 안다)
    case ended
    /// 원장은 살아 있다고 하지만 감독하는 실행이 없다 (강제 종료 뒤 고아). 먼저 끝내야 한다 (Q6)
    case orphanAlive
    /// 확인할 수 없다. 끝났다고 말하지 않는다
    case unknown
}

public struct ReadbackFacts: Sendable {
    public enum Source: Sendable {
        /// `commands[]`의 `leased_by_me: true` 항목
        case commandList
        /// `readbacks[]` (lease가 만료돼 서버가 결과를 모르는 명령)
        case readbackList
    }

    public var source: Source
    /// nil이면 원장에 기록이 없다 (손실 · 손상 격리 뒤)
    public var command: BridgeCommandRecord?
    public var process: ReadbackProcess
    /// 이 task의 보낼 사건이 outbox에 남아 있다 (먼저 재생하면 서버가 다시 붙인다, D2a 3.5)
    public var outboxPending: Bool
    /// 접수 전 `failed` 사건이 outbox에 있다 (그것이 정산한다)
    public var preAcceptFailureQueued: Bool
    public var adapterReadback: AgentReadback

    public init(
        source: Source, command: BridgeCommandRecord?, process: ReadbackProcess, outboxPending: Bool = false, preAcceptFailureQueued: Bool = false,
        adapterReadback: AgentReadback = .unsupported
    ) {
        self.source = source
        self.command = command
        self.process = process
        self.outboxPending = outboxPending
        self.preAcceptFailureQueued = preAcceptFailureQueued
        self.adapterReadback = adapterReadback
    }
}

public enum ReadbackDecision: Equatable, Sendable {
    /// 보낼 것이 없다 (이미 보고했거나 · 끝난 기록이거나 · 서버 몫)
    case none
    /// lease를 다시 요청해 `replay`를 받고 **첫 실행**을 한다 (`start_intent`가 없다는 것이 원장으로 증명된다)
    case leaseAgain
    case report(BridgeV1ReadbackResult, processEnded: Bool)
    /// outbox를 먼저 다시 보낸다 (정산은 사건이 한다). 그래도 목록에 남으면 다음 판정에서 `received`
    case replayOutboxFirst
    /// 고아를 끝낸 뒤 다시 판정한다
    case terminateOrphanFirst
}

public enum EndedOutcome: Equatable, Sendable {
    case nothing
    case failedAgentError
    case cancelled
}

public enum Reconcile {
    public static func readback(_ facts: ReadbackFacts) -> ReadbackDecision {
        guard let command = facts.command else { return .report(.unknown, processEnded: false) }
        // 확정 답(received · not_received)을 이미 최종까지 보냈다
        if command.ackFinalAt != nil, command.ackOp == "readback", command.ackResult != "unknown" { return .none }
        let reportedUnknown = command.ackOp == "readback" && command.ackResult == "unknown"

        switch command.state {
        case .withdrawn, .gone:
            return .none
        case .declined, .stale:
            // 띄우지 않기로 한 명령: 띄운 적이 없다는 것이 원장으로 증명된다
            return command.ackOp == "readback" ? .none : .report(.notReceived, processEnded: true)
        case .seen, .leaseRequested, .leased:
            switch facts.source {
            case .commandList: return .leaseAgain
            case .readbackList: return command.ackOp == "readback" ? .none : .report(.notReceived, processEnded: true)
            }
        case .startIntent, .started, .inputSent, .accepted, .ended, .settled:
            break
        }

        if facts.process == .orphanAlive { return .terminateOrphanFirst }
        // 목록의 `leased_by_me` 항목은 서버가 결과를 묻는 것이 아니다 (단계가 calling): start_intent 이상이면 감독만 한다
        if facts.source == .commandList { return .none }

        let decision: ReadbackDecision
        if command.state == .startIntent, facts.process != .alive {
            // 시작 중에 죽음: 띄웠는지 모른다. adapter가 확인할 수 있으면 그 결과, 아니면 unknown
            switch facts.adapterReadback {
            case .received: decision = .report(.received, processEnded: facts.process == .ended)
            case .notReceived(let ended): decision = ended ? .report(.notReceived, processEnded: true) : .report(.unknown, processEnded: false)
            case .unknown, .unsupported: decision = .report(.unknown, processEnded: false)
            }
        } else {
            let signal = command.signalAt != nil
            switch facts.process {
            case .alive:
                decision = signal ? (facts.outboxPending ? .replayOutboxFirst : .report(.received, processEnded: false)) : .report(.unknown, processEnded: false)
            case .ended:
                if signal {
                    decision = facts.outboxPending ? .replayOutboxFirst : .report(.received, processEnded: true)
                } else {
                    decision = facts.preAcceptFailureQueued ? .replayOutboxFirst : .report(.notReceived, processEnded: true)
                }
            case .unknown:
                decision = signal ? (facts.outboxPending ? .replayOutboxFirst : .report(.received, processEnded: false)) : .report(.unknown, processEnded: false)
            case .orphanAlive:
                decision = .terminateOrphanFirst
            }
        }
        // 같은 명령에 unknown을 두 번 보내지 않는다 (더 확정적인 답이 생기면 보낸다)
        if reportedUnknown, decision == .report(.unknown, processEnded: false) { return .none }
        return decision
    }

    /// 프로세스가 끝났는데 끝 사건(turn_completed · failed · cancelled)을 못 봤을 때 런타임이 낼 사건.
    /// 접수 전에 조용히 끝난 것은 사건을 지어내지 않는다: 서버가 lease 만료 뒤 결과를 물으면 `not_received`로 답한다 (계약 2.8)
    public static func endedOutcome(task: BridgeTaskRecord, hasAcceptSignal: Bool, terminatedByUs: Bool) -> EndedOutcome {
        if task.segmentTerminal != nil { return .nothing }
        if task.cancelState != nil { return .cancelled }
        if terminatedByUs { return hasAcceptSignal ? .cancelled : .nothing }
        // 답을 기다리는 동안 프로세스가 끝나는 것은 정상이다 (답이 오면 이어서 띄운다)
        if task.lastState == "awaiting_answer" { return .nothing }
        return hasAcceptSignal ? .failedAgentError : .nothing
    }

    /// 재시작 · 깨어남 · 마지막 성공 heartbeat가 `unreachableAfter`보다 오래됐을 때 reconcile 사건을 낸다
    public static func needsReconcileAfterGap(lastHeartbeatOKAt: Date?, now: Date, unreachableAfter: TimeInterval = 90) -> Bool {
        guard let lastHeartbeatOKAt else { return true }
        return now.timeIntervalSince(lastHeartbeatOKAt) > unreachableAfter
    }

    /// reconcile 사건을 낼 task: 원장이 아직 살아 있다고 보는 것 (접수된 뒤 · 질문 대기 · 실행 중).
    /// 접수 전(`dispatched`)에 프로세스가 끝났거나 아직 시작 중인 task는 제외한다: reconcile 사건도 서버에서는 `unknown_outcome` 단계를 다시 붙이므로,
    /// 접수 전에 조용히 죽은 task에 보내면 `readback not_received` 경로를 막는다 (계약 2.8)
    public static func reconcileTargets(_ tasks: [BridgeTaskRecord]) -> [BridgeTaskRecord] {
        tasks.filter { task in
            if ["accepted", "running", "awaiting_answer"].contains(task.lastState) { return true }
            return task.alive && task.lastState != "dispatched"
        }
    }
}
#endif
