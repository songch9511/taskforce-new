import Auth
import Foundation
import Testing
@testable import TaskforceKit

struct GoogleSignInConfigTests {
    let clientID = "123456-abcDEF.apps.googleusercontent.com"
    let scheme = "com.googleusercontent.apps.123456-abcDEF"

    func info(clientID: String?, schemes: [String]) -> [String: Any] {
        var info: [String: Any] = [
            "CFBundleURLTypes": [
                ["CFBundleURLName": "dev.taskforcelabs.taskforce", "CFBundleURLSchemes": ["taskforce"]],
                ["CFBundleURLName": "Google Sign-In", "CFBundleURLSchemes": schemes],
            ],
        ]
        if let clientID { info["GIDClientID"] = clientID }
        return info
    }

    @Test func readsClientIDWhenCallbackSchemeIsRegistered() throws {
        let config = try #require(GoogleSignInConfig(infoDictionary: info(clientID: clientID, schemes: [scheme])))
        #expect(config.clientID == clientID)
        #expect(config.callbackScheme == "com.googleusercontent.apps.123456-abcdef")
    }

    /// CI · 기여자 빌드: xcconfig 값이 비어 있으면 버튼을 숨긴다
    @Test func emptyOrUnresolvedClientIDHidesGoogle() {
        #expect(GoogleSignInConfig(infoDictionary: info(clientID: nil, schemes: [scheme])) == nil)
        #expect(GoogleSignInConfig(infoDictionary: info(clientID: "", schemes: [""])) == nil)
        #expect(GoogleSignInConfig(infoDictionary: info(clientID: "  ", schemes: [scheme])) == nil)
        #expect(GoogleSignInConfig(infoDictionary: info(clientID: "$(GOOGLE_IOS_CLIENT_ID)", schemes: [scheme])) == nil)
        #expect(GoogleSignInConfig(infoDictionary: info(clientID: "<client id>", schemes: [scheme])) == nil)
    }

    /// scheme이 빠지거나 다른 클라이언트 것이면 SDK가 로그인 때 예외를 던지므로 숨긴다
    @Test func missingOrMismatchedSchemeHidesGoogle() {
        #expect(GoogleSignInConfig(infoDictionary: info(clientID: clientID, schemes: [])) == nil)
        #expect(GoogleSignInConfig(infoDictionary: info(clientID: clientID, schemes: ["com.googleusercontent.apps.999-other"])) == nil)
        #expect(GoogleSignInConfig(infoDictionary: ["GIDClientID": clientID]) == nil)
    }

    @Test func schemeMatchIgnoresCase() {
        #expect(GoogleSignInConfig(infoDictionary: info(clientID: clientID, schemes: [scheme.uppercased()])) != nil)
    }

    @Test func callbackSchemeReversesDotSeparatedParts() {
        #expect(GoogleSignInConfig.callbackScheme(for: "923900348266-iopmhbf1foor213n1jc3a8tv6v4fti82.apps.googleusercontent.com")
            == "com.googleusercontent.apps.923900348266-iopmhbf1foor213n1jc3a8tv6v4fti82")
    }

    @Test func handlesOnlyGoogleCallbacks() throws {
        let config = try #require(GoogleSignInConfig(infoDictionary: info(clientID: clientID, schemes: [scheme])))
        #expect(config.handles(URL(string: "com.googleusercontent.apps.123456-abcdef:/oauth2callback?code=x")!))
        #expect(config.handles(URL(string: "COM.googleusercontent.apps.123456-ABCDEF:/oauth2callback")!))
        #expect(!config.handles(URL(string: "taskforce://connections/notion?handoff=abc")!))
    }
}

