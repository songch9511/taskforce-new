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

/// 계정 삭제 때 폐기할 것. 삭제 직전에 서버에서 새로 읽은 사용자로 정한다: 세션의 사용자는 토큰을 받은 때의 것이라,
/// 그 뒤 다른 기기에서 Apple을 이었으면 빠져 있다 (App Store 5.1.1(v): Apple 토큰 폐기). 못 읽으면 Apple 재확인을 받는다.
/// 새로 읽은 쪽에 Apple이 없어도 세션에 있으면 받는다: 폐기를 빠뜨리는 것보다 한 번 더 묻는 쪽이 안전하다.
public struct AccountDeletionPlan: Equatable, Sendable {
    /// 삭제 전에 Sign in with Apple을 한 번 더 받아 토큰 폐기용 code를 보낼지
    public let reauthorizeWithApple: Bool
    /// 삭제 뒤 이 기기의 Google 로그인 권한을 폐기할지
    public let disconnectGoogle: Bool

    /// `fresh`: 서버에서 새로 읽은 방식 (못 읽었으면 nil), `cached`: 세션의 방식
    public init(fresh: SignInMethods?, cached: SignInMethods) {
        reauthorizeWithApple = (fresh ?? .unknown).needsAppleReauthorization || cached.providers.contains("apple")
        disconnectGoogle = (fresh?.hasGoogle ?? false) || cached.hasGoogle
    }

    /// `fetchUser`: 서버에서 사용자 읽기 (`auth.user()`)
    public static func make(cached: SignInMethods, fetchUser: @Sendable () async throws -> User) async -> AccountDeletionPlan {
        let fresh = try? await fetchUser()
        return AccountDeletionPlan(fresh: fresh.map(SignInMethods.init(user:)), cached: cached)
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

/// Google 로그인 직후 한 번: 프로필 이름이 비어 있으면 그 로그인이 준 이름으로 채운다 (원문 속 "나"를 찾는 기본 이름).
/// 그 로그인의 사용자 id를 함께 들고 있어, 그사이 다른 계정으로 바뀌었으면 채우지 않는다.
/// 로그인 직후에만 채우므로, 사용자가 이름을 지운 뒤 다른 기기에서 앱을 열어도 다시 채우지 않는다.
public struct AccountNameFill: Equatable, Sendable {
    public let userID: UUID
    public let name: String

    public init(userID: UUID, name: String) {
        self.userID = userID
        self.name = name
    }

    /// 이름을 준 로그인이면 (Apple · 이메일 로그인은 이름이 없어 nil)
    public init?(user: User) {
        guard let name = AccountName.from(metadata: user.userMetadata) else { return nil }
        self.init(userID: user.id, name: name)
    }

    /// 지금 로그인한 사용자가 그 사용자이고 프로필 이름이 비어 있으면 저장할 프로필. 아니면 nil
    public func profile(filling profile: Profile, signedInUserID: UUID?) -> Profile? {
        guard signedInUserID == userID, profile.displayName == nil else { return nil }
        return Profile.edited(name: name, aliases: profile.aliases, keeping: profile)
    }
}
