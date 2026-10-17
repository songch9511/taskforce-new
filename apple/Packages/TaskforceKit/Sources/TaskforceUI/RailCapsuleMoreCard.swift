import CoreGraphics
import SwiftUI
import TaskforceKit

/// More 카드의 자리 (OA U3 16.1, DS EdgeRail `.tf-edge .tf-menu { right: calc(100% + 10px); bottom: 0 }`). 좌표는 화면 좌표(아래가 0).
/// 카드는 셋째 캡슐의 **왼쪽 10pt**에 오른쪽 끝을 두고, 아래 끝은 그 캡슐의 아래 끝과 같다. 화면 밖으로 넘치면 안으로 민다
public enum RailMoreCardGeometry {
    /// 캡슐과 카드 사이
    public static let gap: CGFloat = 10

    public static func frame(size: CGSize, capsule: CGRect, visible: CGRect) -> CGRect {
        var x = capsule.minX - gap - size.width
        var y = capsule.minY
        x = max(visible.minX, min(x, visible.maxX - size.width))
        y = max(visible.minY, min(y, visible.maxY - size.height))
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

/// More 카드 (OA U3 16.1, DS EdgeRail "More open"): 레일 ⋯ 메뉴. 아이콘 + 이름 두 줄(Connections · Settings)뿐이다.
/// DS `.tf-menu`: 최소 폭 170 · 안쪽 4 · 모서리 12 · `bg/elevated` · 그림자는 창이 그린다. 줄: 안쪽 8/10 · 모서리 `radius-sm` · 간격 8 · 아이콘 `text/secondary`, 호버 · 키보드로 짚으면 `bg/selected`.
/// 줄 이동 · 고름은 `ContextMenuModel`(↑ ↓ Return)이 한다. 글은 기존 앱 문구 그대로다 (새 글 없음)
public struct RailMoreCard: View {
    nonisolated public static let minWidth: CGFloat = 170
    nonisolated public static let padding: CGFloat = 4
    /// 줄의 안쪽 위아래 · 좌우
    nonisolated public static let rowInset = EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)

    let model: ContextMenuModel
    let label: String

    public init(model: ContextMenuModel, label: String) {
        self.model = model
        self.label = label
    }

    public var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                if !item.isSeparator { row(item, index: index) }
            }
        }
        .padding(Self.padding)
        .frame(minWidth: Self.minWidth)
        .fixedSize(horizontal: true, vertical: true)
        .background(TFColor.bgElevated, in: RoundedRectangle(cornerRadius: TFRadius.panel, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private func row(_ item: ContextMenuItem, index: Int) -> some View {
        let lit = model.highlighted == index
        return Button { model.pick(index) } label: {
            HStack(spacing: TFSpace.sm) {
                if let icon = item.icon {
                    icon.image().foregroundStyle(TFColor.textSecondary)
                }
                Text(item.label)
                    .font(TFFont.callout)
                    .tracking(-0.24)
                    .foregroundStyle(TFColor.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Self.rowInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(lit ? TFColor.bgSelected : Color.clear, in: RoundedRectangle(cornerRadius: TFRadius.sm, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { model.highlighted = index } else if model.highlighted == index { model.highlighted = nil }
        }
        .accessibilityLabel(item.label)
        .accessibilityAddTraits(.isButton)
    }
}

#Preview("RailMoreCard") {
    RailMoreCard(
        model: ContextMenuModel(items: [.init(id: "connections", icon: .connections, label: "Connections"), .init(id: "settings", icon: .settings, label: "Settings")]),
        label: "More"
    )
    .padding(24)
    .background(TFColor.bgPanel)
}
