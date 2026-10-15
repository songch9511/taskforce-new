#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

/// 새 Issues 화면(OA U2)의 본문: Projects → 프로젝트 · Ungrouped · Done today 이슈 목록 → 이슈 상세. `View.allWork`가 게이트가 켜진 셸에서 보이는 화면이다.
/// 상태 화면은 기존 All work 규칙 그대로다 (`WorkListScreen`: 읽는 중 = 그리지 않음 · 오프라인 · 읽기 실패 · 받은 목록 뒤 문제 = 위에 Notice 하나 · 전부 비면 "Nothing on your plate yet.")
struct IssuesPanelBody: View {
    @Bindable var shell: EdgeShellModel
    /// 병합된 이슈(D4c-3m)의 "From #144" 읽기 전용 줄이 들어갈 자리: 상세의 Source 뒤. U2는 비워 둔다
    var afterSource: (UUID) -> AnyView? = { _ in nil }

    var body: some View {
        switch shell.nav.current {
        case .projects:
            ProjectsBody(shell: shell)
        case .list(let scope):
            IssueListBody(shell: shell, scope: scope)
        case .detail(let id):
            IssueDetailBody(shell: shell, id: id, afterSource: afterSource)
        }
    }
}

/// 목록 · 프로젝트 화면이 함께 쓰는 상태: 이슈 목록을 받았는지 · 프로젝트 멤버십을 읽었는지
@MainActor
private struct IssuesLoadState {
    enum Screen {
        case blank
        case offline
        case failed
        case noWork(problem: WorkLoad.Problem?)
        case ready(problem: WorkLoad.Problem?)
    }

    static func screen(_ shell: EdgeShellModel) -> Screen {
        switch WorkListScreen.of(load: shell.work.load, isEmpty: shell.workItems.isEmpty, syncing: shell.work.syncing) {
        case .blank, .waitingForSync: return .blank
        case .offline: return .offline
        case .failed: return .failed
        case .noWork(let problem): return .noWork(problem: problem)
        case .list(let problem):
            // 멤버십을 아직 읽지 못했다: 어느 이슈도 프로젝트 · Ungrouped에 두지 않는다. 읽다 실패했으면 그 사실만 말한다
            if !shell.membershipsKnown {
                switch shell.projectsProblem {
                case .offline?: return .offline
                case .failed?: return .failed
                case nil: return .blank
                }
            }
            return .ready(problem: problem)
        }
    }
}

private struct IssuesNotice: View {
    let problem: WorkLoad.Problem?
    let retry: () -> Void

    var body: some View {
        if let problem {
            Notice(title: problem == .offline ? PanelEmptyKind.offline.title : PanelEmptyKind.couldNotLoad.title) {
                Button("Try again", action: retry).buttonStyle(TFButtonStyle(.secondary, size: .sm))
            }
            .padding(.bottom, TFSpace.md)
        }
    }
}

struct ProjectsBody: View {
    @Bindable var shell: EdgeShellModel

    var body: some View {
        switch IssuesLoadState.screen(shell) {
        case .blank:
            Color.clear.frame(height: 0)
        case .offline:
            PanelEmptyState(.offline) { Button("Try again") { shell.onRetry() }.buttonStyle(TFButtonStyle(.secondary, size: .md)) }
        case .failed:
            PanelEmptyState(.couldNotLoad) { Button("Try again") { shell.onRetry() }.buttonStyle(TFButtonStyle(.secondary, size: .md)) }
        case .noWork(let problem):
            VStack(alignment: .leading, spacing: 0) {
                IssuesNotice(problem: problem, retry: shell.onRetry)
                PanelEmptyState(.noWork) {
                    Button("Add task") { shell.onAddTask() }.buttonStyle(TFButtonStyle(.primary, size: .md))
                    if shell.work.canConnect { Button("Connect a source") { shell.onConnect() }.buttonStyle(TFButtonStyle(.secondary, size: .md)) }
                }
            }
        case .ready(let problem):
            VStack(alignment: .leading, spacing: 0) {
                IssuesNotice(problem: problem ?? shell.projectsProblem, retry: shell.onRetry)
                // 프로젝트가 하나도 없고 이슈도 없는 경우는 위 `.noWork`다. 행은 서버 순서가 아니라 이름순 (`ProjectListRules`)
                let rows = shell.projectRows
                // 행 사이 2 (Figma M1: 행 54 + 간격 2)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(rows) { row in
                        ProjectRow(row, current: false, highlighted: false, onOpen: { open(row) }, onAsk: { ask(row) })
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Projects")
        }
    }

    private func open(_ row: ProjectRowContent) {
        switch row.kind {
        case .project(let id): shell.openList(.project(id))
        case .ungrouped: shell.openList(.ungrouped)
        case .doneToday: shell.openList(.doneToday)
        }
    }

    /// Ask: 프로젝트 행은 그 프로젝트(context) 칩. Ungrouped · Done today는 칩이 없다 (이름 없는 범위)
    private func ask(_ row: ProjectRowContent) {
        guard case .project(let id) = row.kind else { return }
        shell.onAsk(AssistantOpenItem(kind: .context, id: id, title: row.name))
    }
}

struct IssueListBody: View {
    @Bindable var shell: EdgeShellModel
    let scope: IssueListScope

