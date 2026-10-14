#if os(macOS) && DEBUG
import Darwin
import Foundation

/// 대본으로 움직이는 가짜 agent (시험 전용, Release 바이너리에 없다 — OA D2b 계약 2.4).
/// 메모리 대본은 상태 기계를 결정적으로 시험하고, 하위 프로세스 모드(F10)는 실제 pid · 시작 시각 · 고아를 만든다.
/// 시험이 임시 폴더에 쓴 `/bin/sh` 대본만 띄운다 — 실제 `claude` · `codex`는 띄우지 않는다.
public final class FakeAgentProcess: AgentProcess, @unchecked Sendable {
    // MARK: 대본

    public enum Step: Sendable {
        case sessionBound(external: String, workspace: String?)
        case accepted
        case progress
        case message(String)
        case question(AgentQuestion)
        case artifact(path: String, hash: String, summary: String)
        case turnCompleted
        case failed(BridgeV1FailureReason?)
        case cancelled
        /// 수동 시계로 이만큼 흐를 때까지 기다린다
        case wait(TimeInterval)
        /// `deliverAnswer`가 올 때까지 멈춘다 (프로세스는 살아 있다)
        case awaitAnswer
        case end(AgentExit)
    }

    public struct Script: Sendable {
        public var steps: [Step]

        public init(_ steps: [Step]) {
            self.steps = steps
        }

        /// F1 정상 턴: (지연) → sessionBound(첫 턴) → accepted → progress → message → turnCompleted → ended(0)
        public static func normal(delay: TimeInterval = 0, message: String = "done", bind: (external: String, workspace: String?)? = ("fake-session-1", "workspace-fake")) -> Script {
            var steps: [Step] = []
            if delay > 0 { steps.append(.wait(delay)) }
            if let bind { steps.append(.sessionBound(external: bind.external, workspace: bind.workspace)) }
            steps += [.accepted, .progress, .message(message), .turnCompleted, .end(AgentExit(code: 0))]
            return Script(steps)
        }

        /// F2 질문: accepted → question → 답 대기 → progress → turnCompleted → ended
        public static func asking(_ question: AgentQuestion, bind: (external: String, workspace: String?)? = ("fake-session-1", "workspace-fake")) -> Script {
            var steps: [Step] = []
            if let bind { steps.append(.sessionBound(external: bind.external, workspace: bind.workspace)) }
            steps += [.accepted, .question(question), .awaitAnswer, .progress, .turnCompleted, .end(AgentExit(code: 0))]
            return Script(steps)
        }

        /// F3 접수 전 실패
        public static func failsBeforeAcceptance(_ reason: BridgeV1FailureReason) -> Script {
            Script([.failed(reason), .end(AgentExit(code: 1))])
        }

        /// F4 턴 중 죽음: accepted 뒤 끝 사건 없이 비정상 종료
        public static func diesMidTurn() -> Script {
            Script([.accepted, .progress, .end(AgentExit(code: nil, signal: 9))])
        }

        /// F5 느린 시작: `seconds` 뒤에 accepted
        public static func slowStart(_ seconds: TimeInterval) -> Script { normal(delay: seconds) }

        /// F9 사건 폭주
        public static func burst(count: Int) -> Script {
            Script([.accepted] + Array(repeating: Step.progress, count: count) + [.turnCompleted, .end(AgentExit(code: 0))])
        }

        /// 접수 전에 조용히 끝남 (ONE-TF-04 c): 사건 0
        public static func silentDeathBeforeAcceptance() -> Script { Script([.end(AgentExit(code: nil, signal: 9))]) }

        /// 접수한 뒤 멈춰서 계속 돈다 (중단 · 고아 시험)
        public static func staysRunning() -> Script { Script([.sessionBound(external: "fake-session-1", workspace: "workspace-fake"), .accepted, .progress, .wait(100_000)]) }
    }

    /// 시험이 읽는 기록 (사용자 글이 들어 있다: 시험 안에서만 쓴다)
    public struct StartedTurn: Sendable {
        public let taskID: String
        public let sessionID: String
        public let turnSeq: Int
        public let marker: String
        public let text: String
        public let externalSessionID: String?
        public let workspaceRef: String?
        public let resume: Bool
        public let access: AgentAccess
        public let policyMode: AgentPolicyMode
    }

    public struct DeliveredAnswer: Sendable {
        public let taskID: String
        public let requestID: String
        public let value: AgentAnswerValue
    }

    private struct Run {
        var taskID: String
        var identity: AgentProcessIdentity
        var ended = false
        var task: Task<Void, Never>?
        var answerWaiter: CheckedContinuation<Void, Never>?
        var answerArrived = false
        var childProcess: Process?
    }

