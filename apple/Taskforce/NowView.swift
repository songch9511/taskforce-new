import SwiftUI
import TaskforceKit

/// '지금 할 일' 화면. Phase A1에서 Supabase의 Action 목록을 붙인다.
struct NowView: View {
    @Environment(SessionStore.self) private var session
    let email: String?

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "아직 할 일이 없습니다",
                systemImage: "checkmark.circle",
                description: Text("회의록이나 메시지를 보내면 여기에 할 일이 나타납니다.")
            )
            .navigationTitle("지금 할 일")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if let email {
                            Text(email)
                        }
                        Button("로그아웃", role: .destructive) {
                            Task { await session.signOut() }
                        }
                    } label: {
                        Label("계정", systemImage: "person.crop.circle")
                    }
                }
            }
        }
    }
}
