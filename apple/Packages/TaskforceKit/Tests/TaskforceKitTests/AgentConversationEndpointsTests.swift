import Foundation
import Testing
@testable import TaskforceKit

/// 에이전트 대화 요청 넷 (OA D4a-1, 계약 5장): Send again(deliver) · 후보 고르기(referent) · 대화 Stop · 전달 읽기(delivery).
/// 경로 · 메서드 · 본문 · 응답 · 오류 코드를 본다. 픽스처는 서버 `src/lib/agents/conversation-contract.test.ts`(sha1 058340bf8606)의 `AGENT_CONVERSATION_*` 상수와 같은 JSON이다
/// (`AgentConversationFixtures`). 서버 route 시험: deliver `9a051f8d54b4` · delivery `db569120bb69` · stop `11ca9b35a04a` · referent `8c76bfa4320a` (head 38b5994).
struct AgentConversationEndpointsTests {
    typealias F = AgentConversationFixtures

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

    private var base: String { "/api/v2/conversations/\(F.conversationID.uuidString.lowercased())" }

    // MARK: Send again (deliver)

    @Test func deliverSendsTheLowercaseMessageIDsAndReadsEachResult() async throws {
        let (api, host) = client(body: F.deliverResponse)
        let response = try await api.deliverAgentMessages(conversationID: F.conversationID, messageIDs: [F.messageID])
        let sent = try #require(StubProtocol.requests(host: host).last)
        #expect(sent.method == "POST" && sent.url.path == "\(base)/deliver" && sent.headers["Authorization"] == "Bearer token-123")
        #expect(try json(sent.body) == ["message_ids": [F.messageID.uuidString.lowercased()]])
        #expect(response.messages.map(\.result) == [.requeued, .skipped, .skipped])
        #expect(response.messages[0].delivery == AgentDelivery(state: .queued, reason: .sessionBusy))
        #expect(response.messages[1].skippedReason == .unknownOutcome && response.messages[1].delivery?.state == .outcomeUnknown)
        #expect(response.messages[2].skippedReason == .notFound && response.messages[2].delivery == nil, "not_found에는 delivery가 없다")
    }

    @Test func deliverWithoutIDsSendsAnEmptyObject() async throws {
        let (api, host) = client(body: F.deliverResponse)
        _ = try await api.deliverAgentMessages(conversationID: F.conversationID, messageIDs: nil)
        let sent = try #require(StubProtocol.requests(host: host).last)
        #expect(try json(sent.body) == [:], "message_ids가 없으면 그 대화의 보류 · 만료 메시지 전부")
    }

