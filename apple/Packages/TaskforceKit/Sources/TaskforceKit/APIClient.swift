import Foundation

/// contract.ts `apiErrorCodeSchema`
public enum APIErrorCode: String, Decodable, Sendable {
    case unauthorized
    case invalidRequest = "invalid_request"
    case notFound = "not_found"
    case conflict
    case rateLimited = "rate_limited"
    case internalError = "internal_error"
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

    /// 화면에 보여줄 한 줄
    public var userMessage: String {
        switch self {
        case .server(_, .conflict, _):
            "그사이 다른 곳에서 바뀌었어요. 새로 불러왔으니 다시 확인해 주세요."
        case .server(_, .unauthorized, _), .notSignedIn:
            "로그인이 필요해요. 다시 로그인해 주세요."
        case .server(_, .rateLimited, _):
            "요청이 너무 많아요. 잠시 뒤에 다시 해 주세요."
        case .server(_, .notFound, _):
            "찾을 수 없어요. 이미 지워졌을 수 있어요."
        case .server(_, _, let message) where !message.isEmpty:
            message
        case .server, .unexpectedStatus, .decoding:
            "서버에서 문제가 생겼어요. 잠시 뒤에 다시 해 주세요."
        case .transport:
            "서버에 연결하지 못했어요. 네트워크를 확인해 주세요."
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

    public let baseURL: URL
    private let session: URLSession
    private let token: TokenProvider

    public init(baseURL: URL, session: URLSession = .shared, token: @escaping TokenProvider) {
        self.baseURL = baseURL
        self.session = session
        self.token = token
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

    public func handoff(id: UUID) async throws -> HandoffResponse {
        try await send(.post, "actions/\(id.lowercased)/handoff")
    }

    /// 빠진 할 일 신고. `quote`는 원문에 그대로 있는 구절이어야 한다 (`SourceText.quote`). 서버가 LLM을 불러 몇 초 걸린다.
    public func reportMissing(sourceID: UUID, quote: String) async throws -> MissingReportResponse {
        try await send(.post, "sources/\(sourceID.lowercased)/missing", body: MissingReportRequest(quote: quote))
    }

    public func answerWeeklyCheck(weekStart: LocalDate, answer: WeeklyCheckAnswer) async throws {
        try await sendNoContent(.post, "weekly-check", body: WeeklyCheckRequest(weekStart: weekStart, answer: answer))
    }

    /// 앱이 앞으로 나올 때마다 한 번 (지표 2 · 3)
    public func appOpened() async throws {
        try await sendNoContent(.post, "metric-events", body: MetricEventRequest(type: "app_opened"))
    }

    // MARK: 요청

    enum Method: String {
        case get = "GET", post = "POST", patch = "PATCH", delete = "DELETE"
    }

    func makeRequest(_ method: Method, _ path: String, body: (any Encodable)?, token: String) throws -> URLRequest {
        var url = baseURL.appending(path: "api/v1")
        url.append(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try TaskforceJSON.encoder().encode(body)
        }
        return request
    }

    private func perform(_ method: Method, _ path: String, body: (any Encodable)?) async throws -> (Data, HTTPURLResponse) {
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
        let request = try makeRequest(method, path, body: body, token: accessToken)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw APIError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.unexpectedStatus(0) }
        guard (200..<300).contains(http.statusCode) else { throw Self.error(status: http.statusCode, data: data) }
        return (data, http)
    }

    private func send<T: Decodable>(_ method: Method, _ path: String, body: (any Encodable)? = nil) async throws -> T {
        let (data, _) = try await perform(method, path, body: body)
        do {
            return try TaskforceJSON.decoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    private func sendNoContent(_ method: Method, _ path: String, body: (any Encodable)? = nil) async throws {
        _ = try await perform(method, path, body: body)
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

struct MissingReportRequest: Encodable {
    let quote: String
}

struct WeeklyCheckRequest: Encodable {
    let weekStart: LocalDate
    let answer: WeeklyCheckAnswer

    enum CodingKeys: String, CodingKey {
        case answer
        case weekStart = "week_start"
    }
}

struct MetricEventRequest: Encodable {
    let type: String
}

extension UUID {
    /// 서버 · Postgres가 쓰는 소문자 표기
    var lowercased: String { uuidString.lowercased() }
}
