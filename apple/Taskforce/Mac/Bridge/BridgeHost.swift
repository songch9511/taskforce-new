#if os(macOS)
import AppKit
import Foundation
import Observation
import TaskforceKit

/// 앱 수명에 하나 (OA D2b 계약 2.9 · 2.13 · 2.14). 핵심 로직은 Kit의 `BridgeRuntime`이고 이 호스트는 **연결만** 한다:
/// 계정이 바뀌면 런타임 교체 · 절전/깨어남 알림 전달 · 종료 확인 · 업데이트 재시작 막기 · 계정 삭제 정리 · `BRIDGE_ENABLED`와 마무리 모드.
/// 원장에 직접 접근하지 않는다 (판단은 서버, 기록은 런타임).
@MainActor
final class BridgeHost {
    typealias RuntimeFactory = @MainActor (
        _ partition: BridgePartition, _ mode: BridgeRuntimeConfiguration.Mode, _ secrets: LocalSecretAnswers, _ onChange: @escaping @Sendable (BridgeRuntimeSnapshot) -> Void
    ) async throws -> BridgeRuntime

    private(set) static weak var shared: BridgeHost?

    private struct Entry {
        let id: UUID
        let partition: BridgePartition
        let mode: BridgeRuntimeConfiguration.Mode
        let runtime: BridgeRuntime
        let secrets: LocalSecretAnswers
    }

    private let enabled: Bool
    private let apiBaseURL: URL
    private let storageRoot: URL
    private let credentials: any BridgeCredentialStore
    private let currentUser: @MainActor () -> UUID?
    private let epoch: @MainActor () -> Int
    private let factory: RuntimeFactory
    private let quitPrompt: any BridgeQuitPrompting
    private let reply: @MainActor (Bool) -> Void
    private let notificationCenter: NotificationCenter
    /// 앱 전체에 하나인 Claude Code 훅 소켓 (OA D3a 2.6). bridge가 켜졌을 때만 있고 앱 종료 때 닫는다. 런타임(파티션)이 바뀌어도 하나다 — nonce가 spawn을 가리킨다
    let hookServer: HookSocketServer?

    /// 파티션 id → 런타임. 계정이 떠난 뒤에도 살아 있는 턴이 있으면 남겨 둔다 (계속 감독하고 그 파티션 원장에만 기록, 네트워크 0 — Q5)
    private var entries: [String: Entry] = [:]
    private var activePartitionID: String?
    private var busyByEntry: [UUID: Bool] = [:]
    private var liveByEntry: [UUID: Bool] = [:]
    private var hasSynced = false
    private var syncedUser: UUID?
    private var syncedEpoch = 0
    /// `syncAccount`는 한 번에 하나씩 이어서 돈다 (계정 전환이 겹쳐도 런타임이 섞이지 않게)
    private var syncTail: Task<Void, Never>?
    /// 놓는 중인 런타임이 원장을 닫는 일: 같은 파티션의 새 런타임은 이것이 끝난 뒤에 원장을 연다 (한 원장에 런타임 둘이 열리지 않게)
    private var closing: [String: Task<Void, Never>] = [:]
    private var observers: [NSObjectProtocol] = []
    private var lastBusy = false

    /// 종료 확인이나 업데이트 재시작을 막아야 하나: 살아 있는 턴이 있거나 아직 전달하지 않은 비밀값 답이 있다 (런타임의 마지막 알림 값 — 동기 경로용)
    var isBusy: Bool { busyByEntry.values.contains(true) }

    /// 원장이 살아 있다고 하는 프로세스가 하나라도 있다 (턴이 `idle`이어도 남아 있을 수 있다). 종료 때 감독 밖 writer를 남기지 않기 위해 본다
    var hasLiveProcess: Bool { liveByEntry.values.contains(true) }

    /// 지금 계정의 런타임 (계정이 없거나 꺼져 있으면 nil)
    var activeRuntime: BridgeRuntime? { activePartitionID.flatMap { entries[$0]?.runtime } }

    /// D4a가 비밀값 답을 넣는 곳 (메모리에만)
    var activeSecrets: LocalSecretAnswers? { activePartitionID.flatMap { entries[$0]?.secrets } }

    var activePartition: BridgePartition? { activePartitionID.flatMap { entries[$0]?.partition } }

    var runtimeCount: Int { entries.count }