    public let adapter: String
    private let clock: BridgeClock
    private let lock = NSLock()
    private var runs: [String: Run] = [:] // by marker
    private var _probe: BridgeV1AdapterReport
    private var scriptProvider: @Sendable (AgentTurnStart) -> Script = { _ in .normal() }
    private var answerScript: @Sendable (AgentAnswerDelivery) -> Script? = { _ in nil }
    private var _started: [StartedTurn] = []
    private var _answers: [DeliveredAnswer] = []
    private var _closed: [AgentRequestRef] = []
    private var _interrupts: [(AgentTurnRef, AgentCancelScope)] = []
    private var _terminated: [AgentProcessIdentity] = []
    private var closedRequestIDs: Set<String> = []
    private var _readback: AgentReadback = .unsupported
    private var _versionSupported: @Sendable (String?) -> Bool = { _ in true }
    private var _startError: AgentStartError?
    private var _useSubprocess = false
    private var _ignoreInterruptFor: TimeInterval?
    private var _answersFail = false
    private var _hookStart: (@Sendable (AgentTurnStart) async -> Void)?
    private var _hookDeliver: (@Sendable (AgentAnswerDelivery) async -> Void)?
    private var _livenessOverride: AgentLiveness?
    public var processCounter = 0

    public init(adapter: String = "agent:claude-code", version: String = "2.1.241", clock: BridgeClock = .system) {
        self.adapter = adapter
        self.clock = clock
        _probe = BridgeV1AdapterReport(adapter: adapter, installed: true, version: version, signedIn: .yes, managedSettings: false)
    }

    // MARK: 시험이 정하는 것

    public var report: BridgeV1AdapterReport {
        get { lock.withLock { _probe } }
        set { lock.withLock { _probe = newValue } }
    }

    /// F11: 설치 안 됨 · 버전 밖 · 로그인 안 됨
    public func setReport(_ change: (inout BridgeV1AdapterReport) -> Void) {
        lock.withLock { change(&_probe) }
    }

    public func setScript(_ provider: @escaping @Sendable (AgentTurnStart) -> Script) { lock.withLock { scriptProvider = provider } }
    public func setScript(_ script: Script) { lock.withLock { scriptProvider = { _ in script } } }
    public func setAnswerScript(_ provider: @escaping @Sendable (AgentAnswerDelivery) -> Script?) { lock.withLock { answerScript = provider } }
    public func setReadback(_ value: AgentReadback) { lock.withLock { _readback = value } }
    public func setVersionSupport(_ check: @escaping @Sendable (String?) -> Bool) { lock.withLock { _versionSupported = check } }
    public func setStartError(_ error: AgentStartError?) { lock.withLock { _startError = error } }
    public func setSubprocess(_ on: Bool) { lock.withLock { _useSubprocess = on } }
    /// F6: 중단 신호를 받고도 이만큼 더 돈다
    public func setIgnoreInterrupt(for seconds: TimeInterval?) { lock.withLock { _ignoreInterruptFor = seconds } }
    public func setAnswersFail(_ value: Bool) { lock.withLock { _answersFail = value } }
    public func setLiveness(_ value: AgentLiveness?) { lock.withLock { _livenessOverride = value } }
    public func onStart(_ hook: (@Sendable (AgentTurnStart) async -> Void)?) { lock.withLock { _hookStart = hook } }
    public func onDeliver(_ hook: (@Sendable (AgentAnswerDelivery) async -> Void)?) { lock.withLock { _hookDeliver = hook } }

    public var startedTurns: [StartedTurn] { lock.withLock { _started } }
    public var deliveredAnswers: [DeliveredAnswer] { lock.withLock { _answers } }
    public var closedRequests: [AgentRequestRef] { lock.withLock { _closed } }
    public var interrupts: [(AgentTurnRef, AgentCancelScope)] { lock.withLock { _interrupts } }
    public var terminatedOrphans: [AgentProcessIdentity] { lock.withLock { _terminated } }
    public var liveRunCount: Int { lock.withLock { runs.values.filter { !$0.ended }.count } }

    // MARK: AgentProcess

    public func probe() async -> BridgeV1AdapterReport { report }

    public func supportsVersion(_ version: String?) -> Bool { lock.withLock { _versionSupported }(version) }

    public func startTurn(_ turn: AgentTurnStart, events: AgentEventSink) async throws -> AgentProcessIdentity {
        let hook = lock.withLock { _hookStart }
        await hook?(turn)
        let (startError, script, subprocess): (AgentStartError?, Script, Bool) = lock.withLock {
            _started.append(StartedTurn(
                taskID: turn.taskID, sessionID: turn.sessionID, turnSeq: turn.turnSeq, marker: turn.marker, text: turn.text, externalSessionID: turn.externalSessionID,
                workspaceRef: turn.workspaceRef, resume: turn.resume, access: turn.access, policyMode: turn.policyMode
            ))
            return (_startError, scriptProvider(turn), _useSubprocess)
        }
        if let startError { throw startError }
        return try launch(script: script, taskID: turn.taskID, marker: turn.marker, events: events, subprocess: subprocess)
    }

