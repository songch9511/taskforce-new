#if os(macOS)
import Foundation
import Security

/// 중계 프로세스 하나 (PR-D3k): 지킴이 아래 `claude -p`의 stdin · stdout. 시험은 가짜를 쓴다 (`ClaudeAppRelayLauncher`)
public protocol ClaudeAppRelayProcess: Sendable {
    var pid: Int32 { get }
    /// 띄운 프로세스의 시작 시각 (정체 확인 · 시험 가짜는 nil일 수 있다)
    var startedAt: Date? { get }
    /// stdout 한 줄씩 (줄바꿈 없이). 프로세스가 끝나면 스트림이 끝난다
    var lines: AsyncStream<Data> { get }
    /// stdin에 쓴다 (한 줄, 끝에 `\n`은 부르는 쪽이 붙인다). 막히는 쓰기는 이 안에서 메인 밖에서 한다. 쓰지 못했으면 false
    func write(_ data: Data) async -> Bool
    /// stdin을 닫고 프로세스를 끝낸다 (돌아오면 끝난 것이다)
    func stop() async
    /// 지금도 띄운 그 프로세스인가 (pid · 시작 시각, ⑤)
    func identityMatches() -> Bool
}

public protocol ClaudeAppRelayLauncher: Sendable {
    /// `claude`를 `arguments`로, 빈 작업 폴더 `cwd`에서 띄운다. 환경은 이 안에서 정한다 (넷뿐, AC-42). 띄우지 못하면 던진다
    func launch(arguments: [String], cwd: String) async throws -> any ClaudeAppRelayProcess
}

/// 중계 프로세스의 pid (레일 · "On this Mac" 목록 · 다른 writer 확인이 Taskforce 자신의 프로세스로 빼는 값, 계약 25.4.1 "자기 제외"). 동기로 읽는다
public final class ClaudeAppRelayPIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Set<Int32> = []

    public init() {}

    /// 앱 하나에 중계가 하나다: 레일 폴러 · "On this Mac" 훑기 · 다른 writer 확인이 모두 이 값을 읽는다 (시험은 자기 값을 넘긴다)
    public static let shared = ClaudeAppRelayPIDs()

    public var current: Set<Int32> { lock.withLock { value } }
    func set(_ pids: Set<Int32>) { lock.withLock { value = pids } }
}

public enum ClaudeAppRelaySendResult: Equatable, Sendable {
    /// 대상 소켓에 넣었다 (mod `isDelivered true`). `relayPID`는 받는 쪽 기록의 `verifiedPeerPid`로 나올 값이다
    case delivered(relayPID: Int32)
    case notDelivered(ClaudeAppNotSentReason)
}

