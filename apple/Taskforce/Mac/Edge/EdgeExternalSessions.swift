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
    nonisolated static let bundleID = "com.anthropic.claudefordesktop"

    /// 이 Mac의 `claude` · 실제 폴더 규칙으로 만든 열기 (시험은 바꾼다). nil이면 열지 않는다 (fail-closed)
    var makeOpener: @MainActor () -> ClaudeDesktopSessionOpener? = { LiveClaudeAppOpener.standardOpener() }

    /// Claude 데스크톱 앱이 이 Mac에 있나 (보안 검토 P2-2): 없으면 `claude --desktop`을 띄우지 않는다. 막을 수 있는 호출이 아니라 아무 스레드에서나 부른다
    nonisolated static func isClaudeAppInstalled() -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// 폴더 규칙은 사용자가 폴더를 고를 때와 같은 `.standard`: 앱 데이터 · bridge 폴더 보호 목록은 지금 계정의 것이다. **그 목록을 모르면(이 계정의 bridge가 없다) 규칙을 세울 수 없다: 열지 않는다 (fail-closed).**
    /// 로그는 고정 코드뿐 (id · 경로 · 출력 글 0)
    static func standardOpener(home: String = NSHomeDirectory()) -> ClaudeDesktopSessionOpener? {
        guard let paths = BridgeHost.shared?.externalSessionPaths() else { return nil }
        return ClaudeDesktopSessionOpener(
            locator: .standard(home: home), folderRules: .standard(home: home, protectedRoots: paths.protectedRoots), desktopInstalled: { isClaudeAppInstalled() }, log: BridgeOSLog()
        )
    }

    func openClaudeApp() -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        return true
    }

    func openSession(id: String, folder: String?) async -> ClaudeDesktopOpenResult {
        guard let opener = makeOpener() else { return .unavailable }
        return await opener.open(sessionID: id, folder: folder)
    }
}

/// Sessions 패널 본문 (OA PR-D2, DZ 승인 2026-10-22 `oa-rail-sessions-dz`): 출처별 두 절 — "Taskforce"(이슈의 세션: 도는 것 · 끝난 것 · 쉬는 것 · 닫힌 것)와 "On this Mac"(이 Mac의 Claude 세션).
/// 링 있는 줄은 늘 보이고, 쉬는 줄 · 끝난 줄만 절마다 셋 뒤로 접는다 (Show all · Show less). 빈 절은 머리째 없고 두 절이 모두 비면 "No sessions".
/// On this Mac의 읽는 중 · 못 읽음 · Claude Code 없음은 그 절 안의 한 줄이다 (Taskforce 세션은 그대로 보인다). 줄 순서 · 접기 · 문구는 Kit의 `SessionsPanelRules`가 정한다
struct SessionsPanelBody: View {
    @Bindable var shell: EdgeShellModel
    @State private var taskforceExpanded = false
    @State private var macExpanded = false
    @State private var codexExpanded = false
    @State private var codexSessions: [CodexLocalSession] = []
    @State private var codexFailed = false
    @State private var codexLoaded = false
    private let codexReader = CodexLocalSessionReader()

