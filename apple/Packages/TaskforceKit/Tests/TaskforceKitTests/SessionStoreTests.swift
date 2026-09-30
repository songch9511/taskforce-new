import Auth
import Foundation
import Testing
@testable import TaskforceKit

struct SessionStoreTests {
    let userID = UUID()

    /// `identities`: 연결된 로그인 방법 (`apple` · `email`)
    func user(identities: [String]? = nil, appMetadata: [String: AnyJSON] = [:]) -> User {
        User(
            id: userID, appMetadata: appMetadata, userMetadata: [:], aud: "authenticated",
            email: "me@example.com", createdAt: Date(), updatedAt: Date(),
            identities: identities?.map { provider in
                UserIdentity(
                    id: "\(provider)-sub", identityId: UUID(), userId: userID, identityData: [:],
                    provider: provider, createdAt: nil, lastSignInAt: nil, updatedAt: nil
                )
            }
        )
    }

    func session(expiresIn seconds: TimeInterval, user: User? = nil) -> Session {
        Session(
            accessToken: "access", tokenType: "bearer", expiresIn: seconds,
            expiresAt: Date().addingTimeInterval(seconds).timeIntervalSince1970,
            refreshToken: "refresh", user: user ?? self.user()
        )
    }

    @Test func noSessionIsSignedOut() {
        #expect(SessionStore.state(for: .initialSession, session: nil) == .signedOut)
    }

    @Test func signedOutEventWinsOverSession() {
        #expect(SessionStore.state(for: .signedOut, session: session(expiresIn: 3600)) == .signedOut)
    }

    @Test(arguments: [AuthChangeEvent.initialSession, .signedIn, .tokenRefreshed])
    func sessionIsSignedIn(_ event: AuthChangeEvent) {
        #expect(SessionStore.state(for: event, session: session(expiresIn: 3600))
            == .signedIn(userID: userID, email: "me@example.com"))
    }

    @Test func expiredStoredSessionStaysSignedInUntilRefreshResolves() {
        #expect(SessionStore.state(for: .initialSession, session: session(expiresIn: -60))
            == .signedIn(userID: userID, email: "me@example.com"))
    }

    /// Apple로 가입했거나 이메일 계정에 Apple이 연결된 계정
    @Test(arguments: [["apple"], ["email", "apple"]])
    func appleIdentityIsApple(_ identities: [String]) {
        #expect(SessionStore.hasAppleIdentity(user(identities: identities)))
    }

    /// App Store 심사 계정처럼 이메일로 가입한 계정: 계정 삭제 때 Apple 확인을 띄우지 않는다
    @Test func emailAccountIsNotApple() {
        #expect(!SessionStore.hasAppleIdentity(
            user(identities: ["email"], appMetadata: ["provider": "email", "providers": ["email"]])
        ))
    }

    /// 저장된 세션에 identities가 없거나 비어 있어도 app_metadata.providers로 안다
    @Test(arguments: [nil, []] as [[String]?])
    func providersCoverMissingIdentities(_ identities: [String]?) {
        #expect(SessionStore.hasAppleIdentity(
            user(identities: identities, appMetadata: ["provider": "apple", "providers": ["apple"]])
        ))
    }

    @Test func noProviderIsNotApple() {
        #expect(!SessionStore.hasAppleIdentity(user()))
    }
}

/// Keychain 권한이 없을 때처럼 저장이 늘 실패하는 저장소
private struct UnsavableStorage: AuthLocalStorage {
    struct Failure: Error {}
    func store(key: String, value: Data) throws { throw Failure() }
    func retrieve(key: String) throws -> Data? { throw Failure() }
    func remove(key: String) throws {}
}

/// 세션 하나가 저장돼 있는 저장소
private struct SavedSessionStorage: AuthLocalStorage {
    let data: Data
    func store(key: String, value: Data) throws {}
    func retrieve(key: String) throws -> Data? { data }
    func remove(key: String) throws {}
}

@MainActor
struct SessionStoreSaveTests {
    let fixtures = SessionStoreTests()

    func store(storage: any AuthLocalStorage) -> SessionStore {
        SessionStore(auth: AuthClient(
            url: URL(string: "https://example.supabase.co/auth/v1")!, localStorage: storage, autoRefreshToken: false
        ))
    }

    @Test func signInThatWasNotSavedStaysSignedOut() {
        let store = store(storage: UnsavableStorage())
        store.apply(event: .signedIn, session: fixtures.session(expiresIn: 3600))
        #expect(store.state == .signedOut)
        #expect(store.errorMessage == SessionStore.sessionNotSavedMessage)
    }

    @Test func savedSignInIsSignedIn() throws {
        let session = fixtures.session(expiresIn: 3600)
        let store = store(storage: SavedSessionStorage(data: try JSONEncoder().encode(session)))
        store.apply(event: .signedIn, session: session)
        #expect(store.state == .signedIn(userID: fixtures.userID, email: "me@example.com"))
        #expect(store.errorMessage == nil)
    }

    @Test(arguments: [(["apple"], [], true), (["email"], ["email"], false), (nil, ["apple"], true)] as [([String]?, [String], Bool)])
    func isAppleAccountReadsSavedSession(identities: [String]?, providers: [String], apple: Bool) throws {
        let user = fixtures.user(identities: identities, appMetadata: ["providers": .array(providers.map(AnyJSON.string))])
        let session = fixtures.session(expiresIn: 3600, user: user)
        let store = store(storage: SavedSessionStorage(data: try JSONEncoder().encode(session)))
        #expect(store.isAppleAccount == apple)
    }

    /// 저장된 세션을 읽지 못하면 Apple 확인을 띄운다 (폐기를 빠뜨리지 않게)
    @Test func unreadableSessionCountsAsApple() {
        #expect(store(storage: UnsavableStorage()).isAppleAccount)
    }
}
