#if os(macOS)
import SwiftUI
import TaskforceKit
import TaskforceUI

// Settings › Connections › Your agents (OA Settings › Your agents, 디자인 SettingsPage · AgentRow · AgentDetail + DZ 그림, 계약 5–7장).
// 규칙은 Kit(`AgentSettingsRules`), 상태 · 동작은 `AgentSettingsModel`, 부품은 `TaskforceUI`(`AgentRow` 등)다. 여기는 그것들을 DS 트레이에 놓을 뿐이다.
// 이 절은 0.2.0 Settings 창(`EdgeSurfaces.settingsWindow`, Debug `-TF_EDGE_SHELL`, Release false)에서만, Taskforce 로그인 상태일 때만 보인다 (새 플래그 없음, SA-09).

/// 절 · 상세가 보일 때와 창이 다시 키 창이 될 때 읽는다 (SA-06): 처음 보이면 실제 면을 붙이고 새로 고친다 (10초에 한 번까지). 런타임 상태가 바뀌면 지금 값을 다시 읽는다
private struct AgentSettingsLifecycle: ViewModifier {
    @Environment(\.services) private var services
    @Environment(\.controlActiveState) private var activeState

    func body(content: Content) -> some View {
        let model = SettingsWindowModel.shared
        content
            .task {
                model.attachAgentEnvironment(services: services)
                await model.agents.refresh(.shown)
            }
            .onChange(of: activeState) { _, state in
                // Terminal에서 로그인하고 돌아온 때
                guard state == .key else { return }
                Task { await model.agents.refresh(.windowKey) }
            }
            // 상태가 바뀔 때와, 상태가 그대로여도 실행이 시작 · 끝날 때(상세의 "Active since")
            .onChange(of: model.agents.runtimeSignature) {
                Task { await model.agents.refresh(.again) }
            }
    }
}

/// Connections 탭의 Your agents: Claude Code 한 줄. 연결 전에는 줄 아래 각주가 연결이 무엇을 하는지 말한다
struct SettingsYourAgentsSection: View {
    private var model: SettingsWindowModel { .shared }

    var body: some View {
        let agents = model.agents
        let line = agents.line
        SettingsSection(AgentSettingsCopy.sectionTitle, footnote: line.kind == .connect ? AgentSettingsCopy.connectIntro : nil) {
            AgentRow(
                line: line, busy: agents.busy == .connect || agents.busy == .reconnect, hint: agents.rowHint, onOpen: { model.open(.agent) },
                onAction: { Self.perform(line.control, on: agents) }
            )
        }
        .modifier(AgentSettingsLifecycle())
    }

    /// Connect · Reconnect (사용자 행동으로만, D2a Q7). 일은 모델이 쥔다: 창을 닫아도 계속한다
    static func perform(_ control: AgentSettingsLine.Control, on agents: AgentSettingsModel) {
        switch control {
        case .connect: Task { await agents.connect() }
        case .reconnect: Task { await agents.reconnect() }
        case .none, .level: break
        }
    }
}

/// 탭 맨 위 Notice (이 계정의 Mac이 10대): 제목 + Show Macs만 (설명 줄 없음, 사용자 결정)
struct SettingsMacsNotice: View {
    var body: some View {
        Notice(title: AgentSettingsCopy.tenMacsNotice) {
            Button(AgentSettingsCopy.showMacs) { SettingsWindowModel.shared.open(.macs) }
                .buttonStyle(TFButtonStyle())
        }
    }
}

/// Claude Code 상세 (DS `AgentDetail` + DZ): 머리 · Status · Access · Folders · Disconnect this Mac.
/// "What Taskforce can do"는 없다 (SA-04: 능력은 서버가 정한다). Level은 고칠 수 없는 값이다 (SA-01 A)
struct SettingsAgentDetail: View {
    private var model: SettingsWindowModel { .shared }

    var body: some View {
        let agents = model.agents
        let detail = agents.detail
        VStack(alignment: .leading, spacing: SettingsWindowLayout.topicGap) {
            AgentDetailHeader(
                line: detail.line, busy: agents.busy == .connect || agents.busy == .reconnect, hint: agents.rowHint,
                onAction: { SettingsYourAgentsSection.perform(detail.line.control, on: agents) }
            )
            .padding(.top, SettingsWindowLayout.followOnPull)
            SettingsSection(AgentSettingsCopy.status, footnote: detail.statusFootnote) {
                if let signIn = detail.signIn {
                    SettingsTrayRow(AgentSettingsCopy.signIn) { AgentValueText(signIn) }
                }
                SettingsTrayRow(AgentSettingsCopy.session) { AgentValueText(detail.session) }
                if let version = detail.version {
                    SettingsTrayRow(AgentSettingsCopy.version) { SettingsValue(version) }
                }
                if let name = detail.thisMac {
                    SettingsTrayRow(AgentSettingsCopy.thisMac) { SettingsValue(name) }
                }
            }
            SettingsSection(AgentSettingsCopy.access, footnote: detail.accessFootnote) {
                SettingsTrayRow(AgentSettingsCopy.level) { SettingsValue(detail.level) }
                if let openNow = detail.openNow {
                    SettingsTrayRow(AgentSettingsCopy.openNow) { AgentValueText(openNow) }
                }
            }
            if detail.showsFolders { folders(agents) }
            if detail.showsDisconnect { disconnect(agents) }
        }
        .modifier(AgentSettingsLifecycle())
    }

