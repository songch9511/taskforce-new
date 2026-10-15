import Auth
import Foundation

// OA U2: 세션 route 네 개의 Swift 요청 (U2-37). 서버는 `src/app/api/v2/agent-sessions/**`에 다 있고 Swift에는 DTO만 있었다 (`AgentConversationContracts.swift`).
// **화면에 걸지 않는다**: 알약 동작(Open in Terminal · Resume here 확인 카드) · Stop · 거절 문구는 D4a 몫이다. 서버의 한국어 거절 문구는 화면에 쓰지 않는다.
// Bearer 인증이라 CSRF 대상이 아니다.
// **오류 코드를 지키는 이유(검토 반영 10):** `APIClient`는 서버 오류의 `code`를 `APIErrorCode`로 줄여 읽고 모르는 코드는 상태 코드로 짐작해서(409 → `conflict`)
// `session_busy` · `busy_retry` · `conflict`를 가를 수 없다. `APIClient.swift`는 U2 범위 밖이라, 세션 요청은 `AgentSessionClient`가 같은 요청 틀(`APIClient.makeRequest`)로
// 직접 보내고 오류 본문에서 원래 `code`를 읽어 `AgentSessionRouteError.serverCode`에 싣는다. 기존 오류 처리는 `.api`(`APIError`)를 그대로 읽는다.

/// 앱이 서버에 보내기 전에 막는 요청 (서버가 400으로 거절할 것을 보내지 않는다)
public enum AgentSessionRequestError: Error, Equatable, Sendable {
    /// 세션 이름이 trim 뒤 1–200자가 아니다
    case invalidName
}

public enum AgentSessionRename {
    public static let maxLength = 200

    /// trim한 이름. 비었거나 200자를 넘으면 nil. 길이는 서버(zod, JS 문자열)처럼 UTF-16 단위다
    public static func normalized(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf16.count <= maxLength else { return nil }
        return trimmed
    }
}

/// `PATCH /api/v2/agent-sessions/{id}` 본문: `{ display_name }` (strict)
struct RenameAgentSessionRequest: Encodable {
    let displayName: String

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
    }
}

/// 본문 없는 쓰기 (Open in Terminal · Stop): `{}` (strict)
struct EmptyAgentSessionRequest: Encodable {}

/// `POST …/resume-here` 본문: `{ confirmed_terminal_closed: true }` — 서버는 `true` 하나만 받는다 (`z.literal(true)`)
struct ResumeAgentSessionRequest: Encodable {
    let confirmedTerminalClosed = true

    enum CodingKeys: String, CodingKey {
        case confirmedTerminalClosed = "confirmed_terminal_closed"
    }
}

/// 세션 route의 오류: 기존 오류 처리가 읽는 `APIError`(`api`)와, 서버가 보낸 원래 오류 코드 문자열(`serverCode`: `session_busy` · `busy_retry` · `conflict` · `not_found` …).
/// 약속한 형식이 아닌 응답(프록시 · 네트워크 · 로그인 풀림)은 코드가 없다
public struct AgentSessionRouteError: Error, Equatable, Sendable {
    public let api: APIError
    public let serverCode: String?

    public init(api: APIError, serverCode: String? = nil) {
        self.api = api
        self.serverCode = serverCode
    }

    /// 대화 route의 오류 코드로 본 값 (모르는 코드는 `.unknown(raw)`)
    public var conversationCode: AgentConversationErrorCode? { serverCode.map(AgentConversationErrorCode.init(raw:)) }
}

/// 세션 route 네 개의 클라이언트 (OA U2-37). 요청 틀(`APIClient.makeRequest`: 경로 · Bearer · 본문)은 `APIClient`와 같고, 오류는 원래 코드를 지켜 던진다
public struct AgentSessionClient: Sendable {
    let api: APIClient
    private let session: URLSession
    private let token: APIClient.TokenProvider
    private let onUnauthorized: APIClient.UnauthorizedHandler?

    /// - api: 주소 · 요청 틀을 빌린다 (같은 서버)
    public init(api: APIClient, session: URLSession = .shared, token: @escaping APIClient.TokenProvider, onUnauthorized: APIClient.UnauthorizedHandler? = nil) {
        self.api = api
        self.session = session
        self.token = token
        self.onUnauthorized = onUnauthorized
    }

    private func path(_ id: UUID, _ action: String? = nil) -> String {
        "agent-sessions/\(id.lowercased)" + (action.map { "/\($0)" } ?? "")
    }

