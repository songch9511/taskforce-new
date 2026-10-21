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
// - **글 사본 0:** 사용자 메시지 · 답 · 비밀값 · 도구 입력 · 출력 · stream 원문을 세션 폴더 · 원장 · 로그에 쓰지 않는다. 세션 폴더에는 설정 파일 셋(settings · mcp · 프롬프트, spawn 동안)과 상태 파일,
//   그리고 비지 않은 `cwd/`를 옮겨 둔 격리 폴더(승인된 도구가 남긴 것, 12장 13)만. `lineage/`에는 spawn 혈통의 커널 id · pid 숫자와 끝 기록만.
// - **writer 하나:** 같은 세션의 앞 프로세스가 끝난 뒤에만 다음 프로세스를 띄운다 (닫기 · 답 resume 포함).
// - **init은 부수 효과 0:** probe · 폴더 만들기 · 소켓 없음. 런타임이 부를 때만 한다.

/// `withDeadline`의 한 번만 깨우기: 일이 끝나거나 기한이 지나거나, 먼저 온 쪽만 이어 간다
private final class DeadlineOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func claim() -> Bool {
        lock.withLock {
            defer { fired = true }
            return !fired
        }
    }
}

/// 프로젝트 지침 읽기의 작업 폴더별 단일 비행 (검토): 한 작업 폴더에 읽기 일꾼은 하나다. 기한이 지나 건너뛴 읽기도 **일꾼이 실제로 돌아올 때까지** 읽는 중으로 남는다
/// (막힌 볼륨에서 일꾼 스레드가 턴마다 쌓이지 않게). 기한을 넘긴 읽기는 "막힘"으로 적어, 뒤따르는 읽기가 기다리지 않고 바로 건너뛴다
final class InstructionReads: @unchecked Sendable {
    private let lock = NSLock()
    private var reading: Set<String> = []
    private var stuck: Set<String> = []

    /// 읽기를 시작해도 되나 (이미 읽는 중이면 false)
    func begin(_ workspace: String) -> Bool {
        lock.withLock { reading.insert(workspace).inserted }
    }

    /// 일꾼이 돌아왔다
    func end(_ workspace: String) {
        lock.withLock {
            reading.remove(workspace)
            stuck.remove(workspace)
        }
    }

    func isReading(_ workspace: String) -> Bool { lock.withLock { reading.contains(workspace) } }

    /// 기한을 넘겼는데 일꾼이 아직 안 돌아왔다 (이미 돌아왔으면 적지 않는다: 영원히 막히지 않게)
    func markStuck(_ workspace: String) {
        lock.withLock { if reading.contains(workspace) { stuck.insert(workspace) } }
    }

