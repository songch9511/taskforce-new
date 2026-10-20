import Auth
import Foundation

/// 로그인한 계정에 붙은 로그인 방식. Supabase `identities`와 `app_metadata`의 provider("apple" · "google" · "email")로 정한다.
/// 계정 메뉴의 계정 줄 이름과, 계정 삭제 때 무엇을 폐기할지(Apple 재확인 · Google 연결 해제)를 정한다.
/// 같은 이메일(확인된 주소)로 Apple · Google에 로그인하면 Supabase가 한 계정에 둘을 잇는다.
/// 이메일이 다르면(예: Apple의 "이메일 가리기") 다른 계정이 되고, Settings의 Sign-in에서 없는 쪽을 이어 붙일 수 있다 (`SessionStore.linkApple` · `linkGoogle`).
public struct SignInMethods: Equatable, Sendable {
    public let providers: Set<String>
    /// 처음 가입한 방식 (`app_metadata.provider`)
    public let primary: String?
    /// 이어진 방식마다 그 로그인의 이메일 (`identities[].identity_data.email`). 모르면 키가 없다
    public let emails: [String: String]
    /// App Store 심사 계정 (`app_metadata.review_account == true`, `scripts/create-review-account.ts`가 관리자 키로 넣는다).
    /// 이메일 로그인을 모두에게 연 뒤에도 심사 계정은 Email 줄만 보이게 한다 (이메일 계정이면 모두 심사 계정이라는 가정이 틀려진다)
    public let isReviewAccount: Bool

    public static let unknown = SignInMethods(providers: [], primary: nil)

    public init(providers: Set<String>, primary: String?, emails: [String: String] = [:], isReviewAccount: Bool = false) {
        self.providers = providers
        self.primary = primary
        self.emails = emails
        self.isReviewAccount = isReviewAccount
    }

    public init(user: User) {
        let primary = user.appMetadata["provider"]?.stringValue
        var providers = Set((user.identities ?? []).map(\.provider))
        providers.formUnion((user.appMetadata["providers"]?.arrayValue ?? []).compactMap(\.stringValue))
        if let primary { providers.insert(primary) }
        var emails: [String: String] = [:]
        for identity in user.identities ?? [] {
            if let email = identity.identityData?["email"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
                emails[identity.provider] = email
            }
        }
        self.init(providers: providers, primary: primary, emails: emails, isReviewAccount: user.appMetadata["review_account"]?.boolValue == true)
    }

    public var hasGoogle: Bool { providers.contains("google") }
    public var hasApple: Bool { providers.contains("apple") }

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

/// Settings › Account › Sign-in의 방법별 줄 하나. 이어진 방법은 그 로그인의 이메일을 보이고, 이어지지 않은 Apple · Google은 "Add"로 이어 붙인다.
public struct SignInMethodRow: Equatable, Sendable, Identifiable {
    public enum Method: String, Sendable, CaseIterable {
        case apple, google, email
    }

    public let method: Method
    public let linked: Bool
    /// 그 방법으로 로그인하는 이메일: identity의 이메일, 없으면 계정 이메일. 이어지지 않았으면 nil
    public let email: String?

    public var id: String { method.rawValue }
    /// "Add"를 둘 줄: 이어지지 않은 Apple · Google. 이메일(심사 계정)은 이어 붙이지 않는다
    public var canAdd: Bool { !linked && method != .email }
}

extension SignInMethods {
    /// 방법마다 한 줄: 이어진 방법이 먼저(Apple · Google · Email 순), 이어지지 않은 Apple · Google이 그 뒤. 이메일은 이어졌을 때만 줄이 있다.
    /// 방식을 모르면(`providers`가 비어 있음) 줄이 없다: 화면은 예전 한 줄(`accountLabel`)로 둔다.
    ///
    /// `emailSignIn` = 이메일 로그인을 열었는지(`EmailSignInGate`, 기본 닫힘: 줄은 예전과 같다). 닫혀 있으면 이메일(App Store 심사 계정)로 로그인한 계정은
    /// Email 줄만 있고(심사원이 눌러 볼 Add를 두지 않는다) Apple · Google 계정에는 Email 줄이 없다. 열려 있으면 (OA 이메일 로그인 계약 5.8):
    /// - 심사 계정(`isReviewAccount`)은 지금처럼 Email 줄만이다
    /// - Apple · Google로 만든 계정은 계정 이메일이 실제 주소일 때 Email 줄도 이어져 있다 (그 주소로 코드 로그인이 되고 Supabase가 한 계정으로 잇는다).
    ///   Apple "이메일 가리기" 주소(`@privaterelay.appleid.com`)나 주소가 없으면 Email 줄이 없다
    /// - 이메일 코드로 만든 계정은 Email 줄이 이어져 있고, 이어지지 않은 Apple · Google은 Add다
    public func rows(accountEmail: String?, emailSignIn: Bool = false) -> [SignInMethodRow] {
        guard !providers.isEmpty else { return [] }
        let address = accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        // 이메일 줄이 이어졌는가: 이메일 identity가 있거나(이메일 로그인 계정 · 심사 계정), 열려 있으면 실제 주소가 있는 계정
        let emailLinked = providers.contains("email") || (emailSignIn && address.map { !Self.isHiddenAppleAddress($0) } == true)
        func row(_ method: SignInMethodRow.Method) -> SignInMethodRow {
            let linked = method == .email ? emailLinked : providers.contains(method.rawValue)
            return SignInMethodRow(method: method, linked: linked, email: linked ? emails[method.rawValue] ?? accountEmail : nil)
        }
        let all = SignInMethodRow.Method.allCases.map(row)
        let linked = all.filter(\.linked)
        if emailSignIn ? isReviewAccount : providers.contains("email") { return linked }
        return linked + all.filter { !$0.linked && $0.method != .email }
    }