    /// Folders: 늘 보인다 (연결 전에도, 없으면 Ungrouped · "Ask each time" 한 줄). 프로젝트 줄을 누르면 Change… · Remove…
    private func folders(_ agents: AgentSettingsModel) -> some View {
        VStack(alignment: .leading, spacing: TFSpace.sm) {
            foldersSection(agents)
            if let hint = agents.folderHint { AgentHintLine(hint).padding(.horizontal, TFSpace.md) }
        }
    }

    private func foldersSection(_ agents: AgentSettingsModel) -> some View {
        SettingsSection(AgentSettingsCopy.folders, footnote: AgentSettingsCopy.foldersFootnote) {
            ForEach(agents.folderLines) { line in
                if let project = line.project, model.confirming == .removeFolder(project.id) {
                    ConfirmRow(
                        AgentSettingsCopy.removeFolderTitle, detail: AgentSettingsCopy.removeFolderDetail(project: project.name),
                        confirmLabel: AgentSettingsCopy.remove, onConfirm: { Task { await model.removeFolder(project: project.id) } },
                        onCancel: { model.confirming = nil }
                    )
                } else {
                    AgentFolderRow(
                        line: line, onChange: { if let project = line.project { Task { await agents.changeFolder(project: project) } } },
                        onRemove: { if let project = line.project { model.confirming = .removeFolder(project.id) } }
                    )
                }
            }
        }
    }

    /// Disconnect this Mac: 제자리 확인 (Cancel이 먼저). 끊는 동안(최대 세션마다 16초) 확인 줄이 기다리고, 창을 닫아도 일은 계속한다. 실패하면 줄이 그대로 남고 조용한 실패 줄이 붙는다
    private func disconnect(_ agents: AgentSettingsModel) -> some View {
        SettingsSection {
            if model.confirming == .disconnectAgent {
                ConfirmRow(
                    AgentSettingsCopy.disconnectTitle, detail: [AgentSettingsCopy.disconnectDetail, agents.disconnectHint].compactMap { $0 }.joined(separator: "\n"),
                    confirmLabel: AgentSettingsCopy.disconnect, busy: agents.busy == .disconnect, onConfirm: { Task { await model.disconnectAgent() } },
                    onCancel: { if agents.busy != .disconnect { model.confirming = nil } }
                )
            } else {
                SettingsTrayRow(AgentSettingsCopy.disconnectRow) {
                    Button(AgentSettingsCopy.disconnectAction) { model.confirming = .disconnectAgent }
                        .buttonStyle(TFButtonStyle())
                }
            }
        }
    }
}

/// 이 계정의 Mac 목록 (10대일 때, 6.4): 이름 · 마지막으로 본 때 · Remove…. 이 Mac은 없다. 지우면 Connect가 다시 열린 탭으로 돌아간다 (자동으로 연결하지 않는다)
struct SettingsMacsDetail: View {
    @Environment(\.services) private var services
    private var model: SettingsWindowModel { .shared }

    var body: some View {
        let agents = model.agents
        VStack(alignment: .leading, spacing: SettingsWindowLayout.topicGap) {
            if !agents.macs.isEmpty {
                SettingsSection {
                    ForEach(agents.macs) { mac in
                        let title = AgentSettingsMacs.title(mac)
                        if model.confirming == .removeMac(mac.id) {
                            ConfirmRow(
                                AgentSettingsCopy.removeMacTitle(title),
                                detail: [AgentSettingsCopy.removeMacDetail, agents.macHint(mac.id)].compactMap { $0 }.joined(separator: "\n"),
                                confirmLabel: AgentSettingsCopy.remove, busy: agents.busy == .removeMac(mac.id), onConfirm: { Task { await model.removeMac(mac.id) } },
                                onCancel: { if agents.busy != .removeMac(mac.id) { model.confirming = nil } }
                            )
                        } else {
                            SettingsTrayRow(title, detail: AgentSettingsMacs.detail(mac)) {
                                Button(AgentSettingsCopy.removeMacAction) { model.confirming = .removeMac(mac.id) }
                                    .buttonStyle(TFButtonStyle())
                            }
                        }
                    }
                }
            }
            if agents.macsFailed {
                AgentHintLine(AgentSettingsCopy.somethingWentWrong).padding(.horizontal, TFSpace.md)
            }
        }
        .task {
            model.attachAgentEnvironment(services: services)
            await agents.refresh(.again)
            await agents.loadMacs()
        }
    }
}
#endif
