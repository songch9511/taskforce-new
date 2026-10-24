import Foundation

// OA U2-37 → D4a-20: 세션 route 네 개의 Swift 요청. 서버는 `src/app/api/v2/agent-sessions/**`에 다 있다. 요청은 `APIClient`의 요청 틀(경로 · Bearer · 본문)을 그대로 쓰고,
// 서버가 준 원래 오류 코드(`session_busy` · `busy_retry` · `conflict`)는 `APIErrorCode`가 지킨다 (U2의 임시 클라이언트 `AgentSessionClient`는 이 합치기로 없어졌다).
// 서버의 한국어 거절 문구는 화면에 쓰지 않는다. Bearer 인증이라 CSRF 대상이 아니다.
// 화면 연결(알약 동작 · Stop)은 `AgentTerminalFlow.swift` · `AgentStopStore.swift`다.

/// 앱이 서버에 보내기 전에 막는 요청 (서버가 400으로 거절할 것을 보내지 않는다)
public enum AgentSessionRequestError: Error, Equatable, Sendable {
    /// 세션 이름이 trim 뒤 1–200자가 아니다
    case invalidName
    /// 이어받기 요청이 서버 모양(정규 소문자 UUID · 가상 루트 `/taskforce/ws_<소문자 UUID>`)이 아니다: 경로 · 옵션 모양이 서버로 가지 않는다
    case invalidAttach
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

/// `POST /api/v2/agent-sessions/attach` 본문 (서버 `attachAgentSessionRequestSchema`, strict): 경로는 없다 — 가상 루트뿐
struct AttachAgentSessionRequest: Encodable {
    let bridgeID: String
    let adapter: String
    let externalSessionID: String
    let workspaceRef: String

    enum CodingKeys: String, CodingKey {
        case adapter
        case bridgeID = "bridge_id"
        case externalSessionID = "external_session_id"
        case workspaceRef = "workspace_ref"
    }
}

/// 서버가 이어받기를 지금 열어 두었나 (사용자의 Mac 화면이 "Resume here"를 보일지의 근거)
public enum AgentAttachAvailability: Equatable, Sendable {
    /// 켜져 있고 이 사용자에게 열려 있다
    case enabled
    /// 꺼져 있거나 이 사용자는 대상이 아니다 (플래그 꺼짐 · 베타 명단 밖은 같은 404다)
    case disabled
    /// 알 수 없다 (네트워크 · 로그인 · 예상 밖 응답): 화면은 보이지 않는다
    case unknown
}

enum AgentAttachShape {
    /// 정규 소문자 UUID (`UUID` 왕복이 같다)
    static func isCanonicalUUID(_ value: String) -> Bool {
        value.utf8.count == 36 && UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    /// `/taskforce/ws_<정규 소문자 UUID>`
    static func isVirtualRoot(_ value: String) -> Bool {
        let prefix = "/taskforce/ws_"
        return value.hasPrefix(prefix) && isCanonicalUUID(String(value.dropFirst(prefix.count)))
    }
}

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

    /// 외부 세션 이어받기 (OA 외부 세션 PR2m, 서버 PR2s): Taskforce 밖에서 시작한 Claude Code 세션의 UUID와 **가상 루트**를 보낸다 (경로는 가지 않는다). 사용자가 로컬 Resume here를 확인한 뒤에만 부른다.
    /// 서버 모양이 아니면(정규 소문자 UUID · `/taskforce/ws_<소문자 UUID>`가 아니면) 보내지 않고 `invalidAttach`를 던진다.
    /// 201 `created` · 200 `existing`(멱등). 404 = 꺼짐 · 베타 명단 밖 · 이 Mac의 연결 없음, 409(`conflict`로 읽힌다: `session_in_use` · `workspace_mismatch`) = 다른 곳이 쥠, 403 = adapter 불허, 429 = 너무 잦음
    public func attachAgentSession(bridgeID: UUID, adapter: String, externalSessionID: String, workspaceRef: String) async throws -> AttachAgentSessionResponse {
        guard AgentAttachShape.isCanonicalUUID(externalSessionID), AgentAttachShape.isVirtualRoot(workspaceRef), adapter.hasPrefix("agent:") else { throw AgentSessionRequestError.invalidAttach }
        let body = AttachAgentSessionRequest(bridgeID: bridgeID.lowercased, adapter: adapter, externalSessionID: externalSessionID, workspaceRef: workspaceRef)
        return try await send(.post, "agent-sessions/attach", body: body, version: .v2)
    }

    /// 서버가 이어받기를 열어 두었나: 서버 순서(꺼짐 404 → 인증 → 베타 명단 404 → **본문 400**)를 이용해 **일부러 빈 본문**을 보낸다 — 열려 있으면 400 `invalid_request`, 꺼져 있거나 명단 밖이면 404.
    /// 본문 검사가 속도 제한 · 저장보다 앞이라 한도를 쓰지도 아무것도 만들지도 않는다 (`docs/agent-gateway.md` 18-2). 그 밖의 답 · 네트워크 오류는 `unknown`: 화면은 보이지 않는다
    public func agentAttachAvailability() async -> AgentAttachAvailability {
        do {
            let _: AttachAgentSessionResponse = try await send(.post, "agent-sessions/attach", body: EmptyAgentSessionRequest(), version: .v2)
            return .unknown
        } catch let error as APIError {
            if case .server(400, .invalidRequest, _) = error { return .enabled }
            if case .server(404, _, _) = error { return .disabled }
            return .unknown
        } catch {
            return .unknown
        }
    }
}
