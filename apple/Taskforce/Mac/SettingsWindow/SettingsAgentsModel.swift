#if os(macOS)
import Foundation
import Observation
import TaskforceKit
import TaskforceUI

// Settings › Your agents의 상태 · 동작 (OA Settings › Your agents 5–9장). 규칙(줄 · 상세)은 Kit의 `AgentSettingsRules`가 정하고, 이 모델은
// - 이 Mac의 사실(P: probe · R: 런타임 상태 · N: Mac 이름 · 실행 시작 시각)과 서버의 판정(T: 대상 목록)을 읽어 모으고,
// - Connect · Reconnect · Disconnect this Mac · 다른 Mac 지우기 · 폴더 바꾸기 · 지우기를 `AgentSettingsEnvironment`에 맡기며,
// - 눌림(busy) · 조용한 실패 줄 · 새로 고침(10초에 한 번)을 지킨다.
// 서버가 판정하는 말은 대상 목록에서만 온다 — 모델도 다시 계산하지 않는다. 계정이 떠나면 모두 비우고 늦은 응답을 버린다 (`ChatAccountBoundaryTests`와 같은 경계).
// 로그: 이름 · 경로 · id 원문은 0이다 (런타임이 코드 · 개수만 남긴다).

/// 대상 목록 읽기의 결과 (T)
enum AgentSettingsTargetsRead: Equatable {
    /// 읽었다
    case rows([AssistantTarget])
    /// 대화 API · 에이전트가 꺼져 있다 (또는 이 실행에 게이트웨이가 없다): 서버가 이 Mac의 연결을 주지 않는다
    case unavailable
    /// 읽지 못했다 (읽는 중 · 오프라인): 서버 상태를 주장하지 않는다
    case failed
}

/// 폴더 등록부의 면 (실제는 `WorkspaceRegistry`, 견본 · 시험은 가짜): 거절 규칙은 등록부 한 곳에 있다 — Settings가 따로 만들지 않는다
protocol AgentSettingsFolderStore: AnyObject {
    func projectFolders() -> [UUID: String]
    func accepts(path: String, scope: AgentWorkspaceGate.Scope) -> Bool
    func rejectionMessage(forPath path: String, scope: AgentWorkspaceGate.Scope) -> String
    func register(path: String, scope: AgentWorkspaceGate.Scope) throws
    func removeFolder(forProject contextID: UUID)
}

extension WorkspaceRegistry: AgentSettingsFolderStore {}

/// 모델이 부르는 이 Mac · 서버의 면 전부. 실제는 `LiveAgentSettingsEnvironment`(`SettingsAgentsLive.swift`)이고 시험 · 견본이 가짜를 끼운다
@MainActor
protocol AgentSettingsEnvironment: AnyObject {
    /// B: 이 빌드가 에이전트를 띄울 수 있다 (bridge가 켜졌고 활성 런타임에 Claude Code adapter가 있다)
    var canRunAgents: Bool { get }
    /// R: 이 Mac 런타임의 상태 · 살아 있는 실행 (관찰된다: 바뀌면 화면이 다시 그린다)
    var runtimeStatus: BridgeStatus? { get }
    var runtimeHasLiveProcess: Bool { get }

    func localBridgeID() async -> UUID?
    /// P: 지금 보고 (읽기만) · 새로 고침 (로그인 캐시를 비우고 서버 보고도 바꾼다, 런타임이 10초에 한 번으로 막는다)
    func probe() async -> BridgeV1AdapterReport?
    func refreshProbe() async -> BridgeV1AdapterReport?
    func liveSince() async -> Date?
    /// N: 서버에 저장된 이 Mac의 이름 (`bridges.device_name`, RLS)
    func deviceName(of bridgeID: UUID) async -> String?
    /// T
    func loadTargets() async -> AgentSettingsTargetsRead

