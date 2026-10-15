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
// - **글 사본 0:** 사용자 메시지 · 답 · 비밀값 · 도구 입력 · 출력 · stream 원문을 세션 폴더 · 원장 · 로그에 쓰지 않는다. 세션 폴더에는 설정 두 파일(spawn 동안)과 상태 파일만. `lineage/`에는 spawn 혈통의 커널 id 숫자만 (자손 끝을 증명할 때까지).
// - **writer 하나:** 같은 세션의 앞 프로세스가 끝난 뒤에만 다음 프로세스를 띄운다 (닫기 · 답 resume 포함).
// - **init은 부수 효과 0:** probe · 폴더 만들기 · 소켓 없음. 런타임이 부를 때만 한다.

/// 시험 전용 끼어들기 (Release에는 없다)
public struct ClaudeCodeTestHooks: Sendable {
    /// 설정 파일을 쓴 직후 (① 변조 시험, E8)
    public var afterConfigWrite: (@Sendable (URL) -> Void)?
    /// 결정기 앞에서 기다린다 (훅 예산 시험, E17)
    public var gateDelay: Duration?
    /// 고아 끝내기의 결과를 바꾼다 (끝을 증명하지 못한 경우 시험, 8장 15)
    public var terminateOverride: (@Sendable (AgentProcessIdentity) -> AgentLiveness?)?
    /// 끝나는 spawn이 자기 요청을 닫기 모드로 닫기 바로 전 (그 사이 다른 턴이 끼어드는 경쟁 시험, 9장 10)
    public var beforeFinishClose: (@Sendable () async -> Void)?
    /// 훅 결정이 끝나고 응답을 확정하기 바로 전 (마지막 await 경쟁 시험, 11장 6)
    public var beforeHookReturn: (@Sendable () async -> Void)?

