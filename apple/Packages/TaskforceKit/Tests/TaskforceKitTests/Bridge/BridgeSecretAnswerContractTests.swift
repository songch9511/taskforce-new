#if os(macOS)
import Foundation
import Testing
@testable import TaskforceKit

/// OA D4b-m-2: `POST /api/v1/bridge/answer-local`의 Swift 짝 (DTO · 요청 모양 · 응답 · 오류). 기준 JSON은 서버 `ANSWER_LOCAL_REQUEST_JSON`의 사본이다 (`AnswerLocalFixtures`).
struct BridgeSecretAnswerContractTests {
    typealias Fx = AnswerLocalFixtures

    private static let user = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private static let secret = "c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0MTI"

    private struct Harness {
        let host: String
        let client: BridgeClient

        init(scheme: String = "https", handler: @escaping @Sendable (StubURLProtocol.Captured) -> StubURLProtocol.Reply) {
            host = "\(UUID().uuidString.lowercased()).answerlocal.test"
            StubURLProtocol.install(host: host, handler)
            client = BridgeClient(
                baseURL: URL(string: "\(scheme)://\(host)")!, session: StubURLProtocol.session(), expectedUserID: BridgeSecretAnswerContractTests.user,
                bearer: { BridgeBearer(userID: BridgeSecretAnswerContractTests.user, accessToken: "user-jwt") }
            )
        }

        var requests: [StubURLProtocol.Captured] { StubURLProtocol.captured(host: host) }
    }

    private func ok(_ json: String) -> StubURLProtocol.Reply { StubURLProtocol.Reply(status: 200, headers: [:], body: Data(json.utf8)) }

    private var request: BridgeV1AnswerLocalRequest {
        BridgeV1AnswerLocalRequest(bridgeID: Fx.bridgeID, agentTaskID: Fx.taskID, requestDigest: Fx.knownIDs[0].digest)
    }

    // MARK: digest

    @Test func swiftComputesTheServersKnownDigestsIncludingTheMultibyteOne() {
        for known in Fx.knownIDs {
            #expect(AgentQuestionRules.requestDigest(known.providerRequestID) == known.digest, Comment(rawValue: known.providerRequestID))
            #expect(known.digest.count == 64 && known.digest == known.digest.lowercased())
        }
        #expect(Fx.knownIDs[1].providerRequestID.utf8.count > Fx.knownIDs[1].providerRequestID.count, "둘째는 UTF-8 멀티바이트다")
    }

    // MARK: 요청 본문

    @Test func theBodyHasExactlyThreeKeysAndIsTheServersReferenceJSONAndIsUnder512Bytes() throws {
        let data = try TaskforceJSON.encoder().encode(request)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["bridge_id", "agent_task_id", "request_digest"] && object.count == 3)
        let reference = try #require(try JSONSerialization.jsonObject(with: Data(Fx.requestJSON.utf8)) as? [String: String])
        #expect(object as? [String: String] == reference, "서버 기준 JSON과 같다")
        #expect(data.count <= 512, "서버 상한 512바이트 (실제 \(data.count))")
        for known in Fx.knownIDs { #expect(!String(decoding: data, as: UTF8.self).contains(known.providerRequestID), "provider_request_id는 본문에 없다") }
    }

    // MARK: 응답

    @Test func theFiveServerResponsesDecode() throws {
        let decoder = TaskforceJSON.decoder()
        func decode(_ json: String) throws -> BridgeV1AnswerLocalResponse { try decoder.decode(BridgeV1AnswerLocalResponse.self, from: Data(json.utf8)) }
        let byName = Dictionary(uniqueKeysWithValues: Fx.responses.map { ($0.name, $0.json) })
        #expect(try decode(try #require(byName["answered"])) == .answered(stepID: Fx.stepID))
        #expect(try decode(try #require(byName["duplicate"])) == .duplicate(stepID: Fx.stepID))
        #expect(try decode(try #require(byName["stale_question_closed"])) == .stale(reason: .questionClosed))
        #expect(try decode(try #require(byName["stale_not_live"])) == .stale(reason: .notLive))
        #expect(try decode(try #require(byName["stale_not_secret"])) == .stale(reason: .notSecret))
        #expect(Fx.responses.count == 5)
    }

    @Test func anUnknownStatusOrReasonIsKeptAsUnknownAndNeverCrashes() throws {
        let decoder = TaskforceJSON.decoder()
        #expect(try decoder.decode(BridgeV1AnswerLocalResponse.self, from: Data(#"{"status":"future_thing"}"#.utf8)) == .unknown(status: "future_thing"))
        #expect(try decoder.decode(BridgeV1AnswerLocalResponse.self, from: Data(#"{"status":"stale","reason":"new_reason"}"#.utf8)) == .stale(reason: .unknown("new_reason")))
        #expect(throws: (any Error).self) { try decoder.decode(BridgeV1AnswerLocalResponse.self, from: Data(#"{"status":"answered"}"#.utf8)) }
    }

    // MARK: answerLocal 요청