    var body: some View {
        // 시각("2 min ago")이 열려 있는 동안 흐르게 30초마다 다시 그린다
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .task(id: codexReadAccount) {
            guard codexReadAccount != nil, Self.readsLiveCodexSessions else {
                codexSessions = []; codexFailed = false; codexLoaded = true
                return
            }
            while !Task.isCancelled {
                let result = await codexReader.read()
                guard !Task.isCancelled else { return }
                codexLoaded = true
                switch result {
                case .sessions(let rows):
                    codexSessions = rows.filter { !shell.codexChatRuntime.isManagedThread($0.id) }
                    codexFailed = false
                case .unreadable: codexSessions = []; codexFailed = true
                }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private var codexReadAccount: UUID? {
        shell.externalSessionsVisible && shell.panelOpen && shell.view == .sessions ? shell.account : nil
    }

    /// Sample captures and XCTest hosts must never read the user's local Codex index.
    static var readsLiveCodexSessions: Bool {
        #if DEBUG
        if SampleData.isEnabled || ExternalSessionSnapshot.isEnabled { return false }
        #endif
        return !TestHost.isTestHost()
    }

    /// On this Mac 절이 무엇을 보이나
    enum MacPlan: Equatable {
        /// 절이 없다 (목록이 없다 · 보일 줄이 없다 · 최근 세션이 없다)
        case absent
        case checking
        case notInstalled
        case failed
        case rows
    }

    /// 패널이 무엇을 보이나 (순수한 판단: 시험이 단계마다 확인한다)
    struct Plan: Equatable {
        /// 세 절이 모두 비어 패널 전체가 "No sessions"
        var noSessions: Bool
        var taskforce: Bool
        var mac: MacPlan
        /// Saved chats 절 (OA D3v-m): 읽었는데 비면(서버 gate가 꺼졌거나 저장된 대화가 없다) `.absent` — 빈 상태 글이 없다
        var saved: SavedChatsStore.SectionState = .absent
    }

    /// - phase: On this Mac 목록의 단계 (목록이 없으면 nil) · taskforceRead: Taskforce 세션을 한 번이라도 읽었다. **아직 읽는 중인 절이 있으면 비었다고 하지 않는다** ("No sessions"는 모든 절을 읽은 뒤에만)
    /// - saved: Saved chats 절의 상태 (저장소가 없으면 `.absent`). 읽는 중 · 읽기 실패의 절이 보이면 패널은 "No sessions"가 아니다
    static func plan(
        taskforce: SessionsSection<SessionsTaskforceRow>, mac: SessionsSection<SessionsMacRow>, phase: ExternalSessionsStore.Phase?, taskforceRead: Bool,
        saved: SavedChatsStore.SectionState = .absent
    ) -> Plan {
        let settled = taskforceRead && (phase.map { $0 == .empty || $0 == .ready } ?? true)
        // 저장된 대화 절이 보이면(읽는 중 · 읽기 실패 · 줄) "No sessions"가 아니다. 읽었는데 비었으면(`.absent`) 다른 절이 모두 비었을 때 "No sessions" 하나다
        if settled, saved == .absent, SessionsPanelRules.isEmpty(taskforce: taskforce, mac: mac) { return Plan(noSessions: true, taskforce: false, mac: .absent) }
        let macPlan: MacPlan
        switch phase {
        case nil, .empty?: macPlan = .absent
        case .idle?, .checking?: macPlan = .checking
        case .notInstalled?: macPlan = .notInstalled
        case .failed?: macPlan = .failed
        case .ready?: macPlan = mac.isEmpty ? .absent : .rows
        }
        return Plan(noSessions: false, taskforce: !taskforce.isEmpty, mac: macPlan, saved: saved)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let store = shell.externalSessionsVisible ? shell.externalSessions : nil
        let taskforce = SessionsPanelRules.taskforce(
            shell.issues?.sessions.items ?? [], issueNumber: { shell.issues?.numbers.number(for: $0) }, now: now, expanded: taskforceExpanded
        )
        let mac = macSection(store, now: now)
        // 저장된 대화 (OA D3v-m): 목록과 같은 게이트. 읽었는데 비면 절이 없다
        let savedStore = shell.savedChatsVisible ? shell.savedChats : nil
        let saved = savedStore?.section(expanded: shell.savedChatsExpanded)
        let plan = Self.plan(taskforce: taskforce, mac: mac, phase: store?.phase, taskforceRead: shell.issues?.sessions.hasRead ?? true, saved: saved?.state ?? .absent)
        if plan.noSessions && codexLoaded && codexSessions.isEmpty && !codexFailed {
            PanelEmptyState(title: SessionsPanelCopy.noSessions) {}
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if plan.taskforce {
                    SessionsSectionHeader(SessionsPanelCopy.taskforce, togglesFold: taskforce.togglesFold, expanded: taskforce.expanded) { taskforceExpanded.toggle() }
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(taskforce.rows) { row in
                            SessionsTaskforceRowView(row, current: shell.sessionPanelID == row.id) { shell.openSessionRow(row.id) }
                        }
                    }
                }
                if let store { onThisMac(store, plan: plan.mac, section: mac) }
                codexSection
                if let savedStore, let saved { savedChats(savedStore, section: saved, now: now) }
            }
        }
    }

    @ViewBuilder private var codexSection: some View {
        if !codexSessions.isEmpty || codexFailed {
            SessionsSectionHeader("Codex on this Mac", togglesFold: codexSessions.count > 3, expanded: codexExpanded) { codexExpanded.toggle() }
            if codexFailed {
                SessionsSectionNote("Couldn’t read Codex sessions")
            }
            ForEach(codexExpanded ? codexSessions : Array(codexSessions.prefix(3))) { session in
                Button {
                    shell.openCodexSession(session)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        AgentMark(.codex, size: 20).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(session.title).font(TFFont.callout).foregroundStyle(TFColor.textPrimary).lineLimit(1)
                            Text("Local session").font(TFFont.footnote).foregroundStyle(TFColor.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right").foregroundStyle(TFColor.textSecondary)
                    }
                    .padding(.vertical, 8).padding(.horizontal, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(session.title) — Open session")
            }
        }
    }

    /// Saved chats 절 (OA D3v-m, DZ 시트 1 · 4 · 5): 세 번째 절. 처음 셋 + Show all(읽어 둔 20개), 끝의 Show earlier가 20개씩 더 읽는다. 읽는 중 · 읽기 실패는 절 안의 한 줄 (위 절은 그대로).
    /// 읽었는데 비면 절이 머리째 없다 (빈 상태 글 없음: 서버 gate가 꺼져 읽기가 비는 경우도 같다)
    @ViewBuilder
    private func savedChats(_ store: SavedChatsStore, section: SavedChatsSection, now: Date) -> some View {
        switch section.state {
        case .absent:
            EmptyView()
        case .checking:
            SessionsSectionHeader(SavedChatsCopy.title, togglesFold: false, expanded: false) {}
            SessionsSectionNote(ExternalSessionCopy.checking)
        case .failed:
            SessionsSectionHeader(SavedChatsCopy.title, togglesFold: false, expanded: false) {}
            SessionsSectionNote(SavedChatsCopy.couldNotLoad) {
                Button(ExternalSessionCopy.tryAgain) { store.retry() }.buttonStyle(TFButtonStyle(.secondary, size: .sm))
            }
        case .rows:
            SessionsSectionHeader(SavedChatsCopy.title, togglesFold: section.fold.togglesFold, expanded: section.fold.expanded) { shell.savedChatsExpanded.toggle() }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(section.fold.visible) { row in
                    SavedChatRowView(row, now: now, current: shell.savedChatPanelID == row.id) {
                        shell.openSavedChat(row.id)
                    } onDelete: {
                        shell.openSavedChat(row.id, confirmDelete: true)
                    }
                }
            }
            if section.showsEarlier {
                HStack {
                    Spacer(minLength: 0)
                    QuietLink(SessionViewCopy.showEarlier) { Task { await store.loadMore() } }
                        .disabled(store.loadingMore)
                    Spacer(minLength: 0)
                }
                .padding(.top, TFSpace.md)
            }
        }
    }

    /// On this Mac 절의 줄: 훑은 줄이 있을 때만 (`.ready`)
    private func macSection(_ store: ExternalSessionsStore?, now: Date) -> SessionsSection<SessionsMacRow> {
        guard let store, store.phase == .ready else { return SessionsSection(rows: [], hiddenCount: 0, togglesFold: false, expanded: false) }
        return SessionsPanelRules.onThisMac(
            store.rows, live: { shell.desktop?.liveStatus(for: $0) }, now: now, expanded: macExpanded,
            notice: shell.openNoticeSessionID.map { ($0, ExternalSessionCopy.runningInTerminal) }, busy: shell.openingSessionIDs, attach: shell.attachPresentation
        )
    }

    @ViewBuilder
    private func onThisMac(_ store: ExternalSessionsStore, plan: MacPlan, section: SessionsSection<SessionsMacRow>) -> some View {
        switch plan {
        case .absent:
            EmptyView()
        case .checking:
            SessionsSectionHeader(SessionsPanelCopy.onThisMac, togglesFold: false, expanded: false) {}
            SessionsSectionNote(ExternalSessionCopy.checking)
        case .notInstalled:
            SessionsSectionHeader(SessionsPanelCopy.onThisMac, togglesFold: false, expanded: false) {}
            SessionsSectionNote(ExternalSessionCopy.notInstalled) {
                // Settings › Your agents (Connections 탭)
                Button(ExternalSessionCopy.getClaudeCode) { shell.onConnect() }.buttonStyle(TFButtonStyle(.secondary, size: .sm))
            }
        case .failed:
            SessionsSectionHeader(SessionsPanelCopy.onThisMac, togglesFold: false, expanded: false) {}
            SessionsSectionNote(ExternalSessionCopy.couldNotCheckSessions) {
                Button(ExternalSessionCopy.tryAgain) { store.retry() }.buttonStyle(TFButtonStyle(.secondary, size: .sm))
            }
        case .rows:
            SessionsSectionHeader(SessionsPanelCopy.onThisMac, togglesFold: section.togglesFold, expanded: section.expanded) { macExpanded.toggle() }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(section.rows) { mac in
                    // 확인이 서 있는 줄(`mac.attach`)은 선택 바탕을 유지한다: 어느 세션인지 읽히게, 확인은 그 줄 밑에 선다 (DZ 승인 2026-10-21 "줄을 남기고 밑에")
                    VStack(alignment: .leading, spacing: 2) {
                        // 여는 동안(`isBusy`)의 "Opening…" 글자와 비활성은 줄 그림이 `content`에서 스스로 정한다
                        ExternalSessionLineView(
                            content: mac.line, ring: mac.ring, current: shell.desktopPanelID == mac.id || mac.attach != nil,
                            onOpen: mac.opensSession ? { shell.openDesktopSession(mac.id, from: .list) } : nil
                        ) { action in
                            switch action {
                            case .openInClaude: shell.openInClaude(mac.row)
                            case .resumeHere: shell.resumeHere(mac.row)
                            }
                        }
                        if let phase = mac.attach {
                            ExternalSessionConfirmView(note: phase.note, busy: phase == .working, onConfirm: { shell.confirmResume(mac.row) }, onCancel: { shell.cancelResume(mac.id) })
                        }
                    }
                }
            }
        }
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

    /// 열기 직전(F4): 마지막 훑기가 본 그 세션의 쥠을 지금 사실로 다시 본다. 같은 계정의 훑기가 아직 없거나 모르면 nil (부른 쪽이 막는다)
    func recheck(_ id: String) async -> ExternalSessionStatus? {
        guard let context = await context(), let existing = lock.withLock({ scanner }), existing.partition == context.paths.partition.id else { return nil }
        return await existing.scanner.recheck(id: id)
    }

    /// 데스크톱 세션과의 대화를 서버에 저장할 때 쓰는 이 세션의 표시 (OA PR-D3, 계약 25.2): 이 Mac의 bridge id · 세션 UUID의 HMAC ref(`external_sessions`와 같은 열쇠) · 제목 · ref 열쇠.
    /// bridge가 아직 없거나 열쇠를 둘 수 없으면 nil (올리지 않는다). Claude 세션 id · 경로는 이 값에 없다
    func chatIdentity(sessionID: String, title: String?) async -> ClaudeAppChatIdentity? {
        guard let context = await context(), let runtime = context.runtime, let bridge = await runtime.localBridgeID(),
              let key = try? FileExternalSessionKeyStore(directory: context.paths.partitionDirectory).loadOrCreate() else { return nil }
        return ClaudeAppChatIdentity(
            context: ClaudeAppChatContext(bridgeID: bridge, sessionRef: key.ref(forSessionID: sessionID), title: title.flatMap(ExternalSessionRules.sanitizedTitle)),
            ref: { key.chatRef($0) }
        )
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
        let configuration = Self.scannerConfiguration(
            home: home, protectedRoots: context.paths.protectedRoots, sessionsRoot: context.paths.sessionsRoot,
            installedCLIVersion: { [weak self] in self?.lock.withLock { self?.currentVersion } }
        )
        let made = ExternalSessionScanner(configuration: configuration, key: key)
        lock.withLock { scanner = (id, made) }
        return made
    }

    /// "On this Mac" 훑기의 설정. **우리 중계 `claude`(데스크톱 세션과 대화, PR-D3)의 pid는 목록에서 뺀다**: 이 실행이 지금 띄운 중계 pid(`ClaudeAppRelayPIDs.shared`)를 읽는다 (OA PR-D3 검토 P3-16: 시험이 이 연결을 본다)
    static func scannerConfiguration(
        home: String, protectedRoots: [String], sessionsRoot: URL, installedCLIVersion: @escaping @Sendable () -> String?
    ) -> ExternalSessionScanner.Configuration {
        ExternalSessionScanner.Configuration(
            claudeDirectory: home + "/.claude", folderRules: ExternalSessionFolderRules.lexical(home: home, protectedRoots: protectedRoots), protectedRoots: protectedRoots,
            taskforceSessionIDs: { taskforceSessionIDs(sessionsRoot: sessionsRoot) }, attachedSessionIDs: { attachedSessionIDs(sessionsRoot: sessionsRoot) },
            ownPIDs: { ClaudeAppRelayPIDs.shared.current }, installedCLIVersion: installedCLIVersion
        )
    }

    /// Taskforce가 띄운 세션의 Claude id (세션 폴더의 `state.json`): 목록에서 뺀다. **이 Mac의 사용자가 이어받은 세션은 뺀다** (그 줄은 "In Taskforce"로 남는다: `attachedSessionIDs`)
    static func taskforceSessionIDs(sessionsRoot: URL) -> Set<String> {
        ExternalSessionBoundIDs.read(sessionsRoot: sessionsRoot).taskforce
    }

    /// 이 Mac이 로컬 Resume here로 이어받은 세션의 Claude id (OA 외부 세션 PR2m): 목록에서는 "In Taskforce" 줄이고, Sessions 패널은 그 줄을 Taskforce 절에서만 보인다
    static func attachedSessionIDs(sessionsRoot: URL) -> Set<String> {
        ExternalSessionBoundIDs.read(sessionsRoot: sessionsRoot).attached
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
            shown: { rows, held in (try? await api.externalSessionsShown(rowsBucket: rows, heldBucket: held)) != nil }, recheck: { id in await environment.recheck(id) }, seen: seen, log: log
        )
    }
}

/// 이어받기 "Resume here" (OA 외부 세션 PR2m, 계약 6 · 8.3 · 17 · 20장): 목록과 같은 게이트(새 Issues 화면 ∧ `BridgeFlag` ∧ 서비스 · 계정 경계)에 더해 **서버가 이어받기를 열었고**(플래그 · 베타 명단)
/// 이 Mac의 Claude Code 대상이 ready일 때만 줄에 단추가 보인다 (`ExternalSessionAttachModel.gate`). 쓰기(서버 이어받기 · 핀 · 상태)는 이 Mac의 런타임이 사용자가 누른 확인에서만 하고,
/// 여기서는 Kit의 흐름에 런타임 · 서버 면을 낄 뿐이다 (이 파일은 쓰기를 부르지 않는다: 소스 검사 시험이 지킨다). 정상 모드의 런타임만 쓴다 (마무리 모드는 새 등록 0)
enum ExternalSessionAttachRuntime {
    @MainActor
    static func make(
        services: AppServices?, scope: AccountScope?, externalSessions: ExternalSessionsStore?, targets: AssistantTargetsStore?,
        host: @escaping @MainActor @Sendable () -> BridgeHost? = { BridgeHost.shared }
    ) -> ExternalSessionAttachModel? {
        guard externalSessions != nil, let services, let scope, let targets else { return nil }
        let runtime: @Sendable () async -> BridgeRuntime? = { await MainActor.run { host()?.activeAgentRuntime } }
        let server = ExternalSessionAttachServer.live(api: services.api, reads: services.reads, targets: targets, bridgeID: { await runtime()?.localBridgeID() })
        return ExternalSessionAttachModel(scope: scope, runtime: ExternalSessionAttachingHost(runtime: runtime), server: server, log: BridgeOSLog())
    }
}

extension EdgeShellModel {
    /// 실제 앱의 세션 보기 대화 읽기: 이 Mac의 `~/.claude` 기록을 읽기만 한다 (`ClaudeAppTranscriptReader`). 글 · 경로를 로그에 남기지 않는다.
    /// (경로 글자는 이 파일에 둔다: 셸 모델 파일의 글자에는 제품 이름 금지 검사가 걸려 있다)
    static let liveConversation: @MainActor (String, String?) -> ClaudeAppConversation = { id, cwd in
        ClaudeAppConversation(sessionID: id, cwd: cwd, source: ClaudeAppTranscriptReader(claudeDirectory: NSHomeDirectory() + "/.claude", log: BridgeOSLog()))
    }