    @Test func theMessageIDCountIsOneToFiftyAndOtherCountsAreNeverSent() async throws {
        for count in [1, 50] {
            let (api, host) = client(body: F.deliverResponse)
            let ids = (0..<count).map { _ in UUID() }
            _ = try await api.deliverAgentMessages(conversationID: F.conversationID, messageIDs: ids)
            let sent = try #require(StubProtocol.requests(host: host).last, "\(count)")
            #expect((try json(sent.body)["message_ids"] as? [String])?.count == count)
        }
        for count in [0, 51] {
            let (api, host) = client(body: F.deliverResponse)
            await #expect(throws: AgentDeliverRequestError.invalidCount) {
                _ = try await api.deliverAgentMessages(conversationID: F.conversationID, messageIDs: (0..<count).map { _ in UUID() })
            }
            #expect(StubProtocol.requests(host: host).isEmpty, "\(count)개는 서버가 400이다: 보내지 않는다")
        }
    }

    // MARK: 후보 고르기 (referent)

    @Test func referentPostsTheChosenActionToTheMessageAndReadsTheNewDelivery() async throws {
        let (api, host) = client(body: F.postResponse)
        let posted = try await api.setAgentReferent(conversationID: F.conversationID, messageID: F.messageID, actionID: F.deterministicActionID)
        let sent = try #require(StubProtocol.requests(host: host).last)
        #expect(sent.method == "POST" && sent.url.path == "\(base)/messages/\(F.messageID.uuidString.lowercased())/referent")
        #expect(try json(sent.body) == ["action_id": F.deterministicActionID.uuidString.lowercased()])
        #expect(posted.delivery.state == .sent && posted.message.id == F.messageID)
    }

    // MARK: 대화 Stop

    @Test func conversationStopIsAnEmptyPostAndReadsEachTask() async throws {
        let (api, host) = client(body: F.stopResponse)
        let response = try await api.stopAgentConversation(id: F.conversationID)
        let sent = try #require(StubProtocol.requests(host: host).last)
        #expect(sent.method == "POST" && sent.url.path == "\(base)/stop")
        #expect(try json(sent.body) == [:])
        #expect(response.tasks.map(\.cancel) == [.requestedOnly, .confirmed] && response.tasks[0].processes == .mayContinue)
    }

    // MARK: 전달 읽기

    @Test func deliveriesAreAGetWithOrWithoutSinceSeq() async throws {
        let (api, host) = client(body: F.deliveryRead)
        let all = try await api.agentDeliveries(conversationID: F.conversationID, sinceSeq: nil)
        var sent = try #require(StubProtocol.requests(host: host).last)
        #expect(sent.method == "GET" && sent.url.path == "\(base)/delivery" && sent.url.query == nil && sent.body == nil)
        #expect(all.messages.map(\.seq) == [1, 2])
        #expect(all.messages[0].delivery.state == .accepted && all.messages[1].delivery == AgentDelivery(state: .notSent, reason: .usageLimited))
        _ = try await api.agentDeliveries(conversationID: F.conversationID, sinceSeq: 100)
        sent = try #require(StubProtocol.requests(host: host).last)
        #expect(sent.url.path == "\(base)/delivery" && sent.url.query == "since_seq=100")
        _ = try await api.agentDeliveries(conversationID: F.conversationID, sinceSeq: 0)
        sent = try #require(StubProtocol.requests(host: host).last)
        #expect(sent.url.query == "since_seq=0", "0도 보낸다 (nil과 다르다)")
    }

    // MARK: 오류 코드 (D4a-20)

    private static let codes: [(String, APIErrorCode)] = [
        ("target_mismatch", .targetMismatch), ("question_stale", .questionStale), ("secret_requires_local", .secretRequiresLocal),
        ("session_busy", .sessionBusy), ("approval_via_review", .approvalViaReview), ("busy_retry", .busyRetry),
    ]

    @Test func theSixAgentErrorCodesAreKeptNotGuessedFromTheStatus() async throws {
        for (raw, code) in Self.codes {
            let body = ChatContractFixtures.error(raw)
            let error = APIClient.error(status: 409, data: Data(body.utf8))
            #expect(error == .server(status: 409, code: code, message: "x"), "\(raw)")
            #expect(error.agentCode == AgentConversationErrorCode(raw: raw), "\(raw)")
            #expect(error.isConflict == false, "더는 `conflict`로 줄지 않는다: \(raw)")
            // 상태 코드와 상관없이 코드를 지킨다
            #expect(APIClient.error(status: 400, data: Data(body.utf8)) == .server(status: 400, code: code, message: "x"), "\(raw)")
        }
    }

    @Test func theSixCodesComeOutOfEveryNewRequest() async throws {
        for (raw, code) in Self.codes {
            let body = ChatContractFixtures.error(raw)
            for call in ["deliver", "referent", "stop", "delivery"] {
                let (api, _) = client(status: 409, body: body)
                do {
                    switch call {
                    case "deliver": _ = try await api.deliverAgentMessages(conversationID: F.conversationID, messageIDs: nil)
                    case "referent": _ = try await api.setAgentReferent(conversationID: F.conversationID, messageID: F.messageID, actionID: F.secondID)
                    case "stop": _ = try await api.stopAgentConversation(id: F.conversationID)
                    default: _ = try await api.agentDeliveries(conversationID: F.conversationID, sinceSeq: nil)
                    }
                    Issue.record("\(call) \(raw): 성공으로 읽혔다")
                } catch {
                    #expect(error as? APIError == .server(status: 409, code: code, message: "x"), "\(call) \(raw)")
                }
            }
        }
    }

    /// 짐작 경로는 다른 코드에서 그대로다: 모르는 409는 `conflict`, 모르는 401 · 429 · 그 밖
    @Test func theGuessForOtherCodesIsUnchanged() {
        for (status, expected) in [(409, APIErrorCode.conflict), (401, .unauthorized), (429, .rateLimited), (500, .internalError), (404, .internalError)] {
            let error = APIClient.error(status: status, data: Data(ChatContractFixtures.error("some_future_code").utf8))
            #expect(error == .server(status: status, code: expected, message: "x"), "\(status)")
            #expect(error.agentCode == nil)
        }
        // 옛 코드 디코딩은 그대로
        #expect(APIClient.error(status: 409, data: Data(ChatContractFixtures.error("conflict").utf8)) == .server(status: 409, code: .conflict, message: "x"))
        #expect(APIClient.error(status: 404, data: Data(ChatContractFixtures.error("not_found").utf8)) == .server(status: 404, code: .notFound, message: "x"))
        #expect(APIClient.error(status: 409, data: Data(ChatContractFixtures.error("confirm_unavailable").utf8)) == .server(status: 409, code: .confirmUnavailable, message: "x"))
    }

    @Test func theNewCodesNeverShowTheServersKoreanRefusal() {
        for (raw, _) in Self.codes {
            let error = APIClient.error(status: 409, data: Data(ChatContractFixtures.error(raw, "에이전트가 일하고 있습니다.").utf8))
            #expect(!error.userMessage.contains("에이전트"), "\(raw)")
            #expect(!error.userMessage.isEmpty)
        }
    }
}
