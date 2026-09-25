import SwiftUI
import TaskforceKit

@main
struct TaskforceApp: App {
    @State private var startup = Startup.make()

    var body: some Scene {
        WindowGroup {
            switch startup {
            case .ready(let session):
                RootView()
                    .environment(session)
                    .task { session.start() }
            case .misconfigured(let message):
                ConfigErrorView(message: message)
            }
        }
    }
}

/// 설정(Secrets.xcconfig)이 빠졌으면 앱을 죽이지 않고 무엇을 채워야 하는지 보여준다.
enum Startup {
    case ready(SessionStore)
    case misconfigured(String)

    @MainActor
    static func make() -> Startup {
        do {
            let config = try AppConfig.fromMainBundle()
            let supabase = TaskforceClient.makeSupabase(config: config)
            return .ready(SessionStore(auth: supabase.auth))
        } catch {
            return .misconfigured(String(describing: error))
        }
    }
}

struct ConfigErrorView: View {
    let message: String

    var body: some View {
        ContentUnavailableView("설정이 필요합니다", systemImage: "wrench.and.screwdriver", description: Text(message))
            .padding()
    }
}
