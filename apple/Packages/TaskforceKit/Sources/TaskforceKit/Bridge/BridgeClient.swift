#if os(macOS)
import Foundation

// bridge route 다섯의 전송 (OA D2b 계약 2.2 · 2.11). 전송이고 재시도 정책은 `Outbox` · `BridgeRuntime`의 몫이다.
// 요청 만들기는 `APIClient.makeRequest`를 다시 쓴다 (Bearer · 주소 · Accept). 장치 secret은 헤더 `X-Taskforce-Bridge-Secret`로만 보낸다.
// 로그에 본문 · secret · 헤더를 남기지 않는다.

/// 사용자 토큰과 그 토큰의 사용자. 요청 직전 파티션 사용자와 대조한다 (ONE-TF-09 c: 토큰 공급과 계정 전환 사이의 경쟁)
public struct BridgeBearer: Sendable {
    public let userID: UUID
    public let accessToken: String

    public init(userID: UUID, accessToken: String) {
        self.userID = userID
        self.accessToken = accessToken
    }
}

public enum BridgeClientError: Error, Equatable, Sendable {
    /// 401: 사용자 토큰 또는 장치 secret이 맞지 않다
    case unauthorized
    /// 403: bridge가 폐기됐다 (register에서는 `reactivate`가 필요하다는 뜻)
    case forbidden
    /// 404: bridge 행이 없다 (다른 환경 · 지워짐) 또는 ack의 그 명령이 없다
    case notFound
    /// 409 `too_many_bridges` (register): 이 계정의 Mac이 10대다
    case tooManyBridges
    case conflict
    /// 429: `Retry-After`초 동안 그 route를 멈춘다
    case rateLimited(retryAfter: TimeInterval)
    case badRequest
    case server(status: Int)
    case transport(String)
    case decoding
    /// 토큰의 사용자가 이 파티션의 사용자가 아니다: 보내지 않았다
    case accountChanged
    case notSignedIn
    /// 서버 주소가 https도 loopback도 아니다: 사용자 토큰 · 장치 secret을 평문으로 보내지 않는다 (보내지 않았다)
    case insecureEndpoint
}

/// bridge 요청을 보낼 수 있는 주소 (OA D2b 검토 반영 7장 D · security 6): https, 또는 개발용 loopback(http)만
public enum BridgeEndpointPolicy {
    public static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]" || host.hasSuffix(".localhost")
    }

    public static func allows(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": url.host() != nil
        case "http": isLoopback(url)
        default: false
        }
    }
}

/// 리다이렉트를 따르지 않는다: 사용자 토큰 · 장치 secret이 다른 주소로 새지 않게, 3xx는 그대로 오류로 본다
private final class RedirectRefuser: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public struct BridgeClient: Sendable {
    public typealias BearerProvider = @Sendable () async throws -> BridgeBearer

    static let defaultRetryAfter: TimeInterval = 30
    static let requestTimeout: TimeInterval = 30
    /// 긴 대기 요청의 여유: 서버 route `maxDuration = 30` · 대기 25초
    static let longPollSlack: TimeInterval = 10
    /// 응답 본문 상한: bridge 응답은 수 KB이고 가장 큰 목록도 1MB 아래다. 넘으면 서버가 아닌 무엇이 끼어들었다고 보고 일시 실패로 다룬다
    static let maxResponseBytes = 4_000_000

    private let api: APIClient
    private let session: URLSession
    private let expectedUserID: UUID
    private let bearer: BearerProvider
    private let endpointAllowed: Bool

    public init(baseURL: URL, session: URLSession, expectedUserID: UUID, bearer: @escaping BearerProvider) {
        // `makeRequest`만 쓴다 (토큰은 `bearer`가 따로 준다)
        self.api = APIClient(baseURL: baseURL, session: session, token: { throw APIError.notSignedIn })
        self.session = session
        self.expectedUserID = expectedUserID
        self.bearer = bearer
        self.endpointAllowed = BridgeEndpointPolicy.allows(baseURL)
    }

