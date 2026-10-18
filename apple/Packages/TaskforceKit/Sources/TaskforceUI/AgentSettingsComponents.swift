#if os(macOS)
import SwiftUI
import TaskforceKit

// Settings › Your agents의 부품 (OA Settings › Your agents, 디자인 SSOT `AgentRow` · `AgentDetail` · `ConnectionHeader plain` + DZ 그림).
// 규칙(어느 줄에 무슨 말)은 Kit의 `AgentSettingsRules`가 정하고, 여기는 그리기만 한다. DS 부품과 토큰만 쓴다: **색은 더하지 않는다** (빨강 0 — 실패 줄도 조용한 회색 힌트 톤).
// 굵은 말은 DS가 정한 것뿐이다: 줄 말은 `AgentSettingsLine.bold`, 상세 값은 `AgentSettingsValue.bold`, 사라진 폴더의 "Missing".

/// 실패 줄 (DS FieldMessage 힌트 톤): 보조 색 12pt. 빨강이 아니다 ("실패는 굵은 말, 빨강 아님" — 입력 오류만 빨강이 허락된다)
public struct AgentHintLine: View {
    let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(TFFont.meta)
            .foregroundStyle(TFColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 읽기 전용 값 글자 (DS `Value`): 굵은 말은 DS가 정한 "Unsupported" · "Can't run agents in this build" · "Not signed in"뿐이다
public struct AgentValueText: View {
    let value: AgentSettingsValue

    public init(_ value: AgentSettingsValue) {
        self.value = value
    }

    public var body: some View {
        Text(value.text)
            .font(value.bold ? TFFont.footnoteEmphasis : TFFont.footnote)
            .foregroundStyle(value.bold ? TFColor.textPrimary : TFColor.textSecondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

/// 버튼 하나 (DS Button sm): 누르는 동안(`busy`) 라벨을 그대로 두고 스피너를 앞에 붙인다. 흐리게 하지 않는다 — 눌림을 막는 것은 쓰는 쪽이다
public struct AgentActionButton: View {
    let title: String
    let busy: Bool
    let prominent: Bool
    let accessibilityName: String
    let action: () -> Void

    /// - prominent: 잉크 버튼(DS `attention`: Reconnect · 상세 머리의 Connect). 아니면 `bg/field` 면(Connect)
    public init(_ title: String, busy: Bool = false, prominent: Bool = false, accessibilityName: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.busy = busy
        self.prominent = prominent
        self.accessibilityName = accessibilityName ?? title
        self.action = action
    }

    public var body: some View {
        Button(action: busyAwareAction) {
            HStack(spacing: 6) {
                if busy { ProgressView().controlSize(.small).scaleEffect(0.75).frame(width: 12, height: 12) }
                Text(title)
            }
        }
        .buttonStyle(TFButtonStyle(prominent ? .primary : .secondary))
        .accessibilityLabel(accessibilityName)
        .accessibilityAddTraits(busy ? .updatesFrequently : [])
    }

    private func busyAwareAction() {
        guard !busy else { return }
        action()
    }
}

/// Your agents 줄 (DS `AgentRow`): 이름 · 줄 말(굵을 수 있다) · (실패 줄) · 오른쪽 컨트롤 하나. 규칙은 `AgentSettingsLine`이 정했다.
/// 컨트롤이 없으면 줄 전체가 상세를 열고(›), 있으면 글자 쪽이 상세를 연다 (`SettingsTrayRow`와 같은 규칙).
/// 오른쪽: Connect(`bg/field` 버튼) · Reconnect(잉크 버튼) · Level(고칠 수 없는 `Value` "Can write", SA-01 A)
public struct AgentRow: View {
    let line: AgentSettingsLine
    let busy: Bool
    let hint: String?
    let onOpen: () -> Void
    let onAction: () -> Void
    @State private var hovering = false

    public init(line: AgentSettingsLine, busy: Bool = false, hint: String? = nil, onOpen: @escaping () -> Void, onAction: @escaping () -> Void = {}) {
        self.line = line
        self.busy = busy
        self.hint = hint
        self.onOpen = onOpen
        self.onAction = onAction
    }

    /// 접근성 이름: 줄 + 상태(+ 실패 줄). 동작은 버튼이 자기 이름으로 말한다
    public nonisolated static func accessibilityName(_ line: AgentSettingsLine, hint: String? = nil) -> String {
        [AgentSettingsCopy.agentName, line.detail, hint].compactMap { $0 }.joined(separator: ", ")
    }

    /// 버튼의 접근성 이름: 동작 + 대상 ("Connect Claude Code")
    public nonisolated static func actionName(_ line: AgentSettingsLine) -> String? {
        switch line.control {
        case .connect: "\(AgentSettingsCopy.connect) \(AgentSettingsCopy.agentName)"
        case .reconnect: "\(AgentSettingsCopy.reconnect) \(AgentSettingsCopy.agentName)"
        case .none, .level: nil
        }
    }

    public var body: some View {
        Group {
            if line.control == .none {
                Button(action: onOpen) {
                    HStack(spacing: SettingsTray.separatorInset) {
                        text
                        TFIcon.disclosureClosed.image(size: 14).foregroundStyle(TFColor.textSecondary)
                    }
                    .padding(SettingsTray.rowPadding)
                    .frame(maxWidth: .infinity, minHeight: SettingsTray.rowMinHeight, alignment: .leading)
                    .background(hovering ? TFColor.bgSelected : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
            } else {
                HStack(spacing: SettingsTray.separatorInset) {
                    Button(action: onOpen) { text.contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        .onHover { hovering = $0 }
                    control
                }
                .padding(SettingsTray.rowPadding)
                .frame(maxWidth: .infinity, minHeight: SettingsTray.rowMinHeight, alignment: .leading)
                .background(hovering ? TFColor.bgSelected : .clear)
            }
        }
        .animation(TFMotion.ease(TFMotion.hoverFade), value: hovering)
        .containerValue(\.settingsSeparatorLeading, SettingsTray.separatorInset)
    }

    private var secondary: Color { hovering ? TFColor.textSecondarySelected : TFColor.textSecondary }

    private var text: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(AgentSettingsCopy.agentName)
                .font(TFFont.footnote)
                .foregroundStyle(TFColor.textPrimary)
                .lineLimit(1)
            Text(line.detail)
                .font(line.bold ? TFFont.meta.weight(.semibold) : TFFont.meta)
                .foregroundStyle(line.bold ? TFColor.textPrimary : secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let hint {
                Text(hint)
                    .font(TFFont.meta)
                    .foregroundStyle(secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityName(line, hint: hint))
    }

    @ViewBuilder
    private var control: some View {
        switch line.control {
        case .none:
            EmptyView()
        case .connect:
            AgentActionButton(AgentSettingsCopy.connect, busy: busy, accessibilityName: Self.actionName(line), action: onAction)
        case .reconnect:
            AgentActionButton(AgentSettingsCopy.reconnect, busy: busy, prominent: true, accessibilityName: Self.actionName(line), action: onAction)
        case .level:
            SettingsValue(AgentSettingsCopy.canWrite)
                .accessibilityLabel(AgentSettingsCopy.level)
                .accessibilityValue(AgentSettingsCopy.canWrite)
        }
    }
}

/// 상세 머리 (DS `ConnectionHeader plain`): 이름 17 semibold · 줄 말 · (실패 줄) · 오른쪽 동작 하나 (Connect · Reconnect는 잉크 버튼, 누르는 동안 스피너)
public struct AgentDetailHeader: View {
    let line: AgentSettingsLine
    let busy: Bool
    let hint: String?
    let onAction: () -> Void

    public init(line: AgentSettingsLine, busy: Bool = false, hint: String? = nil, onAction: @escaping () -> Void = {}) {
        self.line = line
        self.busy = busy
        self.hint = hint
        self.onAction = onAction
    }

    public var body: some View {
        HStack(alignment: .top, spacing: TFSpace.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(AgentSettingsCopy.agentName)
                    .font(TFFont.headline)
                    .foregroundStyle(TFColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                // 머리의 줄 말은 굵지 않다 (그림: 줄에서만 굵다)
                Text(line.detail)
                    .font(TFFont.footnote)
                    .foregroundStyle(TFColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint {
                    AgentHintLine(hint).padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(AgentRow.accessibilityName(line, hint: hint))
            switch line.control {
            case .connect:
                AgentActionButton(AgentSettingsCopy.connect, busy: busy, prominent: true, accessibilityName: AgentRow.actionName(line), action: onAction)
            case .reconnect:
                AgentActionButton(AgentSettingsCopy.reconnect, busy: busy, prominent: true, accessibilityName: AgentRow.actionName(line), action: onAction)
            case .none, .level:
                EmptyView()
            }
        }
        .padding(.horizontal, TFSpace.md)
    }
}

/// Folders의 줄 (`SettingsRow` lead = `ProjectGlyph` 16pt, 오른쪽 `Value` = 경로): 프로젝트 줄은 누르면 Change… · Remove… 메뉴가 열리고, Ungrouped 줄은 컨트롤이 없다.
/// 긴 프로젝트 이름은 줄바꿈하고 경로가 남는 폭으로 줄어든다 (가운데 줄임). 사라진 폴더는 이름 아래 굵은 "Missing" (자동으로 지우지 않는다)
public struct AgentFolderRow: View {
    let line: AgentFolderLine
    let onChange: () -> Void
    let onRemove: () -> Void
    @State private var hovering = false

    public init(line: AgentFolderLine, onChange: @escaping () -> Void = {}, onRemove: @escaping () -> Void = {}) {
        self.line = line
        self.onChange = onChange
        self.onRemove = onRemove
    }

    /// 접근성 이름: 이름 + 경로(또는 "Ask each time") + 사라졌으면 "Missing"
    public nonisolated static func accessibilityName(_ line: AgentFolderLine) -> String {
        [line.name, line.display, line.missing ? AgentSettingsCopy.missing : nil].compactMap { $0 }.joined(separator: ", ")
    }

    public var body: some View {
        Group {
            if line.isUngrouped {
                content
            } else {
                Menu {
                    Button(AgentSettingsCopy.change, action: onChange)
                    Divider()
                    Button(AgentSettingsCopy.removeFolderAction, action: onRemove)
                } label: {
                    content.contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .onHover { hovering = $0 }
            }
        }
        .background(hovering ? TFColor.bgSelected : .clear)
        .animation(TFMotion.ease(TFMotion.hoverFade), value: hovering)
        .containerValue(\.settingsSeparatorLeading, SettingsTray.leadSeparatorInset)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityName(line))
        .accessibilityAddTraits(line.isUngrouped ? [] : .isButton)
        .modifier(FolderActions(enabled: !line.isUngrouped, onChange: onChange, onRemove: onRemove))
    }

    private var content: some View {
        HStack(spacing: SettingsTray.separatorInset) {
            ProjectGlyph(line.project.map { ProjectGlyph.Kind.project($0.icon) } ?? ProjectGlyph.Kind.ungrouped, lit: hovering)
                .frame(width: SettingsTray.leadSide)
            VStack(alignment: .leading, spacing: 1) {
                Text(line.name)
                    .font(TFFont.footnote)
                    .foregroundStyle(TFColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if line.missing {
                    Text(AgentSettingsCopy.missing)
                        .font(TFFont.meta.weight(.semibold))
                        .foregroundStyle(TFColor.textPrimary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            Text(line.display)
                .font(TFFont.footnote)
                .foregroundStyle(hovering ? TFColor.textSecondarySelected : TFColor.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .multilineTextAlignment(.trailing)
        }
        .padding(SettingsTray.rowPadding)
        .frame(maxWidth: .infinity, minHeight: SettingsTray.rowMinHeight, alignment: .leading)
    }
}

/// 메뉴 항목을 보조 기술의 동작으로도 준다 (프로젝트 줄만)
private struct FolderActions: ViewModifier {
    let enabled: Bool
    let onChange: () -> Void
    let onRemove: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .accessibilityAction(named: AgentSettingsCopy.change, onChange)
                .accessibilityAction(named: AgentSettingsCopy.removeFolderAction, onRemove)
        } else {
            content
        }
    }
}

#Preview("Your agents") {
    let facts = AgentSettingsFacts(
        canRunAgents: true, status: .connected, hasLiveProcess: true,
        report: BridgeV1AdapterReport(adapter: "agent:claude-code", installed: true, version: "2.1.241", signedIn: .yes, managedSettings: false),
        target: .row(state: .unsupported, access: .write)
    )
    let project = AgentFolderProject(id: UUID(), name: "Shape launch", icon: .rocket)
    let folders = AgentSettingsFolders.lines(folders: [project.id: "/Users/alex/Documents/Shape/launch"], projects: [project.id: project], homes: ["/Users/alex"], exists: { _ in true })
    return VStack(alignment: .leading, spacing: SettingsTray.topicGap) {
        SettingsSection(AgentSettingsCopy.sectionTitle) {
            AgentRow(line: AgentSettingsRules.line(facts), onOpen: {})
            AgentRow(line: AgentSettingsRules.line(AgentSettingsFacts(canRunAgents: true, status: .revoked, report: facts.report, target: .none)), hint: AgentSettingsCopy.somethingWentWrong, onOpen: {})
        }
        SettingsSection(AgentSettingsCopy.folders, footnote: AgentSettingsCopy.foldersFootnote) {
            ForEach(folders.lines) { AgentFolderRow(line: $0) }
        }
    }
    .padding(20)
    .frame(width: 560)
    .background(TFColor.bgSurface)
}
#endif