/// 중계 관리자 (PR-D3k, 계약 25.4.1 · 위협 DT4 · DT5 · DT6 · DT7 · DT12 · DT13). 사용자의 글을 데스크톱 Claude Code 세션에 "다른 세션의 메시지"로 넣는다:
/// 지킴이 아래 `claude -p --input-format stream-json …`를 늘 떠 있게 두고 번들 mod `tf-relay`의 `/tfsend`로 `$.session.send`를 한 번 부른다 (모델 0 · 비용 0).
/// - **인자는 바이트까지 고정**이다 (`arguments`): bypass · auto · dontAsk 0, 도구는 `SendMessage`뿐, 기록 파일은 만들지 않는다 (`--no-session-persistence`: 탐침으로 확인)
/// - **글은 stdin으로만** 간다 (`/tfsend <소문자 UUID>` + 줄바꿈 + 글, stream-json user 메시지 한 줄). argv · 환경 · 파일 · 로그에 글 0
/// - 띄우기 전 mod 파일 해시를 본다 (DT7). 띄운 뒤 첫 명령은 `/tfping <nonce>`: 돌려받은 nonce가 같아야 보낸다 (DT12)
/// - 모든 결과에서 모델 0을 확인한다: 모델이 불린 흔적이 하나라도 있으면 즉시 끝내고 **이 실행 동안** 끈다 (DT5)
/// - 한 번에 한 명령만 돈다 (순서대로). 쓰는 곳(`retain`)이 없어지고 2분 뒤 끝낸다. 죽으면 다음 보내기가 다시 띄운다 (pid가 바뀐다)
/// - 로그는 `claude_app_relay {result}` 코드뿐이다 (글 · id · 경로 · pid 0)
public actor ClaudeAppRelay {
    public struct Configuration: Sendable {
        /// 번들 안 mod 폴더 (`Contents/Resources/tf-relay`)
        public var modDirectory: String
        /// 앱 데이터 안 빈 폴더: 중계의 cwd (사용자 프로젝트가 아니다)
        public var workDirectory: String
        /// 쓰는 곳이 없어진 뒤 끝내기까지
        public var idleTimeout: TimeInterval
        /// 보내기 명령의 답을 기다리는 시간
        public var commandTimeout: TimeInterval
        /// 띄운 뒤 첫 명령(`/tfping`)의 답을 기다리는 시간
        public var startTimeout: TimeInterval

        public init(modDirectory: String, workDirectory: String, idleTimeout: TimeInterval = 120, commandTimeout: TimeInterval = 20, startTimeout: TimeInterval = 30) {
            self.modDirectory = modDirectory
            self.workDirectory = workDirectory
            self.idleTimeout = idleTimeout
            self.commandTimeout = commandTimeout
            self.startTimeout = startTimeout
        }
    }

    public typealias Sleep = @Sendable (TimeInterval) async -> Void

    /// 보낼 글의 상한 (mod와 서버가 같다: 16,000자)
    public static let maxTextLength = 16_000

    /// 중계의 인자 (계약 25.4.1, 바이트 고정). `--setting-sources ""`는 빈 글 인자 하나다
    public nonisolated static func arguments(modDirectory: String) -> [String] {
        [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--plugin-dir", modDirectory, "--setting-sources", "", "--strict-mcp-config", "--tools",
            "SendMessage", "--permission-mode", "default", "--name", "Taskforce", "--max-budget-usd", "0.01", "--no-session-persistence",
        ]
    }

    /// 무작위 nonce (소문자 hex 32자): `/tfping`이 그대로 돌려줘야 하는 값
    public static let randomNonce: @Sendable () -> String = {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private enum Phase { case stopped, ready }

    private enum Reply {
        case result(ClaudeAppRelayResult)
        case modelTurn
        case timeout
        case ended
        case writeFailed
    }

    /// 레일 · 목록이 빼는 중계의 pid
    public nonisolated let pids: ClaudeAppRelayPIDs

    private let configuration: Configuration
    private let launcher: any ClaudeAppRelayLauncher
    private let fileSystem: ExternalSessionFileSystem
    private let makeNonce: @Sendable () -> String
    private let sleep: Sleep
    private let log: any BridgeLogSink

    private var process: (any ClaudeAppRelayProcess)?
    private var phase = Phase.stopped
    /// 띄울 때마다 오른다: 끝난 프로세스의 늦은 줄 · 끝남 알림을 버린다
    private var generation = 0
    /// 이 실행 동안 꺼졌다 (모델 턴이 나왔다)
    private var disabled = false
    private var reader: Task<Void, Never>?
    private var waiter: (token: Int, continuation: CheckedContinuation<Reply, Never>)?
    private var nextToken = 0
    private var busy = false
    private var gate: [CheckedContinuation<Void, Never>] = []
    private var interest = 0
    private var idleTask: Task<Void, Never>?
    private var idleToken = 0

    public init(
        configuration: Configuration, launcher: any ClaudeAppRelayLauncher, fileSystem: ExternalSessionFileSystem = .live, makeNonce: @escaping @Sendable () -> String = ClaudeAppRelay.randomNonce,
        sleep: @escaping Sleep = { try? await Task.sleep(for: .seconds($0)) }, log: any BridgeLogSink = NoBridgeLog(), pids: ClaudeAppRelayPIDs = ClaudeAppRelayPIDs()
    ) {
        self.pids = pids
        self.configuration = configuration
        self.launcher = launcher
        self.fileSystem = fileSystem
        self.makeNonce = makeNonce
        self.sleep = sleep
        self.log = log
    }

    // MARK: 상태

    /// ⑤ 보내기 전 확인이 보는 중계의 상태
    public func readiness() -> ClaudeAppSendContext.Relay {
        if disabled { return .unavailable }
        guard let process, phase == .ready else { return .notRunning }
        return process.identityMatches() ? .ready : .mismatch
    }

    // MARK: 쓰는 곳 (2분 유휴)

    /// 입력창이 보이거나 따라가는 교환이 있다: 끝내기를 미룬다
    public func retain() {
        interest += 1
        cancelIdle()
    }

    public func release() {
        interest = max(0, interest - 1)
        if interest == 0 { scheduleIdle() }
    }

    /// 입력창이 보일 때 미리 띄워 둔다 (첫 보내기가 중계가 뜨기를 4초쯤 기다리지 않게): 글은 쓰지 않는다. 준비됐으면 true
    @discardableResult
    public func prepare() async -> Bool {
        await acquire()
        defer { releaseGate() }
        guard await ensureReady() else { return false }
        if interest == 0 { scheduleIdle() }
        return true
    }

    private func cancelIdle() {
        idleTask?.cancel()
        idleTask = nil
        idleToken += 1
    }

    private func scheduleIdle() {
        guard process != nil else { return }
        cancelIdle()
        let token = idleToken
        let timeout = configuration.idleTimeout
        let sleep = sleep
        idleTask = Task { [weak self] in
            await sleep(timeout)
            guard !Task.isCancelled else { return }
            await self?.idleExpired(token)
        }
    }

    private func idleExpired(_ token: Int) async {
        guard token == idleToken, interest == 0, process != nil else { return }
        log.log("claude_app_relay", ["result": .code("idle_stop")])
        await stopProcess()
    }

    // MARK: 보내기

    /// 글을 `sessionID`(소문자 UUID)의 데스크톱 세션에 넣는다. 부르는 쪽이 보내기 전 확인(`ClaudeAppSendCheck`)을 먼저 한다.
    /// 막히는 일이 없게 중계를 띄우고 명령이 끝날 때까지 기다린다 (한 번에 하나)
    public func send(sessionID: String, text: String) async -> ClaudeAppRelaySendResult {
        // mod가 거절할 입력은 프로세스에 닿지 않는다 (옵션 · 줄바꿈 주입 · 길이 · NUL)
        guard ExternalSessionRules.isCanonicalUUID(sessionID), (1...Self.maxTextLength).contains(text.utf16.count), !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
            return .notDelivered(.relayFailed)
        }
        await acquire()
        defer { releaseGate() }
        guard await ensureReady() else { return .notDelivered(.relayFailed) }
        guard let process else { return .notDelivered(.relayFailed) }
        let pid = process.pid
        let reply = await command("/tfsend \(sessionID)\n\(text)", timeout: configuration.commandTimeout)
        let result: ClaudeAppRelaySendResult
        switch reply {
        case .result(let parsed):
            switch ClaudeAppRelayAnswer.sendOutcome(parsed) {
            case .delivered: result = .delivered(relayPID: pid)
            case .notDelivered(let reason): result = .notDelivered(reason)
            case .failed: result = .notDelivered(.relayFailed)
            }
        case .modelTurn, .timeout, .ended, .writeFailed:
            await failed(reply)
            result = .notDelivered(.relayFailed)
        }
        if interest == 0 { scheduleIdle() }
        return result
    }

    /// 앱 종료 · 로그아웃 · 플래그 꺼짐: 바로 끝낸다
    public func shutdown() async {
        cancelIdle()
        interest = 0
        await stopProcess()
    }

    // MARK: 띄우기 · 건강 확인

    private func ensureReady() async -> Bool {
        if disabled { return false }
        if let process, phase == .ready {
            if process.identityMatches() { return true }
            // ⑤ 띄운 뒤 정체가 바뀌었다: 글을 쓰지 않고 새로 띄운다
            log.log("claude_app_relay", ["result": .code("identity_changed")])
            await stopProcess()
        }
        // DT7: 해시 다른 mod는 띄우지 않는다
        guard ClaudeAppRelayMod.verify(directory: configuration.modDirectory, fileSystem: fileSystem) == .ok else {
            log.log("claude_app_relay", ["result": .code("mod_hash")])
            return false
        }
        let launched: any ClaudeAppRelayProcess
        do {
            launched = try await launcher.launch(arguments: Self.arguments(modDirectory: configuration.modDirectory), cwd: configuration.workDirectory)
        } catch {
            log.log("claude_app_relay", ["result": .code("launch_failed")])
            return false
        }
        generation += 1
        let started = generation
        process = launched
        phase = .ready
        pids.set([launched.pid])
        reader = Task { [weak self] in
            for await line in launched.lines { await self?.consume(line, generation: started) }
            await self?.ended(generation: started)
        }
        // DT12: 첫 명령은 /tfping <nonce>. 같은 nonce가 돌아와야 보낸다
        let nonce = makeNonce()
        let reply = await command("/tfping \(nonce)", timeout: configuration.startTimeout)
        guard case .result(let parsed) = reply, ClaudeAppRelayAnswer.pingMatches(parsed, nonce: nonce) else {
            if case .result = reply { log.log("claude_app_relay", ["result": .code("ping_failed")]) } else { await failed(reply) }
            await stopProcess()
            return false
        }
        log.log("claude_app_relay", ["result": .code("started")])
        return true
    }

    /// 명령이 답 없이 끝났다: 까닭을 코드로 남기고 중계를 끝낸다 (모델 턴이면 이 실행을 끈다)
    private func failed(_ reply: Reply) async {
        switch reply {
        case .modelTurn: log.log("claude_app_relay", ["result": .code("model_turn")])
        case .timeout: log.log("claude_app_relay", ["result": .code("timeout")])
        case .ended: log.log("claude_app_relay", ["result": .code("exited")])
        case .writeFailed: log.log("claude_app_relay", ["result": .code("write_failed")])
        case .result: break
        }
        await stopProcess()
    }

    // MARK: 명령 한 번 (한 번에 하나)

    private func acquire() async {
        if busy {
            await withCheckedContinuation { gate.append($0) }
        } else {
            busy = true
        }
    }

    private func releaseGate() {
        if gate.isEmpty {
            busy = false
        } else {
            gate.removeFirst().resume()
        }
    }

    /// stream-json user 메시지 한 줄을 쓰고 `result` 줄을 기다린다. 글은 이 한 줄 안에만 있다
    private func command(_ content: String, timeout: TimeInterval) async -> Reply {
        guard let process, phase == .ready else { return .ended }
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        guard var line = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return .writeFailed }
        line.append(0x0A)
        nextToken += 1
        let token = nextToken
        let sleep = sleep
        let timer = Task { [weak self] in
            await sleep(timeout)
            guard !Task.isCancelled else { return }
            await self?.resolve(token, .timeout)
        }
        let payload = line
        let reply: Reply = await withCheckedContinuation { continuation in
            waiter = (token, continuation)
            Task { [weak self] in
                if await process.write(payload) == false { await self?.resolve(token, .writeFailed) }
            }
        }
        timer.cancel()
        return reply
    }

    private func resolve(_ token: Int, _ reply: Reply) {
        guard let current = waiter, current.token == token else { return }
        waiter = nil
        current.continuation.resume(returning: reply)
    }

    // MARK: stdout

    private func consume(_ data: Data, generation started: Int) async {
        guard started == generation else { return }
        let line = ClaudeAppRelayLine.parse(data)
        // DT5: 모델이 불린 흔적(어느 줄이든)이 있으면 즉시 끝내고 이 실행 동안 끈다
        if line.isModelTurn {
            disabled = true
            if let current = waiter { resolve(current.token, .modelTurn) } else { await failed(.modelTurn) }
            return
        }
        if case .result(let result) = line, let current = waiter { resolve(current.token, .result(result)) }
    }

    private func ended(generation finished: Int) async {
        guard finished == generation, process != nil else { return }
        if let current = waiter { resolve(current.token, .ended) }
        log.log("claude_app_relay", ["result": .code("exited")])
        let dead = process
        process = nil
        phase = .stopped
        pids.set([])
        cancelIdle()
        // 스스로 끝난 프로세스도 거둔다 (지킴이 · 보고 fd를 남기지 않는다)
        await dead?.stop()
    }

    private func stopProcess() async {
        let stopping = process
        process = nil
        phase = .stopped
        generation += 1
        pids.set([])
        cancelIdle()
        reader?.cancel()
        reader = nil
        if let current = waiter { resolve(current.token, .ended) }
        await stopping?.stop()
    }
}
#endif
