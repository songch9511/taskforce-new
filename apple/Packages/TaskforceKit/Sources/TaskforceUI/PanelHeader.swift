import SwiftUI

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

/// Panel header (0.2.0 디자인 시스템 Organisms): 패널의 맨 윗줄. 제목, 그다음 컨트롤 셋까지. 닫기 버튼은 없다
/// (밖을 누르거나 Esc · ⌥ Space로 접힌다). 두 번째 줄 · 탭 · 머리글 없음.
/// - steps: Review 항목의 위치 (6pt 점, 24pt 누르는 영역, 둘 이상일 때만)
/// - onPin: 일에만 (`pinned`), onNewChat · onHistory: 채팅에만
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

    public init(
        title: String, steps: Steps? = nil, onStep: ((Int) -> Void)? = nil, pinned: Bool? = nil, onPin: (() -> Void)? = nil,
        onNewChat: (() -> Void)? = nil, historyOpen: Bool? = nil, onHistory: (() -> Void)? = nil
    ) {
        self.title = title
        self.steps = steps
        self.onStep = onStep
        self.pinned = pinned
        self.onPin = onPin
        self.onNewChat = onNewChat
        self.historyOpen = historyOpen
        self.onHistory = onHistory
    }

    public var body: some View {
        HStack(spacing: TFSpace.xs) {
            Text(title)
                .font(TFFont.calloutEmphasis)
                .tracking(-0.24)
                .foregroundStyle(TFColor.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
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
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 10))
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
