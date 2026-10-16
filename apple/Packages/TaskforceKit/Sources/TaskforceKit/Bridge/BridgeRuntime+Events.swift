#if os(macOS)
import Foundation

// adapter 사건 → outbox → 서버 (OA D2b 계약 2.7). 사건마다 한 트랜잭션: `last_seq + 1` · outbox 행 · task 상태 · (잘렸으면) 전체 글.
// 지우는 신호는 응답의 `accepted_event_ids`뿐이다.

extension BridgeRuntime {
    func makeSink(taskID: String, runID: UUID) -> AgentEventSink {
        AgentEventSink { [weak self] event, at in
            await self?.handleAdapterEvent(taskID: taskID, runID: runID, event: event, at: at)
        }
    }

    /// adapter가 낸 형태 있는 사건을 서버로 갈 사건으로 바꿔 원장에 적는다. 현재 실행 구간의 사건만 받는다 (옛 구간의 늦은 사건은 버린다)
    func handleAdapterEvent(taskID: String, runID: UUID, event: AgentEvent, at: Date?) async {
        guard let current = supervised[taskID], current.runID == runID else {
            log.log("event_dropped", ["task": .id(taskID)])
            return
        }
        // 답을 닫은 실행은 끝 사건만 받는다 (OA D3a 14장 2): 끝은 보통의 끝처럼 정산한다 (질문 대기 중의 끝 = 사건 0)
        if current.endOnly {
            if case .ended = event { await handleEnded(taskID: taskID, runID: runID) } else { log.log("event_dropped", ["task": .id(taskID)]) }
            return
        }
        let observed = at ?? clock.now()
        // 앞에서 적지 못한 `inputReached`가 있으면 다시 적는다 (OA D3a Q5)
        if current.inputReachedAt != nil { await applyInputReached(taskID: taskID) }
        switch event {
        case .inputReached:
            // 로컬 전용: 서버 사건 0 · 접수 신호 아님. 명령의 `inputAt`이 비어 있을 때만 적는다
            if supervised[taskID]?.inputReachedAt == nil { supervised[taskID]?.inputReachedAt = observed }
            await applyInputReached(taskID: taskID)
            return
        case .ended:
            await handleEnded(taskID: taskID, runID: runID)
        case .sessionBound(let external, let workspace):
            // 서버는 `pending:`으로 시작하는 id · 200자를 넘는 id · 500자를 넘는 workspace_ref를 final로 거절한다: 자르면 다른 세션 · 폴더가 되므로 보내지 않는다 (adapter 버그)
            let workspaceValue: String?
            switch OutgoingValues.workspaceRef(workspace) {
            case .absent: workspaceValue = nil
            case .value(let value): workspaceValue = value
            case .refused:
                log.log("session_bound_refused", ["task": .id(taskID), "why": .code("workspace_ref")])
                return
            }
            guard let sessionID = OutgoingValues.identity(external), !sessionID.hasPrefix("pending:") else {
                log.log("session_bound_refused", ["task": .id(taskID), "why": .code("external_session_id")])
                return
            }
            await appendTaskEvent(taskID: taskID, numbering: .sessionScoped, body: .sessionBound(externalSessionID: sessionID, workspaceRef: workspaceValue), observed: observed) {
                $0.externalSessionID = sessionID
                $0.workspaceRef = workspaceValue ?? $0.workspaceRef
            }
        case .accepted:
            await appendTaskEvent(taskID: taskID, body: .accepted, observed: observed, signal: true) {
                $0.acceptedAt = $0.acceptedAt ?? observed
                if $0.lastState == "dispatched" { $0.lastState = "accepted" }
            }
        case .progress:
            await appendTaskEvent(taskID: taskID, body: .progress, observed: observed, signal: true) { Self.markRunning(&$0) }
        case .message(let text):
            let fit = Outbox.fit(text: text)
            await appendTaskEvent(taskID: taskID, body: .message(text: fit.sent), observed: observed, fullText: fit.full, signal: true) { Self.markRunning(&$0) }
        case .artifact(let path, let hash, let summary):
            guard let artifact = OutgoingValues.artifact(path: path, hash: hash, summary: summary) else {
                log.log("artifact_refused", ["task": .id(taskID)])
                return
            }
            await appendTaskEvent(taskID: taskID, body: .artifact(path: artifact.path, hash: artifact.hash, summary: artifact.summary), observed: observed, signal: true) {
                Self.markRunning(&$0)
            }
        case .question(let question):
            await handleQuestion(taskID: taskID, question: question, observed: observed)
        case .turnCompleted:
            await appendTaskEvent(taskID: taskID, body: .turnCompleted, observed: observed, signal: true) {
                $0.lastState = "idle"
                $0.segmentTerminal = "completed"
                $0.openRequestID = nil
                $0.openRequestKind = nil
                $0.openRequestSecret = false
            }
        case .failed(let reason):
            await appendTaskEvent(taskID: taskID, body: .failed(reason), observed: observed) {
                $0.lastState = "failed"
                $0.segmentTerminal = "failed"
            }
        case .cancelled:
            await appendTaskEvent(taskID: taskID, body: .cancelled, observed: observed) {
                $0.lastState = "cancelled"
                $0.segmentTerminal = "cancelled"
            }
        }
        await publish()
    }

