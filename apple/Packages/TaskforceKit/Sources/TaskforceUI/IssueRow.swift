import SwiftUI
import TaskforceKit

/// IssueRow (0.2.0 디자인 시스템 Molecules, OA U2): 프로젝트 · Ungrouped · Done today 목록의 이슈 한 줄 (Figma `8:152`, 36pt).
/// StatusMark 16 · 제목(callout, 한 줄 끝 줄임) · 오른쪽 meta 하나(footnote, **줄이지 않는다**, 제목이 먼저 줄어든다). 안쪽 8/10 · 간격 10 · 구분선 없음.
/// - meta는 활동("Needs your answer" · "Running" · …)이 먼저, 없으면 기한(`DueText.short`). 기한이 지났거나 오늘이면 `status/overdue` 600 (지났으면 접근성 이름에 "overdue")
/// - 번호는 행에 없다 (번호는 상세 머리 · 세션 머리 · 칩). 끝낸 행 제목은 `text/secondary` (취소선 없음)
/// - 호버 · 현재 행 · 레일에서 가리킨 행은 `bg/selected`, 보조 글자는 `text/secondary-selected`. Ask 알약이 뜨는 동안은 meta가 가려진다
public struct IssueRow: View {
    let content: IssueRowContent
    let current: Bool
    let highlighted: Bool
    let askLabel: String?
    let onOpen: () -> Void
    let onAsk: (() -> Void)?

    /// - askLabel: Ask 알약의 접근성 이름 ("Ask about #139", 번호를 쓰는 쪽이 정한다)
    public init(
        _ content: IssueRowContent, current: Bool = false, highlighted: Bool = false, askLabel: String? = nil, onOpen: @escaping () -> Void,
        onAsk: (() -> Void)? = nil
    ) {
        self.content = content
        self.current = current
        self.highlighted = highlighted
        self.askLabel = askLabel
        self.onOpen = onOpen
        self.onAsk = onAsk
    }

    public var body: some View {
        PanelRowChrome(
            current: current, highlighted: highlighted, accessibilityName: content.accessibilityLabel, askLabel: askLabel, onOpen: onOpen, onAsk: onAsk
        ) { lit, asking in
            let secondary = lit ? TFColor.textSecondarySelected : TFColor.textSecondary
            HStack(spacing: 10) {
                StatusMark(StatusMark.State(content.state))
                Text(content.title)
                    .font(TFFont.callout)
                    .tracking(-0.24)
                    .foregroundStyle(content.state == .done ? secondary : TFColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let meta = content.metaText {
                    Text(meta)
                        .font(content.urgent && content.metaIsDue ? TFFont.footnoteEmphasis : TFFont.footnote)
                        .monospacedDigit()
                        .foregroundStyle(content.urgent && content.metaIsDue ? (lit ? TFColor.statusOverdueSelected : TFColor.statusOverdue) : secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .opacity(asking ? 0 : 1)
                }
            }
            // 줄 높이 20 + 위아래 8 = 36
            .frame(minHeight: 20)
        }
    }
}

#Preview("Issue rows") {
    let row = { (title: String, state: WorkState, activity: String?, due: String?, urgent: Bool) in
        IssueRowContent(id: UUID(), title: title, state: state, activity: activity, due: due, urgent: urgent, overdue: urgent)
    }
    VStack(spacing: 0) {
        GroupLabel("In Progress")
        IssueRow(row("Rewrite pricing page copy for the 3-day trial and Lifetime plan", .inProgress, "Needs your answer", nil, false), onOpen: {})
        IssueRow(row("Wire EdgeRail rings to live session state", .inProgress, nil, "Thu", false), onOpen: {})
        GroupLabel("To Do")
        IssueRow(row("Ask Mina to confirm the refund window", .toDo, nil, "Yesterday", true), current: true, onOpen: {})
        IssueRow(row("Apple sign-in on Mac next to Google", .toDo, nil, "Oct 20", false), onOpen: {}, onAsk: {})
        GroupLabel("Done today")
        IssueRow(row("Privacy policy beta 1.4", .done, nil, nil, false), onOpen: {})
    }
    .padding(8)
    .frame(width: 380)
    .background(TFColor.bgPanel)
}