    /// 실제 앱의 백그라운드 일 출력 꼬리 읽기 (세션 보기 V1): 이 Mac의 임시 폴더 · `~/.claude`의 그 일 하나만 좁게 읽는다 (`BackgroundTaskTail`: 경로는 (세션 id · 일 id · 작업 폴더)로 만들고
    /// 모든 폴더 · 파일이 이 사용자의 진짜 것일 때만, 끝 부분만, 메모리에만). 글 · 경로를 로그에 남기지 않는다
    static let liveBackgroundTail: @MainActor (String, String?, TaskforceKit.BackgroundTask) -> BackgroundTaskTailModel = { sessionID, cwd, task in
        let reader = BackgroundTaskTail(claudeDirectory: NSHomeDirectory() + "/.claude")
        let taskID = task.id
        let kind = task.kind
        return BackgroundTaskTailModel(taskID: taskID, update: { window, cursor in
            reader.update(sessionID: sessionID, cwd: cwd, taskID: taskID, kind: kind, window: window, since: cursor)
        })
    }
}

/// Claude 데스크톱 세션을 레일에 올리는 이 Mac의 값들 (OA PR-D2): 등록 폴더(`~/.claude/sessions`) 폴러 + `claude agents --json` 맞춰 보기 + 안 연 끝남 표시 + 하루 한 번 지표.
/// 목록(`ExternalSessionsStore`)과 같은 게이트다: 목록이 없으면(새 Issues 화면 ∧ BridgeFlag ∧ 서비스 · 계정 경계) 데스크톱 링도 세션 보기도 없다. 폴은 컨트롤러가 목록이 보이는 동안만 돈다 (`EdgeShellController.followDesktop`)
@MainActor
enum ClaudeAppRuntime {
    struct Made {
        let sessions: ClaudeAppSessionsModel
        let opened: ClaudeAppOpenedMetric
        /// 데스크톱 세션과 대화하는 흐름 (OA PR-D3): `ClaudeAppRelayGate`가 꺼진 빌드(Release)에는 없다
        let chat: ClaudeAppChatService?