    /// 세션 이름 바꾸기. 같은 이름이면 서버가 200으로 그대로 돌려준다. trim 뒤 1–200자가 아니면 보내지 않고 `invalidName`을 던진다
    public func renameAgentSession(id: UUID, displayName: String) async throws -> AgentSessionResponse {
        guard let name = AgentSessionRename.normalized(displayName) else { throw AgentSessionRequestError.invalidName }
        return try await send(.patch, path(id), body: RenameAgentSessionRequest(displayName: name))
    }

    /// Open in Terminal: 세션을 `external`로 넘긴다 (Taskforce 전달 0). 터미널을 여는 일은 서버가 아니라 Mac 앱 · bridge 몫이다.
    /// 턴이 돌거나 답을 기다리면 409 `session_busy`, 첫 턴 전 · `bound`가 아니면 409 `conflict` (`serverCode`로 가른다)
    public func openAgentSessionExternal(id: UUID) async throws -> AgentSessionResponse {
        try await send(.post, path(id, "open-external"), body: EmptyAgentSessionRequest())
    }

    /// Resume here: 터미널 세션을 닫았다고 **사용자가 확인한 뒤에만** 부른다 (서버는 프로세스를 검사하지 않고 확인 본문만 받는다).
    /// `external`이 아니면 409 `conflict`. 성공하면 서버가 대기 메시지를 순서대로 시작한다 (`started_message_id`)
    public func resumeAgentSessionHere(id: UUID) async throws -> AgentResumeResponse {
        try await send(.post, path(id, "resume-here"), body: ResumeAgentSessionRequest())
    }

    /// Stop: 세션의 열린 턴을 멈춘다. `requested_only`는 아직 확인 전이고 `processes: may_continue`면 실행 중 명령이 남을 수 있다
    public func stopAgentSession(id: UUID) async throws -> AgentStopResponse {
        try await send(.post, path(id, "stop"), body: EmptyAgentSessionRequest())
    }

    private func send<T: Decodable>(_ method: APIClient.Method, _ path: String, body: any Encodable) async throws -> T {
        let accessToken: String
        do {
            accessToken = try await token()
        } catch let error as APIError {
            throw AgentSessionRouteError(api: error)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw AgentSessionRouteError(api: .transport(error.localizedDescription))
        } catch {
            throw AgentSessionRouteError(api: .notSignedIn)
        }
        let request = try api.makeRequest(method, path, body: body, token: accessToken, version: .v2)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw AgentSessionRouteError(api: .transport(error.localizedDescription))
        }
        guard let http = response as? HTTPURLResponse else { throw AgentSessionRouteError(api: .unexpectedStatus(0)) }
        guard (200..<300).contains(http.statusCode) else {
            // 토큰을 거절당함: 세션이 끝난 것으로 확인되면(다른 기기에서 계정 삭제 등) 이 기기는 이미 로그아웃됐다 → 로그인 안내
            if http.statusCode == 401, let onUnauthorized {
                let ended = await onUnauthorized()
                try Task.checkCancellation()
                if ended { throw AgentSessionRouteError(api: .notSignedIn) }
            }
            throw AgentSessionRouteError(api: APIClient.error(status: http.statusCode, data: data), serverCode: Self.serverCode(in: data))
        }
        do {
            return try TaskforceJSON.decoder().decode(T.self, from: data)
        } catch {
            throw AgentSessionRouteError(api: .decoding(String(describing: error)))
        }
    }

    /// 오류 응답 `{ error: { code, message } }`의 원래 코드 문자열 (약속한 형식이 아니면 nil)
    static func serverCode(in data: Data) -> String? {
        struct Envelope: Decodable {
            struct Body: Decodable { let code: String }
            let error: Body
        }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.error.code
    }
}

extension AppServices {
    /// 앱의 실제 세션 route 클라이언트: `AppServices.api`와 같은 주소 · 같은 토큰 공급(만료가 가까우면 갱신) · 같은 401 처리
    public func agentSessionClient(session: URLSession = .shared) -> AgentSessionClient {
        let auth = supabase.auth
        return AgentSessionClient(
            api: api, session: session,
            token: {
                do {
                    return try await auth.session.accessToken
                } catch let AuthError.api(_, _, _, response) where response.statusCode >= 500 || response.statusCode == 429 {
                    throw APIClient.error(status: response.statusCode, data: Data())
                }
            },
            onUnauthorized: { await auth.endSessionIfGone() }
        )
    }
}