    static func markRunning(_ task: inout BridgeTaskRecord) {
        if ["dispatched", "accepted", "awaiting_answer"].contains(task.lastState) { task.lastState = "running" }
    }

    func handleQuestion(taskID: String, question: AgentQuestion, observed: Date) async {
        switch Outbox.fit(question: question, taskID: taskID, observedAt: observed) {
        case .fits(let fitted, let map):
            if !map.isEmpty, let data = try? JSONEncoder().encode(map) {
                try? await ledger.saveQuestionMap(taskID: taskID, requestID: question.providerRequestID, mappingJSON: String(decoding: data, as: UTF8.self))
            }
            let text = Outbox.fit(text: question.text)
            let secret = question.items.contains(where: \.secret)
            await appendTaskEvent(taskID: taskID, body: .question(text: text.sent, fitted), observed: observed, fullText: text.full, signal: true) {
                $0.openRequestID = question.providerRequestID
                $0.openRequestKind = question.kind.rawValue
                $0.openRequestSecret = secret
                $0.lastState = "awaiting_answer"
            }
        case .unrepresentable(let why):
            // 서버 모양에 담을 수 없다: 보내면 dead-letter가 되어 턴이 영원히 멈춘다. 그 요청을 거절로 닫는다 (Q15)
            log.log("question_unrepresentable", ["task": .id(taskID), "why": .code(why)])
            guard let task = try? await ledger.task(taskID), let adapter = adapters[task.adapter] else { return }
            try? await adapter.closeRequest(AgentRequestRef(taskID: taskID, sessionID: task.agentSessionID, requestID: question.providerRequestID, externalSessionID: task.externalSessionID, workspaceRef: task.workspaceRef))
            _ = try? await ledger.updateTask(taskID) { if !$0.closedRequestIDs.contains(question.providerRequestID) { $0.closedRequestIDs.append(question.providerRequestID) } }
        }
    }

    /// 사건 하나를 원장에 적는다 (outbox 행 + task 갱신 + 접수 신호를 한 트랜잭션으로)
    func appendTaskEvent(
        taskID: String, numbering: EventNumbering = .taskSequence, body: BridgeV1Event.Body, observed: Date, fullText: String? = nil, signal: Bool = false,
        update: @escaping @Sendable (inout BridgeTaskRecord) -> Void = { _ in }
    ) async {
        guard let task = try? await ledger.task(taskID) else { return }
        let now = clock.now()
        let sessionLevel = numbering == .sessionScoped
        var commandUpdate: (id: String, change: @Sendable (inout BridgeCommandRecord) -> Void)?
        if signal, let commandID = task.currentCommandID {
            commandUpdate = (commandID, { record in
                if record.signalAt == nil { record.signalAt = now }
                if (record.state.rank ?? 0) < (BridgeCommandState.accepted.rank ?? 6) {
                    record.state = .accepted
                    record.stateAt = now
                }
            })
        }
        do {
            _ = try await ledger.appendEvent(
                taskID: taskID, numbering: numbering,
                build: { seq, eventID in
                    let event = BridgeV1Event(
                        adapter: task.adapter, sessionID: task.agentSessionID, taskID: task.agentTaskID, externalTaskID: sessionLevel ? nil : task.externalTaskID, eventID: eventID,
                        seq: seq, turnSeq: task.turnSeq, observedAt: observed, body: body
                    )
                    let json = String(decoding: try TaskforceJSON.encoder().encode(event), as: UTF8.self)
                    return BuiltEvent(type: event.typeName, json: json, observedAt: observed, fullText: fullText)
                },
                update: update,
                command: commandUpdate
            )
        } catch {
            log.log("ledger_write_failed", ["step": .code("event")])
            return
        }
        scheduleFlush()
    }

