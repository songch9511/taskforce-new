import Auth
import Foundation
import Supabase
import Testing
@testable import TaskforceKit

/// 질문 읽기(RLS select)와 답 요청 (OA D4b-m-1, 계약 6장): 경로 · 메서드 · 본문 · 열 · 필터 · 오류 코드. 서버 변경은 없다 —
/// 답 route는 `src/lib/api/agent-conversations.ts`의 `handleAnswerQuestion`, 본문은 `answerAgentQuestionRequestSchema`(strict: `provider_request_id` · `answers`)다.
struct AgentQuestionEndpointsTests {
    typealias F = AgentQuestionFixtures

    // MARK: 답 요청

    private func client(status: Int = 200, body: String = F.answered) -> (APIClient, String) {
        let host = "q\(UUID().uuidString.lowercased().prefix(8)).test"
        StubProtocol.register(host: host, reply: .init(status: status, body: body))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return (APIClient(baseURL: URL(string: "https://\(host)")!, session: URLSession(configuration: configuration), token: { "token-123" }), host)
    }

    private func json(_ data: Data?) throws -> NSDictionary {
        let body = try #require(data)
        return try #require(try JSONSerialization.jsonObject(with: body) as? NSDictionary)
    }

    private var request: AgentAnswerRequest {
        AgentAnswerRequest(providerRequestID: F.requestID, answers: ["price": .text("Yearly total"), "plans": .choices(["Pro monthly", "Lifetime"])])
    }

    @Test func theAnswerIsAPostToTheTaskWithExactlyTheRequestIDAndTheAnswers() async throws {
        let (api, host) = client()
        let response = try await api.answerAgentQuestion(taskID: F.taskID, request)
        let sent = try #require(StubProtocol.requests(host: host).last)
        #expect(sent.method == "POST" && sent.url.path == "/api/v2/agent-tasks/\(F.taskID.uuidString.lowercased())/answer")
        #expect(sent.headers["Authorization"] == "Bearer token-123", "Bearer라 CSRF 대상이 아니다")
        let body = try json(sent.body)
        #expect(Set(body.allKeys.compactMap { $0 as? String }) == ["provider_request_id", "answers"], "strict 본문: 다른 키가 없다")
        #expect(body["provider_request_id"] as? String == F.requestID)
        let answers = try #require(body["answers"] as? NSDictionary)
        #expect(answers["price"] as? String == "Yearly total" && answers["plans"] as? [String] == ["Pro monthly", "Lifetime"], "글은 글로, 다중은 배열로")
        #expect(response.status == .answered && response.stepID == UUID(uuidString: "f0000000-0000-f000-f000-000000000001"))
    }

    @Test func aSecondIdenticalAnswerReadsAsDuplicate() async throws {
        let (api, _) = client(body: F.duplicate)
        #expect(try await api.answerAgentQuestion(taskID: F.taskID, request).status == .duplicate)
    }

    @Test func anApprovalAnswerIsTheWordAllowOrDenyUnderTheApprovalID() async throws {
        let (api, host) = client()
        _ = try await api.answerAgentQuestion(taskID: F.taskID, AgentAnswerRequest(providerRequestID: F.requestID, answers: ["approval": .text("allow")]))
        let body = try json(try #require(StubProtocol.requests(host: host).last).body)
        #expect((body["answers"] as? NSDictionary) == ["approval": "allow"])
    }

    @Test func everyAnswerErrorKeepsItsServerCodeAndNeverTheKoreanMessage() async throws {
        let table: [(Int, String, AgentConversationErrorCode?)] = [
            (409, "question_stale", .questionStale), (409, "secret_requires_local", .secretRequiresLocal), (409, "busy_retry", .busyRetry),
            (400, "invalid_request", nil), (404, "not_found", nil),
        ]
        for (status, code, agent) in table {
            let (api, _) = client(status: status, body: F.error(code, "이미 닫히거나 바뀐 질문입니다."))
            do {
                _ = try await api.answerAgentQuestion(taskID: F.taskID, request)
                Issue.record("\(code) should throw")
            } catch let error as APIError {
                #expect(error.status == status && error.agentCode == agent, "\(code)")
                #expect(!error.userMessage.contains("질문"), "서버의 한국어 문구는 화면에 쓰지 않는다")
            }
        }
    }

    // MARK: 질문 읽기

    private let host = "agentq-\(UUID().uuidString.lowercased()).supabase.test"

    private func reads(rows: [String: String] = [:]) -> TaskforceReads {
        ChatReadStub.configure(host: host, rows: rows)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatReadStub.self]
        let supabase = SupabaseClient(
            supabaseURL: URL(string: "https://\(host)")!, supabaseKey: "test-public-key",
            options: SupabaseClientOptions(auth: .init(storage: ChatEmptyAuthStorage(), autoRefreshToken: false), global: .init(session: URLSession(configuration: configuration)))
        )
        return TaskforceReads(supabase: supabase)
    }

