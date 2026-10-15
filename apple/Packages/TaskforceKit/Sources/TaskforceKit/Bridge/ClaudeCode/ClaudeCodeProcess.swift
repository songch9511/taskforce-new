#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import Synchronization
import TaskforceAgentWire

// Claude Code adapter (OA D3a 계약 0.1 · 2장). 턴마다 `claude -p` 프로세스 하나를 띄우고 감독한다.
//
// - **판정은 서버, 파일 시스템 사실과 전송 안전 규칙은 Mac** (2.7): 훅 요청은 `ClaudeToolGate`가 정한다. Bash · Edit · Write는 서버 판정 없이 자동 허용하지 않는다.
// - **CLI가 말한 것이 사실이다:** 보류는 `result.deferred_tool_use`로만 확정하고, 접수는 진짜 첫 assistant(synthetic 제외)로만, 버전은 init으로 다시 본다. transcript는 읽지 않는다.
// - **다시 보내지 않는다:** 스스로 턴을 다시 띄우지 않는다. 결과를 모르면 런타임이 `unknown`으로 답한다 (`inputReached`, Q5).
// - **글 사본 0:** 사용자 메시지 · 답 · 비밀값 · 도구 입력 · 출력 · stream 원문을 세션 폴더 · 원장 · 로그에 쓰지 않는다. 세션 폴더에는 설정 두 파일(spawn 동안)과 상태 파일만.
// - **writer 하나:** 같은 세션의 앞 프로세스가 끝난 뒤에만 다음 프로세스를 띄운다 (닫기 · 답 resume 포함).
// - **init은 부수 효과 0:** probe · 폴더 만들기 · 소켓 없음. 런타임이 부를 때만 한다.

/// 시험 전용 끼어들기 (Release에는 없다)
public struct ClaudeCodeTestHooks: Sendable {
    /// 설정 파일을 쓴 직후 (① 변조 시험, E8)
    public var afterConfigWrite: (@Sendable (URL) -> Void)?
    /// 결정기 앞에서 기다린다 (훅 예산 시험, E17)
    public var gateDelay: Duration?

    public init(afterConfigWrite: (@Sendable (URL) -> Void)? = nil, gateDelay: Duration? = nil) {
        self.afterConfigWrite = afterConfigWrite
        self.gateDelay = gateDelay
    }
}

