import Auth
import Foundation
import Testing
@testable import TaskforceKit

struct SessionStoreTests {
    let userID = UUID()

    func session(expiresIn seconds: TimeInterval) -> Session {
        let user = User(
            id: userID, appMetadata: [:], userMetadata: [:], aud: "authenticated",
            email: "me@example.com", createdAt: Date(), updatedAt: Date()
        )
        return Session(
            accessToken: "access", tokenType: "bearer", expiresIn: seconds,
            expiresAt: Date().addingTimeInterval(seconds).timeIntervalSince1970,
            refreshToken: "refresh", user: user
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
}
