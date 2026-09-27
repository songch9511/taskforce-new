import SwiftUI
import TaskforceKit

struct RootView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.services) private var services

    var body: some View {
        Group {
            switch session.state {
            case .loading:
                ProgressView()
            case .signedOut:
                SignInView()
            case .signedIn(let userID, let email):
                if let services {
                    MainTabs(services: services, userID: userID, email: email)
                        // 계정이 바뀌면 화면 상태를 새로 만든다
                        .id(userID)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }
}

/// 지금 · 원문 두 탭. 아이패드 · Mac에서는 사이드바가 된다.
struct MainTabs: View {
    let services: AppServices
    let userID: UUID
    let email: String?

    @Environment(\.scenePhase) private var scenePhase
    @State private var changes = ActionChangeFeed()
    @State private var appOpen = AppOpenTracker()

    var body: some View {
        TabView {
            Tab("지금", systemImage: "checklist") {
                NowView(services: services, email: email)
            }
            Tab("원문", systemImage: "doc.text") {
                SourcesView(services: services)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .environment(changes)
        // 로그인해 있는 동안 Realtime 구독 하나. 로그아웃 · 계정 전환으로 이 화면이 사라지면 끝난다.
        .task { await changes.follow(services: services, userID: userID) }
        // 지표 2 · 3: 로그인한 화면이 처음 나타날 때와 백그라운드에서 돌아올 때 한 번
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard appOpen.update(AppOpenTracker.Phase(phase)) else { return }
            Task { try? await services.api.appOpened() }
        }
    }
}

/// 로그인해 있는 동안 하나만 두는 `actions` Realtime 구독. 화면은 `revision`이 바뀌면 다시 불러온다.
/// 화면마다 구독하면 탭을 옮기거나 들어갔다 나올 때마다 채널을 만들고 지우게 되어 신호를 놓치기 쉽다.
@MainActor
@Observable
final class ActionChangeFeed {
    /// Realtime 신호가 (묶여서) 올 때마다 1씩 오른다
    private(set) var revision = 0

    func follow(services: AppServices, userID: UUID) async {
        while !Task.isCancelled {
            for await _ in services.actionChanges(userID: userID) {
                revision += 1
            }
            // 구독이 안 되거나 끊겼으면 잠시 뒤 다시 붙는다 (그동안은 새로고침 · 화면 복귀 때 불러온다)
            try? await Task.sleep(for: .seconds(15))
        }
    }
}

extension AppOpenTracker.Phase {
    init(_ phase: ScenePhase) {
        switch phase {
        case .active: self = .active
        case .background: self = .background
        default: self = .inactive
        }
    }
}
