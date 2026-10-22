#if os(macOS)
import SwiftUI
import TaskforceKit

/// Sessions 패널 Taskforce 절의 줄 (OA PR-D2, DZ 승인 2026-10-22 `oa-rail-sessions-dz` 시트 4): 에이전트 마크 20 · 세션 이름(callout) · "상태 · 마지막 활동 · 이슈 번호"(footnote) · 줄 끝 링(밝은 바탕 12pt).
/// 끝난(closed) 세션은 `SessionRow.Look`처럼 흐리게(이름 `text-secondary` · 마크 .45), 상태 말 없이 시각 · 번호만, 링 없음. 줄 전체가 버튼이다 (누르면 그 세션 패널이 이 패널 왼쪽에 열린다).
/// 링은 레일의 Taskforce 세션 링과 똑같이 그린다. `current`는 `bg/selected` (지금 그 세션 패널이 열려 있다). 접근성 이름은 `row.accessibilityName`
public struct SessionsTaskforceRowView: View {
    let row: SessionsTaskforceRow
    let current: Bool
    let onOpen: () -> Void

    public init(_ row: SessionsTaskforceRow, current: Bool = false, onOpen: @escaping () -> Void) {
        self.row = row
        self.current = current
        self.onOpen = onOpen
    }

    public var body: some View {
        let look = SessionRow.Look.of(line: row.metaText, dimmed: row.isClosed)
        PanelRowChrome(current: current, highlighted: false, accessibilityName: row.accessibilityName, askLabel: nil, onOpen: onOpen, onAsk: nil) { lit, _ in
            HStack(alignment: .top, spacing: 10) {
                AgentMark(row.agent, size: 20)
                    .opacity(look.markOpacity)
                    .frame(minHeight: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.name)
                        .font(TFFont.callout)
                        .tracking(-0.24)
                        .foregroundStyle(look.nameIsQuiet ? TFColor.textSecondary : TFColor.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: 20, alignment: .leading)
                    Text(row.metaText)
                        .font(TFFont.footnote)
                        .tracking(-0.08)
                        .foregroundStyle(lit ? TFColor.textSecondarySelected : TFColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: 18, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let ring = row.ring {
                    ActivityRing(ActivityRing.Kind(ring), size: .small, ground: .light, look: .capsule)
                        .frame(height: 20)
                        .accessibilityHidden(true)
                }
            }
        }
    }
}

/// 절 머리 (DS GroupLabel): "Taskforce" · "On this Mac" + 오른쪽 링크 하나("Show all" · "Show less")는 접을 수 있는 줄이 있을 때만
public struct SessionsSectionHeader: View {
    let title: String
    let togglesFold: Bool
    let expanded: Bool
    let onToggle: () -> Void

    public init(_ title: String, togglesFold: Bool, expanded: Bool, onToggle: @escaping () -> Void) {
        self.title = title
        self.togglesFold = togglesFold
        self.expanded = expanded
        self.onToggle = onToggle
    }

    public var body: some View {
        GroupLabel(title) {
            if togglesFold { QuietLink(expanded ? ExternalSessionCopy.showLess : ExternalSessionCopy.showAll, action: onToggle) }
        }
    }
}

/// 절 안의 한 줄 안내 ("Checking…" · "Couldn't check sessions" + Try again · "Claude Code isn't installed" + Get Claude Code): 패널 전체를 비우지 않는다 (Taskforce 세션은 그대로 보인다)
public struct SessionsSectionNote<Action: View>: View {
    let text: String
    let action: Action

    public init(_ text: String, @ViewBuilder action: () -> Action) {
        self.text = text
        self.action = action()
    }

    public var body: some View {
        HStack(spacing: TFSpace.sm) {
            Text(text)
                .font(TFFont.callout)
                .foregroundStyle(TFColor.textSecondary)
                .lineLimit(1)
            action
        }
        .padding(EdgeInsets(top: 4, leading: 10, bottom: 8, trailing: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

extension SessionsSectionNote where Action == EmptyView {
    public init(_ text: String) {
        self.init(text, action: { EmptyView() })
    }
}

#Preview("Sessions rows") {
    VStack(spacing: 0) {
        SessionsSectionHeader(SessionsPanelCopy.taskforce, togglesFold: true, expanded: false) {}
        SessionsTaskforceRowView(
            SessionsTaskforceRow(id: UUID(), name: "Pricing copy draft", agent: .claudeCode, ring: .running, isClosed: false, metaText: "Running · 1 min ago · #12", accessibilityName: "Pricing copy draft"),
            onOpen: {}
        )
        SessionsTaskforceRowView(
            SessionsTaskforceRow(id: UUID(), name: "Update the Settings window copy", agent: .claudeCode, ring: .done, isClosed: false, metaText: "Done · 40 min ago · #11", accessibilityName: "x"), onOpen: {}
        )
        SessionsTaskforceRowView(
            SessionsTaskforceRow(id: UUID(), name: "Spike: bridge reconnect backoff", agent: .claudeCode, ring: nil, isClosed: true, metaText: "Yesterday · #8", accessibilityName: "y"), onOpen: {}
        )
    }
    .padding(8)
    .frame(width: 380)
    .background(TFColor.bgPanel)
}
#endif
