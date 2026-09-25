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