    var body: some View {
        switch IssuesLoadState.screen(shell) {
        case .blank:
            Color.clear.frame(height: 0)
        case .offline:
            PanelEmptyState(.offline) { Button("Try again") { shell.onRetry() }.buttonStyle(TFButtonStyle(.secondary, size: .md)) }
        case .failed:
            PanelEmptyState(.couldNotLoad) { Button("Try again") { shell.onRetry() }.buttonStyle(TFButtonStyle(.secondary, size: .md)) }
        case .noWork(let problem):
            VStack(alignment: .leading, spacing: 0) {
                IssuesNotice(problem: problem, retry: shell.onRetry)
            }
        case .ready(let problem):
            VStack(alignment: .leading, spacing: 0) {
                IssuesNotice(problem: problem ?? shell.projectsProblem, retry: shell.onRetry)
                if let list = shell.issueList(scope) {
                    ForEach(list.groups) { group in
                        if let label = group.label { GroupLabel(label) }
                        // 행 사이 2 (Figma M3: 행 36 + 간격 2)
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(group.rows) { row in
                                IssueRow(
                                    row, current: shell.currentID == row.id, highlighted: shell.hoveredID == row.id,
                                    askLabel: AskPill.accessibilityName(number: number(row.id), name: row.title), onOpen: { shell.openIssue(row.id) },
                                    onAsk: { shell.onAsk(AssistantOpenItem(kind: .action, id: row.id, title: row.title, number: number(row.id))) }
                                )
                            }
                        }
                    }
                }
            }
            .padding(.top, 0)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(shell.issueList(scope)?.title ?? "Issues")
        }
    }

    private func number(_ id: UUID) -> Int? { shell.issues?.numbers.number(for: id) }
}

struct IssueDetailBody: View {
    @Bindable var shell: EdgeShellModel
    let id: UUID
    let afterSource: (UUID) -> AnyView?
    @State private var showsAllSources = false

    private var screen: IssueDetailScreen { shell.issues?.details.screen(for: id) ?? .blank }

    var body: some View {
        Group {
            switch screen {
            case .offline:
                PanelEmptyState(.offline) { Button("Try again") { retry() }.buttonStyle(TFButtonStyle(.secondary, size: .md)) }
            case .failed:
                PanelEmptyState(.couldNotLoad) { Button("Try again") { retry() }.buttonStyle(TFButtonStyle(.secondary, size: .md)) }
            case .blank, .ready, .gone:
                if let item = shell.issueItem(id) {
                    content(item, sources: { if case .ready(let content) = screen { content } else { nil } }())
                }
            }
        }
        .task(id: id) {
            showsAllSources = false
            await shell.issues?.numbers.ensure([id])
            await shell.issues?.details.load(id)
        }
        .onChange(of: screen == .gone) { _, gone in
            // 서버에 없는 이슈(지움 · 병합): 열어 둔 상세는 목록으로 돌아간다
            if gone { shell.goBack() }
        }
    }

    private func retry() {
        Task { await shell.issues?.details.load(id) }
    }

