#if os(iOS)
import SwiftUI
import TaskforceKit
import TaskforceUI

struct RootView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.services) private var services
    /// 앱을 연 뒤 지금 계정이 아닌 저장본을 한 번 정리했는지
    @State private var prunedSaved = false

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
                    SignedInRoot(services: services, session: session, userID: SampleData.userID, email: nil)
                } else {
                    SignInView()
                }
                #else
                SignInView()
                #endif
            case .signedIn(let userID, let email):
                if let services {
                    SignedInRoot(services: services, session: session, userID: userID, email: email)
                        // 계정이 바뀌면 화면 상태를 새로 만든다
                        .id(userID)
                }
            }
        }
        // 알림: 허용돼 있으면 로그인한 사용자로 기기 토큰을 보낸다 (로그아웃이면 멈춘다)
        // 로그아웃 · 세션 만료 · 계정 삭제 모두: 이 기기의 Google 로그인도 지운다 (다음 계정이 전 계정의 Google 토큰을 쓰지 않게)
        .onChange(of: session.state, initial: true) { _, state in
            switch state {
            case .signedIn(let userID, _):
                PushCenter.shared.follow(userID: userID, services: services)
                pruneSavedOnce(keeping: userID)
            case .signedOut:
                PushCenter.shared.follow(userID: nil, services: nil)
                GoogleSignInFlow.signOut()
                pruneSavedOnce(keeping: nil)
            case .loading: break
            }
        }
    }

    /// 앱을 연 뒤 로그인 상태를 처음 알게 되면 한 번: 지금 계정이 아닌 저장본을 지운다 (앱이 돌지 않는 동안 떠난 계정은 `onSignedOut`에 오지 않는다).
    /// 로그아웃 상태면 모두. 앱이 도는 동안 떠나는 계정은 `Startup.make`가 등록한 `onSignedOut`이 지운다
    private func pruneSavedOnce(keeping userID: UUID?) {
        guard !prunedSaved, let saved = AppRuntime.savedNow else { return }
        prunedSaved = true
        try? saved.prune(keeping: userID)
    }
}

/// 로그인한 동안: Realtime 구독 하나 + app_opened + 연결 콜백 + 연결 경로 + 저장본
private struct SignedInRoot: View {
    let services: AppServices
    let userID: UUID
    let email: String?

    @Environment(\.scenePhase) private var scenePhase
    @State private var changes = ActionChangeFeed()
    @State private var appOpen = AppOpenTracker()
    @State private var now: NowStore
    @State private var account: AccountStore

    init(services: AppServices, session: SessionStore, userID: UUID, email: String?) {
        self.services = services
        self.userID = userID
        self.email = email
        // 저장본(제목 · 기한 · 상태만): `/now`가 성공할 때마다 요청한 계정 폴더에 쓴다. 쓰는 순간 그 계정이 아직 로그인해 있을 때만 (`NowStore.writeSaved`):
        // 로그아웃 뒤 이 화면이 사라지기 전에 늦게 온 `/now`도 다시 쓰지 않는다
        let now = NowStore(services: services, session: session, saved: AppRuntime.savedNow)
        let account = AccountStore(services: services, session: session)
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
            // 이번 실행에서 `/now`를 받기 전(처음 불러오는 중 · 오프라인 · 새로고침 실패)에는 이 계정의 저장본을 보인다
            .onAppear { now.restoreSaved() }
            // 연결이 끊기면 오프라인 상태(P10), 돌아오면 다시 불러온다. 이 화면이 사라지면 감시도 끝난다
            .task {
                guard !isSample else { return }
                for await online in Connectivity.updates() {
                    if now.pathChanged(online: online) { Task { await now.load() } }
                }
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
            // 로그아웃 · 계정 전환으로 사라질 때: 이 계정의 저장소는 버려지지만, 그전에 보낸 요청의 늦은 결과(클립보드 · 연결 마치기 등)도 버린다
            .onDisappear {
                now.reset()
                account.reset()
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