    public init(
        afterConfigWrite: (@Sendable (URL) -> Void)? = nil, gateDelay: Duration? = nil, terminateOverride: (@Sendable (AgentProcessIdentity) -> AgentLiveness?)? = nil,
        beforeFinishClose: (@Sendable () async -> Void)? = nil, beforeHookReturn: (@Sendable () async -> Void)? = nil
    ) {
        self.afterConfigWrite = afterConfigWrite
        self.gateDelay = gateDelay
        self.terminateOverride = terminateOverride
        self.beforeFinishClose = beforeFinishClose
        self.beforeHookReturn = beforeHookReturn
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
    /// Edit/Write가 바꾸면 안 되는 앱 데이터 폴더 (`sessionsRoot`는 늘 포함, 10장 5)
    nonisolated let protectedRoots: [URL]

    private var spawns: [String: Spawn] = [:]
    private var sessionSpawn: [String: String] = [:]
    private var taskSpawn: [String: String] = [:]
    /// 세션마다 지금 열린 입력 질문의 비밀 항목 (메모리만, 8장 11)
    private var secretItems: [String: (requestID: String, ids: Set<String>, single: Bool)] = [:]
    /// agent 세션마다 건넨 비밀값의 가리개 (메모리만, 9장 1): 그 세션의 모든 spawn(턴 · 답 · 닫기)과 결정표에 쓴다. 값은 쌓이고,
    /// 세션을 잊을 때(`forgetSession`) · 이 adapter가 사라질 때(계정 삭제 · 앱 종료) 지워진다. 디스크 · 로그 0
    private var sessionRedactors: [String: SecretRedactor] = [:]

    /// 그 세션의 비밀값 · 비밀 항목을 메모리에서 지운다 (세션 삭제 · 닫기 완료 때 부른다, 9장 1)
    public func forgetSession(_ sessionID: String) {
        sessionRedactors[sessionID] = nil
        secretItems[sessionID] = nil
    }

    func redactor(_ sessionID: String) -> SecretRedactor {
        sessionRedactors[sessionID] ?? SecretRedactor()
    }

    /// spawn 혈통 파일 (9장 4 정정): `<sessionsRoot>/lineage/<spawn id>.lineage`. 이름은 spawn id(UUID)뿐이다
    nonisolated func lineageFile(_ marker: String) -> URL? {
        guard UUID(uuidString: marker) != nil else { return nil }
        return sessionsRoot.appending(path: "lineage", directoryHint: .isDirectory).appending(path: "\(marker).lineage")
    }

    /// - `sessionsRoot`: `<원장 파티션 폴더>/claude-code` (계정 삭제는 파티션째 지운다)
    /// - `hookServer`: 앱 전체 소켓 (bridge가 꺼져 있으면 nil: 새 턴 · 답은 `spawn_failed`, 닫기는 소켓 없이 — 훅이 모두 deny)
    /// - `protectedRoots`: 앱 Application Support 등 Edit/Write를 막을 앱 데이터 폴더 (`sessionsRoot`는 늘 막는다)
    public init(
        sessionsRoot: URL, hookServer: HookSocketServer?, helpers: ClaudeCodeHelpers, locator: ClaudeCodeLocator,
        environment: [String: String] = ProcessInfo.processInfo.environment, managedSettingsPath: String = ClaudeCodeProbe.managedSettingsPath,
        fileSystem: GateFileSystem = .live, timing: ClaudeCodeTiming = .standard, log: any BridgeLogSink = NoBridgeLog(), runner: ClaudeCommandRunner? = nil,
        testHooks: ClaudeCodeTestHooks = ClaudeCodeTestHooks(), protectedRoots: [URL] = []
    ) {
        self.sessionsRoot = sessionsRoot
        self.protectedRoots = [sessionsRoot] + protectedRoots
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
        try await waitForSessionIdle(turn.sessionID)
        let folder = try ClaudeSessionFolder.prepare(sessionsRoot: sessionsRoot, agentSessionID: turn.sessionID)
        var state = ClaudeSessionState.load(from: folder.root)
        let providerID: String
        let session: ClaudeCodeLaunch.SessionArgument
        var newSession: String?
        if let external = turn.externalSessionID {
            guard BridgeRuntime.isSafeSessionID(external) else { throw AgentStartError(.spawnFailed) }
            try Self.requireBound(external, state: state)
            try requireSecretContext(state, sessionID: turn.sessionID, taskID: turn.taskID)
            providerID = external
            session = .resume(external)
        } else {
            // 새 세션: id를 만들어 적는다. init이 같은 id를 돌려주면 `session_bound` (Q15). 묶이지 않은 id는 다음 턴에 버린다
            providerID = UUID().uuidString.lowercased()
            session = .new(providerID)
            newSession = providerID
            state.providerSessionID = providerID
            state.bound = false
            state.secretAnswered = false
        }
        // 이 세션에서 다른 프로세스가 돈다: 앞의 보류는 더는 열려 있지 않다 (13.2 :511)
        state.openDeferred = nil
        try? state.save(in: folder.root)
        secretItems[turn.sessionID] = nil
        let spawn = try launch(
            mode: .turn(newSessionID: newSession), session: session, providerID: providerID, agentSessionID: turn.sessionID, taskID: turn.taskID, turnSeq: turn.turnSeq,
            access: turn.access, workspace: workspace, folder: folder, executable: executable, sink: events, stdin: Data(turn.text.utf8)
        )
        guard let identity = spawn.identity else { throw AgentStartError(.spawnFailed) }
        return identity
    }

    /// `--resume`에는 이 세션 폴더 상태가 묶은 id(init이 돌려준 id)만 쓴다 (8장 10). 다른 값은 서버가 줘도 띄우지 않는다
    static func requireBound(_ external: String, state: ClaudeSessionState) throws {
        guard state.bound, state.providerSessionID == external else { throw AgentStartError(.spawnFailed) }
    }

    /// 이 Claude 세션에 비밀값을 건넨 적이 있는데 이 adapter의 가리개가 비었다(앱이 다시 떴다): 모델이 되말해도 가릴 수 없으므로 그 세션은 이어 띄우지 않는다
    /// (11장 9, fail-closed. 값은 디스크에 두지 않는다 — 사용자 결정 Q9). 사용자는 새 세션으로 (이유 표시는 D4a)
    private func requireSecretContext(_ state: ClaudeSessionState, sessionID: String, taskID: String) throws {
        guard state.secretAnswered, redactor(sessionID).isEmpty else { return }
        log.log("claude_secret_context_lost", ["task": .id(taskID)])
        throw AgentStartError(.spawnFailed)
    }

    /// 이 답에서 비밀 항목의 값 (8장 11 · 10장 7): 질문을 낸 spawn이 메모리에 적은 항목과 상태 파일의 비밀 항목 id(앱이 다시 떠도 남는다).
    /// 이 Mac에서 답한 값(`answeredLocally`)인데 어느 항목이 비밀인지 모르면 답 값 전부를 비밀로 본다
    private func secretValues(_ answer: AgentAnswerDelivery, open: ClaudeSessionState.OpenDeferred) -> [String] {
        var ids = Set(open.secretItemIDs)
        var single = open.singleItem
        if let marked = secretItems[answer.sessionID], marked.requestID == answer.requestID {
            ids.formUnion(marked.ids)
            single = single || marked.single
        }
        var values: [String] = []
        for (id, value) in answer.value.answers ?? [:] where ids.contains(id) || (answer.answeredLocally && ids.isEmpty) {
            switch value {
            case .one(let text): values.append(text)
            case .many(let texts): values += texts
            }
        }
        if let text = answer.value.text, (single && !ids.isEmpty) || (answer.answeredLocally && ids.isEmpty) { values.append(text) }
        return values
    }

    // MARK: 답 (계약 2.10-3)

    public func deliverAnswer(_ answer: AgentAnswerDelivery, events: AgentEventSink) async throws -> AgentAnswerResult {
        guard let workspace = answer.workspaceRef.flatMap(workspaceRealPath) else { throw AgentStartError(.spawnFailed) }
        guard let external = answer.externalSessionID, BridgeRuntime.isSafeSessionID(external) else { return .requestClosed }
        guard hookServer != nil, let executable = locator.locate() else { throw AgentStartError(.spawnFailed) }
        try await waitForSessionIdle(answer.sessionID)
        let folder = try ClaudeSessionFolder.prepare(sessionsRoot: sessionsRoot, agentSessionID: answer.sessionID)
        var state = ClaudeSessionState.load(from: folder.root)
        try Self.requireBound(external, state: state)
        // 열린 보류가 아니면 spawn 0 (ONE-TF-03, AC-37, G28)
        guard let open = state.openDeferred, open.id == answer.requestID, open.kind == answer.kind.rawValue else {
            log.log("claude_answer_closed", ["task": .id(answer.taskID)])
            return .requestClosed
        }
        try requireSecretContext(state, sessionID: answer.sessionID, taskID: answer.taskID)
        // 비밀 항목의 답 값을 이 세션의 가리개에 쌓는다 (9장 1: 이 세션의 다음 spawn에도 쓴다. 10장 7: 앱이 다시 떠도 상태 파일의 항목 id로).
        // 비밀값을 건넨다는 표식(값 0)은 띄우기 전에 상태 파일에 적는다: 적지 못하면 건네지 않는다 (11장 9)
        let values = secretValues(answer, open: open)
        state.openDeferred = nil
        if !values.isEmpty {
            state.secretAnswered = true
            do {
                try state.save(in: folder.root)
            } catch {
                log.log("claude_state_save_failed", [:])
                throw AgentStartError(.spawnFailed)
            }
        } else {
            try? state.save(in: folder.root)
        }
        if !values.isEmpty { sessionRedactors[answer.sessionID] = redactor(answer.sessionID).adding(values) }
        secretItems[answer.sessionID] = nil
        let binding = ClaudeAnswerBinding(requestID: answer.requestID, kind: answer.kind, inputSHA256: open.inputSHA256, value: answer.value, targetSHA256: open.targetSHA256)
        let spawn = try launch(
            mode: .answer(requestID: answer.requestID), binding: binding, session: .resume(external), providerID: external, agentSessionID: answer.sessionID,
            taskID: answer.taskID, turnSeq: answer.turnSeq, access: answer.access, workspace: workspace, folder: folder, executable: executable, sink: events, stdin: Data()
        )
        // 새 프로세스의 정체가 원장에 commit돼야 답을 준다 (8장 14 · 9장 8): 그 전의 답 훅은 기다린다. 실패하면 답을 주지 않고 그 프로세스를 끝낸다.
        // 끝이 증명될 때까지 이 spawn이 등록부에 남아 같은 세션의 다음 실행을 막는다
        var recorded = false
        if let identity = spawn.identity, let services = services.withLock({ $0 }) { recorded = await services.recordSpawn(answer.taskID, identity) }
        spawn.identityRecorded = recorded
        guard recorded else {
            log.log("claude_identity_unrecorded", ["task": .id(answer.taskID)])
            if spawn.answerSignal == nil { spawn.answerSignal = .lost }
            sendInterrupt(spawn)
            throw AgentStartError(.agentError)
        }
        // 보류 id의 훅이 오면 그 순간 전달이다. 그 전에 init이나 다른 호출이 오면(상태 유실) 멈추고 닫힘, 그 전에 끝나면 던진다. 기다림에는 시간 제한이 있다 (9장 9)
        let deadline = Date().addingTimeInterval(timing.answerTimeout)
        var signal = spawn.answerSignal
        while signal == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
            signal = spawn.answerSignal
        }
        if signal == nil {
            log.log("claude_answer_timeout", ["task": .id(answer.taskID)])
            spawn.answerSignal = .lost
            sendInterrupt(spawn)
            signal = .lost
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
        try await waitForSessionIdle(request.sessionID)
        let folder = try ClaudeSessionFolder.prepare(sessionsRoot: sessionsRoot, agentSessionID: request.sessionID)
        try Self.requireBound(external, state: ClaudeSessionState.load(from: folder.root))
        secretItems[request.sessionID] = nil
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
        // 끝날 때까지 기다린다 (다음 startTurn이 두 번째 writer를 만들지 않게). 10초 안에 끝나지 않으면 고아 끝내기.
        // 끝을 증명하지 못하면 던진다 (8장 15): 호출한 쪽은 이 세션의 다음 실행을 띄우지 않는다
        if await waitForEnd(spawn, timeout: timing.closeTimeout) { return }
        if let identity = spawn.identity { _ = await terminate(identity, lineage: spawn.lineage) }
        if await waitForEnd(spawn, timeout: timing.orphanKillGrace + 1) { return }
        log.log("claude_writer_unproven", ["mode": .code("close")])
        throw AgentStartError(.agentError)
    }

    // MARK: 중단 · 고아 (계약 2.13 · 2.14)

    /// 감독 중인 실행이면 SIGINT를 보내고 유예 뒤 정체를 다시 보고 자손까지 SIGKILL로 올린다 (9장 6). 끝은 감독이 `ended`로 알린다(`signalled`).
    /// 등록부에 없으면(앱이 다시 떴다) 원장의 정체로 확인해 끝까지 끝낸다: 끝났음이 증명될 때만 `notRunning`, 확인할 수 없거나 끝내지 못했으면 `signalled` (8장 12)
    public func interrupt(_ target: AgentTurnRef, scope: AgentCancelScope) async -> AgentInterruptResult {
        if let spawnID = taskSpawn[target.taskID], let spawn = spawns[spawnID] {
            spawn.mapper.markInterruptRequested()
            spawn.stopped = true
            if !spawn.exited, spawn.identity != nil, !spawn.interruptSent {
                sendInterrupt(spawn)
                log.log("claude_interrupt", ["task": .id(target.taskID)])
            }
            return .signalled
        }
        guard let identity = target.identity else { return .signalled }
        switch await terminate(identity) {
        case .ended:
            log.log("claude_interrupt", ["task": .id(target.taskID), "orphan": .count(1)])
            return .notRunning
        case .alive, .unknown:
            log.log("claude_interrupt_unproven", ["task": .id(target.taskID)])
            return .signalled
        }
    }

    /// 감독 중인 spawn이면 그 혈통으로, 아니면(앱이 다시 떴다) 적어 둔 혈통 파일로 자손까지 본다 (9장 4 정정). 감독 밖에서 끝을 증명하면 그 파일을 지운다 (10장 4)
    public func liveness(_ identity: AgentProcessIdentity) async -> AgentLiveness {
        if let lineage = spawns[identity.processMarker]?.lineage { return ClaudeProcessInspector.liveness(identity, lineage: lineage) }
        let lineage = ClaudeLineage(file: lineageFile(identity.processMarker))
        let result = ClaudeProcessInspector.liveness(identity, lineage: lineage)
        if case .ended = result { lineage.forget() }
        return result
    }

    /// 앱이 뜰 때 부른다: 다른 부팅에 적힌 혈통 파일을 이번 부팅의 끝 기록으로 바꾼다 (10장 4 · 11장 1, 결정 11-1). 이번 부팅의 파일은 고아 정리가 쓰고 끝을 증명하면 끝 기록이 된다
    public nonisolated func purgeLineageOfOtherBoots() {
        ClaudeLineage.purge(directory: sessionsRoot.appending(path: "lineage", directoryHint: .isDirectory))
    }

    public func terminateOrphan(_ identity: AgentProcessIdentity) async -> AgentLiveness {
        await terminate(identity, lineage: spawns[identity.processMarker]?.lineage)
    }

    /// `lineage`가 없으면(감독 밖) 혈통 파일 + 지금 부모에서 시작하고, 끝을 증명하면 그 파일을 지운다. 감독 중인 spawn의 혈통은 `finish`가 지운다
    nonisolated func terminate(_ identity: AgentProcessIdentity, lineage: ClaudeLineage? = nil) async -> AgentLiveness {
        if let override = testHooks.terminateOverride?(identity) { return override }
        let timing = self.timing
        let file = lineageFile(identity.processMarker)
        return await offActor {
            let known = lineage ?? ClaudeLineage.seeded(identity, file: file)
            let result = ClaudeProcessInspector.terminate(identity, timing: timing, lineage: known)
            if lineage == nil, case .ended = result { known.forget() }
            return result
        }
    }

    /// 막히는 일(신호 뒤 기다림 · 파일 해시)을 협력 스레드 밖에서
    nonisolated func offActor<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
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
        // ①: 쓴 파일을 다시 읽어 기대 값과 같고, 격리 `cwd/`가 비어 있을 때만 띄운다 (11장 10: 누가 project 설정을 심어 두지 않았다)
        guard ClaudeCodeLaunch.verifyConfig(files, settings: settings, mcp: mcp), (try? FileManager.default.contentsOfDirectory(atPath: folder.cwd.path))?.isEmpty == true else {
            ClaudeCodeLaunch.removeConfig(files)
            log.log("claude_selfcheck_failed", ["check": .count(1)])
            throw AgentStartError(.spawnFailed)
        }
        let cwdReal = GateFileSystem.realpath(folder.cwd.path) ?? folder.cwd.path
        // 환경 넷 + spawn marker (9장 4): 자손이 물려받아 세션을 떠난 Bash 자손도 끝낼 때 찾는다
        var environment = ClaudeCodeEnvironment.child(app: self.environment, executable: executable)
        environment[ClaudeProcessInspector.markerKey] = spawnID
        let mapper = ClaudeEventMapper(config: ClaudeMapperConfig(
            mode: mode, expectedSessionID: providerID, expectedTools: ClaudeCodeSupport.initTools(for: access), expectedCwd: cwdReal, requireSessionStart: true,
            workspaceRealPath: workspace, versionSupported: { ClaudeCodeSupport.supports($0) }
        ))
        let spawn = Spawn(
            id: spawnID, nonce: nonce, mode: mode, providerID: providerID, agentSessionID: agentSessionID, taskID: taskID, turnSeq: turnSeq, access: access, workspace: workspace,
            folder: folder, cwdReal: cwdReal, childPATH: environment["PATH"] ?? "", files: files, sink: sink, mapper: mapper,
            lineage: ClaudeLineage(file: lineageFile(spawnID), fresh: true)
        )
        spawn.binding = binding
        let answered = spawn.answered
        hookServer?.register(nonce: nonce, HookSocketServer.Registration(agentSessionID: agentSessionID, providerSessionID: providerID, handler: { [weak self] request in
            await self?.handleHook(spawnID: spawnID, request) ?? HookResponse(decision: .deny, reason: ClaudeGateReason.turnStopped)
        }, onAnswer: { id in answered.insert(id) }))
        let arguments = ClaudeCodeLaunch.arguments(access: access, workspace: workspace, settings: files.settings.path, mcp: files.mcp.path, session: session)
        let process: ClaudeSpawnedProcess
        do {
            // 검사한 실제 파일(realpath)로 띄운다. 자식이 보는 argv[0]은 후보 경로 그대로 (8장 8)
            process = try ClaudeSpawner.spawn(executable: executable.realPath, argv0: executable.path, arguments: arguments, environment: environment, cwd: folder.cwd.path)
        } catch {
            hookServer?.unregister(nonce: nonce, after: .zero)
            ClaudeCodeLaunch.removeConfig(files)
            throw AgentStartError(.spawnFailed)
        }
        spawn.process = process
        // 혈통의 뿌리 (9장 4 정정): 거두기 전이라 그 pid는 우리 자식이다. 부팅 id · 뿌리 id를 바로 파일에 적는다 (10장 1 · 3). 지켜보기는 끝을 증명한 `finish`까지
        spawn.lineage.seed(process.pid)
        spawn.lineage.save(force: true)
        // 혈통 파일을 적지 못했으면 이 spawn의 끝을 나중에 증명할 수 없다: 정체를 적기 전에 멈추고 띄우지 않은 것으로 한다 (11장 2)
        guard spawn.lineage.isRecorded else {
            kill(process.pid, SIGKILL)
            _ = process.waitForExit()
            process.closeStandardStreams()
            hookServer?.unregister(nonce: nonce, after: .zero)
            ClaudeCodeLaunch.removeConfig(files)
            log.log("claude_lineage_unrecorded", [:])
            throw AgentStartError(.spawnFailed)
        }
        let identity = AgentProcessIdentity(pid: Int(process.pid), startedAt: process.startedAt, processMarker: spawnID, externalTaskID: "\(providerID):\(turnSeq)")
        spawn.identity = identity
        spawn.lineage.watch(identity)
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

    /// 훅 요청 하나. 한 spawn의 훅은 하나씩 정한다 (defer 하나 · 답 한 번이 겹치지 않게): 앞 훅이 응답을 확정할 때까지 기다린다.
    /// 정한 뒤 돌려주기 직전(마지막 await 뒤)에 중단 상태와 응답 · 전달 기록을 한 번에 확정한다(`settle`, 11장 6): 그 사이에 await가 없어 Stop이 끼어들 틈이 없다
    func handleHook(spawnID: String, _ request: HookRequest) async -> HookResponse {
        guard let spawn = spawns[spawnID] else { return HookResponse(decision: .deny, reason: ClaudeGateReason.turnStopped) }
        let previous = spawn.hookTail
        let (turn, settled) = AsyncStream<Void>.makeStream()
        spawn.hookTail = Task { for await _ in turn {} }
        defer { settled.finish() }
        await previous?.value
        let started = Date()
        let decided = await decide(spawn: spawn, request)
        await testHooks.beforeHookReturn?()
        return settle(spawn, request, decided, started: started)
    }

    /// 돌려주기 직전의 확정 (11장 6, await 없음): 중단 · 자체 점검 실패가 보이면 answers 없는 deny(답 훅이면 값을 지우고 `.lost` → `requestClosed`),
    /// 아니면 그 결과대로 보류 · 전달(`.delivered` · 값 지우기)을 적는다
    private func settle(_ spawn: Spawn, _ request: HookRequest, _ decided: ClaudeGateOutcome, started: Date) -> HookResponse {
        let outcome = stopOverride(spawn, request, decided)
        if outcome.response.decision == .defer, let deferred = outcome.deferred {
            spawn.deferIssued = true
            spawn.facts.pending = deferred
        }
        if outcome.answeredPending {
            spawn.answerDelivered = true
            // 답(비밀값 포함)은 보류 id 훅에 한 번 주고 메모리에서도 지운다
            spawn.binding?.value = AgentAnswerValue()
            if spawn.answerSignal == nil { spawn.answerSignal = .delivered(Date()) }
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

    /// 중단 재확인 하나 (9장 7 · 10장 6 · 11장 6): 이 spawn에 Stop · 자체 점검 실패가 왔으면 allow · defer를 answers 없는 deny로 바꾼다.
    /// 답 훅이었으면 그 답은 모델에 닿지 않는다: 값은 메모리에서 지우고 `.lost`
    private func stopOverride(_ spawn: Spawn, _ request: HookRequest, _ outcome: ClaudeGateOutcome) -> ClaudeGateOutcome {
        guard spawn.stopped || spawn.interruptSent, outcome.response.decision != .deny else { return outcome }
        if case .answer = spawn.mode, request.toolUseID == spawn.binding?.requestID {
            spawn.binding?.value = AgentAnswerValue()
            if spawn.answerSignal == nil { spawn.answerSignal = .lost }
        }
        return ClaudeToolGate.local(.deny, ClaudeGateReason.turnStopped, "stopped_after_wait")
    }

    private func decide(spawn: Spawn, _ request: HookRequest) async -> ClaudeGateOutcome {
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
        // 답 훅은 새 정체가 원장에 commit된 뒤에만 답한다 (9장 8): 그 전이면 잠깐 기다리고(훅 예산 안), 실패 · 시간 초과면 답을 주지 않는다
        if case .answer = spawn.mode, request.toolUseID == spawn.binding?.requestID {
            let deadline = Date().addingTimeInterval(Self.identityWait)
            while spawn.identityRecorded == nil, Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
            if spawn.identityRecorded != true {
                if spawn.answerSignal == nil { spawn.answerSignal = .lost }
                sendInterrupt(spawn)
                return ClaudeToolGate.local(.deny, ClaudeGateReason.turnStopped, "identity_unrecorded")
            }
        }
        let context = ClaudeGateContext(
            mode: gateMode, access: spawn.access, workspaceRealPath: spawn.workspace, sessionCwdRealPath: spawn.cwdReal, childPATH: spawn.childPATH,
            agentSessionID: spawn.agentSessionID, agentTaskID: spawn.taskID, turnSeq: spawn.turnSeq, deferIssued: spawn.deferIssued, answerDelivered: spawn.answerDelivered,
            stopped: spawn.stopped || spawn.interruptSent, secrets: redactor(spawn.agentSessionID),
            protectedRealPaths: protectedRoots.map { GateFileSystem.realpath($0.path) ?? $0.path }
        )
        if let delay = testHooks.gateDelay { try? await Task.sleep(for: delay) }
        let gate = ClaudeToolGate(fileSystem: fileSystem, decide: services.withLock { $0 }?.decideTool, serverTimeout: .milliseconds(Int(timing.serverTimeout * 1000)))
        // 서버를 기다리는 동안 Stop · 자체 점검 실패가 왔으면 그 결과를 쓰지 않는다 (9장 7): 진행 사건도 내지 않는다. 기록은 `settle`이 한다
        let evaluated = await gate.evaluate(request, context: context)
        let outcome = stopOverride(spawn, request, evaluated)
        if outcome.answeredPending { await spawn.sink?.emit(.progress) }
        return outcome
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
    /// 답 훅이 새 정체 기록을 기다리는 최대 시간 (훅 예산 1.2초 안, 9장 8)
    static let identityWait: TimeInterval = 0.8

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
                    // 거둔 직후 답 기다림을 끝낸다 (9장 9): 자손 정리를 기다리지 않는다. 세션 자리는 정리가 끝날 때까지 잡혀 있다
                    if spawn.answerSignal == nil { spawn.answerSignal = .ended }
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
                // 건넨 비밀값을 모델이 되말해도 밖으로 나가는 글에서는 가린다 (8장 11 · 9장 1: 그 세션의 가리개)
                await spawn.sink?.emit(redactor(spawn.agentSessionID).redact(event))
            case .interrupt(let cause):
                switch cause {
                case .selfCheck(let check): log.log("claude_selfcheck_failed", ["check": .count(check)])
                case .answerLost: if spawn.answerSignal == nil { spawn.answerSignal = .lost }
                case .closeDone: break
                }
                // 멈추기로 한 spawn의 훅은 모두 deny (8장 9)
                spawn.stopped = true
                sendInterrupt(spawn)
            case .confirmQuestion(let pending):
                // 보고된 보류만 열린 요청이다: id · 종류 · digest · 대상 지문만 적는다 (글 · 경로 0)
                var state = ClaudeSessionState.load(from: spawn.folder.root)
                let secret = pending.kind == .input ? pending.question.items.filter(\.secret).map(\.id) : []
                let single = pending.question.items.count == 1
                // 비밀 항목은 id만 상태 파일에 (10장 7: 앱이 다시 떠도 그 답 값을 가린다. 값은 쓰지 않는다)
                state.openDeferred = ClaudeSessionState.OpenDeferred(
                    id: pending.id, kind: pending.kind.rawValue, inputSHA256: pending.inputSHA256, spawnID: spawn.id, at: Date(), targetSHA256: pending.targetSHA256,
                    secretItemIDs: secret, singleItem: single
                )
                do {
                    try state.save(in: spawn.folder.root)
                    if !secret.isEmpty { secretItems[spawn.agentSessionID] = (pending.id, Set(secret), single) }
                } catch {
                    // 열린 요청으로 적지 못했다 (8장 17): 답할 수 없는 질문은 내지 않는다. 그 호출은 끝난 뒤 닫기 모드로 거절하고 실패로 알린다
                    log.log("claude_state_save_failed", [:])
                    spawn.mapper.dropConfirmedQuestion()
                    spawn.unexpectedDeferred = pending.id
                    await spawn.sink?.emit(.failed(.agentError))
                }
            case .unexpectedDeferred(let id):
                spawn.unexpectedDeferred = id
                log.log("claude_unexpected_deferred", [:])
            case .artifacts(let candidates):
                // 파일 해시는 actor 밖에서 (일반 파일 · 크기 상한, 8장 18)
                let workspace = spawn.workspace
                for candidate in candidates {
                    if let artifact = await offActor({ self.artifact(candidate, workspace: workspace) }) {
                        await spawn.sink?.emit(redactor(spawn.agentSessionID).redact(.artifact(path: artifact.path, hash: artifact.hash, summary: artifact.summary)))
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
              let hash = Self.artifactHash(atPath: real, limit: Self.artifactHashLimit) else { return nil }
        let relative = String(real.dropFirst(workspace == "/" ? 1 : workspace.count + 1))
        return (relative, hash, (candidate.tool == "Edit" ? "Edited " : "Wrote ") + relative)
    }

    /// 산출물 해시를 내는 파일 크기 상한
    static let artifactHashLimit: Int64 = 64 * 1024 * 1024

    /// `sha256:<hex>`. 일반 파일이고 `limit` 바이트 이하일 때만 (FIFO · 장치 · 폴더는 열어도 읽지 않는다: 막히지 않게 `O_NONBLOCK`으로 연다). 읽지 못하면 nil
    nonisolated static func artifactHash(atPath path: String, limit: Int64) -> String? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, Int64(info.st_size) <= limit else { return nil }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var total: Int64 = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { return nil }
            if count == 0 { break }
            total += Int64(count)
            // 읽는 사이 커진 파일도 상한을 넘기지 않는다
            guard total <= limit else { return nil }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<count])) }
        }
        return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 우리 자식에게 SIGINT (정체 확인 뒤). 그래도 끝나지 않으면 유예 뒤 고아 끝내기
    func sendInterrupt(_ spawn: Spawn) {
        spawn.stopped = true
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
        _ = await terminate(identity, lineage: spawn.lineage)
    }