    public func deliverAnswer(_ answer: AgentAnswerDelivery, events: AgentEventSink) async throws -> AgentAnswerResult {
        let hook = lock.withLock { _hookDeliver }
        await hook?(answer)
        let (fails, alreadyClosed): (Bool, Bool) = lock.withLock { (_answersFail, closedRequestIDs.contains(answer.requestID)) }
        if fails { throw AgentStartError(.agentError) }
        if alreadyClosed { return .requestClosed }
        let resume: CheckedContinuation<Void, Never>? = lock.withLock {
            _answers.append(DeliveredAnswer(taskID: answer.taskID, requestID: answer.requestID, value: answer.value))
            if let key = runs.first(where: { $0.value.taskID == answer.taskID && !$0.value.ended })?.key {
                let waiter = runs[key]?.answerWaiter
                runs[key]?.answerWaiter = nil
                runs[key]?.answerArrived = true
                return waiter
            }
            return nil
        }
        if let resume {
            resume.resume()
            let identity = lock.withLock { runs.values.first { $0.taskID == answer.taskID && !$0.ended }?.identity }
            if let identity { return .delivered(identity) }
        }
        // 살아 있는 실행이 없으면 새 실행 구간을 띄운다 (Claude Code: 답을 주며 resume)
        let script = lock.withLock { answerScript(answer) } ?? Script([.progress, .turnCompleted, .end(AgentExit(code: 0))])
        let identity = try launch(script: script, taskID: answer.taskID, marker: answer.marker + "-a", events: events, subprocess: lock.withLock { _useSubprocess })
        return .delivered(identity)
    }

    public func closeRequest(_ request: AgentRequestRef) async throws {
        lock.withLock {
            _closed.append(request)
            closedRequestIDs.insert(request.requestID)
        }
    }

    public func interrupt(_ target: AgentTurnRef, scope: AgentCancelScope) async -> AgentInterruptResult {
        let (key, ignore): (String?, TimeInterval?) = lock.withLock {
            _interrupts.append((target, scope))
            return (runs.first { $0.value.taskID == target.taskID && !$0.value.ended }?.key, _ignoreInterruptFor)
        }
        guard let key else { return .notRunning }
        if let ignore {
            Task { [self] in
                try? await clock.sleep(.seconds(ignore))
                await finishRun(marker: key, exit: AgentExit(code: nil, signal: 2))
            }
        } else {
            await finishRun(marker: key, exit: AgentExit(code: nil, signal: 2))
        }
        return .signalled
    }

    public func liveness(_ identity: AgentProcessIdentity) async -> AgentLiveness {
        if let override = lock.withLock({ _livenessOverride }) { return override }
        if let pid = identity.pid {
            return Self.processExists(pid: pid, startedAt: identity.startedAt) ? .alive : .ended(AgentExit(code: nil))
        }
        return lock.withLock { runs[identity.processMarker].map { $0.ended ? .ended(AgentExit(code: 0)) : .alive } } ?? .ended(AgentExit(code: nil))
    }

