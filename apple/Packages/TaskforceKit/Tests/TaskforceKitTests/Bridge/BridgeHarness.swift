#if os(macOS) && DEBUG
import Foundation
@testable import TaskforceKit

/// 로그를 모아 두는 싱크 (K14: 글 · secret · device_id · 경로가 로그에 0인지 본다)
final class CapturingLog: BridgeLogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(String, [String: BridgeLogValue])] = []

    func log(_ event: String, _ fields: [String: BridgeLogValue]) {
        lock.withLock { entries.append((event, fields)) }
    }

    var lines: [String] {
        lock.withLock { entries.map { event, fields in event + " " + fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ") } }
    }

    var events: [String] { lock.withLock { entries.map(\.0) } }
}

/// 가짜 서버 · 가짜 agent · 수동 시계 · 임시 원장으로 런타임 하나를 세운다 (계약 6.3 시험 격리: 실제 Application Support · Keychain 0, 네트워크는 가짜 서버만)
final class BridgeHarness: @unchecked Sendable {
    static let sessionID = "5e551011-0000-4000-8000-000000000001"

    let clock: ManualBridgeClock
    let server: FakeBridgeServer
    let userID: UUID
    let token: String
    let temp = TempDirectory()
    let partition: BridgePartition
    let credentials: InMemoryBridgeCredentialStore
    let agent: FakeAgentProcess
    let secrets = LocalSecretAnswers()
    let log = CapturingLog()
    let wake: FakeBridgeWake?
    var workspaces: WorkspaceResolver?
    /// 사용자 세션이 아직 살아 있나 (401 뒤 확인, `SessionStore`의 판단 대역)
    let sessionValid = Locked<Bool>(true)
    /// 토큰 공급이 다른 사용자의 토큰을 주는 경쟁을 흉내 낸다 (ONE-TF-09 c)
    let bearerUser = Locked<UUID?>(nil)
    private(set) var ledger: BridgeLedger
    private(set) var runtime: BridgeRuntime
    private let mode: BridgeRuntimeConfiguration.Mode
    private let jitter: Double
    /// 표시용 Mac 이름의 원천 (OA F1m): nil이면 이름을 보내지 않는다
    private let deviceName: (@Sendable () -> String?)?

    init(
        agent: FakeAgentProcess? = nil, mode: BridgeRuntimeConfiguration.Mode = .normal, wake: FakeBridgeWake? = nil, userID: UUID = UUID(),
        server: FakeBridgeServer? = nil, withAdapter: Bool = true, workspace: String? = "workspace-test", jitter: Double = 0, serverClockOffset: TimeInterval = 0,
        deviceName: (@Sendable () -> String?)? = nil, credentials: InMemoryBridgeCredentialStore? = nil
    ) throws {
        self.jitter = jitter
        self.deviceName = deviceName
        let clock = ManualBridgeClock()
        self.clock = clock
        let server = server ?? FakeBridgeServer(clock: { clock.now.addingTimeInterval(serverClockOffset) })
        self.server = server
        self.userID = userID
        let token = "token-\(userID.uuidString.lowercased())"
        self.token = token
        server.addUser(token: token, userID: userID)
        let partition = BridgePartition(apiBaseURL: server.baseURL, userID: userID)
        self.partition = partition
        let agent = agent ?? FakeAgentProcess(clock: clock.clock)
        self.agent = agent
        self.wake = wake
        self.mode = mode
        let store = credentials ?? InMemoryBridgeCredentialStore()
        self.credentials = store
        let resolver = workspace.map { FixedWorkspace(path: $0) }
        self.workspaces = resolver
        let directory = partition.directory(in: temp.url)
        let ledger = try BridgeLedger(directory: directory, now: { clock.now })
        self.ledger = ledger
        runtime = BridgeHarness.makeRuntime(
            server, userID, token, partition, ledger, store, withAdapter ? [agent] : [], clock, wake, secrets, resolver, log, mode, jitter, sessionValid, bearerUser,
            deviceName
        )
    }

    deinit {
        agent.killEverything()
    }

    private static func makeRuntime(
        _ server: FakeBridgeServer, _ userID: UUID, _ token: String, _ partition: BridgePartition, _ ledger: BridgeLedger, _ credentials: InMemoryBridgeCredentialStore,
        _ adapters: [any AgentProcess], _ clock: ManualBridgeClock, _ wake: FakeBridgeWake?, _ secrets: LocalSecretAnswers, _ workspaces: WorkspaceResolver?,
        _ log: CapturingLog, _ mode: BridgeRuntimeConfiguration.Mode, _ jitter: Double, _ sessionValid: Locked<Bool>, _ bearerUser: Locked<UUID?>,
        _ deviceName: (@Sendable () -> String?)?
    ) -> BridgeRuntime {
        let client = BridgeClient(
            baseURL: server.baseURL, session: server.makeSession(), expectedUserID: userID, bearer: { BridgeBearer(userID: bearerUser.get() ?? userID, accessToken: token) }
        )
        return BridgeRuntime(
            configuration: BridgeRuntimeConfiguration(partition: partition, appVersion: "0.2.0-test", mode: mode, heartbeatJitterSeconds: jitter, deviceName: deviceName), client: client, ledger: ledger,
            credentials: credentials, adapters: adapters, clock: clock.clock, wake: wake, secrets: secrets, workspaces: workspaces,
            sessionStillValid: { sessionValid.get() }, log: log
        )
    }

    /// 같은 파티션으로 새 런타임을 만든다 (앱 재시작 흉내). 원장은 파일을 다시 열고, 자격은 그대로다
    func restart(adapters: [any AgentProcess]? = nil, mode: BridgeRuntimeConfiguration.Mode? = nil, reopenLedger: Bool = true, wake: FakeBridgeWake? = nil) async throws {
        if reopenLedger {
            await ledger.close()
            let clock = self.clock
            ledger = try BridgeLedger(directory: partition.directory(in: temp.url), now: { clock.now })
        }
        runtime = BridgeHarness.makeRuntime(
            server, userID, token, partition, ledger, credentials, adapters ?? [agent], clock, wake ?? self.wake, secrets, workspaces, log, mode ?? self.mode, jitter,
            sessionValid, bearerUser, deviceName
        )
    }

    /// 원장 파일을 지운다 (손실 · 격리 흉내, ONE-TF-04 e). 새 런타임은 `restart`로 만든다
    func wipeLedger() async throws {
        await ledger.close()
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: ledger.fileURL.path + suffix))
        }
    }

    // MARK: 도우미

    var bridgeID: String { server.bridgeID(userID: userID) ?? "" }

    /// 등록을 거쳐 bridge가 서버에 생기게 한다 (첫 tick: 등록 → heartbeat → 목록)
    func registerFirst() async {
        await runtime.tick()
    }

    @discardableResult
    func message(
        _ text: String = "Please summarize.", session: String = BridgeHarness.sessionID, task: String = UUID().uuidString.lowercased(), turn: Int = 1,
        closeBefore: String? = nil, extra: [String: Any] = [:]
    ) -> FakeBridgeServer.Created {
        server.enqueueMessage(bridgeID: bridgeID, sessionID: session, taskID: task, turnSeq: turn, text: text, closeBefore: closeBefore, extra: extra)
    }

    /// 조건이 맞을 때까지 실제 시간으로 기다린다 (비동기로 도는 대본 · 사건 때문에)
    @discardableResult
    func eventually(timeout: TimeInterval = 8, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    /// 조건이 맞을 때까지 outbox를 계속 비운다 (대본 사건이 비동기로 쌓이므로 한 번 비우고 끝내지 않는다)
    func settle(timeout: TimeInterval = 8, until condition: () async -> Bool = { true }) async {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            await runtime.flushOutbox()
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        } while Date() < deadline
    }

    /// 서버에 보낼 사건을 원장에 직접 쌓는다 (요청 한도 · 묶음 시험용). 서버는 이 세션을 모르므로 최종 `not_found`로 지운다
    func seedEvents(count: Int, task taskID: String = "7a5c0001-0000-4000-8000-0000000000e1", session: String = BridgeHarness.sessionID, text: String? = nil) async throws {
        if try await ledger.task(taskID) == nil { try await ledger.saveTask(BridgeTest.task(taskID, session: session, at: clock.now)) }
        for _ in 0..<count {
            _ = try await ledger.appendEvent(
                taskID: taskID, numbering: .taskSequence,
                build: { seq, eventID in
                    let body: BridgeV1Event.Body = text.map { .message(text: $0) } ?? .progress
                    let event = BridgeV1Event(adapter: "agent:claude-code", sessionID: session, taskID: taskID, externalTaskID: nil, eventID: eventID, seq: seq, turnSeq: 1, observedAt: BridgeTest.t0, body: body)
                    return BuiltEvent(type: event.typeName, json: String(decoding: try TaskforceJSON.encoder().encode(event), as: UTF8.self), observedAt: BridgeTest.t0)
                },
                update: { _ in }
            )
        }
    }

    func command(_ id: String) async -> BridgeCommandRecord? { try? await ledger.command(id) }
    func task(_ id: String) async -> BridgeTaskRecord? { try? await ledger.task(id) }

    func routes() -> [String] { server.requests.map(\.route) }

    /// 원장 파일(DB · WAL · SHM) 바이트에 글이 있는가
    func diskContains(_ needle: String) -> Bool {
        BridgeTest.diskBytesContain(needle, in: ledger.directory)
    }
}

struct FixedWorkspace: WorkspaceResolver {
    let path: String
    /// 이 Mac이 만든 값으로 인정하는 폴더들 (가짜 agent가 `session_bound`로 알리는 `workspace-fake` 포함)
    var authorized: Set<String> = ["workspace-fake"]

    func workspace(forSession sessionID: String, adapter: String) async -> String? { path }

    func authorize(workspaceRef: String, session sessionID: String, adapter: String) async -> Bool {
        workspaceRef == path || authorized.contains(workspaceRef)
    }
}

struct NoWorkspace: WorkspaceResolver {
    func workspace(forSession sessionID: String, adapter: String) async -> String? { nil }
}
#endif