    private func finish(_ spawn: Spawn, status: ClaudeExitStatus) async {
        spawn.resultTimer?.cancel()
        spawn.exited = true
        if spawn.answerSignal == nil { spawn.answerSignal = .ended }
        // 자손(혈통 · 그룹 · spawn marker)까지 끝나야 끝이다 (8장 13 · 9장 4). 끝을 증명할 때까지 다시 시도한다: 그동안 이 세션의 다음 writer는 기다린다
        if let identity = spawn.identity {
            let timing = self.timing
            let lineage = spawn.lineage
            var attempt = 0
            while await !offActor({ ClaudeProcessInspector.endDescendants(identity, lineage: lineage, timing: timing) }) {
                if attempt == 0 { log.log("claude_group_lingering", ["mode": .code(spawn.modeName)]) }
                attempt += 1
                try? await Task.sleep(for: .seconds(min(5, attempt)))
            }
            lineage.forget()
        }
        let actions = spawn.mapper.finish()
        ClaudeCodeLaunch.removeConfig(spawn.files)
        hookServer?.unregister(nonce: spawn.nonce)
        await apply(spawn, actions)
        if let id = spawn.unexpectedDeferred, let executable = locator.locate() {
            // 기록에 없는 id가 보고됐거나 열린 요청으로 적지 못했다: 그 id를 바로 닫는다 (질문을 내지 않는다)
            await testHooks.beforeFinishClose?()
            do {
                try await close(requestID: id, providerID: spawn.providerID, agentSessionID: spawn.agentSessionID, taskID: spawn.taskID, workspace: spawn.workspace, executable: executable)
            } catch {
                log.log("claude_close_failed", [:])
            }
        }
        // 세션 자리는 자기 닫기까지 마친 뒤에 놓는다 (9장 10): 그 전에는 같은 세션의 다음 실행이 이 spawn을 기다린다
        spawns[spawn.id] = nil
        if sessionSpawn[spawn.agentSessionID] == spawn.id { sessionSpawn[spawn.agentSessionID] = nil }
        if taskSpawn[spawn.taskID] == spawn.id { taskSpawn[spawn.taskID] = nil }
        spawn.ended = true
        log.log("claude_ended", ["mode": .code(spawn.modeName), "code": .count(Int(status.code ?? -1)), "signal": .count(Int(status.signal ?? 0))])
        await spawn.sink?.emit(.ended(status.agentExit))
    }

