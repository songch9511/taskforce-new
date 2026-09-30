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
                #if DEBUG
                // 견본 모드는 로그인 없이 견본 화면을 보여 준다 (시뮬레이터에 Apple ID가 없어도 화면을 확인할 수 있게)
                if SampleData.isEnabled, let services {
                    SignedInRoot(services: services, userID: SampleData.userID, email: nil)
                } else {
                    SignInView()
                }
                #else
                SignInView()
                #endif
            case .signedIn(let userID, let email):
                if let services {
                    SignedInRoot(services: services, userID: userID, email: email)
                        // 계정이 바뀌면 화면 상태를 새로 만든다
                        .id(userID)
                }
            }
        }
        // 알림: 허용돼 있으면 로그인한 사용자로 기기 토큰을 보낸다 (로그아웃이면 멈춘다)
        .onChange(of: session.state, initial: true) { _, state in
            switch state {
            case .signedIn(let userID, _): PushCenter.shared.follow(userID: userID, services: services)
            case .signedOut: PushCenter.shared.follow(userID: nil, services: nil)
            case .loading: break
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
        let account = AccountStore(services: services)
        #if DEBUG
        if SampleData.isEnabled {
            now.useSampleData()
            account.useSampleData(connections: SampleData.connections, policyNotice: SampleData.policyNotice)
        }
        #endif
        _now = State(initialValue: now)
        _account = State(initialValue: account)
    }

    var body: some View {
        HomeView(userID: userID, email: email)
            .environment(now)
            .environment(changes)
            .environment(account)
            // 로그인해 있는 동안 Realtime 구독 하나. 로그아웃 · 계정 전환으로 이 화면이 사라지면 끝난다.
            .task {
                guard !isSample else { return }
                await changes.follow(services: services, userID: userID)
            }
            // 지표 2 · 3: 로그인한 화면이 처음 나타날 때와 백그라운드에서 돌아올 때 한 번
            .onChange(of: scenePhase, initial: true) { _, phase in
                guard !isSample, appOpen.update(AppOpenTracker.Phase(phase)) else { return }
                Task { try? await services.api.appOpened() }
            }
            // ASWebAuthenticationSession이 주소를 바로 돌려주지만, 앱 밖에서 열린 경우를 위해
            .onOpenURL { url in
                Task { await account.handleCallback(url) }
            }
    }

    /// 견본 모드에서는 서버를 부르지 않는다 (Realtime · app_opened)
    private var isSample: Bool {
        #if DEBUG
        SampleData.isEnabled
        #else
        false
        #endif
    }
}
#endif