    func connect() async -> AgentConnectOutcome
    func reconnect() async -> AgentConnectOutcome
    func disconnect() async -> AgentDisconnectOutcome
    func removeMac(_ bridgeID: UUID) async -> AgentRemoveMacOutcome
    /// 10대일 때의 Mac 목록 (RLS). 읽지 못하면 nil
    func macs() async -> [AgentMacRecord]?

    // 작업 폴더 (W)
    var folders: (any AgentSettingsFolderStore)? { get }
    /// 그 id의 프로젝트 이름 · 아이콘을 **id로 직접** 묻는다 (RLS, 보관된 것 포함). 돌려주는 것은 있는 프로젝트뿐이고, 물은 id가 없으면 "없다고 확인된" 것이다.
    /// 묻기 실패 · 이 Mac 등록부의 사용자와 로그인한 사용자가 다름 · 읽는 사이 계정이 바뀜이면 nil — 모르는 채로 아무것도 정리하지 않는다
    func projects(ids: [UUID]) async -> [UUID: AgentFolderProject]?
    var homes: [String] { get }
    /// 등록된 폴더 중 지금 있는 것 (파일 시스템은 메인 밖에서 본다)
    func existingFolders(among paths: [String]) async -> Set<String>
    /// 시스템 폴더 창 (D4a-2와 같은 창 · 같은 거절 규칙). 취소하면 nil
    func pickFolder(
        message: String, prompt: String, rejection: String, accepts: @escaping @Sendable (String) -> Bool, reason: @escaping @Sendable (String) -> String
    ) async -> String?

    /// 첫 연결 뒤 알림 묻기 (SA-10): 있는 한 번 묻기 길 (`PushPermission.shouldRequest`가 이미 물었으면 0)
    func requestNotificationPermission() async
}

@MainActor
@Observable
final class AgentSettingsModel {
    /// 지금 도는 동작 (한 번에 하나)
    enum Busy: Equatable {
        case connect, reconnect, disconnect
        case removeMac(UUID)
    }

    /// 조용한 실패 줄 (힌트 톤, 빨강 아님): 어느 동작의 것인가 + 말
    struct Failure: Equatable {
        enum Action: Equatable {
            case connect, reconnect, disconnect
            case removeMac(UUID)
            /// 폴더를 바꿨는데 저장하지 못했다 (거절이 아닌 쓰기 실패)
            case changeFolder(UUID)
        }

        let action: Action
        let text: String
    }

    /// 새로 고침의 이유: `.shown`(절 · 상세가 보임) · `.windowKey`(창이 다시 키 창이 됨, Terminal에서 로그인하고 돌아온 때)는 10초에 한 번까지 probe를 새로 하고 서버 보고도 바꾼다.
    /// `.again`(동작 뒤 · 런타임 상태가 바뀜)은 지금 보고를 읽기만 한다
    enum Refresh: Equatable {
        case shown, windowKey, again
    }

    static let refreshInterval: TimeInterval = 10

    // 읽은 사실 (관찰된다)
    private(set) var report: BridgeV1AdapterReport?
    private(set) var target: AgentSettingsFacts.Target = .notLoaded
    private(set) var deviceName: String?
    private(set) var liveSince: Date?
    private(set) var thisMacBridgeID: UUID?
    private(set) var folderLines: [AgentFolderLine] = AgentSettingsFolders.lines(folders: [:], projects: nil, homes: [], exists: { _ in true }).lines
    private(set) var macs: [AgentMacRecord] = []
    private(set) var macsRead = false
    private(set) var macsFailed = false
    private(set) var busy: Busy?
    private(set) var failure: Failure?

    @ObservationIgnored private(set) var environment: (any AgentSettingsEnvironment)?
    /// 계정이 바뀔 때마다 오른다: 옛 계정의 늦은 응답을 버린다
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastFullRefresh: Date?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshAgain = false
    /// 다음 반복이 전체 새로 고침(로그인 캐시 비움 + 서버 보고)이어야 하나: 합쳐진 요청 중 센 쪽을 지킨다 (ch.21 4)
    @ObservationIgnored private var refreshFull = false
    @ObservationIgnored private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    // MARK: 붙이기

