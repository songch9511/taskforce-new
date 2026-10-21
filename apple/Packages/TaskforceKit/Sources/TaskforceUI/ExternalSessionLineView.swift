#if os(macOS)
import SwiftUI
import TaskforceKit

/// 외부 세션 줄 (OA 외부 세션 PR1, DS 승인 2026-10-21 · SessionRow 모양): Claude Code 마크 20 · 제목(callout, 한 줄 끝 줄임) · 둘째 줄(footnote, 굵은 상태 말 + 회색 조각) · 오른쪽 동작.
/// 줄 전체는 누르는 곳이 아니다: 동작은 오른쪽 버튼 하나("Open in Claude")뿐이다 (이어받기는 다음 PR). 호버의 `bg/selected`는 버튼이 있는 줄에만 칠한다 (`highlightsOnHover`): 누를 수 없는 줄은 반응하지 않는다.
/// 링은 이어받은 줄에만 있고(이어받기 PR) 이 줄에는 없다. 접근성 이름은 "{제목} — {둘째 줄}"
public struct ExternalSessionLineView: View {
    let content: ExternalSessionLineContent
    let onAction: (ExternalSessionLineContent.Action) -> Void
    @State private var hovering = false

    public init(content: ExternalSessionLineContent, onAction: @escaping (ExternalSessionLineContent.Action) -> Void = { _ in }) {
        self.content = content
        self.onAction = onAction
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentMark(.claudeCode, size: 20)
                .frame(minHeight: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(content.title)
                    .font(TFFont.callout)
                    .tracking(-0.24)
                    .foregroundStyle(TFColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(height: 20, alignment: .leading)
                meta
                    .font(TFFont.footnote)
                    .tracking(-0.08)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(height: 18, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let action = content.action {
                Button(ExternalSessionCopy.openInClaude) { onAction(action) }
                    .buttonStyle(TFButtonStyle(.secondary, size: .sm))
                    .padding(.top, -1)
            }
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlighted ? TFColor.bgSelected : Color.clear, in: RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(TFMotion.ease(TFMotion.hoverFade), value: highlighted)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(content.accessibilityName)
    }

    /// 포인터가 올라 있고 그 줄이 눌리는 줄일 때만 칠한다
    private var highlighted: Bool { hovering && content.highlightsOnHover }

    /// 굵은 첫 말(DS :44, 빨강 없음) + 회색 조각들
    private var meta: Text {
        let quiet = highlighted ? TFColor.textSecondarySelected : TFColor.textSecondary
        let word = Text(content.statusWord)
            .fontWeight(content.statusIsEmphasis ? .semibold : .regular)
            .foregroundColor(content.statusIsEmphasis ? TFColor.textPrimary : quiet)
        guard !content.detail.isEmpty else { return word }
        return word + Text(" · " + content.detail.joined(separator: " · ")).foregroundColor(quiet)
    }
}

#Preview("ExternalSessionLine") {
    VStack(spacing: 2) {
        ExternalSessionLineView(content: .init(title: "Fix launcher focus after sleep when the panel is open", statusWord: "Running in Claude", statusIsEmphasis: true, detail: ["2 min ago"], action: .openInClaude))
        ExternalSessionLineView(content: .init(title: "Add RLS test", statusWord: "Idle", statusIsEmphasis: false, detail: ["40 min ago", "Claude desktop"], action: nil))
        ExternalSessionLineView(content: .init(title: "Banner variants", statusWord: "Can't resume here", statusIsEmphasis: true, detail: ["Worktree", "2 hr ago"], action: nil))
    }
    .padding(8)
    .frame(width: 380)
    .background(TFColor.bgPanel)
}
#endif
