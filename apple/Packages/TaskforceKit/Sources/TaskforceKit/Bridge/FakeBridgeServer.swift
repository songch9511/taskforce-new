#if os(macOS) && DEBUG
import CryptoKit
import Foundation

/// bridge 서버(D2a)의 시험 대역 (OA D2b 계약 4.5). `URLProtocol`로 `/api/v1/bridge/*` 다섯 route를 흉내 낸다.
/// **이것은 시험 대역이다.** 앱 코드 경로에서 부르지 않는다 (Debug 전용 · Release 바이너리에 없다).
/// D2a 표를 그대로 옮긴 작은 상태 기계다. 칸마다 출처 절을 주석으로 적었다 (`handoffs/oa-d2a-contract.md`).
/// 시각은 주입한 수동 시계의 것이다 (lease 330초 · heartbeat 90초를 실제로 기다리지 않는다).
public final class FakeBridgeServer: @unchecked Sendable {
    // MARK: 기록

    public struct Recorded: Sendable {
        public let index: Int
        public let route: String
        public let method: String
        public let query: [String: String]
        public let token: String?
        public let secret: String?
        public let bodyJSON: String
        public let at: Date

        public var json: [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(bodyJSON.utf8)) as? [String: Any]) ?? [:]
        }

        public var bridgeID: String? { query["bridge_id"] ?? (json["bridge_id"] as? String) }
    }

    /// 다음 요청 몇 개에 줄 가짜 실패
    public struct Failure: Sendable {
        public var status: Int
        public var headers: [String: String] = [:]
        public var transport = false
        public var count = 1
        /// 있으면 오류 본문 대신 이 JSON을 준다 (예: 모르는 `status`를 단 200 ack 응답)
        public var bodyJSON: String?

        public init(status: Int, headers: [String: String] = [:], transport: Bool = false, count: Int = 1, bodyJSON: String? = nil) {
            self.status = status
            self.headers = headers
            self.transport = transport
            self.count = count
            self.bodyJSON = bodyJSON
        }
    }

    // MARK: 서버 상태

    enum Step: String { case prepared, calling, unknownOutcome = "unknown_outcome", called, failed, skipped }

    struct Bridge {
        var id: String
        var userID: UUID
        var deviceRef: String
        var secret: String
        var active = true
        var lastHeartbeatAt: Date?
        var cachedHeartbeat: [String: Any]?
        var report: [[String: Any]] = []
        var connected: Set<String> = []
    }

    struct Session {
        var id: String
        var bridgeID: String
        var adapter: String
        var status = "bound"
        var externalSessionID: String?
        var workspaceRef: String?
    }

    struct ServerTask {
        var id: String
        var sessionID: String
        var turnSeq: Int
        var state = "dispatched"
        var lastLiveState: String?
        var lastEventSeq = 0
        var externalTaskID: String?
        var openQuestion: OpenQuestion?
        var currentCommandID: String?
    }

    /// 지금 열린 질문 (question 사건에서 안다): `answer-local`이 digest · 비밀값 여부를 대조한다 (OA F2 · D4b-m-2)
    struct OpenQuestion {
        var requestID: String
        var digest: String
        var kind: String
        var structured: Bool
        var secret: Bool
        /// 이 Mac이 이미 답한 질문이면 그 답 명령의 단계 id (`duplicate`가 돌려준다)
        var answeredStepID: String?
    }

    struct Command {
        var id: String
        var bridgeID: String
        var kind: String
        var sessionID: String
        var taskID: String
        var turnSeq: Int
        var cursor: Int
        var createdAt: Date
        var step: Step = .prepared
        var stepID = UUID().uuidString.lowercased()
        var marker = UUID().uuidString.lowercased() // 실제 서버의 marker는 uuid다 (`execution_intents.marker`)
        var leaseOwner: String?
        var leaseExpiresAt: Date?
        var leasedAt: Date?
        var outcome: String?
        var outcomeAt: Date?
        var payload: [String: Any] = [:]
    }

    private let lock = NSLock()
    private let clock: @Sendable () -> Date
    public let host: String
    private var users: [String: UUID] = [:]
    private var bridges: [String: Bridge] = [:]
    private var sessions: [String: Session] = [:]
    private var tasks: [String: ServerTask] = [:]
    private var commands: [String: Command] = [:]
    private var cursorCounter = 0
    private var seenEvents: Set<String> = []
    private var recorded: [Recorded] = []
    private var failures: [String: [Failure]] = [:]
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var registerCount = 0
    private var _eventResults: [(eventID: String, type: String, status: String)] = []
    private var retryOnce: Set<String> = []

    /// false면 새 전달(message · answer)의 lease를 `withdrawn/write_gate_closed`로 거둔다 (cancel은 보지 않는다)
    public var gateOpen: Bool { get { lock.withLock { _gateOpen } } set { lock.withLock { _gateOpen = newValue } } }
    private var _gateOpen = true
    /// true면 등록 응답의 secret이 서버 약속(43자 base64url)과 다른 모양이다
    public var badSecret: Bool { get { lock.withLock { _badSecret } } set { lock.withLock { _badSecret = newValue } } }
    private var _badSecret = false
    /// 등록 한도 (시간당 20회). 0이면 끄기
    public var registerLimit: Int { get { lock.withLock { _registerLimit } } set { lock.withLock { _registerLimit = newValue } } }
    private var _registerLimit = 20
    /// 시험이 URL 처리 전에 끼워 넣는 비동기 훅 (예: 요청이 도착한 순간 원장을 읽어 write-ahead를 확인한다)
    public var onRequest: (@Sendable (Recorded) async -> Void)? { get { lock.withLock { _onRequest } } set { lock.withLock { _onRequest = newValue } } }
    private var _onRequest: (@Sendable (Recorded) async -> Void)?
    /// 서버가 요청을 **처리한 뒤**, 응답을 돌려주기 전에 부른다 (응답이 늦게 도착하는 순서를 만든다: 서버 쪽 효과는 이미 났다)
    public var onResponse: (@Sendable (Recorded) async -> Void)? { get { lock.withLock { _onResponse } } set { lock.withLock { _onResponse = newValue } } }
    private var _onResponse: (@Sendable (Recorded) async -> Void)?
    /// 긴 대기를 실제로 붙잡아 둘 최대 시간 (시험이 멈추지 않게)
    public var longPollRealTimeCap: TimeInterval = 5

    public init(clock: @escaping @Sendable () -> Date) {
        self.clock = clock
        self.host = "bridge-\(UUID().uuidString.lowercased()).fake.test"
        FakeBridgeURLProtocol.register(host: host, server: self)
    }

    deinit {
        FakeBridgeURLProtocol.unregister(host: host)
    }

    public var baseURL: URL { URL(string: "https://\(host)")! }

    public func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeBridgeURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    // MARK: 사용자 · 시험 설정

    /// 이 토큰을 가진 요청은 이 사용자다
    public func addUser(token: String, userID: UUID) {
        lock.withLock { users[token] = userID }
    }

    public var requests: [Recorded] { lock.withLock { recorded } }

    public func requests(_ route: String) -> [Recorded] { requests.filter { $0.route == route } }

    public func clearFailures() {
        lock.withLock { failures.removeAll() }
    }

    /// 이 사용자의 다른 기기 bridge를 `count`개 active로 만든다 (사용자당 10개 상한 시험)
    public func fillBridges(userID: UUID, count: Int) {
        lock.withLock {
            for index in 0..<count {
                let id = UUID().uuidString.lowercased()
                bridges[id] = Bridge(id: id, userID: userID, deviceRef: "other-device-\(index)-\(UUID().uuidString)", secret: Self.newSecret())
            }
        }
    }

    public func failNext(_ route: String, _ failure: Failure) {
        lock.withLock { failures[route, default: []].append(failure) }
    }

    /// 이 event id는 한 번 `retry_event_ids`로 돌려보낸다 (그 뒤 같은 세션 사건도 retry)
    public func retryEventOnce(_ eventID: String) {
        lock.withLock { _ = retryOnce.insert(eventID) }
    }

    public var eventResults: [(eventID: String, type: String, status: String)] { lock.withLock { _eventResults } }

    public func bridgeID(userID: UUID) -> String? { lock.withLock { bridges.values.first { $0.userID == userID }?.id } }
    public func secret(bridgeID: String) -> String? { lock.withLock { bridges[bridgeID]?.secret } }
    public func bridgeIsActive(_ id: String) -> Bool { lock.withLock { bridges[id]?.active ?? false } }
    public func lastHeartbeat(bridgeID: String) -> Date? { lock.withLock { bridges[bridgeID]?.lastHeartbeatAt } }
    public func removeBridge(_ id: String) { lock.withLock { _ = bridges.removeValue(forKey: id) } }
    public func revoke(bridgeID: String) { lock.withLock { bridges[bridgeID]?.active = false } }
    public var registerAttempts: Int { lock.withLock { registerCount } }

    // MARK: 명령 만들기 (서버 쪽 일)

    public struct Created: Sendable {
        public let commandID: String
        public let taskID: String
        public let sessionID: String
        public let stepID: String
        public let marker: String
    }

    /// 세션이 없으면 만든다. `externalSessionID`가 nil이면 아직 pending이다 (bridge가 만들고 `session_bound`로 알린다)
    @discardableResult
    public func ensureSession(id: String, bridgeID: String, adapter: String = "agent:claude-code", externalSessionID: String? = nil, workspaceRef: String? = nil) -> String {
        lock.withLock {
            if sessions[id] == nil {
                sessions[id] = Session(id: id, bridgeID: bridgeID, adapter: adapter, externalSessionID: externalSessionID, workspaceRef: workspaceRef)
            }
            return id
        }
    }

    public func sessionState(_ id: String) -> (status: String, externalSessionID: String?, workspaceRef: String?)? {
        lock.withLock { sessions[id].map { ($0.status, $0.externalSessionID, $0.workspaceRef) } }
    }

    public func taskState(_ id: String) -> String? { lock.withLock { tasks[id]?.state } }
    public func taskLastSeq(_ id: String) -> Int? { lock.withLock { tasks[id]?.lastEventSeq } }

    /// 답 명령이 not_received로 정산될 때 서버가 질문을 되살리나 (실제 서버는 run이 아직 queued · running이고 취소 요청이 없을 때만 되살린다, `20261118000000_bridge_commands.sql:394`). false면 run이 끝난 것처럼 task를 failed로 둔다
    public var restoresQuestionOnNotReceived: Bool { get { lock.withLock { _restoresQuestionOnNotReceived } } set { lock.withLock { _restoresQuestionOnNotReceived = newValue } } }
    private var _restoresQuestionOnNotReceived = true

    /// 시험 전용: 서버가 이 task의 질문을 되살렸다 (`awaiting_answer`, 다시 답할 수 있다). 정산 없이 되살아난 경우를 만든다
    public func restoreQuestion(taskID: String) {
        lock.withLock {
            tasks[taskID]?.state = "awaiting_answer"
            tasks[taskID]?.openQuestion?.answeredStepID = nil
        }
    }

    /// 시험 전용: 서버가 이 task를 다른 세션의 것으로 말한다 (이후 이 task를 가리키는 명령은 그 세션 id를 싣는다)
    public func reassignTask(_ id: String, toSession sessionID: String) {
        lock.withLock { tasks[id]?.sessionID = sessionID }
    }

    /// 그 task의 이 종류 명령 id들 (만든 순서). 서버가 스스로 만든 명령(`answer-local`의 답 명령)을 시험이 찾는다
    public func commandIDs(taskID: String, kind: String) -> [String] {
        lock.withLock { commands.values.filter { $0.taskID == taskID && $0.kind == kind }.sorted { $0.cursor < $1.cursor }.map(\.id) }
    }

    public func commandStep(_ id: String) -> String? { lock.withLock { commands[id]?.step.rawValue } }
    public func commandCursor(_ id: String) -> Int? { lock.withLock { commands[id]?.cursor } }
    public func commandOutcome(_ id: String) -> String? { lock.withLock { commands[id]?.outcome } }
    public func commandLeaseCount(_ id: String) -> Int { lock.withLock { leaseCounts[id] ?? 0 } }
    private var leaseCounts: [String: Int] = [:]

    @discardableResult
    public func enqueueMessage(
        bridgeID: String, sessionID: String, taskID: String = UUID().uuidString.lowercased(), turnSeq: Int = 1, text: String, adapter: String = "agent:claude-code",
        access: String = "write", policyMode: String = "manual", closeBefore: String? = nil, commandID: String = UUID().uuidString.lowercased(),
        extra: [String: Any] = [:]
    ) -> Created {
        lock.withLock {
            ensureSessionLocked(id: sessionID, bridgeID: bridgeID, adapter: adapter)
            tasks[taskID] = ServerTask(id: taskID, sessionID: sessionID, turnSeq: turnSeq, currentCommandID: commandID)
            var command = newCommand(id: commandID, bridgeID: bridgeID, kind: "message", sessionID: sessionID, taskID: taskID, turnSeq: turnSeq)
            var closeValue: Any = NSNull()
            if let closeBefore { closeValue = ["provider_request_id": closeBefore] }
            command.payload = [
                "adapter": adapter, "access": access, "policy_mode": policyMode,
                "message": ["id": UUID().uuidString.lowercased(), "text": text],
                "close_before": closeValue,
            ].merging(extra) { $1 }
            commands[commandID] = command
            notifyLocked()
            return Created(commandID: commandID, taskID: taskID, sessionID: sessionID, stepID: command.stepID, marker: command.marker)
        }
    }

    /// 질문에 대한 답. 서버 task는 `awaiting_answer`로 만들어 둔다 (이미 질문이 와 있는 상황)
    @discardableResult
    public func enqueueAnswer(
        bridgeID: String, taskID: String, requestID: String, answers: [String: Any]? = nil, answerText: String? = nil, locally: Bool = false, structured: Bool = true,
        questionKind: String = "input", commandID: String = UUID().uuidString.lowercased(), extra: [String: Any] = [:]
    ) -> Created? {
        lock.withLock {
            enqueueAnswerLocked(
                bridgeID: bridgeID, taskID: taskID, requestID: requestID, answers: answers, answerText: answerText, locally: locally, structured: structured,
                questionKind: questionKind, commandID: commandID, extra: extra
            )
        }
    }

    private func enqueueAnswerLocked(
        bridgeID: String, taskID: String, requestID: String, answers: [String: Any]?, answerText: String?, locally: Bool, structured: Bool, questionKind: String,
        commandID: String, extra: [String: Any]
    ) -> Created? {
        guard let task = tasks[taskID] else { return nil }
        var command = newCommand(id: commandID, bridgeID: bridgeID, kind: "answer", sessionID: task.sessionID, taskID: taskID, turnSeq: task.turnSeq)
        let adapter = sessions[task.sessionID]?.adapter ?? "agent:claude-code"
        var answersValue: Any = NSNull()
        var textValue: Any = NSNull()
        if !locally {
            if let answers { answersValue = answers }
            if let answerText { textValue = answerText }
        }
        command.payload = [
            "adapter": adapter, "access": "write", "policy_mode": "manual", "provider_request_id": requestID, "question_kind": questionKind, "structured": structured,
            "answers": answersValue, "answer_text": textValue, "answered_locally": locally,
        ].merging(extra) { $1 }
        commands[commandID] = command
        tasks[taskID]?.currentCommandID = commandID
        notifyLocked()
        return Created(commandID: commandID, taskID: taskID, sessionID: task.sessionID, stepID: command.stepID, marker: command.marker)
    }

    @discardableResult
    public func enqueueCancel(
        bridgeID: String, taskID: String, abandoned: String? = nil, scope: String = "turn_and_processes", commandID: String = UUID().uuidString.lowercased(),
        extra: [String: Any] = [:]
    ) -> Created? {
        lock.withLock {
            guard let task = tasks[taskID] else { return nil }
            var command = newCommand(id: commandID, bridgeID: bridgeID, kind: "cancel", sessionID: task.sessionID, taskID: taskID, turnSeq: task.turnSeq)
            let adapter = sessions[task.sessionID]?.adapter ?? "agent:claude-code"
            command.payload = ["adapter": adapter, "abandoned_request_id": (abandoned as Any?) ?? NSNull(), "cancel_scope": scope].merging(extra) { $1 }
            commands[commandID] = command
            notifyLocked()
            return Created(commandID: commandID, taskID: taskID, sessionID: task.sessionID, stepID: command.stepID, marker: command.marker)
        }
    }

    /// 모르는 kind의 명령 (아키텍처 9.2): bridge는 lease하지 않고 decline해야 한다
    @discardableResult
    public func enqueueRaw(bridgeID: String, kind: String, taskID: String = UUID().uuidString.lowercased(), sessionID: String, commandID: String = UUID().uuidString.lowercased()) -> String {
        lock.withLock {
            ensureSessionLocked(id: sessionID, bridgeID: bridgeID, adapter: "agent:claude-code")
            tasks[taskID] = ServerTask(id: taskID, sessionID: sessionID, turnSeq: 1, currentCommandID: commandID)
            commands[commandID] = newCommand(id: commandID, bridgeID: bridgeID, kind: kind, sessionID: sessionID, taskID: taskID, turnSeq: 1)
            notifyLocked()
            return commandID
        }
    }

    /// 서버가 이 task를 모른다 (다른 환경 · 지워짐): heartbeat가 `unknown_task_ids`로 돌려준다
    public func removeTask(_ id: String) {
        lock.withLock { _ = tasks.removeValue(forKey: id) }
    }

    /// 세션을 `unreachable`로 만든다 (heartbeat가 끊겨 sweep이 처리한 뒤의 모양)
    public func sweepSessionUnreachable(_ id: String) {
        lock.withLock { sessions[id]?.status = "unreachable" }
    }

    /// 명령의 단계를 바꾼다 (시험 준비용: prepared · calling · unknown_outcome · called · failed · skipped)
    public func setCommandStep(_ id: String, _ step: String) {
        lock.withLock { if let value = Step(rawValue: step) { commands[id]?.step = value } }
    }

    /// 이 route의 다음 요청 하나는 **서버가 처리한 뒤** 응답이 유실된다 (ONE-TF-04 a: lease 응답 유실)
    public func dropResponseOnce(route: String) {
        lock.withLock { _ = dropAfter.insert(route) }
    }

    private var dropAfter: Set<String> = []
    private var staleOnce: [String: String] = [:]
    private var withdrawnOnce: [String: String] = [:]

    /// 이 명령의 다음 lease 요청 하나에 `withdrawn/<reason>`을 준다. 서버 SQL(`withdraw_bridge_command`, `20261127000000_bridge_device_name.sql:63-84`)처럼 답 명령의 단계를 거두고,
    /// `stale_answer` · `action_closed`가 아니면 질문을 `awaiting_answer`로 되살린다 (`:79-81`). `action_closed`(Done)는 task를 취소한다
    public func withdrawOnNextLease(_ commandID: String, reason: String) {
        lock.withLock { withdrawnOnce[commandID] = reason }
    }

    /// 이 명령의 다음 lease 요청 하나에 `stale/<reason>`을 준다 (`heartbeat_first` · `policy_changed` 재시도 시험)
    public func staleOnNextLease(_ commandID: String, reason: String) {
        lock.withLock { staleOnce[commandID] = reason }
    }

    /// 이 명령을 "bridge가 lease했는데 결과를 모르는" 상태로 만든다 (lease 만료 뒤 `readbacks`에 나온다)
    public func markLeasedUnknown(_ commandID: String) {
        lock.withLock {
            guard var command = commands[commandID] else { return }
            command.leaseOwner = "bridge:\(command.bridgeID):\(commandID)"
            command.leasedAt = clock()
            command.leaseExpiresAt = clock()
            command.step = .unknownOutcome
            commands[commandID] = command
        }
    }

    /// 서버가 센 `pending_commands`: 이 bridge의 prepared · calling · unknown_outcome 명령 수 (heartbeat 응답과 같다)
    public func pendingCommandCount(bridgeID: String) -> Int {
        lock.withLock { pendingCountLocked(bridgeID: bridgeID) }
    }

    private func pendingCountLocked(bridgeID: String) -> Int {
        commands.values.filter { $0.bridgeID == bridgeID && [.prepared, .calling, .unknownOutcome].contains($0.step) }.count
    }

    /// 서버가 task를 이 상태로 둔다 (시험 준비용)
    public func setTaskState(_ id: String, _ state: String) {
        lock.withLock { tasks[id]?.state = state }
    }

    private func ensureSessionLocked(id: String, bridgeID: String, adapter: String) {
        if sessions[id] == nil { sessions[id] = Session(id: id, bridgeID: bridgeID, adapter: adapter) }
    }

    private func newCommand(id: String, bridgeID: String, kind: String, sessionID: String, taskID: String, turnSeq: Int) -> Command {
        cursorCounter += 1
        return Command(id: id, bridgeID: bridgeID, kind: kind, sessionID: sessionID, taskID: taskID, turnSeq: turnSeq, cursor: cursorCounter, createdAt: clock())
    }

    // MARK: cron 흉내 (`sweep_agent_step_leases` · `sweep_bridge_heartbeats`, D2a 3.6)

    public func sweep() {
        lock.withLock {
            let now = clock()
            for (id, var command) in commands where command.step == .calling && (command.leaseExpiresAt ?? .distantFuture) <= now {
                command.step = .unknownOutcome
                commands[id] = command
            }
            for (id, var bridge) in bridges where bridge.active {
                guard let last = bridge.lastHeartbeatAt, now.timeIntervalSince(last) > 90 else { continue }
                bridge.cachedHeartbeat = nil
                bridges[id] = bridge
                for (sessionID, var session) in sessions where session.bridgeID == id && session.status == "bound" {
                    session.status = "unreachable"
                    sessions[sessionID] = session
                    for (taskID, var task) in tasks where task.sessionID == sessionID && ["accepted", "running", "awaiting_answer"].contains(task.state) {
                        task.lastLiveState = task.state
                        task.state = "unreachable"
                        tasks[taskID] = task
                    }
                }
            }
            notifyLocked()
        }
    }

    // MARK: 긴 대기 깨우기

    private func notifyLocked() {
        let pending = waiters
        waiters.removeAll()
        for (_, continuation) in pending { continuation.resume() }
    }

    public func notifyChange() {
        lock.withLock { notifyLocked() }
    }

    private func wait(realTime cap: TimeInterval) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                waiters[id] = continuation
                lock.unlock()
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(cap))
                    self?.resumeWaiter(id)
                }
            }
        } onCancel: {
            resumeWaiter(id)
        }
    }

    private func resumeWaiter(_ id: UUID) {
        lock.lock()
        let continuation = waiters.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume()
    }

    // MARK: 요청 처리

    struct Reply {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data = Data()
        var transportError = false
    }

    func handle(_ request: URLRequest, body: Data) async -> Reply {
        guard let url = request.url else { return Reply(status: 400) }
        let route = String(url.path().split(separator: "/").last ?? "")
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let token = request.value(forHTTPHeaderField: "Authorization").map { String($0.dropFirst("Bearer ".count)) }
        let record: Recorded = lock.withLock {
            let item = Recorded(
                index: recorded.count, route: route, method: request.httpMethod ?? "GET", query: query, token: token,
                secret: request.value(forHTTPHeaderField: "X-Taskforce-Bridge-Secret"), bodyJSON: String(decoding: body, as: UTF8.self), at: clock()
            )
            recorded.append(item)
            return item
        }
        if let hook = onRequest { await hook(record) }

        let injected: Failure? = lock.withLock {
            guard var queue = failures[route], var first = queue.first else { return nil }
            let used = first
            first.count -= 1
            if first.count <= 0 { queue.removeFirst() } else { queue[0] = first }
            failures[route] = queue
            return used
        }
        if let injected {
            if injected.transport { return Reply(status: 0, transportError: true) }
            return Reply(status: injected.status, headers: injected.headers, body: injected.bodyJSON.map { Data($0.utf8) } ?? error("injected", "injected"))
        }

        guard let token, let userID = lock.withLock({ users[token] }) else { return Reply(status: 401, body: error("unauthorized", "Unauthorized")) }
        let json = record.json
        switch (route, record.method) {
        case ("register", "POST"): return register(userID: userID, json: json)
        case ("register", "DELETE"): return revokeBridge(userID: userID, json: json)
        default: break
        }
        // 장치 확인 (D2a 3.1): 행 없음 404 · secret 불일치 401 · 폐기 403
        guard let bridgeID = record.bridgeID else { return Reply(status: 400, body: error("invalid_request", "bridge_id")) }
        let auth: Reply? = lock.withLock {
            guard let bridge = bridges[bridgeID], bridge.userID == userID else { return Reply(status: 404, body: error("not_found", "Bridge not found.")) }
            if !bridge.active { return Reply(status: 403, body: error("unauthorized", "Bridge revoked.")) }
            if record.secret != bridge.secret { return Reply(status: 401, body: error("unauthorized", "Unauthorized")) }
            return nil
        }
        if let auth { return auth }
        let reply: Reply
        switch route {
        case "commands": reply = await listCommands(bridgeID: bridgeID, query: query)
        case "ack": reply = ack(bridgeID: bridgeID, json: json)
        case "events": reply = events(bridgeID: bridgeID, json: json)
        case "heartbeat": reply = heartbeat(bridgeID: bridgeID, json: json)
        case "answer-local": reply = answerLocal(bridgeID: bridgeID, json: json)
        default: reply = Reply(status: 404, body: error("not_found", "route"))
        }
        let dropped = lock.withLock { dropAfter.remove(route) != nil }
        if let hook = onResponse { await hook(record) }
        return dropped ? Reply(status: 0, transportError: true) : reply
    }

    private func error(_ code: String, _ message: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["error": ["code": code, "message": message]])) ?? Data()
    }

    private func ok(_ object: [String: Any]) -> Reply {
        Reply(status: 200, headers: ["Content-Type": "application/json"], body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    private func iso(_ date: Date) -> String { BridgeV1Time.string(date) }

    // MARK: register (D2a 3.1 · 3.2 register_bridge)

    private func register(userID: UUID, json: [String: Any]) -> Reply {
        lock.withLock {
            registerCount += 1
            if _registerLimit > 0, registerCount > _registerLimit {
                return Reply(status: 429, headers: ["Retry-After": "600"], body: error("rate_limited", "Please try again later."))
            }
            guard let deviceID = json["device_id"] as? String, deviceID.count >= 16 else { return Reply(status: 400, body: error("invalid_request", "device_id")) }
            let reactivate = json["reactivate"] as? Bool ?? false
            var bridge: Bridge
            if var existing = bridges.values.first(where: { $0.userID == userID && $0.deviceRef == deviceID }) {
                if !existing.active {
                    guard reactivate else { return Reply(status: 403, body: error("unauthorized", "Explicit reactivation is required.")) }
                    existing.active = true
                }
                existing.secret = Self.newSecret()
                existing.cachedHeartbeat = nil
                bridge = existing
            } else {
                if bridges.values.filter({ $0.userID == userID && $0.active }).count >= 10 {
                    return Reply(status: 409, body: error("conflict", "too_many_bridges"))
                }
                bridge = Bridge(id: UUID().uuidString.lowercased(), userID: userID, deviceRef: deviceID, secret: Self.newSecret())
            }
            bridge.report = json["adapters"] as? [[String: Any]] ?? []
            bridge.lastHeartbeatAt = clock()
            for adapter in json["connect"] as? [String] ?? [] { bridge.connected.insert(adapter) }
            bridges[bridge.id] = bridge
            let connections = bridge.connected.sorted().map { ["connection_id": UUID().uuidString.lowercased(), "adapter": $0, "status": "active"] }
            return ok([
                "bridge_id": bridge.id, "bridge_secret": _badSecret ? "short" : bridge.secret, "heartbeat_interval_seconds": 30, "unreachable_after_seconds": 90,
                "long_poll_max_seconds": 25, "connections": connections,
            ])
        }
    }

    private func revokeBridge(userID: UUID, json: [String: Any]) -> Reply {
        lock.withLock {
            guard let id = json["bridge_id"] as? String, bridges[id]?.userID == userID else { return Reply(status: 404, body: error("not_found", "Bridge not found.")) }
            bridges[id]?.active = false
            return ok(["status": "revoked", "tasks": []])
        }
    }

    static func newSecret() -> String {
        Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    // MARK: commands (D2a 3.8 · list_bridge_commands)

    private func listCommands(bridgeID: String, query: [String: String]) async -> Reply {
        let after = Int(query["after"] ?? "0") ?? 0
        let wait = min(25, Int(query["wait"] ?? "0") ?? 0)
        var first = true
        while true {
            let result: (Reply, Bool) = lock.withLock {
                let mine = commands.values.filter { $0.bridgeID == bridgeID }
                let items = mine.filter { [.prepared, .calling, .unknownOutcome].contains($0.step) }
                let listed = items.filter {
                    ($0.step == .prepared && $0.leaseOwner == nil && $0.cursor > after) || ($0.step == .calling && $0.leaseOwner != nil)
                }.sorted { ($0.cursor > after ? 0 : 1, $0.cursor) < ($1.cursor > after ? 0 : 1, $1.cursor) }.prefix(50)
                let readbacks = items.filter { $0.step == .unknownOutcome && $0.leaseOwner != nil && $0.outcomeAt == nil }.sorted { $0.cursor < $1.cursor }.prefix(50)
                let reply = ok([
                    "commands": listed.map { command -> [String: Any] in
                        [
                            "id": command.id, "cursor": command.cursor, "kind": command.kind, "agent_session_id": command.sessionID, "agent_task_id": command.taskID,
                            "turn_seq": command.turnSeq, "created_at": iso(command.createdAt), "leased_by_me": command.step == .calling,
                        ]
                    },
                    "readbacks": readbacks.map { command -> [String: Any] in
                        [
                            "command_id": command.id, "kind": command.kind, "agent_session_id": command.sessionID, "agent_task_id": command.taskID, "turn_seq": command.turnSeq,
                            "marker": command.marker, "leased_at": iso(command.leasedAt ?? clock()),
                        ]
                    },
                    "next_cursor": max(after, listed.map(\.cursor).max() ?? after),
                    "server_time": iso(clock()),
                ])
                // 긴 대기는 새 cursor가 있는 명령이나 readback이 있을 때 바로 돌려준다 (commands.ts:48)
                let early = listed.contains { $0.cursor > after } || !readbacks.isEmpty
                return (reply, early)
            }
            if wait == 0 || result.1 || !first { return result.0 }
            first = false
            await self.wait(realTime: longPollRealTimeCap)
            if Task.isCancelled { return result.0 }
        }
    }

    // MARK: ack (D2a 3.3 · 3.4)

    private func payload(_ command: Command) -> [String: Any] {
        var body: [String: Any] = [
            "id": command.id, "kind": command.kind, "agent_session_id": command.sessionID, "agent_task_id": command.taskID, "turn_seq": command.turnSeq,
            "step_id": command.stepID, "marker": command.marker,
        ]
        let session = sessions[command.sessionID]
        body["session"] = [
            "external_session_id": (session?.externalSessionID as Any?) ?? NSNull(), "workspace_ref": (session?.workspaceRef as Any?) ?? NSNull(),
            "resume": session?.externalSessionID != nil,
        ]
        for (key, value) in command.payload { body[key] = value }
        return body
    }

    private func ack(bridgeID: String, json: [String: Any]) -> Reply {
        lock.withLock {
            guard let commandID = json["command_id"] as? String, var command = commands[commandID], command.bridgeID == bridgeID else {
                return Reply(status: 404, body: error("not_found", "Bridge command or device not found."))
            }
            let owner = "bridge:\(bridgeID):\(commandID)"
            let op = json["op"] as? String ?? ""
            let now = clock()
            switch op {
            case "lease":
                leaseCounts[commandID, default: 0] += 1
                // 시험이 정한 한 번짜리 stale (예: `policy_changed`): 단계는 바꾸지 않는다
                if let reason = staleOnce.removeValue(forKey: commandID) { return ok(["status": "stale", "reason": reason]) }
                // 시험이 정한 한 번짜리 withdrawn: 서버가 단계를 거두고 (사유에 따라) 질문을 되살린다
                if let reason = withdrawnOnce.removeValue(forKey: commandID) {
                    command.step = reason == "stale_answer" ? .skipped : .failed
                    commands[commandID] = command
                    if reason == "action_closed" {
                        tasks[command.taskID]?.state = "cancelled"
                    } else if reason != "stale_answer", command.kind == "answer", _restoresQuestionOnNotReceived {
                        tasks[command.taskID]?.state = "awaiting_answer"
                        tasks[command.taskID]?.openQuestion?.answeredStepID = nil
                    }
                    return ok(["status": "withdrawn", "reason": reason])
                }
                // 3.3 4: 단계가 calling이고 lease_owner가 같으면 replay (만료 연장 0, 쓰기 0). 지금 gate를 다시 본다 (정정 ⑨)
                if command.step == .calling, command.leaseOwner == owner {
                    if !_gateOpen, command.kind != "cancel" { return ok(["status": "stale", "reason": "write_gate_closed"]) }
                    return ok(["status": "replay", "command": payload(command), "lease_expires_at": iso(command.leaseExpiresAt ?? now)])
                }
                guard command.step == .prepared else { return ok(["status": "stale", "reason": "not_prepared"]) }
                if command.kind != "cancel" {
                    if sessions[command.sessionID]?.status == "unreachable" { return ok(["status": "stale", "reason": "heartbeat_first"]) }
                    if !_gateOpen {
                        command.step = .failed
                        commands[commandID] = command
                        tasks[command.taskID]?.state = "failed"
                        return ok(["status": "withdrawn", "reason": "write_gate_closed"])
                    }
                }
                command.step = .calling
                command.leaseOwner = owner
                command.leasedAt = now
                command.leaseExpiresAt = now.addingTimeInterval(330)
                command.outcome = nil
                command.outcomeAt = nil
                commands[commandID] = command
                var reply = ["status": "leased", "command": payload(command), "lease_expires_at": iso(command.leaseExpiresAt!)] as [String: Any]
                if command.kind == "cancel", var inner = reply["command"] as? [String: Any] {
                    inner["cancel_scope"] = command.payload["cancel_scope"] ?? "turn_and_processes"
                    reply["command"] = inner
                }
                return ok(reply)
            case "decline":
                guard command.step == .prepared else { return ok(["status": "stale", "reason": "not_prepared"]) }
                command.step = .failed
                command.outcome = "withdrawn"
                command.outcomeAt = now
                commands[commandID] = command
                tasks[command.taskID]?.state = "failed"
                return ok(["status": "withdrawn", "reason": "unsupported"])
            default:
                guard command.leaseOwner == owner else { return ok(["status": "stale"]) }
                switch op {
                case "complete":
                    guard [.calling, .unknownOutcome].contains(command.step) else { return ok(["status": "stale", "reason": "wrong_state"]) }
                    command.step = .called
                    if (json["result"] as? String) == "task_unknown" { tasks[command.taskID]?.state = "cancelled" }
                    command.outcome = json["result"] as? String
                    command.outcomeAt = now
                    commands[commandID] = command
                    var settled: [String: Any] = ["status": "settled"]
                    if let state = tasks[command.taskID]?.state { settled["task_state"] = state }
                    return ok(settled)
                case "readback":
                    guard [.calling, .unknownOutcome].contains(command.step) else { return ok(["status": "stale", "reason": "wrong_state"]) }
                    let result = json["result"] as? String ?? ""
                    let ended = json["process_ended"] as? Bool ?? false
                    if result == "not_received", !ended { return Reply(status: 400, body: error("invalid_request", "process_ended")) }
                    command.outcome = result
                    command.outcomeAt = now
                    if result == "received" {
                        command.step = .called
                        if tasks[command.taskID]?.state == "dispatched" { tasks[command.taskID]?.state = "accepted" }
                    } else if result == "not_received" {
                        command.step = .failed
                        if command.kind == "answer", _restoresQuestionOnNotReceived {
                            // 실제 서버(`20261118000000_bridge_commands.sql:394`): 답 명령의 not_received는 task를 failed로 만들지 않고 질문을 `awaiting_answer`로 복원한다
                            // (답은 아직 전달되지 않았다: 사용자가 다시 입력하면 새 답 명령이 만들어진다). 취소 요청 · run 상태 조건은 흉내 내지 않는다
                            tasks[command.taskID]?.state = "awaiting_answer"
                            tasks[command.taskID]?.openQuestion?.answeredStepID = nil
                        } else {
                            tasks[command.taskID]?.state = "failed"
                        }
                    }
                    commands[commandID] = command
                    return ok(["status": "settled", "task_state": tasks[command.taskID]?.state ?? "dispatched"])
                case "request_closed":
                    guard [.calling, .unknownOutcome].contains(command.step) else { return ok(["status": "stale", "reason": "wrong_state"]) }
                    command.step = .failed
                    command.outcome = "request_closed"
                    command.outcomeAt = now
                    commands[commandID] = command
                    return ok(["status": "settled"])
                default:
                    return Reply(status: 400, body: error("invalid_request", "op"))
                }
            }
        }
    }

    // MARK: events (D2a 3.5)

    private func events(bridgeID: String, json: [String: Any]) -> Reply {
        guard let list = json["events"] as? [Any] else { return Reply(status: 400, body: error("invalid_request", "events")) }
        return lock.withLock {
            var results: [[String: Any]] = []
            var accepted: [String] = []
            var retry: [String] = []
            var rejected: [[String: Any]] = []
            var blockedSessions: Set<String> = []
            for item in list {
                guard let event = item as? [String: Any], let eventID = event["event_id"] as? String, let type = event["type"] as? String,
                      let sessionRef = event["session_ref"] as? [String: Any], let sessionID = sessionRef["agent_session_id"] as? String else {
                    rejected.append(["event_id": (item as? [String: Any])?["event_id"] as? String ?? "?", "code": "invalid"])
                    continue
                }
                if blockedSessions.contains(sessionID) || retryOnce.contains(eventID) {
                    retryOnce.remove(eventID)
                    blockedSessions.insert(sessionID)
                    retry.append(eventID)
                    continue
                }
                let (status, taskState) = applyEvent(event: event, type: type, eventID: eventID, sessionID: sessionID, bridgeID: bridgeID)
                var result: [String: Any] = ["event_id": eventID, "status": status]
                if let taskState { result["task_state"] = taskState }
                results.append(result)
                _eventResults.append((eventID, type, status))
                accepted.append(eventID)
            }
            return ok(["results": results, "accepted_event_ids": accepted, "retry_event_ids": retry, "rejected": rejected])
        }
    }

    private func applyEvent(event: [String: Any], type: String, eventID: String, sessionID: String, bridgeID: String) -> (String, String?) {
        guard let session = sessions[sessionID] else { return ("not_found", nil) }
        if session.bridgeID != bridgeID { return ("wrong_bridge", nil) }
        let taskID = event["agent_task_id"] as? String ?? tasks.values.filter { $0.sessionID == sessionID }.max { $0.turnSeq < $1.turnSeq }?.id
        guard let taskID, var task = tasks[taskID], task.sessionID == sessionID else { return ("not_found", nil) }
        if seenEvents.contains("\(sessionID):\(eventID)") { return ("duplicate", task.state) }
        let turn = event["turn_seq"] as? Int
        let seq = event["seq"] as? Int
        // 다시 붙이기 (3.5-2): 단계가 unknown_outcome이고 lease 주인이 이 bridge이고 같은 turn이면 calling으로
        if let commandID = task.currentCommandID, var command = commands[commandID], command.step == .unknownOutcome,
           command.leaseOwner == "bridge:\(bridgeID):\(commandID)", turn == nil || turn == task.turnSeq, type != "session_bound" {
            command.step = .calling
            command.leaseExpiresAt = clock().addingTimeInterval(330)
            command.outcomeAt = nil
            command.outcome = nil
            commands[commandID] = command
        }
        if type != "session_bound", let turn, turn != task.turnSeq { seenEvents.insert("\(sessionID):\(eventID)"); return ("late", task.state) }
        var late = false
        if type != "session_bound", type != "accepted", let seq, seq <= task.lastEventSeq { late = true }
        let effective = task.state == "unreachable" ? (task.lastLiveState ?? "running") : task.state
        let activity = ["accepted", "progress", "message", "question", "artifact", "turn_completed"].contains(type)
        if activity, effective == "dispatched" {
            guard let commandID = task.currentCommandID, var command = commands[commandID], command.step == .calling, command.leaseOwner != nil else {
                return ("step_not_calling", task.state)
            }
            command.step = .called
            commands[commandID] = command
        }
        seenEvents.insert("\(sessionID):\(eventID)")
        if late { return ("late", task.state) }
        if type == "session_bound", let payload = event["payload"] as? [String: Any], let external = payload["external_session_id"] as? String {
            if let existing = sessions[sessionID]?.externalSessionID, existing == external { return ("ignored", task.state) }
            if sessions[sessionID]?.externalSessionID != nil { return ("conflict", task.state) }
            sessions[sessionID]?.externalSessionID = external
            sessions[sessionID]?.workspaceRef = payload["workspace_ref"] as? String
            return ("applied", task.state)
        }
        if let external = event["external_task_id"] as? String {
            if let existing = task.externalTaskID, existing != external { return ("conflict", task.state) }
            task.externalTaskID = external
        }
        if let seq { task.lastEventSeq = max(task.lastEventSeq, seq) }
        var state = effective
        switch type {
        case "accepted": if state == "dispatched" { state = "accepted" }
        case "progress", "message", "artifact":
            state = "running"
            task.openQuestion = nil
        case "question":
            state = "awaiting_answer"
            task.openQuestion = Self.openQuestion(in: event)
        case "turn_completed":
            state = "idle"
            task.openQuestion = nil
        case "failed":
            state = "failed"
            task.openQuestion = nil
        case "cancelled":
            state = "cancelled"
            task.openQuestion = nil
        case "reconcile":
            guard task.state == "unreachable" else { tasks[taskID] = task; return ("ignored", task.state) }
            state = task.lastLiveState ?? "running"
        default: break
        }
        if type == "reconcile" || task.state != "unreachable" { task.state = state } else { task.lastLiveState = state }
        if type == "failed", let commandID = task.currentCommandID, var command = commands[commandID], command.step == .calling {
            command.step = .failed
            commands[commandID] = command
        }
        tasks[taskID] = task
        return ("applied", task.state)
    }

    // MARK: answer-local (OA F2 · D4b-m-2): 이 Mac이 비밀값 질문에 답했다고 표시한다 (값은 오지 않는다). 실제 서버 규칙을 작게 흉내 낸다

    static func openQuestion(in event: [String: Any]) -> OpenQuestion? {
        guard let question = event["question"] as? [String: Any], let requestID = question["provider_request_id"] as? String else { return nil }
        let items = question["questions"] as? [[String: Any]] ?? []
        return OpenQuestion(
            requestID: requestID, digest: Self.sha256Hex(requestID), kind: question["kind"] as? String ?? "input", structured: question["structured"] as? Bool ?? false,
            secret: items.contains { ($0["secret"] as? Bool) == true }
        )
    }

    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func answerLocal(bridgeID: String, json: [String: Any]) -> Reply {
        lock.withLock {
            // 본문은 strict 3키다: 값을 실을 다른 키는 400 (문구는 고정)
            let digest = json["request_digest"] as? String ?? ""
            guard Set(json.keys) == ["bridge_id", "agent_task_id", "request_digest"], let taskID = json["agent_task_id"] as? String, UUID(uuidString: taskID) != nil,
                  digest.count == 64, digest.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                return Reply(status: 400, body: error("invalid_request", "Invalid local answer request."))
            }
            guard let task = tasks[taskID], sessions[task.sessionID]?.bridgeID == bridgeID else { return Reply(status: 404, body: error("not_found", "Local answer target not found.")) }
            guard task.state == "awaiting_answer", let open = task.openQuestion, open.digest == digest else { return ok(["status": "stale", "reason": "question_closed"]) }
            guard open.secret, open.kind == "input" else { return ok(["status": "stale", "reason": "not_secret"]) }
            let now = clock()
            let heartbeatAlive = bridges[bridgeID]?.lastHeartbeatAt.map { now.timeIntervalSince($0) <= 90 } ?? false
            guard heartbeatAlive, sessions[task.sessionID]?.status != "unreachable" else { return ok(["status": "stale", "reason": "not_live"]) }
            if let step = open.answeredStepID { return ok(["status": "duplicate", "step_id": step]) }
            guard let created = enqueueAnswerLocked(
                bridgeID: bridgeID, taskID: taskID, requestID: open.requestID, answers: nil, answerText: nil, locally: true, structured: open.structured, questionKind: open.kind,
                commandID: UUID().uuidString.lowercased(), extra: [:]
            ) else { return Reply(status: 404, body: error("not_found", "Local answer target not found.")) }
            tasks[taskID]?.openQuestion?.answeredStepID = created.stepID
            return ok(["status": "answered", "step_id": created.stepID])
        }
    }

    // MARK: heartbeat (D2a 3.6)

    private func heartbeat(bridgeID: String, json: [String: Any]) -> Reply {
        lock.withLock {
            guard var bridge = bridges[bridgeID] else { return Reply(status: 404) }
            let now = clock()
            if let last = bridge.lastHeartbeatAt, now.timeIntervalSince(last) < 5, var cached = bridge.cachedHeartbeat {
                cached["throttled"] = true
                return ok(cached)
            }
            bridge.lastHeartbeatAt = now
            if let adapters = json["adapters"] as? [[String: Any]] { bridge.report = adapters }
            var unknown: [String] = []
            var reported: Set<String> = []
            for item in json["tasks"] as? [[String: Any]] ?? [] {
                guard let taskID = item["task_id"] as? String else { continue }
                guard let task = tasks[taskID], sessions[task.sessionID]?.bridgeID == bridgeID else { unknown.append(taskID); continue }
                reported.insert(taskID)
                if item["process_alive"] as? Bool == true, let commandID = task.currentCommandID, var command = commands[commandID], command.step == .calling,
                   command.leaseOwner == "bridge:\(bridgeID):\(commandID)" {
                    command.leaseExpiresAt = max(command.leaseExpiresAt ?? now, now.addingTimeInterval(330))
                    commands[commandID] = command
                }
            }
            for (id, var session) in sessions where session.bridgeID == bridgeID && session.status == "unreachable" {
                session.status = "bound"
                sessions[id] = session
            }
            let missing = tasks.values.filter {
                sessions[$0.sessionID]?.bridgeID == bridgeID && ["accepted", "running", "awaiting_answer", "unreachable"].contains($0.state) && !reported.contains($0.id)
            }.map(\.id).prefix(50)
            // 실제 서버(`bridge_heartbeat`)처럼 prepared · calling · unknown_outcome 모두 센다
            let pending = pendingCountLocked(bridgeID: bridgeID)
            let response: [String: Any] = [
                "heartbeat_interval_seconds": 30, "server_time": iso(now), "pending_commands": pending, "unknown_task_ids": unknown, "missing_task_ids": Array(missing),
            ]
            bridge.cachedHeartbeat = response
            bridges[bridgeID] = bridge
            return ok(response)
        }
    }
}

private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
}

/// `FakeBridgeServer`로 가는 URLProtocol. 서버마다 다른 호스트로 갈라서 병렬 시험이 섞이지 않는다
final class FakeBridgeURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [String: FakeBridgeServer] = [:]
    private var loading: Task<Void, Never>?

    static func register(host: String, server: FakeBridgeServer) {
        lock.withLock { servers[host] = server }
    }

    static func unregister(host: String) {
        lock.withLock { servers[host] = nil }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host() else { return false }
        return lock.withLock { servers[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let host = request.url?.host(), let server = Self.lock.withLock({ Self.servers[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let request = self.request
        let body = Self.readBody(request)
        let box = UncheckedBox(value: self)
        loading = Task {
            let reply = await server.handle(request, body: body)
            guard !Task.isCancelled else { return }
            let me = box.value
            if reply.transportError {
                me.client?.urlProtocol(me, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            me.client?.urlProtocol(me, didReceive: response, cacheStoragePolicy: .notAllowed)
            me.client?.urlProtocol(me, didLoad: reply.body)
            me.client?.urlProtocolDidFinishLoading(me)
        }
    }

    override func stopLoading() {
        loading?.cancel()
    }

    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16384)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
#endif
