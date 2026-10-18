#if os(macOS) && DEBUG
import Foundation
import SwiftUI
import TaskforceKit

// 견본 하네스의 Your agents 상태 표 (Debug 전용, Release 바이너리에 없다): `-TFSettingsSnapshotAgents`로 5.4 체크리스트의 모든 상태를 라이트 · 다크 PNG로 찍는다.
// 값은 모두 가짜다 — 실제 런타임 · 서버 · `claude` · 폴더 · Keychain에 닿지 않는다. 렌더된 견본일 뿐이다: 실제 포인터 · 키보드 · VoiceOver 확인이 아니다.

enum SettingsAgentsSnapshot {
    static let argument = "-TFSettingsSnapshotAgents"

    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

    // MARK: 견본 값

    static let home = "/Users/daniel"
    static let bridge = UUID(uuidString: "b1111111-1111-4111-8111-111111111111")!

    static func report(installed: Bool = true, version: String? = "2.1.241", signedIn: BridgeV1SignedIn = .yes, managed: Bool = false) -> BridgeV1AdapterReport {
        BridgeV1AdapterReport(adapter: "agent:claude-code", installed: installed, version: installed ? version : nil, signedIn: signedIn, managedSettings: managed)
    }

    static func row(_ state: AgentTargetState, _ access: AgentAccessLevel? = .write) -> AgentSettingsTargetsRead {
        .rows([.agent(AssistantTarget.Agent(adapter: "agent:claude-code", displayName: "Claude Code", connectionID: UUID(), state: state, access: access, bridgeID: bridge, deviceName: "Daniel's MacBook Pro"))])
    }

    /// DZ 그림의 열두 프로젝트 (이름 · 아이콘 · 폴더)
    static let projects: [(name: String, icon: ProjectIconName, path: String)] = [
        ("Shape launch", .rocket, "\(home)/Documents/Shape/launch"), ("Acme website", .briefcase, "\(home)/Projects/acme-site"),
        ("Taskforce 0.2.0", .codeXml, "\(home)/Documents/Life Design/Taskforce-new"), ("Brand refresh", .palette, "\(home)/Design/brand-refresh"),
        ("Pricing experiments", .flaskConical, "\(home)/Documents/Research/pricing"), ("Podcast", .megaphone, "\(home)/Audio/podcast-season-2"),
        ("Handbook", .bookOpen, "\(home)/Documents/Handbook"), ("Office move", .building2, "\(home)/Documents/Admin/office-move"),
        ("Garden app", .leaf, "/Volumes/Work SSD/garden-app"), ("Field study", .compass, "\(home)/Research/field-study"),
        ("Q4 targets", .target, "\(home)/Documents/Planning/q4"), ("Hiring", .users, "\(home)/Documents/People/hiring-2026"),
    ]

