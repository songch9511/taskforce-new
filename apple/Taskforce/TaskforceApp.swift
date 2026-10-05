import SwiftUI
import TaskforceKit
import TaskforceUI

@main
struct TaskforceApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate

    var body: some Scene {
        // 에이전트 앱: Dock · 창 없이 메뉴 막대 아이콘 + ⌥Space 런처 (MacAppDelegate)
        MenuBarExtra {
            MenuBarMenu()
        } label: {
            MenuBarLabel()
        }
        Settings {
            switch AppRuntime.startup {
            case .ready(let session, let services):
                MacSettingsView()
                    .environment(session)
                    .environment(\.services, services)
                    .environment(AppRuntime.account(services: services))
                    .environment(AppRuntime.runs(services: services))
            case .misconfigured(let message):
                ConfigErrorView(message: message)
                    .frame(width: 420, height: 240)
            }
        }
    }
}

/// 앱 전체에서 하나만 두는 것들: 설정 · 로그인 상태 · 서비스. Mac은 SwiftUI 장면 밖(런처 패널)에서도 같은 것을 쓴다.
@MainActor
enum AppRuntime {
    static let startup = Startup.make()

    /// Mac 런처 목록의 계정별 저장본. 로그아웃과 계정 삭제 때 지운다.
    static let savedNow: SavedNowStore? = (try? AppConfig.fromMainBundle())
        .flatMap { SavedNowStore.defaultRoot(appGroupID: $0.appGroupID) }
        .map(SavedNowStore.init(root:))

    private static var accountStore: AccountStore?

    /// 연결 · 동의 · 프로필 상태 (런처와 Mac 설정 창이 같은 것을 본다)
    static func account(services: AppServices) -> AccountStore {
        if let accountStore { return accountStore }
        let session: SessionStore? = if case .ready(let session, _) = startup { session } else { nil }
        let store = AccountStore(services: services, session: session)
        accountStore = store
        return store
    }

    private static var runStore: RunStore?

    /// 실행(U2) 상태: credits · run · 초안 (Mac 설정 Usage & Credits와 런처가 같은 것을 본다). 계정이 떠나면 스스로 비운다 (`RunStore.reset`).
    /// 견본(`-TFSampleData`)이면 서버를 부르지 않고 `SampleRuns` 인자대로 채운다
    static func runs(services: AppServices) -> RunStore {
        if let runStore { return runStore }
        let session: SessionStore? = if case .ready(let session, _) = startup { session } else { nil }
        let store = RunStore(services: services, session: session)
        #if DEBUG
        if SampleData.isEnabled { store.useSampleData() }
        #endif
        runStore = store
        return store
    }
}

/// 설정(Secrets.xcconfig)이 빠졌으면 앱을 죽이지 않고 무엇을 채워야 하는지 보여준다.
enum Startup {
    case ready(SessionStore, AppServices)
    case misconfigured(String)

    @MainActor
    static func make() -> Startup {
        do {
            let config = try AppConfig.fromMainBundle()
            // 클라이언트 하나를 로그인 · 읽기 · Realtime이 함께 쓴다 (세션 · 토큰 갱신을 공유)
            let supabase = TaskforceClient.makeSupabase(config: config)
            // 요청은 디스크 캐시 없는 세션으로 (`TaskforceClient.urlSession`). 예전 빌드가 공유 캐시에 남긴 응답 사본은 시작할 때 지운다
            URLCache.shared.removeAllCachedResponses()
            // 계정별로 이 기기에 남기는 데이터(목록 · 저장본)는 계정이 떠날 때 `SessionStore.onSignedOut`에서 지운다 (Mac 런처: `LauncherModel`)
            let session = SessionStore(auth: supabase.auth, googleOnly: true)
            return .ready(session, AppServices(config: config, supabase: supabase, session: TaskforceClient.urlSession))
        } catch {
            return .misconfigured(String(describing: error))
        }
    }
}

struct ConfigErrorView: View {
    let message: String

    var body: some View {
        ContentUnavailableView("Setup needed", systemImage: "wrench.and.screwdriver", description: Text(message))
            .padding()
    }
}
