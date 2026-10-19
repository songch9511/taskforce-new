import Foundation

/// Mac의 Sign in with Apple (브라우저 창, Apple 웹 로그인). 순수 부품: 설정 읽기 · 주소 만들기 · 돌아온 주소 읽기. 창을 띄우는 일은 앱(`AppleSignInFlow`)이 한다.
///
/// 왜 웹인가: Developer ID로 배포하는 Mac 앱은 `com.apple.developer.applesignin` 권한을 프로필로 받을 수 없어 앱 안(native) Apple 로그인을 쓸 수 없다
/// (Apple "Supported capabilities (macOS)": Sign in with Apple은 Developer ID 열이 비었다. 10-05 export가 이래서 실패했다). 권한 파일에는 넣지 않는다.
/// 흐름: 앱이 Apple authorize 주소를 연다 → Apple이 서버 `POST /api/v1/apple/return`으로 form_post → 서버가 `taskforce://auth/apple?…`로 303 →
/// ASWebAuthenticationSession이 그 주소를 받는다 → `signInWithApple(idToken:nonce:)`. 서버는 저장 · 기록 0이고, 토큰의 서명 · aud · nonce는 Supabase가 확인한다.
/// iPhone은 앱 안 로그인이라 이 부품을 쓰지 않는다 (같은 `SessionStore.signInWithApple`).
public struct AppleWebSignInConfig: Equatable, Sendable {
    /// Apple Developer의 Services ID (Primary App ID `dev.taskforcelabs.taskforce`에 묶인 것). Supabase Apple 제공자의 Client IDs에도 있다
    public let servicesID: String
    /// Services ID의 Return URL: `https://<서버>/api/v1/apple/return`
    public let returnURL: URL

    public enum Key {
        public static let servicesID = "AppleServicesID"
        public static let returnURL = "AppleWebReturnURL"
    }

    /// 서버 중계 route의 경로 (`src/app/api/v1/apple/return/route.ts`)
    public static let returnPath = "/api/v1/apple/return"

