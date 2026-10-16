import Foundation

// OA U2-37 → D4a-20: 세션 route 네 개의 Swift 요청. 서버는 `src/app/api/v2/agent-sessions/**`에 다 있다. 요청은 `APIClient`의 요청 틀(경로 · Bearer · 본문)을 그대로 쓰고,
// 서버가 준 원래 오류 코드(`session_busy` · `busy_retry` · `conflict`)는 `APIErrorCode`가 지킨다 (U2의 임시 클라이언트 `AgentSessionClient`는 이 합치기로 없어졌다).
// 서버의 한국어 거절 문구는 화면에 쓰지 않는다. Bearer 인증이라 CSRF 대상이 아니다.
// 화면 연결(알약 동작 · Stop)은 `AgentTerminalFlow.swift` · `AgentStopStore.swift`다.

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

extension APIClient {
    private func sessionPath(_ id: UUID, _ action: String? = nil) -> String {
        "agent-sessions/\(id.lowercased)" + (action.map { "/\($0)" } ?? "")
    }

    /// 세션 이름 바꾸기. 같은 이름이면 서버가 200으로 그대로 돌려준다. trim 뒤 1–200자가 아니면 보내지 않고 `invalidName`을 던진다
    public func renameAgentSession(id: UUID, displayName: String) async throws -> AgentSessionResponse {
        guard let name = AgentSessionRename.normalized(displayName) else { throw AgentSessionRequestError.invalidName }
        return try await send(.patch, sessionPath(id), body: RenameAgentSessionRequest(displayName: name), version: .v2)
    }

    /// Open in Terminal: 세션을 `external`로 넘긴다 (Taskforce 전달 0). 터미널을 여는 일은 서버가 아니라 Mac 앱 · bridge 몫이다.
    /// 턴이 돌거나 답을 기다리면 409 `session_busy`, 첫 턴 전 · `bound`가 아니면 409 `conflict` (`APIErrorCode`로 가른다)
    public func openAgentSessionExternal(id: UUID) async throws -> AgentSessionResponse {
        try await send(.post, sessionPath(id, "open-external"), body: EmptyAgentSessionRequest(), version: .v2)
    }

    /// Resume here: 터미널 세션을 닫았다고 **사용자가 확인한 뒤에만** 부른다 (서버는 프로세스를 검사하지 않고 확인 본문만 받는다).
    /// `external`이 아니면 409 `conflict`. 성공하면 서버가 대기 메시지를 순서대로 시작한다 (`started_message_id`)
    public func resumeAgentSessionHere(id: UUID) async throws -> AgentResumeResponse {
        try await send(.post, sessionPath(id, "resume-here"), body: ResumeAgentSessionRequest(), version: .v2)
    }

    /// Stop: 세션의 열린 턴을 멈춘다. `requested_only`는 아직 확인 전이고 `processes: may_continue`면 실행 중 명령이 남을 수 있다
    public func stopAgentSession(id: UUID) async throws -> AgentStopResponse {
        try await send(.post, sessionPath(id, "stop"), body: EmptyAgentSessionRequest(), version: .v2)
    }
}