    /// 이 모델이 쓸 면. 이미 있으면 바꾸지 않는다 (시험 · 견본이 먼저 끼운 가짜를 실제가 덮지 않는다)
    func attach(_ environment: any AgentSettingsEnvironment) {
        guard self.environment == nil else { return }
        self.environment = environment
    }

    /// 견본 · 시험이 면을 바꿔 끼운다: 읽은 것 · 동작 상태를 모두 비운다
    func replaceEnvironment(_ environment: (any AgentSettingsEnvironment)?) {
        reset()
        self.environment = environment
    }

    /// 계정이 이 기기를 떠남: 읽은 것 · 눌림 · 실패 줄을 모두 지우고 늦은 응답을 버린다
    func accountLeft() {
        reset()
    }

    private func reset() {
        generation += 1
        report = nil
        target = .notLoaded
        deviceName = nil
        liveSince = nil
        thisMacBridgeID = nil
        macs = []
        macsRead = false
        macsFailed = false
        busy = nil
        failure = nil
        lastFullRefresh = nil
        refreshing = false
        refreshAgain = false
        refreshFull = false
        folderLines = AgentSettingsFolders.lines(folders: [:], projects: nil, homes: [], exists: { _ in true }).lines
    }

    // MARK: 보이는 값

    var facts: AgentSettingsFacts {
        AgentSettingsFacts(
            canRunAgents: environment?.canRunAgents ?? false, status: environment?.runtimeStatus, hasLiveProcess: environment?.runtimeHasLiveProcess ?? false,
            report: report, target: target, deviceName: deviceName, liveSince: liveSince
        )
    }

    /// 런타임에서 화면이 따라가야 하는 값: 상태와 살아 있는 실행 여부. 바뀌면 지금 값을 다시 읽는다 (상태가 그대로여도 실행이 시작 · 끝나면 "Active since"가 바뀐다)
    struct RuntimeSignature: Equatable {
        let status: BridgeStatus?
        let hasLiveProcess: Bool
    }

    var runtimeSignature: RuntimeSignature {
        RuntimeSignature(status: environment?.runtimeStatus, hasLiveProcess: environment?.runtimeHasLiveProcess ?? false)
    }

    var line: AgentSettingsLine { AgentSettingsRules.line(facts) }
    var detail: AgentSettingsDetail { AgentSettingsRules.detail(facts) }

    /// 탭 맨 위 Notice (README "at most one Notice"): 이 계정의 Mac이 10대
    var showsMacsNotice: Bool { facts.canRunAgents && environment?.runtimeStatus == .tooManyBridges }

    /// 줄 아래 · 머리의 실패 줄 (Connect · Reconnect 것만)
    var rowHint: String? {
        guard let failure, failure.action == .connect || failure.action == .reconnect else { return nil }
        return failure.text
    }

    var disconnectHint: String? { failure?.action == .disconnect ? failure?.text : nil }

    func macHint(_ id: UUID) -> String? { failure?.action == .removeMac(id) ? failure?.text : nil }

    /// Folders 절 아래 조용한 회색 줄: 폴더를 저장하지 못했다 (있는 문장). 거절은 폴더 창 안에서 끝나므로 여기에 없다
    var folderHint: String? {
        guard case .changeFolder = failure?.action else { return nil }
        return failure?.text
    }

    // MARK: 읽기 (SA-06)

