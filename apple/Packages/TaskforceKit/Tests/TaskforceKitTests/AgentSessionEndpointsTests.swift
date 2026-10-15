import Foundation
import Testing
@testable import TaskforceKit

/// 세션 route 네 개의 Swift 요청 (OA U2-37): 경로 · 메서드 · 본문 · 응답 · 오류. 화면에 걸지 않는다 (알약 동작 · Stop · 거절 문구는 D4a).
/// 픽스처는 서버 route 시험의 모양이다 (`AgentSessionFixtures` 머리에 출처 sha)
struct AgentSessionEndpointsTests {
    typealias F = AgentSessionFixtures

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

    private var path: String { "/api/v2/agent-sessions/\(F.sessionID.uuidString.lowercased())" }

    // MARK: 이름 바꾸기

    @Test func renameIsAPatchWithTheTrimmedName() async throws {
        let (api, host) = client(body: F.renamed)
        let response = try await api.renameAgentSession(id: F.sessionID, displayName: "  Pricing  ")
        #expect(response.session.displayName == "Pricing" && response.session.status == .bound)
        let sent = try #require(StubProtocol.requests(host: host).last)
        #expect(sent.method == "PATCH" && sent.url.path == path)
        #expect(sent.headers["Authorization"] == "Bearer token-123")
        #expect(try json(sent.body) == ["display_name": "Pricing"])
    }

    @Test func theNameIsOneToTwoHundredAfterTrimming() {
        #expect(AgentSessionRename.normalized("  Pricing  ") == "Pricing")
        #expect(AgentSessionRename.normalized("") == nil)
        #expect(AgentSessionRename.normalized("   \n\t ") == nil, "공백뿐인 이름")
        #expect(AgentSessionRename.normalized("a") == "a")
        #expect(AgentSessionRename.normalized(String(repeating: "a", count: 200))?.count == 200)
        #expect(AgentSessionRename.normalized(String(repeating: "a", count: 201)) == nil)
        // 앞뒤 공백을 걷어낸 뒤의 길이다
        #expect(AgentSessionRename.normalized("  " + String(repeating: "a", count: 200) + "  ")?.count == 200)
        // 서버(JS 문자열)는 UTF-16 단위로 센다: 이모지는 둘이다
        #expect(AgentSessionRename.normalized(String(repeating: "😀", count: 100)) != nil)
        #expect(AgentSessionRename.normalized(String(repeating: "😀", count: 101)) == nil)
    }

    @Test func anInvalidNameIsNeverSent() async throws {
        let (api, host) = client(body: F.renamed)
        for name in ["", "   ", String(repeating: "a", count: 201)] {
            await #expect(throws: AgentSessionRequestError.invalidName) {
                _ = try await api.renameAgentSession(id: F.sessionID, displayName: name)
            }
        }
        #expect(StubProtocol.requests(host: host).isEmpty)
    }

    // MARK: Open in Terminal · Resume here · Stop

    @Test func openExternalIsAnEmptyPost() async throws {
        let (api, host) = client(body: F.openedExternal)
        let response = try await api.openAgentSessionExternal(id: F.sessionID)
        #expect(response.session.status == .external)
        let sent = try #require(StubProtocol.requests(host: host).last)
        #expect(sent.method == "POST" && sent.url.path == "\(path)/open-external")
        #expect(try json(sent.body) == [:])
    }

    @Test func resumeSendsTheConfirmationAndReadsTheStartedMessage() async throws {
        let (api, host) = client(body: F.resumed)
        let response = try await api.resumeAgentSessionHere(id: F.sessionID)
        #expect(response.session.lastTurnSeq == 2 && response.startedMessageID == F.startedMessageID)
        let sent = try #require(StubProtocol.requests(host: host).last)
        #expect(sent.method == "POST" && sent.url.path == "\(path)/resume-here")
        #expect(try json(sent.body) == ["confirmed_terminal_closed": true])
        let (api2, _) = client(body: F.resumedWithoutMessage)
        #expect(try await api2.resumeAgentSessionHere(id: F.sessionID).startedMessageID == nil)
    }

    @Test func stopIsAnEmptyPostAndReadsRequestedOnlyAndConfirmed() async throws {
        let (api, host) = client(body: F.stoppedRequestedOnly)
        let response = try await api.stopAgentSession(id: F.sessionID)
        #expect(response.tasks.count == 1 && response.tasks[0].cancel == .requestedOnly && response.tasks[0].processes == .mayContinue)
        #expect(response.tasks[0].agentTaskID == F.taskID)
        let sent = try #require(StubProtocol.requests(host: host).last)
        #expect(sent.method == "POST" && sent.url.path == "\(path)/stop")
        #expect(try json(sent.body) == [:])
        let (api2, _) = client(body: F.stoppedConfirmed)
        let confirmed = try await api2.stopAgentSession(id: F.sessionID)
        #expect(confirmed.tasks[0].cancel == .confirmed && confirmed.tasks[0].processes == nil)
    }

    // MARK: 모르는 값

    @Test func unknownValuesDecodeSafely() async throws {
        let (api, _) = client(body: F.stoppedFuture)
        let stopped = try await api.stopAgentSession(id: F.sessionID)
        #expect(stopped.tasks[0].cancel == .unknown("someday") && stopped.tasks[0].processes == .unknown("mystery"))
        let (api2, _) = client(body: F.futureStatus)
        #expect(try await api2.openAgentSessionExternal(id: F.sessionID).session.status == .unknown("hibernating"))
    }

    // MARK: 오류

    @Test func theServerRefusalsComeBackAsErrorsNotAsSuccess() async throws {
        for body in [F.sessionBusy, F.conflict, F.busyRetry] {
            let (api, _) = client(status: 409, body: body)
            let error = await #expect(throws: APIError.self) { _ = try await api.openAgentSessionExternal(id: F.sessionID) }
            #expect(error?.isConflict == true && error?.status == 409)
        }
        let (gone, _) = client(status: 404, body: F.notFound)
        let missing = await #expect(throws: APIError.self) { _ = try await gone.stopAgentSession(id: F.sessionID) }
        #expect(missing?.status == 404)
        #expect(missing?.isConflict == false)
        // 서버의 한국어 거절 문구는 화면에 쓰지 않는다 (영어 틀 `userMessage`가 말한다)
        #expect(missing?.userMessage.contains("세션") == false)
    }

    @Test func theServerErrorCodesStillDecodeFromTheErrorBody() throws {
        let busy = try AgentConversationErrorBody(data: Data(F.sessionBusy.utf8))
        let retry = try AgentConversationErrorBody(data: Data(F.busyRetry.utf8))
        let conflict = try AgentConversationErrorBody(data: Data(F.conflict.utf8))
        #expect(busy.code == .sessionBusy && retry.code == .busyRetry)
        #expect(conflict.code == .unknown("conflict"), "기존 v2 코드는 `APIErrorCode`가 안다")
    }
}
