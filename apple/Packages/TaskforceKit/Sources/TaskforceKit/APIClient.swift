import Foundation

/// contract.ts `apiErrorCodeSchema`
public enum APIErrorCode: String, Decodable, Sendable {
    case unauthorized
    case invalidRequest = "invalid_request"
    case notFound = "not_found"
    case conflict
    case rateLimited = "rate_limited"
    case internalError = "internal_error"
    case aiBudgetExhausted = "ai_budget_exhausted"
    case aiPricingUnavailable = "ai_pricing_unavailable"
    case aiProviderBoundViolation = "ai_provider_bound_violation"
    case aiBudgetUnavailable = "ai_budget_unavailable"
    case aiTimeout = "ai_timeout"
    case aiUnavailable = "ai_unavailable"
}

public enum APIError: Error, Equatable, Sendable, CustomStringConvertible {
    /// 서버가 `{ error: { code, message } }`로 답함
    case server(status: Int, code: APIErrorCode, message: String)
    /// 약속한 형식이 아닌 오류 응답
    case unexpectedStatus(Int)
    /// 응답을 읽지 못함
    case decoding(String)
    /// 네트워크 오류
    case transport(String)
    /// 로그인 세션이 없음
    case notSignedIn

    /// 다른 기기 · 파이프라인과 동시에 고쳐서 부딪힘 (409). 다시 읽고 사용자에게 알린다.
    public var isConflict: Bool {
        if case .server(_, .conflict, _) = self { return true }
        return false
    }

    /// 외부 AI 처리 동의가 먼저 필요함 (`POST /sources` · `/ask` · 연결 시작 · `POST /runs`의 409)
    public var isConsentRequired: Bool { isConflict }

    /// 서버가 돌려준 HTTP 상태 (응답을 받지 못했으면 nil)
    public var status: Int? {
        switch self {
        case .server(let status, _, _), .unexpectedStatus(let status): status
        case .decoding, .transport, .notSignedIn: nil
        }
    }

    /// 화면에 보여줄 한 줄 (화면 틀은 영어, docs/BRAND.md "UI 문구"). 서버의 한국어 설명은 보이지 않는다.
    public var userMessage: String {
        switch self {
        case .server(_, .aiBudgetExhausted, _):
            "Your $10 beta AI allowance cannot cover this request. Reservations count until confirmed. You can still manage tasks and connections."
        case .server(_, .aiPricingUnavailable, _):
            "AI is unavailable because its price limit cannot be verified."
        case .server(_, .aiProviderBoundViolation, _):
            "AI is paused because a provider exceeded its reserved cost."
        case .server(_, .aiBudgetUnavailable, _):
            "Could not verify your AI allowance. Try again later."
        case .server(_, .aiTimeout, _):
            "AI took too long to prepare this handoff. Try again."
        case .server(_, .aiUnavailable, _):
            "AI couldn't prepare this handoff. Try again."
        case .server(_, .conflict, _):
            "This changed somewhere else. It's been refreshed."
        case .server(_, .unauthorized, _):
            // 이 서버가 거절했는데 인증 서버는 계정 · 세션이 있다고 함 (없다고 하면 `onUnauthorized`가 이 기기를 로그아웃시키고 `.notSignedIn`이 된다)
            "Couldn't verify your sign-in. Sign out, then sign in again."
        case .notSignedIn:
            "Sign in to continue."
        case .server(_, .rateLimited, _):
            "Too many requests. Try again in a moment."
        case .server(_, .notFound, _):
            "Not found. It may have been removed."
        case .server, .unexpectedStatus, .decoding:
            "Something went wrong. Try again in a moment."
        case .transport:
            "Can't reach the server. Check your connection."
        }
    }

    public var description: String {
        switch self {
        case .server(let status, let code, let message): "API \(status) \(code.rawValue): \(message)"
        case .unexpectedStatus(let status): "API 예상하지 못한 응답 \(status)"
        case .decoding(let detail): "API 응답 해석 실패: \(detail)"
        case .transport(let detail): "API 연결 실패: \(detail)"
        case .notSignedIn: "로그인 세션 없음"
        }
    }
}