    /// 새로 고침. `.shown` · `.windowKey`는 10초에 한 번까지 (그 안의 두 번째는 아무것도 하지 않는다)
    func refresh(_ reason: Refresh) async {
        guard let environment else { return }
        let wantsFull = reason != .again
        // 전체 새로 고침만 10초 예산을 쓴다: 읽기만 하는 `.again`은 쓰지 않는다
        if wantsFull {
            let at = now()
            if let last = lastFullRefresh, at.timeIntervalSince(last) < Self.refreshInterval { return }
            lastFullRefresh = at
        }
        // 겹친 읽기는 하나로: 도는 동안 온 요청은 끝난 뒤 한 번 더 읽는다. 합쳐질 때 센 쪽(전체)을 잃지 않는다 — 예산은 이미 썼으니 다음 반복이 전체 새로 고침이어야 한다
        if refreshing {
            refreshAgain = true
            if wantsFull { refreshFull = true }
            return
        }
        refreshing = true
        refreshFull = wantsFull
        let started = generation
        defer { if started == generation { refreshing = false } }
        repeat {
            refreshAgain = false
            let full = refreshFull
            refreshFull = false
            await read(environment, full: full, started: started)
            guard started == generation else { return }
        } while refreshAgain
    }

    private func read(_ environment: any AgentSettingsEnvironment, full: Bool, started: Int) async {
        // 이 빌드가 못 띄우면 아무것도 읽지 않는다: 서버 · 런타임 호출 0 (줄은 "Can't run agents in this build")
        guard environment.canRunAgents else {
            report = nil
            target = .notLoaded
            deviceName = nil
            liveSince = nil
            thisMacBridgeID = nil
            return
        }
        let bridge = await environment.localBridgeID()
        guard started == generation else { return }
        thisMacBridgeID = bridge
        // P: 새로 고침은 로그인 캐시를 비우고 서버 보고도 바꾼다. 이 Mac의 사실이라 그대로 보인다
        let probed = full ? await environment.refreshProbe() : await environment.probe()
        guard started == generation else { return }
        report = probed
        // T: 서버가 판정한다. 읽지 못했으면 마지막으로 받은 것을 그대로 둔다 (받은 적이 없으면 주장하지 않는다)
        let read = await environment.loadTargets()
        guard started == generation else { return }
        var serverName: String?
        switch read {
        case .rows(let targets):
            let row = AgentSettingsRules.thisMacRow(in: targets, adapter: ClaudeCodeSupport.adapterID, bridgeID: bridge)
            target = AgentSettingsRules.target(from: row)
            serverName = row?.deviceName
        case .unavailable:
            target = .none
        case .failed:
            break
        }
        // N: 서버에 저장된 이름. 모르면 대상 행의 이름. 둘 다 모르면 줄이 없다
        let stored = if let bridge { await environment.deviceName(of: bridge) } else { nil as String? }
        guard started == generation else { return }
        deviceName = stored ?? serverName
        let since = await environment.liveSince()
        guard started == generation else { return }
        liveSince = since
        await reloadFolders(environment, started: started)
    }

    // MARK: Connect · Reconnect (6.1 · 6.2)

    func connect() async {
        await runConnection(.connect)
    }

    func reconnect() async {
        await runConnection(.reconnect)
    }

    private func runConnection(_ action: Busy) async {
        guard let environment, busy == nil else { return }
        let expected: AgentSettingsLine.Control = action == .connect ? .connect : .reconnect
        guard line.control == expected else { return }
        let started = generation
        busy = action
        failure = nil
        let outcome = action == .connect ? await environment.connect() : await environment.reconnect()
        // 응답을 기다리는 사이 계정이 바뀌었다: 아무것도 쓰지 않고 알리지도 않는다
        guard started == generation else { return }
        busy = nil
        switch outcome {
        case .connected:
            await refresh(.again)
            // SA-10: 첫 연결 뒤 알림 묻기 (이미 물었으면 그 길이 0으로 만든다)
            guard started == generation else { return }
            await environment.requestNotificationPermission()
        case .tooManyMacs, .needsReconnect:
            // 상태 말은 런타임 상태(R)가 바뀌어 줄이 바꾼다 (Too many Macs · Not connected + Reconnect)
            await refresh(.again)
        case .failed(let reason):
            failure = Failure(action: action == .connect ? .connect : .reconnect, text: Self.text(reason))
        case .unavailable:
            failure = Failure(action: action == .connect ? .connect : .reconnect, text: Self.text(.other))
        }
    }

