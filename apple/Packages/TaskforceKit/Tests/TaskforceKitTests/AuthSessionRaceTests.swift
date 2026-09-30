import Auth
import Foundation
import Synchronization
import Supabase
import Testing
@testable import TaskforceKit

/// Exercises the public auth operations in the same order as the app's sign-out/sign-in flow.
struct AuthSessionRaceTests {
    private let storageKey = "taskforce.auth.race"

    @Test func lateRefreshCannotRestoreTheSignedOutAccountOrReachAppServices() async throws {
        let userA = session("A")
        let userB = session("B")
        var refreshedA = session("A-refreshed")
        refreshedA.user = userA.user
        let storage = try MemoryAuthStorage(session: userA, key: storageKey)
        let gate = RefreshResponseGate()
        let auth = authClient(storage: storage, gate: gate, refreshed: refreshedA, signedIn: userB)

        let refresh = Task { try await auth.refreshSession(refreshToken: userA.refreshToken) }
        let refreshWasSent = await gate.waitUntilEntered()
        #expect(refreshWasSent)

        // Match SessionStore.signOut(): remove locally and complete the remote logout first.
        try await auth.signOut()
        _ = try await auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(provider: .google, idToken: "mock-id-token")
        )

        await gate.release()
        _ = await refresh.result

        #expect(auth.currentSession?.user.id == userB.user.id)
        #expect(auth.currentSession?.refreshToken == userB.refreshToken)

        // AppServices obtains its bearer token from SupabaseClient.auth.session.accessToken.
        // Use a second client sharing the same device storage, as another app service would.
        let apiHost = "auth-race-\(UUID().uuidString.lowercased()).test"
        StubProtocol.register(host: apiHost, reply: .init(status: 200, body: #"{"now":[],"confirmations":[]}"#))
        let apiConfiguration = URLSessionConfiguration.ephemeral
        apiConfiguration.protocolClasses = [StubProtocol.self]
        let config = AppConfig(
            supabaseURL: URL(string: "https://\(UUID().uuidString.lowercased()).supabase.test")!,
            supabaseKey: "test-public-key",
            appGroupID: "group.test.taskforce",
            apiBaseURL: URL(string: "https://\(apiHost)/api/v1")!
        )
        let supabase = SupabaseClient(
            supabaseURL: config.supabaseURL,
            supabaseKey: config.supabaseKey,
            options: SupabaseClientOptions(
                auth: .init(storage: storage, storageKey: storageKey, autoRefreshToken: false)
            )
        )
        let services = AppServices(
            config: config,
            supabase: supabase,
            session: URLSession(configuration: apiConfiguration)
        )

        _ = try await services.api.now()
        let request = try #require(StubProtocol.requests(host: apiHost).last)
        #expect(request.headers["Authorization"] == "Bearer \(userB.accessToken)")
    }

    @Test func lateRefreshCleanupErrorCannotRemoveTheNextSignedInAccount() async throws {
        let userA = session("A")
        let userB = session("B")
        let storage = try MemoryAuthStorage(session: userA, key: storageKey)
        let gate = RefreshResponseGate()
        let auth = authClient(storage: storage, gate: gate, refreshed: nil, signedIn: userB)

        let refresh = Task { try await auth.refreshSession(refreshToken: userA.refreshToken) }
        let refreshWasSent = await gate.waitUntilEntered()
        #expect(refreshWasSent)

        try await auth.signOut()
        _ = try await auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(provider: .google, idToken: "mock-id-token")
        )

        await gate.release()
        _ = await refresh.result

        #expect(auth.currentSession?.user.id == userB.user.id)
        #expect(auth.currentSession?.refreshToken == userB.refreshToken)
    }

    @Test func refreshWithoutAnInterveningSignOutStoresTheRotatedSession() async throws {
        let userA = session("A")
        var refreshedA = session("A-refreshed")
        refreshedA.user = userA.user
        let storage = try MemoryAuthStorage(session: userA, key: storageKey)
        let gate = RefreshResponseGate()
        let auth = authClient(storage: storage, gate: gate, refreshed: refreshedA, signedIn: userA)

        let refresh = Task { try await auth.refreshSession(refreshToken: userA.refreshToken) }
        #expect(await gate.waitUntilEntered())
        await gate.release()
        let result = try await refresh.value

        #expect(result.refreshToken == refreshedA.refreshToken)
        #expect(auth.currentSession?.user.id == userA.user.id)
        #expect(auth.currentSession?.refreshToken == refreshedA.refreshToken)
    }