/// Taskforce 서버 `/api/v1` 클라이언트. 모든 쓰기는 여기를 거친다 (서버가 이벤트 · 지표를 남긴다).
/// 토큰은 부를 때마다 받아온다 (`supabase.auth.session.accessToken`은 만료가 가까우면 갱신한다).
public struct APIClient: Sendable {
    public typealias TokenProvider = @Sendable () async throws -> String
    /// 서버가 401을 돌려줬을 때: 이 기기의 세션이 끝났는지 확인하고, 끝났으면(로그아웃시켰으면) true
    public typealias UnauthorizedHandler = @Sendable () async -> Bool

    public let baseURL: URL
    private let session: URLSession
    private let token: TokenProvider
    private let onUnauthorized: UnauthorizedHandler?

    public init(
        baseURL: URL, session: URLSession = .shared, token: @escaping TokenProvider, onUnauthorized: UnauthorizedHandler? = nil
    ) {
        self.baseURL = baseURL
        self.session = session
        self.token = token
        self.onUnauthorized = onUnauthorized
    }

    // MARK: 엔드포인트

    /// 지금 할 일 순서 + 확인 요청 + 주간 질문. 순서는 서버가 정한다.
    public func now() async throws -> NowResponse {
        try await send(.get, "now")
    }

    public func editAction(id: UUID, _ edit: ActionEdit) async throws -> ActionSummary {
        let response: ActionResponse = try await send(.patch, "actions/\(id.lowercased)", body: edit)
        return response.action
    }

    /// 실제로 지우지 않고 취소(dropped)로 둔다 (서버). 확인 요청에 "아니에요"도 이것.
    public func deleteAction(id: UUID) async throws -> ActionSummary {
        let response: ActionResponse = try await send(.delete, "actions/\(id.lowercased)")
        return response.action
    }

    public func confirmAction(id: UUID) async throws -> ActionSummary {
        let response: ActionResponse = try await send(.post, "actions/\(id.lowercased)/confirm")
        return response.action
    }

    public func startAction(id: UUID) async throws -> ActionSummary {
        let response: ActionResponse = try await send(.post, "actions/\(id.lowercased)/start")
        return response.action
    }

    /// 진행 상태 바꾸기: To Do (착수 전으로) · In Progress (착수) · Done (완료). 끝낸 할 일을 To Do · In Progress로 옮기면 다시 연다.
    public func setProgress(_ id: UUID, state: WorkState) async throws -> ActionSummary {
        let response: ActionResponse = try await send(.post, "actions/\(id.lowercased)/progress", body: ProgressRequest(state: state))
        return response.action
    }

    /// 바뀐 할 일을 봤다 (`POST /actions/:id/seen`, 본문 없음 · 204). 서버는 지금 바뀜일 때만 기록한다.
    /// 실패해도 다시 보내지 않는다: 다음 `/now`의 `changed`가 진실이다 (`SeenTracker`).
    public func markSeen(_ id: UUID) async throws {
        try await sendNoContent(.post, "actions/\(id.lowercased)/seen")
    }

    public func handoff(id: UUID, assisted: Bool = true) async throws -> HandoffResponse {
        let body: (any Encodable)? = assisted ? HandoffRequest(mode: "assisted") : nil
        return try await send(.post, "actions/\(id.lowercased)/handoff", body: body)
    }

    /// 빠진 할 일 신고. `quote`는 원문에 그대로 있는 구절이어야 한다 (`SourceText.quote`). 서버가 LLM을 불러 몇 초 걸린다.
    public func reportMissing(sourceID: UUID, quote: String) async throws -> MissingReportResponse {
        try await send(.post, "sources/\(sourceID.lowercased)/missing", body: MissingReportRequest(quote: quote))
    }

    /// 직접 추가 (Mac 런처 "Add “…”"). 기한이 없으면 `due_date: null`.
    /// 원문을 골랐으면 `sourceID`와 `quote`(원문에 그대로 있는 구절, `SourceText.quote`)를 함께 보낸다. 404 = 원문 없음.
    /// 그 구절이 이미 근거인 할 일이 있으면 서버가 그 할 일을 그대로 돌려준다 (200 `already_tracked`).
    public func createAction(
        title: String, dueDate: LocalDate? = nil, sourceID: UUID? = nil, quote: String? = nil
    ) async throws -> CreateActionResponse {
        let body = CreateActionRequest(title: title, dueDate: dueDate, sourceID: sourceID, quote: quote)
        return try await send(.post, "actions", body: body)
    }

