#if os(macOS)
import SwiftUI
import TaskforceKit
import TaskforceUI

/// 상세의 Taskforce 갈래 (Figma M1 Lane · Taskforce 181:1642 · M12 · M17): 할 일의 최신 run이 있거나 초안이 있을 때만 보인다.
/// 초안이 있으면 상태와 상관없이 `View Draft` (멈춤 · 실패 · needs_*에도 앞서 만든 초안이 있을 수 있다, A39). Tab · →로 버튼에 옮겨 ↩로 연다.
struct LauncherLaneView: View {
    @Bindable var model: LauncherModel
    let target: LauncherModel.Target

    var body: some View {
        if let lane = model.lane(for: target.action.id), let card = RunLaneText.make(lane) {
            LaneCard(
                heading: "Taskforce", title: card.title, subtitle: card.subtitle, spokenState: card.spokenState,
                action: card.draft.map { draft in
                    LaneCard.Action("View Draft", isFocused: model.laneFocusTarget?.action.id == target.action.id) {
                        model.openDraft(draft, for: target)
                    }
                }
            )
            // 보고 있는 할 일의 상태가 바뀌면 VoiceOver가 알린다 (Draft ready · Stop requested). 다른 할 일로 옮긴 것은 알리지 않는다
            .onChange(of: Announcement(id: target.action.id, text: RunLaneText.announcement(lane.state))) { old, new in
                guard old.id == new.id, let text = new.text, old.text != text else { return }
                AccessibilityNotification.Announcement(text).post()
            }
        }
    }

    private struct Announcement: Equatable {
        let id: UUID
        let text: String?
    }
}
#endif
