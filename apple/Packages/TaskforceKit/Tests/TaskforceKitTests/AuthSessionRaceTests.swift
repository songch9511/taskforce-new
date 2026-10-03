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

        // Match SessionStore.signOut(): remove locally (`.local`) and complete the remote logout first.
        try await auth.signOut(scope: .local)
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

        try await auth.signOut(scope: .local)
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
        try await auth.signOut(scope: .local)
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

/// 로그아웃 범위와 다른 기기에서 지운 계정: 실제 `SessionStore` · `AppServices` 흐름으로 확인한다.
@MainActor
struct SignOutScopeTests {
    private let storageKey = "taskforce.auth.scope"

    /// 같은 계정으로 로그인한 Mac과 iPhone: Mac에서 Sign Out해도 iPhone의 세션과 토큰 갱신은 그대로다.
    /// 가짜 인증 서버는 Supabase Auth `/logout`의 범위대로 세션을 끝낸다 (local = 그 세션, global = 그 계정의 모든 세션)
    @Test func signingOutOnTheMacKeepsTheIPhoneSignedIn() async throws {
        let server = FakeAuthServer()
        let user = User(
            id: UUID(), appMetadata: [:], userMetadata: [:], aud: "authenticated",
            email: "me@example.test", createdAt: Date(), updatedAt: Date()
        )
        let mac = session(user, device: "mac")
        let phone = session(user, device: "phone")
        await server.open(mac)
        await server.open(phone)
        let macStore = SessionStore(auth: server.client(storage: try MemoryAuthStorage(session: mac, key: storageKey), key: storageKey))
        let phoneAuth = server.client(storage: try MemoryAuthStorage(session: phone, key: storageKey), key: storageKey)

        await macStore.signOut()

        #expect(await server.logoutScopes == ["local"])
        let refreshed = try await phoneAuth.refreshSession()
        #expect(refreshed.user.id == user.id)
        #expect(phoneAuth.currentSession?.refreshToken == refreshed.refreshToken)
        #expect(await server.isOpen(refreshToken: refreshed.refreshToken))
        #expect(await !server.isOpen(refreshToken: mac.refreshToken))
    }

    /// 다른 기기에서 계정을 지운 뒤 이 기기의 API 요청이 401: 인증 서버가 `user_not_found`면 이 기기의 세션만 지우고(`.local`)
    /// `onSignedOut` 정리가 그 계정으로 불린다. 화면에는 로그인 안내
    @Test func unauthorizedForADeletedAccountSignsOutThisDeviceAndCleansUp() async throws {
        let account = session(nil, device: "deleted")
        let harness = try await Harness.make(
            account: account, key: storageKey,
            auth: .init(status: 403, body: #"{"code":"user_not_found","error_code":"user_not_found","msg":"User from sub claim in JWT does not exist"}"#)
        )

        await #expect(throws: APIError.notSignedIn) { _ = try await harness.services.api.now() }
        await harness.wait(for: .signedOut)

        #expect(harness.store.state == .signedOut)
        #expect(harness.supabase.auth.currentSession == nil)
        #expect(harness.departed.ids == [account.user.id])
        let authRequests = StubProtocol.requests(host: harness.authHost).filter { $0.url.path.hasPrefix("/auth/v1/") }
        #expect(authRequests.map(\.url.path) == ["/auth/v1/user", "/auth/v1/logout"])
        #expect(authRequests.last.flatMap { URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.queryItems }
            == [URLQueryItem(name: "scope", value: "local")])
    }

    /// 인증 서버가 세션을 인정하면 401만으로는 로그아웃하지 않는다: 세션 · 화면을 두고 다시 로그인하는 길을 알린다
    @Test func unauthorizedWithALiveSessionKeepsTheSession() async throws {
        let account = session(nil, device: "live")
        let user = String(decoding: try AuthClient.Configuration.jsonEncoder.encode(account.user), as: UTF8.self)
        let harness = try await Harness.make(account: account, key: storageKey, auth: .init(status: 200, body: user))

        await #expect(throws: APIError.server(status: 401, code: .unauthorized, message: "Unauthorized")) {
            _ = try await harness.services.api.now()
        }

