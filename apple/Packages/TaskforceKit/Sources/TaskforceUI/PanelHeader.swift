import SwiftUI
import TaskforceKit

/// Icon button (0.2.0 디자인 시스템 Atoms): 글자 없는 컨트롤 (패널 머리 · 입력칸). 늘 접근성 이름이 있다.
/// 28pt 누르는 영역, 호버 · 눌림 · 펼침은 `bg/selected`(청색 아님). 닫기 IconButton은 없다.
public struct TFIconButton: View {
    let icon: TFIcon
    let label: String
    let size: CGFloat
    let isOn: Bool
    let action: () -> Void
    @State private var hovering = false

    /// - isOn: `pressed`(Pin 같은 토글) 또는 `expanded`(History처럼 여는 것)
    public init(_ icon: TFIcon, label: String, size: CGFloat = 14, isOn: Bool = false, action: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.size = size
        self.isOn = isOn
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            icon.image(size: size)
                .frame(width: 28, height: 28)
                .background {
                    RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous)
                        .fill(hovering || isOn ? TFColor.bgSelected : .clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(TFColor.textPrimary)
        .onHover { hovering = $0 }
        .animation(TFMotion.ease(TFMotion.hoverFade), value: hovering)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// 세션 패널 머리의 알약 하나 (Open in Terminal · Resume here, OA U2). 동작이 주어질 때만 머리에 보인다 (U2에서는 견본 하네스뿐, 동작은 D4a)
public struct PanelHeaderPill {
    public let title: String
    /// 꺼진 이유: 알약은 말을 그대로 두고 흐려지며(불투명도 .45) 이유는 알약 아래 툴팁과 접근성이 말한다. 높이는 꺼져도 같다
    public let disabledReason: String?
    public let action: () -> Void

    public init(title: String, disabledReason: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.disabledReason = disabledReason
        self.action = action
    }
}

/// Panel header (0.2.0 디자인 시스템 Organisms): 패널의 맨 윗줄. 제목, 그다음 컨트롤 셋까지. 닫기 버튼은 없다
/// (밖을 누르거나 Esc · ⌥ Space로 접힌다). 두 번째 줄 · 탭 · 머리글 없음 (세션 변형의 상태 줄 하나만 있다).
/// - steps: Review 항목의 위치 (6pt 점, 24pt 누르는 영역, 둘 이상일 때만)
/// - onPin: 일에만 (`pinned`), onNewChat · onHistory: 채팅에만
/// - onBack: 이슈 목록 · 이슈 상세의 뒤로 (`chevron-left`, 왼쪽 8). onAdd: 이슈 목록의 직접 추가 (`plus`, "Add task")
/// - **세션 변형**(OA U2): `agent`가 에이전트 마크 20(제목과 8)을 앞에 두고, 제목은 "세션 이름 — #번호"다. `pill`은 끝의 알약 하나(Secondary S: 24pt, 12 · 600, 아이콘 없음),
///   `status`는 머리 아래 글만 있는 한 줄(footnote `text/secondary`, 안쪽 0 16 10, 한 줄 끝 줄임). 세션 머리는 알약이 있어도 40pt다 (위 10 · 아래 6). View full은 머리에 없다
public struct PanelHeader: View {
    public struct Steps: Equatable, Sendable {
        public let count: Int
        public let current: Int

        public init(count: Int, current: Int) {
            self.count = count
            self.current = current
        }

        /// "Review item 2 of 3"
        public var accessibilityLabel: String { "Review item \(current + 1) of \(count)" }
    }

    let title: String
    let steps: Steps?
    let onStep: ((Int) -> Void)?
    let pinned: Bool?
    let onPin: (() -> Void)?
    let onNewChat: (() -> Void)?
    let historyOpen: Bool?
    let onHistory: (() -> Void)?
    let onBack: (() -> Void)?
    let onAdd: (() -> Void)?
    let agent: AgentMarkKind?
    let pill: PanelHeaderPill?
    let status: String?
    /// 끝난 세션의 머리: 마크 불투명도 .45 · 제목 `text/secondary` (상태 줄은 없다)
    let dimmed: Bool
    @State private var hoveringPill = false

    public init(
        title: String, steps: Steps? = nil, onStep: ((Int) -> Void)? = nil, pinned: Bool? = nil, onPin: (() -> Void)? = nil,
        onNewChat: (() -> Void)? = nil, historyOpen: Bool? = nil, onHistory: (() -> Void)? = nil,
        onBack: (() -> Void)? = nil, onAdd: (() -> Void)? = nil, agent: AgentMarkKind? = nil, pill: PanelHeaderPill? = nil, status: String? = nil, dimmed: Bool = false
    ) {
        self.dimmed = dimmed
        self.onBack = onBack
        self.onAdd = onAdd
        self.agent = agent
        self.pill = pill
        self.status = status
        self.title = title
        self.steps = steps
        self.onStep = onStep
        self.pinned = pinned
        self.onPin = onPin
        self.onNewChat = onNewChat
        self.historyOpen = historyOpen
        self.onHistory = onHistory
    }

    /// 세션 변형인가 (에이전트 마크 · 알약 · 상태 줄 중 하나라도 있다)
    private var isSession: Bool { agent != nil || pill != nil || status != nil }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            if let status {
                Text(status)
                    .font(TFFont.footnote)
                    .tracking(-0.08)
                    .foregroundStyle(TFColor.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(EdgeInsets(top: 0, leading: TFSpace.lg, bottom: 10, trailing: TFSpace.lg))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var row: some View {
        HStack(spacing: TFSpace.xs) {
            if let onBack {
                TFIconButton(.back, label: "Back", size: 16, action: onBack)
            }
            if let agent {
                AgentMark(agent, size: 20)
                    .opacity(dimmed ? SessionRow.Look.of(line: "", dimmed: true).markOpacity : 1)
                    .padding(.trailing, TFSpace.xs)
            }
            Text(title)
                .font(TFFont.calloutEmphasis)
                .tracking(-0.24)
                .foregroundStyle(dimmed ? TFColor.textSecondary : TFColor.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(-1)
                .accessibilityAddTraits(.isHeader)
            if let steps, steps.count > 1 {
                HStack(spacing: 0) {
                    ForEach(0..<steps.count, id: \.self) { index in
                        Button { onStep?(index) } label: {
                            Circle()
                                .fill(index == steps.current ? TFColor.textPrimary : TFColor.statusStepInactive)
                                .frame(width: 6, height: 6)
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Review item \(index + 1)")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(steps.accessibilityLabel)
            }
            if let pinned, let onPin {
                TFIconButton(.pin, label: pinned ? "Unpin work" : "Pin work", isOn: pinned, action: onPin)
            }
            if let onNewChat {
                TFIconButton(.newChat, label: "New chat", action: onNewChat)
            }
            if let historyOpen, let onHistory {
                TFIconButton(.chatHistory, label: "Chat history", isOn: historyOpen, action: onHistory)
            }
            if let onAdd {
                TFIconButton(.addTask, label: "Add task", size: 16, action: onAdd)
            }
            if let pill {
                pillView(pill)
                    .padding(.leading, TFSpace.xs)
            }
        }
        // 뒤로 · 추가 버튼(28 누르는 영역)이 있어도 머리는 40이다 (Figma M3 · M4: 행 20 + 위 12 · 아래 8): 버튼은 제목 줄 높이를 넘어 겹쳐 놓는다. 옛 머리(Chats)는 그대로
        .frame(height: onBack != nil || onAdd != nil ? 20 : nil)
        .padding(isSession ? EdgeInsets(top: 10, leading: 16, bottom: 6, trailing: 10) : EdgeInsets(top: 12, leading: onBack == nil ? 16 : 8, bottom: 8, trailing: 10))
    }

    /// 스냅샷만 (Release는 늘 거짓): 알약을 호버한 것으로 그린다
    private static var pretendsHover: Bool {
        #if DEBUG
        PanelHeaderSnapshot.showsPillTooltip
        #else
        false
        #endif
    }

    /// 알약: Button secondary sm. 꺼져도 글은 그대로고, 이유는 알약 아래 툴팁(DS `.tf-tip.is-below`)과 접근성이 말한다
    @ViewBuilder
    private func pillView(_ pill: PanelHeaderPill) -> some View {
        let disabled = pill.disabledReason != nil
        Button(pill.title, action: pill.action)
            .buttonStyle(TFButtonStyle(.secondary, size: .sm))
            .disabled(disabled)
            .fixedSize()
            .accessibilityLabel(pill.title)
            .accessibilityHint(pill.disabledReason ?? "")
            .overlay(alignment: .bottomTrailing) {
                if disabled, hoveringPill || Self.pretendsHover, let reason = pill.disabledReason {
                    PanelTooltip(reason)
                        .offset(y: 24 + 6)
                        .fixedSize()
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .onHover { hoveringPill = $0 }
            .animation(TFMotion.ease(TFMotion.hoverFade), value: hoveringPill)
            .zIndex(1)
    }
}

/// 툴팁 (DS `.tf-tip.is-below`): `bg/tooltip`, 모서리 5, 안쪽 6/9, 12/16, 그림자. 알약 아래 6 · 오른쪽 맞춤 (레일 툴팁과 같은 값)
public struct PanelTooltip: View {
    let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(TFFont.meta)
            .foregroundStyle(TFColor.textPrimary)
            .lineLimit(1)
            .padding(EdgeInsets(top: 6, leading: 9, bottom: 6, trailing: 9))
            .background(TFColor.bgTooltip, in: RoundedRectangle(cornerRadius: TFRadius.sm, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
            .accessibilityHidden(true)
    }
}

#Preview("Panel header") {
    VStack(spacing: 0) {
        PanelHeader(title: "All work")
        PanelHeader(title: "Launch timing", steps: .init(count: 3, current: 0), onStep: { _ in })
        PanelHeader(title: "Pricing page with a very long title that truncates", pinned: true, onPin: {})
        PanelHeader(title: "Shape launch", onNewChat: {}, historyOpen: false, onHistory: {})
    }
    .frame(width: 380)
    .background(TFColor.bgPanel)
}

#if DEBUG
/// 디자인 비교 스냅샷만 (Debug): 꺼진 알약의 툴팁("Turn is running")을 호버한 것처럼 보인다. 앱의 다른 곳에서는 쓰지 않는다
public enum PanelHeaderSnapshot {
    nonisolated(unsafe) public static var showsPillTooltip = false
}
#endif
