import Foundation
import Synchronization
import Testing
@testable import TaskforceKit

/// 테스트마다 다른 호스트를 써서 병렬로 돌아도 응답이 섞이지 않게 한다.
final class StubProtocol: URLProtocol {
    struct Recorded: Sendable {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data?
    }

    struct Reply: Sendable {
        let status: Int
        let body: String
    }

    private static let state = Mutex<(replies: [String: Reply], requests: [String: [Recorded]])>(([:], [:]))

    static func register(host: String, reply: Reply) {
        state.withLock { $0.replies[host] = reply }
    }

    static func requests(host: String) -> [Recorded] {
        state.withLock { $0.requests[host] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        let recorded = Recorded(
            method: request.httpMethod ?? "GET",
            url: request.url!,
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody ?? request.httpBodyStream.map(Self.read)
        )
        let reply = Self.state.withLock { state -> Reply? in
            state.requests[host, default: []].append(recorded)
            return state.replies[host]
        } ?? Reply(status: 500, body: "")
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

struct APIClientTests {
    let host = "t\(UUID().uuidString.lowercased().prefix(8)).test"

    func client(status: Int = 200, body: String = "{}", token: @escaping APIClient.TokenProvider = { "token-123" }) -> APIClient {
        StubProtocol.register(host: host, reply: .init(status: status, body: body))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return APIClient(baseURL: URL(string: "https://\(host)")!, session: URLSession(configuration: configuration), token: token)
    }

    var last: StubProtocol.Recorded? { StubProtocol.requests(host: host).last }

    func json(_ data: Data?) throws -> [String: Any] {
        let body = try #require(data)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test func nowSendsBearerToken() async throws {
        let response = try await client(body: Fixtures.nowWithWeeklyCheck).now()
        #expect(response.now.count == 2)
        let request = try #require(last)
        #expect(request.method == "GET")
        #expect(request.url.absoluteString == "https://\(host)/api/v1/now")
        #expect(request.headers["Authorization"] == "Bearer token-123")
    }

    @Test func editSendsPatchWithBody() async throws {
        let action = try await client(body: #"{"action":\#(Fixtures.actionSummary)}"#)
            .editAction(id: Fixtures.actionID, ActionEdit(title: "새 제목", due: .clear))
        #expect(action.id == Fixtures.actionID)
        let request = try #require(last)
        #expect(request.method == "PATCH")
        #expect(request.url.path == "/api/v1/actions/11111111-1111-4111-8111-111111111111")
        #expect(request.headers["Content-Type"] == "application/json")
        let body = try json(request.body)
        #expect(body["title"] as? String == "새 제목")
        #expect(body["due_date"] is NSNull)
    }

    @Test func actionEndpointsUseRightPaths() async throws {
        let api = client(body: #"{"action":\#(Fixtures.actionSummary)}"#)
        _ = try await api.deleteAction(id: Fixtures.actionID)
        _ = try await api.confirmAction(id: Fixtures.actionID)
        _ = try await api.startAction(id: Fixtures.actionID)
        let calls = StubProtocol.requests(host: host).map { "\($0.method) \($0.url.path)" }
        #expect(calls == [
            "DELETE /api/v1/actions/11111111-1111-4111-8111-111111111111",
            "POST /api/v1/actions/11111111-1111-4111-8111-111111111111/confirm",
            "POST /api/v1/actions/11111111-1111-4111-8111-111111111111/start",
        ])
    }

    @Test func setProgressPostsTheState() async throws {
        let api = client(body: #"{"action":\#(Fixtures.actionSummary)}"#)
        for state in WorkState.allCases {
            let action = try await api.setProgress(Fixtures.actionID, state: state)
            #expect(action.id == Fixtures.actionID)
        }
        let requests = StubProtocol.requests(host: host)
        #expect(requests.map { "\($0.method) \($0.url.path)" } == Array(
            repeating: "POST /api/v1/actions/11111111-1111-4111-8111-111111111111/progress", count: 3
        ))
        #expect(requests.map { $0.headers["Content-Type"] } == Array(repeating: "application/json", count: 3))
        #expect(try requests.map { try json($0.body)["state"] as? String } == ["to_do", "in_progress", "done"])
    }

    @Test func setProgressSurfacesServerErrors() async throws {
        let api = client(status: 404, body: #"{"error":{"code":"not_found","message":"없음"}}"#)
        await #expect(throws: APIError.server(status: 404, code: .notFound, message: "없음")) {
            try await api.setProgress(Fixtures.actionID, state: .done)
        }
    }

    @Test func deleteAccountSendsDelete() async throws {
        try await client(body: #"{"deleted":true}"#).deleteAccount()
        let request = try #require(last)
        #expect(request.method == "DELETE")
        #expect(request.url.path == "/api/v1/account")
        #expect(request.headers["Authorization"] == "Bearer token-123")
        // Apple 확인을 취소했으면 본문 없이 (서버는 토큰 폐기 없이 지운다)
        #expect(request.body == nil || request.body?.isEmpty == true)
    }

    @Test func deleteAccountSendsAppleAuthorizationCode() async throws {
        try await client(body: #"{"deleted":true}"#).deleteAccount(authorizationCode: "c0de.apple")
        let request = try #require(last)
        #expect(request.method == "DELETE")
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(try json(request.body) as NSDictionary == ["apple_authorization_code": "c0de.apple"] as NSDictionary)
    }

    @Test func handoff() async throws {
        let response = try await client(body: Fixtures.handoff).handoff(id: Fixtures.actionID)
        #expect(response.title == "투자 자료 보내기")
        #expect(last?.url.path == "/api/v1/actions/11111111-1111-4111-8111-111111111111/handoff")
    }

    @Test func reportMissingSendsQuote() async throws {
        let result = try await client(body: Fixtures.missingCreated).reportMissing(sourceID: Fixtures.sourceID, quote: "자료 금요일까지")
        #expect(result.status == .created)
        let request = try #require(last)
        #expect(request.method == "POST")
        #expect(request.url.path == "/api/v1/sources/22222222-2222-4222-8222-222222222222/missing")
        #expect(try json(request.body) as NSDictionary == ["quote": "자료 금요일까지"] as NSDictionary)
    }

    @Test func createActionWithoutDueOrSource() async throws {
        let result = try await client(status: 201, body: #"{"action":\#(Fixtures.actionSummary),"status":"created"}"#)
            .createAction(title: "Send deck to Mina")
        #expect(result.action.id == Fixtures.actionID)
        #expect(result.status == .created)
        let request = try #require(last)
        #expect(request.method == "POST")
        #expect(request.url.path == "/api/v1/actions")
        #expect(request.headers["Authorization"] == "Bearer token-123")
        #expect(request.headers["Content-Type"] == "application/json")
        // 기한 없음은 null, 원문을 고르지 않았으면 source_id · quote 키가 없다
        #expect(try json(request.body) as NSDictionary == ["title": "Send deck to Mina", "due_date": NSNull()] as NSDictionary)
    }

    @Test func createActionWithDueAndSourceQuote() async throws {
        _ = try await client(status: 201, body: #"{"action":\#(Fixtures.actionSummary)}"#).createAction(
            title: "투자 자료 보내기", dueDate: LocalDate("2026-10-02")!, sourceID: Fixtures.sourceID, quote: "자료 금요일까지"
        )
        let request = try #require(last)
        #expect(try json(request.body) as NSDictionary == [
            "title": "투자 자료 보내기",
            "due_date": "2026-10-02",
            "source_id": "22222222-2222-4222-8222-222222222222",
            "quote": "자료 금요일까지",
        ] as NSDictionary)
    }

    @Test func createActionAlreadyTrackedReturnsExistingAction() async throws {
        let result = try await client(status: 200, body: #"{"action":\#(Fixtures.actionSummary),"status":"already_tracked"}"#)
            .createAction(title: "투자 자료 보내기", sourceID: Fixtures.sourceID, quote: "자료 금요일까지")
        #expect(result.status == .alreadyTracked)
        #expect(result.action.id == Fixtures.actionID)
    }

    /// status가 없는 옛 서버 · 모르는 값은 추가된 것으로 본다
    @Test(arguments: [#"{"action":\#(Fixtures.actionSummary)}"#, #"{"action":\#(Fixtures.actionSummary),"status":"merged"}"#])
    func createActionMissingOrUnknownStatusIsCreated(_ body: String) async throws {
        let result = try await client(status: 201, body: body).createAction(title: "Send deck to Mina")
        #expect(result.status == .created)
        #expect(result.action.id == Fixtures.actionID)
    }

    @Test func createActionMissingSourceIsNotFound() async throws {
        let api = client(status: 404, body: #"{"error":{"code":"not_found","message":"원문이 없습니다."}}"#)
        do {
            _ = try await api.createAction(title: "a", sourceID: Fixtures.sourceID, quote: "b")
            Issue.record("오류가 나야 함")
        } catch let error as APIError {
            #expect(error == .server(status: 404, code: .notFound, message: "원문이 없습니다."))
            #expect(error.userMessage == "Not found. It may have been removed.")
        }
    }

    @Test func weeklyCheckAndAppOpenedAccept204() async throws {
        let api = client(status: 204, body: "")
        try await api.answerWeeklyCheck(weekStart: LocalDate("2026-09-21")!, answer: .skipped)
        try await api.appOpened()
        let requests = StubProtocol.requests(host: host)
        #expect(requests.map(\.url.path) == ["/api/v1/weekly-check", "/api/v1/metric-events"])
        #expect(try json(requests[0].body) as NSDictionary == ["week_start": "2026-09-21", "answer": "skipped"] as NSDictionary)
        #expect(try json(requests[1].body) as NSDictionary == ["type": "app_opened"] as NSDictionary)
    }

    @Test func decodesConflict() async throws {
        let api = client(status: 409, body: #"{"error":{"code":"conflict","message":"다른 곳에서 바뀌었습니다."}}"#)
        do {
            _ = try await api.editAction(id: Fixtures.actionID, ActionEdit(status: .done))
            Issue.record("오류가 나야 함")
        } catch let error as APIError {
            #expect(error == .server(status: 409, code: .conflict, message: "다른 곳에서 바뀌었습니다."))
            #expect(error.isConflict)
        }
    }

    @Test func decodesInvalidRequest() async throws {
        let api = client(status: 400, body: #"{"error":{"code":"invalid_request","message":"구절이 원문에 없습니다."}}"#)
        await #expect(throws: APIError.server(status: 400, code: .invalidRequest, message: "구절이 원문에 없습니다.")) {
            _ = try await api.reportMissing(sourceID: Fixtures.sourceID, quote: "없는 말")
        }
    }

    @Test func nonEnvelopeErrorKeepsStatus() async throws {
        let api = client(status: 502, body: "<html>Bad gateway</html>")
        await #expect(throws: APIError.unexpectedStatus(502)) { _ = try await api.now() }
    }

    @Test func unknownErrorCodeFallsBackToStatus() {
        let data = Data(#"{"error":{"code":"brand_new","message":"m"}}"#.utf8)
        #expect(APIClient.error(status: 409, data: data).isConflict)
        #expect(APIClient.error(status: 500, data: data) == .server(status: 500, code: .internalError, message: "m"))
    }

    @Test func badBodyIsDecodingError() async throws {
        let api = client(body: #"{"now": "nope"}"#)
        await #expect {
            _ = try await api.now()
        } throws: { error in
            if case .decoding = error as? APIError { return true }
            return false
        }
    }

    @Test func missingSessionIsNotSignedIn() async throws {
        struct NoSession: Error {}
        let api = client(token: { throw NoSession() })
        await #expect(throws: APIError.notSignedIn) { _ = try await api.now() }
        #expect(StubProtocol.requests(host: host).isEmpty)
    }

    @Test func offlineTokenRefreshIsTransportNotSignedOut() async throws {
        let api = client(token: { throw URLError(.notConnectedToInternet) })
        await #expect {
            _ = try await api.now()
        } throws: { error in
            if case .transport = error as? APIError { return true }
            return false
        }
        #expect(StubProtocol.requests(host: host).isEmpty)
    }

    @Test func cancelledTokenRefreshIsCancellation() async throws {
        let api = client(token: { throw URLError(.cancelled) })
        await #expect(throws: CancellationError.self) { _ = try await api.now() }
    }

    @Test func tokenProviderAPIErrorPassesThrough() async throws {
        let api = client(token: { throw APIError.unexpectedStatus(503) })
        await #expect(throws: APIError.unexpectedStatus(503)) { _ = try await api.now() }
    }

    @Test func rateLimitedIsFriendly() async throws {
        let api = client(status: 429, body: #"{"error":{"code":"rate_limited","message":"Too many reports"}}"#)
        do {
            _ = try await api.reportMissing(sourceID: Fixtures.sourceID, quote: "자료 금요일까지")
            Issue.record("오류가 나야 함")
        } catch let error as APIError {
            #expect(error == .server(status: 429, code: .rateLimited, message: "Too many reports"))
            #expect(error.userMessage == "Too many requests. Try again in a moment.")
        }
    }

    @Test func rateLimitWithoutEnvelopeIsStillRateLimited() {
        #expect(APIClient.error(status: 429, data: Data("Too Many Requests".utf8)) == .server(status: 429, code: .rateLimited, message: ""))
        #expect(APIClient.error(status: 429, data: Data(#"{"error":{"code":"brand_new","message":"m"}}"#.utf8)) == .server(status: 429, code: .rateLimited, message: "m"))
    }
}