    public func terminateOrphan(_ identity: AgentProcessIdentity) async -> AgentLiveness {
        lock.withLock { _terminated.append(identity) }
        if let pid = identity.pid, Self.processExists(pid: pid, startedAt: identity.startedAt) {
            kill(pid_t(pid), SIGTERM)
            for _ in 0..<50 {
                var status: Int32 = 0
                _ = waitpid(pid_t(pid), &status, WNOHANG)
                if !Self.processExists(pid: pid, startedAt: identity.startedAt) { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            if Self.processExists(pid: pid, startedAt: identity.startedAt) { kill(pid_t(pid), SIGKILL) }
            for _ in 0..<50 {
                var status: Int32 = 0
                _ = waitpid(pid_t(pid), &status, WNOHANG)
                if !Self.processExists(pid: pid, startedAt: identity.startedAt) { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return Self.processExists(pid: pid, startedAt: identity.startedAt) ? .alive : .ended(AgentExit(code: nil, signal: 15))
        }
        await finishRun(marker: identity.processMarker, exit: AgentExit(code: nil, signal: 15), emit: false)
        return .ended(AgentExit(code: nil, signal: 15))
    }

    public func readback(marker: String, session: AgentSessionRef) async -> AgentReadback { lock.withLock { _readback } }

    // MARK: 대본 실행

    private func launch(script: Script, taskID: String, marker: String, events: AgentEventSink, subprocess: Bool) throws -> AgentProcessIdentity {
        var child: Process?
        var pid: Int?
        var startedAt = clock.now()
        if subprocess {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "while :; do sleep 1; done"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            try process.run()
            child = process
            pid = Int(process.processIdentifier)
            startedAt = Self.processStartTime(pid: pid!) ?? startedAt
        }
        let identity: AgentProcessIdentity = lock.withLock {
            processCounter += 1
            return AgentProcessIdentity(pid: pid, startedAt: startedAt, processMarker: marker, externalTaskID: "turn-\(processCounter)")
        }
        let run = Task { [self] in await play(script, marker: marker, events: events) }
        lock.withLock {
            runs[marker] = Run(taskID: taskID, identity: identity, task: run, childProcess: child)
            storedSinks[marker] = events
        }
        return identity
    }

    private func play(_ script: Script, marker: String, events: AgentEventSink) async {
        for step in script.steps {
            if Task.isCancelled { return }
            if lock.withLock({ runs[marker]?.ended ?? true }) { return }
            switch step {
            case .sessionBound(let external, let workspace): await events.emit(.sessionBound(externalSessionID: external, workspaceRef: workspace))
            case .accepted: await events.emit(.accepted)
            case .progress: await events.emit(.progress)
            case .message(let text): await events.emit(.message(text: text))
            case .question(let question): await events.emit(.question(question))
            case .artifact(let path, let hash, let summary): await events.emit(.artifact(path: path, hash: hash, summary: summary))
            case .turnCompleted: await events.emit(.turnCompleted)
            case .failed(let reason): await events.emit(.failed(reason))
            case .cancelled: await events.emit(.cancelled)
            case .wait(let seconds): try? await clock.sleep(.seconds(seconds))
            case .awaitAnswer:
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    lock.lock()
                    if runs[marker]?.answerArrived == true || runs[marker]?.ended != false {
                        runs[marker]?.answerArrived = false
                        lock.unlock()
                        continuation.resume()
                    } else {
                        runs[marker]?.answerWaiter = continuation
                        lock.unlock()
                    }
                }
            case .end(let exit):
                await finishRun(marker: marker, exit: exit, emit: true, events: events)
                return
            }
        }
    }

    private func finishRun(marker: String, exit: AgentExit, emit: Bool = true, events: AgentEventSink? = nil) async {
        let (alreadyEnded, waiter, child, sink): (Bool, CheckedContinuation<Void, Never>?, Process?, AgentEventSink?) = lock.withLock {
            guard var run = runs[marker] else { return (true, nil, nil, nil) }
            if run.ended { return (true, nil, nil, nil) }
            run.ended = true
            let waiter = run.answerWaiter
            run.answerWaiter = nil
            run.task?.cancel()
            runs[marker] = run
            return (false, waiter, run.childProcess, storedSinks[marker])
        }
        if alreadyEnded { return }
        waiter?.resume()
        if let child, child.isRunning {
            child.terminate()
            child.waitUntilExit()
        }
        if emit, let sink = events ?? sink { await sink.emit(.ended(exit)) }
    }

    private var storedSinks: [String: AgentEventSink] = [:]

    /// 시험 정리: 띄운 하위 프로세스를 모두 끝낸다 (`abandon`으로 남긴 고아도)
    public func killEverything() {
        let children: [Process] = lock.withLock {
            let list = runs.values.compactMap(\.childProcess)
            for key in runs.keys { runs[key]?.task?.cancel() }
            return list
        }
        for child in children where child.isRunning {
            child.terminate()
            child.waitUntilExit()
        }
    }

    /// 런타임을 정리 없이 버리는 흉내 (ONE-TF-15 b): 대본 실행은 멈추지만 **하위 프로세스는 살려 둔다** (고아)
    public func abandon() -> [AgentProcessIdentity] {
        lock.withLock {
            for key in runs.keys {
                runs[key]?.task?.cancel()
                runs[key]?.ended = true
            }
            return runs.values.filter { $0.childProcess?.isRunning == true }.map(\.identity)
        }
    }

    // MARK: 실제 프로세스 조회 (F10)

    /// pid의 시작 시각 (sysctl). 없는 프로세스면 nil
    static func processStartTime(pid: Int) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == Int32(pid) else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }

    /// 앱 시험이 고아의 생존을 직접 본다 (`processExists`의 공개 이름)
    public static func isProcessAlive(pid: Int, startedAt: Date) -> Bool {
        processExists(pid: pid, startedAt: startedAt)
    }

    /// 같은 pid + 같은 시작 시각이고 좀비가 아니면 살아 있다 (pid 재사용을 시작 시각으로 가른다)
    static func processExists(pid: Int, startedAt: Date) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == Int32(pid) else { return false }
        if info.kp_proc.p_stat == SZOMB { return false }
        let start = info.kp_proc.p_un.__p_starttime
        let actual = Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
        return abs(actual.timeIntervalSince(startedAt)) < 1.5
    }
}
#endif
