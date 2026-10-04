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
        if let crumb = model.crumb {
            crumbBar(task: crumb.task, screen: crumb.screen)
        } else {
            searchField
        }
    }

    private var searchField: some View {
        let placeholder = model.showsSavedTasks ? "Search saved tasks" : "Search tasks"
        return HStack(spacing: TFSpace.md) {
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

    /// 하위 화면 머리 (Figma M8 `Search field`): `‹` + `<할 일>  ›  Run with AI`(할 일 제목만 한 줄로 자름) + `Back esc`.
    /// 유리 위 글자라 text/primary (Figma는 text/secondary: 액션 바와 같은 이유로 4.5:1을 위해 바꿈, `GlassContrastTests`)
    private func crumbBar(task: String?, screen: String) -> some View {
        HStack(spacing: TFSpace.md) {
            Button { model.back() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TFColor.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // VoiceOver는 오른쪽 `Back esc` 하나로 (같은 이름이 둘이 되지 않게)
            .accessibilityHidden(true)
            HStack(spacing: 0) {
                if let task {
                    Text(task)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("  ›  ")
                        .fixedSize()
                        .accessibilityHidden(true)
                }
                Text(screen)
                    .lineLimit(1)
                    .fixedSize()
            }
            .font(TFFont.callout)
            .foregroundStyle(TFColor.textPrimary)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: TFSpace.md)
            Button { model.back() } label: {
                HStack(spacing: 6) {
                    Text("Back")
                        .font(TFFont.footnote)
                        .foregroundStyle(TFColor.textPrimary)
                    KeyHint("esc")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Back")
            .accessibilityHint(KeyHint.spokenName(KeyHint.keys("esc")))
        }
        .padding(.horizontal, 18)
        .frame(height: 62)
    }
}

/// 범위 메뉴 (Figma M13 `Scope menu`, 폭 250): 범위마다 개수, 지금 범위에 체크. ⌘P · `All Tasks ⌄`로 열고 ↑↓ ↩ · esc.
/// All Tasks | 네 구역 | Taskforce Working(실행을 쓸 수 있을 때) · Changed Since Last Look 사이에 구분선. `Waiting on Someone`은 U5가 더한다.
struct LauncherScopeMenu: View {
    @Bindable var model: LauncherModel

    var body: some View {
        let choices = model.scopeChoices
        VStack(spacing: 0) {
            ForEach(Array(choices.enumerated()), id: \.element) { index, scope in
                if index > 0, Self.startsGroup(scope, after: choices[index - 1]) {
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
        .overlay(RoundedRectangle(cornerRadius: TFRadius.panel, style: .continuous).strokeBorder(TFColor.borderDefault, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Scope, \(model.scope.title)")
    }

    /// 구분선 아래의 첫 범위: 네 구역의 처음, 마지막 묶음의 처음
    private static func startsGroup(_ scope: TaskScope, after previous: TaskScope) -> Bool {
        scope == .review || (lastGroup.contains(scope) && !lastGroup.contains(previous))
    }

    /// M13 마지막 묶음: (Waiting on Someone, U5) · Taskforce Working · Changed Since Last Look
    private static let lastGroup: Set<TaskScope> = [.taskforceWorking, .changed]

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