    static func macs(unnamed: Bool = true, now: Date = Date()) -> [AgentMacRecord] {
        let names: [String?] = ["Old MacBook Pro", unnamed ? nil : "Mac mini", "Studio Mac mini", "Design iMac", "Jordan's MacBook Air", "Travel MacBook", "Office Mac Studio", "Home Mac mini", "Daniel's MacBook Pro", "Test MacBook Air"]
        let ages: [TimeInterval] = [86_400 * 63, 86_400 * 56, 86_400 * 42, 86_400 * 35, 86_400 * 21, 86_400 * 14, 86_400 * 6, 86_400 * 2, 86_400, 240]
        return zip(names, ages).enumerated().map { index, pair in
            AgentMacRecord(id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 1))!, deviceName: pair.0, lastHeartbeatAt: now.addingTimeInterval(-pair.1))
        }
    }

    // MARK: 한 장면

    struct Scenario {
        enum Screen { case list, detail, macs }

        var name: String
        var screen: Screen
        var canRun = true
        var status: BridgeStatus? = .connected
        var live = false
        var report: BridgeV1AdapterReport? = SettingsAgentsSnapshot.report()
        var target: AgentSettingsTargetsRead = .rows([])
        var mac: String? = "Daniel's MacBook Pro"
        var since: Date?
        /// 등록부 · 프로젝트에 놓을 폴더 (이름 · 아이콘 · 경로 · 사라졌나)
        var folders: [(name: String, icon: ProjectIconName, path: String, missing: Bool)] = []
        var macsRead: [AgentMacRecord] = []
        var busy: AgentSettingsModel.Busy?
        /// 첫 번째 Mac을 지우는 중 (Mac id는 목록을 읽은 뒤에 안다)
        var busyRemovingFirstMac = false
        var failure: AgentSettingsModel.Failure?
        var confirming: (@MainActor (AgentSettingsModel) -> SettingsWindowConfirm?)?
        var scrollEnd = false
        /// 대비 높이기 모습 (앱 모양을 접근성 고대비 모양으로 바꿔 찍는다)
        var increasedContrast = false
    }

    private static func folders(_ count: Int, missing: Set<String> = []) -> [(name: String, icon: ProjectIconName, path: String, missing: Bool)] {
        projects.prefix(count).map { ($0.name, $0.icon, $0.path, missing.contains($0.name)) }
    }

    /// 5.4 체크리스트 전부 (상태 이름은 파일 이름이 된다)
    static func scenarios(now: Date) -> [Scenario] {
        let tenAgo = now.addingTimeInterval(-3600)
        var list: [Scenario] = []
        func add(_ name: String, _ screen: Scenario.Screen = .list, _ configure: (inout Scenario) -> Void = { _ in }) {
            var scenario = Scenario(name: name, screen: screen)
            configure(&scenario)
            list.append(scenario)
        }
        let serverFailure = AgentSettingsModel.Failure(action: .connect, text: AgentSettingsCopy.somethingWentWrong)
        let offlineFailure = AgentSettingsModel.Failure(action: .connect, text: AgentSettingsCopy.youAreOffline)

        // Connections 탭: Your agents 줄 0–8 (탭 끝으로 스크롤)
        add("list-0-checking") { $0.target = .failed; $0.scrollEnd = true }
        add("list-1-cannot-run") { $0.canRun = false; $0.report = nil; $0.status = nil; $0.scrollEnd = true }
        add("list-2-reconnect") { $0.status = .revoked; $0.scrollEnd = true }
        add("list-3-too-many-macs") { $0.status = .tooManyBridges; $0.macsRead = macs(); $0.scrollEnd = true }
        add("list-3-notice-top") { $0.status = .tooManyBridges; $0.macsRead = macs() }
        add("list-4-not-installed") { $0.report = report(installed: false); $0.scrollEnd = true }
        add("list-5-connect") { $0.scrollEnd = true }
        add("list-5-connect-busy") { $0.busy = .connect; $0.scrollEnd = true }
        add("list-5-connect-failed-server") { $0.failure = serverFailure; $0.scrollEnd = true }
        add("list-5-connect-failed-offline") { $0.failure = offlineFailure; $0.scrollEnd = true }
        add("list-2-reconnect-busy") { $0.status = .revoked; $0.busy = .reconnect; $0.scrollEnd = true }
        add("list-6-not-signed-in") { $0.target = row(.signInNeeded); $0.scrollEnd = true }
        add("list-7-offline") { $0.target = row(.unreachable); $0.scrollEnd = true }
        add("list-8-session-active") { $0.target = row(.ready); $0.live = true; $0.scrollEnd = true }
        add("list-8-no-session") { $0.target = row(.ready); $0.scrollEnd = true }
        add("list-8-unsupported") { $0.target = row(.unsupported); $0.live = true; $0.scrollEnd = true }
        add("list-8-read-only") { $0.target = row(.ready, .readOnly); $0.live = true; $0.scrollEnd = true }
        add("list-8-can-write") { $0.target = row(.ready, .write); $0.live = true; $0.scrollEnd = true }
        add("list-contrast-more-reconnect", .list) { $0.status = .revoked; $0.scrollEnd = true; $0.increasedContrast = true }

        // 상세: 연결 없음 · 누르는 중 · 실패 줄
        add("detail-connect", .detail) { $0.target = .rows([]) }
        add("detail-connect-busy", .detail) { $0.busy = .connect }
        add("detail-connect-failed", .detail) { $0.failure = serverFailure }
        add("detail-reconnect", .detail) { $0.status = .revoked; $0.folders = folders(2) }
        add("detail-reconnect-busy", .detail) { $0.status = .revoked; $0.busy = .reconnect }
        // 상세: Status 각주 넷
        add("detail-not-signed-in", .detail) { $0.target = row(.signInNeeded); $0.report = report(signedIn: .no) }
        add("detail-not-installed", .detail) { $0.report = report(installed: false) }
        add("detail-managed-settings", .detail) { $0.target = row(.unsupported); $0.live = true; $0.since = tenAgo; $0.report = report(managed: true); $0.folders = folders(3) }
        add("detail-unsupported-version", .detail) { $0.target = row(.unsupported); $0.live = true; $0.since = tenAgo; $0.report = report(version: "1.0.88") }
        // 상세: ready 셋
        add("detail-ready-unsupported", .detail) { $0.target = row(.unsupported); $0.live = true; $0.since = tenAgo; }
        add("detail-ready-read-only", .detail) { $0.target = row(.ready, .readOnly); $0.live = true; $0.since = tenAgo }
        add("detail-ready-can-write", .detail) { $0.target = row(.ready, .write); $0.live = true; $0.since = tenAgo }
        add("detail-checking", .detail) { $0.report = nil; $0.target = .failed }
        add("detail-cannot-run", .detail) { $0.canRun = false; $0.report = nil; $0.status = nil }
        add("detail-contrast-more", .detail) { $0.target = row(.unsupported); $0.live = true; $0.since = tenAgo; $0.increasedContrast = true }
        // 상세: Folders
        add("detail-folders-0", .detail) { $0.target = row(.ready) }
        add("detail-folders-3", .detail) { $0.target = row(.ready); $0.folders = folders(3); $0.scrollEnd = true }
        add("detail-folders-12", .detail) { $0.target = row(.ready); $0.folders = folders(12); $0.scrollEnd = true }
        add("detail-folders-long-path", .detail) {
            $0.target = row(.ready)
            $0.folders = [("Northwind", .briefcase, "\(home)/Documents/Clients/Northwind Traders/2026/Marketing site/source", false), ("Garden app", .leaf, "/Volumes/Work SSD/Clients/Northwind Traders/garden/site", false), ("Shape launch", .rocket, projects[0].path, false)]
            $0.scrollEnd = true
        }
        add("detail-folders-long-name", .detail) {
            $0.target = row(.ready)
            $0.folders = [("Northwind Traders · 2026 website relaunch and brand refresh for the partner program", .briefcase, "\(home)/Documents/Northwind/site", false), ("Shape launch", .rocket, projects[0].path, false), ("Acme website", .briefcase, projects[1].path, false)]
            $0.scrollEnd = true
        }
        add("detail-folders-missing", .detail) { $0.target = row(.ready); $0.folders = folders(3, missing: ["Acme website"]); $0.scrollEnd = true }
        add("detail-folders-remove-confirm", .detail) {
            $0.target = row(.ready)
            $0.folders = folders(3)
            $0.confirming = { model in model.folderLines.compactMap(\.project).first { $0.name == "Acme website" }.map { .removeFolder($0.id) } }
            $0.scrollEnd = true
        }
        // 상세: Disconnect
        add("detail-disconnect", .detail) { $0.target = row(.unsupported); $0.live = true; $0.since = tenAgo; $0.folders = folders(3); $0.scrollEnd = true }
        add("detail-disconnect-confirm", .detail) { $0.target = row(.unsupported); $0.live = true; $0.since = tenAgo; $0.folders = folders(3); $0.confirming = { _ in .disconnectAgent }; $0.scrollEnd = true }
        add("detail-disconnect-busy", .detail) { $0.target = row(.unsupported); $0.live = true; $0.since = tenAgo; $0.folders = folders(3); $0.confirming = { _ in .disconnectAgent }; $0.busy = .disconnect; $0.scrollEnd = true }
        add("detail-disconnect-failed", .detail) {
            $0.target = row(.unsupported); $0.live = true; $0.since = tenAgo; $0.folders = folders(3); $0.confirming = { _ in .disconnectAgent }
            $0.failure = AgentSettingsModel.Failure(action: .disconnect, text: AgentSettingsCopy.somethingWentWrong); $0.scrollEnd = true
        }
        add("detail-disconnect-offline", .detail) {
            $0.target = row(.unsupported); $0.live = true; $0.since = tenAgo; $0.folders = folders(3); $0.confirming = { _ in .disconnectAgent }
            $0.failure = AgentSettingsModel.Failure(action: .disconnect, text: AgentSettingsCopy.youAreOffline); $0.scrollEnd = true
        }
        add("detail-disconnect-confirm-contrast-more", .detail) { $0.target = row(.unsupported); $0.live = true; $0.since = tenAgo; $0.folders = folders(3); $0.confirming = { _ in .disconnectAgent }; $0.scrollEnd = true; $0.increasedContrast = true }
        // This Mac
        add("detail-mac-name-64", .detail) { $0.target = row(.unsupported); $0.live = true; $0.since = tenAgo; $0.mac = "Daniel Song's Mac Studio in the Life Design office, second floor" }
        add("detail-mac-name-none", .detail) { $0.target = row(.unsupported); $0.live = true; $0.since = tenAgo; $0.mac = nil }
        // 10대
        add("macs-list", .macs) { $0.status = .tooManyBridges; $0.macsRead = macs() }
        add("macs-unnamed-mac", .macs) { $0.status = .tooManyBridges; $0.macsRead = macs(unnamed: true) }
        add("macs-remove-confirm", .macs) { $0.status = .tooManyBridges; $0.macsRead = macs(); $0.confirming = { model in model.macs.first.map { .removeMac($0.id) } } }
        add("macs-remove-busy", .macs) {
            $0.status = .tooManyBridges; $0.macsRead = macs()
            $0.confirming = { model in model.macs.first.map { .removeMac($0.id) } }
            $0.busyRemovingFirstMac = true
        }
        add("macs-after-removal-connect", .list) { $0.status = .connected; $0.target = .rows([]); $0.scrollEnd = true }
        return list
    }

    // MARK: 견본 면

    /// 장면 하나의 값을 그대로 돌려주는 가짜 면 (읽기 · 동작 모두 가짜: 서버 · 런타임 · 폴더 창에 닿지 않는다)
    @MainActor
    final class SampleEnvironment: AgentSettingsEnvironment {
        let scenario: Scenario
        let store: SampleFolderStore

        init(_ scenario: Scenario) {
            self.scenario = scenario
            store = SampleFolderStore(Dictionary(uniqueKeysWithValues: scenario.folders.enumerated().map { (SettingsAgentsSnapshot.projectID($0.offset), $0.element.path) }))
        }

        var canRunAgents: Bool { scenario.canRun }
        var runtimeStatus: BridgeStatus? { scenario.canRun ? scenario.status : nil }
        var runtimeHasLiveProcess: Bool { scenario.live }
        var folders: (any AgentSettingsFolderStore)? { scenario.canRun ? store : nil }
        var homes: [String] { [SettingsAgentsSnapshot.home] }

        func localBridgeID() async -> UUID? { SettingsAgentsSnapshot.bridge }
        func probe() async -> BridgeV1AdapterReport? { scenario.canRun ? scenario.report : nil }
        func refreshProbe() async -> BridgeV1AdapterReport? { scenario.canRun ? scenario.report : nil }
        func liveSince() async -> Date? { scenario.since }
        func deviceName(of bridgeID: UUID) async -> String? { scenario.mac }
        func loadTargets() async -> AgentSettingsTargetsRead { scenario.target }
        func connect() async -> AgentConnectOutcome { .unavailable }
        func reconnect() async -> AgentConnectOutcome { .unavailable }
        func disconnect() async -> AgentDisconnectOutcome { .unavailable }
        func removeMac(_ bridgeID: UUID) async -> AgentRemoveMacOutcome { .refused }
        func macs() async -> [AgentMacRecord]? { scenario.macsRead }

        func projects() async -> [UUID: AgentFolderProject]? {
            Dictionary(uniqueKeysWithValues: scenario.folders.enumerated().map { index, item in
                (SettingsAgentsSnapshot.projectID(index), AgentFolderProject(id: SettingsAgentsSnapshot.projectID(index), name: item.name, icon: item.icon))
            })
        }

        func existingFolders(among paths: [String]) async -> Set<String> {
            let gone = Set(scenario.folders.filter(\.missing).map(\.path))
            return Set(paths).subtracting(gone)
        }

        func pickFolder(
            message: String, prompt: String, rejection: String, accepts: @escaping @Sendable (String) -> Bool, reason: @escaping @Sendable (String) -> String
        ) async -> String? { nil }

        func requestNotificationPermission() async {}
    }

    static func projectID(_ index: Int) -> UUID { UUID(uuidString: String(format: "aaaaaaaa-0000-4000-8000-%012d", index + 1))! }

    /// 견본 폴더 등록부: 값만 돌려준다 (규칙 · 디스크 0)
    final class SampleFolderStore: AgentSettingsFolderStore, @unchecked Sendable {
        private let folders: [UUID: String]

        init(_ folders: [UUID: String]) {
            self.folders = folders
        }

        func projectFolders() -> [UUID: String] { folders }
        func accepts(path: String, scope: AgentWorkspaceGate.Scope) -> Bool { false }
        func rejectionMessage(forPath path: String, scope: AgentWorkspaceGate.Scope) -> String { AgentWorkspaceCopy.rejected }
        func register(path: String, scope: AgentWorkspaceGate.Scope) throws {}
        func removeFolder(forProject contextID: UUID) {}
    }
}
#endif