    // MARK: route

    public func register(_ request: BridgeV1RegisterRequest) async throws -> BridgeV1RegisterResponse {
        try await send(.post, "bridge/register", body: request, secret: nil, isRegister: true)
    }

    public func revoke(bridgeID: String) async throws -> BridgeV1RevokeResponse {
        try await send(.delete, "bridge/register", body: BridgeV1RevokeRequest(bridgeID: bridgeID), secret: nil)
    }

    public func commands(bridgeID: String, secret: String, after: Int, wait: Int) async throws -> BridgeV1CommandsResponse {
        let query = BridgeV1CommandsQuery(bridgeID: bridgeID, after: after, wait: wait)
        let timeout = wait > 0 ? Double(wait) + Self.longPollSlack : Self.requestTimeout
        return try await send(.get, "bridge/commands", query: query.queryItems, body: nil, secret: secret, timeout: timeout)
    }

    public func ack(_ request: BridgeV1AckRequest, secret: String) async throws -> BridgeV1AckResponse {
        try await send(.post, "bridge/ack", body: request, secret: secret)
    }

    /// 저장해 둔 ack 본문을 그대로 다시 보낸다 (ack outbox)
    public func ack(bodyJSON: String, secret: String) async throws -> BridgeV1AckResponse {
        try await send(.post, "bridge/ack", rawBody: Data(bodyJSON.utf8), secret: secret)
    }

    /// `eventJSON`은 outbox에 저장한 사건 JSON 그대로다 (같은 event id로 다시 보낸다)
    public func events(bridgeID: String, secret: String, eventJSON: [String]) async throws -> BridgeV1EventsResponse {
        try await send(.post, "bridge/events", rawBody: BridgeV1EventsRequest.body(bridgeID: bridgeID, eventJSON: eventJSON), secret: secret)
    }

    public func heartbeat(_ request: BridgeV1HeartbeatRequest, secret: String) async throws -> BridgeV1HeartbeatResponse {
        try await send(.post, "bridge/heartbeat", body: request, secret: secret)
    }

    /// 도구 호출 판정 (OA D3a 3.1, D3c-2). 시간 예산이 짧다 (훅이 1.5초 안에 답해야 한다): 호출한 쪽이 `timeout`(1.0초)을 준다. 재시도는 하지 않는다
    public func toolDecision(_ request: BridgeV1ToolDecisionRequest, secret: String, timeout: TimeInterval) async throws -> BridgeV1ToolDecisionResponse {
        try await send(.post, "bridge/tool-decision", body: request, secret: secret, timeout: timeout)
    }

    /// 이 Mac에서 답한 비밀값을 서버에 표시한다 (OA F2 · D4b-m-2). 값은 가지 않는다: 본문은 `bridge_id` · `agent_task_id` · `request_digest` 셋뿐이다. 주소는 상수이고 쿼리 · 경로 인자는 0이다.
    /// 사용자가 접힌 "Answer sent" 줄을 보고 있다: 시간 제한은 10초다 (재시도는 호출한 쪽의 결과 표, 최대 3번)
    public func answerLocal(_ request: BridgeV1AnswerLocalRequest, secret: String) async throws -> BridgeV1AnswerLocalResponse {
        try await send(.post, Self.answerLocalPath, body: request, secret: secret, timeout: Self.answerLocalTimeout)
    }

    // MARK: 전송

    static let answerLocalPath = "bridge/answer-local"
    static let answerLocalTimeout: TimeInterval = 10