    // MARK: 프로세스 끝

    /// `inputReached` 시각을 명령 `inputAt`에 바로 적는다 (비어 있을 때만). 시작 기록(`recordStarted`)은 adapter 정체 값이 없으면 이 값을 남긴다 (OA D3a 5.2),
    /// 그래서 시작 기록 전에 init → 끝이 와도 `supervised`를 지우기 전에 적힌다 (8장 16). 원장 읽기 · 쓰기가 실패하면 다음 사건 · 끝남에서 다시 본다
    func applyInputReached(taskID: String) async {
        guard let at = supervised[taskID]?.inputReachedAt, let task = try? await ledger.task(taskID), let commandID = task.currentCommandID,
              let command = try? await ledger.command(commandID) else { return }
        guard command.inputAt == nil else {
            supervised[taskID]?.inputReachedAt = nil
            return
        }
        guard (try? await ledger.updateCommand(commandID) { if $0.inputAt == nil { $0.inputAt = at } }) != nil else { return }
        supervised[taskID]?.inputReachedAt = nil
    }

    func handleEnded(taskID: String, runID: UUID) async {
        guard supervised[taskID]?.runID == runID else { return }
        if supervised[taskID]?.inputReachedAt != nil { await applyInputReached(taskID: taskID) }
        supervised[taskID] = nil
        let byUs = terminatedByUs.remove(taskID) != nil
        await finishEnded(taskID: taskID, byUs: byUs)
    }

    /// 프로세스가 끝났다. 끝 사건을 못 봤으면 원장으로 정한다: 접수 뒤 조용히 죽음 → `failed(agent_error)`, 우리가 멈춤 → `cancelled`,
    /// 접수 전에 조용히 끝남 → 사건을 지어내지 않는다 (서버가 결과를 물으면 `not_received`, 계약 2.8)
    func finishEnded(taskID: String, byUs: Bool) async {
        orphanLiveness[taskID] = nil
        guard let task = try? await ledger.task(taskID) else { return }
        // 이 실행이 끝나도 그 세션의 지금 실행(잠금의 현재 spawn: 내부 닫기 등)이 끝을 증명하지 못했으면 `alive`를 지우지 않는다 (OA D3a 15장 1: 앞 실행의 끝으로 덮지 않는다)
        var processEnded = true
        if let adapter = adapters[task.adapter], let run = await currentRun(taskID: taskID, session: task.agentSessionID, adapter: adapter) {
            switch run.liveness {
            case .ended: break
            case .alive:
                processEnded = false
                orphanLiveness[taskID] = .alive
            case .unknown:
                processEnded = false
                orphanLiveness[taskID] = .unknown
                log.log("run_end_unproven", ["task": .id(taskID)])
            }
        }
        let stillAlive = !processEnded
        let command = if let id = task.currentCommandID { try? await ledger.command(id) } else { nil as BridgeCommandRecord? }
        let outcome = Reconcile.endedOutcome(task: task, hasAcceptSignal: command?.signalAt != nil, terminatedByUs: byUs)
        let now = clock.now()
        switch outcome {
        case .failedAgentError:
            await appendTaskEvent(taskID: taskID, body: .failed(.agentError), observed: now) {
                $0.alive = stillAlive
                $0.lastState = "failed"
                $0.segmentTerminal = "failed"
            }
        case .cancelled:
            await appendTaskEvent(taskID: taskID, body: .cancelled, observed: now) {
                $0.alive = stillAlive
                $0.lastState = "cancelled"
                $0.segmentTerminal = "cancelled"
            }
        case .nothing:
            break
        }
        _ = try? await ledger.updateTask(taskID) { $0.alive = stillAlive }
        if let commandID = task.currentCommandID {
            _ = try? await ledger.updateCommand(commandID) {
                if ($0.state.rank ?? 0) < (BridgeCommandState.ended.rank ?? 7), !$0.state.isFinished {
                    $0.state = .ended
                    $0.stateAt = now
                }
            }
        }
        await publish()
        scheduleFlush()
    }

    // MARK: outbox 보내기