    @Test func lateRefreshCannotRestoreASessionAfterLogoutAlone() async throws {
        let userA = session("A")
        var refreshedA = session("A-refreshed")
        refreshedA.user = userA.user
        let storage = try MemoryAuthStorage(session: userA, key: storageKey)
        let gate = RefreshResponseGate()
        let auth = authClient(storage: storage, gate: gate, refreshed: refreshedA, signedIn: userA)

        let refresh = Task { try await auth.refreshSession(refreshToken: userA.refreshToken) }
        #expect(await gate.waitUntilEntered())
        try await auth.signOut()
        await gate.release()
        _ = await refresh.result

        #expect(auth.currentSession == nil)
    }

    private func authClient(
        storage: MemoryAuthStorage,
        gate: RefreshResponseGate,
        refreshed: Session?,
        signedIn: Session
    ) -> AuthClient {
        let url = URL(string: "https://auth-race-\(UUID().uuidString.lowercased()).test/auth/v1")!
        return AuthClient(
            url: url,
            storageKey: storageKey,
            localStorage: storage,
            fetch: { request in
                let path = request.url?.path ?? ""
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let grant = query.first(where: { $0.name == "grant_type" })?.value

                if path.hasSuffix("/token"), grant == "refresh_token" {
                    await gate.holdUntilReleased()
                    if let refreshed {
                        return (try AuthClient.Configuration.jsonEncoder.encode(refreshed), response(request, status: 200))
                    }
                    let body = Data(#"{"code":"refresh_token_not_found","message":"Refresh Token Not Found"}"#.utf8)
                    return (body, response(request, status: 400))
                }
                if path.hasSuffix("/token"), grant == "id_token" {
                    return (try AuthClient.Configuration.jsonEncoder.encode(signedIn), response(request, status: 200))
                }
                if path.hasSuffix("/logout") {
                    return (Data(), response(request, status: 204))
                }
                return (Data(), response(request, status: 404))
            },
            autoRefreshToken: false
        )
    }

    private func response(_ request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/json",
                "X-Supabase-Api-Version": "2024-01-01",
            ]
        )!
    }

    private func session(_ name: String) -> Session {
        let user = User(
            id: UUID(), appMetadata: [:], userMetadata: [:], aud: "authenticated",
            email: "\(name.lowercased())@example.test", createdAt: Date(), updatedAt: Date()
        )
        return Session(
            accessToken: "\(name)-access", tokenType: "bearer", expiresIn: 3600,
            expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970,
            refreshToken: "\(name)-refresh", user: user
        )
    }
}

private final class MemoryAuthStorage: AuthLocalStorage, Sendable {
    private let storedData: Mutex<[String: Data]>

    init(session: Session, key: String) throws {
        storedData = Mutex([key: try AuthClient.Configuration.jsonEncoder.encode(session)])
    }

    func store(key: String, value: Data) throws {
        storedData.withLock { $0[key] = value }
    }

    func retrieve(key: String) throws -> Data? {
        storedData.withLock { $0[key] }
    }

    func remove(key: String) throws {
        storedData.withLock { _ = $0.removeValue(forKey: key) }
    }
}

private actor RefreshResponseGate {
    private var hasEntered = false
    private var isReleased = false
    private var waitingForRelease: CheckedContinuation<Void, Never>?

    func holdUntilReleased() async {
        hasEntered = true
        guard !isReleased else { return }
        await withCheckedContinuation { waitingForRelease = $0 }
    }

    func waitUntilEntered(timeout: Duration = .seconds(5)) async -> Bool {
        if hasEntered { return true }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
            if hasEntered { return true }
        }
        return hasEntered
    }

    func release() {
        isReleased = true
        waitingForRelease?.resume()
        waitingForRelease = nil
    }
}
