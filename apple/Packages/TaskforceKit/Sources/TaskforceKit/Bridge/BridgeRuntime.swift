#if os(macOS)
import CryptoKit
import Foundation

// Mac bridge 런타임 (OA D2b 계약 2.6–2.14). 파티션(API origin + 사용자) 하나에 하나.
//
// **bridge는 전송이고 판단은 서버다.** 등급 · gate · 상태 전이를 계산하지 않고, "내가 실제로 무엇을 했는가"만 원장에 적고 보고한다.
// - 다시 보내지 않는다: 명령 하나 = 실행 한 번. 원장이 `start_intent` 이상이면 다시 띄우지 않는다.
// - 먼저 적고 그다음 한다: lease 요청 · 프로세스 시작 · 중단 · ack 앞에 의도를 원장에 commit한다.
// - 이 파일은 구성 · 수명 · 등록 · heartbeat · 요청 한도와 오류 처리. 명령은 `+Commands`, 사건 · outbox · 감독은 `+Events`.

public struct BridgeRuntimeConfiguration: Sendable {
    public enum Mode: Sendable, Equatable {
        case normal
        /// BRIDGE_ENABLED가 꺼졌는데 원장에 할 일이 남았다: 새 전달(message · answer) 0, 새 등록 · Connect 0, 사건 · cancel · readback · Stop은 계속 (계약 2.14, 계획 §9 롤백)
        case drain
    }

    public var partition: BridgePartition
    public var appVersion: String
    public var mode: Mode
    /// heartbeat 주기 흔들기 (±초, 계약 2.9: ±2초)
    public var heartbeatJitterSeconds: Double

    public init(partition: BridgePartition, appVersion: String, mode: Mode = .normal, heartbeatJitterSeconds: Double = 0) {
        self.partition = partition
        self.appVersion = appVersion
        self.mode = mode
        self.heartbeatJitterSeconds = heartbeatJitterSeconds
    }
}

public enum BridgeStatus: Equatable, Sendable {
    case notStarted
    case connecting
    case connected
    /// 서버에 닿지 않는다 (재시도 중)
    case offline
    case sleeping
    /// 이 Mac이 폐기됐다 (403). 자동으로 다시 켜지 않는다 — 사용자 행동(`reactivate`)만 (D2a Q21)
    case revoked
    /// 이 계정의 Mac이 10대다 (409). 화면은 D4a · U2
    case tooManyBridges
    /// 401이 되풀이된다 (장치 secret을 한 번 새로 받아도)
    case credentialRejected
    case stopped
}

public struct BridgeRuntimeSnapshot: Equatable, Sendable {
    public var status: BridgeStatus
    /// 살아 있는 실행(`idle`이 아닌 턴)이 있거나 아직 전달하지 않은 비밀값 답이 있다 (종료 확인 · 업데이트 재시작을 막는다)
    public var isBusy: Bool
    /// 원장이 살아 있다고 하는 프로세스(감독 중이든 아니든)가 하나라도 있다. 턴이 `idle`이어도 프로세스가 남아 있을 수 있다 (종료 때 감독 밖 writer를 남기지 않기 위해)
    public var hasLiveProcess: Bool
}

public struct PollOutcome: Equatable, Sendable {
    public var listed = 0
    /// 이번 목록에서 실제로 한 일(lease · 정산 · 결과 확인 · 중단)이 있는 항목 수
    public var handled = 0
    /// 미룬 항목 수 (writer 하나 · 마무리 모드 · heartbeat 먼저)
    public var deferred = 0
    public var failed = false

    /// 돌아온 항목이 모두 이미 처리했거나 미룬 것: 다음 목록은 5초 뒤 (즉시 반환 반복이 요청 한도를 치지 않게, 계약 2.10)
    public var onlyKnownOrDeferred: Bool { listed > 0 && handled == 0 }
}

/// 한 route 호출의 실패. 호출한 쪽이 맥락에 맞게 다룬다
enum RouteFailure: Error, Equatable {
    /// 보내지 않았다: 멈춘 route · 요청 예산 · 네트워크 꺼짐 · 자격 없음 · 늦은 응답
    case blocked
    case accountLeft
    case accountMismatch
    case revoked
    case credentialRejected
    /// 404 (ack 밖): bridge 행이 없다
    case bridgeGone
    /// 404 (ack)
    case notFound
    case offline
    case rateLimited
    case badRequest
    case cancelled
}

