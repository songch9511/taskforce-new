import Observation
import SwiftUI
import TaskforceKit

/// TargetPicker (0.2.0 디자인 시스템 Molecules): Assistant 프롬프트 박스 아래 줄에서 다음 메시지가 누구에게 가는지 고른다.
/// - **알약**: 지금 대상의 `AgentMark` 16 + 이름 `footnote` `text/secondary` + `chevrons-up-down` 14, 모서리 6, 안쪽 3/4. 메뉴가 열리면 면이 `bg/selected`
/// - **메뉴**(`TargetMenuView`): 알약 **위로** 열린다. 모든 대상 + 마크, 고른 것에 체크(DS ContextMenu: 오른쪽), Taskforce 뒤 구분선. 가장 긴 줄에 맞춰 240 ~ 460pt
/// - 상태는 행 detail에 단어로 (Unsupported · Read only · Sign in needed · Not connected · Offline · Can't run agents in this build). 상태가 있어도 고를 수 있고 어둡게 하지 않는다
/// - Esc로 닫는다. 선택은 대화마다고 알약이 곧 표시라 다른 데 반복하지 않는다
public struct TargetPill: View {
    nonisolated public static let markSize: CGFloat = 16
    nonisolated public static let chevronSize: CGFloat = 14

    let name: String
    let mark: AgentMarkKind
    let isOpen: Bool
    let action: () -> Void
    @State private var hovering = false

    public init(name: String, mark: AgentMarkKind, isOpen: Bool, action: @escaping () -> Void) {
        self.name = name
        self.mark = mark
        self.isOpen = isOpen
        self.action = action
    }

    /// "Send to Codex"
    nonisolated public static func accessibilityLabel(_ name: String) -> String { "Send to \(name)" }

