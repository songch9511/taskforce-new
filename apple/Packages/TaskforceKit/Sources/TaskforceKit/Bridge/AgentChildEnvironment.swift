#if os(macOS)
import Foundation

/// adapter가 에이전트 하위 프로세스에 넘기는 환경 변수의 허용 목록 (OA D2b 계약 7장 D · security 5).
/// 앱의 환경에는 사용자 토큰 · API 키 · 개발용 설정이 섞여 있을 수 있다. 하위 프로세스는 이 목록의 키만 받는다 (그 밖의 값은 adapter가 필요한 것을 명시해 더한다).
public enum AgentChildEnvironment {
    /// 허용하는 키. 값은 앱 환경 그대로 넘기고 목록 밖의 키는 모두 버린다
    public static let allowedKeys: [String] = ["HOME", "PATH", "LANG", "USER"]

    public static func allowlisted(from environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var result: [String: String] = [:]
        for key in allowedKeys {
            if let value = environment[key], !value.isEmpty, !value.contains("\0") { result[key] = value }
        }
        return result
    }
}
#endif
