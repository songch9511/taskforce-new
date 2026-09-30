import Auth
import Foundation

/// 로그인한 계정에 붙은 로그인 방식. Supabase `identities`와 `app_metadata`의 provider("apple" · "google" · "email")로 정한다.
/// 계정 메뉴의 계정 줄 이름과, 계정 삭제 때 무엇을 폐기할지(Apple 재확인 · Google 연결 해제)를 정한다.
/// 같은 이메일(확인된 주소)로 Apple · Google에 로그인하면 Supabase가 한 계정에 둘을 잇는다.
public struct SignInMethods: Equatable, Sendable {
    public let providers: Set<String>
    /// 처음 가입한 방식 (`app_metadata.provider`)
    public let primary: String?

    public static let unknown = SignInMethods(providers: [], primary: nil)

    public init(providers: Set<String>, primary: String?) {
        self.providers = providers
        self.primary = primary
    }

    public init(user: User) {
        let primary = user.appMetadata["provider"]?.stringValue
        var providers = Set((user.identities ?? []).map(\.provider))
        providers.formUnion((user.appMetadata["providers"]?.arrayValue ?? []).compactMap(\.stringValue))
        if let primary { providers.insert(primary) }
        self.init(providers: providers, primary: primary)
    }

    public var hasGoogle: Bool { providers.contains("google") }

    /// 계정 삭제 전에 Apple 재확인(토큰 폐기용 authorization code)을 받을지: Apple 로그인이 붙은 계정만.
    /// 방식을 모르면(세션에 정보가 없음) 예전처럼 받는다.
    public var needsAppleReauthorization: Bool { providers.isEmpty || providers.contains("apple") }

    /// 계정 메뉴의 로그인 계정 줄 이름 (값은 로그인 이메일)
    public var accountLabel: String {
        switch primary {
        case "google": "Google Account"
        case "email": "Email"
        default: "Apple ID"
        }
    }
}

/// 로그인 계정이 준 이름 (Supabase `user_metadata`의 `full_name` → `name`: Google 로그인이 채운다. Apple · 이메일 로그인에는 없다).
/// 서버 `accountDisplayName`(src/lib/api/profile.ts)과 같은 순서이고, 이메일 앞부분으로 대신하지 않는다.
public enum AccountName {
    public static func from(metadata: [String: AnyJSON]) -> String? {
        for key in ["full_name", "name"] {
            if let value = metadata[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
