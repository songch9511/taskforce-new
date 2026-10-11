#if os(macOS)
import SwiftUI
import TaskforceKit
import TaskforceUI

/// 고른 All work 줄 아래의 ProjectLink 줄들 (S3b). 일 상세가 아직 없어 디자인의 "일 머리"를 줄 수준으로 둔다 (S4가 상세를 만들면 거기 머리로 옮긴다).
/// 확인된 멤버십마다 한 줄(한 할 일이 여러 프로젝트면 여럿), 없으면 "No clear link" 한 줄, 확인되지 않은 후보는 따로. 멤버십을 아직 읽지 못했으면 아무것도 그리지 않는다.
/// 바꾸기 · 빼기 · 넣기 · Undo는 서버 200 뒤에만 바뀌고, 충돌 · 응답 유실은 다시 읽은 상태와 한 줄 안내로 보인다 (`WorkContextStore`)
struct WorkRowProjectLinks: View {
    let actionID: UUID
    let store: WorkContextStore
    #if DEBUG
    /// 사진용: 열어 둔 채로 보일 줄을 고른다 (`EdgeSnapshot`). 기본(nil)은 모두 닫힘
    nonisolated(unsafe) static var opensForSnapshot: ((ProjectLinkContent) -> Bool)?
    #endif

    var body: some View {
        if let links = store.projectLinks(for: actionID) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(links) { link in
                    ProjectLink(
                        content: link,
                        onChange: { choice in send(ProjectChange.choosing(choice, in: link)) },
                        onUndo: { Task { await store.undoLast(actionID) } },
                        onConfirm: { send(ProjectChange.confirming(link)) },
                        onDismiss: { send(ProjectChange.dismissing(link)) },
                        initiallyOpen: initiallyOpen(link)
                    )
                }
            }
        }
    }

    private func initiallyOpen(_ link: ProjectLinkContent) -> Bool {
        #if DEBUG
        Self.opensForSnapshot?(link) ?? false
        #else
        false
        #endif
    }

    private func send(_ change: ProjectChange?) {
        guard let change else { return }
        Task { await store.perform(change, for: actionID) }
    }
}
#endif
