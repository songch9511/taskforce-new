import Foundation
import Testing
@testable import TaskforceKit

/// 세션 route 네 개의 Swift 요청 (OA U2-37 → D4a-20에서 `APIClient`로 합쳤다): 경로 · 메서드 · 본문 · 응답 · 오류.
/// 픽스처는 서버 route 시험의 모양이다 (`AgentSessionFixtures` 머리에 출처 sha).
/// 오류는 `APIClient`의 `APIError`로 올라오고, 서버가 준 원래 코드(`session_busy` · `busy_retry`)는 `APIErrorCode`가 지킨다 (D4a-20)
struct AgentSessionEndpointsTests {
    typealias F = AgentSessionFixtures

    private func client(status: Int = 200, body: String = "{}", onUnauthorized: APIClient.UnauthorizedHandler? = nil) -> (APIClient, String) {
        let host = "t\(UUID().uuidString.lowercased().prefix(8)).test"
        StubProtocol.register(host: host, reply: .init(status: status, body: body))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return (
            APIClient(baseURL: URL(string: "https://\(host)")!, session: URLSession(configuration: configuration), token: { "token-123" }, onUnauthorized: onUnauthorized),
            host
        )
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

    // MARK: 오류 (D4a-20: 원래 서버 코드를 `APIErrorCode`가 지킨다)

    private func apiError(status: Int, body: String, _ call: (APIClient) async throws -> Void) async -> APIError? {
        let (api, _) = client(status: status, body: body)
        do {
            try await call(api)
            return nil
        } catch {
            return error as? APIError
        }
    }

    @Test func theServerRefusalsComeBackAsErrorsNotAsSuccess() async throws {
        for body in [F.sessionBusy, F.conflict, F.busyRetry] {
            let error = await apiError(status: 409, body: body) { _ = try await $0.openAgentSessionExternal(id: F.sessionID) }
            #expect(error?.status == 409, "기존 오류 처리(`APIError`)가 그대로 읽는다")
        }
        let missing = await apiError(status: 404, body: F.notFound) { _ = try await $0.stopAgentSession(id: F.sessionID) }
        #expect(missing?.status == 404)
        #expect(missing?.isConflict == false)
        // 서버의 한국어 거절 문구는 화면에 쓰지 않는다 (영어 틀 `userMessage`가 말한다)
        #expect(missing?.userMessage.contains("세션") == false)
    }

    /// 검토 반영 10 → D4a-20: `session_busy` · `busy_retry` · `conflict`는 서로 다른 코드로 남고, 네 요청 모두 같다 (옛 `AgentSessionClient`와 같은 결과)
    @Test func theOriginalServerCodeIsKeptSoTheThreeConflictsCanBeTold() async throws {
        let expected: [(String, APIErrorCode)] = [(F.sessionBusy, .sessionBusy), (F.busyRetry, .busyRetry), (F.conflict, .conflict)]
        for (body, code) in expected {
            for call in ["open", "resume", "stop", "rename"] {
                let error = await apiError(status: 409, body: body) { api in
                    switch call {
                    case "open": _ = try await api.openAgentSessionExternal(id: F.sessionID)
                    case "resume": _ = try await api.resumeAgentSessionHere(id: F.sessionID)
                    case "stop": _ = try await api.stopAgentSession(id: F.sessionID)
                    default: _ = try await api.renameAgentSession(id: F.sessionID, displayName: "Pricing")
                    }
                }
                guard case .server(let status, let got, _)? = error else {
                    Issue.record("\(call): 서버 오류가 아니다 \(String(describing: error))")
                    continue
                }
                #expect(status == 409 && got == code, "\(call): \(code.rawValue)")
            }
        }
        let missing = await apiError(status: 404, body: F.notFound) { _ = try await $0.stopAgentSession(id: F.sessionID) }
        guard case .server(404, .notFound, _)? = missing else {
            Issue.record("404 not_found가 아니다 \(String(describing: missing))")
            return
        }
        // 서버가 코드를 주지 않은 오류(약속한 형식이 아닌 응답)는 코드가 없다
        let proxy = await apiError(status: 502, body: "<html>bad gateway</html>") { _ = try await $0.stopAgentSession(id: F.sessionID) }
        #expect(proxy == .unexpectedStatus(502))
    }

    @Test func aRejectedTokenAsksTheSessionEndedHandlerAndTheEndedSessionIsNotSignedIn() async throws {
        let (ended, _) = client(status: 401, body: F.notFound, onUnauthorized: { true })
        do {
            _ = try await ended.stopAgentSession(id: F.sessionID)
            Issue.record("성공으로 읽혔다")
        } catch {
            #expect(error as? APIError == .notSignedIn)
        }
        let (alive, _) = client(status: 401, body: F.notFound, onUnauthorized: { false })
        do {
            _ = try await alive.stopAgentSession(id: F.sessionID)
            Issue.record("성공으로 읽혔다")
        } catch {
            #expect((error as? APIError)?.status == 401)
        }
    }

    @Test func theRequestsStillCarryTheBearerTokenOnAllFourPaths() async throws {
        for (call, suffix, method) in [("rename", "", "PATCH"), ("open", "/open-external", "POST"), ("resume", "/resume-here", "POST"), ("stop", "/stop", "POST")] {
            let (api, host) = client(body: F.stoppedConfirmed)
            do {
                switch call {
                case "rename": _ = try await api.renameAgentSession(id: F.sessionID, displayName: "x")
                case "open": _ = try await api.openAgentSessionExternal(id: F.sessionID)
                case "resume": _ = try await api.resumeAgentSessionHere(id: F.sessionID)
                default: _ = try await api.stopAgentSession(id: F.sessionID)
                }
            } catch {
                // 응답 모양이 이 호출과 달라 읽지 못해도 요청은 나갔다 (아래에서 본다)
            }
            let sent = try #require(StubProtocol.requests(host: host).last, "\(call)")
            #expect(sent.method == method && sent.url.path == path + suffix && sent.headers["Authorization"] == "Bearer token-123", "\(call)")
        }
    }

    @Test func theServerErrorCodesStillDecodeFromTheErrorBody() throws {
        let busy = try AgentConversationErrorBody(data: Data(F.sessionBusy.utf8))
        let retry = try AgentConversationErrorBody(data: Data(F.busyRetry.utf8))
        let conflict = try AgentConversationErrorBody(data: Data(F.conflict.utf8))
        #expect(busy.code == .sessionBusy && retry.code == .busyRetry)
        #expect(conflict.code == .unknown("conflict"), "기존 v2 코드는 `APIErrorCode`가 안다")
    }
}
