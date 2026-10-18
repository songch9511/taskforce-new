import Foundation
import Observation
@testable import TaskforceKit
@testable import Taskforce

/// 한 호출을 붙잡아 두는 문 (눌림 · 늦은 응답 시험): 처음 온 `wait()`가 `open()`까지 멈춘다.
/// 겹쳐 온 두 번째 호출은 기다리지 않는다: 막아야 할 호출이 새어 나가도 시험이 멈추지 않고 호출 수로 빨개진다
final class AgentTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<Void, Never>?
    private var opened = false
    private var arrivedFlag = false

    var arrived: Bool { lock.withLock { arrivedFlag } }

    func wait() async {
        let first = lock.withLock { () -> Bool in
            defer { arrivedFlag = true }
            return !arrivedFlag
        }
        guard first else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if opened { return true }
                waiter = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            opened = true
            defer { waiter = nil }
            return waiter
        }
        pending?.resume()
    }
}

/// 가짜 폴더 등록부: 규칙(받아 줄 폴더)과 쓰기 기록만 가진다. 실제 파일 · 디스크 0
final class FakeFolderStore: AgentSettingsFolderStore, @unchecked Sendable {
    private let lock = NSLock()
    private var _folders: [UUID: String]
    private var _registered: [(path: String, scope: AgentWorkspaceGate.Scope)] = []
    private var _removed: [UUID] = []
    /// 이 접두어로 시작하는 폴더만 받아 준다 (홈 아래 같은 규칙의 대역)
    var acceptedPrefixes: [String] = ["/Users/alex/"]
    var registerThrows = false
    /// true면 규칙은 통과하지만 파일을 쓰지 못한다 (거절이 아닌 쓰기 실패)
    var writeFails = false

    init(folders: [UUID: String] = [:]) {
        _folders = folders
    }

    var registered: [(path: String, scope: AgentWorkspaceGate.Scope)] { lock.withLock { _registered } }
    var removed: [UUID] { lock.withLock { _removed } }

    func projectFolders() -> [UUID: String] { lock.withLock { _folders } }

    func accepts(path: String, scope: AgentWorkspaceGate.Scope) -> Bool {
        acceptedPrefixes.contains { path.hasPrefix($0) }
    }

    func rejectionMessage(forPath path: String, scope: AgentWorkspaceGate.Scope) -> String { AgentWorkspaceCopy.rejected }

    func register(path: String, scope: AgentWorkspaceGate.Scope) throws {
        struct Rejected: Error {}
        guard !registerThrows, accepts(path: path, scope: scope) else { throw Rejected() }
        if writeFails { throw WorkspaceRegistry.RegistryError.writeFailed }
        lock.withLock {
            _registered.append((path, scope))
            if case .project(let id) = scope { _folders[id] = path }
        }
    }

    /// 시험이 등록부의 지금 폴더를 바로 정한다 (규칙을 거치지 않는다)
    func forceFolder(_ id: UUID, _ path: String) {
        lock.withLock { _folders[id] = path }
    }

    func removeFolder(forProject contextID: UUID) {
        lock.withLock {
            _removed.append(contextID)
            _folders[contextID] = nil
        }
    }
}

/// 가짜 폴더 창: 시험이 고를 폴더를 정하고, 받은 인자를 기록한다. 실제 `NSOpenPanel` 0
@MainActor
final class FakeAgentFolderPicker {
    struct Asked {
        let message: String
        let prompt: String
        let rejection: String
        let accepts: @Sendable (String) -> Bool
        let reason: @Sendable (String) -> String
    }

    var result: String?
    /// true면 진짜 창처럼 거절되는 폴더는 고를 수 없다 (nil). false면 창이 뚫려 거절 폴더가 돌아온 경우를 흉내 낸다
    var respectsAccepts = true
    private(set) var asked: [Asked] = []

    func pick(
        message: String, prompt: String, rejection: String, accepts: @escaping @Sendable (String) -> Bool, reason: @escaping @Sendable (String) -> String
    ) -> String? {
        asked.append(Asked(message: message, prompt: prompt, rejection: rejection, accepts: accepts, reason: reason))
        guard let result else { return nil }
        return respectsAccepts && !accepts(result) ? nil : result
    }
}

/// 가짜 면: 읽는 값은 시험이 정하고, 동작은 호출을 세고 정한 결과를 돌려준다. 실제 런타임 · 서버 · Keychain · 알림 센터 0
@MainActor
@Observable
final class FakeAgentSettingsEnvironment: AgentSettingsEnvironment {
    static let adapter = "agent:claude-code"

    var canRunAgents = true
    var runtimeStatus: BridgeStatus? = .connected
    var runtimeHasLiveProcess = false
    var bridge: UUID? = UUID(uuidString: "b1111111-1111-4111-8111-111111111111")
    var report: BridgeV1AdapterReport? = BridgeV1AdapterReport(adapter: adapter, installed: true, version: "2.1.241", signedIn: .yes, managedSettings: false)
    var targetsRead: AgentSettingsTargetsRead = .rows([])
    var name: String?
    var since: Date?
    var macsRead: [AgentMacRecord]? = []
    var projectsRead: [UUID: AgentFolderProject]? = [:]
    var existing: Set<String>?
    var store: FakeFolderStore?
    let picker = FakeAgentFolderPicker()
    var homes = ["/Users/alex"]