    @Test func answerLocalIsAPostToTheConstantRouteWithNoQueryAndBothCredentialsAsHeaders() async throws {
        let harness = Harness { _ in ok(Fx.responses[0].json) }
        let response = try await harness.client.answerLocal(request, secret: Self.secret)
        #expect(response == .answered(stepID: Fx.stepID))
        let captured = try #require(harness.requests.first)
        #expect(harness.requests.count == 1)
        let sent = captured.request
        #expect(sent.httpMethod == "POST" && sent.url?.path() == "/api/v1/bridge/answer-local" && sent.url?.query == nil)
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer user-jwt")
        #expect(sent.value(forHTTPHeaderField: "X-Taskforce-Bridge-Secret") == Self.secret)
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(sent.timeoutInterval == 10, "D4bm2-03: 10초")
        let object = try #require(try JSONSerialization.jsonObject(with: captured.body) as? [String: Any])
        #expect(Set(object.keys) == ["bridge_id", "agent_task_id", "request_digest"])
        #expect(captured.body.count <= 512)
        let address = try #require(sent.url).absoluteString
        #expect(!address.contains(Fx.knownIDs[0].digest), "digest도 주소에 없다")
    }

    @Test func eachServerErrorBodyBecomesItsOwnClientError() async {
        for error in Fx.errors {
            let harness = Harness { _ in StubURLProtocol.Reply(status: error.status, headers: error.status == 429 ? ["Retry-After": "9"] : [:], body: Data(error.body.utf8)) }
            do {
                _ = try await harness.client.answerLocal(request, secret: Self.secret)
                Issue.record("\(error.name) must throw")
            } catch let thrown as BridgeClientError {
                switch error.status {
                case 400: #expect(thrown == .badRequest, "\(error.name)")
                case 401: #expect(thrown == .unauthorized, "\(error.name)")
                case 403: #expect(thrown == .forbidden, "\(error.name)")
                case 404: #expect(thrown == .notFound, "\(error.name)")
                case 409: #expect(thrown == .conflict, "\(error.name)")
                default: #expect(thrown == .rateLimited(retryAfter: 9), "\(error.name)")
                }
            } catch {
                Issue.record("unexpected \(error)")
            }
        }
        #expect(Fx.errors.count == 6)
    }

    @Test func anInsecureEndpointSendsNothing() async throws {
        let harness = Harness(scheme: "http") { _ in ok(Fx.responses[0].json) }
        await #expect(throws: BridgeClientError.insecureEndpoint) { _ = try await harness.client.answerLocal(request, secret: Self.secret) }
        #expect(harness.requests.isEmpty)
    }

    @Test func aLoopbackDevServerIsAllowedOverPlainHTTP() async throws {
        let loopback = BridgeClient(
            baseURL: URL(string: "http://localhost:3000")!, session: StubURLProtocol.session(), expectedUserID: Self.user, bearer: { BridgeBearer(userID: Self.user, accessToken: "t") }
        )
        StubURLProtocol.install(host: "localhost") { _ in ok(Fx.responses[1].json) }
        let response = try await loopback.answerLocal(request, secret: Self.secret)
        #expect(response == .duplicate(stepID: Fx.stepID))
    }

    @Test func aRedirectIsNeverFollowedSoTheSecretHeaderStaysOnTheServer() async throws {
        let origin = "\(UUID().uuidString.lowercased()).origin.test"
        let elsewhere = "\(UUID().uuidString.lowercased()).elsewhere.test"
        StubURLProtocol.install(host: elsewhere) { _ in ok(Fx.responses[0].json) }
        StubURLProtocol.install(host: origin) { _ in
            StubURLProtocol.Reply(status: 307, headers: ["Location": "https://\(elsewhere)/api/v1/bridge/answer-local"], redirectTo: URL(string: "https://\(elsewhere)/api/v1/bridge/answer-local"))
        }
        let client = BridgeClient(
            baseURL: URL(string: "https://\(origin)")!, session: StubURLProtocol.session(), expectedUserID: Self.user, bearer: { BridgeBearer(userID: Self.user, accessToken: "t") }
        )
        await #expect(throws: BridgeClientError.server(status: 307)) { _ = try await client.answerLocal(request, secret: Self.secret) }
        #expect(StubURLProtocol.captured(host: elsewhere).isEmpty, "리다이렉트 대상으로 요청이 가지 않았다")
    }

    @Test func aTokenForAnotherUserNeverReachesTheNetwork() async {
        let other = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let host = "\(UUID().uuidString.lowercased()).other.test"
        StubURLProtocol.install(host: host) { _ in ok(Fx.responses[0].json) }
        let client = BridgeClient(baseURL: URL(string: "https://\(host)")!, session: StubURLProtocol.session(), expectedUserID: Self.user, bearer: { BridgeBearer(userID: other, accessToken: "t") })
        await #expect(throws: BridgeClientError.accountChanged) { _ = try await client.answerLocal(request, secret: Self.secret) }
        #expect(StubURLProtocol.captured(host: host).isEmpty)
    }
}
#endif
