import Foundation

/// 앱 번들의 Info.plist에서 읽는 설정. 값은 `apple/Config/Secrets.xcconfig`(커밋하지 않음)에서 들어온다.
public struct AppConfig: Equatable, Sendable {
    public let supabaseURL: URL
    public let supabaseKey: String
    /// 앱 · 공유 확장 · 위젯이 로그인 세션을 함께 쓰는 App Group. Keychain 접근 그룹으로도 쓴다.
    public let appGroupID: String

    public enum Key {
        public static let supabaseURL = "SupabaseURL"
        public static let supabaseKey = "SupabaseKey"
        public static let appGroupID = "AppGroupID"
    }

    public enum ConfigError: Error, Equatable, CustomStringConvertible {
        case missing(String)
        case invalidURL(String)

        public var description: String {
            switch self {
            case .missing(let key):
                "\(key) 값이 없습니다. apple/Config/Secrets.example.xcconfig를 복사해 Secrets.xcconfig를 채우세요."
            case .invalidURL(let value):
                "SupabaseURL이 잘못되었습니다 (\(value)). 경로 없이 https://<프로젝트 ref>.supabase.co 형태여야 합니다."
            }
        }
    }

    public init(supabaseURL: URL, supabaseKey: String, appGroupID: String) {
        self.supabaseURL = supabaseURL
        self.supabaseKey = supabaseKey
        self.appGroupID = appGroupID
    }

    public init(infoDictionary: [String: Any]) throws {
        func value(_ key: String) throws -> String {
            let raw = (infoDictionary[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // xcconfig에 값이 없으면 "$(SUPABASE_URL)" 같은 치환 전 문자열이 남을 수 있다.
            guard !raw.isEmpty, !raw.hasPrefix("$(") else { throw ConfigError.missing(key) }
            return raw
        }

        let urlString = try value(Key.supabaseURL)
        guard let components = URLComponents(string: urlString),
              components.scheme == "https" || components.scheme == "http",
              let host = components.host, !host.isEmpty,
              components.path.isEmpty || components.path == "/",
              components.query == nil,
              let url = components.url
        else { throw ConfigError.invalidURL(urlString) }

        self.init(supabaseURL: url, supabaseKey: try value(Key.supabaseKey), appGroupID: try value(Key.appGroupID))
    }

    public static func fromMainBundle() throws -> AppConfig {
        try AppConfig(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }
}