    public func answerWeeklyCheck(weekStart: LocalDate, answer: WeeklyCheckAnswer) async throws {
        try await sendNoContent(.post, "weekly-check", body: WeeklyCheckRequest(weekStart: weekStart, answer: answer))
    }

    /// 계정 삭제 (서버가 원문 · 할 일 · 변경 이력을 모두 지운다. 되돌릴 수 없다).
    /// `authorizationCode`: 삭제 직전 Sign in with Apple로 새로 받은 authorization code. 있으면 서버가 Apple 토큰을 폐기한다
    /// (App Store 5.1.1(v)). 사용자가 Apple 확인을 취소했으면 nil로 보내고, 서버는 폐기 없이 지운다.
    /// 성공하면 `SessionStore.accountDeleted()`로 이 기기에 저장된 세션을 지운다.
    public func deleteAccount(authorizationCode: String? = nil) async throws {
        let body = authorizationCode.map(DeleteAccountRequest.init(appleAuthorizationCode:))
        try await sendNoContent(.delete, "account", body: body)
    }

    /// 앱이 앞으로 나올 때마다 한 번 (지표 2 · 3)
    public func appOpened() async throws {
        try await sendNoContent(.post, "metric-events", body: MetricEventRequest(type: "app_opened"))
    }

    // MARK: 프로필 · 동의

    public func profile() async throws -> Profile {
        try await send(.get, "profile")
    }

    /// 이름 · 별칭 · 이메일을 통째로 바꾼다 (동의는 `/consent`로만)
    public func saveProfile(_ profile: Profile) async throws -> Profile {
        try await send(.put, "profile", body: profile)
    }

    /// 외부 AI 처리 동의 (App Store 5.1.2(i)). 동의 전에는 서버가 연동 원문을 AI로 보내지 않는다.
    public func giveAIConsent() async throws {
        try await sendNoContent(.post, "consent", body: ConsentRequest())
    }

    /// 동의 철회: 서버가 이후 원문을 AI로 보내지 않는다
    public func withdrawAIConsent() async throws {
        try await sendNoContent(.delete, "consent")
    }

    /// 처리방침 판과 이 계정에 보일 변경 안내 (읽기만. 본 판은 `PolicyNoticeSeen`이 기기에 적는다)
    public func legal() async throws -> LegalResponse {
        try await send(.get, "legal")
    }

    // MARK: 연동

    /// OAuth 시작 주소. `ASWebAuthenticationSession`으로 열고 `taskforce://connections/{provider}?status=…`로 돌아온다.
    /// 400 invalid_request = 아직 준비되지 않은 서비스, 409 conflict = 동의가 먼저 필요함 (`ConnectionStartFailure`).
    public func startConnection(_ provider: ConnectionProvider) async throws -> URL {
        let response: StartConnectionResponse = try await send(.post, "connections/\(provider.rawValue)/start")
        return response.url
    }

    /// OAuth 콜백의 handoff id로 연결을 마친다. 서버는 연결을 시작한 사용자(이 토큰)일 때만 잇는다.
    /// 404 not_found = 만료됐거나 내 것이 아님, 409 conflict = 동의가 먼저 필요함 (`ConnectionCompleteFailure`).
    public func completeConnection(_ provider: ConnectionProvider, handoff: String) async throws -> ConnectionCallback.Status {
        let response: CompleteConnectionResponse = try await send(
            .post, "connections/\(provider.rawValue)/complete", body: CompleteConnectionRequest(handoff: handoff)
        )
        return response.status
    }

    /// 2단계 서비스 "Want this" (다시 눌러도 그대로)
    public func requestConnection(_ provider: ConnectionProvider) async throws {
        try await sendNoContent(.post, "connection-requests", body: ConnectionRequestBody(provider: provider.rawValue))
    }

    /// 지금 동기화. 서버는 끝날 때까지(최대 4분) 답하지 않아 기다리는 시간을 서버 한도(5분)에 맞춘다.
    /// 이미 동기화 중이거나 방금 동기화했으면 429 rate_limited (`SyncNowFailure.alreadySyncing`), 동의 전이면 409.
    public func syncConnections() async throws {
        try await sendNoContent(.post, "connections/sync", timeout: Self.syncTimeout)
    }

    /// `POST /connections/sync`의 기다리는 시간 (서버 `maxDuration = 300`)
    static let syncTimeout: TimeInterval = 300

