import Foundation
import Supabase

public enum TaskforceClient {
    /// 앱의 Supabase · 서버 API 요청이 쓰는 URLSession. 응답(할 일 · 원문)을 디스크 캐시(`URLCache`)에 남기지 않는다:
    /// 기기에 남는 계정 데이터는 저장본(제목 · 기한 · 상태)뿐이고, 로그아웃 뒤 전 계정 응답 사본이 남지 않게
    public static let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    /// 앱이 만드는 Supabase 클라이언트. 세션은 App Group Keychain에 저장해, 공유 확장 · 위젯을 붙이면 같은 설정으로 같은 세션을 읽는다 (아직 없음).
    public static func makeSupabase(config: AppConfig) -> SupabaseClient {
        SupabaseClient(
            supabaseURL: config.supabaseURL,
            supabaseKey: config.supabaseKey,
            options: SupabaseClientOptions(
                auth: .init(
                    storage: SharedKeychainStorage(accessGroup: config.appGroupID),
                    emitLocalSessionAsInitialSession: true
                ),
                global: .init(session: urlSession)
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
        self.api = APIClient(
            baseURL: config.apiBaseURL, session: session,
            token: {
                // 만료가 가까우면 갱신된 토큰을 준다
                do {
                    return try await auth.session.accessToken
                } catch let AuthError.api(_, _, _, response) where response.statusCode >= 500 || response.statusCode == 429 {
                    // 인증 서버가 잠깐 탈이 난 것: 로그인이 풀린 게 아니다
                    throw APIClient.error(status: response.statusCode, data: Data())
                }
            },
            // 401이면 인증 서버에 세션을 다시 묻고, 계정 · 세션이 없으면 이 기기만 로그아웃 (`SessionStore.onSignedOut`이 정리)
            onUnauthorized: { await auth.endSessionIfGone() }
        )
        self.reads = TaskforceReads(supabase: supabase)
    }

    /// 로그인한 사용자의 Action이 바뀔 때마다 (묶어서) 신호
    public func actionChanges(userID: UUID) -> AsyncStream<Void> {
        Debounce.signals(ActionChanges.signals(supabase: supabase, userID: userID), interval: .milliseconds(500))
    }
}
