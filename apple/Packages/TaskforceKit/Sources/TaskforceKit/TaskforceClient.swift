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

/// 앱이 화면에 넘겨주는 서비스 묶음: Supabase(로그인 · 읽기 · Realtime) + 서버 API(쓰기)
public struct AppServices: Sendable {
    public let supabase: SupabaseClient
    public let api: APIClient
    public let reads: TaskforceReads

    public init(config: AppConfig, supabase: SupabaseClient, session: URLSession = .shared) {
        self.supabase = supabase
        let auth = supabase.auth
        self.api = APIClient(baseURL: config.apiBaseURL, session: session) {
            // 만료가 가까우면 갱신된 토큰을 준다
            do {
                return try await auth.session.accessToken
            } catch let AuthError.api(_, _, _, response) where response.statusCode >= 500 || response.statusCode == 429 {
                // 인증 서버가 잠깐 탈이 난 것: 로그인이 풀린 게 아니다
                throw APIClient.error(status: response.statusCode, data: Data())
            }
        }
        self.reads = TaskforceReads(supabase: supabase)
    }

    /// 로그인한 사용자의 Action이 바뀔 때마다 (묶어서) 신호
    public func actionChanges(userID: UUID) -> AsyncStream<Void> {
        Debounce.signals(ActionChanges.signals(supabase: supabase, userID: userID), interval: .milliseconds(500))
    }
}
