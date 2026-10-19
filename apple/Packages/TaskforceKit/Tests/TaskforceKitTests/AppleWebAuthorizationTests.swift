import Foundation
import Testing
@testable import TaskforceKit

/// Mac의 Apple 웹 로그인 (OA 로그인 계약 5.1): 설정 읽기 · 주소 만들기 · 돌아온 주소 읽기. 순수 부품이라 창 · 네트워크 없이 본다.
struct AppleWebSignInConfigTests {
    let servicesID = "dev.taskforcelabs.taskforce.signin"
    let returnURL = "https://api.taskforcelabs.dev/api/v1/apple/return"

    func info(_ servicesID: String?, _ returnURL: String?) -> [String: Any] {
        var info: [String: Any] = [:]
        if let servicesID { info["AppleServicesID"] = servicesID }
        if let returnURL { info["AppleWebReturnURL"] = returnURL }
        return info
    }

    @Test func readsAServicesIDAndTheHTTPSReturnURL() throws {
        let config = try #require(AppleWebSignInConfig(infoDictionary: info(servicesID, returnURL)))
        #expect(config.servicesID == servicesID)
        #expect(config.returnURL.absoluteString == returnURL)
        #expect(AppleWebSignInConfig(infoDictionary: info("  \(servicesID) ", " \(returnURL)\n")) == config)
    }

    /// CI · 기여자 빌드: xcconfig 값이 비어 있으면 Apple 버튼 · 행을 숨긴다
    @Test func emptyOrUnresolvedValuesHideApple() {
        #expect(AppleWebSignInConfig(infoDictionary: [:]) == nil)
        #expect(AppleWebSignInConfig(infoDictionary: info("", returnURL)) == nil)
        #expect(AppleWebSignInConfig(infoDictionary: info("  ", returnURL)) == nil)
        #expect(AppleWebSignInConfig(infoDictionary: info("$(APPLE_SERVICES_ID)", returnURL)) == nil)
        #expect(AppleWebSignInConfig(infoDictionary: info(servicesID, "")) == nil)
        #expect(AppleWebSignInConfig(infoDictionary: info(servicesID, "$(APPLE_WEB_RETURN_URL)")) == nil)
        #expect(AppleWebSignInConfig(infoDictionary: info("two words", returnURL)) == nil)
        #expect(AppleWebSignInConfig(infoDictionary: info(servicesID, nil)) == nil)
    }

    @Test func aReturnURLThatIsNotHTTPSAndTheFixedPathHidesApple() {
        for bad in [
            "http://api.taskforcelabs.dev/api/v1/apple/return",
            "taskforce://auth/apple",
            "https://api.taskforcelabs.dev/api/v1/apple/other",
            "https://api.taskforcelabs.dev/api/v1/apple/return/",
            "https://api.taskforcelabs.dev/",
            "https://api.taskforcelabs.dev/api/v1/apple/return?x=1",
            "https://api.taskforcelabs.dev/api/v1/apple/return#frag",
            "https://user:pw@api.taskforcelabs.dev/api/v1/apple/return",
            "api.taskforcelabs.dev/api/v1/apple/return",
        ] {
            #expect(AppleWebSignInConfig(infoDictionary: info(servicesID, bad)) == nil, "\(bad)")
        }
    }

    /// Apple은 return URL로 도메인만 받는다 (IP · localhost 불가)
    @Test func appleDoesNotTakeIPsOrLocalhost() {
        for host in ["localhost", "127.0.0.1", "10.0.0.5:3000", "[::1]", "myhost", "app.localhost"] {
            #expect(AppleWebSignInConfig(infoDictionary: info(servicesID, "https://\(host)/api/v1/apple/return")) == nil, "\(host)")
        }
        #expect(AppleWebSignInConfig(infoDictionary: info(servicesID, "https://api.taskforcelabs.dev:8443/api/v1/apple/return")) != nil)
    }
}

struct AppleWebAuthorizationTests {
    let config = AppleWebSignInConfig(infoDictionary: [
        "AppleServicesID": "dev.taskforcelabs.taskforce.signin", "AppleWebReturnURL": "https://api.taskforcelabs.dev/api/v1/apple/return",
    ])!
    let state = "Abcdefghijklmnop_-0123456789"

    func query(_ url: URL) -> [(String, String)] {
        (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }
    }

