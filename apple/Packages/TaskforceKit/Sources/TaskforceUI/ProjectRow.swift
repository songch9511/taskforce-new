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
public struct SessionRowDisclosure {
    public let isExpanded: Bool
    public let canToggle: Bool
    public let accessibilityValue: String?
    public let toggleActionName: String?
    public let onToggle: () -> Void
    public init(isExpanded: Bool, canToggle: Bool, accessibilityValue: String, toggleActionName: String, onToggle: @escaping () -> Void) {
        self.isExpanded = isExpanded; self.canToggle = canToggle
        self.accessibilityValue = canToggle ? accessibilityValue : nil
        self.toggleActionName = canToggle ? toggleActionName : nil
        self.onToggle = onToggle
    }
}

public struct SessionRow: View {
    /// 끝난(`closed`) 세션의 모양 (사용자 결정 2026-10-15): 상태 말 없이 흐리게. DS에는 `text-tertiary`가 없어 DS의 비활성 값을 쓴다: 이름은 `text-secondary`,
    /// 마크는 불투명도 .45(DS `.tf-btn:disabled` · `.tf-iconbtn:disabled`와 같은 값). 새 색을 만들지 않는다
    public struct Look: Equatable, Sendable {
        public let nameIsQuiet: Bool
        public let markOpacity: Double
        public let showsLine: Bool

        public static func of(line: String, dimmed: Bool) -> Look {
            Look(nameIsQuiet: dimmed, markOpacity: dimmed ? 0.45 : 1, showsLine: !dimmed && !line.isEmpty)
        }
    }

    let name: String
    let agent: AgentMarkKind
    let line: String
    let accessibilityName: String
    let current: Bool
    let highlighted: Bool
    let dimmed: Bool
    var disclosure: SessionRowDisclosure? = nil
    var shared: String? = nil
    var summary: String? = nil
    let onOpen: () -> Void
    let onAsk: (() -> Void)?

    public init(
        name: String, agent: AgentMarkKind, line: String, accessibilityName: String, current: Bool = false, highlighted: Bool = false, dimmed: Bool = false,
        onOpen: @escaping () -> Void, onAsk: (() -> Void)? = nil
    ) {
        self.name = name
        self.agent = agent
        self.line = line
        self.accessibilityName = accessibilityName
        self.current = current
        self.highlighted = highlighted
        self.dimmed = dimmed
        self.onOpen = onOpen
        self.onAsk = onAsk
    }

    public init(_ item: AgentSessionItem, current: Bool = false, highlighted: Bool = false, disclosure: SessionRowDisclosure? = nil, shared: String? = nil, summary: String? = nil, onOpen: @escaping () -> Void, onAsk: (() -> Void)? = nil) {
        self.init(
            name: item.name, agent: item.agent, line: item.line, accessibilityName: Self.accessibilityName(item, shared: shared, summary: summary), current: current, highlighted: highlighted,
            dimmed: item.isClosed, onOpen: onOpen, onAsk: onAsk
        )
        self.disclosure = disclosure
        self.shared = shared
        self.summary = summary
    }

    public static func secondLine(line: String, dimmed: Bool, shared: String?) -> String? {
        let parts = [dimmed || line.isEmpty ? nil : line, shared?.isEmpty == false ? shared : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    public static func accessibilityName(_ item: AgentSessionItem, shared: String? = nil, summary: String? = nil) -> String {
        var result = item.rowAccessibilityName
        if let summary, !summary.isEmpty { result += ", " + summary }
        if let shared, !shared.isEmpty { result += " — " + shared }
        return result
    }

    public var body: some View {
        let look = Look.of(line: line, dimmed: dimmed)
        PanelRowChrome(
            current: current, highlighted: highlighted, accessibilityName: accessibilityName,
            askLabel: onAsk == nil ? nil : AskPill.accessibilityName(number: nil, name: name), onOpen: onOpen, onAsk: onAsk
        ) { lit, asking in
            HStack(alignment: .top, spacing: 10) {
                if disclosure != nil { Color.clear.frame(width: 14, height: 20) }
                AgentMark(agent, size: 20)
                    .opacity(look.markOpacity)
                    .frame(minHeight: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(name)
                        .font(TFFont.callout)
                        .tracking(-0.24)
                        .foregroundStyle(look.nameIsQuiet ? TFColor.textSecondary : TFColor.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: 20, alignment: .leading)
                    if let second = Self.secondLine(line: line, dimmed: dimmed, shared: shared) {
                        Text(second)
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
                if let summary { Text(summary).font(TFFont.footnote).foregroundStyle(TFColor.textSecondary) }
            }
        }
        .overlay(alignment: .topLeading) {
            if let disclosure, disclosure.canToggle {
                Button(action: disclosure.onToggle) {
                    Image(systemName: disclosure.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 24, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 5)
                .accessibilityLabel(disclosure.toggleActionName ?? "")
                .accessibilityValue(disclosure.accessibilityValue ?? "")
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
