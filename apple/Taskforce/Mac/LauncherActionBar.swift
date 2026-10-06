#if os(macOS)
import SwiftUI
import TaskforceKit
import TaskforceUI

/// 액션 바 (Figma M1 · M8 · M17 · M19 · M20 Footer, 높이 44): 왼쪽 앱 기호 + 화면 이름(`Tasks` · `Run with AI` · `Draft`) 또는 상태(`Offline since 8:01.` ·
/// `Couldn’t refresh at 10:46. Showing 10:31.` · `Stop requested 14:20`), 오른쪽 설명(`Manual, uses credits`) · 보조 동작(`Try Again ⌘R` · `Undo ⌘Z` ·
/// `Dismiss ⌘⌫`) → Return 동작(`Open in Notion ↩` · `Show details ↩` · `Confirm ⌘↩` · `Start ⌘↩` · `View Draft ↩` · `Copy ⌘C`) → `Actions ⌘K`.
/// 그 밖의 화면은 `Back esc`.
struct LauncherActionBar: View {
    @Bindable var model: LauncherModel

    var body: some View {
        ActionBar(
            leading: leading,
            note: note,
            secondary: model.secondaryAction.map { action in ActionBarItem(action.title, keys: action.keys) { model.performSecondary() } },
            primary: model.primaryAction.map { action in
                ActionBarItem(action.title, keys: action.keys, isEnabled: isPrimaryEnabled) { model.performPrimary() }
            },
            actions: trailing
        )
    }

    private var leading: ActionBar.Leading {
        if let text = model.statusText {
            if model.refreshState.isOffline {
                return .status(systemImage: "wifi.slash", text: text)
            }
            return .status(systemImage: "exclamationmark.triangle", text: text, alert: true)
        }
        if let stop = stopRequested {
            return .status(systemImage: "stop.circle", text: stop)
        }
        return .app(model.crumb?.screen ?? "Tasks")
    }

    /// M17: 상세에 보이는 할 일의 run을 멈췄으면 `Stop requested 14:20` (시각은 서버 값)
    private var stopRequested: String? {
        guard model.screen == .list || model.screen.isDetail, let id = model.detailTarget?.action.id, let lane = model.lane(for: id) else { return nil }
        return RunLaneText.stopRequested(lane)
    }

    /// M8: 모드 · 비용 한 줄 (Mode `Change`는 U6b라 늘 Manual)
    private var note: String? {
        if let feedback = model.feedbackMessage { return feedback }
        if case .runWithAI = model.screen { return "Manual, uses credits" }
        return nil
    }

    /// M8 Start는 Goal이 있고 보내는 중이 아닐 때만
    private var isPrimaryEnabled: Bool {
        if case .runWithAI = model.screen { model.canStartRun } else { true }
    }

    private var trailing: ActionBarItem? {
        switch model.screen {
        case .list, .detail, .runWithAI, .handoff, .draft(.some, _):
            // 할 일 행이 아니면 명령 패널 (로그아웃이면 할 일이 없어 숨긴다)
            guard model.canOpenActions else { return nil }
            return ActionBarItem("Actions", keys: "⌘K") { model.openActions() }
        case .draft(nil, _):
            // 목록에 없는 할 일의 초안: 동작이 없다 (`Back esc`는 머리에)
            return nil
        default:
            // 직접 추가 · 신고를 보내는 중에는 esc가 할 일이 없다
            guard !model.isSubmitting else { return nil }
            return ActionBarItem("Back", keys: "esc") { model.back() }
        }
    }
}
#endif