    // MARK: Disconnect this Mac (6.3)

    /// 확인 줄의 Disconnect. 서버가 폐기를 받으면 이 Mac을 정리하고 런타임을 바꾼다. 실패하면 이 Mac에서 바뀐 것은 0이라 확인 줄이 그대로 남고 실패 줄이 붙는다.
    /// 창을 닫아도 일은 계속한다 (이 모델이 Task를 쥔다)
    @discardableResult
    func disconnect() async -> Bool {
        guard let environment, busy == nil, detail.showsDisconnect else { return false }
        let started = generation
        busy = .disconnect
        failure = nil
        let outcome = await environment.disconnect()
        guard started == generation else { return false }
        busy = nil
        switch outcome {
        case .disconnected, .unavailable:
            // `.unavailable`: 끊을 것이 없다 (이미 폐기 · 등록 전) — 확인 줄을 닫고 지금 상태를 다시 읽는다
            await refresh(.again)
            return true
        case .failed(let reason):
            failure = Failure(action: .disconnect, text: Self.text(reason))
            return false
        }
    }

    // MARK: Mac 10대 (6.4)

    func loadMacs() async {
        guard let environment else { return }
        let started = generation
        let read = await environment.macs()
        guard started == generation else { return }
        guard let read else {
            macsFailed = true
            macsRead = true
            return
        }
        macsFailed = false
        macsRead = true
        macs = AgentSettingsMacs.rows(read, excluding: thisMacBridgeID)
    }

    /// 확인 줄의 Remove: 그 Mac만 폐기한다. 성공하면 목록을 다시 읽고 Connect를 다시 연다 (자동으로 연결하지 않는다)
    @discardableResult
    func removeMac(_ id: UUID) async -> Bool {
        guard let environment, busy == nil else { return false }
        let started = generation
        busy = .removeMac(id)
        failure = nil
        let outcome = await environment.removeMac(id)
        guard started == generation else { return false }
        busy = nil
        switch outcome {
        case .removed:
            await loadMacs()
            guard started == generation else { return true }
            await refresh(.again)
            return true
        case .failed(let reason):
            failure = Failure(action: .removeMac(id), text: Self.text(reason))
            return false
        case .refused:
            failure = Failure(action: .removeMac(id), text: Self.text(.other))
            return false
        }
    }

    // MARK: 작업 폴더 (7장)

    /// 등록부 · 프로젝트를 다시 읽어 줄을 만든다. 지워진 프로젝트의 폴더는 줄 대신 등록부에서 지운다 (프로젝트 목록을 읽은 뒤에만)
    func reloadFolders() async {
        guard let environment else { return }
        await reloadFolders(environment, started: generation)
    }

    private func reloadFolders(_ environment: any AgentSettingsEnvironment, started: Int) async {
        guard let store = environment.folders else { return }
        let registered = store.projectFolders()
        // 지워진 프로젝트의 매핑은 등록된 프로젝트 id로 직접 물어 "없다"고 확인된 것만 지운다 (이름순 500 목록으로 판단하지 않는다, ch.21 3).
        // 묻기 실패 · 사용자 불일치(nil) · 계정 세대가 바뀜이면 지우지 않는다. 등록된 것이 없으면 물을 것도 없다
        let projects: [UUID: AgentFolderProject]? = registered.isEmpty ? [:] : await environment.projects(ids: Array(registered.keys))
        let existing = await environment.existingFolders(among: Array(registered.values))
        // 두 읽기가 끝난 지금 한 번만 본다: 그 사이 계정이 바뀌었거나(세대) 읽던 등록부가 바뀌었으면 줄도 정리도 하지 않는다
        guard started == generation, environment.folders === store else { return }
        let result = AgentSettingsFolders.lines(folders: registered, projects: projects, homes: environment.homes, exists: { existing.contains($0) })
        // 읽는 사이 그 프로젝트의 폴더가 바뀌었으면(Change…) 지우지 않는다: 읽은 값 그대로일 때만
        let current = store.projectFolders()
        for orphan in result.orphans where current[orphan] == registered[orphan] { store.removeFolder(forProject: orphan) }
        folderLines = result.lines
    }