    /// 사건이 생긴 뒤 250ms 안에 모아 한 번에 보낸다 (루프가 돌 때만)
    func scheduleFlush() {
        guard loopsRunning, networkEnabled, flushTask == nil else { return }
        flushTask = Task { [weak self, clock] in
            try? await clock.sleep(.milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.runScheduledFlush()
        }
    }

    func runScheduledFlush() async {
        flushTask = nil
        await flushOutbox()
    }

    /// 적고 보낸다: 보낼 때가 된 사건을 묶음(≤ 100개 · ≤ 900KB, 같은 세션 순서)으로 보내고 응답의 세 목록으로만 지운다
    public func flushOutbox() async {
        guard networkEnabled, bridgeID != nil, secret != nil else { return }
        if flushing {
            flushAgain = true
            return
        }
        flushing = true
        defer { flushing = false }
        repeat {
            flushAgain = false
            let gen = generation
            while isCurrent(gen) {
                let rows = (try? await ledger.outboxRows(limit: 400)) ?? []
                let batch = Outbox.selectBatch(from: rows, now: clock.now())
                if batch.isEmpty { break }
                if await sendBatch(batch) == false { return }
            }
            _ = try? await ledger.settleEndedCommands()
        } while flushAgain && networkEnabled
        await publish()
    }

    /// 묶음 하나를 보낸다. 계속 보내도 되면 true
    func sendBatch(_ batch: [OutboxRow]) async -> Bool {
        guard let bridgeID else { return false }
        let gen = generation
        let response: BridgeV1EventsResponse
        do {
            response = try await authed(.events) { [client] secret in try await client.events(bridgeID: bridgeID, secret: secret, eventJSON: batch.map(\.bodyJSON)) }
        } catch let failure as RouteFailure {
            guard isCurrent(gen) || failure == .offline else { return false }
            switch failure {
            case .badRequest:
                // 묶음 전체 400: 반으로 나눠 다시. 한 사건만 남아도 400이면 그 사건은 dead-letter (본문 버그, 개수만 로그)
                if batch.count > 1 {
                    let (first, second) = Outbox.halves(batch)
                    if await sendBatch(first) == false { return false }
                    return await sendBatch(second)
                }
                try? await ledger.markOutboxDead(keys: batch.map(\.key), reason: "bad_request")
                log.log("outbox_dead_letter", ["count": .count(1), "reason": .code("bad_request")])
                return true
            case .offline:
                let delay = Outbox.backoff(attempts: batch.map(\.attempts).max() ?? 0, jitter: Double.random(in: -0.2...0.2))
                try? await ledger.recordOutboxFailure(keys: batch.map(\.key), nextAttemptAt: clock.now().addingTimeInterval(delay), status: "transport")
                return false
            default:
                // 429 · 401 · 403 · 404 · 멈춤: 지우지 않는다 (D2a 6.4)
                return false
            }
        } catch {
            return false
        }
        guard isCurrent(gen) else { return false }
        let disposition = Outbox.disposition(of: response, batch: batch)
        try? await ledger.removeOutbox(keys: disposition.delivered)
        if !disposition.dead.isEmpty {
            try? await ledger.markOutboxDead(keys: disposition.dead, reason: "rejected")
            log.log("outbox_dead_letter", ["count": .count(disposition.dead.count), "reason": .code("rejected")])
        }
        if !disposition.retry.isEmpty {
            // 남기고 뒤로 미룬다. 같은 세션의 뒤 사건도 다음 시도까지 보내지 않는다 (`selectBatch`가 막는다)
            let attempts = batch.filter { disposition.retry.contains($0.key) }.map(\.attempts).max() ?? 0
            let delay = Outbox.backoff(attempts: attempts, jitter: Double.random(in: -0.2...0.2))
            try? await ledger.recordOutboxFailure(keys: disposition.retry, nextAttemptAt: clock.now().addingTimeInterval(delay), status: "retry")
            return false
        }
        return true
    }

    // MARK: reconcile 사건 (계약 2.8)

    /// 재시작 · 깨어남 · 90초 넘게 끊김 뒤: outbox를 원래 순서 · 원래 event id로 다 보낸 **뒤** 원장이 살아 있다고 보는 task마다 `reconcile`.
    /// 상태를 지어내지 않는다(payload `state` 없음): 서버가 `last_live_state`로 되돌린다. seq도 싣지 않는다
    func enqueueReconcileIfNeeded() async {
        guard needsReconcile, networkEnabled, bridgeID != nil, heartbeatFresh() else { return }
        guard (try? await ledger.outboxRows().isEmpty) == true else { return }
        let tasks = (try? await ledger.allTasks()) ?? []
        for task in Reconcile.reconcileTargets(tasks) where task.serverUnknownAt == nil {
            await appendTaskEvent(taskID: task.agentTaskID, numbering: .reconcile, body: .reconcile(state: nil), observed: clock.now())
        }
        needsReconcile = false
        await flushOutbox()
    }
}
#endif
