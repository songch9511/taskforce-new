#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

extension ExternalSessionSuites {
    /// Mac이 서버에 부르는 세 route (PR-D3k, 서버 노트 5장): `GET claude-app-chats/status` · `PUT claude-app-chats` · `POST external-sessions/claude-app-sent`. 모두 `/api/v2`, Bearer.
    /// 가짜 서버(`StubProtocol`)로 경로 · 본문 · 오류 모양을 본다
    struct ClaudeAppChatsEndpointsTests {
        private func client(status: Int = 200, body: String = "") -> (APIClient, String) {
            let host = "t\(UUID().uuidString.lowercased().prefix(8)).test"
            StubProtocol.register(host: host, reply: .init(status: status, body: body))
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubProtocol.self]
            return (APIClient(baseURL: URL(string: "https://\(host)")!, session: URLSession(configuration: configuration), token: { "token-123" }), host)
        }

        private func request() -> ClaudeAppChatPutRequest {
            ClaudeAppChatPutRequest(
                context: ClaudeAppChatContext(bridgeID: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!, sessionRef: String(repeating: "c", count: 64), title: "Title"),
                rows: [
                    ClaudeAppChatRow(macRef: String(repeating: "1", count: 64), role: .user, replyToRef: nil, body: "hi", truncated: false, saidAt: Date(timeIntervalSince1970: 1_800_000_000), toolNames: []),
                ]
            )
        }

        @Test func theStatusIsAGetOnTheV2RouteWithTheBearerAndNoBody() async throws {
            let (api, host) = client(body: #"{"save":true,"max_batch":20,"max_bytes":262144}"#)
            let status = try await api.claudeAppChatsStatus()
            #expect(status == ClaudeAppChatsStatus(save: true, maxBatch: 20, maxBytes: 262_144))
            let sent = try #require(StubProtocol.requests(host: host).last)
            #expect(sent.method == "GET" && sent.url.path == "/api/v2/claude-app-chats/status" && sent.headers["Authorization"] == "Bearer token-123" && sent.body == nil)
        }

        @Test func aNotFoundStatusThrowsSoTheCallerCreatesNoUploader() async {
            for body in [#"{"error":{"code":"not_found","message":"x"}}"#, "<html>Not Found</html>", ""] {
                let (api, _) = client(status: 404, body: body)
                do {
                    _ = try await api.claudeAppChatsStatus()
                    Issue.record("404인데 던지지 않았다")
                } catch {
                    #expect(ClaudeAppChatUploader.outcome(for: error) == .disabled, "\(body)")
                }
            }
        }

        @Test func thePutIsOnTheV2RouteWithExactlyTheServersFieldsAndDecodesANullChat() async throws {
            let (api, host) = client(body: #"{"chat_id":null,"saved":0,"existing":0,"orphan":1}"#)
            let response = try await api.putClaudeAppChat(request())
            #expect(response == ClaudeAppChatPutResponse(chatID: nil, saved: 0, existing: 0, orphan: 1))
            let sent = try #require(StubProtocol.requests(host: host).last)
            #expect(sent.method == "PUT" && sent.url.path == "/api/v2/claude-app-chats" && sent.headers["Authorization"] == "Bearer token-123")
            let putBody = try #require(sent.body)
            let object = try #require(try JSONSerialization.jsonObject(with: putBody) as? [String: Any])
            #expect(Set(object.keys) == ["bridge_id", "session_ref", "title", "messages"])
            let ok = client(body: #"{"chat_id":"22222222-2222-4333-8444-555555555555","saved":1,"existing":0,"orphan":0}"#)
            let saved = try await ok.0.putClaudeAppChat(request())
            #expect(saved.chatID == UUID(uuidString: "22222222-2222-4333-8444-555555555555") && saved.saved == 1)
        }

        @Test func thePutErrorsKeepTheirStatusSoTheUploaderCanTellThemApart() async {
            // 404: 서버의 `bridge_not_found`처럼 `APIErrorCode`에 없는 코드는 그 bridge만 사라진 것이고, 알려진 `not_found`(gate가 꺼짐)는 모두 꺼진 것이다
            let expected: [(Int, String, ClaudeAppChatUploader.PutOutcome)] = [
                (400, "some_code", .invalid), (404, "bridge_not_found", .bridgeGone), (404, "not_found", .disabled), (409, "some_code", .retry), (413, "quota_exceeded", .quota),
                (429, "some_code", .retry), (500, "some_code", .retry), (503, "some_code", .retry),
            ]
            for (status, code, outcome) in expected {
                let (api, _) = client(status: status, body: #"{"error":{"code":"\#(code)","message":"x"}}"#)
                do {
                    _ = try await api.putClaudeAppChat(request())
                    Issue.record("\(status)인데 던지지 않았다")
                } catch {
                    #expect(ClaudeAppChatUploader.outcome(for: error) == outcome, "\(status)")
                }
            }
        }

        @Test func theSentMetricsCarryOnlyTheResultTheReasonCodeAndTheUploadedFlag() async throws {
            let cases: [(ClaudeAppSentReport, [String: String])] = [
                (.received, ["result": "received"]),
                (.receivedButNotUploaded, ["result": "received", "uploaded": "false"]),
                (.notSent(.sessionClosed), ["result": "not_sent", "reason": "session_closed"]),
                (.notSent(.notReceived), ["result": "not_sent", "reason": "not_received"]),
                (.notSent(.bypass), ["result": "not_sent", "reason": "bypass"]),
                (.notSent(.twoWriters), ["result": "not_sent", "reason": "two_writers"]),
                (.notSent(.relayFailed), ["result": "not_sent", "reason": "relay_failed"]),
            ]
            for (report, expected) in cases {
                let (api, host) = client(status: 204)
                try await api.claudeAppSent(report)
                let sent = try #require(StubProtocol.requests(host: host).last)
                #expect(sent.method == "POST" && sent.url.path == "/api/v2/external-sessions/claude-app-sent")
                let reportBody = try #require(sent.body)
                let object = try #require(try JSONSerialization.jsonObject(with: reportBody) as? [String: Any])
                let flat = object.mapValues { "\($0)" }
                #expect(flat == expected.mapValues { $0 == "false" ? "0" : $0 }, "\(report)")
            }
        }

        @Test func aFailedMetricPostThrowsAndTheServerErrorKeepsItsStatus() async {
            let (api, _) = client(status: 429, body: #"{"error":{"code":"rate_limited","message":"x"}}"#)
            await #expect(throws: APIError.self) { try await api.claudeAppSent(.received) }
        }
    }
}
#endif