    // MARK: writer 하나

    /// 같은 세션의 앞 spawn이 끝나기를 기다린다. 넘으면 고아 끝내기. 끝(자손까지)을 증명하지 못하면 던진다: 두 번째 writer를 만들지 않는다 (8장 15)
    private func waitForSessionIdle(_ sessionID: String) async throws {
        guard let spawnID = sessionSpawn[sessionID], let spawn = spawns[spawnID] else { return }
        if await waitForEnd(spawn, timeout: timing.closeTimeout) { return }
        if let identity = spawn.identity { _ = await terminate(identity, lineage: spawn.lineage) }
        if await waitForEnd(spawn, timeout: timing.orphanKillGrace + 1) { return }
        log.log("claude_writer_unproven", ["mode": .code(spawn.modeName)])
        throw AgentStartError(.spawnFailed)
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
        /// 이 spawn에서 나온 프로세스 (9장 4 정정)
        let lineage: ClaudeLineage
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
        /// 중단 · 자체 점검 실패 · 닫기 끝: 이 spawn의 훅은 모두 deny (8장 9)
        var stopped = false
        /// 답 resume: 새 정체의 원장 commit 결과 (nil = 아직). true일 때만 답 훅에 답한다 (9장 8)
        var identityRecorded: Bool?
        var unexpectedDeferred: String?
        var resultTimer: Task<Void, Never>?

        init(
            id: String, nonce: String, mode: ClaudeMapperConfig.Mode, providerID: String, agentSessionID: String, taskID: String, turnSeq: Int, access: AgentAccess,
            workspace: String, folder: ClaudeSessionFolder, cwdReal: String, childPATH: String, files: ClaudeCodeLaunch.ConfigFiles, sink: AgentEventSink?, mapper: ClaudeEventMapper,
            lineage: ClaudeLineage
        ) {
            self.lineage = lineage
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
