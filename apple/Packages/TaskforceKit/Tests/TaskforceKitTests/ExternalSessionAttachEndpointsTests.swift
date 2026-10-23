import Foundation
import Testing
@testable import TaskforceKit

/// 이어받기 route의 Swift 요청 (OA 외부 세션 PR2m, 서버 PR2s `docs/agent-gateway.md` 18장): 경로 · 본문 · 응답 · 오류, 그리고 서버가 열려 있는지 보는 길.
/// 픽스처는 서버 route 시험(`src/app/api/v2/agent-sessions/attach/route.test.ts`)의 모양이다
struct ExternalSessionAttachEndpointsTests {
    private let bridge = UUID(uuidString: "b1b1b1b1-0000-4000-8000-000000000001")!
    private let external = "5e5e5e5e-0000-4000-8000-0000000000a1"
    private let ref = "/taskforce/ws_7a7a7a7a-0000-4000-8000-000000000001"

    private func client(status: Int = 200, body: String = "{}") -> (APIClient, String) {
        let host = "t\(UUID().uuidString.lowercased().prefix(8)).test"
        StubProtocol.register(host: host, reply: .init(status: status, body: body))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return (APIClient(baseURL: URL(string: "https://\(host)")!, session: URLSession(configuration: configuration), token: { "token-123" }), host)
    }

    private func json(_ data: Data?) throws -> NSDictionary {
        let body = try #require(data)
        return try #require(try JSONSerialization.jsonObject(with: body) as? NSDictionary)
    }

    private func response(status: String = "created") -> String {
        #"{"status":"\#(status)","conversation_id":"d0d0d0d0-0000-4000-8000-000000000001","workspace_ref":"\#(ref)","session":{"id":"5e5e5e5e-0000-4000-8000-000000000001","connection_id":"c0c0c0c0-0000-4000-8000-000000000001","display_name":"","status":"bound","last_turn_seq":0,"updated_at":"2026-10-21T14:00:00.000Z"}}"#
    }

    @Test func attachIsAPostWithTheLocalIdAndTheVirtualRootAndNothingElse() async throws {
        let (api, host) = client(status: 201, body: response())
        let result = try await api.attachAgentSession(bridgeID: bridge, adapter: "agent:claude-code", externalSessionID: external, workspaceRef: ref)
        #expect(result.status == .created && result.workspaceRef == ref && result.session.displayName == "" && result.session.status == .bound)
        #expect(result.conversationID == UUID(uuidString: "d0d0d0d0-0000-4000-8000-000000000001"))
        let sent = try #require(StubProtocol.requests(host: host).last)
        #expect(sent.method == "POST" && sent.url.path == "/api/v2/agent-sessions/attach")
        #expect(sent.headers["Authorization"] == "Bearer token-123")
        #expect(try json(sent.body) == ["bridge_id": bridge.uuidString.lowercased(), "adapter": "agent:claude-code", "external_session_id": external, "workspace_ref": ref], "strict 본문: 모르는 칸 0, 경로 0")
    }

    @Test func existingIsTheIdempotentAnswer() async throws {
        let (api, _) = client(status: 200, body: response(status: "existing"))
        let result = try await api.attachAgentSession(bridgeID: bridge, adapter: "agent:claude-code", externalSessionID: external, workspaceRef: ref)
        #expect(result.status == .existing)
    }

    @Test func aRequestThatIsNotTheServerShapeIsNeverSent() async throws {
        let (api, host) = client(status: 201, body: response())
        let badIDs = [external.uppercased(), "-r", "../x", "/tmp/a.jsonl", external + " ", "pending:" + external, ""]
        for bad in badIDs {
            await #expect(throws: AgentSessionRequestError.invalidAttach) {
                _ = try await api.attachAgentSession(bridgeID: bridge, adapter: "agent:claude-code", externalSessionID: bad, workspaceRef: ref)
            }
        }
        let badRefs = ["/Users/daniel/Documents/project", "/taskforce/ws_x", "/taskforce/ws_" + UUID().uuidString, "/taskforce/ws_7A7A7A7A-0000-4000-8000-000000000001", "", ref + "/sub"]
        for bad in badRefs {
            await #expect(throws: AgentSessionRequestError.invalidAttach) {
                _ = try await api.attachAgentSession(bridgeID: bridge, adapter: "agent:claude-code", externalSessionID: external, workspaceRef: bad)
            }
        }
        await #expect(throws: AgentSessionRequestError.invalidAttach) {
            _ = try await api.attachAgentSession(bridgeID: bridge, adapter: "claude-code", externalSessionID: external, workspaceRef: ref)
        }
        #expect(StubProtocol.requests(host: host).isEmpty, "서버에 아무것도 가지 않았다")
    }

    @Test func theServerErrorsKeepTheirStatusSoTheFlowCanTellThemApart() async throws {
        for (status, code, expected) in [
            (404, "not_found", APIErrorCode.notFound), (409, "session_in_use", .conflict), (409, "workspace_mismatch", .conflict), (409, "busy_retry", .busyRetry),
            (403, "forbidden", .internalError), (429, "rate_limited", .rateLimited), (400, "invalid_request", .invalidRequest),
        ] {
            let (api, _) = client(status: status, body: #"{"error":{"code":"\#(code)","message":"x"}}"#)
            do {
                _ = try await api.attachAgentSession(bridgeID: bridge, adapter: "agent:claude-code", externalSessionID: external, workspaceRef: ref)
                Issue.record("\(status) \(code)")
            } catch let error as APIError {
                #expect(error.status == status, "\(code)")
                if case .server(_, let readCode, _) = error { #expect(readCode == expected, "\(code)") } else { Issue.record("\(error)") }
            }
        }
    }

    // MARK: 서버가 열려 있나 (화면 게이트)

    @Test func theServerIsOpenWhenAnEmptyBodyGetsA400AndClosedWhenItGetsA404() async throws {
        let (open, openHost) = client(status: 400, body: #"{"error":{"code":"invalid_request","message":"x"}}"#)
        #expect(await open.agentAttachAvailability() == .enabled)
        let sent = try #require(StubProtocol.requests(host: openHost).last)
        let body = try json(sent.body)
        #expect(sent.method == "POST" && sent.url.path == "/api/v2/agent-sessions/attach" && body == [:], "빈 본문 하나: 아무것도 만들지 않고 속도 제한도 쓰지 않는다 (본문 검사가 앞이다)")
        let (closed, _) = client(status: 404, body: #"{"error":{"code":"not_found","message":"없는 경로입니다."}}"#)
        #expect(await closed.agentAttachAvailability() == .disabled)
    }

    @Test func anythingElseIsUnknownSoTheScreenStaysHidden() async throws {
        for (status, body) in [
            (200, response()), (201, response()), (401, #"{"error":{"code":"unauthorized","message":"x"}}"#), (403, #"{"error":{"code":"forbidden","message":"x"}}"#),
            (429, #"{"error":{"code":"rate_limited","message":"x"}}"#), (500, #"{"error":{"code":"internal_error","message":"x"}}"#), (502, "bad gateway"),
        ] {
            let (api, _) = client(status: status, body: body)
            #expect(await api.agentAttachAvailability() == .unknown, "\(status)")
        }
        // 토큰을 받다가 네트워크가 끊겼다 (APIClient가 전송 오류로 올린다)
        let offline = APIClient(baseURL: URL(string: "https://offline.test")!, session: .shared, token: { throw URLError(.notConnectedToInternet) })
        #expect(await offline.agentAttachAvailability() == .unknown)
    }
}
