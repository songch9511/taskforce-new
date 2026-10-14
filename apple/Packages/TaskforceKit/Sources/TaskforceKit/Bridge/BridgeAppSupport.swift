#if os(macOS)
import Auth
import Foundation
import OSLog
import Supabase

/// 앱이 bridge 런타임에 넘기는 로그인 연결 (OA D2b 계약 2.11 · 2.13). `SessionStore`의 판단(`endSessionIfGone`)을 그대로 쓴다.
public enum BridgeAppSupport {
    /// 사용자 토큰과 그 토큰의 사용자를 **같은 세션에서 함께** 읽는다 (토큰 공급과 계정 전환 사이의 경쟁을 요청 직전에 `BridgeClient`가 다시 대조한다).
    /// 만료가 가까우면 갱신된 토큰을 준다. 인증 서버가 잠깐 탈이 난 것은 로그인이 풀린 것이 아니다 (`AppServices`와 같은 처리)
    public static func bearer(_ supabase: SupabaseClient) -> BridgeClient.BearerProvider {
        let auth = supabase.auth
        return {
            do {
                let session = try await auth.session
                return BridgeBearer(userID: session.user.id, accessToken: session.accessToken)
            } catch let AuthError.api(_, _, _, response) where response.statusCode >= 500 || response.statusCode == 429 {
                throw APIClient.error(status: response.statusCode, data: Data())
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError {
                throw APIError.transport(error.localizedDescription)
            } catch {
                throw APIError.notSignedIn
            }
        }
    }

    /// 401을 받았을 때: 이 기기의 세션이 아직 살아 있나. 끝났으면(`SessionStore.onSignedOut`이 정리하는 로그아웃) false
    public static func sessionStillValid(_ supabase: SupabaseClient) -> @Sendable () async -> Bool {
        let auth = supabase.auth
        return { !(await auth.endSessionIfGone()) }
    }
}

/// OSLog 싱크 (`category: bridge`). 값 종류가 글 없는 것으로 좁혀져 있어 메시지 · 질문 · 답 · 비밀 · 경로가 들어갈 자리가 없다 (계약 2.15)
public struct BridgeOSLog: BridgeLogSink {
    private let logger: Logger

    public init(subsystem: String = Bundle.main.bundleIdentifier ?? "dev.taskforcelabs.taskforce") {
        logger = Logger(subsystem: subsystem, category: "bridge")
    }

    public func log(_ event: String, _ fields: [String: BridgeLogValue]) {
        let text = fields.sorted { $0.key < $1.key }.map { key, value -> String in
            switch value {
            case .count(let number): "\(key)=\(number)"
            case .id(let id): "\(key)=\(id)"
            case .code(let code): "\(key)=\(code)"
            case .status(let status): "\(key)=\(status)"
            case .millis(let millis): "\(key)=\(millis)ms"
            }
        }.joined(separator: " ")
        logger.info("\(event, privacy: .public) \(text, privacy: .public)")
    }
}
#endif
