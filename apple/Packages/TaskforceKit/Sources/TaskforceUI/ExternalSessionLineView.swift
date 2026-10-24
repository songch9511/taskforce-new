#if os(macOS)
import SwiftUI
import TaskforceKit

/// 외부 세션 줄 (OA 외부 세션 PR1, DS 승인 2026-10-21 · SessionRow 모양): Claude Code 마크 20 · 제목(callout, 한 줄 끝 줄임) · 둘째 줄(footnote, 굵은 상태 말 + 회색 조각) · 오른쪽 링 · 동작.
/// - 오른쪽 동작은 버튼 하나("Open in Claude", 여는 동안은 "Opening…" 비활성)다. **줄에 포인터를 올리거나 키보드 포커스가 있을 때만 보인다** (DZ 승인 2026-10-22 `oa-rail-sessions-dz`: 줄을 누르면 이제 Taskforce 안에서 그 세션이 열리고 세션 보기 머리에도 같은 버튼이 있다.
///   늘 보이면 링 + 버튼이 둘째 줄을 잘라 시각이 사라진다). 보이지 않는 동안에도 VoiceOver에는 "Open in Claude" 동작이 있다
/// - `onOpen`이 있으면 줄 전체가 버튼이다: Taskforce가 상태를 아는 살아 있는 데스크톱 줄은 누르면 Claude 세션 보기가 열린다. 없으면 줄은 누르는 곳이 아니다 (터미널 · 막힘 · 모름 줄)
/// - `ring`: Taskforce가 상태를 아는 데스크톱 줄에만 (Taskforce 세션 링과 똑같이 그린다: 마크 없음). 줄 끝 12pt, 동작 버튼이 보이면 그 왼쪽
/// - 호버의 `bg/selected`는 누를 수 있는 줄(`highlightsOnHover`)에만 칠한다. 접근성 이름은 "{제목} — {둘째 줄}"
public struct ExternalSessionLineView: View {
    let content: ExternalSessionLineContent
    let ring: AgentSessionRing?
    let onOpen: (() -> Void)?
    let current: Bool
    let onAction: (ExternalSessionLineContent.Action) -> Void
    @State private var hovering = false
    @FocusState private var rowFocused: Bool
    @FocusState private var actionFocused: Bool

    public init(
        content: ExternalSessionLineContent, ring: AgentSessionRing? = nil, current: Bool = false, onOpen: (() -> Void)? = nil,
        onAction: @escaping (ExternalSessionLineContent.Action) -> Void = { _ in }
    ) {
        self.content = content
        self.ring = ring
        self.current = current
        self.onOpen = onOpen
        self.onAction = onAction
    }

    /// 스냅샷만 (Release는 늘 거짓): 호버한 것으로 그린다
    private var pretendsHover: Bool {
        #if DEBUG
        ExternalSessionLineSnapshot.hoveredTitles.contains(content.title)
        #else
        false
        #endif
    }

    /// 동작 버튼을 보이나: 호버 · 줄이나 버튼의 키보드 포커스 · 여는 동안(눌렀는데 버튼이 사라지면 "Opening…"이 안 보인다)
    private var showsAction: Bool { content.action != nil && (hovering || pretendsHover || rowFocused || actionFocused || content.isBusy) }

    public var body: some View {
        Group {
            if let onOpen {
                Button(action: onOpen) { rowContent }
                    .buttonStyle(.plain)
                    .focused($rowFocused)
                    .accessibilityLabel(content.accessibilityName)
                    .accessibilityAddTraits(current ? .isSelected : [])
                    .accessibilityActions { accessibilityOpenAction }
            } else {
                rowContent
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(content.accessibilityName)
                    .accessibilityActions { accessibilityOpenAction }
            }
        }
        .onHover { hovering = $0 }
        .animation(TFMotion.ease(TFMotion.hoverFade), value: highlighted)
    }

    /// VoiceOver 동작: 보이는 버튼의 동작과 (Resume here가 보이는 쉬는 데스크톱 줄의) Open in Claude. 여는 동안은 없다
    @ViewBuilder private var accessibilityOpenAction: some View {
        if !content.isBusy {
            ForEach(Array(([content.action].compactMap { $0 } + content.extraActions).enumerated()), id: \.offset) { _, action in
                Button(content.title(of: action)) { onAction(action) }
            }
        }
    }