        init(sessions: ClaudeAppSessionsModel, opened: ClaudeAppOpenedMetric, chat: ClaudeAppChatService? = nil) {
            self.sessions = sessions
            self.opened = opened
            self.chat = chat
        }
    }

    /// - home: 시험은 임시 홈을 넘긴다. 실제 앱은 사용자의 홈 (`~/.claude`는 읽기만 한다)
    /// - done: 안 연 끝남 표시의 저장소. 기본값이 없다 — 실제 앱은 `AppRuntime`이 만든 영속 저장소를 넘기고(`ChatRuntime.doneStores`), 어디선가 메모리 저장소로 이어지지 않게 부르는 쪽이 늘 정한다
    /// - chatEnabled: 데스크톱 세션과 대화하는 기능의 게이트 (`ClaudeAppRelayGate`: Debug · 내부 배포 빌드만 켜짐). 시험은 값으로 넘겨 Release 갈래를 본다
    static func make(
        services: AppServices?, scope: AccountScope?, externalSessions: ExternalSessionsStore?, home: String = NSHomeDirectory(), done: any ClaudeAppDoneStore,
        chatEnabled: Bool = ClaudeAppChatRuntime.enabledForThisRun
    ) -> Made? {
        guard externalSessions != nil, let services, let scope else { return nil }
        let log = BridgeOSLog()
        let agents = ClaudeAgentsLister.live(locator: .standard(home: home), log: log)
        // 중계(PR-D3)는 레일 폴러보다 먼저 만든다: 폴러가 중계의 pid를 뺀다 (중계 `claude`는 `sdk-cli`라 레일에 오르지 않지만, 정체를 아는 값은 모두 같은 곳에서 뺀다)
        let relay = chatEnabled ? ClaudeAppChatRuntime.makeRelay(home: home, log: log) : nil
        let poller = makePoller(home: home, agents: { await agents.list() }, log: log)
        let sessions = ClaudeAppSessionsModel(poll: { await poller.poll() }, scope: scope, done: done)
        let api = services.api
        let opened = ClaudeAppOpenedMetric(send: { (try? await api.claudeAppSessionOpened()) != nil }, scope: scope, log: log)
        let chat = relay.map { ClaudeAppChatRuntime.makeService(relay: $0, api: api, scope: scope, desktop: sessions, externalSessions: externalSessions, home: home, log: log) }
        return Made(sessions: sessions, opened: opened, chat: chat)
    }