        #expect(harness.store.state == .signedIn(userID: account.user.id, email: account.user.email))
        #expect(harness.supabase.auth.currentSession?.user.id == account.user.id)
        #expect(harness.departed.ids.isEmpty)
        #expect(StubProtocol.requests(host: harness.authHost).map(\.url.path) == ["/auth/v1/user"])
    }

    /// 인증 서버에 닿지 못하면(오프라인) 그대로 둔다
    @Test func unauthorizedWhileAuthIsUnreachableKeepsTheSession() async throws {
        let account = session(nil, device: "unreachable")
        let harness = try await Harness.make(account: account, key: storageKey, auth: .init(status: 503, body: "<html>unavailable</html>"))

        await #expect(throws: APIError.server(status: 401, code: .unauthorized, message: "Unauthorized")) {
            _ = try await harness.services.api.now()
        }

        #expect(harness.store.state == .signedIn(userID: account.user.id, email: account.user.email))
        #expect(harness.departed.ids.isEmpty)
    }

    private func session(_ user: User?, device: String) -> Session {
        let user = user ?? User(
            id: UUID(), appMetadata: [:], userMetadata: [:], aud: "authenticated",
            email: "\(device)@example.test", createdAt: Date(), updatedAt: Date()
        )
        return Session(
            accessToken: "\(device)-access", tokenType: "bearer", expiresIn: 3600,
            expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970,
            refreshToken: "\(device)-refresh", user: user
        )
    }

    /// 앱과 같은 묶음: SupabaseClient 하나를 `SessionStore`와 `AppServices`가 함께 쓴다. 서버 API는 401로 답한다
    @MainActor
    private struct Harness {
        let supabase: SupabaseClient
        let services: AppServices
        let store: SessionStore
        let departed: Departures
        let authHost: String

        static func make(account: Session, key: String, auth reply: StubProtocol.Reply) async throws -> Harness {
            let authHost = "auth-\(UUID().uuidString.lowercased()).test"
            let apiHost = "api-\(UUID().uuidString.lowercased()).test"
            StubProtocol.register(host: authHost, reply: reply)
            StubProtocol.register(host: apiHost, reply: .init(status: 401, body: #"{"error":{"code":"unauthorized","message":"Unauthorized"}}"#))
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubProtocol.self]
            let urlSession = URLSession(configuration: configuration)
            let config = AppConfig(
                supabaseURL: URL(string: "https://\(authHost)")!,
                supabaseKey: "test-public-key",
                appGroupID: "group.test.taskforce",
                apiBaseURL: URL(string: "https://\(apiHost)")!
            )
            let supabase = SupabaseClient(
                supabaseURL: config.supabaseURL,
                supabaseKey: config.supabaseKey,
                options: SupabaseClientOptions(
                    auth: .init(storage: try MemoryAuthStorage(session: account, key: key), storageKey: key, autoRefreshToken: false),
                    global: .init(session: urlSession)
                )
            )
            let store = SessionStore(auth: supabase.auth)
            let departed = Departures()
            store.onSignedOut { departed.ids.append($0) }
            let harness = Harness(
                supabase: supabase, services: AppServices(config: config, supabase: supabase, session: urlSession),
                store: store, departed: departed, authHost: authHost
            )
            store.start()
            await harness.wait(for: .signedIn(userID: account.user.id, email: account.user.email))
            #expect(store.state == .signedIn(userID: account.user.id, email: account.user.email))
            return harness
        }

        func wait(for state: SessionStore.State) async {
            for _ in 0..<300 where store.state != state {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }
}

/// Supabase Auth의 세션 · 로그아웃 범위만 흉내 낸 서버 (refresh token 회전, `/logout?scope=`)
private actor FakeAuthServer {
    private var sessions: [Session] = []
    private(set) var logoutScopes: [String] = []
    private let url = URL(string: "https://auth-scope-\(UUID().uuidString.lowercased()).test/auth/v1")!

    func open(_ session: Session) {
        sessions.append(session)
    }

    func isOpen(refreshToken: String) -> Bool {
        sessions.contains { $0.refreshToken == refreshToken }
    }

    nonisolated func client(storage: MemoryAuthStorage, key: String) -> AuthClient {
        AuthClient(url: url, storageKey: key, localStorage: storage, fetch: { try await self.respond(to: $0) }, autoRefreshToken: false)
    }

    private func respond(to request: URLRequest) throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if url.path.hasSuffix("/logout") {
            let scope = query.first { $0.name == "scope" }?.value ?? "global"
            logoutScopes.append(scope)
            let bearer = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "")
            guard let current = sessions.first(where: { $0.accessToken == bearer }) else { return (Data(), response(url, 401)) }
            switch scope {
            case "local": sessions.removeAll { $0.accessToken == current.accessToken }
            case "others": sessions.removeAll { $0.user.id == current.user.id && $0.accessToken != current.accessToken }
            default: sessions.removeAll { $0.user.id == current.user.id }
            }
            return (Data(), response(url, 204))
        }
        if url.path.hasSuffix("/token"), query.contains(URLQueryItem(name: "grant_type", value: "refresh_token")) {
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            let token = body?["refresh_token"] as? String
            guard let index = sessions.firstIndex(where: { $0.refreshToken == token }) else {
                let error = Data(#"{"code":"refresh_token_not_found","msg":"Invalid Refresh Token: Refresh Token Not Found"}"#.utf8)
                return (error, response(url, 400))
            }
            var rotated = sessions[index]
            rotated.accessToken += "-rotated"
            rotated.refreshToken += "-rotated"
            sessions[index] = rotated
            return (try AuthClient.Configuration.jsonEncoder.encode(rotated), response(url, 200))
        }
        return (Data(), response(url, 404))
    }

    private func response(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json", "X-Supabase-Api-Version": "2024-01-01"]
        )!
    }
}
