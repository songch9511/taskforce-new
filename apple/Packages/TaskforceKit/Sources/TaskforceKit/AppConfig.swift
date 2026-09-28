import Foundation

/// 앱 번들의 Info.plist에서 읽는 설정. 값은 `apple/Config/Secrets.xcconfig`(커밋하지 않음)에서 들어온다.
public struct AppConfig: Equatable, Sendable {
    public let supabaseURL: URL
    public let supabaseKey: String
    /// 앱 · 공유 확장 · 위젯이 로그인 세션을 함께 쓰는 App Group. Keychain 접근 그룹으로도 쓴다.
    public let appGroupID: String
    /// Taskforce 서버 (`/api/v1`의 앞부분). 로컬 개발은 `http://localhost:3000`
    public let apiBaseURL: URL

    public enum Key {
        public static let supabaseURL = "SupabaseURL"
        public static let supabaseKey = "SupabaseKey"
        public static let appGroupID = "AppGroupID"
        public static let apiBaseURL = "APIBaseURL"
    }

    public enum ConfigError: Error, Equatable, CustomStringConvertible {
        case missing(String)
        case invalidURL(key: String, value: String)

        public var description: String {
            switch self {
            // 개발자가 보는 설정 오류지만 화면에 뜨므로 영어로 (docs/BRAND.md "UI 문구")
            case .missing(let key):
                "\(key) is missing. Copy apple/Config/Secrets.example.xcconfig to Secrets.xcconfig and fill it in."
            case .invalidURL(let key, let value) where key == Key.apiBaseURL:
                "APIBaseURL is invalid (\(value)). Use https://<server> or http://localhost:3000 with no path."
            case .invalidURL(_, let value):
                "SupabaseURL is invalid (\(value)). Use https://<project ref>.supabase.co with no path."
            }
        }
    }

    public init(supabaseURL: URL, supabaseKey: String, appGroupID: String, apiBaseURL: URL) {
        self.supabaseURL = supabaseURL
        self.supabaseKey = supabaseKey
        self.appGroupID = appGroupID
        self.apiBaseURL = apiBaseURL
    }

    public init(infoDictionary: [String: Any]) throws {
        func value(_ key: String) throws -> String {
            let raw = (infoDictionary[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // xcconfig에 값이 없으면 "$(SUPABASE_URL)" 같은 치환 전 문자열이 남을 수 있다.
            guard !raw.isEmpty, !raw.hasPrefix("$(") else { throw ConfigError.missing(key) }
            return raw
        }

        /// 경로 · 쿼리 없는 http(s) 주소
        func baseURL(_ key: String) throws -> URL {
            let urlString = try value(key)
            guard let components = URLComponents(string: urlString),
                  components.scheme == "https" || components.scheme == "http",
                  let host = components.host, !host.isEmpty,
                  components.path.isEmpty || components.path == "/",
                  components.query == nil,
                  let url = components.url
            else { throw ConfigError.invalidURL(key: key, value: urlString) }
            return url
        }

        self.init(
            supabaseURL: try baseURL(Key.supabaseURL),
            supabaseKey: try value(Key.supabaseKey),
            appGroupID: try value(Key.appGroupID),
            apiBaseURL: try baseURL(Key.apiBaseURL)
        )
    }

    public static func fromMainBundle() throws -> AppConfig {
        try AppConfig(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }
}