    /// 레일의 폴러. **우리 중계 `claude`의 pid는 데스크톱 세션에서 뺀다** (`ClaudeAppRelayPIDs.shared`): 이 연결을 시험이 본다 (OA PR-D3 검토 P3-16)
    static func makePoller(home: String, agents: @escaping @Sendable () async -> [ClaudeAgentsItem]?, log: any BridgeLogSink) -> ClaudeAppStatusPoller {
        ClaudeAppStatusPoller(sessionsDirectory: home + "/.claude/sessions", ownPIDs: { ClaudeAppRelayPIDs.shared.current }, agents: agents, log: log)
    }
}

/// 안 연 끝남 표시의 두 저장소 (계약 23장): 레일 링(Taskforce 세션 · 이슈)과 Claude 데스크톱 링. `ChatRuntime`이 들고 셸 컨트롤러가 그대로 쓴다.
/// 어느 쪽을 쓸지는 앱 생성 경로(`AppRuntime.doneStores`)가 정한다: 실사용 앱은 이 Mac의 설정(영속), 시험 호스트 · 견본은 메모리뿐이다
struct RailDoneStores {
    let rail: any RailDoneStore
    let claudeApp: any ClaudeAppDoneStore
    /// 백그라운드 일 옆줄의 "열어 본 시각" (세션 보기 V1: 막 끝난 일은 목록을 한 번 열어 볼 때까지 남는다). 두 세션 패널이 같이 쓴다
    let backgroundOpen: any BackgroundTaskOpenStore

    static func inMemory() -> RailDoneStores {
        RailDoneStores(rail: InMemoryRailDoneStore(), claudeApp: InMemoryClaudeAppDoneStore(), backgroundOpen: InMemoryBackgroundTaskOpenStore())
    }

