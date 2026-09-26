import Foundation
import Supabase

public enum TaskforceClient {
    /// 앱 · 공유 확장이 같은 설정으로 만드는 Supabase 클라이언트. 세션은 App Group Keychain에 저장된다.
    public static func makeSupabase(config: AppConfig) -> SupabaseClient {
        SupabaseClient(
            supabaseURL: config.supabaseURL,
            supabaseKey: config.supabaseKey,
            options: SupabaseClientOptions(
                auth: .init(
                    storage: SharedKeychainStorage(accessGroup: config.appGroupID),
                    emitLocalSessionAsInitialSession: true
                )
            )
        )
    }
}