    private func send<T: Decodable>(
        _ method: APIClient.Method, _ path: String, query: [URLQueryItem] = [], body: (any Encodable)?, secret: String?, timeout: TimeInterval = BridgeClient.requestTimeout,
        isRegister: Bool = false
    ) async throws -> T {
        let token = try await userToken()
        var request: URLRequest
        do {
            request = try api.makeRequest(method, path, query: query, body: body, token: token, timeout: timeout)
        } catch {
            // 우리 쪽에서 요청을 만들지 못했다 (보내지 않았다): 서버가 본문을 읽지 못한 `decoding`(2xx)과 다르다
            throw BridgeClientError.badRequest
        }
        return try await perform(&request, secret: secret, isRegister: isRegister)
    }

    private func send<T: Decodable>(_ method: APIClient.Method, _ path: String, rawBody: Data, secret: String?) async throws -> T {
        let token = try await userToken()
        var request = try api.makeRequest(method, path, body: nil, token: token, timeout: Self.requestTimeout)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = rawBody
        return try await perform(&request, secret: secret, isRegister: false)
    }

    /// 토큰을 받고, 그 토큰의 사용자가 이 파티션의 사용자인지 요청을 만들기 직전에 다시 본다
    private func userToken() async throws -> String {
        guard endpointAllowed else { throw BridgeClientError.insecureEndpoint } // 토큰을 꺼내기도 전에 막는다
        let bearer: BridgeBearer
        do {
            bearer = try await self.bearer()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw BridgeClientError.transport(String(describing: error.code))
        } catch let error as APIError {
            if case .transport(let detail) = error { throw BridgeClientError.transport(detail) }
            if let status = error.status { throw Self.error(status: status, retryAfter: nil, data: Data(), isRegister: false) }
            throw BridgeClientError.notSignedIn
        } catch {
            throw BridgeClientError.notSignedIn
        }
        guard bearer.userID == expectedUserID else { throw BridgeClientError.accountChanged }
        return bearer.accessToken
    }

    private func perform<T: Decodable>(_ request: inout URLRequest, secret: String?, isRegister: Bool) async throws -> T {
        if let secret { request.setValue(secret, forHTTPHeaderField: "X-Taskforce-Bridge-Secret") }
        var data = Data()
        let http: HTTPURLResponse
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: RedirectRefuser())
            guard let received = response as? HTTPURLResponse else { throw BridgeClientError.server(status: 0) }
            http = received
            // 본문은 읽으면서 센다: 알린 길이가 상한을 넘으면 읽지 않고, 넘기 시작하면 거기서 끊는다 (끝까지 메모리에 받은 뒤 세지 않는다)
            guard http.expectedContentLength <= Int64(Self.maxResponseBytes) else { throw BridgeClientError.server(status: http.statusCode) }
            for try await byte in bytes {
                data.append(byte)
                guard data.count <= Self.maxResponseBytes else { throw BridgeClientError.server(status: http.statusCode) }
            }
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw BridgeClientError.transport(String(describing: error.code))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(status: http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After"), data: data, isRegister: isRegister)
        }
        do {
            return try TaskforceJSON.decoder().decode(T.self, from: data)
        } catch {
            throw BridgeClientError.decoding
        }
    }

    // MARK: 상태 → 오류

    static func error(status: Int, retryAfter: String?, data: Data, isRegister: Bool) -> BridgeClientError {
        switch status {
        case 400: return .badRequest
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404: return .notFound
        case 409:
            if isRegister, case .server(_, _, let message) = APIClient.error(status: status, data: data), message == "too_many_bridges" { return .tooManyBridges }
            return .conflict
        case 429: return .rateLimited(retryAfter: retryAfterSeconds(retryAfter))
        default: return .server(status: status)
        }
    }

    /// `Retry-After`는 초 단위 정수만 읽는다. 없거나 읽을 수 없으면 30초, 0은 1초, 위는 1시간으로 자른다
    static func retryAfterSeconds(_ header: String?) -> TimeInterval {
        guard let header, let seconds = Int(header.trimmingCharacters(in: .whitespaces)), seconds >= 0 else { return defaultRetryAfter }
        return TimeInterval(min(max(seconds, 1), 3600))
    }
}
#endif