    /// 앱을 다시 켠 뒤에도 남는다 (기본은 앱 설정 도메인)
    static func persistent(defaults: any RailDoneDefaults = UserDefaults.standard) -> RailDoneStores {
        RailDoneStores(
            rail: UserDefaultsRailDoneStore(defaults: defaults), claudeApp: UserDefaultsClaudeAppDoneStore(defaults: defaults),
            backgroundOpen: UserDefaultsBackgroundTaskOpenStore(defaults: defaults)
        )
    }
}

#if DEBUG
/// 디자인 비교용 견본 (Debug 전용, Release 바이너리에 없다): `-TF_EDGE_SHELL YES -TFSampleData -TF_S3B YES -TF_U2 YES -TFEdgeSnapshot <폴더> -TFEdgeSnapshotIssues -TFEdgeSnapshotExternalSessions`
/// (+ `-TFSnapshotDark`). 이 Mac의 실제 Claude 기록 · 프로세스 · 서버를 읽지 않는다: 줄 · 살아 있는 데스크톱 세션 · 대화는 모두 만든 값이다 (`mac-edge-sessions-<이름>.png`).
/// 남기는 것: rail-rest · rail-expanded(Sessions · + · 링) · panel-mixed(두 절) · panel-projects · more-card(⋯ 옆, 셋째 캡슐 아래 끝에 맞춤 — 가운데로 옮기지 않는다) · centered-rail-low/high/home(레일을 옮겨 본다) ·
/// centered-short-rail-short-panel/panel/tall-panel(링 하나, 패널 높이 셋) — 모두 레일 전체의 세로 가운데 (`-TFEdgeSnapshotTopPlacement`를 더하면 옛 위 맞춤), 숫자는 로그의 `PLACEMENT` 줄 ·
/// panel-fold(Show all) · panel-blocked · panel-long · panel-checking · panel-failed · panel-not-installed · panel-empty(No sessions),
/// claude-running · claude-approval(띠) · claude-done · claude-earlier(Show earlier) · claude-beside-sessions(Sessions 왼쪽, 메인 패널 위 맞춤) · claude-failed · claude-closed —
/// 링으로 연 Claude 세션 패널(beside-sessions 빼고)은 레일 전체의 세로 가운데이고(`PLACEMENT`), centered-claude-rail-low/high/home은 레일을 옮긴 장면
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
            if ProcessInfo.processInfo.arguments.contains("-TFAgentTreeSample") {
                return [
                    row(1, "Pricing copy draft", group: "taskforce", status: .held(.claudeApp), client: .claudeDesktop, minutes: 1),
                    row(9, "A session without sub-agents", group: "taskforce", status: .held(.claudeApp), client: .claudeDesktop, minutes: 2),
                ]
            }
            return [
                row(1, "Fix launcher focus after sleep when the panel is open", group: "taskforce", status: .held(.claudeApp), client: .claudeDesktop, minutes: 2),
                row(2, "Add RLS test for agent_sessions", group: "taskforce", status: .held(.terminal), minutes: 0.2),
                row(3, "Rewrite the pricing page copy for the 3-day trial banner", group: "taskforce", status: .available, client: .claudeDesktop, minutes: 40),
                row(4, "Remotion launch video storyboard", group: "taskforce", status: .inTaskforce, minutes: 3),
                row(5, "Hero section motion pass", group: "life-design-site", status: .held(.unknown), minutes: 4),
                row(6, "가격 페이지 FAQ 문구 다듬기", group: "life-design-site", status: .available, client: .claudeDesktop, minutes: 60 * 30),
                row(7, "Banner variants", group: "life-design-site", status: .cannotResume(.worktree), client: .claudeDesktop, minutes: 120),
                row(8, "Dependency bump", group: "thesvg-marks", status: .couldNotCheck, client: .claudeDesktop, minutes: 60),
                // Taskforce가 상태를 아는 살아 있는 데스크톱 세션 (`liveSessions`가 같은 번호로 상태를 준다)
                row(9, "Update the Settings window copy", group: "taskforce", status: .held(.claudeApp), client: .claudeDesktop, minutes: 1),
                row(10, "Check the launch checklist", group: "taskforce", status: .held(.claudeApp), client: .claudeDesktop, minutes: 6),
                row(11, "Source marks audit", group: "thesvg-marks", status: .held(.claudeApp), client: .claudeDesktop, minutes: 25),
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

    // MARK: 데스크톱 세션 (OA PR-D2)

    /// 살아 있는 데스크톱 세션 한 줄 (`rows`와 같은 번호 → 같은 id)
    nonisolated private static func live(_ n: Int, _ state: ClaudeAppSessionState, folder: String = "taskforce") -> ClaudeAppSession {
        ClaudeAppSession(
            id: String(format: "5e5e5e5e-0000-4000-8000-%012x", n), pid: Int32(40_000 + n), cwd: "/Users/sample/" + folder, procStart: nil, state: state, statusUpdatedAt: now
        )
    }

    nonisolated static func sessionID(_ n: Int) -> String { String(format: "5e5e5e5e-0000-4000-8000-%012x", n) }

    /// 폴이 돌려줄 살아 있는 세션: 견본 하네스가 단계마다 바꾼다
    final class DesktopScript: @unchecked Sendable {
        static let shared = DesktopScript()
        private let lock = NSLock()
        private var _sessions: [ClaudeAppSession] = []

        var sessions: [ClaudeAppSession] {
            get { lock.withLock { _sessions } }
            set { lock.withLock { _sessions = newValue } }
        }

        func poll() -> ClaudeAppStatusPoller.Poll {
            ClaudeAppStatusPoller.Poll(sessions: sessions, doubled: [], source: .registry, mismatch: false, verified: true, registryUnavailable: false)
        }
    }

    /// 견본 데스크톱 모델: 가짜 폴 · 메모리 저장 · 보내지 않는 지표. 실제 `~/.claude`를 읽지 않는다
    static func sampleDesktop(scope: AccountScope?) -> ClaudeAppRuntime.Made? {
        guard let scope else { return nil }
        let script = DesktopScript.shared
        return ClaudeAppRuntime.Made(
            sessions: ClaudeAppSessionsModel(poll: { script.poll() }, scope: scope, done: InMemoryClaudeAppDoneStore()),
            opened: ClaudeAppOpenedMetric(send: { true }, scope: scope)
        )
    }

    /// 견본 대화: 실제 기록을 읽지 않는다. 세션 번호마다 정해 둔 대화 (읽기 실패 · 맨 위 Show earlier 포함)
    struct SampleTranscript: ClaudeAppTranscriptSource {
        private static func turn(_ n: Int, _ kind: ClaudeAppTurn.Kind) -> ClaudeAppTurn { ClaudeAppTurn(id: "s\(n)", kind: kind) }

        private static let long: [ClaudeAppTurn] = [
            turn(1, .user("가격 페이지 3일 체험이랑 Lifetime 플랜 문구를 다시 써줘. 한국어 버전은 승인된 용어집이랑 맞춰서 확인해줘.")),
            turn(2, .assistant("I'll read the current pricing page and the glossary first, then rewrite the trial and Lifetime sections.")),
            turn(3, .tool(name: "Read", description: nil)), turn(4, .tool(name: "Read", description: nil)), turn(5, .tool(name: "Grep", description: nil)),
            turn(6, .assistant("The page has two blocks to change.\n\n- Trial card: the headline still says 7 days. The brief says 3 days, so the headline, the button label and the footnote all need the new number.\n- Lifetime card: the price line mixes the launch price and the regular price. I'll keep only the launch price and move the regular price to the footnote.\n\nThe Korean strings live in ko.json. Two of them use 평가판 where the glossary says 체험, so I'll fix those at the same time and leave every other string alone.")),
            turn(7, .tool(name: "Edit", description: nil)), turn(8, .tool(name: "Edit", description: nil)),
            turn(9, .user("Lifetime 카드는 가격만 바꾸고 문구 톤은 그대로 둬")),
            turn(10, .assistant("Understood. I reverted the tone changes on the Lifetime card and kept only the price line.")),
            turn(11, .tool(name: "Bash", description: "Run the copy lint")),
            turn(12, .assistant("Copy lint passed. Checking the Korean version against the glossary now.")),
            turn(13, .tool(name: "Read", description: nil)),
        ]

        private static let fix: [ClaudeAppTurn] = [
            turn(1, .user("Fix the launcher losing focus after the Mac wakes from sleep")),
            turn(2, .assistant("The panel loses first responder when the display wakes. I will re-assert it in the wake handler.")),
            turn(3, .tool(name: "Read", description: nil)), turn(4, .tool(name: "Grep", description: nil)),
            turn(5, .assistant("Found it in LauncherWindowController. I am adding the focus restore after the wake notification.")),
            turn(6, .tool(name: "Edit", description: nil)),
        ]

        private static let short: [ClaudeAppTurn] = [
            turn(1, .user("Tidy the Settings window copy")),
            turn(2, .assistant("Done. I shortened three labels and removed the helper sentence under Connections.")),
        ]

        func open(sessionID: String, cwd: String?) -> ClaudeAppTranscriptLoad {
            let turns: [ClaudeAppTurn]
            var earlier = false
            switch sessionID {
            case ExternalSessionSnapshot.sessionID(1): turns = Self.long
            case ExternalSessionSnapshot.sessionID(9): turns = Self.fix
            case ExternalSessionSnapshot.sessionID(10): turns = Self.short
            case ExternalSessionSnapshot.sessionID(11):
                turns = Self.short
                earlier = true
            default: return .unreadable
            }
            return .page(ClaudeAppTranscriptPage(turns: turns, cursor: ClaudeAppTranscriptCursor(sessionID: sessionID), hasEarlier: earlier, skippedLines: 0))
        }

        func earlier(_ cursor: ClaudeAppTranscriptCursor) -> ClaudeAppTranscriptLoad { .unreadable }

        func newer(_ cursor: ClaudeAppTranscriptCursor) -> ClaudeAppTranscriptUpdate { .turns([], cursor: cursor, hasMore: false) }
    }

    static func capture(_ edge: EdgeShellController, file: (String) -> URL, pause: @escaping (Double) async -> Void) async {
        let shell = edge.shell
        guard let store = shell.externalSessions, let desktop = shell.desktop else {
            print("ExternalSessionSnapshot: 목록이 꺼진 구성이다 (-TF_EDGE_SHELL YES -TFSampleData -TF_S3B YES -TF_U2 YES 필요) visible=\(shell.externalSessionsVisible) issues=\(shell.issues != nil) store=\(shell.externalSessions != nil) desktop=\(shell.desktop != nil)")
            return
        }
        let sample = IssueSampleGateway.shared
        let script = DesktopScript.shared
        shell.makeConversation = { id, cwd in ClaudeAppConversation(sessionID: id, cwd: cwd, source: SampleTranscript()) }
        // 확인 요청(주황) 링이 용량을 다 차지하지 않게 이슈는 확인 요청 없이
        edge.workOverride = { _ in IssueSnapshotData.snapshot(seeds: IssueSnapshotData.seeds.filter { !$0.review }) }
        func shoot(_ name: String) { IssueSnapshot.compose(edge, to: file("sessions-\(name)")) }
        func poll() async {
            await desktop.pollOnce()
            await pause(0.3)
        }
        /// 새로 시작한 것처럼 Taskforce 세션(`.basic` → `scenario`)과 이 Mac 목록을 다시 읽는다
        func world(_ tf: IssueSampleGateway.SessionScenario, _ mac: Scenario) async {
            scenario = mac
            shell.openAllWork()
            // 읽기는 마지막에 시작한 것만 반영된다(다른 읽기와 겹치면 하나가 버려진다): 끝난 세션(done)은 "일하는 중 → 끝남"을 정말 본 뒤에야 서므로 서기까지 되풀이한다
            for _ in 0..<5 {
                sample.sessions = tf == .finished ? .basic : tf
                await shell.issues?.sessions.refresh()
                await pause(0.2)
                sample.sessions = tf
                await shell.issues?.sessions.refresh()
                await pause(0.2)
                if tf != .finished || shell.issues?.sessions.items.contains(where: { $0.ring == .done }) == true { break }
            }
            store.reset()
            // "Checking…"의 훑기는 끝나지 않는다 (기다리지 않는다)
            if mac == .checking { Task { await store.refresh() } } else { await store.refresh() }
            await pause(0.5)
        }
        /// Sessions 패널을 연다
        func sessions(settle: Double = 0.7) async {
            shell.openSessions()
            await pause(settle)
        }
        // 레일이 여는 패널은 레일 전체의 세로 가운데에 선다 (사용자 확인): 짧은 레일 · 짧은 · 긴(520 상한) 패널 · 낮거나 높은 레일. 숫자도 로그에 남긴다 (`PLACEMENT …`)
        let contextSample = IssueSampleContextGateway.shared
        let railHome = edge.rail.panel.frame
        func placement(_ name: String) {
            let screen = EdgeRailPanelController.screen
            func f(_ value: CGFloat?) -> String { value.map { String(format: "%.1f", $0) } ?? "-" }
            print("PLACEMENT \(name) railCenter=\(f(edge.rail.centerLineY)) panelMid=\(f(edge.panel.panel.frame.midY)) panelHeight=\(f(edge.panel.panel.frame.height)) screenMid=\(f(screen?.frame.midY)) visibleY=\(f(screen?.visibleFrame.minY))…\(f(screen?.visibleFrame.maxY))")
        }
        func projects(_ scenario: IssueSampleContextGateway.Scenario, _ name: String) async {
            contextSample.scenario = scenario
            await edge.chat?.contexts?.refresh()
            shell.dismiss()
            await pause(0.4)
            shell.openAllWork()
            await pause(1.0)
            placement(name)
            shoot(name)
        }
        func moveRail(_ dy: CGFloat, _ name: String) async {
            edge.rail.panel.setFrame(railHome.offsetBy(dx: 0, dy: dy), display: true)
            edge.panel.fitToContent()
            await pause(0.7)
            placement(name)
            shoot(name)
        }
        /// 데스크톱 링으로 연 Claude 세션 패널의 자리 (레일 중심선에 가운데, 사용자 결정 2026-10-22)
        func claudePlacement(_ name: String) {
            let screen = EdgeRailPanelController.screen
            func f(_ value: CGFloat?) -> String { value.map { String(format: "%.1f", $0) } ?? "-" }
            print("PLACEMENT \(name) railCenter=\(f(edge.rail.centerLineY)) panelMid=\(f(edge.claudePanel?.panel.frame.midY)) panelHeight=\(f(edge.claudePanel?.panel.frame.height)) screenMid=\(f(screen?.frame.midY)) visibleY=\(f(screen?.visibleFrame.minY))…\(f(screen?.visibleFrame.maxY))")
        }
        func moveRailForClaude(_ dy: CGFloat, _ name: String) async {
            edge.rail.panel.setFrame(railHome.offsetBy(dx: 0, dy: dy), display: true)
            edge.claudePanel?.fit()
            await pause(0.7)
            claudePlacement(name)
            shoot(name)
        }
        // 살아 있는 데스크톱: 10번은 일하다가 쉬면 done이 된다 (열어 볼 때까지 남는다)
        script.sessions = [live(1, .busy), live(9, .waiting(.approval)), live(10, .busy), live(11, .idle, folder: "thesvg-marks")]
        await world(.finished, .mixed)
        await poll()
        script.sessions = [live(1, .busy), live(9, .waiting(.approval)), live(10, .idle), live(11, .idle, folder: "thesvg-marks")]
        await poll()
        // 레일: 접힘 → 펼침 (Sessions · + · 링)
        shell.dismiss()
        await pause(0.4)
        shoot("rail-rest")
        shell.pointer(inside: true)
        await pause(0.7)
        shoot("rail-expanded")
        // Sessions 패널
        await sessions()
        shoot("panel-mixed")
        // 레일이 여는 다른 패널 (세로 가운데 · 전/후 비교): Projects. More 카드는 가운데로 옮기지 않고 ⋯ 옆이다
        shell.openAllWork()
        await pause(0.8)
        placement("panel-projects")
        shoot("panel-projects")
        // 낮은 레일 · 높은 레일 (레일 창을 위아래로 옮겨 본다: 패널은 그 레일의 가운데를 따라간다)
        await moveRail(-190, "centered-rail-low")
        await moveRail(190, "centered-rail-high")
        await moveRail(0, "centered-rail-home")
        shell.dismiss()
        shell.pointer(inside: true)
        await pause(0.7)
        edge.rail.openMoreCardForSnapshot()
        await pause(0.6)
        shoot("more-card")
        edge.rail.moreCard.dismiss()
        await pause(0.3)
        // 줄 접기 (Show all) · 긴 제목 · 막힌 줄
        await world(.nine, .many)
        await poll()
        await sessions()
        shoot("panel-fold")
        await world(.finished, .blocked)
        await sessions()
        shoot("panel-blocked")
        await world(.basic, .long)
        await sessions()
        shoot("panel-long")
        // 절 안의 상태 · 빈 패널
        await world(.basic, .checking)
        await sessions(settle: 0.4)
        shoot("panel-checking")
        await world(.basic, .failed)
        await sessions()
        shoot("panel-failed")
        await world(.basic, .notInstalled)
        await sessions()
        shoot("panel-not-installed")
        script.sessions = []
        await world(.none, .empty)
        await poll()
        await sessions()
        shoot("panel-empty")
        // 짧은 레일(링 하나): 짧은 패널 · 보통 패널 · 긴 패널(520 상한) 모두 레일 가운데
        await projects(.empty, "centered-short-rail-short-panel")
        await projects(.full, "centered-short-rail-panel")
        await projects(.many, "centered-short-rail-tall-panel")
        contextSample.scenario = .full
        await edge.chat?.contexts?.refresh()
        // Claude 세션 보기: 링으로 열면 한 패널, Sessions 줄로 열면 Sessions 왼쪽
        script.sessions = [live(1, .busy), live(9, .waiting(.approval)), live(10, .busy), live(11, .idle, folder: "thesvg-marks")]
        await world(.finished, .mixed)
        await poll()
        script.sessions = [live(1, .busy), live(9, .waiting(.approval)), live(10, .idle), live(11, .idle, folder: "thesvg-marks")]
        await poll()
        func view(_ n: Int, _ name: String, from source: EdgeShellModel.DesktopOpenSource = .rail, settle: Double = 1.0) async {
            shell.dismiss()
            await pause(0.3)
            if source == .list { await sessions() }
            shell.openDesktopSession(sessionID(n), from: source)
            await pause(settle)
            claudePlacement(name)
            shoot(name)
        }
        await view(1, "claude-running")
        // 낮은 레일 · 높은 레일: 링으로 연 Claude 세션 패널도 그 레일의 가운데를 따라간다
        await moveRailForClaude(-190, "centered-claude-rail-low")
        await moveRailForClaude(190, "centered-claude-rail-high")
        await moveRailForClaude(0, "centered-claude-rail-home")
        await view(9, "claude-approval")
        await view(10, "claude-done")
        await view(11, "claude-earlier")
        await view(1, "claude-beside-sessions", from: .list)
        // 읽지 못한 대화
        script.sessions = [live(12, .busy)]
        await poll()
        await view(12, "claude-failed")
        // Claude에서 닫음: 보는 세션이 목록에서 사라진다 (세 번 연달아)
        script.sessions = [live(1, .busy)]
        await poll()
        shell.dismiss()
        await pause(0.3)
        shell.openDesktopSession(sessionID(1), from: .rail)
        await pause(0.8)
        script.sessions = []
        for _ in 0..<5 { await poll() }
        await pause(0.6)
        shoot("claude-closed")
        shell.dismiss()
        store.reset()
        script.sessions = []
    }
}
#endif
#endif