public actor ClaudeCodeProcess: AgentProcess {
    public nonisolated let adapter = ClaudeCodeSupport.adapterID

    nonisolated let sessionsRoot: URL
    nonisolated let hookServer: HookSocketServer?
    nonisolated let helpers: ClaudeCodeHelpers
    nonisolated let locator: ClaudeCodeLocator
    nonisolated let environment: [String: String]
    nonisolated let fileSystem: GateFileSystem
    nonisolated let timing: ClaudeCodeTiming
    nonisolated let log: any BridgeLogSink
    nonisolated let probeActor: ClaudeCodeProbe
    nonisolated let testHooks: ClaudeCodeTestHooks
    nonisolated let services = Mutex<AgentRuntimeServices?>(nil)

    private var spawns: [String: Spawn] = [:]
    private var sessionSpawn: [String: String] = [:]
    private var taskSpawn: [String: String] = [:]

    /// - `sessionsRoot`: `<원장 파티션 폴더>/claude-code` (계정 삭제는 파티션째 지운다)
    /// - `hookServer`: 앱 전체 소켓 (bridge가 꺼져 있으면 nil: 새 턴 · 답은 `spawn_failed`, 닫기는 소켓 없이 — 훅이 모두 deny)
    public init(
        sessionsRoot: URL, hookServer: HookSocketServer?, helpers: ClaudeCodeHelpers, locator: ClaudeCodeLocator,
        environment: [String: String] = ProcessInfo.processInfo.environment, managedSettingsPath: String = ClaudeCodeProbe.managedSettingsPath,
        fileSystem: GateFileSystem = .live, timing: ClaudeCodeTiming = .standard, log: any BridgeLogSink = NoBridgeLog(), runner: ClaudeCommandRunner? = nil,
        testHooks: ClaudeCodeTestHooks = ClaudeCodeTestHooks()
    ) {
        self.sessionsRoot = sessionsRoot
        self.hookServer = hookServer
        self.helpers = helpers
        self.locator = locator
        self.environment = environment
        self.fileSystem = fileSystem
        self.timing = timing
        self.log = log
        #if DEBUG
        self.testHooks = testHooks
        #else
        self.testHooks = ClaudeCodeTestHooks()
        #endif
        let probeCwd = sessionsRoot.appending(path: "probe-cwd", directoryHint: .isDirectory)
        self.probeActor = ClaudeCodeProbe(
            locator: locator,
            runner: runner ?? ClaudeCodeProbe.liveRunner(environment: environment, cwd: {
                try? FileManager.default.createDirectory(at: probeCwd, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                return probeCwd.path
            }),
            managedSettingsPath: managedSettingsPath, timeout: timing.probeTimeout, log: log
        )
    }

    // MARK: AgentProcess — 보고 · 연결

    public nonisolated func attach(_ services: AgentRuntimeServices) {
        self.services.withLock { $0 = services }
    }

    public func probe() async -> BridgeV1AdapterReport {
        await probeActor.report()
    }

    public nonisolated func supportsVersion(_ version: String?) -> Bool {
        ClaudeCodeSupport.supports(version)
    }

    // MARK: 새 턴

    public func startTurn(_ turn: AgentTurnStart, events: AgentEventSink) async throws -> AgentProcessIdentity {
        guard let workspace = turn.workspaceRef.flatMap(workspaceRealPath), hookServer != nil, let executable = locator.locate() else { throw AgentStartError(.spawnFailed) }
        await waitForSessionIdle(turn.sessionID)
        let folder = try ClaudeSessionFolder.prepare(sessionsRoot: sessionsRoot, agentSessionID: turn.sessionID)
        var state = ClaudeSessionState.load(from: folder.root)
        let providerID: String
        let session: ClaudeCodeLaunch.SessionArgument
        var newSession: String?
        if let external = turn.externalSessionID {
            guard BridgeRuntime.isSafeSessionID(external) else { throw AgentStartError(.spawnFailed) }
            providerID = external
            session = .resume(external)
        } else {
            // 새 세션: id를 만들어 적는다. init이 같은 id를 돌려주면 `session_bound` (Q15). 묶이지 않은 id는 다음 턴에 버린다
            providerID = UUID().uuidString.lowercased()
            session = .new(providerID)
            newSession = providerID
            state.providerSessionID = providerID
            state.bound = false
        }
        // 이 세션에서 다른 프로세스가 돈다: 앞의 보류는 더는 열려 있지 않다 (13.2 :511)
        state.openDeferred = nil
        try? state.save(in: folder.root)
        let spawn = try launch(
            mode: .turn(newSessionID: newSession), session: session, providerID: providerID, agentSessionID: turn.sessionID, taskID: turn.taskID, turnSeq: turn.turnSeq,
            access: turn.access, workspace: workspace, folder: folder, executable: executable, sink: events, stdin: Data(turn.text.utf8)
        )
        guard let identity = spawn.identity else { throw AgentStartError(.spawnFailed) }
        return identity
    }

    // MARK: 답 (계약 2.10-3)

    public func deliverAnswer(_ answer: AgentAnswerDelivery, events: AgentEventSink) async throws -> AgentAnswerResult {
        guard let workspace = answer.workspaceRef.flatMap(workspaceRealPath) else { throw AgentStartError(.spawnFailed) }
        guard let external = answer.externalSessionID, BridgeRuntime.isSafeSessionID(external) else { return .requestClosed }
        guard hookServer != nil, let executable = locator.locate() else { throw AgentStartError(.spawnFailed) }
        await waitForSessionIdle(answer.sessionID)
        let folder = try ClaudeSessionFolder.prepare(sessionsRoot: sessionsRoot, agentSessionID: answer.sessionID)
        var state = ClaudeSessionState.load(from: folder.root)
        // 열린 보류가 아니면 spawn 0 (ONE-TF-03, AC-37, G28)
        guard let open = state.openDeferred, open.id == answer.requestID, open.kind == answer.kind.rawValue else {
            log.log("claude_answer_closed", ["task": .id(answer.taskID)])
            return .requestClosed
        }
        state.openDeferred = nil
        try? state.save(in: folder.root)
        let binding = ClaudeAnswerBinding(requestID: answer.requestID, kind: answer.kind, inputSHA256: open.inputSHA256, value: answer.value)
        let spawn = try launch(
            mode: .answer(requestID: answer.requestID), binding: binding, session: .resume(external), providerID: external, agentSessionID: answer.sessionID,
            taskID: answer.taskID, turnSeq: answer.turnSeq, access: answer.access, workspace: workspace, folder: folder, executable: executable, sink: events, stdin: Data()
        )
        // 보류 id의 훅이 오면 그 순간 전달이다. 그 전에 init이나 다른 호출이 오면(상태 유실) 멈추고 닫힘, 그 전에 끝나면 던진다
        var signal = spawn.answerSignal
        while signal == nil {
            try? await Task.sleep(for: .milliseconds(5))
            signal = spawn.answerSignal
        }
        switch signal {
        case .delivered(let at):
            guard var identity = spawn.identity else { throw AgentStartError(.agentError) }
            identity.inputSentAt = at
            return .delivered(identity)
        case .lost:
            _ = await waitForEnd(spawn, timeout: timing.closeTimeout)
            return .requestClosed
        default:
            throw AgentStartError(.agentError)
        }
    }

    // MARK: 닫기 (계약 2.12)

    public func closeRequest(_ request: AgentRequestRef) async throws {
        guard let workspace = request.workspaceRef.flatMap(workspaceRealPath) else { throw AgentStartError(.spawnFailed) }
        // Claude 세션이 없으면 닫을 보류도 없다
        guard let external = request.externalSessionID, BridgeRuntime.isSafeSessionID(external) else { return }
        guard let executable = locator.locate() else { throw AgentStartError(.spawnFailed) }
        await waitForSessionIdle(request.sessionID)
        try await close(requestID: request.requestID, providerID: external, agentSessionID: request.sessionID, taskID: request.taskID, workspace: workspace, executable: executable)
    }

    private func close(requestID: String, providerID: String, agentSessionID: String, taskID: String, workspace: String, executable: ClaudeCodeExecutable) async throws {
        let folder = try ClaudeSessionFolder.prepare(sessionsRoot: sessionsRoot, agentSessionID: agentSessionID)
        var state = ClaudeSessionState.load(from: folder.root)
        state.openDeferred = nil
        try? state.save(in: folder.root)
        // 닫기 spawn의 사건은 서버로 보내지 않는다 (sink 없음). 모든 훅이 deny, 닫는 id의 결과에서 SIGINT
        let spawn = try launch(
            mode: .close(requestID: requestID), session: .resume(providerID), providerID: providerID, agentSessionID: agentSessionID, taskID: taskID, turnSeq: 1,
            access: .write, workspace: workspace, folder: folder, executable: executable, sink: nil, stdin: Data()
        )
        // 끝날 때까지 기다린다 (다음 startTurn이 두 번째 writer를 만들지 않게). 10초 안에 끝나지 않으면 고아 끝내기
        if await !waitForEnd(spawn, timeout: timing.closeTimeout), let identity = spawn.identity {
            _ = await terminate(identity)
            _ = await waitForEnd(spawn, timeout: timing.orphanKillGrace + 1)
        }
    }

    // MARK: 중단 · 고아 (계약 2.13 · 2.14)

    public func interrupt(_ target: AgentTurnRef, scope: AgentCancelScope) async -> AgentInterruptResult {
        guard let spawnID = taskSpawn[target.taskID], let spawn = spawns[spawnID], !spawn.exited, let identity = spawn.identity else { return .notRunning }
        spawn.mapper.markInterruptRequested()
        guard ClaudeProcessInspector.interrupt(identity) else { return .notRunning }
        log.log("claude_interrupt", ["task": .id(target.taskID)])
        return .signalled
    }

    public func liveness(_ identity: AgentProcessIdentity) async -> AgentLiveness {
        ClaudeProcessInspector.liveness(identity)
    }

    public func terminateOrphan(_ identity: AgentProcessIdentity) async -> AgentLiveness {
        await terminate(identity)
    }

    nonisolated func terminate(_ identity: AgentProcessIdentity) async -> AgentLiveness {
        let timing = self.timing
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: ClaudeProcessInspector.terminate(identity, timing: timing))
            }
        }
    }

    // MARK: 띄우기

    /// 작업 폴더: `realpath(3)`, 디렉터리이고 소유자가 이 사용자 (계약 2.4)
    nonisolated func workspaceRealPath(_ ref: String) -> String? {
        guard ref.hasPrefix("/"), let real = GateFileSystem.realpath(ref) else { return nil }
        var info = stat()
        guard stat(real, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else { return nil }
        return real
    }

    private func launch(
        mode: ClaudeMapperConfig.Mode, binding: ClaudeAnswerBinding? = nil, session: ClaudeCodeLaunch.SessionArgument, providerID: String, agentSessionID: String, taskID: String,
        turnSeq: Int, access: AgentAccess, workspace: String, folder: ClaudeSessionFolder, executable: ClaudeCodeExecutable, sink: AgentEventSink?, stdin: Data
    ) throws -> Spawn {
        let spawnID = UUID().uuidString
        let nonce = ClaudeCodeLaunch.newNonce()
        // 소켓이 없으면(닫기만) 없는 경로를 준다: 훅은 연결하지 못해 모두 deny한다
        let socket = hookServer?.path ?? folder.config.appending(path: "no-socket").path
        let settings = try ClaudeCodeLaunch.settingsJSON(hook: helpers.hook, socket: socket, session: agentSessionID, nonce: nonce)
        let mcp = ClaudeCodeLaunch.mcpJSON(helper: helpers.mcp, session: agentSessionID)
        let files = try ClaudeCodeLaunch.writeConfig(directory: folder.config, spawnID: spawnID, settings: settings, mcp: mcp)
        testHooks.afterConfigWrite?(files.settings)
        // ①: 쓴 파일을 다시 읽어 기대 값과 같을 때만 띄운다
        guard ClaudeCodeLaunch.verifyConfig(files, settings: settings, mcp: mcp) else {
            ClaudeCodeLaunch.removeConfig(files)
            log.log("claude_selfcheck_failed", ["check": .count(1)])
            throw AgentStartError(.spawnFailed)
        }
        let cwdReal = GateFileSystem.realpath(folder.cwd.path) ?? folder.cwd.path
        let environment = ClaudeCodeEnvironment.child(app: self.environment, executable: executable)
        let mapper = ClaudeEventMapper(config: ClaudeMapperConfig(
            mode: mode, expectedSessionID: providerID, expectedTools: ClaudeCodeSupport.initTools(for: access), expectedCwd: cwdReal, requireSessionStart: true,
            workspaceRealPath: workspace, versionSupported: { ClaudeCodeSupport.supports($0) }
        ))
        let spawn = Spawn(
            id: spawnID, nonce: nonce, mode: mode, providerID: providerID, agentSessionID: agentSessionID, taskID: taskID, turnSeq: turnSeq, access: access, workspace: workspace,
            folder: folder, cwdReal: cwdReal, childPATH: environment["PATH"] ?? "", files: files, sink: sink, mapper: mapper
        )
        spawn.binding = binding
        let answered = spawn.answered
        hookServer?.register(nonce: nonce, HookSocketServer.Registration(agentSessionID: agentSessionID, providerSessionID: providerID, handler: { [weak self] request in
            await self?.handleHook(spawnID: spawnID, request) ?? HookResponse(decision: .deny, reason: ClaudeGateReason.turnStopped)
        }, onAnswer: { id in answered.insert(id) }))
        let arguments = ClaudeCodeLaunch.arguments(access: access, workspace: workspace, settings: files.settings.path, mcp: files.mcp.path, session: session)
        let process: ClaudeSpawnedProcess
        do {
            process = try ClaudeSpawner.spawn(executable: executable.path, arguments: arguments, environment: environment, cwd: folder.cwd.path)
        } catch {
            hookServer?.unregister(nonce: nonce, after: .zero)
            ClaudeCodeLaunch.removeConfig(files)
            throw AgentStartError(.spawnFailed)
        }
        spawn.process = process
        spawn.identity = AgentProcessIdentity(pid: Int(process.pid), startedAt: process.startedAt, processMarker: spawnID, externalTaskID: "\(providerID):\(turnSeq)")
        spawns[spawnID] = spawn
        sessionSpawn[agentSessionID] = spawnID
        taskSpawn[taskID] = spawnID
        // stdin: 새 턴은 메시지 글을 쓰고 닫는다. 답 · 닫기 resume는 아무것도 쓰지 않고 닫는다 (빈 stdin, 13.2 :509, 사례 8-05). 쓰기는 따로 (파이프 64KB 막힘 방지)
        let input = process.stdinFD
        DispatchQueue.global(qos: .userInitiated).async {
            _ = HookMain.writeAll(fd: input, stdin)
            Darwin.close(input)
        }
        supervise(spawn, process: process)
        log.log("claude_spawn", ["mode": .code(spawn.modeName)])
        return spawn
    }

    // MARK: 훅 요청 (소켓 → 결정기)

    func handleHook(spawnID: String, _ request: HookRequest) async -> HookResponse {
        guard let spawn = spawns[spawnID] else { return HookResponse(decision: .deny, reason: ClaudeGateReason.turnStopped) }
        // 한 spawn의 훅은 하나씩 정한다 (defer 하나 · 답 한 번이 겹치지 않게)
        let previous = spawn.hookTail
        let task = Task { () -> HookResponse in
            await previous?.value
            return await self.decide(spawn: spawn, request)
        }
        spawn.hookTail = Task { _ = await task.value }
        return await task.value
    }

    private func decide(spawn: Spawn, _ request: HookRequest) async -> HookResponse {
        let started = Date()
        spawn.facts.toolNames[request.toolUseID] = request.toolName
        if ["Edit", "Write"].contains(request.toolName), let path = request.toolInput["file_path"]?.stringValue, let absolute = GateFileSystem.absolute(path, cwd: request.cwd) {
            spawn.facts.filePaths[request.toolUseID] = absolute
        }
        let gateMode: ClaudeGateContext.Mode
        switch spawn.mode {
        case .turn: gateMode = .normal
        case .answer: gateMode = spawn.binding.map { .answer($0) } ?? .normal
        case .close(let requestID): gateMode = .close(requestID: requestID)
        }
        let context = ClaudeGateContext(
            mode: gateMode, access: spawn.access, workspaceRealPath: spawn.workspace, sessionCwdRealPath: spawn.cwdReal, childPATH: spawn.childPATH,
            agentSessionID: spawn.agentSessionID, agentTaskID: spawn.taskID, turnSeq: spawn.turnSeq, deferIssued: spawn.deferIssued, answerDelivered: spawn.answerDelivered
        )
        if let delay = testHooks.gateDelay { try? await Task.sleep(for: delay) }
        let gate = ClaudeToolGate(fileSystem: fileSystem, decide: services.withLock { $0 }?.decideTool, serverTimeout: .milliseconds(Int(timing.serverTimeout * 1000)))
        let outcome = await gate.evaluate(request, context: context)
        if outcome.response.decision == .defer, let deferred = outcome.deferred {
            spawn.deferIssued = true
            spawn.facts.pending = deferred
        }
        if outcome.answeredPending {
            spawn.answerDelivered = true
            // 답(비밀값 포함)은 보류 id 훅에 한 번 주고 메모리에서도 지운다
            spawn.binding?.value = AgentAnswerValue()
            if spawn.answerSignal == nil { spawn.answerSignal = .delivered(Date()) }
            await spawn.sink?.emit(.progress)
        }
        if outcome.abortSpawn {
            if spawn.answerSignal == nil { spawn.answerSignal = .lost }
            sendInterrupt(spawn)
        }
        log.log("tool_gate", [
            "source": .code(outcome.source.rawValue), "decision": .code(outcome.response.decision.rawValue), "reason": .code(outcome.code),
            "ms": .millis(Int(Date().timeIntervalSince(started) * 1000)),
        ])
        return outcome.response
    }

    // MARK: 감독

    enum ReaderItem: Sendable {
        case line(Data)
        case oversized
        case eof
        case exited(ClaudeExitStatus)
        case drainTimeout
    }

    /// stdout 한 줄 상한 (⑥)
    static let maxLineBytes = 32 * 1024 * 1024

    private func supervise(_ spawn: Spawn, process: ClaudeSpawnedProcess) {
        let (stream, continuation) = AsyncStream<ReaderItem>.makeStream()
        let stop = spawn.readerStop
        let output = process.stdoutFD
        let errors = process.stderrFD
        DispatchQueue.global(qos: .userInitiated).async {
            Self.readLines(fd: output, stop: stop) { continuation.yield($0) }
            continuation.yield(.eof)
            Darwin.close(output)
        }
        DispatchQueue.global(qos: .utility).async {
            // stderr는 읽어 버린다 (바이트 수도 남기지 않는다: 글이 섞일 수 있다)
            var sink = [UInt8](repeating: 0, count: 8192)
            while read(errors, &sink, sink.count) > 0 {}
            Darwin.close(errors)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.yield(.exited(process.waitForExit()))
        }
        let drain = timing.drainAfterExit
        Task {
            var exited: ClaudeExitStatus?
            var eof = false
            loop: for await item in stream {
                switch item {
                case .line(let line):
                    await self.consume(spawn, line: line)
                case .oversized:
                    await self.apply(spawn, spawn.mapper.oversizedLine())
                case .eof:
                    eof = true
                    if exited != nil { break loop }
                case .exited(let status):
                    exited = status
                    spawn.exited = true
                    if eof { break loop }
                    Task {
                        try? await Task.sleep(for: .seconds(drain))
                        continuation.yield(.drainTimeout)
                    }
                case .drainTimeout:
                    break loop
                }
            }
            stop.set()
            continuation.finish()
            await self.finish(spawn, status: exited ?? ClaudeExitStatus(code: nil, signal: nil))
        }
    }

    /// stdout을 줄로 나눈다. 줄 하나가 상한을 넘으면 `.oversized` 한 번 내고 다음 줄바꿈까지 버린다
    nonisolated static func readLines(fd: Int32, stop: Flag, yield: (ReaderItem) -> Void) {
        var pending = Data()
        var skipping = false
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while !stop.isSet {
            var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&item, 1, 200)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { continue }
            let count = buffer.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress!, $0.count) }
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count > 0 else { break }
            pending.append(contentsOf: buffer[0..<count])
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending = Data(pending[pending.index(after: newline)...])
                if skipping {
                    skipping = false
                } else if !line.isEmpty {
                    yield(.line(Data(line)))
                }
            }
            if pending.count > maxLineBytes {
                pending.removeAll()
                if !skipping { yield(.oversized) }
                skipping = true
            }
        }
        if !pending.isEmpty, !skipping { yield(.line(pending)) }
    }

    private func consume(_ spawn: Spawn, line: Data) async {
        guard let event = ClaudeStreamParser.parse(line) else { return }
        await apply(spawn, spawn.mapper.consume(event, facts: spawn.snapshot(), now: Date()))
    }

    private func apply(_ spawn: Spawn, _ actions: [ClaudeMapperAction]) async {
        for action in actions {
            switch action {
            case .emit(let event):
                await spawn.sink?.emit(event)
            case .interrupt(let cause):
                switch cause {
                case .selfCheck(let check): log.log("claude_selfcheck_failed", ["check": .count(check)])
                case .answerLost: if spawn.answerSignal == nil { spawn.answerSignal = .lost }
                case .closeDone: break
                }
                sendInterrupt(spawn)
            case .confirmQuestion(let pending):
                // 보고된 보류만 열린 요청이다: id · 종류 · digest만 적는다 (글 0)
                var state = ClaudeSessionState.load(from: spawn.folder.root)
                state.openDeferred = ClaudeSessionState.OpenDeferred(id: pending.id, kind: pending.kind.rawValue, inputSHA256: pending.inputSHA256, spawnID: spawn.id, at: Date())
                try? state.save(in: spawn.folder.root)
            case .unexpectedDeferred(let id):
                spawn.unexpectedDeferred = id
                log.log("claude_unexpected_deferred", [:])
            case .artifacts(let candidates):
                for candidate in candidates {
                    if let artifact = artifact(candidate, workspace: spawn.workspace) {
                        await spawn.sink?.emit(.artifact(path: artifact.path, hash: artifact.hash, summary: artifact.summary))
                    }
                }
            case .signInNeeded:
                await probeActor.invalidateLogin()
            case .initSeen(let info):
                if case .turn(let newSessionID?) = spawn.mode, info.sessionID == newSessionID {
                    var state = ClaudeSessionState.load(from: spawn.folder.root)
                    state.providerSessionID = newSessionID
                    state.bound = true
                    try? state.save(in: spawn.folder.root)
                }
                log.log("claude_init", [
                    "mode": .code(spawn.modeName), "ms_to_init": .millis(Int(Date().timeIntervalSince(spawn.startedAt) * 1000)), "plugins": .count(info.hasPlugins ? 1 : 0),
                    "skills": .count(info.hasSkills ? 1 : 0), "messaging_socket": .count(info.hasMessagingSocket ? 1 : 0),
                ])
            case .resultSeen:
                // result 뒤에는 스스로 끝나야 한다: 끝나지 않으면 SIGINT
                let wait = timing.exitAfterResult
                spawn.resultTimer = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(wait))
                    guard !Task.isCancelled else { return }
                    await self?.sendInterrupt(spawn)
                }
            }
        }
    }

    /// 산출물: 작업 폴더 기준 realpath 상대 경로 · 결과 뒤 파일의 sha256 (D3c-2 Q19)
    nonisolated func artifact(_ candidate: ClaudeArtifactCandidate, workspace: String) -> (path: String, hash: String, summary: String)? {
        guard let real = fileSystem.realpath(candidate.filePath), real != workspace, GateFileSystem.isInside(real, root: workspace),
              let handle = FileHandle(forReadingAtPath: real) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        let hash = "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let relative = String(real.dropFirst(workspace == "/" ? 1 : workspace.count + 1))
        return (relative, hash, (candidate.tool == "Edit" ? "Edited " : "Wrote ") + relative)
    }

    /// 우리 자식에게 SIGINT (정체 확인 뒤). 그래도 끝나지 않으면 유예 뒤 고아 끝내기
    func sendInterrupt(_ spawn: Spawn) {
        guard !spawn.exited, let identity = spawn.identity, !spawn.interruptSent else { return }
        spawn.interruptSent = true
        ClaudeProcessInspector.interrupt(identity)
        let grace = timing.orphanInterruptGrace + timing.exitAfterResult
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(grace))
            await self?.escalate(spawn, identity: identity)
        }
    }

    /// SIGINT 뒤에도 살아 있으면 고아 끝내기 (신호마다 정체 재확인)
    private func escalate(_ spawn: Spawn, identity: AgentProcessIdentity) async {
        guard !spawn.exited else { return }
        _ = await terminate(identity)
    }

    private func finish(_ spawn: Spawn, status: ClaudeExitStatus) async {
        spawn.resultTimer?.cancel()
        spawn.exited = true
        let actions = spawn.mapper.finish()
        // 이 spawn을 감독 목록에서 뺀 뒤에 닫기를 띄운다 (같은 세션의 다음 spawn이 이 spawn을 기다리지 않게)
        spawns[spawn.id] = nil
        if sessionSpawn[spawn.agentSessionID] == spawn.id { sessionSpawn[spawn.agentSessionID] = nil }
        if taskSpawn[spawn.taskID] == spawn.id { taskSpawn[spawn.taskID] = nil }
        ClaudeCodeLaunch.removeConfig(spawn.files)
        hookServer?.unregister(nonce: spawn.nonce)
        if spawn.answerSignal == nil { spawn.answerSignal = .ended }
        await apply(spawn, actions)
        if let id = spawn.unexpectedDeferred, let executable = locator.locate() {
            // 기록에 없는 id가 보고됐다: 그 id를 바로 닫는다 (질문을 내지 않는다)
            try? await close(requestID: id, providerID: spawn.providerID, agentSessionID: spawn.agentSessionID, taskID: spawn.taskID, workspace: spawn.workspace, executable: executable)
        }
        spawn.ended = true
        log.log("claude_ended", ["mode": .code(spawn.modeName), "code": .count(Int(status.code ?? -1)), "signal": .count(Int(status.signal ?? 0))])
        await spawn.sink?.emit(.ended(status.agentExit))
    }

    // MARK: writer 하나

    /// 같은 세션의 앞 spawn이 끝나기를 기다린다. 넘으면 고아 끝내기
    private func waitForSessionIdle(_ sessionID: String) async {
        guard let spawnID = sessionSpawn[sessionID], let spawn = spawns[spawnID] else { return }
        if await waitForEnd(spawn, timeout: timing.closeTimeout) { return }
        if let identity = spawn.identity { _ = await terminate(identity) }
        _ = await waitForEnd(spawn, timeout: timing.orphanKillGrace + 1)
    }

    private func waitForEnd(_ spawn: Spawn, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !spawn.ended, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return spawn.ended
    }

    // MARK: spawn 한 번의 상태 (이 actor 안에서만 바꾼다)

    final class Spawn: @unchecked Sendable {
        enum AnswerSignal: Equatable {
            case delivered(Date)
            case lost
            case ended
        }

        let id: String
        let nonce: String
        let mode: ClaudeMapperConfig.Mode
        let providerID: String
        let agentSessionID: String
        let taskID: String
        let turnSeq: Int
        let access: AgentAccess
        let workspace: String
        let folder: ClaudeSessionFolder
        let cwdReal: String
        let childPATH: String
        let files: ClaudeCodeLaunch.ConfigFiles
        let sink: AgentEventSink?
        let startedAt = Date()
        /// 소켓 서버가 답을 쓰기 직전에 넣는다 (④). 감독 스레드와 나눠 쓴다
        let answered = IDSet()
        let readerStop = Flag()
        var mapper: ClaudeEventMapper
        var facts = ClaudeSpawnFacts()
        var binding: ClaudeAnswerBinding?
        var deferIssued = false
        var answerDelivered = false
        var answerSignal: AnswerSignal?
        var hookTail: Task<Void, Never>?
        var process: ClaudeSpawnedProcess?
        var identity: AgentProcessIdentity?
        var exited = false
        var ended = false
        var interruptSent = false
        var unexpectedDeferred: String?
        var resultTimer: Task<Void, Never>?

        init(
            id: String, nonce: String, mode: ClaudeMapperConfig.Mode, providerID: String, agentSessionID: String, taskID: String, turnSeq: Int, access: AgentAccess,
            workspace: String, folder: ClaudeSessionFolder, cwdReal: String, childPATH: String, files: ClaudeCodeLaunch.ConfigFiles, sink: AgentEventSink?, mapper: ClaudeEventMapper
        ) {
            self.id = id
            self.nonce = nonce
            self.mode = mode
            self.providerID = providerID
            self.agentSessionID = agentSessionID
            self.taskID = taskID
            self.turnSeq = turnSeq
            self.access = access
            self.workspace = workspace
            self.folder = folder
            self.cwdReal = cwdReal
            self.childPATH = childPATH
            self.files = files
            self.sink = sink
            self.mapper = mapper
        }

        var modeName: String {
            switch mode {
            case .turn: "turn"
            case .answer: "answer"
            case .close: "close"
            }
        }

        func snapshot() -> ClaudeSpawnFacts {
            var copy = facts
            copy.answered = answered.values
            return copy
        }
    }

    /// 여러 스레드가 같이 쓰는 참거짓 하나
    final class Flag: Sendable {
        private let value = Mutex(false)

        func set() { value.withLock { $0 = true } }
        var isSet: Bool { value.withLock { $0 } }
    }

    /// 여러 스레드가 같이 쓰는 id 집합
    final class IDSet: Sendable {
        private let storage = Mutex<Set<String>>([])

        func insert(_ id: String) { storage.withLock { _ = $0.insert(id) } }
        var values: Set<String> { storage.withLock { $0 } }
    }
}
#endif
