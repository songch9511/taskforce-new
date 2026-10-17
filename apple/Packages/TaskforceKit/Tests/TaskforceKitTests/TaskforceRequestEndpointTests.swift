import Foundation
import Testing
@testable import TaskforceKit

/// 진짜 `APIClient`(가짜 전송)로 읽는 gateway: 저장소가 부르는 길이 실제로 어느 경로로 나가는지 본다 (R-dec-m). 나머지는 기본 구현(404 · 빈 값)이다
private struct APIBackedTaskforceGateway: TaskforceRequestGateway {
    let api: APIClient
    func taskforceReview() async throws -> TaskforceReviewResponse { try await api.taskforceReview() }
}

/// OA U3 11.1 · R-dec-m: `GET /api/v2/review/decisions` · `POST /api/v2/path-conflicts/{lease_id}/resolve`의 경로 · 메서드 · 본문 · 오류 디코딩 (가짜 전송, 서버 호출 0)
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

    @Test func theDecisionsReadIsAPlainBearerGetOnTheV2DecisionsRoute() async throws {
        let response = try await client(body: Fx.reviewDecisions).taskforceReview()
        #expect(response.items.count == 6)
        let request = try #require(last)
        #expect(request.method == "GET" && request.url.absoluteString == "https://\(host)/api/v2/review/decisions")
        #expect(request.headers["Authorization"] == "Bearer token-123")
        #expect(request.body == nil || request.body?.isEmpty == true)
    }

    /// R-dec-m: 쓰기가 있는 옛 `GET /api/v2/review`는 어떤 대답에도 부르지 않는다. 404(옛 서버 · 기능 꺼짐)여도 되돌아가 읽지 않고 요청은 새 경로 하나뿐이다
    @Test(arguments: [200, 404, 401, 500, 503])
    func noReadEverGoesToTheOldWritingReviewRoute(_ status: Int) async {
        let body = status == 200 ? Fx.reviewDecisions : #"{"error":{"code":"not_found","message":"없는 경로입니다."}}"#
        _ = try? await client(status: status, body: body).taskforceReview()
        let paths = StubProtocol.requests(host: host).map(\.url.path)
        #expect(paths == ["/api/v2/review/decisions"], "새 경로 하나로만 나간다: \(paths)")
        #expect(!paths.contains("/api/v2/review"))
    }

    /// R-dec-m: 저장소를 거쳐도 같다. 404는 `featureOff`로 읽고, 옛 쓰기 GET으로 되돌아가 읽지 않는다 (새로 읽을 때마다 새 경로 하나)
    @Test @MainActor func aFeatureOffServerStaysFeatureOffThroughTheStoreAndNeverFallsBackToTheOldRoute() async {
        let account = TaskforceTestAccount()
        let gateway = APIBackedTaskforceGateway(api: client(status: 404, body: #"{"error":{"code":"not_found","message":"없는 경로입니다."}}"#))
        let store = TaskforceRequestStore(gateway: gateway, scope: account.scope, schedule: TaskforceManualClock().schedule)
        await store.refresh()
        await store.refresh()
        #expect(store.featureOff && store.readProblem == .failed && store.response == nil)
        let paths = StubProtocol.requests(host: host).map(\.url.path)
        #expect(paths == ["/api/v2/review/decisions", "/api/v2/review/decisions"], "읽기마다 새 경로 하나: \(paths)")
        #expect(!paths.contains("/api/v2/review"))
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
