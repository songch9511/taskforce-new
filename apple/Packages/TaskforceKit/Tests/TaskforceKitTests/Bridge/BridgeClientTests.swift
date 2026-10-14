#if os(macOS)
import Foundation
import Testing
@testable import TaskforceKit

/// BridgeClient (OA D2b 계약 2.11 · 4.1 K2): 헤더 · 상태별 오류 · Retry-After · 긴 대기 · 취소 · 요청 직전 사용자 대조
struct BridgeClientTests {
    private static let user = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private static let bridgeID = "b1111111-1111-4111-8111-111111111111"
    private static let secret = "c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0MTI"

    private struct Harness {
        let host: String
        let client: BridgeClient

        init(user: UUID = BridgeClientTests.user, bearerUser: UUID = BridgeClientTests.user, handler: @escaping @Sendable (StubURLProtocol.Captured) -> StubURLProtocol.Reply) {
            host = "\(UUID().uuidString.lowercased()).stub.test"
            StubURLProtocol.install(host: host, handler)
            client = BridgeClient(
                baseURL: URL(string: "http://\(host)")!, session: StubURLProtocol.session(), expectedUserID: user,
                bearer: { BridgeBearer(userID: bearerUser, accessToken: "user-jwt") }
            )
        }

        var requests: [StubURLProtocol.Captured] { StubURLProtocol.captured(host: host) }
    }

    private func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> StubURLProtocol.Reply {
        StubURLProtocol.Reply(status: status, headers: headers, body: Data(text.utf8))
    }

    private static let registerResponse = #"{"bridge_id":"b1111111-1111-4111-8111-111111111111","bridge_secret":"c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0MTI","heartbeat_interval_seconds":30,"unreachable_after_seconds":90,"long_poll_max_seconds":25,"connections":[]}"#
    private static let emptyCommands = #"{"commands":[],"readbacks":[],"next_cursor":0,"server_time":"2026-10-14T05:00:00Z"}"#

    // MARK: 요청 모양