    /// Change…: D4a-2와 같은 시스템 폴더 창 · 같은 거절 규칙. 고르면 그 프로젝트의 폴더를 바꾼다. 이미 연 세션은 옛 폴더를 그대로 쓴다 (세션 핀).
    /// 거절된 폴더는 창 안에서 막힌다 (D4a-2의 승인된 글): Settings 줄에 되풀이하지 않고, 등록부가 한 번 더 거절하면 아무것도 바뀌지 않는다
    func changeFolder(project: AgentFolderProject) async {
        guard let environment, let store = environment.folders else { return }
        let started = generation
        let scope = AgentWorkspaceGate.Scope.project(project.id)
        let picked = await environment.pickFolder(
            message: AgentWorkspaceCopy.chooseFolder(forProject: project.name), prompt: AgentWorkspaceCopy.choose, rejection: AgentWorkspaceCopy.rejected,
            accepts: { [store = UncheckedStore(store)] in store.value.accepts(path: $0, scope: scope) },
            reason: { [store = UncheckedStore(store)] in store.value.rejectionMessage(forPath: $0, scope: scope) }
        )
        guard started == generation, let picked else { return }
        failure = nil
        // 등록부가 다시 거른다 (창 밖에서 온 값이어도 규칙 한 곳): 거절이면 아무것도 바뀌지 않고 줄도 없다 (폴더 창 안의 글로 끝).
        // 거절이 아닌 쓰기 실패는 있는 문장을 조용한 회색 줄로 보인다 (옛 폴더 그대로)
        do {
            try store.register(path: picked, scope: scope)
        } catch WorkspaceRegistry.RegistryError.writeFailed {
            failure = Failure(action: .changeFolder(project.id), text: Self.text(.other))
        } catch {}
        await reloadFolders()
    }

    /// 확인 줄의 Remove: 그 프로젝트의 폴더를 지운다. 다음 새 세션이 다시 묻는다
    func removeFolder(project: UUID) async {
        environment?.folders?.removeFolder(forProject: project)
        await reloadFolders()
    }

    // MARK: 실패 말

    static func text(_ reason: AgentSettingsFailure) -> String {
        switch reason {
        case .offline: AgentSettingsCopy.youAreOffline
        case .other: AgentSettingsCopy.somethingWentWrong
        }
    }

    /// 실패 줄만 지운다 (탭 · 상세를 옮기거나 창을 닫을 때)
    func dismissFailure() {
        failure = nil
    }

    #if DEBUG
    /// 견본 하네스 전용 (Release에는 없다): 눌림 · 실패 줄을 정해 그 모습을 찍는다
    func debugForce(busy: Busy?, failure: Failure?) {
        self.busy = busy
        self.failure = failure
    }

    /// 견본 하네스 전용: 이 값들을 그대로 쓴다 (읽지 않는다)
    func debugSet(
        report: BridgeV1AdapterReport?, target: AgentSettingsFacts.Target, deviceName: String?, liveSince: Date?, folders: [AgentFolderLine], macs: [AgentMacRecord] = []
    ) {
        self.report = report
        self.target = target
        self.deviceName = deviceName
        self.liveSince = liveSince
        folderLines = folders
        self.macs = macs
        macsRead = true
    }
    #endif
}

/// 폴더 창이 부르는 거절 규칙의 닫힌 값 (창의 검증은 메인 밖일 수 있다): 등록부는 안에서 잠금으로 읽는다
private struct UncheckedStore: @unchecked Sendable {
    let value: any AgentSettingsFolderStore

    init(_ value: any AgentSettingsFolderStore) {
        self.value = value
    }
}
#endif