    func callback(_ items: [(String, String?)], host: String = "auth", path: String = "/apple", scheme: String = "taskforce") -> URL {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = host
        parts.path = path
        parts.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        return parts.url!
    }

    // MARK: 주소 만들기

    @Test func signInURLCarriesExactlyTheAuthorizeParameters() {
        let nonce = SignInNonce(raw: "raw-nonce-123")
        let url = AppleWebAuthorization.signInURL(config: config, state: state, nonce: nonce)
        #expect(url.scheme == "https")
        #expect(url.host == "appleid.apple.com")
        #expect(url.path == "/auth/authorize")
        #expect(query(url).map(\.0) == ["client_id", "redirect_uri", "response_type", "response_mode", "scope", "state", "nonce"])
        let values = Dictionary(uniqueKeysWithValues: query(url))
        #expect(values["client_id"] == "dev.taskforcelabs.taskforce.signin")
        #expect(values["redirect_uri"] == "https://api.taskforcelabs.dev/api/v1/apple/return")
        #expect(values["response_type"] == "code id_token")
        #expect(values["response_mode"] == "form_post")
        // 범위는 email만 (이름 없음)
        #expect(values["scope"] == "email")
        #expect(values["state"] == state)
        // Apple에는 nonce의 해시를 보낸다 (원본은 Supabase에)
        #expect(values["nonce"] == nonce.hashed)
        #expect(values["nonce"] != nonce.raw)
    }

    /// 공백은 `%20`이다 (`+` 아님): Apple authorize는 `+`를 공백으로 읽지 않는다
    @Test func spacesArePercentTwentyAndTheReturnURLIsEncoded() {
        let url = AppleWebAuthorization.signInURL(config: config, state: state, nonce: SignInNonce(raw: "n"))
        let raw = url.absoluteString
        #expect(raw.contains("response_type=code%20id_token"))
        #expect(!raw.contains("+"))
        #expect(raw.contains("redirect_uri=https%3A%2F%2Fapi.taskforcelabs.dev%2Fapi%2Fv1%2Fapple%2Freturn"))
    }

    /// 재확인: 범위 · nonce 없이 code만 (`response_mode`는 form_post: code가 주소 기록에 남지 않는다)
    @Test func reauthorizeURLAsksOnlyForACode() {
        let url = AppleWebAuthorization.reauthorizeURL(config: config, state: state)
        #expect(url.host == "appleid.apple.com")
        #expect(url.path == "/auth/authorize")
        let values = Dictionary(uniqueKeysWithValues: query(url))
        #expect(Set(values.keys) == ["client_id", "redirect_uri", "response_type", "response_mode", "state"])
        #expect(values["response_type"] == "code")
        #expect(values["response_mode"] == "form_post")
        #expect(values["scope"] == nil && values["nonce"] == nil)
        #expect(values["state"] == state)
        #expect(values["client_id"] == "dev.taskforcelabs.taskforce.signin")
    }