struct SignInMethodsTests {
    func user(provider: String?, providers: [String] = [], identities: [String] = []) -> User {
        var appMetadata: [String: AnyJSON] = [:]
        if let provider { appMetadata["provider"] = .string(provider) }
        if !providers.isEmpty { appMetadata["providers"] = .array(providers.map(AnyJSON.string)) }
        let userID = UUID()
        return User(
            id: userID, appMetadata: appMetadata, userMetadata: [:], aud: "authenticated", createdAt: Date(), updatedAt: Date(),
            identities: identities.map {
                UserIdentity(id: "sub-\($0)", identityId: UUID(), userId: userID, identityData: [:], provider: $0, createdAt: nil, lastSignInAt: nil, updatedAt: nil)
            }
        )
    }

    @Test func googleAccountSkipsAppleReauthorization() {
        let methods = SignInMethods(user: user(provider: "google", providers: ["google"], identities: ["google"]))
        #expect(methods.hasGoogle)
        #expect(!methods.needsAppleReauthorization)
        #expect(methods.accountLabel == "Google Account")
    }

    @Test func appleAccountReauthorizesWithApple() {
        let methods = SignInMethods(user: user(provider: "apple", providers: ["apple"], identities: ["apple"]))
        #expect(!methods.hasGoogle)
        #expect(methods.needsAppleReauthorization)
        #expect(methods.accountLabel == "Apple ID")
    }

    /// 같은 이메일로 Apple · Google을 모두 쓴 계정: 둘 다 폐기한다
    @Test func linkedAccountHasBoth() {
        let methods = SignInMethods(user: user(provider: "apple", providers: ["apple", "google"]))
        #expect(methods.providers == ["apple", "google"])
        #expect(methods.hasGoogle)
        #expect(methods.needsAppleReauthorization)
        #expect(methods.accountLabel == "Apple ID")
    }

    /// App Store 심사 계정 (이메일 · 비밀번호): Apple 재확인을 받지 않는다 (docs/go-live/app-store.md 6장 3번)
    @Test func emailAccountSkipsAppleReauthorization() {
        let methods = SignInMethods(user: user(provider: "email", providers: ["email"]))
        #expect(!methods.needsAppleReauthorization)
        #expect(!methods.hasGoogle)
        #expect(methods.accountLabel == "Email")
    }

    @Test func unknownKeepsAppleReauthorization() {
        #expect(SignInMethods(user: user(provider: nil)) == .unknown)
        #expect(SignInMethods.unknown.needsAppleReauthorization)
        #expect(!SignInMethods.unknown.hasGoogle)
    }
}

struct AccountDeletionPlanTests {
    let google = SignInMethods(providers: ["google"], primary: "google")
    let apple = SignInMethods(providers: ["apple"], primary: "apple")
    let email = SignInMethods(providers: ["email"], primary: "email")

    struct Offline: Error {}

    /// Google로 가입한 뒤 다른 기기에서 Apple을 이은 계정: 세션에는 google뿐이어도 새로 읽은 사용자로 Apple 토큰을 폐기한다
    @Test func freshUserWithLinkedAppleReauthorizesWithApple() async {
        let fresh = SignInMethodsTests().user(provider: "google", providers: ["google", "apple"])
        let plan = await AccountDeletionPlan.make(cached: google) { fresh }
        #expect(plan == AccountDeletionPlan(fresh: SignInMethods(providers: ["google", "apple"], primary: "google"), cached: google))
        #expect(plan.reauthorizeWithApple)
        #expect(plan.disconnectGoogle)
    }

    /// 새로 읽지 못하면 Apple 재확인을 받는다 (Google 폐기는 세션의 방식으로)
    @Test func unreadableUserFallsBackToAskingApple() async {
        let plan = await AccountDeletionPlan.make(cached: google) { throw Offline() }
        #expect(plan.reauthorizeWithApple)
        #expect(plan.disconnectGoogle)
        let emailPlan = await AccountDeletionPlan.make(cached: email) { throw Offline() }
        #expect(emailPlan.reauthorizeWithApple)
        #expect(!emailPlan.disconnectGoogle)
    }

