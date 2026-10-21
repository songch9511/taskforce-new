#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

// 레일 "On this Mac" (OA 외부 세션 PR1, DZ 승인 2026-10-21 · 계약 16–17장): 이 Mac의 Claude Code 세션 중 Taskforce 밖에서 시작한 것을 폴더별로 보인다.
// 판정 · 읽기는 Kit(`ExternalSessionScanner`)이 하고 여기는 패널 화면 · 이 Mac의 값을 대는 일 · Claude 앱 열기뿐이다. 이어받기(Resume here · 확인 줄)는 다음 PR이라 줄에 없다.
// 글 · 경로 · 세션 id를 로그에 남기지 않는다.

/// Claude 데스크톱 앱만 앞으로 가져온다 (인자 0, 그 세션을 열지는 않는다). 시험은 가짜로 바꾼다
@MainActor
protocol ClaudeAppOpening {
    /// 앱을 앞으로 가져왔으면 true (설치되어 있지 않거나 열지 못하면 false)
    func openClaudeApp() -> Bool
}

@MainActor
struct LiveClaudeAppOpener: ClaudeAppOpening {
    /// Claude 데스크톱 앱의 번들 id (이 Mac의 앱 메타데이터로 확인)
    static let bundleID = "com.anthropic.claudefordesktop"

    func openClaudeApp() -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        return true
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
                Button(ExternalSessionCopy.tryAgain) { Task { await store.refresh() } }.buttonStyle(TFButtonStyle(.secondary, size: .md))
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
                        ExternalSessionLineView(content: ExternalSessionLineText.make(row, now: now)) { action in
                            switch action {
                            case .openInClaude: shell.openInClaude()
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

    func scan() async -> ExternalSessionScan {
        guard let context = await context() else { return ExternalSessionScan(rows: [], failure: .unreadable) }
        _ = await probe(context)
        guard let scanner = makeScanner(context) else { return ExternalSessionScan(rows: [], failure: .unreadable) }
        return await scanner.scan()
    }

    /// 서버에 알린다 (이 Mac의 bridge가 등록돼 있을 때만)
    func report(_ rows: [ExternalSessionRow], via reporter: ExternalSessionReporter) async {
        guard let context = await context(), let runtime = context.runtime, let bridge = await runtime.localBridgeID() else { return }
        await reporter.report(rows, bridgeID: bridge)
    }

    private func makeScanner(_ context: Context) -> ExternalSessionScanner? {
        let id = context.paths.partition.id
        if let existing = lock.withLock({ scanner }), existing.partition == id { return existing.scanner }
        // 열쇠를 두지 못하면 목록을 내지 않는다 (id 없이 서버로 보낼 수 없다)
        guard let key = try? FileExternalSessionKeyStore(directory: context.paths.partitionDirectory).loadOrCreate() else { return nil }
        let sessionsRoot = context.paths.sessionsRoot
        let configuration = ExternalSessionScanner.Configuration(
            claudeDirectory: home + "/.claude", folderRules: WorkspaceFolderRules.standard(home: home, protectedRoots: context.paths.protectedRoots),
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
    @MainActor
    static func make(
        services: AppServices?, scope: AccountScope?, issueScreens: Bool, bridgeEnabled: Bool = BridgeFlag.current,
        host: @escaping @MainActor @Sendable () -> BridgeHost? = { BridgeHost.shared },
        seen: any ExternalSessionSeenStore = UserDefaultsExternalSessionSeenStore()
    ) -> ExternalSessionsStore? {
        guard issueScreens, bridgeEnabled, let services, let scope else { return nil }
        let environment = ExternalSessionsEnvironment(host: host)
        let api = services.api
        let reporter = ExternalSessionReporter(send: { bridge, rows in try await api.reportExternalSessions(bridgeID: bridge, rows: rows) })
        scope.onLeft { Task { await reporter.reset() } }
        return ExternalSessionsStore(
            scope: scope, scan: { await environment.scan() }, isInstalled: { await environment.isInstalled() },
            report: { rows in await environment.report(rows, via: reporter) },
            shown: { rows, held in try? await api.externalSessionsShown(rowsBucket: rows, heldBucket: held) }, seen: seen
        )
    }
}
#endif
