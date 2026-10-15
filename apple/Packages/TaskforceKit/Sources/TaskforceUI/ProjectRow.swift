import SwiftUI
import TaskforceKit

/// ProjectRow (0.2.0 디자인 시스템 Molecules, OA U2): Projects 목록의 프로젝트 하나. 아이콘 · 이름(callout) · "가장 행동할 한 줄"(footnote `text/secondary`).
/// - 두 줄이고 둘 다 한 줄 끝 줄임. 안쪽 8/10 · 모서리 8 · 간격 10. 아이콘은 이름 줄에 맞춘 **위 정렬**이다 (DS `.tf-prow`: lead 최소 20)
/// - meta는 개수 없는 한 줄 (`ProjectListRules`). 비면 이름 한 줄만
/// - Ungrouped · Done today도 행이다 (고정된 조용한 아이콘)
/// - `current`는 `bg/selected`. 호버 · 현재 행의 meta는 `text/secondary-selected`. 접근성 이름 "{name} — {meta}"
public struct ProjectRow: View {
    let content: ProjectRowContent
    let current: Bool
    let highlighted: Bool
    let onOpen: () -> Void
    let onAsk: (() -> Void)?

    public init(
        _ content: ProjectRowContent, current: Bool = false, highlighted: Bool = false, onOpen: @escaping () -> Void, onAsk: (() -> Void)? = nil
    ) {
        self.content = content
        self.current = current
        self.highlighted = highlighted
        self.onOpen = onOpen
        self.onAsk = onAsk
    }

    private var glyphKind: ProjectGlyph.Kind {
        switch content.kind {
        case .project: .project(content.icon ?? .folder)
        case .ungrouped: .ungrouped
        case .doneToday: .doneToday
        }
    }

    public var body: some View {
        PanelRowChrome(
            current: current, highlighted: highlighted, accessibilityName: content.accessibilityName,
            askLabel: onAsk == nil ? nil : AskPill.accessibilityName(number: nil, name: content.name), onOpen: onOpen, onAsk: onAsk
        ) { lit, asking in
            HStack(alignment: .top, spacing: 10) {
                ProjectGlyph(glyphKind, lit: lit)
                    .frame(minHeight: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(content.name)
                        .font(TFFont.callout)
                        .tracking(-0.24)
                        .foregroundStyle(TFColor.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: 20, alignment: .leading)
                    if !content.meta.isEmpty {
                        Text(content.meta)
                            .font(TFFont.footnote)
                            .tracking(-0.08)
                            .foregroundStyle(lit ? TFColor.textSecondarySelected : TFColor.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(height: 18, alignment: .leading)
                            .opacity(asking ? 0 : 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// SessionRow (0.2.0 디자인 시스템 Molecules, OA U2): 이슈의 에이전트 세션 하나. 에이전트 마크 20 · 세션 이름(callout) · 지금 어디에 있나(footnote `text/secondary`).
/// ProjectRow와 같은 수치. 말은 동사를 앞에 ("Running", "External · Open in Terminal"): 줄임이 동사를 남긴다. 접근성 이름 "{이름} — {에이전트} — {말}"
public struct SessionRow: View {
    let name: String
    let agent: AgentMarkKind
    let line: String
    let accessibilityName: String
    let current: Bool
    let highlighted: Bool
    let onOpen: () -> Void
    let onAsk: (() -> Void)?

    public init(
        name: String, agent: AgentMarkKind, line: String, accessibilityName: String, current: Bool = false, highlighted: Bool = false,
        onOpen: @escaping () -> Void, onAsk: (() -> Void)? = nil
    ) {
        self.name = name
        self.agent = agent
        self.line = line
        self.accessibilityName = accessibilityName
        self.current = current
        self.highlighted = highlighted
        self.onOpen = onOpen
        self.onAsk = onAsk
    }

    public init(_ item: AgentSessionItem, current: Bool = false, highlighted: Bool = false, onOpen: @escaping () -> Void, onAsk: (() -> Void)? = nil) {
        self.init(
            name: item.name, agent: item.agent, line: item.line, accessibilityName: item.rowAccessibilityName, current: current, highlighted: highlighted,
            onOpen: onOpen, onAsk: onAsk
        )
    }

    public var body: some View {
        PanelRowChrome(
            current: current, highlighted: highlighted, accessibilityName: accessibilityName,
            askLabel: onAsk == nil ? nil : AskPill.accessibilityName(number: nil, name: name), onOpen: onOpen, onAsk: onAsk
        ) { lit, asking in
            HStack(alignment: .top, spacing: 10) {
                AgentMark(agent, size: 20)
                    .frame(minHeight: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(name)
                        .font(TFFont.callout)
                        .tracking(-0.24)
                        .foregroundStyle(TFColor.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: 20, alignment: .leading)
                    Text(line)
                        .font(TFFont.footnote)
                        .tracking(-0.08)
                        .foregroundStyle(lit ? TFColor.textSecondarySelected : TFColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: 18, alignment: .leading)
                        .opacity(asking ? 0 : 1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

#Preview("Project and session rows") {
    VStack(spacing: 0) {
        ProjectRow(ProjectRowContent(kind: .project(UUID()), name: "Shape launch", icon: .megaphone, meta: "Needs your answer · Pricing tone"), onOpen: {})
        ProjectRow(ProjectRowContent(kind: .project(UUID()), name: "Taskforce 0.2.0", icon: .rocket, meta: "Claude Code · Rewrite pricing page copy"), current: true, onOpen: {})
        ProjectRow(ProjectRowContent(kind: .ungrouped, name: "Ungrouped", icon: nil, meta: "Send the proposal to Alex"), onOpen: {}, onAsk: {})
        SessionRow(name: "Pricing copy draft", agent: .claudeCode, line: "Running", accessibilityName: "Pricing copy draft — Claude Code — Running", current: true, onOpen: {})
        SessionRow(name: "Lifetime plan section", agent: .codex, line: "External · Open in Terminal", accessibilityName: "x", onOpen: {})
    }
    .padding(8)
    .frame(width: 380)
    .background(TFColor.bgPanel)
}
