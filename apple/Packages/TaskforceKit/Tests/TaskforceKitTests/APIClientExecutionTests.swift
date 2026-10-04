import Foundation
import Testing
@testable import TaskforceKit

/// 실행 쓰기 · credits (`POST /runs` · `POST /runs/:id/stop` · `GET /credits`)
struct APIClientExecutionTests {
    let host = "x\(UUID().uuidString.lowercased().prefix(8)).test"

    func client(status: Int = 200, body: String = "{}") -> APIClient {
        StubProtocol.register(host: host, reply: .init(status: status, body: body))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return APIClient(baseURL: URL(string: "https://\(host)")!, session: URLSession(configuration: configuration), token: { "token-123" })
    }

    var last: StubProtocol.Recorded? { StubProtocol.requests(host: host).last }

    @Test func createRunPostsTheRequest() async throws {
        let run = try await client(status: 202, body: #"{"run":\#(ExecutionFixtures.heldRun)}"#)
            .createRun(actionID: Fixtures.actionID, request: " 견적 회신 메일 초안 ")
        #expect(run.id == ExecutionFixtures.runID)
        let request = try #require(last)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://\(host)/api/v1/runs")
        #expect(request.headers["Authorization"] == "Bearer token-123")
        #expect(request.headers["Content-Type"] == "application/json")
        let data = try #require(request.body)
        let sent = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(sent == ["action_id": "11111111-1111-4111-8111-111111111111", "goal": "draft", "request": "견적 회신 메일 초안"])
    }

    @Test(arguments: [
        (409, "conflict", RunStartFailure.consentNeeded),
        (404, "not_found", .unavailable),
        (429, "rate_limited", .rateLimited),
    ])
    func createRunFailures(_ status: Int, _ code: String, _ expected: RunStartFailure) async throws {
        let api = client(status: status, body: #"{"error":{"code":"\#(code)","message":"설명"}}"#)
        do {
            _ = try await api.createRun(actionID: Fixtures.actionID, request: "초안")
            Issue.record("성공하면 안 된다")
        } catch let error as APIError {
            #expect(RunStartFailure(error) == expected)
            if status == 409 { #expect(error.isConsentRequired) }
        }
    }

    @Test func stopRunPostsToTheRun() async throws {
        let run = try await client(body: #"{"run":\#(ExecutionFixtures.stoppedRun)}"#).stopRun(id: ExecutionFixtures.runID)
        #expect(run.state == .stopped)
        #expect(run.stoppedAt != nil)
        let request = try #require(last)
        #expect(request.method == "POST")
        #expect(request.url.path == "/api/v1/runs/55555555-5555-4555-8555-555555555555/stop")
        #expect(request.body == nil || request.body?.isEmpty == true)
    }

    /// `since`는 UTC ISO 8601 (쿼리에 `+`가 들어가지 않게)
    @Test func creditsSendsSince() async throws {
        let since = PostgresTimestamp.parse("2026-09-30T15:00:00Z")!
        let credits = try await client(body: ExecutionFixtures.creditsAfter).credits(since: since)
        #expect(credits?.heldForRunning == 12)
        let request = try #require(last)
        #expect(request.method == "GET")
        #expect(request.url.path == "/api/v1/credits")
        #expect(request.url.query == "since=2026-09-30T15:00:00Z")
        #expect(request.headers["Authorization"] == "Bearer token-123")
    }

    @Test func creditsWithoutSince() async throws {
        let credits = try await client(body: ExecutionFixtures.creditsBefore).credits()
        #expect(credits == CreditsSummary(available: 480, reserved: 20, rateVersion: "c3-v1"))
        #expect(last?.url.absoluteString == "https://\(host)/api/v1/credits")
    }

    /// 404 = 실행을 쓸 수 없는 계정 (서버 형식 · 실행 route가 없는 옛 서버의 형식 없는 404 모두)
    @Test(arguments: [#"{"error":{"code":"not_found","message":"실행 기능을 쓸 수 없습니다."}}"#, "<html>Not Found</html>"])
    func creditsNotFoundIsUnavailable(_ body: String) async throws {
        #expect(try await client(status: 404, body: body).credits(since: Date()) == nil)
    }

    /// `since`를 받지 않으면(400) `since` 없이 한 번 더
    @Test func creditsRetriesWithoutSinceOn400() async throws {
        StubProtocol.register(host: host, reply: .init(status: 400, body: #"{"error":{"code":"invalid_request","message":"since"}}"#))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let api = APIClient(baseURL: URL(string: "https://\(host)")!, session: URLSession(configuration: configuration), token: { "t" })
        await #expect(throws: APIError.server(status: 400, code: .invalidRequest, message: "since")) {
            _ = try await api.credits(since: Date())
        }
        let urls = StubProtocol.requests(host: host).map(\.url)
        #expect(urls.count == 2)
        #expect(urls[0].query?.hasPrefix("since=") == true)
        #expect(urls[1].query == nil)
    }

    @Test func creditsOtherErrorsThrow() async throws {
        let api = client(status: 500, body: #"{"error":{"code":"internal_error","message":"x"}}"#)
        await #expect(throws: APIError.server(status: 500, code: .internalError, message: "x")) {
            _ = try await api.credits()
        }
    }

    @Test func errorStatus() {
        #expect(APIError.server(status: 404, code: .notFound, message: "").status == 404)
        #expect(APIError.unexpectedStatus(502).status == 502)
        #expect(APIError.transport("x").status == nil)
        #expect(APIError.notSignedIn.status == nil)
    }
}
