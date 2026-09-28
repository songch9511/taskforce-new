import Foundation
import Testing
@testable import TaskforceKit

/// go live에 새로 붙은 엔드포인트: 연결 시작 · 원해요 · 동의 · 프로필 · 원문 보내기 · 물어보기
struct APIClientGoLiveTests {
    let host = "g\(UUID().uuidString.lowercased().prefix(8)).test"

    func client(status: Int = 200, body: String = "{}") -> APIClient {
        StubProtocol.register(host: host, reply: .init(status: status, body: body))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return APIClient(baseURL: URL(string: "https://\(host)")!, session: URLSession(configuration: configuration)) { "token-123" }
    }

    var requests: [StubProtocol.Recorded] { StubProtocol.requests(host: host) }

    func json(_ data: Data?) throws -> NSDictionary {
        let body = try #require(data)
        return try #require(try JSONSerialization.jsonObject(with: body) as? NSDictionary)
    }

    @Test func startConnectionReturnsAuthorizeURL() async throws {
        let url = try await client(body: #"{"url":"https://api.notion.com/v1/oauth/authorize?state=abc"}"#).startConnection(.notion)
        #expect(url.host == "api.notion.com")
        #expect(requests.last?.method == "POST")
        #expect(requests.last?.url.path == "/api/v1/connections/notion/start")
    }

    @Test func completeConnectionSendsHandoff() async throws {
        let status = try await client(body: #"{"status":"connected_empty"}"#).completeConnection(.notion, handoff: "h_123")
        #expect(status == .connectedEmpty)
        let request = try #require(requests.last)
        #expect(request.method == "POST")
        #expect(request.url.path == "/api/v1/connections/notion/complete")
        #expect(request.headers["Authorization"] == "Bearer token-123")
        #expect(try json(request.body) == ["handoff": "h_123"] as NSDictionary)
    }

    @Test func completeConnectionExpiredIsRetry() async throws {
        let api = client(status: 404, body: #"{"error":{"code":"not_found","message":"없음"}}"#)
        do {
            _ = try await api.completeConnection(.google, handoff: "old")
            Issue.record("오류가 나야 함")
        } catch let error as APIError {
            #expect(ConnectionCompleteFailure.classify(error) == .failed(ConnectionCompleteFailure.retryMessage))
        }
    }

    @Test func startConnectionNotReadyIsComingSoon() async throws {
        let api = client(status: 400, body: #"{"error":{"code":"invalid_request","message":"아직 준비되지 않았습니다"}}"#)
        do {
            _ = try await api.startConnection(.slack)
            Issue.record("오류가 나야 함")
        } catch let error as APIError {
            #expect(ConnectionStartFailure.classify(error) == .comingSoon)
        }
    }

    @Test func consentAndRequestsAccept204() async throws {
        let api = client(status: 204, body: "")
        try await api.giveAIConsent()
        try await api.withdrawAIConsent()
        try await api.requestConnection(.linear)
        try await api.syncConnections()
        try await api.disconnect(connectionID: Fixtures.actionID)
        #expect(requests.map { "\($0.method) \($0.url.path)" } == [
            "POST /api/v1/consent",
            "DELETE /api/v1/consent",
            "POST /api/v1/connection-requests",
            "POST /api/v1/connections/sync",
            "DELETE /api/v1/connections/11111111-1111-4111-8111-111111111111",
        ])
        #expect(try json(requests[0].body) == ["ai_processing": true] as NSDictionary)
        #expect(try json(requests[2].body) == ["provider": "linear"] as NSDictionary)
    }

    @Test func profileRoundTrip() async throws {
        let api = client(body: #"{"display_name":"김도윤","aliases":["Doyun"],"emails":[],"ai_consent_at":null}"#)
        let profile = try await api.profile()
        #expect(profile.displayName == "김도윤")
        _ = try await api.saveProfile(profile)
        #expect(requests.last?.method == "PUT")
        #expect(requests.last?.url.path == "/api/v1/profile")
        #expect(try json(requests.last?.body) == ["display_name": "김도윤", "aliases": ["Doyun"], "emails": []] as NSDictionary)
    }

    @Test func createSourceAndAsk() async throws {
        let api = client(status: 202, body: #"{"source_id":"22222222-2222-4222-8222-222222222222","status":"pending"}"#)
        let created = try await api.createSource(CreateSourceRequest(kind: .message, text: "금요일까지 보내 주세요", title: "금요일까지 보내 주세요"))
        #expect(created.sourceID == Fixtures.sourceID)
        #expect(requests.last?.url.path == "/api/v1/sources")

        let asker = client(body: #"{"answer":"금요일이에요.","unknown":false,"citations":[]}"#)
        let answer = try await asker.ask("투자 자료 언제까지?")
        #expect(answer.answer == "금요일이에요.")
        #expect(requests.last?.url.path == "/api/v1/ask")
        #expect(try json(requests.last?.body) == ["question": "투자 자료 언제까지?"] as NSDictionary)
    }

    @Test func syncWaitsForTheServerAndBusyIsNotAnError() async throws {
        let api = client(status: 429, body: #"{"error":{"code":"rate_limited","message":"이미 동기화 중이거나 방금 동기화했습니다."}}"#)
        do {
            try await api.syncConnections()
            Issue.record("오류가 나야 함")
        } catch let error as APIError {
            #expect(SyncNowFailure.classify(error) == .alreadySyncing)
        }
        // 서버가 끝날 때까지(최대 4분) 답하지 않아 기본 60초에 끊기지 않게
        #expect(requests.last?.timeout == 300)
        #expect(requests.last?.url.path == "/api/v1/connections/sync")
    }

    @Test func registersAndUnregistersDevice() async throws {
        let api = client(status: 204, body: "")
        let registration = DeviceRegistration(token: "a1b2c3d4e5f60718293a4b5c6d7e8f90", platform: .ios, environment: .sandbox, appVersion: "0.1.0 (1)")
        try await api.registerDevice(registration)
        try await api.unregisterDevice(token: registration.token)
        #expect(requests.map { "\($0.method) \($0.url.path)" } == ["POST /api/v1/devices", "DELETE /api/v1/devices"])
        #expect(try json(requests[0].body) == [
            "token": "a1b2c3d4e5f60718293a4b5c6d7e8f90", "platform": "ios", "environment": "sandbox", "app_version": "0.1.0 (1)",
        ] as NSDictionary)
        #expect(try json(requests[1].body) == ["token": "a1b2c3d4e5f60718293a4b5c6d7e8f90"] as NSDictionary)
    }

    @Test func consentRequiredIsConflict() async throws {
        let api = client(status: 409, body: #"{"error":{"code":"conflict","message":"동의가 필요합니다"}}"#)
        do {
            _ = try await api.ask("무엇?")
            Issue.record("오류가 나야 함")
        } catch let error as APIError {
            #expect(error.isConsentRequired)
        }
    }
}
