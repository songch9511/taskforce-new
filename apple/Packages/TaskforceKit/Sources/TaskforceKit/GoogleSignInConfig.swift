import Foundation

/// Sign in with Google 설정. Info.plist의 `GIDClientID`(Google Cloud iOS 클라이언트, Mac도 같은 값)와
/// 콜백 URL scheme(클라이언트 ID를 점 단위로 뒤집은 값)을 읽는다. 값은 xcconfig `GOOGLE_IOS_CLIENT_ID` · `GOOGLE_IOS_URL_SCHEME`에서 온다.
///
/// 로그인만 한다 (범위는 Google Sign-In 기본값 openid · email · profile). Gmail 연결은 서버 연동으로 따로다.
public struct GoogleSignInConfig: Equatable, Sendable {
    public let clientID: String

    public enum Key {
        public static let clientID = "GIDClientID"
        public static let urlTypes = "CFBundleURLTypes"
        public static let urlSchemes = "CFBundleURLSchemes"
    }

    /// 값이 비었거나(CI · 기여자) 형식이 다르거나, 콜백 URL scheme이 등록되지 않았으면 nil: Google 버튼을 숨긴다.
    /// scheme이 빠진 채 로그인을 시작하면 Google Sign-In SDK가 예외로 앱을 멈추므로 여기서 먼저 거른다.
    public init?(infoDictionary: [String: Any]) {
        let clientID = (infoDictionary[Key.clientID] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // xcconfig에 값이 없으면 빈 문자열, 치환되지 않으면 "$(GOOGLE_IOS_CLIENT_ID)"가 남는다
        guard clientID.hasSuffix(".apps.googleusercontent.com"), !clientID.hasPrefix("$(") else { return nil }
        let schemes = (infoDictionary[Key.urlTypes] as? [[String: Any]] ?? [])
            .flatMap { $0[Key.urlSchemes] as? [String] ?? [] }
            .map { $0.lowercased() }
        guard schemes.contains(Self.callbackScheme(for: clientID)) else { return nil }
        self.clientID = clientID
    }

    /// Google이 로그인 결과를 돌려주는 URL scheme
    public var callbackScheme: String { Self.callbackScheme(for: clientID) }

    /// Google Sign-In SDK와 같은 규칙: 점으로 나눈 조각을 거꾸로 잇고 소문자로
    /// (`123-abc.apps.googleusercontent.com` → `com.googleusercontent.apps.123-abc`)
    public static func callbackScheme(for clientID: String) -> String {
        clientID.split(separator: ".", omittingEmptySubsequences: false).reversed().joined(separator: ".").lowercased()
    }

    /// Google 로그인 콜백인지 (`taskforce://` 연결 콜백과 나눈다)
    public func handles(_ url: URL) -> Bool {
        url.scheme?.lowercased() == callbackScheme
    }
}