    /// Apple "이메일 가리기"가 만든 중계 주소 (보내는 도메인을 Apple에 등록해야 받을 수 있어, 사용자가 외워 넣기도 어렵다)
    static func isHiddenAppleAddress(_ address: String) -> Bool {
        address.lowercased().hasSuffix("@privaterelay.appleid.com")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
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

// MARK: 문구 (사용자 승인 2026-10-19: handoffs/oa-signin-dz/README.md "사용자 승인용 새 문구", 이메일 로그인은 2026-10-20: handoffs/oa-email-signin-dz/README.md)

/// 로그인 화면 · Settings Sign-in 절 · 계정 삭제 · 이메일 로그인의 UI 문구. 승인된 문구를 한 곳에 모은다 (시험이 글자 하나하나 고정한다).
/// 오류 줄은 조용한 회색 힌트이고(빨강 아님), 재확인을 기다리는 동안은 문구 없이 스피너뿐이다.
public enum SignInCopy {
    // 로그인 화면 (DS `SignIn`)
    public static let title = "Sign in to Taskforce"
    public static let appleTitle = "Sign in with Apple"
    public static let googleTitle = "Continue with Google"
    /// 한 줄 안의 "Terms"와 "Privacy Policy"가 링크
    public static let legalLine = "By continuing you agree to the Terms and Privacy Policy."
    /// 로그인 설정이 둘 다 없을 때(Debug 빌드)
    public static let unavailable = "Sign-in is unavailable in this build."
    // Apple 로그인 오류 줄
    public static let appleMissingToken = "Apple didn't return a sign-in token. Try again."
    public static let appleFailed = "Couldn't sign in with Apple. Try again."
    public static let appleOpenFailed = "Couldn't open Apple sign-in. Try again."
    // Settings › Account › Sign-in
    public static let addButton = "Add"
    public static let appleBelongsToAnotherAccount = "This Apple ID belongs to another Taskforce account."
    public static let googleBelongsToAnotherAccount = "This Google account belongs to another Taskforce account."
    public static let addFailed = "Couldn't add it. Try again."
    /// Sign-in 각주에 더하는 문장: 이어 붙일 방법이 남았을 때만
    public static let addTheOther = "Add the other one to sign in with either."
    // 이메일 6자리 코드 로그인 (사용자 승인 2026-10-20). 오류는 모두 칸 아래 회색 한 줄이다
    public static let emailTitle = "Continue with email"
    public static let emailLabel = "Email"
    public static let sendCode = "Send code"
    public static let back = "Back"
    public static let codeLabel = "Code"
    public static let signIn = "Sign in"
    public static let resendCode = "Resend code"
    public static let useDifferentEmail = "Use a different email"
    public static let addressInvalid = "Add the full address, like jordan@example.com."
    public static let addressBlocked = "This address can't be used. Try another one."
    public static let wrongCode = "That code didn't work. Try the latest email."
    /// 보내기 실패 · 보내기 한도 · 확인 한도 · 다시 받기 실패를 한 줄로 합친 글 (어느 쪽에도 거짓이 되지 않게 "send"와 "tries"를 뺐다)
    public static let couldntContinue = "Couldn't continue. Try again in a few minutes."
    /// Sign-in 각주에 더하는 문장: 이어 붙일 방법이 둘 남았을 때(이메일 계정). 하나 남았을 때는 `addTheOther`
    public static let addEither = "Add Apple or Google to sign in with either."
    /// 막힌 버튼의 이유는 글로 보이지 않는다: hover 제목 · VoiceOver에만 (다시 받기 60초 · 6자리가 되기 전의 Sign in). 막힌 버튼의 글자는 그대로다
    public static let enterSixDigits = "Enter the 6-digit code"

    public static func codeSent(to address: String) -> String { "Code sent to \(address)" }
    public static func newCodeSent(to address: String) -> String { "New code sent to \(address)" }
    public static func resendAvailableIn(seconds: Int) -> String { "Available in \(seconds) seconds" }

    // 계정 삭제
    public static let deleteRemovesAccess = "We try to remove Apple, Google, and connected-service access, but it may remain."
    public static let signInBeforeDeleting = "Sign in before deleting your account."
    /// 삭제 뒤 Apple 폐기를 못 했을 때 (account.apple.com의 메뉴 이름은 확인 필요: L2)
    public static let appleRevokeSkipped = "Account deleted. To remove Sign in with Apple too, go to account.apple.com › Sign-In and Security › Sign in with Apple."

    /// Sign-in 절의 줄 이름
    public static func rowLabel(_ method: SignInMethodRow.Method) -> String {
        switch method {
        case .apple: "Apple"
        case .google: "Google"
        case .email: "Email"
        }
    }

    /// 이어 붙이기 결과의 한 줄 (조용한 회색 힌트). 성공이면 nil
    public static func addMessage(for result: SessionStore.LinkResult, method: SignInMethodRow.Method) -> String? {
        switch result {
        case .linked: nil
        case .belongsToAnotherAccount: method == .apple ? appleBelongsToAnotherAccount : googleBelongsToAnotherAccount
        case .failed: addFailed
        }
    }
}
