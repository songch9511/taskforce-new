#if os(macOS)
import CryptoKit
import Foundation

// 명령 처리 (OA D2b 계약 2.6): 목록 → 원장을 먼저 본다 → lease → kind별 실행. 정산(ack)은 ack outbox를 거친다 (먼저 적고 보낸다).

enum ItemResult {
    /// 이번에 한 일이 있다 (lease · 정산 · 결과 확인 · 중단)
    case acted
    /// 미뤘다 (writer 하나 · 마무리 모드 · heartbeat 먼저). 다음 목록에서 다시 판단한다
    case deferred
    /// 할 일 없음 (끝난 기록 · 감독 중)
    case ignored
}

extension BridgeRuntime {
    // MARK: heartbeat (계약 2.9)

    func sendHeartbeat() async {
        guard networkEnabled, bridgeID != nil, !heartbeatInFlight else { return }
        heartbeatInFlight = true
        defer { heartbeatInFlight = false }
        await performHeartbeat()
    }

    /// 50개를 넘으면 살아 있음 → 열림(질문 대기) → 최근 순
    func buildHeartbeatTasks() async -> [BridgeV1HeartbeatTask] {
        let candidates = ((try? await ledger.allTasks()) ?? []).filter { $0.isUnfinished && $0.serverUnknownAt == nil }
        func rank(_ task: BridgeTaskRecord) -> Int { task.alive ? 0 : (task.lastState == "awaiting_answer" || task.openRequestID != nil ? 1 : 2) }
        let sorted = candidates.sorted { (rank($0), $1.updatedAt) < (rank($1), $0.updatedAt) }
        return sorted.prefix(50).map {
            BridgeV1HeartbeatTask(taskID: $0.agentTaskID, processAlive: $0.alive, lastSeq: $0.lastSeq > 0 ? $0.lastSeq : nil)
        }
    }

    /// adapters는 시작 때와 probe 결과가 바뀔 때만 (10분마다 · 깨어날 때 다시 probe). 없으면 키를 뺀다 (null 금지)
    func reportsForHeartbeat() async -> [BridgeV1AdapterReport]? {
        let now = clock.now()
        let due = !appVersionSent || lastProbeAt == nil || now.timeIntervalSince(lastProbeAt!) >= 600
        guard due else { return nil }
        let reports = await probeAll()
        let hash = Self.hash(of: reports)
        guard !appVersionSent || hash != lastAdapterReportHash else { return nil }
        pendingAdapterReportHash = hash
        return reports
    }