    public var body: some View {
        let selected = isOpen || hovering
        Button(action: action) {
            HStack(spacing: TFSpace.xs) {
                AgentMark(mark, size: Self.markSize)
                Text(name)
                    .font(TFFont.footnote)
                    .tracking(-0.08)
                    .foregroundStyle(selected ? TFColor.textSecondarySelected : TFColor.textSecondary)
                    .lineLimit(1)
                // 화살표 아이콘은 호버에서도 보조색 그대로다 (DS `.tf-tpick-btn .tf-icon`)
                TFIcon.popupButton.image(size: Self.chevronSize)
                    .foregroundStyle(TFColor.textSecondary)
            }
            .padding(EdgeInsets(top: 3, leading: TFSpace.xs, bottom: 3, trailing: TFSpace.xs))
            .background(selected ? TFColor.bgSelected : Color.clear, in: RoundedRectangle(cornerRadius: ContextChip.radius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(TFMotion.ease(TFMotion.hoverFade), value: selected)
        .accessibilityLabel(Self.accessibilityLabel(name))
        .accessibilityAddTraits(isOpen ? .isSelected : [])
    }
}

/// 메뉴의 줄 이동 · 고름 (↑ ↓ Return). 처음과 끝에서 돌지 않는다
@MainActor
@Observable
public final class TargetMenuModel {
    public let options: [AssistantTargetOption]
    /// 지금 고른 행 (체크)
    public let selected: Int?
    /// 호버 · 키보드로 짚은 행
    public var highlighted: Int?
    @ObservationIgnored public var onPick: (AssistantTargetOption) -> Void

    public init(options: [AssistantTargetOption], selected: Int?, onPick: @escaping (AssistantTargetOption) -> Void) {
        self.options = options
        self.selected = selected
        highlighted = nil
        self.onPick = onPick
    }

    /// ↑ ↓: 아직 짚은 행이 없으면 ↓은 고른 행(없으면 첫 행), ↑은 마지막 행에서 시작한다
    public func move(_ delta: Int) {
        guard !options.isEmpty else { return }
        guard let current = highlighted else {
            highlighted = delta > 0 ? (selected ?? 0) : options.count - 1
            return
        }
        highlighted = min(max(current + delta, 0), options.count - 1)
    }

    /// Return: 짚은 행을 고른다
    public func activate() {
        guard let highlighted, options.indices.contains(highlighted) else { return }
        onPick(options[highlighted])
    }

    public func pick(_ index: Int) {
        guard options.indices.contains(index) else { return }
        onPick(options[index])
    }
}

/// 대상 메뉴 (ContextMenu): `bg/elevated`, 모서리 12, 안쪽 5. 줄은 안쪽 위아래 5 · 왼쪽 8 · 오른쪽 10, 모서리 6, 간격 8, 이름은 callout
public struct TargetMenuView: View {
    nonisolated public static let maxWidth: CGFloat = 460
    /// DS `.tf-cmenu`의 `min-width`
    nonisolated public static let minWidth: CGFloat = 240
    nonisolated public static let inset: CGFloat = 5

    let model: TargetMenuModel

    public init(model: TargetMenuModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.options.enumerated()), id: \.element.id) { index, option in
                row(option, index: index)
                if index == 0, model.options.count > 1 {
                    Rectangle()
                        .fill(TFColor.borderDefault)
                        .frame(height: 1)
                        .padding(EdgeInsets(top: 4, leading: TFSpace.sm, bottom: 4, trailing: TFSpace.sm))
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(Self.inset)
        .frame(minWidth: Self.minWidth, maxWidth: Self.maxWidth)
        .fixedSize(horizontal: true, vertical: true)
        .background(TFColor.bgElevated, in: RoundedRectangle(cornerRadius: TFRadius.panel, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Send to")
    }

    private func row(_ option: AssistantTargetOption, index: Int) -> some View {
        let highlighted = model.highlighted == index
        let isSelected = model.selected == index
        return Button { model.pick(index) } label: {
            HStack(spacing: TFSpace.sm) {
                AgentMark(option.mark, size: TargetPill.markSize)
                Text(option.name)
                    .font(TFFont.callout)
                    .tracking(-0.24)
                    .foregroundStyle(TFColor.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: TFSpace.md)
                if let detail = option.detail {
                    // 상태가 이름을 줄이지 않는다
                    Text(detail)
                        .font(TFFont.footnote)
                        .tracking(-0.08)
                        .foregroundStyle(highlighted ? TFColor.textSecondarySelected : TFColor.textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                // 고른 것의 체크는 오른쪽 (DS ContextMenu: "a check on the right"). 칸은 모든 줄에 있어 상태 글이 줄마다 같은 자리에서 끝난다
                Group {
                    if isSelected { TFIcon.check.image(size: 14).foregroundStyle(TFColor.textPrimary) } else { Color.clear }
                }
                .frame(width: 14, height: 14)
            }
            .padding(EdgeInsets(top: 5, leading: TFSpace.sm, bottom: 5, trailing: TFSpace.sm))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(highlighted ? TFColor.bgSelected : Color.clear, in: RoundedRectangle(cornerRadius: ContextChip.radius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { model.highlighted = index } else if model.highlighted == index { model.highlighted = nil }
        }
        .accessibilityLabel(option.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview("Target picker") {
    VStack(alignment: .leading, spacing: 12) {
        TargetPill(name: "Taskforce", mark: .taskforce, isOpen: false) {}
        TargetMenuView(model: TargetMenuModel(
            options: AssistantTargetRules.options(from: [
                .taskforce,
                .agent(.init(adapter: "agent:claude-code", displayName: "Claude Code", connectionID: nil, state: .unsupported, access: nil)),
                .agent(.init(adapter: "agent:codex", displayName: "Codex", connectionID: UUID(), state: .ready, access: .readOnly)),
            ], canRunAgents: true),
            selected: 0, onPick: { _ in }
        ))
    }
    .padding(24)
    .background(TFColor.bgPanel)
}