    /// 연결 끊기. 이미 들어온 원문과 할 일은 남는다.
    public func disconnect(connectionID: UUID) async throws {
        try await sendNoContent(.delete, "connections/\(connectionID.lowercased)")
    }

    // MARK: 알림

    /// 알림용 기기 토큰 등록 (APNs). 실행 · 로그인마다 불러도 된다: 같은 토큰은 마지막 로그인 계정으로 옮겨 간다.
    public func registerDevice(_ registration: DeviceRegistration) async throws {
        try await sendNoContent(.post, "devices", body: registration)
    }

    /// 로그아웃 전에: 이 기기로 더는 알림을 보내지 않는다
    public func unregisterDevice(token: String) async throws {
        try await sendNoContent(.delete, "devices", body: DeviceToken(token: token))
    }

    // MARK: 원문 · 물어보기

    /// 원문 보내기. 서버가 받은 뒤 뒤에서 읽는다 (202). 동의 전이면 409.
    public func createSource(_ request: CreateSourceRequest) async throws -> CreateSourceResponse {
        try await send(.post, "sources", body: request)
    }

    /// 내 할 일에 대해 묻기. 근거 인용과 함께 답한다. 동의 전이면 409, 너무 자주 물으면 429.
    public func ask(_ question: String) async throws -> AskResponse {
        try await send(.post, "ask", body: AskRequest(question: question))
    }

    // MARK: 실행 (U2, docs/EXECUTION.md)

    /// 할 일에 내장 초안 run을 만든다 (202 `{ run }`). 첫 단계(계획)는 응답 뒤에 돈다. 크레딧은 여기서 보지 않는다:
    /// 모자라면 run이 `hold_reason = credit`으로 기다린다. iPhone은 부르지 않는다 (`RunAvailability.canStart`).
    /// 409 = 외부 AI 처리 동의가 먼저, 404 = 실행을 쓸 수 없음 · 열린 할 일이 아님, 429 = 10분에 10번을 넘음 (`RunStartFailure`).
    /// `request`는 앞뒤 공백을 빼고 2000자로 잘라 보낸다 (`CreateRunRequest`). 빈 요청은 부르는 쪽이 막는다 (서버는 400)
    public func createRun(actionID: UUID, request: String) async throws -> RunSummary {
        let response: RunResponse = try await send(.post, "runs", body: CreateRunRequest(actionID: actionID, request: request))
        return response.run
    }

    /// 다음 단계만 막는다 (이미 부르는 단계는 끝까지 결과를 받는다). 이미 끝난 run은 그대로 200. 없거나 남의 run 404
    public func stopRun(id: UUID) async throws -> RunSummary {
        let response: RunResponse = try await send(.post, "runs/\(id.lowercased)/stop")
        return response.run
    }

    /// 내 크레딧 합계. 404면 nil: 실행을 쓸 수 없는 계정이다 (플래그 꺼짐 · 실행 주체 밖, 서버가 존재를 드러내지 않는다).
    /// `since`(이번 달 사용량의 시작, 보통 `CreditsMonth.start`)는 UTC ISO 8601로 보낸다. 그 전 서버는 이 값을 읽지 않는다.
    /// 서버가 `since`를 받지 않으면(400: 기기 시계가 앞서 서버의 미래 등) `since` 없이 한 번 더 묻는다 (서버의 UTC 이번 달)
    public func credits(since: Date? = nil) async throws -> CreditsSummary? {
        let query = since.map { [URLQueryItem(name: "since", value: $0.ISO8601Format())] } ?? []
        do {
            return try await send(.get, "credits", query: query)
        } catch let error as APIError where error.status == 404 {
            // 실행 route가 없는 옛 서버의 404(형식 없는 응답)도 같다
            return nil
        } catch let error as APIError where error.status == 400 && since != nil {
            return try await credits(since: nil)
        }
    }

    public func aiBudget() async throws -> AiSpendSummary {
        try await send(.get, "ai-budget")
    }

    // MARK: 요청

    enum Method: String {
        case get = "GET", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE"
    }

    func makeRequest(
        _ method: Method, _ path: String, query: [URLQueryItem] = [], body: (any Encodable)?, token: String, timeout: TimeInterval? = nil
    ) throws -> URLRequest {
        var url = baseURL.appending(path: "api/v1")
        url.append(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        if let timeout { request.timeoutInterval = timeout }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try TaskforceJSON.encoder().encode(body)
        }
        return request
    }