    static func hash(of reports: [BridgeV1AdapterReport]) -> String {
        let data = (try? TaskforceJSON.encoder().encode(reports)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func performHeartbeat() async {
        guard let bridgeID else { return }
        let gen = generation
        let sentAt = clock.now()
        lastHeartbeatAttempt = sentAt
        let tasks = await buildHeartbeatTasks()
        let reports = await reportsForHeartbeat()
        let request = BridgeV1HeartbeatRequest(
            bridgeID: bridgeID, sentAt: sentAt, appVersion: appVersionSent ? nil : config.appVersion, tasks: tasks, adapters: reports
        )
        let response: BridgeV1HeartbeatResponse
        do {
            response = try await authed(.heartbeat) { [client] secret in try await client.heartbeat(request, secret: secret) }
        } catch {
            if let failure = error as? RouteFailure, failure == .bridgeGone { forceHeartbeat = true }
            return
        }
        guard isCurrent(gen) else { return }
        let received = clock.now()
        // 끊겼다 돌아왔다: 서버가 이 Mac의 task를 unreachable로 표시했을 수 있다 → outbox를 다 보낸 뒤 reconcile 사건
        if Reconcile.needsReconcileAfterGap(lastHeartbeatOKAt: lastHeartbeatOK, now: sentAt, unreachableAfter: unreachableAfter) { needsReconcile = true }
        lastHeartbeatOK = received
        forceHeartbeat = false
        reconnecting = false
        appVersionSent = true
        heartbeatInterval = TimeInterval(response.heartbeatIntervalSeconds)
        if reports != nil, let pending = pendingAdapterReportHash { lastAdapterReportHash = pending }
        let offset = Int((response.serverTime.timeIntervalSince(sentAt.addingTimeInterval(received.timeIntervalSince(sentAt) / 2)) * 1000).rounded())
        let hash = lastAdapterReportHash
        try? await ledger.updateMeta {
            $0.lastHeartbeatOKAt = received
            $0.clockOffsetMS = offset
            $0.adaptersReportHash = hash
            $0.heartbeatIntervalSeconds = response.heartbeatIntervalSeconds
        }
        setStatus(.connected)
        for taskID in response.unknownTaskIDs { await markServerUnknown(taskID) }
        if !response.missingTaskIDs.isEmpty { log.log("heartbeat_missing", ["count": .count(response.missingTaskIDs.count)]) }
        if response.pendingCommands > 0 {
            // Realtime이 놓친 것의 안전망: 다음 목록은 cursor 필터 없이 본다
            forceFullList = true
            nudge(.heartbeat)
        }
        await publish()
    }

    /// 서버가 모르는 task: 다음 heartbeat에서 뺀다. 살아 있는 실행이면 중단한다 (감독 밖 writer를 남기지 않는다)
    func markServerUnknown(_ taskID: String) async {
        _ = try? await ledger.updateTask(taskID) { $0.serverUnknownAt = clock.now() }
        log.log("server_unknown_task", ["task": .id(taskID)])
        if let entry = supervised[taskID] { await interruptTask(taskID, entry: entry, scope: .turnAndProcesses) }
    }

    // MARK: 목록 (계약 2.6 · 2.10)

    /// 미룬 명령의 cursor 앞까지만 `after`로 보낸다: 서버는 `cursor > after`인 새 명령만 주므로 미룬 것을 놓치지 않게
    func conservativeAfter() -> Int {
        guard let oldest = deferred.min() else { return after }
        return min(after, oldest - 1)
    }

    public func poll(wait: Int, reason: BridgeWakeReason) async -> PollOutcome {
        var outcome = PollOutcome()
        guard networkEnabled, let bridgeID, secret != nil else {
            outcome.failed = true
            return outcome
        }
        let gen = generation
        let wakeAt = clock.now()
        // Realtime · heartbeat 신호 · 시작은 cursor 필터 없이 본다. 긴 대기만 보수적 cursor (이미 본 명령에 깨지 않게)
        let queryAfter = (reason == .longPoll && !forceFullList) ? conservativeAfter() : 0
        forceFullList = false
        let response: BridgeV1CommandsResponse
        do {
            response = try await authed(.commands) { [client] secret in try await client.commands(bridgeID: bridgeID, secret: secret, after: queryAfter, wait: wait) }
        } catch {
            outcome.failed = true
            return outcome
        }
        guard isCurrent(gen) else { return outcome }
        let listedAt = clock.now()
        after = max(after, response.nextCursor)
        outcome.listed = response.commands.count + response.readbacks.count
        func tally(_ result: ItemResult) {
            switch result {
            case .acted: outcome.handled += 1
            case .deferred: outcome.deferred += 1
            case .ignored: break
            }
        }
        // 결과 확인 먼저, 그다음 cancel → answer → message (같은 종류는 cursor 순)
        for item in response.readbacks {
            guard isCurrent(gen) else { return outcome }
            tally(await handleReadback(item))
        }
        func rank(_ kind: BridgeV1CommandKind) -> Int {
            switch kind {
            case .cancel: 0
            case .answer: 1
            case .message: 2
            case .unknown: 3
            }
        }
        for item in response.commands.sorted(by: { (rank($0.kind), $0.cursor) < (rank($1.kind), $1.cursor) }) {
            guard isCurrent(gen) else { return outcome }
            tally(await handleListItem(item, reason: reason, wakeAt: wakeAt, listedAt: listedAt))
        }
        return outcome
    }

    func makeSeen(_ item: BridgeV1CommandListItem, reason: BridgeWakeReason, wakeAt: Date, listedAt: Date) -> BridgeCommandRecord {
        var record = BridgeCommandRecord(
            commandID: item.id, kind: item.kind.raw, agentSessionID: item.agentSessionID, agentTaskID: item.agentTaskID, turnSeq: item.turnSeq, cursor: item.cursor,
            state: .seen, stateAt: clock.now()
        )
        record.serverCreatedAt = item.createdAt
        record.wakeSource = reason.rawValue
        record.wakeAt = wakeAt
        record.listedAt = listedAt
        return record
    }

    func handleListItem(_ item: BridgeV1CommandListItem, reason: BridgeWakeReason, wakeAt: Date, listedAt: Date) async -> ItemResult {
        let existing = try? await ledger.command(item.id)
        if let existing, existing.state.isFinished {
            deferred.remove(item.cursor)
            return .ignored
        }
        // 모르는 kind: lease하지 않고 실행하지 않는다 (추측 실행 금지, 아키텍처 9.2 · D2a 3.4)
        if case .unknown = item.kind { return await declineUnknownKind(item, existing: existing, reason: reason, wakeAt: wakeAt, listedAt: listedAt) }

        let delivery = item.kind != .cancel
        // 마무리 모드: 새 전달은 lease하지 않는다. 이미 띄운 것은 계속 감독한다
        if config.mode == .drain, delivery, !(existing?.state.hasStartIntent ?? false) {
            deferred.insert(item.cursor)
            return .deferred
        }

        guard let existing else {
            if item.leasedByMe {
                // 원장에 기록이 없는데 서버는 우리가 lease했다고 한다 (원장 손실): 띄웠는지 모른다
                return await reportLostLedger(item, reason: reason, wakeAt: wakeAt, listedAt: listedAt)
            }
            return await leaseNew(item, existing: nil, reason: reason, wakeAt: wakeAt, listedAt: listedAt)
        }

        if item.kind == .cancel {
            switch existing.state {
            case .seen, .leaseRequested, .leased: return await leaseNew(item, existing: existing, reason: reason, wakeAt: wakeAt, listedAt: listedAt)
            default: return .ignored // 중단을 이미 했다: ack는 ack outbox가 보낸다
            }
        }

        let facts = await readbackFacts(source: .commandList, command: existing)
        switch Reconcile.readback(facts) {
        case .leaseAgain:
            if item.leasedByMe { return await leaseNew(item, existing: existing, reason: reason, wakeAt: wakeAt, listedAt: listedAt) }
            // 아직 lease하지 않은 기록: 새 명령처럼 (writer 하나를 다시 본다)
            return await leaseNew(item, existing: existing, reason: reason, wakeAt: wakeAt, listedAt: listedAt)
        case .terminateOrphanFirst:
            await settleOrphans()
            return .acted
        case .none, .report, .replayOutboxFirst:
            return .ignored
        }
    }

    // MARK: 결과 확인 (readback, 계약 2.8)

    func processFact(for taskID: String, task: BridgeTaskRecord?) -> ReadbackProcess {
        if supervised[taskID] != nil { return .alive }
        guard let task else { return .unknown }
        return task.alive ? .orphanAlive : .ended
    }

    func readbackFacts(source: ReadbackFacts.Source, command: BridgeCommandRecord?, marker: String? = nil) async -> ReadbackFacts {
        let taskID = command?.agentTaskID
        let task: BridgeTaskRecord? = if let taskID { try? await ledger.task(taskID) } else { nil }
        let queued = if let taskID { (try? await ledger.outboxRows(forTask: taskID)) ?? [] } else { [OutboxRow]() }
        var adapterReadback = AgentReadback.unsupported
        if let command, command.state == .startIntent, let task, let adapter = adapters[task.adapter], let marker = marker ?? command.marker {
            adapterReadback = await adapter.readback(marker: marker, session: AgentSessionRef(sessionID: task.agentSessionID, externalSessionID: task.externalSessionID, workspaceRef: task.workspaceRef))
        }
        return ReadbackFacts(
            source: source, command: command, process: command.map { processFact(for: $0.agentTaskID, task: task) } ?? .unknown, outboxPending: !queued.isEmpty,
            preAcceptFailureQueued: queued.contains { $0.type == "failed" }, adapterReadback: adapterReadback
        )
    }

    func handleReadback(_ item: BridgeV1ReadbackItem) async -> ItemResult {
        if item.kind == .cancel { return await readbackForCancel(item) }
        if case .unknown = item.kind { return .ignored }
        var existing = try? await ledger.command(item.commandID)
        for attempt in 0..<3 {
            let facts = await readbackFacts(source: .readbackList, command: existing, marker: item.marker)
            switch Reconcile.readback(facts) {
            case .none, .leaseAgain:
                return .ignored
            case .terminateOrphanFirst:
                await settleOrphans()
            case .replayOutboxFirst:
                // 서버가 사건 재생으로 다시 붙인다 (D2a 3.5-2). 그래도 목록에 남아 있을 때만 다음 판정에서 received
                await flushOutbox()
                if attempt == 2 { return .deferred }
            case .report(let result, let ended):
                if existing == nil {
                    // 원장에 기록이 없던 명령: 끝난 기록으로 남긴다 (다시 목록에 나와도 실행하지 않는다)
                    var record = BridgeCommandRecord(
                        commandID: item.commandID, kind: item.kind.raw, agentSessionID: item.agentSessionID, agentTaskID: item.agentTaskID, turnSeq: item.turnSeq,
                        cursor: 0, state: .declined, stateAt: clock.now()
                    )
                    record.marker = item.marker
                    record.reason = "no_record"
                    try? await ledger.saveCommand(record)
                    existing = record
                }
                if result == .notReceived { _ = try? await ledger.updateTask(item.agentTaskID) { $0.lastState = "failed" } }
                await sendAck(.readback(result, processEnded: ended), commandID: item.commandID)
                return .acted
            }
            existing = try? await ledger.command(item.commandID)
        }
        return .deferred
    }

    /// 취소 명령의 결과를 모른다(lease 만료): 결과 확인 대신 중단을 다시 실행하고(멱등) `task_unknown`으로 알린다 (D2a Q15)
    func readbackForCancel(_ item: BridgeV1ReadbackItem) async -> ItemResult {
        if let existing = try? await ledger.command(item.commandID), existing.ackOp != nil || existing.state.isFinished { return .ignored }
        var record = (try? await ledger.command(item.commandID))
            ?? BridgeCommandRecord(commandID: item.commandID, kind: "cancel", agentSessionID: item.agentSessionID, agentTaskID: item.agentTaskID, turnSeq: item.turnSeq, cursor: 0, state: .leased, stateAt: clock.now())
        record.state = .leased
        try? await ledger.saveCommand(record)
        _ = await interruptIfRunning(taskID: item.agentTaskID, scope: .turnAndProcesses)
        await sendAck(.complete(.taskUnknown), commandID: item.commandID)
        return .acted
    }

    func reportLostLedger(_ item: BridgeV1CommandListItem, reason: BridgeWakeReason, wakeAt: Date, listedAt: Date) async -> ItemResult {
        // 띄웠는지 모르므로 이 명령은 다시 실행하지 않는다: 끝난 기록(declined)으로 남기고 결과 확인만 보낸다
        var record = makeSeen(item, reason: reason, wakeAt: wakeAt, listedAt: listedAt)
        record.state = .declined
        record.reason = "ledger_lost"
        try? await ledger.saveCommand(record)
        if item.kind == .cancel {
            await sendAck(.complete(.taskUnknown), commandID: item.id)
        } else {
            await sendAck(.readback(.unknown, processEnded: false), commandID: item.id)
        }
        return .acted
    }

    // MARK: 모르는 kind

    func declineUnknownKind(_ item: BridgeV1CommandListItem, existing: BridgeCommandRecord?, reason: BridgeWakeReason, wakeAt: Date, listedAt: Date) async -> ItemResult {
        if item.leasedByMe { return .ignored } // lease한 적이 없다
        if existing?.ackOp != nil { return .ignored }
        let record = existing ?? makeSeen(item, reason: reason, wakeAt: wakeAt, listedAt: listedAt)
        try? await ledger.saveCommand(record)
        await sendAck(.decline, commandID: item.id)
        return .acted
    }

    // MARK: lease (계약 2.6 "lease 응답")

    func leaseNew(_ item: BridgeV1CommandListItem, existing: BridgeCommandRecord?, reason: BridgeWakeReason, wakeAt: Date, listedAt: Date) async -> ItemResult {
        // 원장이 `start_intent` 이상이면 lease도 실행도 하지 않는다 (이 기록을 `lease_requested`로 되돌리지 않는다)
        if let existing, existing.state.hasStartIntent || existing.state.isFinished { return .ignored }
        // writer 하나: 같은 세션에 살아 있는 실행이 있으면 lease도 하지 않는다 (cancel은 제외). 답은 같은 task의 이어짐이라 그 task는 건너뛴다
        if item.kind != .cancel {
            let skip = item.kind == .answer ? item.agentTaskID : nil
            if (try? await ledger.liveTask(inSession: item.agentSessionID, excluding: skip)) != nil {
                deferred.insert(item.cursor)
                return .deferred
            }
        }
        var record = existing ?? makeSeen(item, reason: reason, wakeAt: wakeAt, listedAt: listedAt)
        var retried = false
        while true {
            // 재접속 뒤 · 90초 넘게 heartbeat가 없었으면 lease 전에 heartbeat부터 (D2a 6.4)
            if !heartbeatFresh() {
                await sendHeartbeat()
                if !heartbeatFresh() {
                    deferred.insert(item.cursor)
                    return .deferred
                }
            }
            guard networkEnabled, let bridgeID else { return .deferred }
            record.state = .leaseRequested
            record.stateAt = clock.now()
            record.leaseRequestedAt = clock.now()
            do { try await ledger.saveCommand(record) } catch {
                log.log("ledger_write_failed", ["step": .code("lease_requested")])
                return .deferred
            }
            let gen = generation
            let response: BridgeV1AckResponse
            do {
                response = try await authed(.ack, ackNotFound: true) { [client] secret in
                    try await client.ack(BridgeV1AckRequest(bridgeID: bridgeID, commandID: item.id, op: .lease), secret: secret)
                }
            } catch RouteFailure.notFound {
                record.state = .gone
                record.stateAt = clock.now()
                try? await ledger.saveCommand(record)
                deferred.remove(item.cursor)
                return .acted
            } catch {
                // 응답을 모른다: 상태를 그대로 둔다. 다음 목록에서 `leased_by_me`면 lease를 다시 해 `replay`를 받는다
                deferred.insert(item.cursor)
                return .deferred
            }
            guard isCurrent(gen) else { return .deferred }
            switch response {
            case .leased(let payload, let expires), .replay(let payload, let expires):
                deferred.remove(item.cursor)
                // 두 번째 실행 0: 원장이 start_intent 이상이면 응답이 replay여도 다시 띄우지 않는다
                let fresh = (try? await ledger.command(item.id)) ?? record
                if fresh.state.hasStartIntent { return .ignored }
                return await applyLease(payload: payload, expires: expires, record: fresh)
            case .withdrawn(let withdrawn):
                record.state = .withdrawn
                record.reason = withdrawn.raw
                record.stateAt = clock.now()
                try? await ledger.saveCommand(record)
                deferred.remove(item.cursor)
                return .acted
            case .stale(let staleReason):
                if !retried, staleReason == .heartbeatFirst || staleReason == .policyChanged {
                    retried = true
                    if staleReason == .heartbeatFirst {
                        forceHeartbeat = true
                        await sendHeartbeat()
                    }
                    continue
                }
                record.state = .stale
                record.reason = staleReason?.raw
                record.stateAt = clock.now()
                try? await ledger.saveCommand(record)
                deferred.remove(item.cursor)
                return .acted
            case .settled, .unknown:
                // 효과를 만들지 않는 쪽: 실행 0, 다음 목록에서 다시 판단한다
                log.log("lease_unexpected_status", ["command": .id(item.id)])
                return .deferred
            }
        }
    }

    /// lease를 받았다: 원장에 `leased`(글 아닌 값만)를 적고 task를 만든 뒤 kind별로 실행한다
    func applyLease(payload: BridgeV1CommandPayload, expires: Date, record initial: BridgeCommandRecord) async -> ItemResult {
        var record = initial
        let now = clock.now()
        let common: BridgeV1CommandCommon
        switch payload {
        case .message(let command): common = command.common
        case .answer(let command): common = command.common
        case .cancel(let command): common = command.common
        case .unsupported:
            return .ignored
        }
        record.state = .leased
        record.stateAt = now
        record.leasedAt = now
        record.leaseExpiresAt = expires
        record.serverLeasedAt = expires.addingTimeInterval(-330)
        record.stepID = common.stepID
        record.adapter = common.adapter
        record.marker = common.marker
        do {
            try await ledger.saveCommand(record)
            if (try await ledger.task(common.agentTaskID)) == nil {
                var task = BridgeTaskRecord(agentTaskID: common.agentTaskID, agentSessionID: common.agentSessionID, adapter: common.adapter, turnSeq: common.turnSeq, updatedAt: now)
                task.externalSessionID = common.session.externalSessionID
                task.workspaceRef = common.session.workspaceRef
                try await ledger.saveTask(task)
            }
        } catch {
            log.log("ledger_write_failed", ["step": .code("leased")])
            return .deferred
        }
        switch payload {
        case .message(let command): await runMessage(command, record: record)
        case .answer(let command): await runAnswer(command, record: record)
        case .cancel(let command): await runCancel(command, record: record)
        case .unsupported: break
        }
        return .acted
    }

    // MARK: ack (먼저 적고 보낸다)

    func sendAck(_ op: BridgeV1AckOp, commandID: String) async {
        guard let bridgeID else { return }
        let request = BridgeV1AckRequest(bridgeID: bridgeID, commandID: commandID, op: op)
        guard let data = try? TaskforceJSON.encoder().encode(request) else {
            log.log("ack_encode_refused", ["op": .code(op.name)])
            return
        }
        do {
            _ = try await ledger.enqueueAck(commandID: commandID, op: op.name, result: op.resultName, bodyJSON: String(decoding: data, as: UTF8.self))
        } catch {
            log.log("ledger_write_failed", ["step": .code("ack")])
            return
        }
        await flushAcks()
    }

    /// 최종 분류: settled · stale · withdrawn · 404는 지운다. 401 · 403 · 429 · 5xx · 전송 오류는 남기고 뒤로 미룬다
    func flushAcks() async {
        guard networkEnabled, bridgeID != nil, !ackFlushing else { return }
        ackFlushing = true
        defer { ackFlushing = false }
        let gen = generation
        let rows = (try? await ledger.dueAcks(now: clock.now(), limit: 20)) ?? []
        for row in rows {
            guard isCurrent(gen) else { return }
            if Self.bridgeID(in: row.bodyJSON) != bridgeID {
                // 다른 bridge(404 회복 전)에 보낼 ack였다: 그 명령은 이 bridge의 것이 아니다
                try? await ledger.settleAck(key: row.key, commandState: .gone, reason: "bridge_changed")
                continue
            }
            let response: BridgeV1AckResponse
            do {
                response = try await authed(.ack, ackNotFound: true) { [client] secret in try await client.ack(bodyJSON: row.bodyJSON, secret: secret) }
            } catch RouteFailure.notFound {
                try? await ledger.settleAck(key: row.key, commandState: .gone, reason: "not_found")
                continue
            } catch RouteFailure.badRequest {
                try? await ledger.settleAck(key: row.key, commandState: .gone, reason: "bad_request")
                continue
            } catch RouteFailure.rateLimited {
                return
            } catch RouteFailure.blocked, RouteFailure.cancelled, RouteFailure.accountLeft, RouteFailure.accountMismatch, RouteFailure.revoked, RouteFailure.credentialRejected, RouteFailure.bridgeGone {
                return
            } catch {
                let delay = Outbox.backoff(attempts: row.attempts, jitter: Double.random(in: -0.2...0.2))
                try? await ledger.recordAckFailure(key: row.key, nextAttemptAt: clock.now().addingTimeInterval(delay))
                return
            }
            guard isCurrent(gen) else { return }
            let state: BridgeCommandState
            var reason: String?
            switch response {
            case .settled: state = row.op == "decline" ? .declined : .settled
            case .stale(let why): state = row.op == "decline" ? .declined : .stale; reason = why?.raw
            case .withdrawn(let why): state = row.op == "decline" ? .declined : .withdrawn; reason = why.raw
            case .leased, .replay, .unknown: state = .settled
            }
            try? await ledger.settleAck(key: row.key, commandState: state, reason: reason)
            await publish()
        }
    }

    static func bridgeID(in bodyJSON: String) -> String? {
        (try? JSONSerialization.jsonObject(with: Data(bodyJSON.utf8)) as? [String: Any])?["bridge_id"] as? String
    }

    // MARK: kind별 실행

    /// 접수 전 실패: 띄우지 않았다. `failed` 사건으로 정확한 이유를 알린다 (계약 3.2)
    func failBeforeAcceptance(taskID: String, commandID: String, reason: BridgeV1FailureReason) async {
        await appendTaskEvent(taskID: taskID, body: .failed(reason), observed: clock.now(), signal: false) {
            $0.alive = false
            $0.lastState = "failed"
            $0.segmentTerminal = "failed"
        }
        _ = try? await ledger.updateCommand(commandID) { $0.state = .ended; $0.stateAt = clock.now() }
        supervised[taskID] = nil
        await publish()
    }

    /// payload에 모르는 값이 있다: 띄우지 않았다는 것이 원장으로 증명된다 → `readback not_received, process_ended: true`
    func refuseUnknownPayload(record: BridgeCommandRecord) async {
        _ = try? await ledger.updateCommand(record.commandID) { $0.state = .declined; $0.reason = "unknown_payload"; $0.stateAt = clock.now() }
        await sendAck(.readback(.notReceived, processEnded: true), commandID: record.commandID)
    }

    func runMessage(_ command: BridgeV1MessageCommand, record: BridgeCommandRecord) async {
        let common = command.common
        let access: AgentAccess
        switch command.access {
        case .write: access = .write
        case .readOnly: access = .readOnly
        case .unknown: return await refuseUnknownPayload(record: record)
        }
        let mode: AgentPolicyMode
        switch command.policyMode {
        case .manual: mode = .manual
        case .auto: mode = .auto
        case .full: mode = .full
        case .unknown: return await refuseUnknownPayload(record: record)
        }
        guard let adapter = adapters[common.adapter] else {
            return await failBeforeAcceptance(taskID: common.agentTaskID, commandID: record.commandID, reason: .spawnFailed)
        }
        // 접수 전 실패 이유: 설치 안 됨 · 버전 밖 · 로그인 아님 (등급 계산은 서버, 여기서는 시작 직전 사실만 본다)
        let report = await adapter.probe()
        if !report.installed {
            return await failBeforeAcceptance(taskID: common.agentTaskID, commandID: record.commandID, reason: .spawnFailed)
        }
        if !adapter.supportsVersion(report.version) {
            return await failBeforeAcceptance(taskID: common.agentTaskID, commandID: record.commandID, reason: .versionUnsupported)
        }
        if report.signedIn == .no {
            return await failBeforeAcceptance(taskID: common.agentTaskID, commandID: record.commandID, reason: .signInNeeded)
        }
        // 새 세션의 작업 폴더는 D4a가 채우는 resolver가 정한다. 값이 없으면 짐작하지 않고 실패 (Q26)
        var workspace = common.session.workspaceRef
        if common.session.externalSessionID == nil, workspace == nil {
            workspace = await workspaces?.workspace(forSession: common.agentSessionID, adapter: common.adapter)
            if workspace == nil {
                return await failBeforeAcceptance(taskID: common.agentTaskID, commandID: record.commandID, reason: .spawnFailed)
            }
        }
        // writer 하나를 한 번 더 (lease 뒤 경쟁)
        if (try? await ledger.liveTask(inSession: common.agentSessionID, excluding: common.agentTaskID)) != nil {
            return await failBeforeAcceptance(taskID: common.agentTaskID, commandID: record.commandID, reason: .spawnFailed)
        }
        // close_before: 앞 턴의 버려진 요청을 거절로 먼저 닫는다 (계약 3.6)
        if let requestID = command.closeBeforeRequestID {
            let ref = AgentRequestRef(taskID: common.agentTaskID, sessionID: common.agentSessionID, requestID: requestID, externalSessionID: common.session.externalSessionID, workspaceRef: workspace)
            try? await adapter.closeRequest(ref)
            _ = try? await ledger.updateTask(common.agentTaskID) { if !$0.closedRequestIDs.contains(requestID) { $0.closedRequestIDs.append(requestID) } }
        }
        // 먼저 적는다 (start_intent): 이 commit 뒤에는 프로세스를 띄웠을 수 있다 → 다시 띄우지 않는다
        let runID = UUID()
        let resolvedWorkspace = workspace
        let startedAt = clock.now()
        do {
            _ = try await ledger.updateTask(common.agentTaskID) {
                $0.alive = true
                $0.currentCommandID = record.commandID
                $0.segmentTerminal = nil
                $0.processMarker = common.marker
                $0.cancelState = nil
                $0.lastState = "dispatched"
                $0.externalSessionID = common.session.externalSessionID ?? $0.externalSessionID
                $0.workspaceRef = resolvedWorkspace ?? $0.workspaceRef
            }
            _ = try await ledger.updateCommand(record.commandID) { $0.state = .startIntent; $0.stateAt = startedAt }
        } catch {
            log.log("ledger_write_failed", ["step": .code("start_intent")])
            return
        }
        supervised[common.agentTaskID] = Supervised(runID: runID, adapterID: common.adapter, identity: nil)
        await publish()
        let start = AgentTurnStart(
            taskID: common.agentTaskID, sessionID: common.agentSessionID, turnSeq: common.turnSeq, adapter: common.adapter, externalSessionID: common.session.externalSessionID,
            workspaceRef: workspace, resume: common.session.resume, access: access, policyMode: mode, marker: common.marker, text: command.text
        )
        do {
            let identity = try await adapter.startTurn(start, events: makeSink(taskID: common.agentTaskID, runID: runID))
            await recordStarted(taskID: common.agentTaskID, runID: runID, commandID: record.commandID, identity: identity, answer: false)
        } catch let error as AgentStartError {
            await failBeforeAcceptance(taskID: common.agentTaskID, commandID: record.commandID, reason: error.reason)
        } catch {
            await failBeforeAcceptance(taskID: common.agentTaskID, commandID: record.commandID, reason: .spawnFailed)
        }
    }

    /// 프로세스를 띄운 뒤: 정체(pid · 시작 시각 · marker)와 `started`를 적는다. 시작 중에 이미 끝났다는 알림이 왔으면 되돌리지 않는다
    func recordStarted(taskID: String, runID: UUID, commandID: String, identity: AgentProcessIdentity, answer: Bool) async {
        let stillRunning = supervised[taskID]?.runID == runID
        if stillRunning { supervised[taskID]?.identity = identity }
        let now = clock.now()
        _ = try? await ledger.updateTask(taskID) {
            $0.pid = identity.pid
            $0.processStartedAt = identity.startedAt
            $0.processMarker = identity.processMarker
            $0.externalTaskID = identity.externalTaskID ?? $0.externalTaskID
            if stillRunning { $0.alive = true }
        }
        _ = try? await ledger.updateCommand(commandID) {
            if answer {
                $0.answerSentAt = now
                $0.inputAt = identity.inputSentAt
            } else {
                $0.spawnAt = identity.startedAt
                $0.inputAt = identity.inputSentAt
            }
            if stillRunning, ($0.state.rank ?? 0) < (BridgeCommandState.started.rank ?? 4) {
                $0.state = answer ? .inputSent : .started
                $0.stateAt = now
            }
        }
        await publish()
    }

    func runAnswer(_ command: BridgeV1AnswerCommand, record: BridgeCommandRecord) async {
        let common = command.common
        let access: AgentAccess
        switch command.access {
        case .write: access = .write
        case .readOnly: access = .readOnly
        case .unknown: return await refuseUnknownPayload(record: record)
        }
        let mode: AgentPolicyMode
        switch command.policyMode {
        case .manual: mode = .manual
        case .auto: mode = .auto
        case .full: mode = .full
        case .unknown: return await refuseUnknownPayload(record: record)
        }
        let kind: BridgeV1PendingQuestionKind
        switch command.questionKind {
        case .input: kind = .input
        case .approval: kind = .approval
        case .unknown: return await refuseUnknownPayload(record: record)
        }
        let requestID = command.providerRequestID
        guard let task = try? await ledger.task(common.agentTaskID), task.openRequestID == requestID, !task.closedRequestIDs.contains(requestID),
              let adapter = adapters[task.adapter] else {
            // 요청이 이미 닫혔거나 이 Mac이 모르는 요청이다: 전달하지 않고 `request_closed`
            return await closeRequestAndAck(record: record, taskID: common.agentTaskID, requestID: requestID, adapterID: common.adapter, session: common.agentSessionID, adapterClose: false)
        }
        if (try? await ledger.liveTask(inSession: common.agentSessionID, excluding: common.agentTaskID)) != nil {
            return await closeRequestAndAck(record: record, taskID: common.agentTaskID, requestID: requestID, adapterID: task.adapter, session: common.agentSessionID, adapterClose: true)
        }
        let value: AgentAnswerValue
        if command.answeredLocally {
            // 비밀값: 이 Mac의 메모리에만 있다. 없으면(앱 재시작 등) 그 요청을 거절로 닫고 알린다 (Q14)
            guard let local = await secrets.take(requestID: requestID) else {
                return await closeRequestAndAck(record: record, taskID: common.agentTaskID, requestID: requestID, adapterID: task.adapter, session: common.agentSessionID, adapterClose: true)
            }
            value = local
        } else {
            var answers = command.answers
            if let answersIn = answers, let json = try? await ledger.questionMap(taskID: common.agentTaskID, requestID: requestID),
               let map = try? JSONDecoder().decode(Outbox.QuestionMap.self, from: Data(json.utf8)) {
                answers = Outbox.originalAnswers(answersIn, map: map)
            }
            value = AgentAnswerValue(answers: answers, text: command.answerText)
        }
        // 프로세스가 질문을 기다리며 살아 있으면(Codex) 같은 실행의 이어짐이다. 끝났으면(Claude Code) 새 실행 구간이다
        let runID = supervised[common.agentTaskID]?.runID ?? UUID()
        let answeredAt = clock.now()
        do {
            _ = try await ledger.updateTask(common.agentTaskID) {
                $0.alive = true
                $0.currentCommandID = record.commandID
                $0.segmentTerminal = nil
                $0.cancelState = nil
            }
            _ = try await ledger.updateCommand(record.commandID) { $0.state = .startIntent; $0.stateAt = answeredAt }
        } catch {
            log.log("ledger_write_failed", ["step": .code("start_intent")])
            return
        }
        supervised[common.agentTaskID] = Supervised(runID: runID, adapterID: task.adapter, identity: supervised[common.agentTaskID]?.identity)
        await publish()
        let delivery = AgentAnswerDelivery(
            taskID: common.agentTaskID, sessionID: common.agentSessionID, turnSeq: common.turnSeq, adapter: task.adapter, externalSessionID: task.externalSessionID,
            workspaceRef: task.workspaceRef, marker: common.marker, access: access, policyMode: mode, requestID: requestID, kind: kind, structured: command.structured, value: value
        )
        do {
            switch try await adapter.deliverAnswer(delivery, events: makeSink(taskID: common.agentTaskID, runID: runID)) {
            case .delivered(let identity):
                _ = try? await ledger.updateTask(common.agentTaskID) {
                    $0.openRequestID = nil
                    $0.openRequestKind = nil
                    $0.openRequestSecret = false
                    $0.lastState = "running"
                }
                await recordStarted(taskID: common.agentTaskID, runID: runID, commandID: record.commandID, identity: identity, answer: true)
            case .requestClosed:
                supervised[common.agentTaskID] = nil
                _ = try? await ledger.updateTask(common.agentTaskID) { $0.alive = false }
                await closeRequestAndAck(record: record, taskID: common.agentTaskID, requestID: requestID, adapterID: task.adapter, session: common.agentSessionID, adapterClose: false)
            }
        } catch {
            supervised[common.agentTaskID] = nil
            _ = try? await ledger.updateTask(common.agentTaskID) { $0.alive = false }
            await closeRequestAndAck(record: record, taskID: common.agentTaskID, requestID: requestID, adapterID: task.adapter, session: common.agentSessionID, adapterClose: true)
        }
        await publish()
    }

    /// 요청을 거절로 닫고(adapter가 할 수 있으면) 원장에 닫힘을 적은 뒤 `request_closed`로 정산한다. 사용자는 "Question closed before the answer was sent" 줄을 본다
    func closeRequestAndAck(record: BridgeCommandRecord, taskID: String, requestID: String, adapterID: String, session: String, adapterClose: Bool) async {
        if adapterClose, let adapter = adapters[adapterID] {
            let task = try? await ledger.task(taskID)
            try? await adapter.closeRequest(AgentRequestRef(taskID: taskID, sessionID: session, requestID: requestID, externalSessionID: task?.externalSessionID, workspaceRef: task?.workspaceRef))
        }
        _ = try? await ledger.updateTask(taskID) {
            if !$0.closedRequestIDs.contains(requestID) { $0.closedRequestIDs.append(requestID) }
            if $0.openRequestID == requestID {
                $0.openRequestID = nil
                $0.openRequestKind = nil
                $0.openRequestSecret = false
            }
        }
        _ = try? await ledger.updateCommand(record.commandID) { $0.state = .ended; $0.stateAt = clock.now() }
        await sendAck(.requestClosed, commandID: record.commandID)
        await publish()
    }

    func runCancel(_ command: BridgeV1CancelCommand, record: BridgeCommandRecord) async {
        let common = command.common
        if let abandoned = command.abandonedRequestID {
            _ = try? await ledger.updateTask(common.agentTaskID) { if !$0.closedRequestIDs.contains(abandoned) { $0.closedRequestIDs.append(abandoned) } }
            if let task = try? await ledger.task(common.agentTaskID), let adapter = adapters[task.adapter] {
                try? await adapter.closeRequest(AgentRequestRef(taskID: task.agentTaskID, sessionID: task.agentSessionID, requestID: abandoned, externalSessionID: task.externalSessionID, workspaceRef: task.workspaceRef))
            }
        }
        // 모르는 범위는 더 넓게 멈춘다 (안전한 쪽)
        let scope: AgentCancelScope = command.cancelScope == .turn ? .turn : .turnAndProcesses
        let signalled = await interruptIfRunning(taskID: common.agentTaskID, scope: scope)
        _ = try? await ledger.updateCommand(record.commandID) { $0.state = .ended; $0.stateAt = clock.now() }
        // 돌고 있는 실행이 없거나 이 Mac이 모르는 작업이면 "기록 없음"이다
        await sendAck(.complete(signalled ? .sent : .taskUnknown), commandID: record.commandID)
    }

    /// 살아 있는 실행에 중단 신호를 보낸다 (멱등). 보냈으면 true. 먼저 의도(`cancel_state`)를 적는다
    func interruptIfRunning(taskID: String, scope: AgentCancelScope) async -> Bool {
        guard let task = try? await ledger.task(taskID) else { return false }
        guard task.alive || supervised[taskID] != nil, let adapter = adapters[task.adapter] else {
            // 살아 있는 실행이 없다. 이 task가 아직 끝났다고 알리지 않았다면 중단으로 닫는다
            return false
        }
        _ = try? await ledger.updateTask(taskID) { $0.cancelState = "requested" }
        terminatedByUs.insert(taskID)
        let identity = supervised[taskID]?.identity ?? processIdentity(of: task)
        let result = await adapter.interrupt(AgentTurnRef(taskID: taskID, sessionID: task.agentSessionID, identity: identity), scope: scope)
        switch result {
        case .signalled:
            _ = try? await ledger.updateTask(taskID) { $0.cancelState = "signalled" }
            return true
        case .notRunning:
            // adapter는 돌고 있지 않다고 한다: 끝난 것으로 정리한다
            if let entry = supervised[taskID] { await handleEnded(taskID: taskID, runID: entry.runID) } else { await finishEnded(taskID: taskID, byUs: true) }
            return false
        }
    }
}
#endif
