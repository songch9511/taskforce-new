#if os(macOS)
import SwiftUI
import TaskforceKit
import TaskforceUI

/// 액션 바 (Figma M1 · M19 · M20 Footer, 높이 44): 왼쪽 앱 기호 + `Tasks` 또는 상태(`Offline since 8:01.` ·
/// `Couldn’t refresh at 10:46. Showing 10:31.`), 오른쪽 보조 동작(`Try Again ⌘R` · `Undo ⌘Z` · `Dismiss ⌘⌫`) →
/// Return 동작(`Open in Notion ↩` · `Show Review ↩` · `Confirm ⌘↩`) → `Actions ⌘K`. 그 밖의 화면은 `Back esc`.
struct LauncherActionBar: View {
    @Bindable var model: LauncherModel

    var body: some View {
        ActionBar(
            leading: leading,
            secondary: model.secondaryAction.map { action in ActionBarItem(action.title, keys: action.keys) { model.performSecondary() } },
            primary: model.primaryAction.map { action in ActionBarItem(action.title, keys: action.keys) { model.performPrimary() } },
            actions: trailing
        )
    }

    private var leading: ActionBar.Leading {
        guard let text = model.statusText else { return .app("Tasks") }
        if model.refreshState.isOffline {
            return .status(systemImage: "wifi.slash", text: text)
        }
        return .status(systemImage: "exclamationmark.triangle", text: text, alert: true)
    }

    private var trailing: ActionBarItem? {
        switch model.screen {
        case .list, .detail:
            // 할 일 행이 아니면 명령 패널 (로그아웃이면 할 일이 없어 숨긴다)
            guard model.canOpenActions else { return nil }
            return ActionBarItem("Actions", keys: "⌘K") { model.openActions() }
        default:
            // 직접 추가 · 신고를 보내는 중에는 esc가 할 일이 없다
            guard !model.isSubmitting else { return nil }
            return ActionBarItem("Back", keys: "esc") { model.back() }
        }
    }
}
#endif
