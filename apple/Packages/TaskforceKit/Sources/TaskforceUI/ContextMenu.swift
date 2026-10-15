import Observation
import SwiftUI
import TaskforceKit

/// 메뉴의 한 줄 (DS ContextMenu: `icon` · `label` · `detail` · `checked` · `submenu` · `separator`)
public struct ContextMenuItem: Identifiable {
    public let id: String
    public let icon: TFIcon?
    public let label: String
    /// 오른쪽 footnote 보조 글 (예: 세션의 링 말)
    public let detail: String?
    /// 오른쪽 체크 (지금 값)
    public let checked: Bool
    /// 오른쪽 chevron (하위 메뉴가 열린다)
    public let hasSubmenu: Bool
    public let isSeparator: Bool
    public let action: () -> Void

    public init(
        id: String, icon: TFIcon? = nil, label: String, detail: String? = nil, checked: Bool = false, hasSubmenu: Bool = false,
        action: @escaping () -> Void = {}
    ) {
        self.id = id
        self.icon = icon
        self.label = label
        self.detail = detail
        self.checked = checked
        self.hasSubmenu = hasSubmenu
        self.isSeparator = false
        self.action = action
    }

    /// 구분선 (1pt `border/default` + 안쪽 4/8). 파괴 동작은 맨 뒤 구분선 아래에 둔다
    public static func separator(id: String = UUID().uuidString) -> ContextMenuItem {
        ContextMenuItem(separatorID: id)
    }

    private init(separatorID: String) {
        id = separatorID
        icon = nil
        label = ""
        detail = nil
        checked = false
        hasSubmenu = false
        isSeparator = true
        action = {}
    }
}

/// 메뉴의 줄 이동 · 고름 (↑ ↓ Return). 구분선은 건너뛰고 처음과 끝에서 돌지 않는다. 호버도 같은 짚음(`highlighted`)을 쓴다
@MainActor
@Observable
public final class ContextMenuModel {
    public let items: [ContextMenuItem]
    /// 호버 · 키보드로 짚은 줄 (`items`의 번호)
    public var highlighted: Int?
    /// 하나를 고르면 부른다 (메뉴가 닫힌다)
    @ObservationIgnored public var onPick: () -> Void = {}

    public init(items: [ContextMenuItem]) {
        self.items = items
    }

    private var selectable: [Int] { items.indices.filter { !items[$0].isSeparator } }

    /// ↑ ↓: 짚은 줄이 없으면 ↓은 첫 줄, ↑은 마지막 줄에서 시작한다
    public func move(_ delta: Int) {
        let rows = selectable
        guard !rows.isEmpty else { return }
        guard let current = highlighted, let position = rows.firstIndex(of: current) else {
            highlighted = delta > 0 ? rows.first : rows.last
            return
        }
        highlighted = rows[min(max(position + delta, 0), rows.count - 1)]
    }

    /// Return: 짚은 줄을 고른다
    public func activate() {
        guard let highlighted, items.indices.contains(highlighted), !items[highlighted].isSeparator else { return }
        pick(highlighted)
    }

    public func pick(_ index: Int) {
        guard items.indices.contains(index), !items[index].isSeparator else { return }
        items[index].action()
        onPick()
    }
}

/// ContextMenu (0.2.0 디자인 시스템 Molecules, OA U2): 한 대상(프로젝트 · 이슈 · 프로젝트 고르기 · More 목록)의 떠 있는 메뉴.
/// `bg/elevated` · 모서리 12 · 안쪽 5 · 그림자는 창이 그린다 (`shadow-float`). 줄: 안쪽 5/8 · 모서리 6 · 간격 8 · callout. 폭은 최소 240에서 가장 긴 줄까지 (최대 460).
/// 호버 · 키보드 포커스는 `bg/selected` (키보드 포커스는 안쪽 1.5pt `border/accent`). 체크는 **오른쪽**, 하위 메뉴는 오른쪽 chevron, 구분선은 1pt `border/default` + 안쪽 4/8.
/// 메뉴는 포인터 곁이나 행 옆에서 열리고 눌린 행을 덮지 않는다 (자리는 `ContextMenuGeometry`)
public struct ContextMenuView: View {
    nonisolated public static let minWidth: CGFloat = 240
    nonisolated public static let maxWidth: CGFloat = 460
    nonisolated public static let inset: CGFloat = 5

    let model: ContextMenuModel
    let label: String
    /// 메뉴 전체 높이를 정해 두면(화면보다 긴 목록, 검토 반영 9) 줄은 그 안에서 스크롤되고 키보드로 짚은 줄을 따라간다. nil이면 줄 전부가 그대로 보인다
    let height: CGFloat?

    public init(model: ContextMenuModel, label: String, height: CGFloat? = nil) {
        self.model = model
        self.label = label
        self.height = height
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                if item.isSeparator {
                    Rectangle()
                        .fill(TFColor.borderDefault)
                        .frame(height: 1)
                        .padding(EdgeInsets(top: 4, leading: TFSpace.sm, bottom: 4, trailing: TFSpace.sm))
                        .accessibilityHidden(true)
                } else {
                    row(item, index: index)
                }
            }
        }
    }

    public var body: some View {
        Group {
            if let height {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) { rows }
                        .scrollIndicators(.automatic)
                        .frame(height: max(0, height - 2 * Self.inset))
                        // 키보드(↑ ↓)로 짚은 줄이 보이는 곳 밖이면 그 줄이 보이게만 움직인다
                        .onChange(of: model.highlighted) { _, index in
                            guard let index, model.items.indices.contains(index) else { return }
                            proxy.scrollTo(model.items[index].id)
                        }
                }
            } else {
                rows
            }
        }
        .padding(Self.inset)
        .frame(minWidth: Self.minWidth, maxWidth: Self.maxWidth)
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
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let detail = item.detail {
                    Text(detail)
                        .font(TFFont.footnote)
                        .tracking(-0.08)
                        .foregroundStyle(lit ? TFColor.textSecondarySelected : TFColor.textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                if item.hasSubmenu {
                    TFIcon.disclosureClosed.image().foregroundStyle(lit ? TFColor.textSecondarySelected : TFColor.textSecondary)
                } else if item.checked {
                    TFIcon.check.image().foregroundStyle(TFColor.textPrimary)
                }
            }
            .padding(EdgeInsets(top: 5, leading: TFSpace.sm, bottom: 5, trailing: TFSpace.sm))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(lit ? TFColor.bgSelected : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { model.highlighted = index } else if model.highlighted == index { model.highlighted = nil }
        }
        .accessibilityLabel(item.detail.map { "\(item.label), \($0)" } ?? item.label)
        .accessibilityAddTraits(item.checked ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview("ContextMenu") {
    HStack(alignment: .top, spacing: 24) {
        ContextMenuView(
            model: ContextMenuModel(items: [
                .init(id: "rename", icon: .rename, label: "Rename"), .init(id: "icon", icon: .changeIcon, label: "Change icon"), .separator(),
                .init(id: "archive", icon: .archive, label: "Archive"),
            ]),
            label: "Taskforce 0.2.0"
        )
        ContextMenuView(
            model: ContextMenuModel(items: [
                .init(id: "a", icon: .rocket, label: "Taskforce 0.2.0", checked: true), .init(id: "b", icon: .megaphone, label: "Shape launch"), .separator(),
                .init(id: "c", icon: .ungrouped, label: "Ungrouped"), .init(id: "d", label: "Session 7", detail: "Running", hasSubmenu: true),
            ]),
            label: "Move to project"
        )
    }
    .padding(24)
    .background(TFColor.bgPanel)
}