    @ViewBuilder
    private func content(_ item: WorkItem, sources: IssueDetailContent?) -> some View {
        let today = DueDateFormat.today()
        VStack(alignment: .leading, spacing: 0) {
            // 제목: 줄바꿈 (머리는 한 줄 끝 줄임이지만 상세 제목은 줄바꿈)
            Text(item.action.title)
                .font(TFFont.headline)
                .tracking(-0.374)
                .foregroundStyle(TFColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 2, leading: 10, bottom: 6, trailing: 10))
                .accessibilityAddTraits(.isHeader)
            // 속성: 값이 있는 것만 (읽기 전용). Waiting on은 데이터가 없어 그리지 않는다
            PropertyRow(label: "Status", value: StatusMark.State(item.state).label) { StatusMark(StatusMark.State(item.state)) }
            if let due = item.action.dueDate {
                let overdue = item.state != .done && DueText.isOverdue(due, today: today)
                PropertyRow(label: "Due", value: DueText.short(due, today: today), overdue: overdue)
            }
            if let project = projectLine(item) {
                PropertyRow(label: "Project", value: project.names) { ProjectGlyph(project.icon) }
            }
            sessionsGroup
            sourceGroup(sources)
            if let slot = afterSource(id) { slot }
        }
    }

    /// Project 속성: 확인된 활성 프로젝트를 이름순으로 ", "로 잇는다 (Ungrouped면 줄 없음). 아이콘은 첫 프로젝트의 것
    private func projectLine(_ item: WorkItem) -> (names: String, icon: ProjectIconName)? {
        let contexts = Dictionary(shell.contextList.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let live = item.memberships.links.map(\.project).filter { !$0.isArchived }
            .sorted { ($0.name.lowercased(), $0.id.uuidString) < ($1.name.lowercased(), $1.id.uuidString) }
        guard let first = live.first else { return nil }
        return (live.map(\.name).joined(separator: ", "), contexts[first.id]?.icon ?? .folder)
    }

    @ViewBuilder
    private var sessionsGroup: some View {
        let sessions = shell.sessions(of: id)
        if !sessions.isEmpty {
            GroupLabel(SessionTab.groupLabel)
            ForEach(sessions) { session in
                SessionRow(
                    session, current: shell.sessionPanelID == session.id,
                    onOpen: { shell.openSession(session.id) },
                    onAsk: { shell.onAsk(AssistantOpenItem(kind: .agentSession, id: session.id, title: session.name)) }
                )
            }
        }
    }

    @ViewBuilder
    private func sourceGroup(_ content: IssueDetailContent?) -> some View {
        if let content, content.hasSource {
            GroupLabel("Source") {
                if content.canShowAll, !showsAllSources {
                    QuietLink("Show all") { withAnimation(TFMotion.move(TFMotion.disclosureFlip, reduceMotion: shell.reduceMotion)) { showsAllSources = true } }
                }
            }
            VStack(spacing: 6) {
                ForEach(showsAllSources ? content.sources : Array(content.sources.prefix(1))) { line in
                    IssueSourceQuote(line: line, open: { shell.onOpenURL($0) })
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)
        }
    }
}

/// 이슈 상세의 원문 인용 하나: 기존 `SourceQuote` (원문 그대로). Slack 연결을 끊어 지운 인용은 기존 문구를 인용 부호 없이 (인용이 아니라 사실 한 줄)
struct IssueSourceQuote: View {
    let line: EvidenceLine
    let open: (URL) -> Void

    var body: some View {
        if RemovedQuote.isRemoved(line.quote) {
            Text(RemovedQuote.label)
                .font(TFFont.callout)
                .foregroundStyle(TFColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 10, leading: TFSpace.md, bottom: 10, trailing: TFSpace.md))
                .background(TFColor.bgField, in: RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous))
                .accessibilityElement(children: .combine)
        } else {
            SourceQuote(
                service: line.service, place: line.displayTitle, time: line.displayDate.map { WhenText.label($0) }, text: line.quote,
                openTitle: line.externalURL == nil ? nil : line.service.openTitle, onOpen: line.externalURL.map { url in { open(url) } }
            )
        }
    }
}
#endif