    @Test func registerSendsOnlyTheUserBearerAndNeverADeviceSecret() async throws {
        let harness = Harness { _ in json(Self.registerResponse) }
        let response = try await harness.client.register(BridgeV1RegisterRequest(deviceID: Self.secret, appVersion: "0.2.0", adapters: [], connect: [], reactivate: false))
        #expect(response.bridgeID == Self.bridgeID)
        let request = try #require(harness.requests.first).request
        #expect(request.httpMethod == "POST" && request.url?.path() == "/api/v1/bridge/register")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer user-jwt")
        #expect(request.value(forHTTPHeaderField: "X-Taskforce-Bridge-Secret") == nil)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func revokeIsADeleteWithTheBridgeIDAndNoDeviceSecret() async throws {
        let harness = Harness { _ in json(#"{"status":"revoked","tasks":[]}"#) }
        _ = try await harness.client.revoke(bridgeID: Self.bridgeID)
        let captured = try #require(harness.requests.first)
        #expect(captured.request.httpMethod == "DELETE" && captured.request.url?.path() == "/api/v1/bridge/register")
        #expect(captured.request.value(forHTTPHeaderField: "X-Taskforce-Bridge-Secret") == nil)
        #expect(String(decoding: captured.body, as: UTF8.self) == #"{"bridge_id":"b1111111-1111-4111-8111-111111111111"}"#)
    }

    @Test func commandsCarryTheQueryTheDeviceSecretAndALongPollTimeout() async throws {
        let harness = Harness { _ in json(Self.emptyCommands) }
        _ = try await harness.client.commands(bridgeID: Self.bridgeID, secret: Self.secret, after: 42, wait: 25)
        _ = try await harness.client.commands(bridgeID: Self.bridgeID, secret: Self.secret, after: 0, wait: 0)
        let requests = harness.requests
        let long = try #require(requests.first).request
        #expect(long.httpMethod == "GET" && long.url?.path() == "/api/v1/bridge/commands")
        let items = URLComponents(url: long.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items == [URLQueryItem(name: "bridge_id", value: Self.bridgeID), URLQueryItem(name: "after", value: "42"), URLQueryItem(name: "wait", value: "25")])
        #expect(long.value(forHTTPHeaderField: "Authorization") == "Bearer user-jwt")
        #expect(long.value(forHTTPHeaderField: "X-Taskforce-Bridge-Secret") == Self.secret)
        #expect(long.timeoutInterval == 35, "긴 대기 25초 + 10초 여유 (route maxDuration 30)")
        #expect(requests[1].request.timeoutInterval < 35)
    }

    @Test func ackEventsAndHeartbeatCarryTheDeviceSecretAndTheirBodies() async throws {
        let harness = Harness { captured in
            switch captured.request.url?.path() {
            case "/api/v1/bridge/ack": json(#"{"status":"settled"}"#)
            case "/api/v1/bridge/events": json(#"{"results":[],"accepted_event_ids":["e1"],"retry_event_ids":[],"rejected":[]}"#)
            default: json(#"{"heartbeat_interval_seconds":30,"server_time":"2026-10-14T05:00:00Z","pending_commands":0,"unknown_task_ids":[],"missing_task_ids":[]}"#)
            }
        }
        let ack = try await harness.client.ack(BridgeV1AckRequest(bridgeID: Self.bridgeID, commandID: "c1", op: .requestClosed), secret: Self.secret)
        #expect(ack == .settled(taskState: nil))
        let events = try await harness.client.events(bridgeID: Self.bridgeID, secret: Self.secret, eventJSON: [#"{"event_id":"e1"}"#, #"{"event_id":"e2"}"#])
        #expect(events.acceptedEventIDs == ["e1"])
        _ = try await harness.client.heartbeat(
            BridgeV1HeartbeatRequest(bridgeID: Self.bridgeID, sentAt: BridgeTest.t0, appVersion: nil, tasks: [], adapters: nil), secret: Self.secret
        )
        let requests = harness.requests
        #expect(requests.map { $0.request.url?.path() } == ["/api/v1/bridge/ack", "/api/v1/bridge/events", "/api/v1/bridge/heartbeat"])
        for captured in requests {
            #expect(captured.request.httpMethod == "POST")
            #expect(captured.request.value(forHTTPHeaderField: "X-Taskforce-Bridge-Secret") == Self.secret)
            #expect(captured.request.value(forHTTPHeaderField: "Authorization") == "Bearer user-jwt")
        }
        #expect(String(decoding: requests[1].body, as: UTF8.self) == #"{"bridge_id":"b1111111-1111-4111-8111-111111111111","events":[{"event_id":"e1"},{"event_id":"e2"}]}"#)
    }

    @Test func aStoredAckBodyIsSentExactlyAsStored() async throws {
        let harness = Harness { _ in json(#"{"status":"settled"}"#) }
        let stored = #"{"bridge_id":"b1111111-1111-4111-8111-111111111111","command_id":"c1","op":"request_closed"}"#
        _ = try await harness.client.ack(bodyJSON: stored, secret: Self.secret)
        #expect(String(decoding: try #require(harness.requests.first).body, as: UTF8.self) == stored)
    }

    // MARK: 상태별 오류

    private func failure(status: Int, body: String = #"{"error":{"code":"x","message":"y"}}"#, headers: [String: String] = [:], register: Bool = false) async -> BridgeClientError? {
        let harness = Harness { _ in json(body, status: status, headers: headers) }
        do {
            if register {
                _ = try await harness.client.register(BridgeV1RegisterRequest(deviceID: Self.secret, appVersion: "1", adapters: [], connect: [], reactivate: false))
            } else {
                _ = try await harness.client.commands(bridgeID: Self.bridgeID, secret: Self.secret, after: 0, wait: 0)
            }
            return nil
        } catch let error as BridgeClientError {
            return error
        } catch {
            return nil
        }
    }

    @Test func eachStatusBecomesItsOwnError() async {
        #expect(await failure(status: 401) == .unauthorized)
        #expect(await failure(status: 403) == .forbidden)
        #expect(await failure(status: 404) == .notFound)
        #expect(await failure(status: 400) == .badRequest)
        #expect(await failure(status: 409) == .conflict)
        #expect(await failure(status: 500) == .server(status: 500))
        #expect(await failure(status: 503) == .server(status: 503))
        #expect(await failure(status: 418) == .server(status: 418))
    }

    @Test func aRegisterConflictNamedTooManyBridgesIsDistinguished() async {
        #expect(await failure(status: 409, body: #"{"error":{"code":"conflict","message":"too_many_bridges"}}"#, register: true) == .tooManyBridges)
        #expect(await failure(status: 409, body: #"{"error":{"code":"conflict","message":"other"}}"#, register: true) == .conflict)
    }

    @Test func retryAfterSecondsAreReadAndABadOrMissingValueMeansThirtySeconds() async {
        #expect(await failure(status: 429, headers: ["Retry-After": "17"]) == .rateLimited(retryAfter: 17))
        #expect(await failure(status: 429) == .rateLimited(retryAfter: 30))
        #expect(await failure(status: 429, headers: ["Retry-After": "soon"]) == .rateLimited(retryAfter: 30))
        #expect(await failure(status: 429, headers: ["Retry-After": "-5"]) == .rateLimited(retryAfter: 30))
        #expect(await failure(status: 429, headers: ["Retry-After": "0"]) == .rateLimited(retryAfter: 1))
        #expect(await failure(status: 429, headers: ["Retry-After": "999999"]) == .rateLimited(retryAfter: 3600))
        #expect(await failure(status: 429, body: "not json", headers: ["Retry-After": "9"]) == .rateLimited(retryAfter: 9))
    }

    @Test func aBodyThatDoesNotDecodeIsADecodingErrorNotACrash() async {
        let harness = Harness { _ in json(#"{"unexpected":true}"#) }
        do {
            _ = try await harness.client.commands(bridgeID: Self.bridgeID, secret: Self.secret, after: 0, wait: 0)
            Issue.record("must throw")
        } catch {
            #expect(error as? BridgeClientError == .decoding)
        }
    }

    @Test func aTransportFailureIsTransportAndKeepsNoBodyText() async {
        let harness = Harness { _ in StubURLProtocol.Reply(transportError: .notConnectedToInternet) }
        do {
            _ = try await harness.client.commands(bridgeID: Self.bridgeID, secret: Self.secret, after: 0, wait: 0)
            Issue.record("must throw")
        } catch let error as BridgeClientError {
            guard case .transport = error else { Issue.record("transport expected, got \(error)"); return }
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    // MARK: 취소

    @Test func cancellingALongPollThrowsCancellationErrorNotATransportError() async throws {
        let harness = Harness { _ in StubURLProtocol.Reply(hold: true) }
        let task = Task { try await harness.client.commands(bridgeID: Self.bridgeID, secret: Self.secret, after: 0, wait: 25) }
        for _ in 0..<200 where harness.requests.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        #expect(harness.requests.count == 1)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("must throw")
        } catch {
            #expect(error is CancellationError)
        }
    }

    // MARK: 요청 직전 사용자 대조 (ONE-TF-09 c)

    @Test func aTokenForAnotherUserNeverReachesTheNetwork() async {
        let other = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let harness = Harness(bearerUser: other) { _ in json(Self.emptyCommands) }
        do {
            _ = try await harness.client.commands(bridgeID: Self.bridgeID, secret: Self.secret, after: 0, wait: 0)
            Issue.record("must throw")
        } catch {
            #expect(error as? BridgeClientError == .accountChanged)
        }
        #expect(harness.requests.isEmpty)
    }

    @Test func aSignedOutSessionIsNotSignedInAndSendsNothing() async {
        let host = "\(UUID().uuidString.lowercased()).stub.test"
        StubURLProtocol.install(host: host) { _ in json(Self.emptyCommands) }
        let client = BridgeClient(baseURL: URL(string: "http://\(host)")!, session: StubURLProtocol.session(), expectedUserID: Self.user, bearer: { throw APIError.notSignedIn })
        do {
            _ = try await client.commands(bridgeID: Self.bridgeID, secret: Self.secret, after: 0, wait: 0)
            Issue.record("must throw")
        } catch {
            #expect(error as? BridgeClientError == .notSignedIn)
        }
        #expect(StubURLProtocol.captured(host: host).isEmpty)
    }
}
#endif