public actor BridgeRuntime {
    struct Supervised {
        let runID: UUID
        let adapterID: String
        var identity: AgentProcessIdentity?
        /// adapter가 `inputReached`를 알렸지만 아직 명령 `inputAt`에 적지 못한 시각 (시작 기록이 끝난 뒤 적는다, OA D3a Q5)
        var inputReachedAt: Date?
    }

    // MARK: 의존성
    let config: BridgeRuntimeConfiguration
    let client: BridgeClient
    let ledger: BridgeLedger
    let credentials: any BridgeCredentialStore
    let adapters: [String: any AgentProcess]
    let adapterOrder: [String]
    let clock: BridgeClock
    let wake: (any BridgeWakeSource)?
    let secrets: LocalSecretAnswers
    let workspaces: (any WorkspaceResolver)?
    let sessionStillValid: @Sendable () async -> Bool
    let log: any BridgeLogSink
    let onChange: @Sendable (BridgeRuntimeSnapshot) -> Void
    let partitionID: String

    // MARK: 상태
    var statusValue: BridgeStatus = .notStarted
    /// 올릴 때마다 진행 중이던 요청의 응답을 버린다 (계정 전환 · 절전: 늦은 응답은 원장에 쓰지 않는다)
    var generation = 0
    /// false면 어떤 요청도 보내지 않는다 (멈춤 · 폐기)
    var networkEnabled = true
    var loopsRunning = false
    var wasStarted = false
    var recovered = false
    var bridgeID: String?
    var secret: String?
    var heartbeatInterval: TimeInterval = 30
    var unreachableAfter: TimeInterval = 90
    var longPollMax = 25
    var forceHeartbeat = true
    var lastHeartbeatAttempt: Date?
    var lastHeartbeatOK: Date?
    var appVersionSent = false
    var lastAdapterReportHash: String?
    var pendingAdapterReportHash: String?
    var lastProbeAt: Date?
    var needsReconcile = true
    /// 요청이 전송 오류로 실패했다: 다시 붙으면 lease 전에 heartbeat부터
    var reconnecting = false
    var after = 0
    var deferred: Set<Int> = []
    var forceFullList = true
    var pausedUntil: [BridgeRoute: Date] = [:]
    var requestTimes: [BridgeRoute: [Date]] = [:]
    var supervised: [String: Supervised] = [:]
    /// 원장은 살아 있다고 하지만 감독하는 실행이 없는 task가 마지막으로 확인된 상태: `.alive`(끝내지 못했다) · `.unknown`(끝을 증명하지 못했다)
    var orphanLiveness: [String: AgentLiveness] = [:]
    /// 최근 1시간의 등록 시도 시각 (자동 등록 예산 · 물러서기)
    var registerTimes: [Date] = []
    var terminatedByUs: Set<String> = []
    var pendingWake: BridgeWakeReason?
    var wakeWaiter: CheckedContinuation<BridgeWakeReason?, Never>?
    var loopTask: Task<Void, Never>?
    var wakeForwarder: Task<Void, Never>?
    var flushTask: Task<Void, Never>?
    var flushing = false
    var flushAgain = false
    var ackFlushing = false
    var heartbeatInFlight = false
    var registerTask: Task<Bool, Never>?
    var pendingConnect: [String] = []
    var lastSnapshot: BridgeRuntimeSnapshot?
    var failureStreak = 0
    var firstPollDone = false
    var lastPrune: Date?

    /// 클라이언트 예산: 서버 한도의 80% (events 120 · ack 240 · poll 90 /분, 계약 2.11)
    static let budgets: [BridgeRoute: Int] = [.events: 96, .ack: 192, .commands: 72]

    public init(
        configuration: BridgeRuntimeConfiguration, client: BridgeClient, ledger: BridgeLedger, credentials: any BridgeCredentialStore,
        adapters: [any AgentProcess], clock: BridgeClock = .system, wake: (any BridgeWakeSource)? = nil, secrets: LocalSecretAnswers = LocalSecretAnswers(),
        workspaces: (any WorkspaceResolver)? = nil, sessionStillValid: @escaping @Sendable () async -> Bool = { true }, log: any BridgeLogSink = NoBridgeLog(),
        onChange: @escaping @Sendable (BridgeRuntimeSnapshot) -> Void = { _ in }
    ) {
        self.config = configuration
        self.client = client
        self.ledger = ledger
        self.credentials = credentials
        self.adapters = Dictionary(adapters.map { ($0.adapter, $0) }, uniquingKeysWith: { first, _ in first })
        self.adapterOrder = adapters.map(\.adapter).sorted()
        self.clock = clock
        self.wake = wake
        self.secrets = secrets
        self.workspaces = workspaces
        self.sessionStillValid = sessionStillValid
        self.log = log
        self.onChange = onChange
        self.partitionID = configuration.partition.id
        // 아직 전달하지 않은 비밀값 답이 생기거나 사라지면 "바쁨"이 바뀐다 (종료 확인 · 업데이트 재시작)
        Task { [weak self, secrets] in
            guard let runtime = self else { return }
            await secrets.observe { [weak runtime] _ in Task { await runtime?.publish() } }
        }
        // adapter마다 한 번: 도구 판정은 이 런타임(이 파티션의 bridge id · secret)으로만 묻는다 (OA D3a Q12, ONE-TF-09)
        let services = AgentRuntimeServices { [weak self] query in
            guard let runtime = self else { throw AgentToolDecisionError.unavailable }
            return try await runtime.decideTool(query)
        }
        for adapter in adapters { adapter.attach(services) }
    }

    // MARK: 도구 판정 (OA D3a 2.17)

    static let toolDecisionTimeout: TimeInterval = 1.0

    /// `POST /api/v1/bridge/tool-decision`: 1.0초 · 재시도 0. 보내지 못했거나(등록 전 · 네트워크 꺼짐 · 멈춘 상태) 답을 못 받으면 `unavailable`(adapter가 defer),
    /// 폐기된 Mac(403)이면 `revoked`(adapter가 deny). 401에 다시 등록하지 않는다: 훅 예산 안에서 secret을 돌리지 않는다 (defer로 둔다)
    func decideTool(_ query: BridgeV1ToolDecisionQuery) async throws -> BridgeV1ToolDecisionResponse {
        if statusValue == .revoked { throw AgentToolDecisionError.revoked }
        guard networkEnabled, statusValue != .stopped, let bridgeID, let secret else { throw AgentToolDecisionError.unavailable }
        let gen = generation
        let response: BridgeV1ToolDecisionResponse
        do {
            response = try await client.toolDecision(BridgeV1ToolDecisionRequest(bridgeID: bridgeID, query: query), secret: secret, timeout: Self.toolDecisionTimeout)
        } catch BridgeClientError.forbidden {
            throw AgentToolDecisionError.revoked
        } catch {
            throw AgentToolDecisionError.unavailable
        }
        guard isCurrent(gen) else { throw AgentToolDecisionError.unavailable }
        return response
    }

    // MARK: 관찰

    public var status: BridgeStatus { statusValue }

    /// 감독 중인 살아 있는 턴이나 아직 전달하지 않은 비밀값 답이 있나. 확인하지 못한 고아(`orphanLiveness`)는 세지 않는다:
    /// 그 세션의 다음 실행은 `liveTask`가 계속 막지만, 끝을 증명할 수 없는 프로세스가 Sparkle 재시작을 영원히 막아서는 안 된다
    public func isBusy() async -> Bool {
        let tasks = (try? await ledger.allTasks()) ?? []
        if tasks.contains(where: { $0.alive && $0.lastState != "idle" && supervised[$0.agentTaskID] != nil }) { return true }
        return await secrets.hasPending
    }

    func setStatus(_ value: BridgeStatus) {
        // 멈춘 런타임의 `.stopped`는 멈추기 전에 시작한 요청(heartbeat · 등록)이 뒤늦게 끝나도 되돌아가지 않는다: `resume()`이 네트워크를 다시 켠 뒤에만 바뀐다.
        // 호스트가 이 값으로 런타임을 놓아도 되는지 가른다 (검토 반영 2 8장 4)
        if statusValue == .stopped, !networkEnabled, value != .stopped { return }
        guard statusValue != value else { return }
        statusValue = value
        log.log("status", ["to": .code(String(describing: value))])
    }

    /// 상태 · 바쁨이 바뀌었으면 알린다
    /// 살아 있는 프로세스가 있나 (감독 중이거나 원장이 살아 있다고 하는 것)
    public func hasLiveProcess() async -> Bool {
        if !supervised.isEmpty { return true }
        return ((try? await ledger.allTasks()) ?? []).contains { $0.alive }
    }

    func publish() async {
        let snapshot = BridgeRuntimeSnapshot(status: statusValue, isBusy: await isBusy(), hasLiveProcess: await hasLiveProcess())
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        onChange(snapshot)
    }

    var active: Bool { networkEnabled && statusValue != .stopped }

    func isCurrent(_ gen: Int) -> Bool { gen == generation && networkEnabled }

    // MARK: 수명

    /// 복구(고아 정리)를 하고 루프를 돌린다
    public func start() {
        guard !loopsRunning, statusValue != .stopped else { return }
        wasStarted = true
        loopsRunning = true
        let gen = generation
        loopTask = Task { [weak self] in
            await self?.recover()
            await self?.mainLoop(generation: gen)
        }
    }

    /// 네트워크를 끊고 루프를 멈춘다 (계정이 떠남 · 앱 종료). 살아 있는 실행은 건드리지 않는다: 그 파티션 원장에만 계속 기록한다 (Q5)
    public func stop() async {
        networkEnabled = false
        generation += 1
        loopsRunning = false
        loopTask?.cancel()
        loopTask = nil
        flushTask?.cancel()
        flushTask = nil
        wakeForwarder?.cancel()
        wakeForwarder = nil
        resumeWaiter(nil)
        setStatus(.stopped)
        await wake?.stop()
        await publish()
    }

    /// 떠났던 계정이 돌아왔다(재로그인): 네트워크를 다시 켜고 루프를 돌린다. 감독 중인 실행 · 원장은 그대로 이어진다
    /// (같은 원장에 두 번째 런타임을 만들면 감독 밖 실행으로 보고 끝내므로, 호스트는 남아 있는 런타임을 이어 쓴다)
    public func resume() async {
        guard statusValue == .stopped else { return }
        networkEnabled = true
        forceHeartbeat = true
        reconnecting = true
        needsReconcile = true
        firstPollDone = false
        setStatus(.connecting)
        start()
        await publish()
    }

    /// 멈추고 원장을 닫는다 (더는 이 런타임을 쓰지 않을 때)
    public func close() async {
        await stop()
        await ledger.close()
    }

    /// 사용자가 Quit을 골랐다: 살아 있는 턴을 중단하고 끝남을 본 턴은 `cancelled` 사건으로 알린 뒤 outbox를 최대 3초 비운다 (Q7, ONE-TF-15 a)
    public func shutdown(interrupt: Bool) async {
        if interrupt {
            await interruptAll(reason: "shutdown")
            await endRemainingRuns()
        }
        if networkEnabled, bridgeID != nil {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.flushOutbox() }
                group.addTask { try? await self.clock.sleep(.seconds(3)) }
                _ = await group.next()
                group.cancelAll()
            }
        }
        await ledger.checkpoint()
        await stop()
    }

    /// 계정 삭제: 살아 있는 턴을 모두 중단한다 (원장 · 자격은 호출한 쪽이 지운다, Q22).
    /// 돌려주는 값은 **끝내지 못했거나 끝을 증명하지 못한 프로세스 수**다: 원장을 지우면 그 정체(pid · marker)도 사라져 감독 밖 writer가 남을 수 있으므로, 호출한 쪽이 정리가 덜 됐다고 알린다 (검토 반영 2 8장 6)
    @discardableResult
    public func interruptLiveTurns() async -> Int {
        await interruptAll(reason: "account_deleted")
        await endRemainingRuns()
        await settleOrphans() // 감독 밖에 남은 프로세스도 끝낸다 (원장을 지우기 전에 감독 밖 writer를 남기지 않는다)
        let unresolved = Set(supervised.keys).union(orphanLiveness.keys).count
        if unresolved > 0 { log.log("account_deleted_unresolved", ["count": .count(unresolved)]) }
        return unresolved
    }

    /// 중단 신호 뒤 3초 유예 동안 감독 중인 실행이 끝나기를 기다리고, 그래도 남은 실행은 `terminateOrphan`으로 끝낸다 (adapter가 SIGTERM → SIGKILL, 신호마다 정체 재확인).
    /// 신호를 무시하는 프로세스가 앱 종료 · 계정 삭제 뒤에 감독 밖 writer로 남지 않게 한다 (검토 반영 7장 C12)
    func endRemainingRuns() async {
        let deadline = clock.now().addingTimeInterval(3)
        while !supervised.isEmpty, clock.now() < deadline {
            try? await clock.sleep(.milliseconds(100))
        }
        for (taskID, entry) in supervised {
            guard let adapter = adapters[entry.adapterID] else { continue }
            let task = try? await ledger.task(taskID)
            guard let identity = entry.identity ?? task.map(processIdentity(of:)) else { continue }
            terminatedByUs.insert(taskID)
            switch await adapter.terminateOrphan(identity) {
            case .ended:
                log.log("run_terminated", ["task": .id(taskID)])
                await handleEnded(taskID: taskID, runID: entry.runID)
            case .alive, .unknown:
                log.log("run_terminate_failed", ["task": .id(taskID)])
            }
        }
    }

    /// 살아 있는 모든 실행에 중단 신호 (종료 · 폐기 · 서버가 모르는 task)
    func interruptAll(reason: String) async {
        for (taskID, entry) in supervised {
            await interruptTask(taskID, entry: entry, scope: .turnAndProcesses)
        }
        log.log("interrupt_all", ["reason": .code(reason), "count": .count(supervised.count)])
    }

    func interruptTask(_ taskID: String, entry: Supervised, scope: AgentCancelScope) async {
        guard let adapter = adapters[entry.adapterID] else { return }
        terminatedByUs.insert(taskID)
        _ = try? await ledger.updateTask(taskID) { $0.cancelState = "requested" }
        let ref = AgentTurnRef(taskID: taskID, sessionID: (try? await ledger.task(taskID))?.agentSessionID ?? "", identity: entry.identity)
        _ = await adapter.interrupt(ref, scope: scope)
    }

    /// 절전: 긴 대기 · heartbeat 작업을 취소하고 Realtime을 닫고 원장을 checkpoint한다. 에이전트 프로세스는 건드리지 않는다 (시스템이 함께 멈춘다)
    public func prepareForSleep() async {
        guard statusValue != .stopped, statusValue != .sleeping else { return }
        generation += 1
        loopsRunning = false
        loopTask?.cancel()
        loopTask = nil
        flushTask?.cancel()
        flushTask = nil
        wakeForwarder?.cancel()
        wakeForwarder = nil
        resumeWaiter(nil)
        await wake?.stop()
        await ledger.checkpoint()
        setStatus(.sleeping)
        await publish()
    }

    /// 깨어남: 모든 task 생존 확인 → heartbeat(lease보다 먼저) → outbox 비우기 → reconcile 사건 → Realtime 다시 구독 → 목록 (계약 2.9)
    public func didWake() async {
        guard statusValue == .sleeping else { return }
        await refreshLiveness()
        forceHeartbeat = true
        reconnecting = true
        needsReconcile = true
        lastProbeAt = nil
        firstPollDone = false
        setStatus(.connecting)
        if wasStarted {
            loopsRunning = true
            let gen = generation
            loopTask = Task { [weak self] in await self?.mainLoop(generation: gen) }
        }
        await publish()
    }

    #if DEBUG
    /// 정리 없이 버린다 (강제 종료 흉내, 시험 전용 — Release에는 없다): 원장만 닫는다
    public func abandonForTest() async {
        networkEnabled = false
        generation += 1
        loopsRunning = false
        loopTask?.cancel()
        flushTask?.cancel()
        wakeForwarder?.cancel()
        resumeWaiter(nil)
        await ledger.close()
        statusValue = .stopped
    }
    #endif

    // MARK: 한 번씩 (루프가 부르고, 시험도 직접 부른다)

    /// 복구 · 등록 · heartbeat · ack · 사건 비우기 · reconcile
    public func tick(reason: BridgeWakeReason = .heartbeat) async {
        await housekeeping()
        guard active else { return }
        _ = await poll(wait: 0, reason: reason)
        await flushAcks()
    }

    public func housekeeping() async {
        await recover()
        guard active else { return }
        // 마무리 모드: 끝낼 일이 없으면 요청을 하나도 보내지 않고 멈춘다 (호스트가 런타임을 놓는다)
        if await finishDrainIfDone() { return }
        await pruneIfDue()
        guard await ensureRegistered() else { return }
        if heartbeatDue() { await sendHeartbeat() }
        await flushAcks()
        await flushOutbox()
        await enqueueReconcileIfNeeded()
        _ = await finishDrainIfDone()
    }

    /// 마무리 모드(`BRIDGE_ENABLED` 꺼짐 + 원장에 할 일)에서 감독 중인 실행도, 끝나지 않은 명령 · 보낼 사건 · ack도, 살아 있는 task도 없으면 멈춘다 (계약 2.14)
    func finishDrainIfDone() async -> Bool {
        guard config.mode == .drain, supervised.isEmpty, let pending = try? await ledger.hasPendingWork(), !pending else { return false }
        log.log("drain_done", [:])
        await stop()
        return true
    }

    // MARK: 루프

    func mainLoop(generation gen: Int) async {
        // 루프가 스스로 끝나면(폐기 · 네트워크 꺼짐) 도는 중이라는 표시를 비운다: 그래야 `reactivate()`가 루프를 다시 시작할 수 있다
        defer {
            if generation == gen {
                loopsRunning = false
                loopTask = nil
            }
        }
        await startWake()
        while !Task.isCancelled, isCurrent(gen) {
            await housekeeping()
            guard !Task.isCancelled, isCurrent(gen) else { return }
            if [.revoked, .tooManyBridges, .credentialRejected].contains(statusValue) {
                // 사용자 행동을 기다린다 (Connect · Reconnect this Mac)
                try? await clock.sleep(.seconds(30))
                continue
            }
            let started = clock.now()
            var outcome = PollOutcome()
            if await wake?.isSubscribed == true {
                if firstPollDone {
                    // Realtime이 붙어 있는 동안은 긴 대기를 돌리지 않는다 (서버 DB 부하). 신호 · heartbeat 주기를 기다린 뒤 한 번 본다
                    guard let reason = await waitForWake(timeout: secondsUntilHeartbeat()) else { return }
                    guard isCurrent(gen) else { return }
                    if reason == .heartbeat, heartbeatDue() { continue }
                    outcome = await poll(wait: 0, reason: reason)
                } else {
                    // 시작 · 깨어난 직후: 구독 전에 쌓인 명령을 한 번 바로 본다
                    outcome = await poll(wait: 0, reason: .startup)
                }
            } else {
                // 끊겼거나 구독이 안 됐다: 긴 대기를 이어서 돈다. heartbeat가 제때 가도록 대기를 줄인다
                let wait = max(1, min(longPollMax, Int(secondsUntilHeartbeat().rounded(.up))))
                outcome = await poll(wait: wait, reason: firstPollDone ? .longPoll : .startup)
            }
            firstPollDone = true
            guard isCurrent(gen), !Task.isCancelled else { return }
            if outcome.failed {
                failureStreak += 1
                let delay = Outbox.backoff(attempts: failureStreak - 1, jitter: Double.random(in: -0.2...0.2))
                try? await clock.sleep(.seconds(delay))
                continue
            }
            failureStreak = 0
            // 목록 사이 최소 2초, 돌아온 항목이 모두 처리했거나 미룬 것이면 5초 (분당 한도를 넘지 않게)
            let gap: TimeInterval = outcome.onlyKnownOrDeferred ? 5 : 2
            let elapsed = clock.now().timeIntervalSince(started)
            if elapsed < gap { try? await clock.sleep(.seconds(gap - elapsed)) }
        }
    }

    func startWake() async {
        guard let wake, let bridgeID, networkEnabled else { return }
        wakeForwarder?.cancel()
        let stream = await wake.start(bridgeID: bridgeID)
        wakeForwarder = Task { [weak self] in
            for await _ in stream {
                await self?.nudge(.realtime)
            }
        }
    }

    /// 깨우기 신호 (Realtime 신호 · heartbeat `pending_commands`)
    func nudge(_ reason: BridgeWakeReason) {
        if let waiter = wakeWaiter {
            wakeWaiter = nil
            waiter.resume(returning: reason)
        } else if pendingWake == nil {
            pendingWake = reason
        }
    }

    func resumeWaiter(_ reason: BridgeWakeReason?) {
        if let waiter = wakeWaiter {
            wakeWaiter = nil
            waiter.resume(returning: reason)
        }
        pendingWake = nil
    }

    func waitForWake(timeout: TimeInterval) async -> BridgeWakeReason? {
        if let pending = pendingWake {
            pendingWake = nil
            return pending
        }
        let timer = Task { [weak self, clock] in
            try? await clock.sleep(.seconds(max(0.05, timeout)))
            if !Task.isCancelled { await self?.nudge(.heartbeat) }
        }
        let reason: BridgeWakeReason? = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<BridgeWakeReason?, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                } else {
                    wakeWaiter = continuation
                }
            }
        } onCancel: {
            Task { await self.resumeWaiter(nil) }
        }
        timer.cancel()
        return reason
    }

    func secondsUntilHeartbeat() -> TimeInterval {
        guard let last = lastHeartbeatAttempt else { return 0 }
        let jitter = config.heartbeatJitterSeconds == 0 ? 0 : Double.random(in: -config.heartbeatJitterSeconds...config.heartbeatJitterSeconds)
        return max(0, heartbeatInterval + jitter - clock.now().timeIntervalSince(last))
    }

    func heartbeatDue() -> Bool {
        if forceHeartbeat || reconnecting { return true }
        guard let last = lastHeartbeatAttempt else { return true }
        return clock.now().timeIntervalSince(last) >= max(1, heartbeatInterval - config.heartbeatJitterSeconds)
    }

    /// 마지막 성공 heartbeat가 90초 안인가 (lease 전에 필요한 조건, D2a 6.4)
    func heartbeatFresh() -> Bool {
        guard let ok = lastHeartbeatOK, !reconnecting, !forceHeartbeat else { return false }
        return clock.now().timeIntervalSince(ok) <= unreachableAfter
    }

    // MARK: 복구 (재시작 · 고아, 계약 2.9)

    /// 원장을 읽어 상태를 되살리고 감독 밖에 남은 프로세스를 끝낸다 (Q6): 새 실행은 lease가 새로 성공한 명령에만
    public func recover() async {
        guard !recovered else { return }
        recovered = true
        if let meta = try? await ledger.meta() {
            bridgeID = meta.bridgeID
            lastHeartbeatOK = meta.lastHeartbeatOKAt
            // 원장에 적힌 서버 숫자도 범위를 자른다 (서버 값은 신뢰 경계 밖이다)
            if let seconds = meta.heartbeatIntervalSeconds { heartbeatInterval = TimeInterval(BridgeV1Clamp.clamp(seconds, to: BridgeV1Clamp.heartbeatSeconds)) }
            if let seconds = meta.unreachableAfterSeconds { unreachableAfter = TimeInterval(BridgeV1Clamp.clamp(seconds, to: BridgeV1Clamp.unreachableSeconds)) }
            if let seconds = meta.longPollMaxSeconds { longPollMax = BridgeV1Clamp.clamp(seconds, to: BridgeV1Clamp.longPollSeconds) }
            lastAdapterReportHash = meta.adaptersReportHash
        }
        secret = (try? credentials.secret(partition: partitionID)) ?? nil
        await settleOrphans()
        needsReconcile = true
        await publish()
    }

    /// 보관 정리: 끝난 명령 · 죽은 outbox 행 7일, 전체 글 30일, 보내지 못한 사건 7일 (Q16 A). 시작 때와 한 시간마다
    func pruneIfDue() async {
        let now = clock.now()
        if let last = lastPrune, now.timeIntervalSince(last) < 3600 { return }
        lastPrune = now
        guard let report = try? await ledger.prune(now: now) else { return }
        log.log("pruned", ["commands": .count(report.commands), "dead": .count(report.deadLetters), "expired": .count(report.expiredEvents), "texts": .count(report.fullTexts)])
    }

    func processIdentity(of task: BridgeTaskRecord) -> AgentProcessIdentity {
        AgentProcessIdentity(pid: task.pid, startedAt: task.processStartedAt ?? task.updatedAt, processMarker: task.processMarker ?? "", externalTaskID: task.externalTaskID)
    }

    /// 원장은 살아 있다고 하는데 감독하는 실행이 없는 task(강제 종료 뒤 고아)를 끝내고 원장으로 정산한다. 접수 뒤였으면 `cancelled`
    func settleOrphans() async {
        let tasks = (try? await ledger.allTasks()) ?? []
        for task in tasks where task.alive && supervised[task.agentTaskID] == nil {
            guard let adapter = adapters[task.adapter] else {
                log.log("orphan_no_adapter", ["task": .id(task.agentTaskID)])
                continue
            }
            let identity = processIdentity(of: task)
            switch await adapter.liveness(identity) {
            case .alive:
                switch await adapter.terminateOrphan(identity) {
                case .ended:
                    orphanLiveness[task.agentTaskID] = nil
                    log.log("orphan_terminated", ["task": .id(task.agentTaskID)])
                    await finishEnded(taskID: task.agentTaskID, byUs: true)
                case .alive:
                    // 살아 있음을 확인했지만 끝내지 못했다: 이 세션의 다음 실행은 막은 채로 둔다 (writer 하나)
                    orphanLiveness[task.agentTaskID] = .alive
                    log.log("orphan_stuck", ["task": .id(task.agentTaskID)])
                case .unknown:
                    orphanLiveness[task.agentTaskID] = .unknown
                    log.log("orphan_stuck", ["task": .id(task.agentTaskID)])
                }
            case .ended:
                orphanLiveness[task.agentTaskID] = nil
                await finishEnded(taskID: task.agentTaskID, byUs: false)
            case .unknown:
                // 확인 안 된 고아: 끝났다고도 살아 있다고도 보고하지 않는다 (heartbeat `process_alive` false, 결과 확인은 `unknown`). 세션은 계속 막는다
                orphanLiveness[task.agentTaskID] = .unknown
                log.log("orphan_unknown", ["task": .id(task.agentTaskID)])
            }
        }
        await publish()
    }

    /// 깨어난 뒤: 감독 중인 실행의 생존을 다시 확인한다 (끝났는데 사건이 안 온 것을 찾는다)
    func refreshLiveness() async {
        for (taskID, entry) in supervised {
            guard let identity = entry.identity, let adapter = adapters[entry.adapterID] else { continue }
            if case .ended = await adapter.liveness(identity) {
                await handleEnded(taskID: taskID, runID: entry.runID)
            }
        }
    }

    // MARK: 등록 (계약 2.12 · Q20)

    /// 이 파티션에 secret이 없을 때 · 401 회복 · 404 회복 · 사용자가 Connect를 눌렀을 때만 (실행마다 등록하지 않는다)
    func ensureRegistered() async -> Bool {
        if bridgeID != nil, secret != nil { return true }
        if [.revoked, .tooManyBridges, .credentialRejected].contains(statusValue) { return false }
        guard config.mode == .normal else { return false }
        return await register(reactivate: false, reason: "initial")
    }

    func register(reactivate: Bool, reason: String) async -> Bool {
        if let running = registerTask { return await running.value }
        let task = Task { await self.performRegister(reactivate: reactivate, reason: reason) }
        registerTask = task
        let result = await task.value
        registerTask = nil
        return result
    }

    func probeAll() async -> [BridgeV1AdapterReport] {
        var reports: [BridgeV1AdapterReport] = []
        for id in adapterOrder {
            guard let adapter = adapters[id] else { continue }
            var report = await adapter.probe()
            report.version = OutgoingValues.adapterVersion(report.version) // 서버는 50자를 넘는 version을 400으로 거절한다
            reports.append(report)
        }
        lastProbeAt = clock.now()
        return reports
    }

    /// 자동 등록(처음 · 401 회복)의 예산과 물러서기 (검토 반영 7장 D · security 3): 서버는 시간당 20회로 막는다. 우리는 1시간에 10회까지,
    /// 시도마다 간격을 두 배로 늘린다 (최대 5분). **성공으로 초기화하지 않는다**: 등록이 성공해도 곧 다시 401/404가 되는 되풀이가 서버 한도를 쓰지 못하게.
    /// 사용자가 누른 Connect · Reconnect는 막지 않는다 (시도는 센다)
    func registerAllowed() -> Bool {
        let now = clock.now()
        registerTimes = registerTimes.filter { now.timeIntervalSince($0) < 3600 }
        guard registerTimes.count < Self.registerBudgetPerHour else { return false }
        guard let last = registerTimes.last else { return true }
        let delay = registerTimes.count <= 1 ? 0 : min(300, pow(2.0, Double(registerTimes.count - 1)))
        return now.timeIntervalSince(last) >= delay
    }

    static let registerBudgetPerHour = 10

    func performRegister(reactivate: Bool, reason: String) async -> Bool {
        guard networkEnabled else { return false }
        if let until = pausedUntil[.register], clock.now() < until { return false }
        if reason == "initial" || reason == "recover_401" {
            guard registerAllowed() else {
                log.log("register_backoff", ["reason": .code(reason)])
                return false
            }
        }
        registerTimes.append(clock.now())
        let gen = generation
        let deviceID: String
        do {
            if let existing = try credentials.deviceID(partition: partitionID) {
                deviceID = existing
            } else {
                deviceID = BridgeCredentialRules.newDeviceID()
                try credentials.save(deviceID: deviceID, partition: partitionID)
            }
        } catch {
            log.log("credential_store_failed", ["step": .code("device_id")])
            return false
        }
        let reports = await probeAll()
        let request = BridgeV1RegisterRequest(deviceID: deviceID, appVersion: config.appVersion, adapters: reports, connect: pendingConnect, reactivate: reactivate)
        setStatus(.connecting)
        let response: BridgeV1RegisterResponse
        do {
            response = try await client.register(request)
        } catch let error as BridgeClientError {
            guard isCurrent(gen) else { return false }
            switch error {
            case .forbidden: setStatus(.revoked)
            case .tooManyBridges: setStatus(.tooManyBridges)
            case .rateLimited(let after): pausedUntil[.register] = clock.now().addingTimeInterval(after)
            case .unauthorized:
                if await sessionStillValid() { setStatus(.credentialRejected) } else { await accountLeft() }
            case .accountChanged, .notSignedIn: break
            default:
                setStatus(.offline)
                reconnecting = true
            }
            log.log("register_failed", ["reason": .code(reason), "error": .code(String(describing: error).prefix(40).description)])
            await publish()
            return false
        } catch {
            return false
        }
        guard isCurrent(gen) else { return false }
        guard BridgeCredentialRules.isValidSecret(response.bridgeSecret) else {
            log.log("register_bad_secret", [:])
            return false
        }
        do {
            try credentials.save(secret: response.bridgeSecret, partition: partitionID)
        } catch {
            log.log("credential_store_failed", ["step": .code("secret")])
            return false
        }
        secret = response.bridgeSecret
        bridgeID = response.bridgeID
        heartbeatInterval = TimeInterval(response.heartbeatIntervalSeconds)
        unreachableAfter = TimeInterval(response.unreachableAfterSeconds)
        longPollMax = response.longPollMaxSeconds
        let now = clock.now()
        try? await ledger.updateMeta {
            $0.bridgeID = response.bridgeID
            $0.registeredAt = now
            $0.heartbeatIntervalSeconds = response.heartbeatIntervalSeconds
            $0.unreachableAfterSeconds = response.unreachableAfterSeconds
            $0.longPollMaxSeconds = response.longPollMaxSeconds
        }
        pendingConnect = []
        appVersionSent = false
        forceHeartbeat = true
        forceFullList = true
        failureStreak = 0
        if statusValue == .revoked || statusValue == .credentialRejected || statusValue == .tooManyBridges { setStatus(.connecting) }
        log.log("registered", ["reason": .code(reason), "connections": .count(response.connections.count)])
        if loopsRunning { await startWake() }
        await publish()
        return true
    }

    /// 사용자가 Connect를 눌렀다 (`connect: [adapter]`, 화면은 U2 · D4a). 마무리 모드에서는 새 등록 · Connect 0
    public func connect(adapters ids: [String]) async -> Bool {
        guard config.mode == .normal, networkEnabled else { return false }
        // probe 보고가 없는(이 앱에 adapter가 없는) 것은 connect하지 않는다: 서버는 보고 없는 adapter의 connect를 거절한다
        let connectable = Set(ids).filter { adapters[$0] != nil }
        guard !connectable.isEmpty else { return false }
        pendingConnect = connectable.sorted()
        return await register(reactivate: false, reason: "connect")
    }

    /// 사용자가 Reconnect this Mac을 눌렀다: 폐기된 Mac을 `reactivate: true`로 되살린다. 자동으로는 부르지 않는다 (Q21)
    public func reactivate() async -> Bool {
        guard config.mode == .normal, statusValue != .stopped else { return false }
        networkEnabled = true
        let result = await register(reactivate: true, reason: "reactivate")
        if !result, statusValue == .revoked { networkEnabled = false }
        if result, wasStarted, !loopsRunning, statusValue != .stopped {
            // 폐기(403)로 루프가 끝났다: 되살아난 Mac은 heartbeat · 목록을 다시 돈다
            firstPollDone = false
            start()
        }
        return result
    }

    // MARK: 요청 한도 · 오류 (계약 2.11)

    func budgetAllows(_ route: BridgeRoute) -> Bool {
        guard let limit = Self.budgets[route] else { return true }
        let now = clock.now()
        let recent = (requestTimes[route] ?? []).filter { now.timeIntervalSince($0) < 60 }
        requestTimes[route] = recent
        return recent.count < limit
    }

    func recordRequest(_ route: BridgeRoute) {
        requestTimes[route, default: []].append(clock.now())
    }

    /// 장치 자격이 필요한 route 호출. 멈춘 route · 예산 · 네트워크 꺼짐이면 보내지 않고, 늦은 응답(세대가 바뀜)은 버린다.
    /// 401: 세션이 끝났으면 계정 떠남, 아니면 장치 secret 불일치로 보고 **한 번** 다시 등록해 되풀이한다. 403: 폐기. 404: bridge 없음(ack은 그 명령만). 429: 그 route만 멈춤
    func authed<T: Sendable>(_ route: BridgeRoute, ackNotFound: Bool = false, _ operation: @Sendable (String) async throws -> T) async throws -> T {
        guard networkEnabled else { throw RouteFailure.blocked }
        // 사용자 행동(Connect · Reconnect this Mac)을 기다리는 상태에서는 보내지 않는다
        guard ![.revoked, .tooManyBridges, .credentialRejected].contains(statusValue) else { throw RouteFailure.blocked }
        if let until = pausedUntil[route], clock.now() < until { throw RouteFailure.blocked }
        guard budgetAllows(route) else { throw RouteFailure.blocked }
        let gen = generation
        var retriedAfter401 = false
        var retriedWithNewerSecret = false
        while true {
            guard let current = secret else { throw RouteFailure.blocked }
            recordRequest(route)
            do {
                let value = try await operation(current)
                guard isCurrent(gen) else { throw RouteFailure.blocked }
                return value
            } catch is CancellationError {
                throw RouteFailure.cancelled
            } catch let error as BridgeClientError {
                guard isCurrent(gen) else { throw RouteFailure.blocked }
                switch error {
                case .unauthorized:
                    // 실패한 요청이 쓴 secret이 이미 낡았다(그 사이 다른 호출이 다시 등록했다): 새 secret으로 다시 보낸다. 또 등록해 secret을 돌리지 않는다
                    if !retriedWithNewerSecret, let latest = secret, latest != current {
                        retriedWithNewerSecret = true
                        continue
                    }
                    if retriedAfter401 {
                        setStatus(.credentialRejected)
                        await publish()
                        throw RouteFailure.credentialRejected
                    }
                    if !(await sessionStillValid()) {
                        await accountLeft()
                        throw RouteFailure.accountLeft
                    }
                    retriedAfter401 = true
                    guard config.mode == .normal, await register(reactivate: false, reason: "recover_401") else {
                        setStatus(.credentialRejected)
                        await publish()
                        throw RouteFailure.credentialRejected
                    }
                    guard isCurrent(gen) else { throw RouteFailure.blocked }
                case .forbidden:
                    await handleRevoked()
                    throw RouteFailure.revoked
                case .notFound:
                    if ackNotFound { throw RouteFailure.notFound }
                    await clearBridge()
                    throw RouteFailure.bridgeGone
                case .rateLimited(let after):
                    pausedUntil[route] = clock.now().addingTimeInterval(after)
                    log.log("rate_limited", ["route": .code(route.rawValue), "seconds": .count(Int(after))])
                    throw RouteFailure.rateLimited
                case .transport, .server, .decoding:
                    // 2xx인데 본문을 읽을 수 없는 것(로그인 안내 창 같은 중간 장치)도 일시 실패다: 물러섰다 다시 보내고 행을 유지한다.
                    // 묶음을 쪼개거나 dead-letter하는 것은 진짜 HTTP 400일 때만이다
                    setStatus(.offline)
                    reconnecting = true
                    await publish()
                    throw RouteFailure.offline
                case .accountChanged, .notSignedIn:
                    throw RouteFailure.accountMismatch
                case .insecureEndpoint:
                    // https도 loopback도 아닌 주소: 토큰 · secret을 보내지 않았다. 조용히 막고 한 번만 기록한다
                    log.log("endpoint_insecure", [:])
                    throw RouteFailure.blocked
                case .badRequest, .conflict, .tooManyBridges:
                    throw RouteFailure.badRequest
                }
            }
        }
    }

    /// 403: 이 Mac이 폐기됐다. 네트워크 멈춤 · 살아 있는 턴 중단 · 원장 보존 (자동 reactivate 금지, Q21)
    func handleRevoked() async {
        guard statusValue != .revoked else { return }
        setStatus(.revoked)
        await interruptAll(reason: "revoked")
        networkEnabled = false
        await publish()
    }

    /// 404: bridge 행이 없다 (다른 환경 · 지워짐). bridge id를 비우고(device_id는 유지) 다시 등록한다
    func clearBridge() async {
        bridgeID = nil
        secret = nil
        try? await ledger.updateMeta { $0.bridgeID = nil }
        log.log("bridge_gone", [:])
    }

    /// 401인데 세션도 끝났다: 계정이 떠났다. `BridgeHost`가 곧 멈추지만 그 전에도 보내지 않는다
    func accountLeft() async {
        networkEnabled = false
        setStatus(.stopped)
        await publish()
    }
}
#endif