    /// 값이 비었거나(CI · 기여자) 치환되지 않았거나, return URL이 https · 정해진 경로가 아니거나 Apple이 받지 않는 주소(IP · localhost)면 nil: Apple 버튼 · 행을 숨긴다
    public init?(infoDictionary: [String: Any]) {
        let servicesID = (infoDictionary[Key.servicesID] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let returnString = (infoDictionary[Key.returnURL] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // xcconfig에 값이 없으면 빈 문자열, 치환되지 않으면 "$(APPLE_SERVICES_ID)"가 남는다
        guard !servicesID.isEmpty, !servicesID.hasPrefix("$("), !servicesID.contains(where: \.isWhitespace) else { return nil }
        guard !returnString.hasPrefix("$("), let url = URL(string: returnString), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // Apple은 return URL의 도메인만 받는다 (IP · localhost 불가, # 불가). 경로는 중계 route 하나다
        guard parts.scheme == "https", let host = parts.host, Self.isDomain(host), parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.path == Self.returnPath else { return nil }
        self.servicesID = servicesID
        self.returnURL = url
    }

    private static func isDomain(_ host: String) -> Bool {
        let host = host.lowercased()
        guard host.contains("."), host != "localhost", !host.hasSuffix(".localhost"), !host.contains(":") else { return false }
        // IPv4 (숫자와 점뿐)
        return host.contains { $0.isLetter }
    }
}

public enum AppleWebAuthorization {
    /// 앱이 받는 주소 `taskforce://auth/apple` (서버 중계 route의 목적지와 같다)
    public static let callbackScheme = "taskforce"
    static let callbackHost = "auth"
    static let callbackPath = "/apple"
    /// Apple이 취소 때 보내는 error 값
    static let canceledError = "user_cancelled_authorize"
    /// 서버가 돌려준 형식 오류
    static let invalidResponseError = "invalid_response"

    /// 흐름마다 새로 만드는 state (32자 [A-Za-z0-9_-]): 돌아온 주소가 이 흐름 것인지 확인한다. 서버 route는 16–128자만 받는다
    public static func makeState() -> String {
        let charset = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        var generator = SystemRandomNumberGenerator()
        return String((0..<32).map { _ in charset.randomElement(using: &generator)! })
    }

    /// 로그인 · 이어 붙이기: ID 토큰을 받는다. 범위는 `email`만 (이름 없음), nonce는 해시를 보낸다 (Supabase에는 원본).
    /// 범위를 달면 `response_mode`는 `form_post`여야 한다. 공백은 `%20` (`+`가 아니다).
    public static func signInURL(config: AppleWebSignInConfig, state: String, nonce: SignInNonce) -> URL {
        authorizeURL(config: config, items: [
            ("client_id", config.servicesID), ("redirect_uri", config.returnURL.absoluteString),
            ("response_type", "code id_token"), ("response_mode", "form_post"), ("scope", "email"),
            ("state", state), ("nonce", nonce.hashed),
        ])
    }

    /// 계정 삭제 재확인: 범위 · nonce 없이 authorization code만 받는다 (서버가 `apple_client: web`으로 폐기)
    public static func reauthorizeURL(config: AppleWebSignInConfig, state: String) -> URL {
        authorizeURL(config: config, items: [
            ("client_id", config.servicesID), ("redirect_uri", config.returnURL.absoluteString),
            ("response_type", "code"), ("response_mode", "form_post"), ("state", state),
        ])
    }

    private static func authorizeURL(config: AppleWebSignInConfig, items: [(String, String)]) -> URL {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = "appleid.apple.com"
        parts.path = "/auth/authorize"
        // `URLQueryItem`은 `+`와 `&` 등을 그대로 둔다: 값을 직접 퍼센트 인코딩해 공백이 `%20`이 되게 한다
        parts.percentEncodedQuery = items.map { "\($0.0)=\(percentEncode($0.1))" }.joined(separator: "&")
        return parts.url!
    }

    private static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// 돌아온 주소를 읽은 결과
    public enum Outcome: Equatable, Sendable {
        /// 로그인 · 이어 붙이기: Apple의 ID 토큰 (nonce는 Supabase가 확인한다)
        case idToken(String)
        /// 재확인: 삭제할 때 서버가 폐기에 쓰는 authorization code
        case code(String)
        /// 사용자가 창에서 취소했다: 조용히 끝낸다
        case canceled
        /// 필요한 값이 없다 (서버가 형식 오류를 돌려줬거나 id_token · code가 없음): "Apple didn't return a sign-in token. Try again."
        case missingToken
        /// Apple이 돌려준 오류 (안전한 글자만 남긴 코드): "Couldn't sign in with Apple. …"
        case failed(String)
        /// 이 흐름의 주소가 아니다 (다른 host · path · state): 아무것도 하지 않는다
        case notOurs
    }

    public enum Purpose: Sendable {
        /// 로그인 · 이어 붙이기 (id_token)
        case signIn
        /// 삭제 재확인 (code)
        case reauthorize
    }

    /// `expectedState`는 이 흐름이 만든 값이어야 한다: 맞지 않으면 토큰이 있어도 `notOurs`.
    public static func parse(callback url: URL, expectedState: String, purpose: Purpose) -> Outcome {
        guard url.scheme?.lowercased() == callbackScheme, url.host?.lowercased() == callbackHost, url.path == callbackPath,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return .notOurs }
        var values: [String: String] = [:]
        var repeated: Set<String> = []
        for item in parts.queryItems ?? [] {
            if values[item.name] != nil { repeated.insert(item.name) } else { values[item.name] = item.value ?? "" }
        }
        // state가 이 흐름의 것이 아니면 아무것도 읽지 않는다 (토큰도 쓰지 않는다)
        guard !expectedState.isEmpty, !repeated.contains("state"), values["state"] == expectedState else { return .notOurs }
        // 읽는 값이 겹쳐 오면 하나로 정할 수 없다
        guard repeated.isDisjoint(with: ["id_token", "code", "error"]) else { return .missingToken }
        if let error = values["error"] {
            switch error {
            case canceledError: return .canceled
            case invalidResponseError: return .missingToken
            default: return .failed(safe(error))
            }
        }
        switch purpose {
        case .signIn:
            guard let idToken = values["id_token"], !idToken.isEmpty else { return .missingToken }
            return .idToken(idToken)
        case .reauthorize:
            guard let code = values["code"], !code.isEmpty else { return .missingToken }
            return .code(code)
        }
    }

    /// 화면에 보일 수 있는 오류 코드만 남긴다 (영문 · 숫자 · `_` `-` `.`, 60자까지)
    private static func safe(_ error: String) -> String {
        let kept = error.filter { $0.isASCII && ($0.isLetter || $0.isNumber || "_-.".contains($0)) }
        return kept.isEmpty ? "unknown_error" : String(kept.prefix(60))
    }
}