    private func query(_ recorded: ChatReadStub.Recorded) -> [String: String] {
        Dictionary(recorded.query.compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { first, _ in first })
    }

    private var requests: [ChatReadStub.Recorded] { ChatReadStub.requests(host: host) }

    @Test func openQuestionsReadOnlyAwaitingAnswerRowsOfTheAskedSessionsWithTheFiveColumns() async throws {
        let rows = "[\(F.row(pending: F.single))]"
        let found = try await reads(rows: ["agent_tasks": rows]).openQuestions(sessionIDs: [F.sessionID])
        let request = try #require(requests.last)
        #expect(request.path == "/rest/v1/agent_tasks")
        let q = query(request)
        #expect(q["select"] == "id, agent_session_id, turn_seq, state, pending_question".replacingOccurrences(of: ", ", with: ","), "열 다섯 (U2의 열 목록은 그대로)")
        #expect(q["state"] == "eq.awaiting_answer", "열린 질문 행만")
        #expect(q["agent_session_id"] == "in.(\(F.sessionID.uuidString.lowercased()))")
        #expect(found.count == 1 && found[0].question?.key == F.key())
    }

    @Test func noSessionsMeansNoRequestAtAll() async throws {
        let source = reads()
        let before = requests.count
        #expect(try await source.openQuestions(sessionIDs: []).isEmpty)
        #expect(requests.count == before)
    }

    @Test func manySessionsAreAskedInChunksOfOneHundred() async throws {
        let ids = Set((0..<230).map { _ in UUID() })
        _ = try await reads().openQuestions(sessionIDs: ids)
        let asked = requests.filter { $0.path == "/rest/v1/agent_tasks" }
        #expect(asked.count == 3, "100 · 100 · 30")
        let counts = asked.map { query($0)["agent_session_id"]?.split(separator: ",").count ?? 0 }.sorted()
        #expect(counts == [30, 100, 100])
    }

    @Test func aBrokenQuestionRowDoesNotHideTheOthers() async throws {
        let other = UUID()
        let rows = "[\(F.row(pending: F.unknownKind)),\(F.row(pending: F.pending(prompts: [F.prompt()], task: other), task: other, session: UUID()))]"
        let found = try await reads(rows: ["agent_tasks": rows]).openQuestions(sessionIDs: [F.sessionID])
        #expect(found.count == 2 && found[0].isMalformed && found[1].question != nil)
    }

    // MARK: Mac 이름 (bridges.device_name)

    @Test func theMacNameIsReadFromTheBridgeRowByID() async throws {
        let name = try await reads(rows: ["bridges": F.bridge(name: "Mina's MacBook Pro")]).bridgeDeviceName(id: F.bridgeID)
        #expect(name == "Mina's MacBook Pro")
        let request = try #require(requests.last)
        #expect(request.path == "/rest/v1/bridges" && query(request)["id"] == "eq.\(F.bridgeID.uuidString.lowercased())" && query(request)["select"] == "id,device_name")
    }

    @Test func aMissingNameOrRowIsNilSoTheScreenUsesItsFallbackWords() async throws {
        #expect(try await reads(rows: ["bridges": F.bridge(name: nil)]).bridgeDeviceName(id: F.bridgeID) == nil)
        #expect(try await reads(rows: ["bridges": "[]"]).bridgeDeviceName(id: F.bridgeID) == nil)
    }

    // MARK: 실제 연결

    @Test func theLiveGatewayAnswersThroughTheApiAndReadsThroughTheRows() async throws {
        let (api, apiHost) = client()
        let live = LiveChatGateway(reads: reads(rows: ["agent_tasks": "[\(F.row(pending: F.approvalEdit))]"]), api: api)
        let gateway: any AgentQuestionGateway = live
        let found = try await gateway.openQuestions(sessionIDs: [F.sessionID])
        #expect(found.first?.question?.kind == .approval)
        _ = try await gateway.answerQuestion(taskID: F.taskID, request: AgentAnswerRequest(providerRequestID: F.requestID, answers: ["approval": .text("deny")]))
        #expect(StubProtocol.requests(host: apiHost).last?.url.path.hasSuffix("/answer") == true)
    }
}
