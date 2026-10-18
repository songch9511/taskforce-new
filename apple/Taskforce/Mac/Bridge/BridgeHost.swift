#if os(macOS)
import AppKit
import Foundation
import Observation
import TaskforceKit

/// 지금 계정 런타임의 상태 · 살아 있는 실행 (OA Settings › Your agents SA-02): Settings 화면이 관찰하는 값이다.
/// 호스트가 런타임의 알림(`onChange`)을 이어 주고, 계정이 떠나거나 런타임이 바뀌는 사이에는 비운다 (모르는 값을 주장하지 않는다)
@MainActor
@Observable
final class BridgeStatusBoard {
    private(set) var status: BridgeStatus?
    private(set) var hasLiveProcess = false

    func apply(_ snapshot: BridgeRuntimeSnapshot) {
        status = snapshot.status
        hasLiveProcess = snapshot.hasLiveProcess
    }

    func clear() {
        status = nil
        hasLiveProcess = false
    }
}

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
    /// 프로젝트마다의 작업 폴더 등록부 · resolver (OA D4a2). bridge가 꺼진 빌드 · 시험 호스트는 nil
    let workspaces: ProjectWorkspaces?
    /// Debug 전용 (OA D4a2-10): 런타임을 시작한 직후 이 adapter로 `connect`를 한 번 부른다. Release는 늘 nil
    private let connectAtStart: String?
    /// `Open in Terminal`의 `.command` 파일을 두는 폴더: 계정 삭제가 안의 파일을 지운다 (보안 F4). 없으면 지우지 않는다
    private let terminalDirectory: URL?

    /// 지금 계정 런타임의 상태 (Settings가 관찰한다)
    let statusBoard = BridgeStatusBoard()
    /// Settings의 Disconnect가 끝났는데 끝내지 못한 프로세스가 남아 바로 바꾸지 못한 런타임: 그 프로세스가 끝나면 `runtimeChanged`가 이어서 바꾼다
    private var retiring: Set<UUID> = []
    /// 런타임을 바꾸는 중이다: 그 새 런타임은 Debug 연결 인자로 다시 연결하지 않는다 (사용자가 끊었다)
    private var renewing = false

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

    /// Settings가 연결 · 끊기를 맡기는 지금 계정의 런타임: 정상 모드일 때만 (마무리 모드는 새 등록 · Connect 0이다)
    var activeAgentRuntime: BridgeRuntime? {
        guard let id = activePartitionID, let entry = entries[id], entry.mode == .normal else { return nil }
        return entry.runtime
    }

    /// D4b-m이 비밀값 답을 넣는 곳 (메모리에만): `BridgeLocalSecretSubmitter` → `BridgeRuntime.submitLocalSecret`
    var activeSecrets: LocalSecretAnswers? { activePartitionID.flatMap { entries[$0]?.secrets } }

    var activePartition: BridgePartition? { activePartitionID.flatMap { entries[$0]?.partition } }

    /// 지금 계정의 작업 폴더 등록부 (계정이 없거나 이 빌드에 등록부가 없으면 nil)
    var activeWorkspaceRegistry: WorkspaceRegistry? { activePartition.flatMap { partition in workspaces?.registry(for: partition) } }

    /// 보내기 전에 작업 폴더를 묻는 데 쓰는 면 (D4a2-05): 지금 계정의 등록부 + 연결이 이 Mac의 것인지 확인. 등록부가 없으면 nil (묻지 않는다)
    var workspaceAsking: AgentWorkspaceAsking? {
        guard let workspaces, let registry = activeWorkspaceRegistry else { return nil }
        return AgentWorkspaceAsking(folders: registry, isThisMac: { await workspaces.isThisMac(connectionID: $0) })
    }

    var runtimeCount: Int { entries.count }

    init(
        enabled: Bool, apiBaseURL: URL, storageRoot: URL, credentials: any BridgeCredentialStore, currentUser: @escaping @MainActor () -> UUID?,
        epoch: @escaping @MainActor () -> Int = { 0 }, factory: @escaping RuntimeFactory, quitPrompt: any BridgeQuitPrompting,
        reply: @escaping @MainActor (Bool) -> Void, notificationCenter: NotificationCenter, hookServer: HookSocketServer? = nil, workspaces: ProjectWorkspaces? = nil,
        connectAtStart: String? = nil, terminalDirectory: URL? = nil
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
        self.workspaces = workspaces
        self.connectAtStart = connectAtStart
        self.terminalDirectory = terminalDirectory
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
            statusBoard.clear()
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
        statusBoard.clear()
        await runtime.start()
        // Debug 전용 연결 인자 (D4a2-10): 런타임을 시작한 뒤 한 번. 연결 화면(Settings)이 들어온 뒤에도 시험 · R2 자동화용으로 남는다.
        // Settings의 Disconnect 뒤 새 런타임에서는 다시 연결하지 않는다 (사용자가 끊었다)
        if let adapter = connectAtStart, mode == .normal, !renewing {
            Task {
                // 처음 등록이 끝난 뒤에 부른다: 등록과 겹치면 `connect` 요청이 진행 중인 등록에 합쳐져 사라진다 (등록 응답이 `pendingConnect`를 비운다). 20초 안에 등록되지 않으면 부르지 않는다
                var registered = await runtime.localBridgeID() != nil
                for _ in 0..<200 where !registered {
                    try? await Task.sleep(for: .milliseconds(100))
                    registered = await runtime.localBridgeID() != nil
                }
                if registered { _ = await runtime.connect(adapters: [adapter]) }
            }
        }
    }

    /// 지금 계정의 네트워크를 멈춘다. 바쁘지도 살아 있는 프로세스도 없으면 원장도 닫고 버린다
    private func retireActive() async {
        guard let id = activePartitionID, let entry = entries[id] else {
            activePartitionID = nil
            return
        }
        activePartitionID = nil
        statusBoard.clear()
        await entry.runtime.stop()
        await release(entry)
    }

    // MARK: Settings의 Disconnect 뒤 (OA Settings › Your agents 6.3)

    /// Disconnect가 끝난 런타임을 놓고 같은 파티션의 새 런타임을 만든다. `interruptLiveTurns`가 `stopSpawning`을 켰으므로 그 런타임은 다시 쓰지 않는다 (계정 전환과 같은 길: 멈추고 → 원장을 닫고 → 새로 만든다).
    /// 새 런타임의 첫 자동 등록은 장치 secret이 없어 403 `revoked`로 끝난다: 화면은 "Not connected · Reconnect"다.
    /// 끝내지 못한 프로세스가 아직 남아 있으면 바꾸지 않는다 (그 원장이 감독 밖 writer를 아는 유일한 자리다): 끝나면 `runtimeChanged`가 이어서 바꾼다
    func renewRuntime(replacing old: BridgeRuntime) async {
        let previous = syncTail
        let task = Task { @MainActor [self] in
            await previous?.value
            await performRenew(old)
        }
        syncTail = task
        await task.value
    }

    /// 보류한 런타임이 있으면 남은 프로세스를 다시 끝내 보고(멱등: 새 실행은 이미 막혔다) 바꾸려 해 본다 (Reconnect 앞에서 부른다).
    /// 바꿀지는 `performRenew`가 정한다: 아직 끝나지 않았으면 그대로 둔다 — 그 런타임은 다시 쓰지 않는다 (Reconnect는 실패 줄로 끝난다)
    func renewRetiredRuntimeIfIdle() async {
        guard let id = activePartitionID, let entry = entries[id], retiring.contains(entry.id) else { return }
        _ = await entry.runtime.interruptLiveTurns()
        await renewRuntime(replacing: entry.runtime)
    }

    private func performRenew(_ old: BridgeRuntime) async {
        guard let id = activePartitionID, let entry = entries[id], entry.runtime === old else { return }
        guard await !old.isBusy(), await !old.hasLiveProcess() else {
            retiring.insert(entry.id)
            return
        }
        retiring.remove(entry.id)
        activePartitionID = nil
        statusBoard.clear()
        await old.stop()
        await release(entry)
        guard entries[id] == nil else {
            // 놓지 못했다 (그 사이 바빠졌다): 이 런타임을 다시 지금 계정의 것으로 두고 나중에 다시 바꾼다
            activePartitionID = id
            retiring.insert(entry.id)
            return
        }
        hasSynced = false
        renewing = true
        defer { renewing = false }
        await performSync()
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
        if entry.partition.id == activePartitionID { statusBoard.apply(snapshot) }
        notifyBusyIfChanged()
        // Disconnect 뒤 끝내지 못했던 프로세스가 모두 끝났다: 보류했던 런타임 바꾸기를 잇는다
        if retiring.contains(entry.id), !snapshot.isBusy, !snapshot.hasLiveProcess {
            Task { await renewRuntime(replacing: entry.runtime) }
        }
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
        // 로컬 잔여 (보안 F4): 등록부 캐시와 `.command` 파일(세션 id · 경로가 적힌다)도 계정과 함께 지운다. 파티션 폴더 삭제 뒤의 늦은 쓰기는 `persist`가 거절한다
        workspaces?.forget(partition)
        if let terminalDirectory {
            await Task.detached(priority: .utility) { _ = AgentTerminalCommandStore(directory: terminalDirectory).removeAll() }.value
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

    /// 런타임 구성 (OA F1m): Mac 이름은 보내도 되는 빌드 · 서버일 때만 싣는다 — Debug는 loopback 서버일 때만, Release는 bridge가 켜진 빌드(런타임이 있을 때)에서만이다.
    /// 처리방침 갱신 전에 개발 빌드가 운영 서버로 이름을 보내지 않게 한다 (F1s notes 8장 위험 2). 마무리 모드는 런타임이 이름을 보내지 않는다
    static func runtimeConfiguration(
        partition: BridgePartition, appVersion: String, mode: BridgeRuntimeConfiguration.Mode, isDebugBuild: Bool, apiBaseURL: URL
    ) -> BridgeRuntimeConfiguration {
        BridgeRuntimeConfiguration(
            partition: partition, appVersion: appVersion, mode: mode, heartbeatJitterSeconds: 2,
            deviceName: DeviceNamePolicy.provider(isDebugBuild: isDebugBuild, apiBaseURL: apiBaseURL)
        )
    }

    /// Claude Code adapter에 넣는 작업 폴더 resolver (OA D4a2): Release와 Debug 모두 등록부 resolver다. Debug만 `-TF_BRIDGE_WORKSPACE`(R2 확인용 일회용 폴더, Q14)가 있으면
    /// 그 폴더만 쓴다 — 조건을 못 채우면 resolver가 없다(등록부로 넘어가지 않는다). `disposable`은 Release에서는 늘 nil이다 (`agentChoice`)
    static func claudeCodeWorkspaces(disposable: String?, apiBaseURL: URL, home: String, registered: () -> (any WorkspaceResolver)?) -> (any WorkspaceResolver)? {
        #if DEBUG
        if disposable != nil { return DisposableWorkspaces.make(path: disposable, apiBaseURL: apiBaseURL, home: home) }
        #else
        _ = (disposable, apiBaseURL, home)
        #endif
        return registered()
    }

    /// Claude Code adapter를 만든다. translocate된 실행인데 원래 번들 경로를 모르면 만들지 않는다 (nil, 보안 N1: fail-closed): 원래 번들의 훅을 에이전트가 바꾸지 못한다고 말할 수 없다
    static func claudeCodeAdapter<Adapter>(bundle: AppBundleProtection, make: () -> Adapter) -> Adapter? {
        bundle.failClosed ? nil : make()
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
        // 작업 폴더 등록부 · resolver (D4a2): 파티션 폴더 안의 `workspaces.json`. 서버에는 경로를 보내지 않는다. bridge가 꺼진 빌드는 만들지 않는다
        // 앱 번들 보호 (보안 F2 · N1): translocate된 실행이면 원래 번들 경로도 보호하고, 원래 경로를 모르면 이 실행에서는 Claude Code adapter를 만들지 않는다
        let bundle = AppBundleProtection()
        let projectWorkspaces = enabled ? ProjectWorkspaces.live(services: services, root: root, support: support, bundleID: bundleID, bundle: bundle) : nil
        if enabled { AgentTerminalLauncherLive.sweepOldFiles() }
        #if DEBUG
        let connectAtStart: String? = enabled ? BridgeFlag.connectAdapter(arguments: BridgeFlag.currentArguments, isDebugBuild: AppRuntime.isDebugBuild, apiBaseURL: services.api.baseURL) : nil
        #else
        let connectAtStart: String? = nil
        #endif
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
                    // 세션 폴더는 파티션 아래 (계정 삭제가 파티션째 지운다). init은 부수 효과 0: probe · 폴더 만들기는 런타임이 부를 때만.
                    // 앱 Application Support 안의 Edit/Write는 막는다 (OA D3a 10장 5). 다른 부팅의 혈통 파일은 런타임을 만들 때 끝 기록으로 바꾼다 (10장 4 · 결정 11-1)
                    guard let claudeCode = BridgeHost.claudeCodeAdapter(bundle: bundle, make: {
                        ClaudeCodeProcess(
                            sessionsRoot: partition.directory(in: root).appending(path: "claude-code", directoryHint: .isDirectory), hookServer: hookServer,
                            helpers: .inBundle(), locator: .standard(home: NSHomeDirectory()), log: BridgeOSLog(),
                            protectedRoots: ProjectWorkspaces.protectedRoots(support: support, bundleID: bundleID, root: root, bundle: bundle)
                        )
                    }) else {
                        BridgeOSLog().log("app_translocation_unresolved", [:])
                        adapters = []
                        workspaces = nil
                        break
                    }
                    claudeCode.purgeLineageOfOtherBoots()
                    adapters = [claudeCode]
                    workspaces = BridgeHost.claudeCodeWorkspaces(
                        disposable: disposable, apiBaseURL: services.api.baseURL, home: NSHomeDirectory(), registered: { projectWorkspaces?.resolver(for: partition) }
                    )
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
                    configuration: BridgeHost.runtimeConfiguration(
                        partition: partition, appVersion: appVersion, mode: mode, isDebugBuild: AppRuntime.isDebugBuild, apiBaseURL: services.api.baseURL
                    ), client: client, ledger: ledger,
                    credentials: credentials, adapters: adapters, wake: SupabaseBridgeWake(supabase: services.supabase), secrets: secrets, workspaces: workspaces,
                    sessionStillValid: BridgeAppSupport.sessionStillValid(services.supabase), log: BridgeOSLog(), onChange: onChange
                )
            },
            quitPrompt: BridgeQuitAlert(), reply: { NSApplication.shared.reply(toApplicationShouldTerminate: $0) }, notificationCenter: NSWorkspace.shared.notificationCenter,
            hookServer: hookServer, workspaces: projectWorkspaces, connectAtStart: connectAtStart, terminalDirectory: AgentTerminalLauncherLive.commandDirectory()
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