    func isStuck(_ workspace: String) -> Bool { lock.withLock { stuck.contains(workspace) } }
}

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
    /// spawn의 stdin에 건네는 바이트 수 (시작 중에 멈춘 spawn은 0, 17장 1)
    public var inputBytes: (@Sendable (Int) -> Void)?
    /// 끝나는 spawn이 등록부에서 내려온 직후 · 남은 출력을 내기 전 (출력 정산 중 `forgetSession`이 가리개를 지우지 않는지 보는 경쟁 시험, 검토 1)
    public var afterUnregister: (@Sendable () async -> Void)?
    /// 프로젝트 지침(CLAUDE.md)을 읽기 바로 전 (읽기가 느려도 한 세션에 writer가 둘 생기지 않고 비밀값 가리개가 지워지지 않는지 보는 경쟁 시험, 검토 P1)
    public var beforeInstructionsRead: (@Sendable () async -> Void)?
    /// 프로젝트 지침 표지에 쓰는 무작위 꼬리표를 정한다 (시험이 프롬프트 전문을 글자까지 대조하게. 없으면 spawn마다 무작위)
    public var instructionsTag: (@Sendable () -> String)?
    /// 프로젝트 지침 읽기를 바꾼다 (막힌 볼륨 · 늦은 읽기를 흉내 내 기한을 보는 시험)
    public var readInstructions: (@Sendable (String) -> ClaudeProjectInstructions.Outcome)?

    public init(
        afterConfigWrite: (@Sendable (URL) -> Void)? = nil, gateDelay: Duration? = nil, terminateOverride: (@Sendable (AgentProcessIdentity) -> AgentLiveness?)? = nil,
        beforeFinishClose: (@Sendable () async -> Void)? = nil, beforeHookReturn: (@Sendable () async -> Void)? = nil, inputBytes: (@Sendable (Int) -> Void)? = nil,
        afterUnregister: (@Sendable () async -> Void)? = nil, beforeInstructionsRead: (@Sendable () async -> Void)? = nil, instructionsTag: (@Sendable () -> String)? = nil,
        readInstructions: (@Sendable (String) -> ClaudeProjectInstructions.Outcome)? = nil
    ) {
        self.readInstructions = readInstructions
        self.beforeInstructionsRead = beforeInstructionsRead
        self.instructionsTag = instructionsTag
        self.afterConfigWrite = afterConfigWrite
        self.gateDelay = gateDelay
        self.terminateOverride = terminateOverride
        self.beforeFinishClose = beforeFinishClose
        self.beforeHookReturn = beforeHookReturn
        self.inputBytes = inputBytes
        self.afterUnregister = afterUnregister
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
    /// 프로젝트 지침 읽기의 작업 폴더별 단일 비행
    nonisolated let instructionReads = InstructionReads()
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
    /// 감독 밖 spawn의 혈통 객체 (12장 8): marker마다 하나를 확인 · 끝내기가 함께 쓴다 (감독 중이면 그 spawn의 것)
    private var lineages: [String: ClaudeLineage] = [:]
    /// 앱 종료 · 계정 삭제가 시작됐다 (16장 1): 그 뒤에는 어떤 spawn(턴 · 답 · 닫기 · 내부 닫기)도 띄우지 않는다
    private var spawningStopped = false
    /// 세션마다 끝나는 중인 spawn 수 (`finish`가 시작해 마지막 출력을 낼 때까지): 이 동안 `forgetSession`은 가리개를 지우지 않는다
    private var settling: [String: Int] = [:]
    /// `forgetSession`을 받았지만 spawn이 있거나 정산 중이라 미룬 세션
    private var forgetWhenSettled: Set<String> = []

    /// marker의 혈통 객체 하나: 감독 중이면 그 spawn의 것, 아니면 파일에서 한 번 읽어 둔 것
    func sharedLineage(_ marker: String) -> ClaudeLineage {
        if let lineage = spawns[marker]?.lineage { return lineage }
        if let lineage = lineages[marker] { return lineage }
        let lineage = ClaudeLineage(file: lineageFile(marker))
        lineages[marker] = lineage
        return lineage
    }

    /// 그 세션의 비밀값 · 비밀 항목을 메모리에서 지운다 (D4a2-08: 런타임이 폐기(revoke) 때, Settings가 Disconnect 성공 뒤에 부른다, 9장 1).
    /// 그 세션의 spawn이 아직 등록부에 있거나(돌고 있거나 끝을 증명하지 못했다) **끝난 spawn의 마지막 출력이 아직 정산 중이면**(`finish`가 등록부에서 내린 뒤 산출물 해시를 기다리며 글을 낸다)
    /// 가리개는 남긴다: 그 출력이 비밀값을 되말하면 가려야 한다 — 비밀 항목만 지운다. 잊기는 세션이 조용해지는 순간 이어서 한다 (`releaseForgetIfIdle`)
    public func forgetSession(_ sessionID: String) async {
        secretItems[sessionID] = nil
        forgetWhenSettled.insert(sessionID)
        if !releaseForgetIfIdle(sessionID) { log.log("claude_forget_deferred", [:]) }
    }

    /// 잊기를 기다리는 세션이 조용하면(등록부에 spawn 0 · 정산 중인 spawn 0) 가리개를 지운다. 지웠으면 true
    @discardableResult
    private func releaseForgetIfIdle(_ sessionID: String) -> Bool {
        guard forgetWhenSettled.contains(sessionID), settling[sessionID] == nil, registeredSpawns(sessionID).isEmpty else { return false }
        forgetWhenSettled.remove(sessionID)
        sessionRedactors[sessionID] = nil
        return true
    }

    private func beginSettling(_ sessionID: String) {
        settling[sessionID, default: 0] += 1
    }

    private func endSettling(_ sessionID: String) {
        if let count = settling[sessionID], count > 1 { settling[sessionID] = count - 1 } else { settling[sessionID] = nil }
        releaseForgetIfIdle(sessionID)
    }

    #if DEBUG
    /// 시험 전용 (Release에는 없다): 가리개를 직접 심는다 (`forgetSession`이 살아 있는 spawn이 있는 세션의 가리개를 남기는지 본다)
    func seedRedactorForTest(_ redactor: SecretRedactor, for sessionID: String) {
        sessionRedactors[sessionID] = redactor
    }
    #endif

    /// 터미널에서 이어받는 데 필요한 값 (D4a2-06): 이 세션 폴더 상태가 묶은 Claude 세션 id · 찾은 `claude`의 realpath · 이 세션을 띄운 `cwd/`의 realpath. 서버 `external_session_id`는 쓰지 않는다.
    /// Claude Code는 대화 기록을 cwd별로 두고 `--add-dir`도 이어받을 때 다시 줘야 하므로, 터미널은 adapter와 같은 세션 cwd에서 이어받는다 (`ClaudeSessionFolder.locate`: 띄우기와 같은 길).
    /// 세션 폴더를 만들지 않고 읽기만 한다. 묶이지 않았거나(첫 턴 전) · 실행 파일을 못 찾았거나 · id 모양이 틀리거나 · 세션 cwd가 없거나(잊었거나 지웠다) · 기호 링크이거나 · 내 폴더가 아니면 nil (열지 않는다)
    public func terminalSession(_ sessionID: String) async -> AgentTerminalSession? {
        guard let folder = ClaudeSessionFolder.locate(sessionsRoot: sessionsRoot, agentSessionID: sessionID), let executable = locator.locate() else { return nil }
        let state = ClaudeSessionState.load(from: folder.root)
        guard state.bound, let provider = state.providerSessionID, BridgeRuntime.isSafeSessionID(provider) else { return nil }
        // 띄울 때(`prepareCwd`)와 같이 `lstat`: 기호 링크이거나 남의 폴더이면 따라가지 않는다
        var info = stat()
        guard lstat(folder.cwd.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(), let cwd = GateFileSystem.realpath(folder.cwd.path) else { return nil }
        return AgentTerminalSession(providerSessionID: provider, executableRealPath: executable.realPath, sessionCwd: cwd)
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

    /// 로그인 캐시(5분)를 비운다: 다음 `probe()`가 `auth status`를 다시 묻는다 (버전은 실행 파일이 같으면 그대로 쓴다)
    public func refreshProbe() async {
        await probeActor.invalidateLogin()
    }

    public nonisolated func supportsVersion(_ version: String?) -> Bool {
        ClaudeCodeSupport.supports(version)
    }

    // MARK: 프로젝트 지침

    /// 작업 폴더의 CLAUDE.md · .claude/CLAUDE.md를 읽는다 (격리 cwd라 저장소 지침이 들어오지 않는다: 새 세션 · 다음 턴 · 답 · 닫기 모두 시작 프롬프트에 붙는다).
    /// **세션이 비었는지 보기 전에** 부른다: 막힐 수 있는 읽기라 `waitForSessionIdle` 뒤에 끼우면 비었다고 본 뒤 등록까지 틈이 생겨 같은 세션에 writer가 둘 되고
    /// (닫기 + 턴) 그 틈에 `forgetSession`이 방금 심은 가리개를 지운다 · 끝내기가 그 spawn을 놓친다 (검토 P1). `launch`는 등록까지 await가 없어야 한다.
    /// 못 읽은 파일은 조용히 건너뛴다: 로그에는 고정 코드와 수만 남기고 글 · 이름 · 경로는 어디에도 가지 않는다
    private func loadInstructions(workspace: String) async -> ClaudeProjectInstructions {
        await testHooks.beforeInstructionsRead?()
        // 작업 폴더마다 읽기는 하나. 이미 읽는 중이면: 막힌 읽기(기한을 넘겼고 일꾼이 아직 안 돌아왔다)는 기다리지 않고 바로 건너뛴다(busy, 일꾼이 쌓이지 않는다).
        // 막힌 게 아니라 방금 시작한 읽기(다른 세션이 같은 폴더를 거의 동시에 연다)는 기한 안에서 끝나기를 기다린 뒤 읽는다 — 건너뛰면 스냅샷 때문에 그 세션은 끝내 지침 없이 돈다
        var claimed = instructionReads.begin(workspace)
        if !claimed, !instructionReads.isStuck(workspace) {
            let giveUp = Date().addingTimeInterval(timing.instructionsDeadline)
            while instructionReads.isReading(workspace), !instructionReads.isStuck(workspace), Date() < giveUp { try? await Task.sleep(for: .milliseconds(10)) }
            claimed = instructionReads.begin(workspace)
        }
        guard claimed else {
            log.log("claude_instructions_skipped", ["count": .count(1), "why": .code("busy")])
            return ClaudeProjectInstructions()
        }
        // 기한을 둔다: 막힌 볼륨이 턴 시작을 영원히 막지 않게. 막힌 읽기 스레드는 그대로 두고(되돌릴 수 없다) 결과만 버린다 — 일꾼이 돌아올 때 읽는 중 표시를 푼다
        let reader = testHooks.readInstructions
        let reads = instructionReads
        let result: ClaudeProjectInstructions.Outcome? = await Self.withDeadline(timing.instructionsDeadline) {
            defer { reads.end(workspace) }
            return reader?(workspace) ?? ClaudeProjectInstructions.read(workspace: workspace)
        }
        guard let outcome = result else {
            instructionReads.markStuck(workspace)
            log.log("claude_instructions_skipped", ["count": .count(1), "why": .code("timeout")])
            return ClaudeProjectInstructions()
        }
        if outcome.skipped > 0 { log.log("claude_instructions_skipped", ["count": .count(outcome.skipped), "why": .code("unusable")]) }
        let read = outcome.instructions
        if !read.isEmpty { log.log("claude_instructions", ["files": .count(read.files.count), "bytes": .count(read.byteCount), "cut": .count(read.wasCut ? 1 : 0)]) }
        return read
    }

    // MARK: 새 턴

    public func startTurn(_ turn: AgentTurnStart, events: AgentEventSink) async throws -> AgentProcessIdentity {
        guard let workspace = turn.workspaceRef.flatMap(workspaceRealPath), hookServer != nil, let executable = locator.locate() else { throw AgentStartError(.spawnFailed) }
        let instructions = await loadInstructions(workspace: workspace)
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
        let spawn = try await launch(
            mode: .turn(newSessionID: newSession), session: session, providerID: providerID, agentSessionID: turn.sessionID, taskID: turn.taskID, turnSeq: turn.turnSeq,
            access: turn.access, workspace: workspace, instructions: instructions, folder: folder, executable: executable, sink: events, stdin: Data(turn.text.utf8)
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
        let instructions = await loadInstructions(workspace: workspace)
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
        // 비밀값을 건넨다는 표식(값 0)은 띄우기 전에 상태 파일에 적는다: 적지 못하면 건네지 않는다 (11장 9). 가리개가 실제로 값을 가질 때만 (12장 12: 8자 미만은 남는 위험)
        let values = secretValues(answer, open: open)
        state.openDeferred = nil
        if !SecretRedactor(values).isEmpty {
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
        // 새 비밀값을 심는 세션은 다시 쓰이는 세션이다: 앞선 잊기 요청이 이 가리개를 지우지 않게 미룬 요청을 거둔다
        if !values.isEmpty {
            forgetWhenSettled.remove(answer.sessionID)
            sessionRedactors[answer.sessionID] = redactor(answer.sessionID).adding(values)
        }
        secretItems[answer.sessionID] = nil
        let binding = ClaudeAnswerBinding(requestID: answer.requestID, kind: answer.kind, inputSHA256: open.inputSHA256, value: answer.value, targetSHA256: open.targetSHA256)
        let spawn = try await launch(
            mode: .answer(requestID: answer.requestID), binding: binding, session: .resume(external), providerID: external, agentSessionID: answer.sessionID,
            taskID: answer.taskID, turnSeq: answer.turnSeq, access: answer.access, workspace: workspace, instructions: instructions, folder: folder, executable: executable,
            sink: events, stdin: Data()
        )
        // 새 프로세스의 정체가 원장에 commit돼야 답을 준다 (8장 14 · 9장 8): 그 전의 답 훅은 기다린다. 실패하면 답을 주지 않고 그 프로세스를 끝낸다.
        // 끝이 증명될 때까지 이 spawn이 등록부 · 디스크 잠금에 남아 같은 세션의 다음 실행을 막는다
        var recorded = false
        if let identity = spawn.identity, let services = services.withLock({ $0 }) { recorded = await services.recordSpawn(answer.taskID, identity) }
        spawn.identityRecorded = recorded
        guard recorded, let spawned = spawn.identity else {
            log.log("claude_identity_unrecorded", ["task": .id(answer.taskID)])
            sendInterrupt(spawn)
            // 원장에 적지 못한 이 실행의 정체를 넘긴다 (15장 1: 런타임이 앞 실행의 끝으로 덮지 않게)
            throw AgentStartError(.agentError, left: spawn.identity ?? Self.lockedIdentity(spawn.id))
        }
        // 보류 id의 훅에 답을 확정하면 그 순간 전달이다. 그 전에 init이나 다른 호출(상태 유실) · Stop · 훅 시간 초과 · 프로세스 끝이 오면 그 자리에서 닫힘(`.lost`).
        // 결과는 답 응답 확정과 한 잠금에서 정해진다 (15장 2: 전달했으면 delivered, 아니면 lost). 기다림에는 시간 제한이 있다 (9장 9)
        let deadline = Date().addingTimeInterval(timing.answerTimeout)
        while spawn.answer.signal == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        if spawn.answer.lose() {
            log.log("claude_answer_timeout", ["task": .id(answer.taskID)])
            sendInterrupt(spawn)
        }
        if case .delivered(let at)? = spawn.answer.signal {
            var identity = spawned
            identity.inputSentAt = at
            return .delivered(identity)
        }
        // 프로세스가 이미 거둬졌으면 자손 정리를 기다리지 않는다 (세션 자리는 정리가 끝날 때까지 잡혀 있다)
        if !spawn.exited { _ = await waitForEnd(spawn, timeout: timing.closeTimeout) }
        return .requestClosed
    }

    // MARK: 닫기 (계약 2.12)

    public func closeRequest(_ request: AgentRequestRef) async throws {
        guard let workspace = request.workspaceRef.flatMap(workspaceRealPath) else { throw AgentStartError(.spawnFailed) }
        // Claude 세션이 없으면 닫을 보류도 없다
        guard let external = request.externalSessionID, BridgeRuntime.isSafeSessionID(external) else { return }
        guard let executable = locator.locate() else { throw AgentStartError(.spawnFailed) }
        let instructions = await loadInstructions(workspace: workspace)
        try await waitForSessionIdle(request.sessionID)
        let folder = try ClaudeSessionFolder.prepare(sessionsRoot: sessionsRoot, agentSessionID: request.sessionID)
        try Self.requireBound(external, state: ClaudeSessionState.load(from: folder.root))
        secretItems[request.sessionID] = nil
        try await close(
            requestID: request.requestID, providerID: external, agentSessionID: request.sessionID, taskID: request.taskID, workspace: workspace, instructions: instructions, executable: executable
        )
    }

    private func close(
        requestID: String, providerID: String, agentSessionID: String, taskID: String, workspace: String, instructions: ClaudeProjectInstructions, executable: ClaudeCodeExecutable
    ) async throws {
        let folder = try ClaudeSessionFolder.prepare(sessionsRoot: sessionsRoot, agentSessionID: agentSessionID)
        var state = ClaudeSessionState.load(from: folder.root)
        state.openDeferred = nil
        try? state.save(in: folder.root)
        // 닫기 spawn의 사건은 서버로 보내지 않는다 (sink 없음). 모든 훅이 deny, 닫는 id의 결과에서 SIGINT
        let spawn = try await launch(
            mode: .close(requestID: requestID), session: .resume(providerID), providerID: providerID, agentSessionID: agentSessionID, taskID: taskID, turnSeq: 1,
            access: .write, workspace: workspace, instructions: instructions, folder: folder, executable: executable, sink: nil, stdin: Data()
        )
        // 끝날 때까지 기다린다 (다음 startTurn이 두 번째 writer를 만들지 않게). 10초 안에 끝나지 않으면 고아 끝내기.
        // 끝을 증명하지 못하면 던진다 (8장 15): 호출한 쪽은 이 세션의 다음 실행을 띄우지 않는다
        if await waitForEnd(spawn, timeout: timing.closeTimeout) { return }
        if let identity = spawn.identity { _ = await terminate(identity, lineage: spawn.lineage) }
        if await waitForEnd(spawn, timeout: timing.orphanKillGrace + 1) { return }
        log.log("claude_writer_unproven", ["mode": .code("close")])
        // 끝을 모르는 닫기 실행의 정체를 넘긴다 (15장 1: 런타임이 그 실행을 Stop · 고아 정리 대상으로 둔다)
        throw AgentStartError(.agentError, left: spawn.identity ?? Self.lockedIdentity(spawn.id))
    }

    // MARK: 중단 · 고아 (계약 2.13 · 2.14)

    /// 감독 중인 실행이면 SIGINT를 보내고 유예 뒤 정체를 다시 보고 자손까지 SIGKILL로 올린다 (9장 6). 끝은 감독이 `ended`로 알린다(`signalled`).
    /// 등록부에 없으면(앱이 다시 떴다) 원장의 정체로 확인해 끝까지 끝낸다: 끝났음이 증명될 때만 `notRunning`, 확인할 수 없거나 끝내지 못했으면 `unknown` (8장 12, OA D4a2-09: 보냈다고 적지 않는다)
    public func interrupt(_ target: AgentTurnRef, scope: AgentCancelScope) async -> AgentInterruptResult {
        if let spawnID = taskSpawn[target.taskID], let spawn = spawns[spawnID] {
            spawn.mapper.markInterruptRequested()
            let signalling = !spawn.exited && spawn.identity != nil && !spawn.interruptSent
            // Stop 전이 (14장 7): 그 뒤 훅은 deny, 아직 전달하지 않은 답은 바로 닫고(값을 지우고 `.lost`: 그 뒤 프로세스가 훅 없이 끝나도 `requestClosed`),
            // 띄운 뒤면 SIGINT (띄우는 중이면 띄운 직후)
            sendInterrupt(spawn)
            if signalling { log.log("claude_interrupt", ["task": .id(target.taskID)]) }
            return .signalled
        }
        // 등록부에 없으면(앱이 다시 떴다 · 닫기가 끝을 증명하지 못했다) 원장 정체가 아니라 그 세션 잠금의 지금 spawn을 끝낸다 (15장 1)
        if sessionLockFile(target.sessionID) != nil {
            switch await terminateLocked(target.sessionID) {
            case .ended:
                log.log("claude_interrupt", ["task": .id(target.taskID), "orphan": .count(1)])
                return .notRunning
            case .alive, .unknown:
                log.log("claude_interrupt_unproven", ["task": .id(target.taskID)])
                return .unknown
            }
        }
        guard let identity = target.identity else { return .unknown }
        switch await terminate(identity, lineage: sharedLineage(identity.processMarker), forgetOnEnd: true) {
        case .ended:
            log.log("claude_interrupt", ["task": .id(target.taskID), "orphan": .count(1)])
            return .notRunning
        case .alive, .unknown:
            log.log("claude_interrupt_unproven", ["task": .id(target.taskID)])
            return .unknown
        }
    }

    /// 감독 중인 spawn이면 그 혈통으로, 아니면(앱이 다시 떴다) 적어 둔 혈통 파일로 자손까지 본다 (9장 4 정정). marker마다 혈통 객체 하나 (12장 8).
    /// 감독 밖에서 끝을 증명하면 끝 기록을 남긴다 (10장 4 · 12장 8)
    public func liveness(_ identity: AgentProcessIdentity) async -> AgentLiveness {
        if let lineage = spawns[identity.processMarker]?.lineage { return ClaudeProcessInspector.liveness(identity, lineage: lineage) }
        let lineage = sharedLineage(identity.processMarker)
        let result = ClaudeProcessInspector.liveness(identity, lineage: lineage)
        if case .ended = result { lineage.forget() }
        return result
    }

    /// 앱이 뜰 때 부른다: 다른 부팅에 적힌 혈통 파일을 이번 부팅의 끝 기록으로 바꾸고 다른 부팅의 세션 잠금을 지운다 (10장 4 · 11장 1, 결정 11-1 · 14장 1).
    /// 이번 부팅의 파일은 고아 정리 · 다음 writer가 쓰고 끝을 증명하면 끝 기록이 된다.
    /// 끝이 증명된 spawn이 앱이 죽어 남긴 설정 파일 셋(`config/<spawn id>.*`: 훅 nonce · 프로젝트 지침 글)도 함께 지운다 (로그에는 지운 수만)
    public nonisolated func purgeLineageOfOtherBoots() {
        ClaudeLineage.purge(directory: sessionsRoot.appending(path: "lineage", directoryHint: .isDirectory))
        let removed = ClaudeLineage.removeConfigLeftovers(sessionsRoot: sessionsRoot)
        if removed > 0 { log.log("claude_config_leftovers_removed", ["count": .count(removed)]) }
    }

    /// 세션의 지금 실행 (14장 2 · 15장 1: 디스크 잠금이 유일한 생존 진실): 잠금의 현재 spawn(턴 · 답 · 닫기 · 내부 닫기)과 그 끝 증명. 감독 중이면 살아 있음
    /// (끝을 증명하지 못하고 그만뒀으면 unknown), 아니면 잠금과 그 혈통으로 본다
    public func sessionRun(_ sessionID: String) async -> AgentSessionRun? {
        // 실행 등록부 하나 (17장 1, 16장 5를 대신한다): 그 세션의 spawn이 등록부에 있는 동안(띄우기 의도 · 시작 보고 기다림 · 실행 · 끝 증명 · 따라오는 닫기까지)은
        // 살아 있다. 끝을 증명하지 못하고 그만둔 것이 있으면 unknown
        let registered = registeredSpawns(sessionID)
        if !registered.isEmpty {
            let current = sessionSpawn[sessionID].flatMap { spawns[$0] } ?? registered[0]
            let liveness: AgentLiveness = registered.contains(where: \.endUnproven) ? .unknown : .alive
            return AgentSessionRun(liveness: liveness, identity: current.identity ?? Self.lockedIdentity(current.id))
        }
        let state = lockState(sessionID)
        return AgentSessionRun(liveness: state.liveness, identity: state.spawnID.map(Self.lockedIdentity))
    }

    /// 그 세션의 등록부 항목 (턴 · 답 · 닫기 · 내부 닫기 · 시작 중인 것)
    private func registeredSpawns(_ sessionID: String) -> [Spawn] {
        spawns.values.filter { $0.agentSessionID == sessionID }.sorted { $0.id < $1.id }
    }

    /// 등록부에 spawn이 하나라도 있나 (17장 1: 종료 판단 · Quit 확인)
    public func hasRegisteredRuns() async -> Bool {
        !spawns.isEmpty
    }

    /// 앱 종료 · 계정 삭제가 시작됐다 (16장 1): 그 뒤의 spawn(내부 닫기 포함)을 모두 막는다. 돌고 있는 것은 그대로 (런타임이 끝낸다)
    public func stopSpawning() async {
        spawningStopped = true
    }

    /// 그 세션의 지금 실행을 끝낸다 (15장 1 · 17장 1: 고아 정리 · 앱 종료). 등록부에 있으면 그 세션의 모든 spawn을: 따라올 내부 닫기를 취소하고, 시작 중인 것은
    /// `stopped`로 표시해 정체를 받은 뒤 stdin 전에 멈추게 하고(`launch`), 도는 것은 그 혈통으로 끝낸 뒤, 등록부에서 빠질 때까지(시작 보고 · 끝 증명 · 정리) 기다린다
    /// (시간 제한). 등록부에 없으면 잠금의 spawn을 그 혈통으로
    public func terminateSessionRun(_ sessionID: String) async -> AgentLiveness {
        let registered = registeredSpawns(sessionID)
        guard !registered.isEmpty else { return await terminateLocked(sessionID) }
        for spawn in registered {
            spawn.unexpectedDeferred = nil
            if let identity = spawn.identity, !spawn.exited {
                _ = await terminate(identity, lineage: spawn.lineage)
            } else {
                sendInterrupt(spawn)
            }
        }
        let deadline = Date().addingTimeInterval(timing.closeTimeout + Self.startSettle)
        while registeredSpawns(sessionID).contains(where: { !$0.endUnproven }), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let left = registeredSpawns(sessionID)
        if left.contains(where: \.endUnproven) { return .unknown }
        guard left.isEmpty else { return .alive }
        return lockState(sessionID).liveness
    }

    /// 시작 중인 spawn이 정산될 때까지(지킴이 시작 보고 5초 · 거두기) 더 기다리는 시간
    static let startSettle: TimeInterval = 6

    /// 디스크 잠금의 지금 spawn을 그 혈통으로 끝낸다: 끝을 증명하면 끝 기록 · 잠금 해제
    private func terminateLocked(_ sessionID: String) async -> AgentLiveness {
        let (state, spawnID) = lockState(sessionID)
        if case .ended = state { return state }
        guard let spawnID else { return state }
        let result = await terminate(Self.lockedIdentity(spawnID), lineage: sharedLineage(spawnID), forgetOnEnd: true)
        if case .ended = result, let file = sessionLockFile(sessionID) { ClaudeSessionLock.release(file, spawnID: spawnID) }
        return result
    }

    /// 세션 잠금 파일 (14장 1)
    nonisolated func sessionLockFile(_ sessionID: String) -> URL? {
        ClaudeSessionLock.file(sessionsRoot: sessionsRoot, session: sessionID)
    }

    /// 확인용 정체: pid 없이 marker만 (그 spawn의 끝은 혈통 · 지킴이로 본다)
    static func lockedIdentity(_ spawnID: String) -> AgentProcessIdentity {
        AgentProcessIdentity(pid: nil, startedAt: .distantPast, processMarker: spawnID)
    }

    /// 디스크 잠금으로 본 그 세션의 마지막 spawn (14장 1): 잠금이 없거나 다른 부팅이면 끝. 잠금의 spawn을 그 혈통으로 보고, 끝을 증명하면 끝 기록을 남기고 잠금을 푼다.
    /// 잠금 · 혈통을 읽지 못했거나 정체 자리(`pending`)뿐이면 unknown. 잠금 자리가 없는 세션 id(UUID 아님)에는 spawn이 생길 수 없다 → 끝 (16장 7)
    private func lockState(_ sessionID: String) -> (liveness: AgentLiveness, spawnID: String?) {
        guard let file = sessionLockFile(sessionID) else { return (.ended(AgentExit(code: nil)), nil) }
        switch ClaudeSessionLock.read(file) {
        case .none: return (.ended(AgentExit(code: nil)), nil)
        case .otherBoot:
            try? FileManager.default.removeItem(at: file)
            return (.ended(AgentExit(code: nil)), nil)
        case .unreadable: return (.unknown, nil)
        case .spawn(let spawnID):
            let lineage = sharedLineage(spawnID)
            let liveness = ClaudeProcessInspector.liveness(Self.lockedIdentity(spawnID), lineage: lineage)
            if case .ended = liveness {
                lineage.forget()
                ClaudeSessionLock.release(file, spawnID: spawnID)
            }
            return (liveness, spawnID)
        }
    }

    public func terminateOrphan(_ identity: AgentProcessIdentity) async -> AgentLiveness {
        await terminate(identity, lineage: sharedLineage(identity.processMarker), forgetOnEnd: spawns[identity.processMarker] == nil)
    }

    /// 그 혈통(marker마다 하나, 12장 8)으로 끝낸다. `forgetOnEnd`(감독 밖)면 끝을 증명했을 때 끝 기록을 남긴다. 감독 중인 spawn의 혈통은 `finish`가 정리한다
    nonisolated func terminate(_ identity: AgentProcessIdentity, lineage: ClaudeLineage, forgetOnEnd: Bool = false) async -> AgentLiveness {
        if let override = testHooks.terminateOverride?(identity) { return override }
        let timing = self.timing
        return await offActor {
            let result = ClaudeProcessInspector.terminate(identity, timing: timing, lineage: lineage)
            if forgetOnEnd, case .ended = result { lineage.forget() }
            return result
        }
    }

    /// 막히는 일(신호 뒤 기다림 · 파일 해시)을 협력 스레드 밖에서
    nonisolated func offActor<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }

    /// 그 작업 폴더의 지침 읽기 일꾼이 아직 안 돌아왔다 (기한을 넘겨 건너뛴 읽기 포함, 시험이 본다)
    nonisolated func instructionReadInFlight(_ workspace: String) -> Bool {
        instructionReads.isReading(workspace)
    }

    /// 막힐 수 있는 일을 다른 스레드에서 돌리고 `seconds` 안에 끝나지 않으면 nil. 일은 끝까지 돌게 두고 결과만 버린다
    /// (막힌 파일 읽기 스레드를 되돌릴 방법은 없다. 구조화된 동시성 그룹은 그 자식을 기다리므로 쓰지 않는다)
    nonisolated static func withDeadline<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = DeadlineOnce()
            DispatchQueue.global(qos: .userInitiated).async {
                let value = work()
                if once.claim() { continuation.resume(returning: value) }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
                if once.claim() { continuation.resume(returning: nil) }
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

    /// 격리 `cwd/` (12장 13 · 14장 11): `lstat`로 이 사용자 소유 · 모드 0700 · 비어 있는 실제 폴더일 때만 그대로 쓴다 (없으면 만든다). 그 밖은 무엇이든
    /// (기호 링크 · 파일 · 다른 소유자 · 다른 모드 · 비지 않음) 따라가지 않고 세션 폴더 안 `cwd.quarantine-<uuid>`로 옮기고 같은 자리에 새 `cwd/`(0700)를 만든다.
    /// 격리 폴더는 세션 폴더와 함께 지워진다 (세션 · 계정 삭제). 옮기거나 만들지 못하면 띄우지 않는다
    private func prepareCwd(_ folder: ClaudeSessionFolder) throws {
        let path = folder.cwd.path
        func usable() -> Bool {
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(), (info.st_mode & 0o7777) == 0o700 else { return false }
            return (try? FileManager.default.contentsOfDirectory(atPath: path))?.isEmpty == true
        }
        if usable() { return }
        var info = stat()
        if lstat(path, &info) == 0 {
            let quarantine = folder.root.appending(path: "cwd.quarantine-\(UUID().uuidString.lowercased())")
            guard rename(path, quarantine.path) == 0 else {
                log.log("claude_selfcheck_failed", ["check": .count(1)])
                throw AgentStartError(.spawnFailed)
            }
            log.log("claude_cwd_quarantined", [:])
        } else if errno != ENOENT {
            log.log("claude_selfcheck_failed", ["check": .count(1)])
            throw AgentStartError(.spawnFailed)
        }
        guard mkdir(path, 0o700) == 0, chmod(path, 0o700) == 0, usable() else {
            log.log("claude_selfcheck_failed", ["check": .count(1)])
            throw AgentStartError(.spawnFailed)
        }
    }

    private func launch(
        mode: ClaudeMapperConfig.Mode, binding: ClaudeAnswerBinding? = nil, session: ClaudeCodeLaunch.SessionArgument, providerID: String, agentSessionID: String, taskID: String,
        turnSeq: Int, access: AgentAccess, workspace: String, instructions: ClaudeProjectInstructions, folder: ClaudeSessionFolder, executable: ClaudeCodeExecutable,
        sink: AgentEventSink?, stdin: Data
    ) async throws -> Spawn {
        // 종료가 시작된 뒤에는 띄우지 않는다 (16장 1, 프로세스 0)
        guard !spawningStopped else {
            log.log("claude_spawn_refused", ["reason": .code("shutdown")])
            throw AgentStartError(.spawnFailed)
        }
        try prepareCwd(folder)
        let spawnID = UUID().uuidString
        let nonce = ClaudeCodeLaunch.newNonce()
        // 소켓이 없으면(닫기만) 없는 경로를 준다: 훅은 연결하지 못해 모두 deny한다
        let socket = hookServer?.path ?? folder.config.appending(path: "no-socket").path
        let settings = try ClaudeCodeLaunch.settingsJSON(hook: helpers.hook, socket: socket, session: agentSessionID, nonce: nonce)
        let mcp = ClaudeCodeLaunch.mcpJSON(helper: helpers.mcp, session: agentSessionID)
        // 시작 프롬프트(작업 폴더 줄 + 프로젝트 지침)는 인자가 아니라 0600 파일로 준다: `ps`가 인자를 읽는다 (검토 보안 P2). 표지 꼬리표는 spawn마다 무작위
        let prompt = ClaudeCodePrompts.v2(workspace: workspace, instructions: instructions, tag: testHooks.instructionsTag?() ?? ClaudeProjectInstructions.newTag())
        let files = try ClaudeCodeLaunch.writeConfig(directory: folder.config, spawnID: spawnID, settings: settings, mcp: mcp, prompt: prompt)
        testHooks.afterConfigWrite?(files.settings)
        // ①: 쓴 파일을 다시 읽어 기대 값과 같고, 격리 `cwd/`가 비어 있을 때만 띄운다 (11장 10: 누가 project 설정을 심어 두지 않았다. 남은 것은 위에서 격리했다, 12장 13)
        guard ClaudeCodeLaunch.verifyConfig(files, settings: settings, mcp: mcp, prompt: prompt), (try? FileManager.default.contentsOfDirectory(atPath: folder.cwd.path))?.isEmpty == true else {
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
        var stripped = binding
        stripped?.value = AgentAnswerValue()
        guard let file = lineageFile(spawnID), let lockFile = sessionLockFile(agentSessionID) else {
            ClaudeCodeLaunch.removeConfig(files)
            throw AgentStartError(.spawnFailed)
        }
        let spawn = Spawn(
            id: spawnID, nonce: nonce, mode: mode, providerID: providerID, agentSessionID: agentSessionID, taskID: taskID, turnSeq: turnSeq, access: access, workspace: workspace,
            folder: folder, cwdReal: cwdReal, childPATH: environment["PATH"] ?? "", files: files, sink: sink, mapper: mapper,
            lineage: ClaudeLineage(file: file, fresh: true), answer: binding?.value ?? AgentAnswerValue()
        )
        spawn.binding = stripped
        // 띄우기 전에 디스크 잠금 (14장 1): 이번 spawn의 정체 자리(혈통 `pending`)와 세션 잠금. 못 쓰면 띄우지 않는다 (프로세스 0)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard spawn.lineage.savePending(), ClaudeSessionLock.write(lockFile, spawnID: spawnID) else {
            spawn.lineage.forget()
            ClaudeSessionLock.release(lockFile, spawnID: spawnID)
            ClaudeCodeLaunch.removeConfig(files)
            log.log("claude_lineage_unrecorded", ["reason": .code("lock")])
            throw AgentStartError(.spawnFailed)
        }
        let answered = spawn.answered
        let slot = spawn.answer
        let answerMode = if case .answer = mode { true } else { false }
        hookServer?.register(nonce: nonce, HookSocketServer.Registration(agentSessionID: agentSessionID, providerSessionID: providerID, committing: { [weak self] request, commit in
            guard let self else {
                _ = commit.commit(HookResponse(decision: .deny, reason: ClaudeGateReason.turnStopped))
                return
            }
            _ = await self.handleHook(spawnID: spawnID, request, commit: commit)
        }, onAnswer: { id in answered.insert(id) }, timeOut: { [weak self] commit, _ in
            // 훅 시간 초과 전이 (14장 7 · 16장 2): 요청을 시간 초과로 정하는 것과 아직 전달하지 않은 답을 닫는 것(`.lost`, 훅 id와 무관)을 답 슬롯 잠금 안에서 함께.
            // 그 뒤 다른 훅의 답 확정은 닫힌 슬롯을 본다. 닫았으면 그 spawn을 멈춘다
            guard answerMode else { return commit.timeOut() }
            let (won, closed) = slot.timeOut(commit)
            if closed { Task { await self?.stopAfterTimeout(spawnID) } }
            return won
        }))
        // 띄우는 동안(actor 밖, 14장 9) 같은 세션의 다음 실행은 이 spawn을 기다린다
        spawns[spawnID] = spawn
        sessionSpawn[agentSessionID] = spawnID
        taskSpawn[taskID] = spawnID
        let arguments = ClaudeCodeLaunch.arguments(
            access: access, workspace: workspace, settings: files.settings.path, mcp: files.mcp.path, promptFile: files.prompt.path, session: session
        )
        // 지킴이를 disclaim으로 띄우고 지킴이가 `claude`를 띄운다 (13장 1). 검사한 실제 파일(realpath)로 띄우고, 자식이 보는 argv[0]은 후보 경로 그대로 (8장 8).
        // 지킴이가 알린 `claude` · 지킴이 id를 앱이 다시 대조하지 못하면 정체 commit · stdin 전에 멈춘다 (12장 6). 막히는 일은 actor 밖에서 (14장 9)
        let keeper = helpers.keeper
        let timing = self.timing
        let lookups = ClaudeProcessInspector.lookups
        let cwd = folder.cwd.path
        let childEnvironment = environment
        let started = await offActor {
            ClaudeSpawner.spawnKept(
                keeper: keeper, ended: ClaudeLineage.keeperFile(file), executable: executable.realPath, argv0: executable.path, arguments: arguments,
                environment: childEnvironment, cwd: cwd, abortTimeout: timing.keeperExit, lookups: lookups
            )
        }
        let kept: ClaudeKeptSpawn
        switch started {
        case .success(let value): kept = value
        case .failure(.notRun): throw launchFailed(spawn, ended: true, claude: nil, reason: "keeper_spawn")
        case .failure(.stopped(let ended, let diagnostic)):
            log.log("claude_start_diagnostic", [
                "cause": .code(diagnostic.cause.rawValue), "ended": .count(ended ? 1 : 0),
                "ended_report": .count(diagnostic.abort.sawEnded ? 1 : 0), "forced_kill": .count(diagnostic.abort.forcedKill ? 1 : 0),
                "exit_code": diagnostic.abort.code.map { .count(Int($0)) } ?? .code("none"), "signal": diagnostic.abort.signal.map { .count(Int($0)) } ?? .code("none"),
                "wait": .millis(diagnostic.waitMilliseconds), "abort": .millis(diagnostic.abortMilliseconds),
            ])
            throw launchFailed(spawn, ended: ended, claude: nil, reason: diagnostic.cause.launchReason)
        }
        spawn.process = kept.keeper
        // 지킴이 · 뿌리를 바로 파일에 적는다 (13장 2). 적지 못했으면 이 spawn의 끝을 나중에 증명할 수 없다: 정체 commit · stdin 전에 멈춘다 (11장 2 · 14장 1)
        spawn.lineage.adopt(ClaudeLineage.Record(
            keeper: ClaudeLineage.Keeper(pid: kept.keeper.pid, uniqueID: kept.keeperID), root: kept.claudeID, rootPID: kept.claudePID, attributable: kept.attributable
        ))
        guard spawn.lineage.save(), spawn.lineage.isRecorded else {
            let ended = await offActor { ClaudeSpawner.abort(kept.keeper, reportFD: kept.reportFD, timeout: timing.keeperExit) }
            throw launchFailed(spawn, ended: ended, claude: kept, reason: "file")
        }
        // 책임 프로세스 물러남 (13장 5): 띄우되 구성원을 증명할 수 없다 → 끝을 확정하지 않는다 (세션 잠금)
        if !kept.attributable { log.log("claude_membership_unprovable", ["reason": .code("disclaim")]) }
        let identity = AgentProcessIdentity(pid: Int(kept.claudePID), startedAt: kept.claudeStartedAt, processMarker: spawnID, externalTaskID: "\(providerID):\(turnSeq)")
        spawn.identity = identity
        // stdin: 새 턴은 메시지 글을 쓰고 닫는다. 답 · 닫기 resume는 아무것도 쓰지 않고 닫는다 (빈 stdin, 13.2 :509, 사례 8-05). 쓰기는 따로 (파이프 64KB 막힘 방지)
        let input = kept.keeper.stdinFD
        // 띄우는 동안 멈추라고 했다(Stop · 시간 초과 · 종료 · 고아 정리, 17장 1): 입력을 건네지 않는다 (빈 stdin, 아래에서 SIGINT)
        let payload = spawn.stopped ? Data() : stdin
        testHooks.inputBytes?(payload.count)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = HookMain.writeAll(fd: input, payload)
            Darwin.close(input)
        }
        supervise(spawn, kept: kept, identity: identity)
        log.log("claude_spawn", ["mode": .code(spawn.modeName)])
        // 띄우는 동안 Stop · 시간 초과가 왔다 (14장 7 · 9)
        if spawn.stopped { sendInterrupt(spawn) }
        return spawn
    }

    /// 띄우기가 정체를 적기 전에 실패했다 (14장 1): 등록부에서 내리고 설정 · 소켓 등록을 거둔다. 끝을 증명했으면(지킴이 spawn 실패 = 프로세스 0, 또는 지킴이 0 종료)
    /// 끝 기록을 남기고 잠금을 푼다. 아니면 잠금 · 정체 자리를 남긴다: 다시 뜬 앱과 지금 런타임 모두 unknown (턴 · 답이면 그 정체를 `left`로 알린다)
    private func launchFailed(_ spawn: Spawn, ended: Bool, claude: ClaudeKeptSpawn?, reason: String) -> AgentStartError {
        hookServer?.unregister(nonce: spawn.nonce, after: .zero)
        ClaudeCodeLaunch.removeConfig(spawn.files)
        spawn.answer.end()
        spawns[spawn.id] = nil
        if sessionSpawn[spawn.agentSessionID] == spawn.id { sessionSpawn[spawn.agentSessionID] = nil }
        if taskSpawn[spawn.taskID] == spawn.id { taskSpawn[spawn.taskID] = nil }
        spawn.ended = true
        if ended {
            spawn.lineage.forget()
            if let lockFile = sessionLockFile(spawn.agentSessionID) { ClaudeSessionLock.release(lockFile, spawnID: spawn.id) }
            log.log("claude_lineage_unrecorded", ["reason": .code(reason)])
            return AgentStartError(.spawnFailed)
        }
        // 이 spawn의 혈통 객체를 다음 확인이 쓴다: 앱이 부모로서 지킴이의 0 종료를 받지 못했다 (15장 4: 기록 파일보다 이것이 우선)
        spawn.lineage.markUnproven()
        lineages[spawn.id] = spawn.lineage
        log.log("claude_start_unproven", ["reason": .code(reason), "mode": .code(spawn.modeName)])
        // 닫기 spawn도 그 정체를 넘긴다 (15장 1)
        let left = AgentProcessIdentity(pid: claude.map { Int($0.claudePID) }, startedAt: claude?.claudeStartedAt ?? Date(), processMarker: spawn.id)
        return AgentStartError(.spawnFailed, left: left)
    }

    /// 훅 시간 초과로 답을 닫았다 (14장 7): 그 spawn을 멈춘다
    private func stopAfterTimeout(_ spawnID: String) {
        guard let spawn = spawns[spawnID] else { return }
        sendInterrupt(spawn)
    }

    // MARK: 훅 요청 (소켓 → 결정기)

    /// 훅 요청 하나. 한 spawn의 훅은 하나씩 정한다 (defer 하나 · 답 한 번이 겹치지 않게): 앞 훅이 응답을 확정할 때까지 기다린다.
    /// 정한 뒤 돌려주기 직전(마지막 await 뒤)에 중단 상태와 응답 · 전달 기록을 한 번에 확정한다(`settle`, 11장 6): 그 사이에 await가 없어 Stop이 끼어들 틈이 없다.
    /// 소켓과는 요청마다 한 번 정해지는 상태(`commit`, 12장 9)로 만난다: 소켓 시간 초과가 먼저면 그 결과를 기록하지 않는다
    func handleHook(spawnID: String, _ request: HookRequest, commit: HookCommit) async -> HookResponse {
        // 정체를 적기 전(띄우는 중)의 훅도 deny다
        guard let spawn = spawns[spawnID], spawn.identity != nil else {
            let response = HookResponse(decision: .deny, reason: ClaudeGateReason.turnStopped)
            _ = commit.commit(response)
            return response
        }
        let previous = spawn.hookTail
        let (turn, settled) = AsyncStream<Void>.makeStream()
        spawn.hookTail = Task { for await _ in turn {} }
        defer { settled.finish() }
        await previous?.value
        let started = Date()
        let decided = await decide(spawn: spawn, request)
        await testHooks.beforeHookReturn?()
        return settle(spawn, request, decided, started: started, commit: commit)
    }

    /// 돌려주기 직전의 확정 (11장 6, await 없음): 중단 · 자체 점검 실패가 보이면 answers 없는 deny(답 훅이면 값을 지우고 `.lost` → `requestClosed`),
    /// 아니면 그 결과대로 보류 · 전달(`.delivered` · 값 지우기)을 적는다. 그 응답을 요청 상태에 확정하지 못했으면(소켓이 시간 초과로 deny를 이미 썼다, 12장 9)
    /// Claude가 받은 것은 deny다: 보류 · 전달을 적지 않고, 답 훅이면 값을 지우고 `.lost`로 그 spawn을 멈춘다
    private func settle(_ spawn: Spawn, _ request: HookRequest, _ decided: ClaudeGateOutcome, started: Date, commit: HookCommit) -> HookResponse {
        var outcome = stopOverride(spawn, request, decided)
        var committed: Bool
        if outcome.answeredPending {
            // 답 응답의 확정과 답 결과를 한 잠금에서 정한다 (15장 2): 이미 닫혔으면(다른 훅 시간 초과 · Stop · 끝) 답을 주지 않고 answers 없는 deny를 확정한다
            let closed = ClaudeToolGate.local(.deny, ClaudeGateReason.turnStopped, "answer_closed")
            switch spawn.answer.commitAnswer(outcome.response, closed: closed.response, to: commit, at: Date()) {
            case .delivered:
                committed = true
                spawn.answerDelivered = true
            case .alreadyClosed:
                outcome = closed
                committed = true
            case .timedOut:
                committed = false
            }
        } else {
            committed = commit.commit(outcome.response)
        }
        if !committed {
            // Claude가 받은 것은 시간 초과 deny다 (14장 7): 아직 전달하지 않은 답은 훅 id와 무관하게 닫고(시간 초과 전이에서 이미 닫았다) 멈춘다.
            // 정한 결과가 그 spawn을 멈추기로 했으면(`abortSpawn`) 그것도 잃지 않는다
            let abort = outcome.abortSpawn || isUndeliveredAnswer(spawn)
            spawn.answer.lose()
            if abort { sendInterrupt(spawn) }
            outcome = ClaudeToolGate.local(.deny, HookReason.unavailable, "bridge_timeout")
        }
        if outcome.response.decision == .defer, let deferred = outcome.deferred {
            spawn.deferIssued = true
            spawn.facts.pending = deferred
        }
        if outcome.abortSpawn { sendInterrupt(spawn) }
        log.log("tool_gate", [
            "source": .code(outcome.source.rawValue), "decision": .code(outcome.response.decision.rawValue), "reason": .code(outcome.code),
            "ms": .millis(Int(Date().timeIntervalSince(started) * 1000)),
        ])
        return outcome.response
    }

    /// 아직 전달하지 않은 답의 보류 id 훅이다
    private func isPendingAnswer(_ spawn: Spawn, _ request: HookRequest) -> Bool {
        request.toolUseID == spawn.binding?.requestID && isUndeliveredAnswer(spawn)
    }

    /// 답 resume인데 아직 답을 전달하지 않았다
    private func isUndeliveredAnswer(_ spawn: Spawn) -> Bool {
        guard case .answer = spawn.mode else { return false }
        return !spawn.answerDelivered
    }

    /// 중단 재확인 하나 (9장 7 · 10장 6 · 11장 6 · 12장 10): 이 spawn에 Stop · 자체 점검 실패가 왔으면 allow · defer를 answers 없는 deny로 바꾼다.
    /// 아직 전달하지 않은 답은 decision과 무관하게(이미 deny여도) Stop이 이긴다: 값은 메모리에서 지우고 `.lost`, answers 없는 deny
    private func stopOverride(_ spawn: Spawn, _ request: HookRequest, _ outcome: ClaudeGateOutcome) -> ClaudeGateOutcome {
        guard spawn.stopped || spawn.interruptSent else { return outcome }
        if isPendingAnswer(spawn, request) {
            spawn.answer.lose()
        } else if outcome.response.decision == .deny {
            return outcome
        }
        return ClaudeToolGate.local(.deny, ClaudeGateReason.turnStopped, "stopped_after_wait")
    }

    private func decide(spawn: Spawn, _ request: HookRequest) async -> ClaudeGateOutcome {
        spawn.facts.toolNames[request.toolUseID] = request.toolName
        if ["Edit", "Write"].contains(request.toolName), let path = request.toolInput["file_path"]?.stringValue, let absolute = GateFileSystem.absolute(path, cwd: request.cwd) {
            spawn.facts.filePaths[request.toolUseID] = absolute
        }
        // 답 훅은 새 정체가 원장에 commit된 뒤에만 답한다 (9장 8): 그 전이면 잠깐 기다리고(훅 예산 안), 실패 · 시간 초과면 답을 주지 않는다
        if case .answer = spawn.mode, request.toolUseID == spawn.binding?.requestID {
            let deadline = Date().addingTimeInterval(timing.identityWait)
            while spawn.identityRecorded == nil, Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
            if spawn.identityRecorded != true {
                sendInterrupt(spawn)
                return ClaudeToolGate.local(.deny, ClaudeGateReason.turnStopped, "identity_unrecorded")
            }
        }
        // 답 값은 기다린 뒤에 읽는다 (그 사이 Stop · 시간 초과가 지웠으면 빈 값: 아래 재확인이 deny로 바꾼다)
        let gateMode: ClaudeGateContext.Mode
        switch spawn.mode {
        case .turn: gateMode = .normal
        case .answer:
            gateMode = spawn.binding.map {
                var binding = $0
                binding.value = spawn.answer.value
                return .answer(binding)
            } ?? .normal
        case .close(let requestID): gateMode = .close(requestID: requestID)
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

    /// `claude`의 stdout · stderr 파이프(지킴이가 넘긴 것)를 읽는다. `claude`가 끝난 것은 지킴이 보고(`exited`)로 안다: 보고 없이 닫히면(지킴이가 죽었다)
    /// `claude`의 정체가 사라질 때까지 기다린 뒤 상태 모름으로. 지킴이는 앱의 자식이라 따로 거두고 그 상태를 혈통에 적는다 (13장 3)
    private func supervise(_ spawn: Spawn, kept: ClaudeKeptSpawn, identity: AgentProcessIdentity) {
        let (stream, continuation) = AsyncStream<ReaderItem>.makeStream()
        let stop = spawn.readerStop
        let output = kept.keeper.stdoutFD
        let errors = kept.keeper.stderrFD
        let report = kept.reportFD
        let keeper = kept.keeper
        let lineage = spawn.lineage
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
            // `exited`가 오면 바로 알리고, 보고 pipe가 닫힐 때까지(지킴이의 끝) 읽어 `ended` 줄을 받았는지 혈통에 적는다 (15장 4)
            var status: ClaudeExitStatus?
            let sawEnded = Self.readReport(report) { line in
                if status == nil, case .exited(let code, let signal) = line {
                    status = ClaudeExitStatus(code: code, signal: signal)
                    continuation.yield(.exited(ClaudeExitStatus(code: code, signal: signal)))
                }
            }
            lineage.reportClosed(sawEnded: sawEnded)
            if status == nil {
                while ClaudeProcessInspector.check(identity) == .same { Thread.sleep(forTimeInterval: 0.1) }
                continuation.yield(.exited(ClaudeExitStatus(code: nil, signal: nil)))
            }
        }
        DispatchQueue.global(qos: .utility).async {
            lineage.keeperExited(keeper.waitForExit())
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
                    spawn.answer.end()
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

    /// 지킴이 보고를 닫힐 때까지 읽는다 (막힘): 줄마다 `each`, 닫히면 fd를 닫고 `ended` 줄을 받았는지 돌려준다 (15장 4)
    nonisolated static func readReport(_ fd: Int32, _ each: (KeeperReport) -> Void) -> Bool {
        defer { Darwin.close(fd) }
        var line = Data()
        var byte: UInt8 = 0
        var sawEnded = false
        while true {
            let count = read(fd, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count == 1 else { return sawEnded }
            guard byte == 0x0A else {
                if line.count < 256 { line.append(byte) }
                continue
            }
            if let report = KeeperReport(line: String(decoding: line, as: UTF8.self)) {
                if report == .ended { sawEnded = true }
                each(report)
            }
            line.removeAll()
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
                case .answerLost: spawn.answer.lose()
                case .closeDone: break
                }
                // 멈추기로 한 spawn의 훅은 모두 deny (8장 9)
                spawn.stopped = true
                sendInterrupt(spawn)
            case .toolRefusedBeforeHook(let refusal, let hookStarted):
                log.log("claude_tool_refused_before_hook", ["reason": .code(refusal.rawValue), "hook_started": .count(hookStarted ? 1 : 0)])
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

    /// 우리 자식에게 SIGINT (정체 확인 뒤). 그래도 끝나지 않으면 유예 뒤 고아 끝내기. 멈추기로 한 답 resume의 미전달 답은 바로 닫는다 (14장 7)
    func sendInterrupt(_ spawn: Spawn) {
        spawn.stopped = true
        spawn.answer.lose()
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
        beginSettling(spawn.agentSessionID)
        defer { endSettling(spawn.agentSessionID) }
        spawn.resultTimer?.cancel()
        spawn.exited = true
        spawn.answer.end()
        // 구성원까지 끝나야 끝이다 (8장 13 · 13장 3 · 4): 남은 구성원(책임 프로세스 = 지킴이)을 끝내고 지킴이가 구성원 0을 증명하고 스스로 끝나기를 기다린다.
        // 끝을 확정할 때까지 다시 시도한다: 그동안 이 세션의 다음 writer는 기다린다. 지킴이가 끝 기록 없이 끝났으면 다시 해도 증명할 수 없다
        // (등록부와 디스크 잠금이 남는다, 14장 1 · 풀기는 D4a)
        if let identity = spawn.identity {
            let timing = self.timing
            let lineage = spawn.lineage
            var attempt = 0
            while true {
                if case .ended = await offActor({ ClaudeProcessInspector.terminate(identity, timing: timing, lineage: lineage) }) { break }
                if lineage.keeper.map(ClaudeProcessInspector.keeperState) == .gone {
                    log.log("claude_end_unproven", ["mode": .code(spawn.modeName)])
                    spawn.endUnproven = true
                    return
                }
                if attempt == 0 { log.log("claude_group_lingering", ["mode": .code(spawn.modeName)]) }
                attempt += 1
                try? await Task.sleep(for: .seconds(min(5, attempt)))
            }
            lineage.forget()
            if let lockFile = sessionLockFile(spawn.agentSessionID) { ClaudeSessionLock.release(lockFile, spawnID: spawn.id) }
        }
        let actions = spawn.mapper.finish()
        ClaudeCodeLaunch.removeConfig(spawn.files)
        hookServer?.unregister(nonce: spawn.nonce)
        // 따라오는 내부 닫기는 끝 증명 전에 정해 등록부에 있다 (`unexpectedDeferred`, 17장 1). 없으면 끝을 증명한 지금 세션 자리를 놓고 나서 질문 · 글을 낸다
        // (17장 3: 그 사건을 받은 쪽이 같은 세션에 닫기를 띄워도 자기를 기다리지 않는다). 있으면 자기 닫기까지 마친 뒤에 놓는다 (9장 10)
        if spawn.unexpectedDeferred == nil { unregister(spawn) }
        await testHooks.afterUnregister?()
        await apply(spawn, actions)
        if let id = spawn.unexpectedDeferred, let executable = locator.locate() {
            // 기록에 없는 id가 보고됐거나 열린 요청으로 적지 못했다: 그 id를 바로 닫는다 (질문을 내지 않는다)
            // 지침은 닫기 앞에서 읽어 `close`가 등록까지 await 없이 가게 한다 (이 spawn은 닫기가 끝날 때까지 등록부에 남아 세션을 막고 있다)
            let instructions = await loadInstructions(workspace: spawn.workspace)
            await testHooks.beforeFinishClose?()
            do {
                try await close(
                    requestID: id, providerID: spawn.providerID, agentSessionID: spawn.agentSessionID, taskID: spawn.taskID, workspace: spawn.workspace, instructions: instructions,
                    executable: executable
                )
            } catch {
                log.log("claude_close_failed", [:])
            }
        }
        unregister(spawn)
        spawn.ended = true
        log.log("claude_ended", ["mode": .code(spawn.modeName), "code": .count(Int(status.code ?? -1)), "signal": .count(Int(status.signal ?? 0))])
        await spawn.sink?.emit(.ended(status.agentExit))
    }

    /// 등록부에서 내린다 (그 세션 · task의 지금 spawn이면 그 자리도)
    private func unregister(_ spawn: Spawn) {
        spawns[spawn.id] = nil
        if sessionSpawn[spawn.agentSessionID] == spawn.id { sessionSpawn[spawn.agentSessionID] = nil }
        if taskSpawn[spawn.taskID] == spawn.id { taskSpawn[spawn.taskID] = nil }
        releaseForgetIfIdle(spawn.agentSessionID)
    }

    // MARK: writer 하나

    /// 같은 세션의 앞 spawn이 끝나기를 기다린다. 넘으면 고아 끝내기. 끝(자손까지)을 증명하지 못하면 던진다: 두 번째 writer를 만들지 않는다 (8장 15).
    /// 등록부에 없으면(앱이 다시 떴다 · 띄우기가 실패했다) 디스크 잠금을 본다 (14장 1 · 2: 원장 `alive`가 아니라)
    private func waitForSessionIdle(_ sessionID: String) async throws {
        if let spawnID = sessionSpawn[sessionID], let spawn = spawns[spawnID] {
            var ended = await waitForEnd(spawn, timeout: timing.closeTimeout)
            if !ended {
                if let identity = spawn.identity { _ = await terminate(identity, lineage: spawn.lineage) }
                ended = await waitForEnd(spawn, timeout: timing.orphanKillGrace + 1)
            }
            guard ended else {
                log.log("claude_writer_unproven", ["mode": .code(spawn.modeName)])
                throw AgentStartError(.spawnFailed)
            }
        }
        var (state, spawnID) = lockState(sessionID)
        if case .alive = state, let locked = spawnID {
            // 앞 앱이 띄운 실행이 아직 돈다: 기다렸다가 넘으면 그 혈통(지킴이)으로 끝낸다
            let deadline = Date().addingTimeInterval(timing.closeTimeout)
            while case .alive = state, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
                state = lockState(sessionID).liveness
            }
            if case .alive = state {
                _ = await terminate(Self.lockedIdentity(locked), lineage: sharedLineage(locked))
                state = lockState(sessionID).liveness
            }
        }
        guard case .ended = state else {
            log.log("claude_writer_unproven", ["mode": .code("lock")])
            throw AgentStartError(.spawnFailed)
        }
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
        /// 답 resume의 답 값과 결과 (14장 7: 소켓 스레드의 시간 초과 전이도 바로 정산한다)
        let answer: AnswerSlot
        var mapper: ClaudeEventMapper
        var facts = ClaudeSpawnFacts()
        /// 답 resume의 보류 (값은 `answer`에만 둔다)
        var binding: ClaudeAnswerBinding?
        var deferIssued = false
        var answerDelivered = false
        var hookTail: Task<Void, Never>?
        var process: ClaudeSpawnedProcess?
        var identity: AgentProcessIdentity?
        var exited = false
        /// 등록부를 떠났다 (끝을 증명했거나 띄우기에 실패했다): 같은 세션의 다음 실행은 디스크 잠금을 본다
        var ended = false
        /// 끝을 증명하지 못하고 정리를 그만뒀다 (지킴이가 기록 없이 사라짐, 13장 3): 이 spawn은 등록부에 남아 세션을 막는다
        var endUnproven = false
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
            lineage: ClaudeLineage, answer: AgentAnswerValue = AgentAnswerValue()
        ) {
            self.lineage = lineage
            self.answer = AnswerSlot(answer)
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

    /// 답 resume의 답 한 번 (9장 9 · 14장 7): 값과 결과를 actor · 소켓 스레드가 같이 본다. 결과는 한 번만 정해진다. 미전달 답을 닫는 전이(Stop · 시간 초과 ·
    /// 상태 유실 · 자체 점검 실패)는 그 자리에서 값을 지우고 `.lost`를 정한다 (끝 사건 · 훅 id를 기다리지 않는다). 전달 · 끝도 값을 지운다
    final class AnswerSlot: Sendable {
        /// 결과는 둘뿐이다 (15장 2): 답을 그 훅 응답으로 확정했으면 `delivered`, 아니면 `lost`
        enum Signal: Equatable, Sendable {
            case delivered(Date)
            case lost
        }

        enum Commit: Equatable {
            /// 답 응답을 확정했다
            case delivered
            /// 이미 닫혔다: 답 대신 닫힘 응답(answers 없는 deny)을 확정했다
            case alreadyClosed
            /// 소켓이 시간 초과로 먼저 정했다 (Claude는 시간 초과 deny를 받았다)
            case timedOut
        }

        private let state: Mutex<(signal: Signal?, value: AgentAnswerValue)>

        init(_ value: AgentAnswerValue) {
            state = Mutex((nil, value))
        }

        var signal: Signal? { state.withLock { $0.signal } }
        var value: AgentAnswerValue { state.withLock { $0.value } }

        /// 아직 정해지지 않았으면 값을 지우고 `.lost` (Stop · 시간 초과 · 상태 유실). 이번에 정했으면 true
        @discardableResult
        func lose() -> Bool {
            state.withLock {
                guard $0.signal == nil else { return false }
                $0.signal = .lost
                $0.value = AgentAnswerValue()
                return true
            }
        }

        /// 보류 id 훅의 답 응답을 그 요청에 확정하면서 결과를 정한다 (15장 2: 같은 잠금 안에서). 이미 닫혔으면 답 대신 `closed`를 확정한다.
        /// 소켓이 먼저 시간 초과로 정했으면 `.lost`. 답을 확정했으면 `.delivered` · 값을 지운다
        func commitAnswer(_ response: HookResponse, closed: HookResponse, to commit: HookCommit, at date: Date) -> Commit {
            state.withLock {
                guard $0.signal == nil else { return commit.commit(closed) ? .alreadyClosed : .timedOut }
                $0.value = AgentAnswerValue()
                guard commit.commit(response) else {
                    $0.signal = .lost
                    return .timedOut
                }
                $0.signal = .delivered(date)
                return .delivered
            }
        }

        /// 소켓이 한 훅의 기한을 넘겼다 (16장 2): 그 요청을 시간 초과로 정하는 것(`HookCommit.timeOut`)과 미전달 답을 닫는 것을 이 잠금 안에서 (잠금 순서 슬롯 → 요청,
        /// `commitAnswer`와 같다). 처리기가 먼저 확정했으면 그 응답 · 닫지 않음. 시간 초과면 nil · 이번에 닫았으면 `closed`
        func timeOut(_ commit: HookCommit) -> (won: HookResponse?, closed: Bool) {
            state.withLock {
                if let response = commit.timeOut() { return (response, false) }
                guard $0.signal == nil else { return (nil, false) }
                $0.signal = .lost
                $0.value = AgentAnswerValue()
                return (nil, true)
            }
        }

        /// 프로세스가 끝났다: 아직 전달하지 않았으면 `.lost`, 값은 지운다
        func end() {
            state.withLock {
                if $0.signal == nil { $0.signal = .lost }
                $0.value = AgentAnswerValue()
            }
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
