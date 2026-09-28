#if os(iOS)
import SwiftUI
import TaskforceKit
import TaskforceUI

struct RootView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.services) private var services

    var body: some View {
        Group {
            switch session.state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(TFColor.bgCanvas)
            case .signedOut:
                SignInView()
            case .signedIn(let userID, let email):
                if let services {
                    SignedInRoot(services: services, userID: userID, email: email)
                        // 계정이 바뀌면 화면 상태를 새로 만든다
                        .id(userID)
                }
            }
        }
    }
}

/// 로그인한 동안: Realtime 구독 하나 + app_opened + 연결 콜백
private struct SignedInRoot: View {
    let services: AppServices
    let userID: UUID
    let email: String?

    @Environment(\.scenePhase) private var scenePhase
    @State private var changes = ActionChangeFeed()
    @State private var appOpen = AppOpenTracker()
    @State private var now: NowStore
    @State private var account: AccountStore

    init(services: AppServices, userID: UUID, email: String?) {
        self.services = services
        self.userID = userID
        self.email = email
        let now = NowStore(services: services)
        #if DEBUG
        if SampleData.isEnabled { now.useSampleData() }
        #endif
        _now = State(initialValue: now)
        _account = State(initialValue: AccountStore(services: services))
    }

    var body: some View {
        HomeView(userID: userID, email: email)
            .environment(now)
            .environment(changes)
            .environment(account)
            // 로그인해 있는 동안 Realtime 구독 하나. 로그아웃 · 계정 전환으로 이 화면이 사라지면 끝난다.
            .task { await changes.follow(services: services, userID: userID) }
            // 지표 2 · 3: 로그인한 화면이 처음 나타날 때와 백그라운드에서 돌아올 때 한 번
            .onChange(of: scenePhase, initial: true) { _, phase in
                guard appOpen.update(AppOpenTracker.Phase(phase)) else { return }
                Task { try? await services.api.appOpened() }
            }
            // ASWebAuthenticationSession이 주소를 바로 돌려주지만, 앱 밖에서 열린 경우를 위해
            .onOpenURL { url in
                Task { await account.handleCallback(url) }
            }
    }
}
#endif