    var connectOutcome: AgentConnectOutcome = .connected
    var reconnectOutcome: AgentConnectOutcome = .connected
    var disconnectOutcome: AgentDisconnectOutcome = .disconnected(unresolvedProcesses: 0)
    var removeOutcome: AgentRemoveMacOutcome = .removed
    /// 동작 중 붙잡는 문
    var connectGate: AgentTestGate?
    var disconnectGate: AgentTestGate?
    var removeGate: AgentTestGate?
    /// 대상 목록을 읽는 동안 붙잡는 문 (읽는 중에 계정이 떠나는 경쟁)
    var targetsGate: AgentTestGate?
    /// 프로젝트를 읽는 동안 붙잡는 문 (읽는 중에 계정이 떠나는 경쟁)
    var projectsGate: AgentTestGate?
    /// 등록된 폴더가 지금 있는지 보는 동안 붙잡는 문
    var existingGate: AgentTestGate?
    /// 동작이 끝나기 전에 일어날 일 (서버가 상태를 바꾼다)
    var onConnect: (() -> Void)?
    var onReconnect: (() -> Void)?
    var onDisconnect: (() -> Void)?
    var onRemove: (() -> Void)?

    private(set) var probeCalls = 0
    private(set) var refreshProbeCalls = 0
    private(set) var targetCalls = 0
    private(set) var connectCalls = 0
    private(set) var reconnectCalls = 0
    private(set) var disconnectCalls = 0
    private(set) var removed: [UUID] = []
    private(set) var notificationCalls = 0
    private(set) var macsCalls = 0
    /// 프로젝트를 물을 때 넘긴 id들
    private(set) var projectIDsAsked: [[UUID]] = []

    init(store: FakeFolderStore? = FakeFolderStore()) {
        self.store = store
    }

    var folders: (any AgentSettingsFolderStore)? { store }

    /// 이 Mac의 Claude Code 연결 행 (T): 서버가 이 Mac의 bridge로 준 것
    func serverRow(state: AgentTargetState, access: AgentAccessLevel? = .write, deviceName: String? = nil) -> AgentSettingsTargetsRead {
        .rows([.agent(AssistantTarget.Agent(
            adapter: Self.adapter, displayName: "Claude Code", connectionID: UUID(), state: state, access: access, bridgeID: bridge, deviceName: deviceName
        ))])
    }

    func localBridgeID() async -> UUID? { bridge }
    func probe() async -> BridgeV1AdapterReport? {
        probeCalls += 1
        return report
    }

    func refreshProbe() async -> BridgeV1AdapterReport? {
        refreshProbeCalls += 1
        return report
    }

    func liveSince() async -> Date? { since }
    func deviceName(of bridgeID: UUID) async -> String? { name }

    func loadTargets() async -> AgentSettingsTargetsRead {
        targetCalls += 1
        await targetsGate?.wait()
        return targetsRead
    }

    func connect() async -> AgentConnectOutcome {
        connectCalls += 1
        await connectGate?.wait()
        onConnect?()
        return connectOutcome
    }

    func reconnect() async -> AgentConnectOutcome {
        reconnectCalls += 1
        onReconnect?()
        return reconnectOutcome
    }

    func disconnect() async -> AgentDisconnectOutcome {
        disconnectCalls += 1
        await disconnectGate?.wait()
        onDisconnect?()
        return disconnectOutcome
    }

    func removeMac(_ bridgeID: UUID) async -> AgentRemoveMacOutcome {
        removed.append(bridgeID)
        await removeGate?.wait()
        onRemove?()
        return removeOutcome
    }

    func macs() async -> [AgentMacRecord]? {
        macsCalls += 1
        return macsRead
    }

    func projects(ids: [UUID]) async -> [UUID: AgentFolderProject]? {
        projectIDsAsked.append(ids)
        await projectsGate?.wait()
        guard let projectsRead else { return nil }
        // 물은 id 중 있는 것만 돌려준다: 물은 id가 답에 없으면 "없다고 확인된" 것이다
        let asked = Set(ids)
        return projectsRead.filter { asked.contains($0.key) }
    }

    func existingFolders(among paths: [String]) async -> Set<String> {
        await existingGate?.wait()
        return existing ?? Set(paths)
    }

    func pickFolder(
        message: String, prompt: String, rejection: String, accepts: @escaping @Sendable (String) -> Bool, reason: @escaping @Sendable (String) -> String
    ) async -> String? {
        picker.pick(message: message, prompt: prompt, rejection: rejection, accepts: accepts, reason: reason)
    }

    func requestNotificationPermission() async { notificationCalls += 1 }
}
