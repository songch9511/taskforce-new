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
    ) throws -> BridgeRuntime

    private(set) static weak var shared: BridgeHost?

    private struct Entry {
        let id: UUID
        let partition: BridgePartition
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

    /// 파티션 id → 런타임. 계정이 떠난 뒤에도 살아 있는 턴이 있으면 남겨 둔다 (계속 감독하고 그 파티션 원장에만 기록, 네트워크 0 — Q5)
    private var entries: [String: Entry] = [:]
    private var activePartitionID: String?
    private var busyByEntry: [UUID: Bool] = [:]
    private var hasSynced = false
    private var syncedUser: UUID?
    private var syncedEpoch = 0
    private var observers: [NSObjectProtocol] = []
    private var lastBusy = false

    /// 종료 확인이나 업데이트 재시작을 막아야 하나: 살아 있는 턴이 있거나 아직 전달하지 않은 비밀값 답이 있다
    var isBusy: Bool { busyByEntry.values.contains(true) }

    /// 지금 계정의 런타임 (계정이 없거나 꺼져 있으면 nil)
    var activeRuntime: BridgeRuntime? { activePartitionID.flatMap { entries[$0]?.runtime } }

    /// D4a가 비밀값 답을 넣는 곳 (메모리에만)
    var activeSecrets: LocalSecretAnswers? { activePartitionID.flatMap { entries[$0]?.secrets } }

    var activePartition: BridgePartition? { activePartitionID.flatMap { entries[$0]?.partition } }

    var runtimeCount: Int { entries.count }

    init(
        enabled: Bool, apiBaseURL: URL, storageRoot: URL, credentials: any BridgeCredentialStore, currentUser: @escaping @MainActor () -> UUID?,
        epoch: @escaping @MainActor () -> Int = { 0 }, factory: @escaping RuntimeFactory, quitPrompt: any BridgeQuitPrompting,
        reply: @escaping @MainActor (Bool) -> Void, notificationCenter: NotificationCenter
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
    }

    // MARK: 계정 (ONE-TF-09)

    /// 지금 계정에 맞는 런타임만 네트워크를 쓴다. 계정이 떠나면 멈추고(살아 있는 턴은 그 파티션 원장에만 기록), 같은 사용자가 돌아오면 같은 파티션을 잇는다.
    /// `BRIDGE_ENABLED`가 꺼졌어도 원장에 할 일이 남았으면 마무리 모드로 올린다. 꺼졌고 할 일도 없으면 런타임을 만들지 않는다 (등록 · Realtime · heartbeat · 프로세스 0)
    func syncAccount() async {
        let user = currentUser()
        let currentEpoch = epoch()
        if hasSynced, user == syncedUser, currentEpoch == syncedEpoch { return }
        hasSynced = true
        syncedUser = user
        syncedEpoch = currentEpoch
        await retireActive()
        guard let user else { return }
        let partition = BridgePartition(apiBaseURL: apiBaseURL, userID: user)
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
            runtime = try factory(partition, mode, secrets) { [weak self] snapshot in
                Task { @MainActor in self?.runtimeChanged(entryID, snapshot) }
            }
        } catch {
            return
        }
        let entry = Entry(id: entryID, partition: partition, runtime: runtime, secrets: secrets)
        entries[partition.id] = entry
        activePartitionID = partition.id
        await runtime.start()
    }

    /// 지금 계정의 네트워크를 멈춘다. 살아 있는 턴이 없으면 원장도 닫고 버린다
    private func retireActive() async {
        guard let id = activePartitionID, let entry = entries[id] else {
            activePartitionID = nil
            return
        }
        activePartitionID = nil
        await entry.runtime.stop()
        if busyByEntry[entry.id] != true { await release(entry) }
    }

    private func release(_ entry: Entry) async {
        await entry.runtime.close()
        // 같은 파티션에 새 세대가 이미 올라와 있으면 그 항목은 건드리지 않는다
        if entries[entry.partition.id]?.id == entry.id { entries[entry.partition.id] = nil }
        busyByEntry[entry.id] = nil
        notifyBusyIfChanged()
    }

    private func runtimeChanged(_ id: UUID, _ snapshot: BridgeRuntimeSnapshot) {
        guard let entry = entries.values.first(where: { $0.id == id }) else { return }
        busyByEntry[id] = snapshot.isBusy
        notifyBusyIfChanged()
        // 떠난 계정의 마지막 턴이 끝났다: 원장을 닫고 버린다
        if !snapshot.isBusy, entry.partition.id != activePartitionID, snapshot.status == .stopped {
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

    /// `applicationShouldTerminate`: 바쁘지 않으면 바로 종료, 바쁘면 확인 창. Quit → 살아 있는 턴 중단 · `cancelled` 사건 · outbox 비우기(최대 3초) 뒤 종료, Cancel → 상태 변화 0
    func terminationReply() -> NSApplication.TerminateReply {
        guard isBusy else { return .terminateNow }
        Task { @MainActor in
            guard await quitPrompt.confirmQuit() else {
                reply(false)
                return
            }
            for entry in entries.values { await entry.runtime.shutdown(interrupt: true) }
            reply(true)
        }
        return .terminateLater
    }

    // MARK: 계정 삭제 (Q22)

    /// `AccountDeletion.delete`가 서버 삭제 성공 뒤 부른다 (`removeSavedData`와 같은 자리). 호스트가 없으면(설정 오류) 할 일이 없다
    static func removeSavedBridgeData(for userID: UUID) {
        guard let host = shared else { return }
        Task { await host.accountDeleted(userID: userID) }
    }

    /// 계정 삭제 성공: 살아 있는 턴을 중단하고 그 파티션의 원장 폴더 · Keychain 항목을 지운다
    func accountDeleted(userID: UUID) async {
        let partition = BridgePartition(apiBaseURL: apiBaseURL, userID: userID)
        if let entry = entries[partition.id] {
            await entry.runtime.interruptLiveTurns()
            await entry.runtime.stop()
            await entry.runtime.close()
            entries[partition.id] = nil
            busyByEntry[entry.id] = nil
            if activePartitionID == partition.id { activePartitionID = nil }
            notifyBusyIfChanged()
        }
        BridgeStorage.deletePartition(partition, root: storageRoot, credentials: credentials)
    }

    // MARK: 앱 연결

    /// 실제 앱 연결: 세션 · 서비스로 호스트를 만든다. 시험 호스트에서는 부르지 않는다 (`MacAppDelegate.applicationDidFinishLaunching`의 가드 뒤)
    static func live(session: SessionStore, services: AppServices) -> BridgeHost? {
        guard let bundleID = Bundle.main.bundleIdentifier, let root = BridgeStorage.defaultRoot(bundleID: bundleID) else { return nil }
        let scope = AccountScope()
        scope.bind(to: session)
        let credentials = KeychainBridgeCredentialStore()
        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).map { String($0.prefix(50)) } ?? "0.0.0"
        let host = BridgeHost(
            enabled: BridgeFlag.current, apiBaseURL: services.api.baseURL, storageRoot: root, credentials: credentials,
            currentUser: { if case .signedIn(let userID, _) = session.state { userID } else { nil } }, epoch: { scope.epoch },
            factory: { partition, mode, secrets, onChange in
                let ledger = try BridgeLedger(directory: partition.directory(in: root))
                let client = BridgeClient(
                    baseURL: services.api.baseURL, session: TaskforceClient.urlSession, expectedUserID: partition.userID, bearer: BridgeAppSupport.bearer(services.supabase)
                )
                #if DEBUG
                // 실제 agent(D3a · D3b)가 들어오기 전: 격리 Debug 실행에서만 가짜 agent (`-TF_BRIDGE_FAKE_AGENT YES`). 작업 폴더는 D4a가 정하기 전까지 가짜 값
                let fake = BridgeFlag.currentUsesFakeAgent
                let adapters: [any AgentProcess] = fake ? [FakeAgentProcess()] : []
                let workspaces: (any WorkspaceResolver)? = fake ? FakeBridgeWorkspaces() : nil
                #else
                let adapters: [any AgentProcess] = []
                let workspaces: (any WorkspaceResolver)? = nil
                #endif
                return BridgeRuntime(
                    configuration: BridgeRuntimeConfiguration(partition: partition, appVersion: appVersion, mode: mode, heartbeatJitterSeconds: 2), client: client, ledger: ledger,
                    credentials: credentials, adapters: adapters, wake: SupabaseBridgeWake(supabase: services.supabase), secrets: secrets, workspaces: workspaces,
                    sessionStillValid: BridgeAppSupport.sessionStillValid(services.supabase), log: BridgeOSLog(), onChange: onChange
                )
            },
            quitPrompt: BridgeQuitAlert(), reply: { NSApplication.shared.reply(toApplicationShouldTerminate: $0) }, notificationCenter: NSWorkspace.shared.notificationCenter
        )
        scope.onLeft { Task { await host.syncAccount() } }
        host.follow(session)
        return host
    }

    #if DEBUG
    private struct FakeBridgeWorkspaces: WorkspaceResolver {
        func workspace(forSession sessionID: String, adapter: String) async -> String? { "workspace-fake" }
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