    private func perform(
        _ method: Method, _ path: String, query: [URLQueryItem] = [], body: (any Encodable)?, timeout: TimeInterval? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let accessToken: String
        do {
            accessToken = try await token()
        } catch let error as APIError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            // 오프라인에서 토큰을 갱신하다 실패한 것: 로그인이 풀린 게 아니다
            if error.code == .cancelled { throw CancellationError() }
            throw APIError.transport(error.localizedDescription)
        } catch {
            throw APIError.notSignedIn
        }
        let request = try makeRequest(method, path, query: query, body: body, token: accessToken, timeout: timeout)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw APIError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.unexpectedStatus(0) }
        guard (200..<300).contains(http.statusCode) else {
            // 토큰을 거절당함: 세션이 끝난 것으로 확인되면(다른 기기에서 계정 삭제 등) 이 기기는 이미 로그아웃됐다 → 로그인 안내
            if http.statusCode == 401, let onUnauthorized {
                let ended = await onUnauthorized()
                try Task.checkCancellation()
                if ended { throw APIError.notSignedIn }
            }
            throw Self.error(status: http.statusCode, data: data)
        }
        return (data, http)
    }

    private func send<T: Decodable>(_ method: Method, _ path: String, query: [URLQueryItem] = [], body: (any Encodable)? = nil) async throws -> T {
        let (data, _) = try await perform(method, path, query: query, body: body)
        do {
            return try TaskforceJSON.decoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    private func sendNoContent(_ method: Method, _ path: String, body: (any Encodable)? = nil, timeout: TimeInterval? = nil) async throws {
        _ = try await perform(method, path, body: body, timeout: timeout)
    }

    static func error(status: Int, data: Data) -> APIError {
        struct Envelope: Decodable {
            struct Body: Decodable {
                let code: String
                let message: String
            }
            let error: Body
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            // 앞단(프록시 · 게이트웨이)이 막은 429도 "잠시 뒤에"로 보여준다
            return status == 429 ? .server(status: status, code: .rateLimited, message: "") : .unexpectedStatus(status)
        }
        // 모르는 코드는 상태 코드로 짐작한다
        let code = APIErrorCode(rawValue: envelope.error.code) ?? Self.code(guessedFrom: status)
        return .server(status: status, code: code, message: envelope.error.message)
    }

    private static func code(guessedFrom status: Int) -> APIErrorCode {
        switch status {
        case 401: .unauthorized
        case 409: .conflict
        case 429: .rateLimited
        default: .internalError
        }
    }
}

/// POST /api/v1/actions/:id/progress 본문
struct ProgressRequest: Encodable {
    let state: WorkState
}

struct MissingReportRequest: Encodable {
    let quote: String
}

private struct HandoffRequest: Encodable {
    let mode: String
}

/// POST /api/v1/actions 본문. `source_id` · `quote`는 원문을 골랐을 때만 넣는다.
struct CreateActionRequest: Encodable {
    let title: String
    let dueDate: LocalDate?
    let sourceID: UUID?
    let quote: String?

    enum CodingKeys: String, CodingKey {
        case title, quote
        case dueDate = "due_date"
        case sourceID = "source_id"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        if let dueDate {
            try c.encode(dueDate, forKey: .dueDate)
        } else {
            try c.encodeNil(forKey: .dueDate)
        }
        try c.encodeIfPresent(sourceID?.lowercased, forKey: .sourceID)
        try c.encodeIfPresent(quote, forKey: .quote)
    }
}

struct WeeklyCheckRequest: Encodable {
    let weekStart: LocalDate
    let answer: WeeklyCheckAnswer

    enum CodingKeys: String, CodingKey {
        case answer
        case weekStart = "week_start"
    }
}

/// DELETE /api/v1/account 본문 (contract.ts `deleteAccountRequestSchema`)
struct DeleteAccountRequest: Encodable {
    let appleAuthorizationCode: String

    enum CodingKeys: String, CodingKey {
        case appleAuthorizationCode = "apple_authorization_code"
    }
}

/// DELETE /api/v1/devices 본문
struct DeviceToken: Encodable {
    let token: String
}

struct MetricEventRequest: Encodable {
    let type: String
}

extension UUID {
    /// 서버 · Postgres가 쓰는 소문자 표기
    var lowercased: String { uuidString.lowercased() }
}
