import Foundation
import Testing
@testable import TaskforceKit

/// OA U3 11.1: `GET /api/v2/review` · `POST /api/v2/path-conflicts/{lease_id}/resolve`의 경로 · 메서드 · 본문 · 오류 디코딩 (가짜 전송, 서버 호출 0)
struct TaskforceRequestEndpointTests {
    typealias Fx = TaskforceRequestFixtures

    let host = "x\(UUID().uuidString.lowercased().prefix(8)).test"

    func client(status: Int = 200, body: String = "{}") -> APIClient {
        StubProtocol.register(host: host, reply: .init(status: status, body: body))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return APIClient(baseURL: URL(string: "https://\(host)")!, session: URLSession(configuration: configuration), token: { "token-123" })
    }

    var last: StubProtocol.Recorded? { StubProtocol.requests(host: host).last }

    @Test func theReviewIsAPlainBearerGetOnTheV2Route() async throws {
        let response = try await client(body: Fx.review).taskforceReview()
        #expect(response.items.count == 6)
        let request = try #require(last)
        #expect(request.method == "GET" && request.url.absoluteString == "https://\(host)/api/v2/review")
        #expect(request.headers["Authorization"] == "Bearer token-123")
        #expect(request.body == nil || request.body?.isEmpty == true)
    }

    @Test func resolvePostsKeepAndConflictVersionToTheLeaseRoute() async throws {
        let reply = try await client(body: Fx.resolveResponse).resolvePathConflict(leaseID: Fx.lease, keep: .holder, conflictVersion: 2)
        #expect(reply.isResolved)
        let request = try #require(last)
        #expect(request.method == "POST")
        #expect(request.url.path == "/api/v2/path-conflicts/c0000000-0000-4000-8000-000000000001/resolve", "lease id는 소문자")
        #expect(request.headers["Authorization"] == "Bearer token-123" && request.headers["Content-Type"] == "application/json")
        let body = try #require(request.body)
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let expected = try #require(try JSONSerialization.jsonObject(with: Data(Fx.resolveRequest.utf8)) as? [String: Any])
        #expect(NSDictionary(dictionary: sent).isEqual(to: expected), "서버 시험의 요청과 같다: 키는 keep · conflict_version 둘뿐")
    }

    @Test(arguments: [(1, TaskforceConflictKeep.holder), (2_147_483_647, .later)])
    func resolveBodyAtTheBoundaries(_ version: Int, _ keep: TaskforceConflictKeep) async throws {
        _ = try await client(body: Fx.resolveResponse).resolvePathConflict(leaseID: Fx.lease, keep: keep, conflictVersion: version)
        let body = try #require(last?.body)
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(sent["conflict_version"] as? Int == version && sent["keep"] as? String == keep.rawValue)
    }

    @Test(arguments: [
        (409, "conflict", true), (404, "not_found", false), (400, "invalid_request", false), (500, "internal_error", false),
    ])
    func resolveFailuresDecodeWithTheirStatus(_ status: Int, _ code: String, _ isConflict: Bool) async throws {
        let api = client(status: status, body: #"{"error":{"code":"\#(code)","message":"설명"}}"#)
        do {
            _ = try await api.resolvePathConflict(leaseID: Fx.lease, keep: .holder, conflictVersion: 2)
            Issue.record("성공하면 안 된다")
        } catch let error as APIError {
            #expect(error.status == status && error.isConflict == isConflict)
            #expect(TaskforceRequestStore.failure(error) == (status == 409 || status == 404 ? .conflict : (status == 400 ? .rejected : .unconfirmed)))
        }
    }

    @Test func aStaleConflictBodyIsTheServersOwn409() async throws {
        let api = client(status: 409, body: Fx.resolveStale409)
        do {
            _ = try await api.resolvePathConflict(leaseID: Fx.lease, keep: .holder, conflictVersion: 1)
            Issue.record("성공하면 안 된다")
        } catch let error as APIError {
            #expect(error.isConflict && error.userMessage == ReviewCopy.conflict, "서버의 한국어 설명은 화면에 쓰지 않는다")
        }
    }

    @Test func anUnauthorizedResolveIsAnAPIErrorNotASuccess() async {
        let api = client(status: 401, body: #"{"error":{"code":"unauthorized","message":"로그인이 필요합니다"}}"#)
        do {
            _ = try await api.resolvePathConflict(leaseID: Fx.lease, keep: .later, conflictVersion: 3)
            Issue.record("성공하면 안 된다")
        } catch let error as APIError {
            #expect(error.status == 401 || error == .notSignedIn)
        } catch {
            Issue.record("APIError여야 한다: \(error)")
        }
    }

    @Test func aFeatureOffReviewIsTheFeatureOffError() async {
        let api = client(status: 404, body: #"{"error":{"code":"not_found","message":"없는 경로입니다."}}"#)
        do {
            _ = try await api.taskforceReview()
            Issue.record("성공하면 안 된다")
        } catch let error as APIError {
            #expect(error.isFeatureOff)
        } catch {
            Issue.record("APIError여야 한다")
        }
    }
}
