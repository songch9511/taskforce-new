import SwiftUI
import TaskforceKit
import TaskforceUI

@main
struct TaskforceApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
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

    private static var accountStore: AccountStore?

    /// 연결 · 동의 · 프로필 상태 (iPhone 시트와 Mac 설정 창이 같은 것을 본다)
    static func account(services: AppServices) -> AccountStore {
        if let accountStore { return accountStore }
        let store = AccountStore(services: services)
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
            return .ready(SessionStore(auth: supabase.auth), AppServices(config: config, supabase: supabase))
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