    init(
        enabled: Bool, apiBaseURL: URL, storageRoot: URL, credentials: any BridgeCredentialStore, currentUser: @escaping @MainActor () -> UUID?,
        epoch: @escaping @MainActor () -> Int = { 0 }, factory: @escaping RuntimeFactory, quitPrompt: any BridgeQuitPrompting,
        reply: @escaping @MainActor (Bool) -> Void, notificationCenter: NotificationCenter, hookServer: HookSocketServer? = nil
    ) {
        self.enabled = enabled
        self.apiBaseURL = apiBaseURL
        self.storageRoot = storageRoot
        self.credentials = credentials
        self.currentUser = currentUser
        self.epoch = epoch
        self.factory = factory
        self.quitPrompt = quitPrompt
        self.reply = reply
        self.notificationCenter = notificationCenter
        self.hookServer = hookServer
    }

    /// 앱이 시작할 때 한 번: 알림 구독 · 업데이트 재시작 정책 연결. 계정 확인은 `syncAccount`가 한다
    func start() {
        Self.shared = self
        UpdateRelaunchPolicy.isBusy = { [weak self] in self?.isBusy ?? false }
        observers = [
            notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.willSleep() }
            },
            notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.didWake() }
            },
        ]
        Task { await syncAccount() }
    }

    func stopObserving() {
        for observer in observers { notificationCenter.removeObserver(observer) }
        observers = []
        if Self.shared === self { Self.shared = nil }
        UpdateRelaunchPolicy.isBusy = { false }
        hookServer?.stop()
    }

    // MARK: 계정 (ONE-TF-09)

    /// 지금 계정에 맞는 런타임만 네트워크를 쓴다. 계정이 떠나면 멈추고(살아 있는 턴은 그 파티션 원장에만 기록), 같은 사용자가 돌아오면 같은 파티션을 잇는다.
    /// `BRIDGE_ENABLED`가 꺼졌어도 원장에 할 일이 남았으면 마무리 모드로 올린다. 꺼졌고 할 일도 없으면 런타임을 만들지 않는다 (등록 · Realtime · heartbeat · 프로세스 0).
    /// 호출은 한 번에 하나씩 이어서 돈다: 앞 호출이 끝난 뒤 자기 차례에 지금 사용자를 읽는다
    func syncAccount() async {
        let previous = syncTail
        let task = Task { @MainActor [self] in
            await previous?.value
            await performSync()
        }
        syncTail = task
        await task.value
    }

    private func performSync() async {
        var user = currentUser()
        var currentEpoch = epoch()
        if hasSynced, user == syncedUser, currentEpoch == syncedEpoch { return }
        hasSynced = true
        await retireActive()
        // 멈추는 동안 계정이 또 바뀌었을 수 있다: 지금 값을 다시 읽는다
        user = currentUser()
        currentEpoch = epoch()
        syncedUser = user
        syncedEpoch = currentEpoch
        guard let user else { return }
        let partition = BridgePartition(apiBaseURL: apiBaseURL, userID: user)
        await closing[partition.id]?.value // 놓는 중인 옛 런타임이 원장을 닫은 뒤에 연다
        if let existing = entries[partition.id] {
            // 떠났다가 돌아온 같은 계정: 남아 있는 런타임을 이어 쓴다 (같은 원장에 연결을 둘 만들지 않는다)
            activePartitionID = partition.id
            await existing.runtime.resume()
            return
        }
        let mode: BridgeRuntimeConfiguration.Mode
        if enabled {
            mode = .normal
        } else if await BridgeStorage.hasPendingWork(partition: partition, root: storageRoot) {
            mode = .drain
        } else {
            return
        }
        let secrets = LocalSecretAnswers()
        let entryID = UUID()
        let runtime: BridgeRuntime
        do {
            runtime = try await factory(partition, mode, secrets) { [weak self] snapshot in
                Task { @MainActor in self?.runtimeChanged(entryID, snapshot) }
            }
        } catch {
            return
        }
        // 원장을 여는 동안 계정이 바뀌었으면 이 런타임은 쓰지 않는다 (다음 sync가 맞춘다)
        guard currentUser() == user, epoch() == currentEpoch else {
            await runtime.close()
            hasSynced = false
            return
        }
        let entry = Entry(id: entryID, partition: partition, mode: mode, runtime: runtime, secrets: secrets)
        entries[partition.id] = entry
        activePartitionID = partition.id
        await runtime.start()
    }

    /// 지금 계정의 네트워크를 멈춘다. 바쁘지도 살아 있는 프로세스도 없으면 원장도 닫고 버린다
    private func retireActive() async {
        guard let id = activePartitionID, let entry = entries[id] else {
            activePartitionID = nil
            return
        }
        activePartitionID = nil
        await entry.runtime.stop()
        await release(entry)
    }

    #if DEBUG
    /// 시험 전용 (Release에는 없다): `release`가 첫 확인을 마친 직후 끼어든다. 놓는 도중 같은 계정이 돌아오는 경쟁을 결정적으로 만든다
    var releaseHook: (@MainActor () async -> Void)?
    #endif

    /// 놓아도 되나: 런타임이 멈춰 있고, 그 파티션이 다시 활성이 아니거나(떠난 계정) 마무리 모드일 때만
    static func mayRelease(status: BridgeStatus, partitionIsActive: Bool, drain: Bool) -> Bool {
        status == .stopped && (!partitionIsActive || drain)
    }

    /// 런타임을 놓는다. 알림 값은 늦게 도착한 옛 값일 수 있으므로 놓기 직전에 런타임에 직접 다시 묻는다.
    /// 그 사이 같은 계정이 돌아와 런타임이 다시 켜졌을 수 있다(`performSync` → `resume`): 멈춰 있고, 그 파티션이 다시 활성이 아니거나 마무리 모드일 때만 놓는다 (검토 반영 2 8장 4).
    /// 마지막 확인과 목록에서 빼는 일은 `await` 없이 이어진다: 이후 같은 계정이 돌아오면 새 런타임을 만들고, 원장은 이 런타임이 닫힌 뒤에 연다 (`closing`)
    private func release(_ entry: Entry) async {
        guard await !entry.runtime.isBusy(), await !entry.runtime.hasLiveProcess() else { return }
        #if DEBUG
        await releaseHook?()
        #endif
        guard await Self.mayRelease(status: entry.runtime.status, partitionIsActive: activePartitionID == entry.partition.id, drain: entry.mode == .drain) else { return }
        // 같은 파티션에 새 세대가 이미 올라와 있으면 그 항목은 건드리지 않는다
        if entries[entry.partition.id]?.id == entry.id {
            entries[entry.partition.id] = nil
            if activePartitionID == entry.partition.id { activePartitionID = nil }
        }
        busyByEntry[entry.id] = nil
        liveByEntry[entry.id] = nil
        let closeTask = Task { await entry.runtime.close() }
        closing[entry.partition.id] = closeTask
        await closeTask.value
        if closing[entry.partition.id] == closeTask { closing[entry.partition.id] = nil }
        notifyBusyIfChanged()
    }

    private func runtimeChanged(_ id: UUID, _ snapshot: BridgeRuntimeSnapshot) {
        guard let entry = entries.values.first(where: { $0.id == id }) else { return }
        busyByEntry[id] = snapshot.isBusy
        liveByEntry[id] = snapshot.hasLiveProcess
        notifyBusyIfChanged()
        // 떠난 계정의 마지막 턴이 끝났거나 · 마무리 모드가 할 일을 모두 끝내 멈췄다: 원장을 닫고 놓는다
        if !snapshot.isBusy, snapshot.status == .stopped, entry.partition.id != activePartitionID || entry.mode == .drain {
            Task { await release(entry) }
        }
    }

    private func notifyBusyIfChanged() {
        let busy = isBusy
        guard busy != lastBusy else { return }
        lastBusy = busy
        UpdateRelaunchPolicy.busyChanged(busy)
    }

    // MARK: 절전 · 깨어남

    func willSleep() async {
        for entry in entries.values { await entry.runtime.prepareForSleep() }
    }

    func didWake() async {
        for entry in entries.values where entry.partition.id == activePartitionID { await entry.runtime.didWake() }
    }

    // MARK: 종료 확인 (ONE-TF-15 a · Q7 · Q8)

    /// `applicationShouldTerminate`: 살아 있는 프로세스도 없으면 바로 종료, 바쁘면 확인 창. Quit → 살아 있는 턴 중단(신호를 무시하면 유예 뒤 강제로 끝냄) · `cancelled` 사건 · outbox 비우기(최대 3초) 뒤 종료,
    /// Cancel → 상태 변화 0. 턴은 끝났는데(`idle`) 프로세스가 남아 있으면 확인 창 없이 조용히 끝내고 종료한다 (감독 밖 writer를 남기지 않는다)
    func terminationReply() -> NSApplication.TerminateReply {
        guard isBusy || hasLiveProcess else {
            hookServer?.stop()
            return .terminateNow
        }
        let needsConfirmation = isBusy
        Task { @MainActor in
            if needsConfirmation {
                guard await quitPrompt.confirmQuit() else {
                    reply(false)
                    return
                }
            }
            for entry in entries.values { await entry.runtime.shutdown(interrupt: true) }
            hookServer?.stop()
            reply(true)
        }
        return .terminateLater
    }

    // MARK: 계정 삭제 (Q22)

    /// `AccountDeletion.delete`가 서버 삭제 성공 뒤 부른다 (`removeSavedData`와 같은 자리). 호스트가 없으면(설정 오류) 할 일이 없다
    static func removeSavedBridgeData(for userID: UUID) {
        guard let host = shared else { return }
        Task {
            let result = await host.accountDeleted(userID: userID)
            if !result.isComplete {
                BridgeOSLog().log("account_cleanup_incomplete", [
                    "folder": .count(result.folderRemoved ? 1 : 0), "credentials": .count(result.credentialsRemoved ? 1 : 0), "processes": .count(result.unterminatedProcesses),
                ])
            }
        }
    }

    /// 계정 삭제 성공: 살아 있는 턴을 중단하고 (신호를 무시하면 유예 뒤 강제로 끝내고, 감독 밖 프로세스도 끝낸다) 원장을 닫은 **뒤에** 그 파티션의 원장 폴더 · Keychain 항목을 지우고 결과를 돌려준다
    @discardableResult
    func accountDeleted(userID: UUID) async -> BridgeStorage.CleanupResult {
        let partition = BridgePartition(apiBaseURL: apiBaseURL, userID: userID)
        var unterminated = 0
        if let entry = entries[partition.id] {
            unterminated = await entry.runtime.interruptLiveTurns()
            await entry.runtime.stop()
            await entry.runtime.close()
            entries[partition.id] = nil
            busyByEntry[entry.id] = nil
            liveByEntry[entry.id] = nil
            if activePartitionID == partition.id { activePartitionID = nil }
            notifyBusyIfChanged()
        }
        return await BridgeStorage.deletePartition(partition, root: storageRoot, credentials: credentials, unterminatedProcesses: unterminated)
    }

    // MARK: 앱 연결

    /// 이 빌드 · 실행이 쓸 adapter (OA D3a 2.17): Release는 인자와 상관없이 실제 Claude Code adapter 하나(`BRIDGE_ENABLED`가 NO면 런타임을 만들지 않아 뜨지 않는다).
    /// Debug는 `-TF_BRIDGE_FAKE_AGENT YES`면 가짜, `-TF_BRIDGE_REAL_AGENT YES`면 실제 adapter + 일회용 작업 폴더, 둘 다 아니면 없음 (둘 다 loopback 서버에서만)
    enum AgentChoice: Equatable {
        case none
        case fake
        case claudeCode(disposableWorkspace: String?)
    }

    static func agentChoice(isDebugBuild: Bool, arguments: [String: Any], apiBaseURL: URL) -> AgentChoice {
        guard isDebugBuild else { return .claudeCode(disposableWorkspace: nil) }
        if BridgeFlag.usesFakeAgent(arguments: arguments, isDebugBuild: true, apiBaseURL: apiBaseURL) { return .fake }
        if BridgeFlag.usesRealAgent(arguments: arguments, isDebugBuild: true, apiBaseURL: apiBaseURL) {
            return .claudeCode(disposableWorkspace: BridgeFlag.disposableWorkspace(arguments: arguments, isDebugBuild: true))
        }
        return .none
    }

    /// bridge가 켜졌을 때만 소켓을 연다 (꺼진 빌드는 소켓 파일 0). 열지 못하면 nil (Claude Code 새 턴은 `spawn_failed`)
    static func startHookServer(enabled: Bool, path: String, log: any BridgeLogSink) -> HookSocketServer? {
        guard enabled else { return nil }
        let server = HookSocketServer(path: path, log: log)
        do {
            try server.start()
            return server
        } catch {
            log.log("hook_socket_failed", [:])
            return nil
        }
    }

    /// 실제 앱 연결: 세션 · 서비스로 호스트를 만든다. 시험 호스트에서는 부르지 않는다 (`MacAppDelegate.applicationDidFinishLaunching`의 가드 뒤)
    static func live(session: SessionStore, services: AppServices) -> BridgeHost? {
        guard let bundleID = Bundle.main.bundleIdentifier, let root = BridgeStorage.defaultRoot(bundleID: bundleID),
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let scope = AccountScope()
        scope.bind(to: session)
        let credentials = KeychainBridgeCredentialStore(accessGroup: BridgeFlag.keychainAccessGroup)
        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).map { String($0.prefix(50)) } ?? "0.0.0"
        let enabled = BridgeFlag.current
        let hookServer = startHookServer(enabled: enabled, path: HookSocketServer.socketPath(applicationSupport: support, bundleID: bundleID), log: BridgeOSLog())
        let choice = agentChoice(isDebugBuild: AppRuntime.isDebugBuild, arguments: BridgeFlag.currentArguments, apiBaseURL: services.api.baseURL)
        let host = BridgeHost(
            enabled: enabled, apiBaseURL: services.api.baseURL, storageRoot: root, credentials: credentials,
            currentUser: { if case .signedIn(let userID, _) = session.state { userID } else { nil } }, epoch: { scope.epoch },
            factory: { partition, mode, secrets, onChange in
                // 원장 열기(디스크 · quick_check)는 메인 스레드 밖에서 한다
                let ledger = try await BridgeLedger.open(directory: partition.directory(in: root))
                let client = BridgeClient(
                    baseURL: services.api.baseURL, session: TaskforceClient.urlSession, expectedUserID: partition.userID, bearer: BridgeAppSupport.bearer(services.supabase)
                )
                let adapters: [any AgentProcess]
                let workspaces: (any WorkspaceResolver)?
                switch choice {
                case .none:
                    adapters = []
                    workspaces = nil
                case .claudeCode(let disposable):
                    // 세션 폴더는 파티션 아래 (계정 삭제가 파티션째 지운다). init은 부수 효과 0: probe · 폴더 만들기는 런타임이 부를 때만
                    adapters = [ClaudeCodeProcess(
                        sessionsRoot: partition.directory(in: root).appending(path: "claude-code", directoryHint: .isDirectory), hookServer: hookServer,
                        helpers: .inBundle(), locator: .standard(home: NSHomeDirectory()), log: BridgeOSLog()
                    )]
                    #if DEBUG
                    // R2 확인용 일회용 폴더 (Q14). 실제 폴더 고르기는 D4a 몫이라 Release는 resolver가 없다 (새 세션 `spawn_failed`)
                    workspaces = DisposableWorkspaces.make(path: disposable, apiBaseURL: services.api.baseURL, home: NSHomeDirectory())
                    #else
                    _ = disposable
                    workspaces = nil
                    #endif
                case .fake:
                    #if DEBUG
                    // 격리 Debug 실행에서만 가짜 agent (`-TF_BRIDGE_FAKE_AGENT YES`, 서버 주소가 loopback일 때만). 작업 폴더는 가짜 값
                    adapters = [FakeAgentProcess()]
                    workspaces = FakeBridgeWorkspaces()
                    #else
                    adapters = []
                    workspaces = nil
                    #endif
                }
                return BridgeRuntime(
                    configuration: BridgeRuntimeConfiguration(partition: partition, appVersion: appVersion, mode: mode, heartbeatJitterSeconds: 2), client: client, ledger: ledger,
                    credentials: credentials, adapters: adapters, wake: SupabaseBridgeWake(supabase: services.supabase), secrets: secrets, workspaces: workspaces,
                    sessionStillValid: BridgeAppSupport.sessionStillValid(services.supabase), log: BridgeOSLog(), onChange: onChange
                )
            },
            quitPrompt: BridgeQuitAlert(), reply: { NSApplication.shared.reply(toApplicationShouldTerminate: $0) }, notificationCenter: NSWorkspace.shared.notificationCenter,
            hookServer: hookServer
        )
        scope.onLeft { Task { await host.syncAccount() } }
        host.follow(session)
        return host
    }

    #if DEBUG
    private struct FakeBridgeWorkspaces: WorkspaceResolver {
        func workspace(forSession sessionID: String, adapter: String) async -> String? { "workspace-fake" }

        func authorize(workspaceRef: String, session sessionID: String, adapter: String) async -> Bool { workspaceRef == "workspace-fake" }
    }
    #endif

    /// 로그인 · 로그아웃 · 계정 전환을 따라간다 (`MacAppDelegate.follow`와 같은 방식)
    private func follow(_ session: SessionStore) {
        withObservationTracking {
            _ = session.state
        } onChange: { [weak self, weak session] in
            Task { @MainActor in
                guard let self, let session else { return }
                await self.syncAccount()
                self.follow(session)
            }
        }
    }
}
#endif
