#if os(macOS)
import AppKit
import Foundation
import TaskforceKit

/// 실제 면 (OA Settings › Your agents SA-02): 이 Mac의 런타임은 `BridgeHost`가, 서버의 판정 · 이름 · 프로젝트는 RLS 읽기와 대상 목록이 댄다.
/// 연결 · 끊기 · 다시 연결은 **런타임 함수만** 부른다 (폐기 순서 · 자격 지우기 · 가리개 · 비밀값 정리는 런타임의 몫 — 앱이 `BridgeClient`를 직접 부르지 않는다).
/// 시험 호스트 · 견본은 이 클래스를 쓰지 않는다 (가짜 면을 끼운다). 실제 `claude` · 폴더 창 · Keychain · 알림 센터는 시험에서 닿지 않는다
@MainActor
final class LiveAgentSettingsEnvironment: AgentSettingsEnvironment {
    private let host: @MainActor () -> BridgeHost?
    private let targets: AssistantTargetsStore?
    private let reads: TaskforceReads?
    private let picker: any AgentWorkspacePicking
    private let notify: @MainActor () async -> Void
    private let adapter: String

    /// - host: 지금 앱의 호스트 (bridge가 꺼진 빌드 · 시험이면 nil이거나 런타임이 없다)
    /// - targets: 대상 목록 저장소 (`ChatRuntime.targets`). 없으면 읽지 못한 것이다
    /// - reads: 서버 읽기 (RLS). 없으면 이름 · 프로젝트 · Mac 목록을 모른다
    /// - picker: 시스템 폴더 창 (`ChatRuntime.workspacePicker`와 같은 것 — 시험은 가짜 패널)
    init(
        host: @escaping @MainActor () -> BridgeHost? = { BridgeHost.shared }, targets: AssistantTargetsStore?, reads: TaskforceReads?,
        picker: any AgentWorkspacePicking, adapter: String = ClaudeCodeSupport.adapterID,
        notify: @escaping @MainActor () async -> Void = { await PushCenter.shared.requestIfNeeded(hasConnections: true) }
    ) {
        self.host = host
        self.targets = targets
        self.reads = reads
        self.picker = picker
        self.adapter = adapter
        self.notify = notify
    }

    private var runtime: BridgeRuntime? { host()?.activeAgentRuntime }

    var canRunAgents: Bool { runtime?.hasAdapter(adapter) == true }
    var runtimeStatus: BridgeStatus? { host()?.statusBoard.status }
    var runtimeHasLiveProcess: Bool { host()?.statusBoard.hasLiveProcess ?? false }

    func localBridgeID() async -> UUID? { await runtime?.localBridgeID() }

    func probe() async -> BridgeV1AdapterReport? {
        await runtime?.adapterReports().first { $0.adapter == adapter }
    }

    func refreshProbe() async -> BridgeV1AdapterReport? {
        await runtime?.refreshAdapterReports().first { $0.adapter == adapter }
    }

    func liveSince() async -> Date? { await runtime?.liveSince() }

    func deviceName(of bridgeID: UUID) async -> String? {
        guard let reads else { return nil }
        return (try? await reads.bridgeDeviceName(id: bridgeID)) ?? nil
    }

    func loadTargets() async -> AgentSettingsTargetsRead {
        guard let targets else { return .failed }
        await targets.refresh()
        switch targets.load {
        case .loaded: return .rows(targets.targets)
        case .unavailable: return .unavailable
        case .idle, .loading, .failed: return .failed
        }
    }

    func connect() async -> AgentConnectOutcome {
        guard let runtime else { return .unavailable }
        return await runtime.connectAgent(adapter)
    }

    func reconnect() async -> AgentConnectOutcome {
        // Disconnect 뒤 끝내지 못한 프로세스가 끝났으면 먼저 새 런타임으로 바꾼다
        await host()?.renewRetiredRuntimeIfIdle()
        guard let runtime else { return .unavailable }
        return await runtime.reconnectAgent(adapter)
    }

    func disconnect() async -> AgentDisconnectOutcome {
        guard let runtime, let host = host() else { return .unavailable }
        let outcome = await runtime.disconnect()
        // 서버가 폐기를 받았고 이 Mac의 정리가 끝났다: 그 런타임은 `stopSpawning`이 켜져 다시 쓰지 않는다 — 놓고 같은 파티션의 새 런타임을 만든다
        if case .disconnected = outcome { await host.renewRuntime(replacing: runtime) }
        return outcome
    }

    func removeMac(_ bridgeID: UUID) async -> AgentRemoveMacOutcome {
        guard let runtime else { return .failed(.other) }
        return await runtime.removeMac(bridgeID: bridgeID.uuidString.lowercased())
    }

    func macs() async -> [AgentMacRecord]? {
        guard let reads else { return nil }
        return try? await reads.activeBridges()
    }

    var folders: (any AgentSettingsFolderStore)? { host()?.activeWorkspaceRegistry }

    func projects() async -> [UUID: AgentFolderProject]? {
        guard let reads, let contexts = try? await reads.workContexts() else { return nil }
        return Dictionary(contexts.map { ($0.id, AgentFolderProject($0)) }, uniquingKeysWith: { first, _ in first })
    }

    var homes: [String] {
        let home = NSHomeDirectory()
        let real = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        return real == home ? [home] : [home, real]
    }

    func existingFolders(among paths: [String]) async -> Set<String> {
        await Task.detached(priority: .utility) {
            Set(paths.filter { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            })
        }.value
    }

    func pickFolder(
        message: String, prompt: String, rejection: String, accepts: @escaping @Sendable (String) -> Bool, reason: @escaping @Sendable (String) -> String
    ) async -> String? {
        await picker.pickFolder(message: message, prompt: prompt, rejection: rejection, accepts: accepts, reason: reason)
    }

    func requestNotificationPermission() async {
        await notify()
    }
}
#endif