    /// 서버 중계 route는 16–128자 [A-Za-z0-9_-]만 받는다: 앱이 만드는 state는 늘 그 모양이고 흐름마다 다르다
    @Test func statesFitTheRelayRouteAndNeverRepeat() {
        let states = (0..<200).map { _ in AppleWebAuthorization.makeState() }
        #expect(Set(states).count == states.count)
        for value in states {
            #expect(value.count == 32)
            #expect(value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        }
    }

    // MARK: 돌아온 주소 읽기

    @Test func readsTheIDTokenForASignIn() {
        let url = callback([("state", state), ("code", "c1"), ("id_token", "aaa.bbb.ccc")])
        #expect(AppleWebAuthorization.parse(callback: url, expectedState: state, purpose: .signIn) == .idToken("aaa.bbb.ccc"))
    }

    @Test func readsTheCodeForAReauthorization() {
        let url = callback([("state", state), ("code", "c0de.1.2")])
        #expect(AppleWebAuthorization.parse(callback: url, expectedState: state, purpose: .reauthorize) == .code("c0de.1.2"))
        // 로그인용 주소를 재확인으로 읽으면 code가 있어도 id_token을 쓰지 않는다
        #expect(AppleWebAuthorization.parse(callback: url, expectedState: state, purpose: .signIn) == .missingToken)
    }

    /// state가 다르면 토큰이 있어도 아무것도 읽지 않는다 (다른 흐름 · 위조된 주소)
    @Test func aDifferentOrMissingStateIsNotOurs() {
        let other = callback([("state", "Zzzzzzzzzzzzzzzz_-9999999999"), ("id_token", "aaa.bbb.ccc")])
        #expect(AppleWebAuthorization.parse(callback: other, expectedState: state, purpose: .signIn) == .notOurs)
        let none = callback([("id_token", "aaa.bbb.ccc")])
        #expect(AppleWebAuthorization.parse(callback: none, expectedState: state, purpose: .signIn) == .notOurs)
        let empty = callback([("state", ""), ("id_token", "aaa.bbb.ccc")])
        #expect(AppleWebAuthorization.parse(callback: empty, expectedState: "", purpose: .signIn) == .notOurs)
        // state가 두 번 오면 하나로 정할 수 없다
        let twice = callback([("state", state), ("state", state), ("id_token", "aaa.bbb.ccc")])
        #expect(AppleWebAuthorization.parse(callback: twice, expectedState: state, purpose: .signIn) == .notOurs)
    }

    @Test func aDifferentSchemeHostOrPathIsNotOurs() {
        for url in [
            callback([("state", state), ("id_token", "a.b.c")], host: "connections"),
            callback([("state", state), ("id_token", "a.b.c")], host: "evil"),
            callback([("state", state), ("id_token", "a.b.c")], path: "/other"),
            callback([("state", state), ("id_token", "a.b.c")], path: "/apple/extra"),
            callback([("state", state), ("id_token", "a.b.c")], path: ""),
            callback([("state", state), ("id_token", "a.b.c")], scheme: "https"),
            URL(string: "com.googleusercontent.apps.123-abc:/oauth2callback?state=\(state)&id_token=a.b.c")!,
        ] {
            #expect(AppleWebAuthorization.parse(callback: url, expectedState: state, purpose: .signIn) == .notOurs, "\(url)")
        }
        // scheme · host는 대소문자를 가리지 않는다
        let upper = URL(string: "TASKFORCE://AUTH/apple?state=\(state)&id_token=a.b.c")!
        #expect(AppleWebAuthorization.parse(callback: upper, expectedState: state, purpose: .signIn) == .idToken("a.b.c"))
    }

    @Test func cancelingIsQuietAndNotAnError() {
        let url = callback([("state", state), ("error", "user_cancelled_authorize")])
        #expect(AppleWebAuthorization.parse(callback: url, expectedState: state, purpose: .signIn) == .canceled)
        #expect(AppleWebAuthorization.parse(callback: url, expectedState: state, purpose: .reauthorize) == .canceled)
    }

    @Test func aMissingTokenIsReportedNotSignedIn() {
        for items in [
            [("state", state)],
            [("state", state), ("code", "c1")],
            [("state", state), ("id_token", "")],
            [("state", state), ("error", "invalid_response")],
            [("state", state), ("id_token", "a.b.c"), ("id_token", "d.e.f")],
        ] as [[(String, String?)]] {
            #expect(AppleWebAuthorization.parse(callback: callback(items), expectedState: state, purpose: .signIn) == .missingToken, "\(items)")
        }
        let noCode = callback([("state", state), ("id_token", "a.b.c")])
        #expect(AppleWebAuthorization.parse(callback: noCode, expectedState: state, purpose: .reauthorize) == .missingToken)
    }

    /// Apple이 돌려준 오류는 안전한 글자만 남겨 알린다. 같이 온 토큰은 쓰지 않는다
    @Test func anAppleErrorIsReportedWithSafeCharactersOnly() {
        let url = callback([("state", state), ("error", "invalid_request"), ("id_token", "a.b.c")])
        #expect(AppleWebAuthorization.parse(callback: url, expectedState: state, purpose: .signIn) == .failed("invalid_request"))
        let noisy = callback([("state", state), ("error", "bad <b>error</b>\n한글 & more")])
        #expect(AppleWebAuthorization.parse(callback: noisy, expectedState: state, purpose: .signIn) == .failed("badberrorbmore"))
        let junk = callback([("state", state), ("error", "한글")])
        #expect(AppleWebAuthorization.parse(callback: junk, expectedState: state, purpose: .signIn) == .failed("unknown_error"))
        let long = callback([("state", state), ("error", String(repeating: "e", count: 300))])
        #expect(AppleWebAuthorization.parse(callback: long, expectedState: state, purpose: .signIn) == .failed(String(repeating: "e", count: 60)))
    }
}
