#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

// 레일 "On this Mac" (OA 외부 세션 PR1, DZ 승인 2026-10-21 · 계약 16–17장): 이 Mac의 Claude Code 세션 중 Taskforce 밖에서 시작한 것을 폴더별로 보인다.
// 판정 · 읽기는 Kit(`ExternalSessionScanner`)이 하고 여기는 패널 화면 · 이 Mac의 값을 대는 일 · Claude 앱 열기(Open in Claude: 그 세션을 데스크톱 앱에서 연다, F4)뿐이다. 이어받기(Resume here · 확인 줄)는 다음 PR이라 줄에 없다.
// 글 · 경로 · 세션 id를 로그에 남기지 않는다.

/// Claude 데스크톱 앱 열기. 시험은 가짜로 바꾼다
@MainActor
protocol ClaudeAppOpening {
    /// 앱만 앞으로 가져왔으면 true (설치되어 있지 않거나 열지 못하면 false). 세션을 열지 못했을 때 물러나는 길이다
    func openClaudeApp() -> Bool
    /// 그 세션을 데스크톱 앱에서 연다: 사용자의 `claude --desktop --resume <id>`를 그 세션의 폴더에서 (`ClaudeDesktopSessionOpener`). 앱이 앞으로 오는 것은 `claude`가 한다.
    /// `.unavailable`이면 부른 쪽이 `openClaudeApp()`으로 물러난다
    func openSession(id: String, folder: String?) async -> ClaudeDesktopOpenResult
}

@MainActor
struct LiveClaudeAppOpener: ClaudeAppOpening {
    /// Claude 데스크톱 앱의 번들 id (이 Mac의 앱 메타데이터로 확인)
    static let bundleID = "com.anthropic.claudefordesktop"

    /// 이 Mac의 `claude` · 실제 폴더 규칙으로 만든 열기 (시험은 바꾼다)
    var makeOpener: @MainActor () -> ClaudeDesktopSessionOpener = { LiveClaudeAppOpener.standardOpener() }

    /// 폴더 규칙은 사용자가 폴더를 고를 때와 같은 `.standard`: 앱 데이터 · bridge 폴더 보호 목록은 지금 계정의 것이다. 로그는 고정 코드뿐 (id · 경로 · 출력 글 0)
    static func standardOpener(home: String = NSHomeDirectory()) -> ClaudeDesktopSessionOpener {
        let protectedRoots = BridgeHost.shared?.externalSessionPaths()?.protectedRoots ?? []
        return ClaudeDesktopSessionOpener(locator: .standard(home: home), folderRules: .standard(home: home, protectedRoots: protectedRoots), log: BridgeOSLog())
    }

    func openClaudeApp() -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        return true
    }

    func openSession(id: String, folder: String?) async -> ClaudeDesktopOpenResult {
        await makeOpener().open(sessionID: id, folder: folder)
    }
}

/// 패널 본문: 처음 읽는 동안 "Checking…", 비면 한 줄, Claude Code 없음 · 읽기 실패는 버튼 하나, 그 밖은 폴더별 묶음 (묶음 머리 = Taskforce 프로젝트 폴더면 프로젝트 이름, 아니면 폴더 이름)
struct ExternalSessionsPanelBody: View {
    @Bindable var shell: EdgeShellModel
    @State private var expanded: Set<String> = []

    var body: some View {
        if let store = shell.externalSessions {
            content(store)
        }
    }

