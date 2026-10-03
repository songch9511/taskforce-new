#if os(macOS)
import SwiftUI
import TaskforceKit
import TaskforceUI

/// 검색줄 (Figma M1 `Search field`, 높이 62 · 좌우 18): 돋보기 없는 22pt 입력창 + 오른쪽 범위 `All Tasks ⌄`.
/// 자리표시는 `Search tasks`, 저장본을 보이는 중이면 `Search saved tasks` (M15 · M19). 붙여 넣은 글은 세 줄까지 늘어난다.
struct LauncherSearchBar: View {
    @Bindable var model: LauncherModel
    var focused: FocusState<Bool>.Binding
    let locked: Bool

    var body: some View {
        let placeholder = model.showsSavedTasks ? "Search saved tasks" : "Search tasks"
        HStack(spacing: TFSpace.md) {
            TextField(text: $model.text, prompt: Text(placeholder).foregroundStyle(TFColor.textSecondary), axis: .vertical) {
                Text(placeholder)
            }
            .textFieldStyle(.plain)
            .font(TFFont.search)
            .foregroundStyle(TFColor.textPrimary)
            .lineLimit(1...3)
            .focused(focused)
            .disabled(locked)
            if model.isSignedIn, model.configurationError == nil {
                DropdownButton(model.scope.title, size: .compact, accessibilityName: "Scope") {
                    model.toggleScopeMenu()
                }
                .disabled(!model.canChooseScope)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 17)
        .frame(minHeight: 62)
    }
}

/// 범위 메뉴 (Figma M13 `Scope menu`, 폭 250): 범위마다 개수, 지금 범위에 체크. ⌘P · `All Tasks ⌄`로 열고 ↑↓ ↩ · esc.
/// All Tasks | 네 구역 | Changed Since Last Look 사이에 구분선. `Waiting on Someone` · `Taskforce Working`은 그 단위(U5 · U2 Mac)가 더한다.
struct LauncherScopeMenu: View {
    @Bindable var model: LauncherModel

    var body: some View {
        let choices = model.scopeChoices
        VStack(spacing: 0) {
            ForEach(Array(choices.enumerated()), id: \.element) { index, scope in
                if index > 0, Self.startsGroup(scope) {
                    TFColor.borderDefault
                        .frame(height: 1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
                        .accessibilityHidden(true)
                }
                row(scope, index: index)
            }
        }
        .padding(6)
        .frame(width: 250)
        // 뒤 내용은 흐리게 (Figma backdrop blur), 그 위에 bg/menu
        .background(TFColor.bgMenu, in: RoundedRectangle(cornerRadius: TFRadius.panel, style: .continuous))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: TFRadius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: TFRadius.panel, style: .continuous).strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Scope, \(model.scope.title)")
    }

    /// 구분선 위의 첫 범위
    private static func startsGroup(_ scope: TaskScope) -> Bool {
        scope == .review || scope == .changed
    }

    private func row(_ scope: TaskScope, index: Int) -> some View {
        let selected = index == model.scopeMenuSelection
        let count = model.count(for: scope)
        return Button {
            model.chooseScope(scope)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TFColor.textPrimary)
                    .frame(width: 16, height: 16)
                    .opacity(scope == model.scope ? 1 : 0)
                Text(scope.title)
                    .font(TFFont.footnote)
                    .foregroundStyle(TFColor.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(count)")
                    .font(TFFont.meta)
                    .foregroundStyle(selected ? TFColor.textSecondarySelected : TFColor.textSecondary)
            }
            .padding(.leading, 10)
            .padding(.trailing, TFSpace.sm)
            .frame(height: 32)
            .background(selected ? TFColor.bgSelected : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { model.selectScopeMenuRow(index) } }
        .accessibilityLabel("\(scope.title), \(count)")
        .accessibilityAddTraits(scope == model.scope ? .isSelected : [])
    }
}
#endif