    /// 새로 읽은 사용자에 Apple이 없어도 세션에 있으면 Apple 재확인을 받는다 (App Store 5.1.1(v))
    @Test func cachedAppleStillReauthorizesWithApple() async {
        let linked = SignInMethods(providers: ["google", "apple"], primary: "google")
        let fresh = SignInMethodsTests().user(provider: "google", providers: ["google"])
        let plan = await AccountDeletionPlan.make(cached: linked) { fresh }
        #expect(plan.reauthorizeWithApple)
        #expect(plan.disconnectGoogle)
        #expect(AccountDeletionPlan(fresh: google, cached: apple).reauthorizeWithApple)
        #expect(!AccountDeletionPlan(fresh: google, cached: google).reauthorizeWithApple)
        // 세션의 방식을 모르는 것은 Apple이 붙은 것이 아니다: 심사 계정(이메일)에 Apple 확인을 띄우지 않는다
        #expect(!AccountDeletionPlan(fresh: email, cached: .unknown).reauthorizeWithApple)
    }

    @Test func plansByProvider() {
        let plans = [google, apple, email, .unknown].map { AccountDeletionPlan(fresh: $0, cached: email) }
        #expect(plans.map(\.reauthorizeWithApple) == [false, true, false, true])
        #expect(plans.map(\.disconnectGoogle) == [true, false, false, false])
    }
}

struct AccountNameFillTests {
    let userID = UUID()
    let empty = Profile(displayName: nil, aliases: ["Doyun"], emails: ["me@x.co"], aiConsentAt: nil, reportsConsent: true)

    @Test func fillsEmptyNameForTheSameUser() throws {
        let fill = AccountNameFill(userID: userID, name: "Doyun Kim")
        let filled = try #require(fill.profile(filling: empty, signedInUserID: userID))
        #expect(filled.displayName == "Doyun Kim")
        #expect(filled.aliases == ["Doyun"])
        #expect(filled.emails == ["me@x.co"])
    }

    /// 그사이 다른 계정으로 바뀌었거나 로그아웃했으면 저장하지 않는다
    @Test func skipsOtherOrNoUser() {
        let fill = AccountNameFill(userID: userID, name: "Doyun Kim")
        #expect(fill.profile(filling: empty, signedInUserID: UUID()) == nil)
        #expect(fill.profile(filling: empty, signedInUserID: nil) == nil)
    }

    /// 이름이 있으면 그대로 둔다
    @Test func keepsExistingName() {
        var named = empty
        named.displayName = "김도윤"
        #expect(AccountNameFill(userID: userID, name: "Doyun Kim").profile(filling: named, signedInUserID: userID) == nil)
    }

    /// Apple · 이메일 로그인은 이름이 없어 채울 것이 없다
    @Test func onlyUsersWithANameGiveAFill() {
        let noName = SignInMethodsTests().user(provider: "apple", providers: ["apple"])
        #expect(AccountNameFill(user: noName) == nil)
    }
}

struct AccountNameTests {
    /// Supabase가 Google ID 토큰으로 채우는 user_metadata 모양 (supabase/auth `parseGoogleIDToken`)
    @Test func readsGoogleFullName() {
        let metadata: [String: AnyJSON] = [
            "iss": "https://accounts.google.com", "sub": "1234", "provider_id": "1234",
            "name": "Doyun Kim", "full_name": "Doyun Kim", "email": "doyun@example.com", "email_verified": true,
            "picture": "https://lh3.googleusercontent.com/a/x", "avatar_url": "https://lh3.googleusercontent.com/a/x",
        ]
        #expect(AccountName.from(metadata: metadata) == "Doyun Kim")
    }

    @Test func fallsBackToNameAndTrims() {
        #expect(AccountName.from(metadata: ["full_name": "  ", "name": " 김도윤 "]) == "김도윤")
    }

    /// Apple · 이메일 로그인에는 이름이 없다 (이메일 앞부분으로 대신하지 않는다)
    @Test func noNameIsNil() {
        #expect(AccountName.from(metadata: [:]) == nil)
        #expect(AccountName.from(metadata: ["email": "abc@privaterelay.appleid.com", "email_verified": true]) == nil)
    }
}
