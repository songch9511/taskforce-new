import SwiftUI
import TaskforceKit
import TaskforceUI

@main
struct TaskforceApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    #else
    @UIApplicationDelegateAdaptor(IOSAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        #if os(iOS)
        WindowGroup {
            switch AppRuntime.startup {
            case .ready(let session, let services):
                RootView()
                    .environment(session)
                    .environment(\.services, services)
                    .task { session.start() }
            case .misconfigured(let message):
                ConfigErrorView(message: message)
            }
        }
        #else
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
            case .misconfigured(let message):
                ConfigErrorView(message: message)
                    .frame(width: 420, height: 240)
            }
        }
        #endif
    }
}

/// 앱 전체에서 하나만 두는 것들: 설정 · 로그인 상태 · 서비스. Mac은 SwiftUI 장면 밖(런처 패널)에서도 같은 것을 쓴다.
@MainActor
enum AppRuntime {
    static let startup = Startup.make()

    /// 이 기기의 저장본 위치: App Group 컨테이너 아래 계정 폴더 (`SavedNowStore`). 설정 · App Group이 없으면 nil (저장본 없이 둔다)
    static let savedNow: SavedNowStore? = (try? AppConfig.fromMainBundle())
        .flatMap { SavedNowStore.defaultRoot(appGroupID: $0.appGroupID) }
        .map(SavedNowStore.init(root:))

    private static var accountStore: AccountStore?

    /// 연결 · 동의 · 프로필 상태 (iPhone 시트와 Mac 설정 창이 같은 것을 본다)
    static func account(services: AppServices) -> AccountStore {
        if let accountStore { return accountStore }
        let session: SessionStore? = if case .ready(let session, _) = startup { session } else { nil }
        let store = AccountStore(services: services, session: session)
        accountStore = store
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
            let session = SessionStore(auth: supabase.auth)
            #if os(iOS)
            // iPhone: 계정이 떠나면 (로그아웃 · 만료 · 계정 삭제 · 전환) 이 기기의 저장본(할 일 제목 · 기한 · 상태)을 모두 지운다. 앱에 하나만 등록한다
            if let saved = AppRuntime.savedNow {
                session.onSignedOut { _ in try? saved.removeAll() }
            }
            #endif
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