    @ViewBuilder
    private func content(_ store: ExternalSessionsStore) -> some View {
        switch store.phase {
        case .idle, .checking:
            Text(ExternalSessionCopy.checking)
                .font(TFFont.callout)
                .foregroundStyle(TFColor.textSecondary)
                .padding(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
                .frame(maxWidth: .infinity, alignment: .leading)
        case .empty:
            PanelEmptyState(title: ExternalSessionCopy.empty) {}
        case .notInstalled:
            PanelEmptyState(title: ExternalSessionCopy.notInstalled) {
                // Settings › Your agents (Connections 탭)
                Button(ExternalSessionCopy.getClaudeCode) { shell.onConnect() }.buttonStyle(TFButtonStyle(.primary, size: .md))
            }
        case .failed:
            PanelEmptyState(title: ExternalSessionCopy.couldNotCheckSessions) {
                Button(ExternalSessionCopy.tryAgain) { store.retry() }.buttonStyle(TFButtonStyle(.secondary, size: .md))
            }
        case .ready:
            // 시각("2 min ago")이 열려 있는 동안 흐르게 30초마다 다시 그린다
            TimelineView(.periodic(from: .now, by: 30)) { context in
                list(store.rows, now: context.date)
            }
        }
    }

    private func list(_ rows: [ExternalSessionRow], now: Date) -> some View {
        let groups = ExternalSessionGrouping.groups(rows, projectName: { shell.externalProjectName(forFolder: $0) })
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(groups) { group in
                let open = expanded.contains(group.id)
                if let name = group.name {
                    GroupLabel(name) {
                        if group.rows.count > ExternalSessionGrouping.visibleLimit {
                            QuietLink(open ? ExternalSessionCopy.showLess : ExternalSessionCopy.showAll) { toggle(group.id) }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(ExternalSessionGrouping.visibleRows(group, expanded: open)) { row in
                        ExternalSessionLineView(content: shell.externalLine(row, now: now)) { action in
                            switch action {
                            case .openInClaude: shell.openInClaude(row)
                            }
                        }
                    }
                }
            }
        }
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}

extension EdgeShellModel {
    /// 묶음 폴더가 Taskforce 프로젝트의 작업 폴더와 같으면 그 프로젝트 이름 (보관한 프로젝트는 뺀다). 아니면 nil → 폴더 이름
    func externalProjectName(forFolder path: String) -> String? {
        guard let id = projectFolders().first(where: { $0.value == path })?.key,
              let context = contextList.first(where: { $0.id == id && $0.status == .active }) else { return nil }
        return context.name
    }
}

/// 이 Mac의 값을 한 곳에서 댄다: 활성 계정의 파티션(열쇠 · Taskforce 세션 폴더) · bridge id · Claude Code probe(설치 · 버전). 계정(파티션)이 바뀌면 스캐너를 새로 만든다.
/// 훑기는 메인 밖(스캐너 actor)에서 하고, 메인에서는 값만 읽는다
final class ExternalSessionsEnvironment: @unchecked Sendable {
    static let adapterID = "agent:claude-code"
    /// probe(`claude --version`)를 다시 하는 간격
    static let probeInterval: TimeInterval = 60

    private struct Context: Sendable {
        let paths: BridgeHost.ExternalSessionPaths
        let runtime: BridgeRuntime?
    }

    private let host: @MainActor @Sendable () -> BridgeHost?
    private let home: String
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    private var scanner: (partition: String, scanner: ExternalSessionScanner)?
    private var probed: (partition: String, installed: Bool?, version: String?, at: Date)?
    private var currentVersion: String?

    init(host: @escaping @MainActor @Sendable () -> BridgeHost?, home: String = NSHomeDirectory(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.host = host
        self.home = home
        self.clock = clock
    }

    private func context() async -> Context? {
        let host = host
        return await MainActor.run {
            guard let bridge = host(), let paths = bridge.externalSessionPaths() else { return nil }
            return Context(paths: paths, runtime: bridge.activeRuntime)
        }
    }

    /// Claude Code 설치 · 버전 (60초에 한 번만 probe). 런타임이 없으면 모른다(nil)
    private func probe(_ context: Context) async -> (installed: Bool?, version: String?) {
        let now = clock()
        if let probed = lock.withLock({ probed }), probed.partition == context.paths.partition.id, now.timeIntervalSince(probed.at) < Self.probeInterval {
            return (probed.installed, probed.version)
        }
        var installed: Bool?
        var version: String?
        if let runtime = context.runtime, let report = await runtime.adapterReports().first(where: { $0.adapter == Self.adapterID }) {
            installed = report.installed
            version = report.version
        }
        lock.withLock {
            probed = (context.paths.partition.id, installed, version, now)
            currentVersion = version
        }
        return (installed, version)
    }

    func isInstalled() async -> Bool? {
        guard let context = await context() else { return nil }
        return await probe(context).installed
    }

    /// 훑는다. 훑기 시작에 잡은 계정 · bridge를 결과에 싣는다 (`ExternalSessionScan.origin`): 서버 보고는 이 값으로만 나간다
    func scan() async -> ExternalSessionScan {
        guard let context = await context() else { return ExternalSessionScan(rows: [], failure: .unreadable) }
        let origin = await origin(of: context)
        _ = await probe(context)
        guard let scanner = makeScanner(context) else { return ExternalSessionScan(rows: [], failure: .unreadable, origin: origin) }
        var result = await scanner.scan()
        result.origin = origin
        return result
    }

    /// 이 계정 파티션 + 이 Mac의 bridge id. bridge가 아직 등록되지 않았으면 nil
    private func origin(of context: Context) async -> ExternalSessionOrigin? {
        guard let runtime = context.runtime, let bridge = await runtime.localBridgeID() else { return nil }
        return ExternalSessionOrigin(partition: context.paths.partition.id, bridgeID: bridge)
    }

    /// 지금의 계정 · bridge (로그아웃 · 다른 계정이면 nil 또는 다른 값)
    func currentOrigin() async -> ExternalSessionOrigin? {
        guard let context = await context() else { return nil }
        return await origin(of: context)
    }

    /// 서버에 알린다: 훑을 때 잡은 계정 · bridge로만. 보내기 직전에 지금의 값과 다르면 버린다. 훑을 때 bridge가 없었으면 알리지 않는다
    func report(_ rows: [ExternalSessionRow], origin: ExternalSessionOrigin?, via reporter: ExternalSessionReporter) async {
        guard let origin else { return }
        await reporter.report(rows, origin: origin, current: { await self.currentOrigin() })
    }

    /// 로그아웃 직전 (`SessionStore.onSigningOut`, 옛 토큰이 살아 있는 동안): 이 Mac의 서버 목록(제목)을 비우고 이 계정의 열쇠를 지운다. 끝나면 스캐너(열쇠를 쥐고 있다)도 버린다
    func signingOut(via reporter: ExternalSessionReporter) async {
        let context = await context()
        var bridge: UUID?
        if let runtime = context?.runtime { bridge = await runtime.localBridgeID() }
        let keyStore = context.map { FileExternalSessionKeyStore(directory: $0.paths.partitionDirectory) }
        await ExternalSessionSignOut.run(bridgeID: bridge, reporter: reporter, keyStore: keyStore)
        lock.withLock { scanner = nil }
    }

    private func makeScanner(_ context: Context) -> ExternalSessionScanner? {
        let id = context.paths.partition.id
        if let existing = lock.withLock({ scanner }), existing.partition == id { return existing.scanner }
        // 열쇠를 두지 못하면 목록을 내지 않는다 (id 없이 서버로 보낼 수 없다)
        guard let key = try? FileExternalSessionKeyStore(directory: context.paths.partitionDirectory).loadOrCreate() else { return nil }
        let sessionsRoot = context.paths.sessionsRoot
        let configuration = ExternalSessionScanner.Configuration(
            claudeDirectory: home + "/.claude", folderRules: ExternalSessionFolderRules.lexical(home: home, protectedRoots: context.paths.protectedRoots),
            protectedRoots: context.paths.protectedRoots, taskforceSessionIDs: { Self.taskforceSessionIDs(sessionsRoot: sessionsRoot) },
            installedCLIVersion: { [weak self] in self?.lock.withLock { self?.currentVersion } }
        )
        let made = ExternalSessionScanner(configuration: configuration, key: key)
        lock.withLock { scanner = (id, made) }
        return made
    }

    /// Taskforce가 띄운 세션의 Claude id (세션 폴더의 `state.json`): 목록에서 뺀다
    static func taskforceSessionIDs(sessionsRoot: URL) -> Set<String> {
        let folders = (try? FileManager.default.contentsOfDirectory(at: sessionsRoot, includingPropertiesForKeys: nil)) ?? []
        return Set(folders.compactMap { ClaudeSessionState.load(from: $0).providerSessionID?.lowercased() })
    }
}

enum ExternalSessionsRuntime {
    /// 이 실행에서 목록이 있나: 새 Issues 화면(캡슐 레일) ∧ `BridgeFlag` ∧ 서비스 · 계정 경계가 있다. 로그인은 셸 모델이 본다 (`externalSessionsVisible`)
    /// - session: Sign Out을 누르면 세션을 지우기 전에 서버에 올린 제목 목록을 비우고 열쇠를 지운다 (`SessionStore.onSigningOut`, 옛 토큰이 살아 있는 동안만 할 수 있다)
    @MainActor
    static func make(
        services: AppServices?, scope: AccountScope?, issueScreens: Bool, bridgeEnabled: Bool = BridgeFlag.current,
        host: @escaping @MainActor @Sendable () -> BridgeHost? = { BridgeHost.shared }, session: SessionStore? = nil,
        seen: any ExternalSessionSeenStore = UserDefaultsExternalSessionSeenStore()
    ) -> ExternalSessionsStore? {
        guard issueScreens, bridgeEnabled, let services, let scope else { return nil }
        let environment = ExternalSessionsEnvironment(host: host)
        let api = services.api
        let log = BridgeOSLog()
        let reporter = ExternalSessionReporter(send: { bridge, rows in try await api.reportExternalSessions(bridgeID: bridge, rows: rows) }, log: log)
        scope.onLeft { Task { await reporter.reset() } }
        session?.onSigningOut { await environment.signingOut(via: reporter) }
        return ExternalSessionsStore(
            scope: scope, scan: { await environment.scan() }, isInstalled: { await environment.isInstalled() },
            report: { rows, origin in await environment.report(rows, origin: origin, via: reporter) },
            shown: { rows, held in (try? await api.externalSessionsShown(rowsBucket: rows, heldBucket: held)) != nil }, seen: seen, log: log
        )
    }
}

#if DEBUG
/// 디자인 비교용 견본 (Debug 전용, Release 바이너리에 없다): `-TF_EDGE_SHELL YES -TFSampleData -TF_S3B YES -TF_U2 YES -TFEdgeSnapshot <폴더> -TFEdgeSnapshotIssues -TFEdgeSnapshotExternalSessions`
/// (+ `-TFSnapshotDark`). 이 Mac의 실제 Claude 기록 · 프로세스 · 서버를 읽지 않는다: 줄은 모두 만든 값이다 (`mac-edge-external-<이름>.png`).
/// 남기는 것: rail-dot · rail-open · mixed(DZ-02 맨 위) · many(17줄, Show all/Show less) · blocked(막힌 줄 모두) · long(긴 제목) · empty · not-installed · failed · checking
@MainActor
enum ExternalSessionSnapshot {
    nonisolated static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("-TFEdgeSnapshotExternalSessions") }

    nonisolated enum Scenario { case mixed, many, blocked, long, empty, notInstalled, failed, checking }

    nonisolated(unsafe) static var scenario = Scenario.mixed
    /// 견본이 보는 "지금"
    nonisolated static let now = Date()

    nonisolated private static func row(
        _ n: Int, _ title: String?, group: String, status: ExternalSessionStatus, client: ExternalSessionClient? = .terminal, minutes: Double, created: Date? = nil, folder: String? = nil
    ) -> ExternalSessionRow {
        let path = "/Users/sample/" + group
        return ExternalSessionRow(
            id: String(format: "5e5e5e5e-0000-4000-8000-%012x", n), ref: String(repeating: "d", count: 64), title: title, folderPath: folder ?? path, groupPath: path,
            lastActivity: now.addingTimeInterval(-minutes * 60), created: created ?? now.addingTimeInterval(-minutes * 60), client: client, status: status
        )
    }

    nonisolated static func rows(_ scenario: Scenario) -> [ExternalSessionRow] {
        switch scenario {
        case .mixed:
            return [
                row(1, "Fix launcher focus after sleep when the panel is open", group: "taskforce", status: .held(.claudeApp), client: .claudeDesktop, minutes: 2),
                row(2, "Add RLS test for agent_sessions", group: "taskforce", status: .held(.terminal), minutes: 0.2),
                row(3, "Rewrite the pricing page copy for the 3-day trial banner", group: "taskforce", status: .available, client: .claudeDesktop, minutes: 40),
                row(4, "Remotion launch video storyboard", group: "taskforce", status: .inTaskforce, minutes: 3),
                row(5, "Hero section motion pass", group: "life-design-site", status: .held(.unknown), minutes: 4),
                row(6, "가격 페이지 FAQ 문구 다듬기", group: "life-design-site", status: .available, client: .claudeDesktop, minutes: 60 * 30),
                row(7, "Banner variants", group: "life-design-site", status: .cannotResume(.worktree), client: .claudeDesktop, minutes: 120),
                row(8, "Dependency bump", group: "thesvg-marks", status: .couldNotCheck, client: .claudeDesktop, minutes: 60),
            ]
        case .many:
            let titles = [
                "Spike: bridge reconnect backoff", "Review migration order for the invoice tables", "Pricing tone options", "Weekly review notes", "notes", "Tidy the Settings window copy",
                "Update the Settings window copy", "Source marks audit", "Fix OG image cache headers", "Remove dead feature flags", "Check launch checklist", "Release notes draft",
                "Investigate flaky test", "Rename Chats section", "Try Lucide laptop icon", "Compare rail dot options", "Kit scanner limits",
            ]
            return titles.enumerated().map { i, title in
                row(100 + i, title, group: i < 11 ? "shape-launch" : "notes", status: i == 3 ? .cannotResume(.updateClaudeCode) : .available, client: i % 2 == 0 ? .terminal : .claudeDesktop, minutes: 30 + Double(i) * 70)
            }
        case .blocked:
            return [
                row(200, "Banner variants", group: "life-design-site", status: .cannotResume(.worktree), client: .claudeDesktop, minutes: 120),
                row(201, "Clean up the home folder", group: "home", status: .cannotResume(.folderNotAllowed), minutes: 300),
                row(202, nil, group: "notes", status: .cannotResume(.unreadable), minutes: 360, folder: nil),
                row(203, "Weekly review notes", group: "notes", status: .cannotResume(.updateClaudeCode), minutes: 60 * 24 * 4),
                row(204, "Launch checklist pass", group: "notes", status: .couldNotCheck, client: .claudeDesktop, minutes: 70),
            ]
        case .long:
            return [
                row(300, "Investigate why the launcher loses keyboard focus when the Mac wakes from sleep while a Claude desktop session is running in the background", group: "a-very-long-project-folder-name-that-keeps-going-and-going", status: .held(.claudeApp), client: .claudeDesktop, minutes: 5),
                row(301, "Rewrite the pricing page copy for the three day trial banner and the annual plan comparison table including the refund wording", group: "a-very-long-project-folder-name-that-keeps-going-and-going", status: .available, client: .claudeDesktop, minutes: 50),
                row(302, "Can't resume this one", group: "a-very-long-project-folder-name-that-keeps-going-and-going", status: .cannotResume(.folderNotAllowed), client: .claudeDesktop, minutes: 60 * 6),
            ]
        case .empty, .notInstalled, .failed, .checking:
            return []
        }
    }

    /// 견본 목록: 가짜 훑기(시나리오대로), 가짜 설치 판정, 서버 보고 · 지표 없음. 기준 시각이 아주 옛날이라 모든 줄이 "새것"이어서 점이 보인다
    static func sampleStore(scope: AccountScope?) -> ExternalSessionsStore? {
        guard let scope else { return nil }
        return ExternalSessionsStore(
            scope: scope,
            scan: {
                switch scenario {
                case .failed: return ExternalSessionScan(rows: [], failure: .unreadable)
                case .checking:
                    try? await Task.sleep(for: .seconds(600))
                    return ExternalSessionScan(rows: [])
                default: return ExternalSessionScan(rows: rows(scenario))
                }
            },
            isInstalled: { scenario == .notInstalled ? false : true }, seen: InMemoryExternalSessionSeenStore(Date(timeIntervalSince1970: 0)), pollInterval: 3600
        )
    }

    static func capture(_ edge: EdgeShellController, file: (String) -> URL, pause: @escaping (Double) async -> Void) async {
        let shell = edge.shell
        guard let store = shell.externalSessions else {
            print("ExternalSessionSnapshot: 목록이 꺼진 구성이다 (-TF_EDGE_SHELL YES -TFSampleData -TF_S3B YES -TF_U2 YES 필요) visible=\(shell.externalSessionsVisible)")
            return
        }
        shell.projectFolders = { [IssueSnapshotData.taskforce: "/Users/sample/taskforce"] }
        func shoot(_ name: String) { EdgeSnapshot.capture(edge, to: file("external-\(name)")) }
        func show(_ next: Scenario, _ name: String, settle: Double = 0.9) async {
            scenario = next
            store.reset()
            shell.openAllWork()
            await pause(0.3)
            shell.openOnThisMac()
            await pause(settle)
            shoot(name)
        }
        // 레일: 점(새 세션) → 열림(입구가 칠해지고 점이 사라진다)
        scenario = .mixed
        shell.dismiss()
        shell.pointer(inside: true)
        await pause(0.6)
        await store.refresh()
        await pause(0.5)
        shoot("rail-dot")
        shell.openOnThisMac()
        await pause(0.9)
        shoot("rail-open")
        await show(.mixed, "mixed")
        await show(.many, "many")
        scenario = .many
        await store.refresh()
        await pause(0.5)
        // Show all: 묶음 머리 오른쪽 링크를 누른 모양은 화면 상태라 여기서는 처음 모양만 남긴다
        await show(.blocked, "blocked")
        await show(.long, "long")
        await show(.empty, "empty")
        await show(.notInstalled, "not-installed")
        await show(.failed, "failed")
        await show(.checking, "checking", settle: 0.4)
        store.reset()
    }
}
#endif
#endif