    private var rowContent: some View {
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
            if let ring {
                ActivityRing(ActivityRing.Kind(ring), size: .small, ground: .light, look: .capsule)
                    .frame(height: 20)
                    .accessibilityHidden(true)
            }
            if showsAction, let action = content.action {
                // 여는 동안(`isBusy`)은 글자가 "Opening…"이 되고 눌리지 않는다 (버튼 스타일이 비활성 모양으로 흐리게 그린다)
                Button(content.actionTitle) { onAction(action) }
                    .buttonStyle(TFButtonStyle(.secondary, size: .sm))
                    .disabled(content.isBusy)
                    .focused($actionFocused)
                    .padding(.top, -1)
                    .transition(.opacity)
            }
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlighted || current ? TFColor.bgSelected : Color.clear, in: RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous))
        .contentShape(Rectangle())
    }

    /// 포인터가 올라 있고 그 줄이 눌리는 줄일 때만 칠한다
    private var highlighted: Bool { (hovering || pretendsHover) && (content.highlightsOnHover || onOpen != nil) }

    /// 굵은 첫 말(DS :44, 빨강 없음) + 회색 조각들
    private var meta: Text {
        let quiet = highlighted || current ? TFColor.textSecondarySelected : TFColor.textSecondary
        let word = Text(content.statusWord)
            .fontWeight(content.statusIsEmphasis ? .semibold : .regular)
            .foregroundColor(content.statusIsEmphasis ? TFColor.textPrimary : quiet)
        guard !content.detail.isEmpty else { return word }
        return word + Text(" · " + content.detail.joined(separator: " · ")).foregroundColor(quiet)
    }
}

/// 줄 밑에 서는 이어받기 제자리 확인 (OA 외부 세션 PR2m, DZ 승인 2026-10-21 · 계약 8.3 · 17장): `ConfirmRow`를 패널 안에 그대로 쓴다 (`bg/field` 바탕 · 둥근 모서리).
/// 제목 "Resume this session in Taskforce?" · 설명 "Don't open it in Claude while Taskforce is working." · 확인 "Resume here" · Cancel이 먼저 포커스.
/// `note`는 직전 시도가 거절된 이유의 회색 한 줄이다 (단추 밑, 빨강 없음). 도는 중(`busy`)에는 확인이 비활성이고 스피너가 돈다
public struct ExternalSessionConfirmView: View {
    let note: String?
    let busy: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    public init(note: String? = nil, busy: Bool = false, onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.note = note
        self.busy = busy
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    public var body: some View {
        ConfirmRow(
            ExternalSessionAttachCopy.confirmTitle, detail: ExternalSessionAttachCopy.confirmDetail, confirmLabel: ExternalSessionAttachCopy.resumeHere, busy: busy, note: note,
            onConfirm: onConfirm, onCancel: onCancel
        )
        .background(TFColor.bgField, in: RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous))
    }
}

#if DEBUG
/// 디자인 비교 스냅샷만 (Debug): 이 제목의 줄을 호버한 것처럼 보인다 (Open in Claude가 뜬다). 앱의 다른 곳에서는 쓰지 않는다
public enum ExternalSessionLineSnapshot {
    nonisolated(unsafe) public static var hoveredTitles: Set<String> = []
}
#endif

#Preview("ExternalSessionLine") {
    VStack(spacing: 2) {
        ExternalSessionLineView(content: .init(title: "Fix launcher focus after sleep when the panel is open", statusWord: "Running in Claude", statusIsEmphasis: true, detail: ["2 min ago"], action: .openInClaude), ring: .running, onOpen: {})
        ExternalSessionLineView(content: .init(title: "Add RLS test", statusWord: "Idle", statusIsEmphasis: false, detail: ["40 min ago", "Claude desktop"], action: nil))
        ExternalSessionLineView(content: .init(title: "Banner variants", statusWord: "Can't resume here", statusIsEmphasis: true, detail: ["Worktree", "2 hr ago"], action: nil))
        ExternalSessionLineView(content: .init(title: "Rewrite the pricing page copy", statusWord: "Idle", statusIsEmphasis: false, detail: ["40 min ago"], action: nil), current: true)
        ExternalSessionConfirmView(note: "Close it in Claude first", onConfirm: {}, onCancel: {})
    }
    .padding(8)
    .frame(width: 380)
    .background(TFColor.bgPanel)
}
#endif
