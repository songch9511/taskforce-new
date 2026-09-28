import Foundation

/// 연동 서비스. 1단계(go live)는 앱에서 바로 연결하고, 2단계는 "Want this"로 수요만 모은다 (docs/GO_LIVE.md).
public enum ConnectionProvider: String, CaseIterable, Sendable, Codable, Hashable, Identifiable {
    case notion, google, gmail, slack
    case microsoft, zoom, github, linear, jira

    public static let stageOne: [ConnectionProvider] = [.notion, .google, .gmail, .slack]
    public static let stageTwo: [ConnectionProvider] = [.microsoft, .zoom, .github, .linear, .jira]

    public var id: String { rawValue }

    public var isStageOne: Bool { Self.stageOne.contains(self) }

    public var displayName: String {
        switch self {
        case .notion: "Notion"
        case .google: "Google Calendar & Meet"
        case .gmail: "Gmail"
        case .slack: "Slack"
        case .microsoft: "Microsoft 365"
        case .zoom: "Zoom"
        case .github: "GitHub"
        case .linear: "Linear"
        case .jira: "Jira"
        }
    }

    /// 목록에 붙는 짧은 안내 (없으면 nil)
    public var note: String? {
        switch self {
        case .gmail: "Beta · Reconnect every 7 days"
        default: nil
        }
    }

    /// 연결 전에 보여 주는 "읽는 것" (Google만, 세 줄)
    public var readsBeforeConnecting: [String] {
        switch self {
        case .google:
            [
                "Calendar: event titles, times, and attendees",
                "Meet: transcripts of meetings you attend",
                "Read-only. Taskforce never changes or sends anything.",
            ]
        default: []
        }
    }

    /// Figma Source icon이 있는 서비스
    public var logo: SourceService? {
        switch self {
        case .notion: .notion
        case .google: .googleMeet
        case .gmail: .gmail
        case .slack: .slack
        default: nil
        }
    }
}

public enum ConnectionStatus: String, Decodable, Sendable {
    case active, error, revoked, reauth
}

/// `connections` 행 (RLS, 읽기 전용). 토큰은 서버에만 있다.
public struct ConnectionRecord: Decodable, Sendable, Hashable, Identifiable {
    public let id: UUID
    /// 모르는 서비스도 받는다
    public let provider: String
    public let displayName: String?
    /// 모르는 상태는 nil
    public let status: ConnectionStatus?
    public let lastSyncedAt: Date?
    public let lastError: String?

    public static let columns = "id, provider, display_name, status, last_synced_at, last_error"

    enum CodingKeys: String, CodingKey {
        case id, provider, status
        case displayName = "display_name"
        case lastSyncedAt = "last_synced_at"
        case lastError = "last_error"
    }

    public init(id: UUID, provider: String, displayName: String?, status: ConnectionStatus?, lastSyncedAt: Date?, lastError: String?) {
        self.id = id
        self.provider = provider
        self.displayName = displayName
        self.status = status
        self.lastSyncedAt = lastSyncedAt
        self.lastError = lastError
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        provider = try c.decode(String.self, forKey: .provider)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        status = (try? c.decodeIfPresent(String.self, forKey: .status)).flatMap { $0.flatMap(ConnectionStatus.init(rawValue:)) }
        lastSyncedAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
    }
}

/// 서비스 하나의 연결 상태 (연결 목록 한 줄)
public enum ConnectionState: Equatable, Sendable {
    case notConnected
    case connected(ConnectionRecord)
    /// 연결은 있지만 마지막 동기화가 실패함 (잠깐 문제일 수 있다): Sync now
    case syncFailed(ConnectionRecord)
    /// 권한이 끊김 · 만료 (Gmail 테스트 상태 7일 등): 다시 연결
    case needsReconnect(ConnectionRecord)

    public var record: ConnectionRecord? {
        switch self {
        case .notConnected: nil
        case .connected(let r), .syncFailed(let r), .needsReconnect(let r): r
        }
    }

    public var isConnected: Bool { record != nil }

    /// 같은 서비스에 연결이 여럿이면 쓸 수 있는 것을 먼저 본다: active > error > reauth · revoked
    public static func state(for provider: ConnectionProvider, in records: [ConnectionRecord]) -> ConnectionState {
        let mine = records.filter { $0.provider == provider.rawValue }
        func latest(_ status: ConnectionStatus) -> ConnectionRecord? {
            mine.filter { $0.status == status }.max { ($0.lastSyncedAt ?? .distantPast) < ($1.lastSyncedAt ?? .distantPast) }
        }
        if let record = latest(.active) { return .connected(record) }
        if let record = latest(.error) { return .syncFailed(record) }
        if let record = latest(.reauth) ?? latest(.revoked) { return .needsReconnect(record) }
        return .notConnected
    }
}

/// OAuth가 끝나고 서버가 앱으로 돌려보내는 주소.
/// - 동의 성공: `taskforce://connections/{provider}?handoff=<id>` — 앱이 자기 토큰으로 `POST /connections/{provider}/complete`를
///   불러야 연결된다 (연결을 시작한 사용자만 이을 수 있게: 남의 계정을 공격자 계정에 잇는 일을 막는다)
/// - 실패: `taskforce://connections/{provider}?status=denied|error|invalid_state`
public struct ConnectionCallback: Equatable, Sendable {
    public static let scheme = "taskforce"

    /// 연결 결과 (콜백의 status, `/complete` 응답의 status)
    public enum Status: Equatable, Sendable, Decodable {
        case connected
        /// 연결됐지만 공유된 페이지가 없음 (Notion)
        case connectedEmpty
        /// 연결됐지만 가져올 회의가 없음 (Google)
        case connectedNoMeetings
        /// 사용자가 허용하지 않음
        case denied
        case error
        /// 서명이 틀리거나 만료 · 재사용된 state
        case invalidState
        case unknown(String)

        public init(raw: String) {
            switch raw {
            case "connected": self = .connected
            case "connected_empty": self = .connectedEmpty
            case "connected_no_meetings": self = .connectedNoMeetings
            case "denied": self = .denied
            case "error": self = .error
            case "invalid_state": self = .invalidState
            default: self = .unknown(raw)
            }
        }

        public init(from decoder: Decoder) throws {
            self.init(raw: try decoder.singleValueContainer().decode(String.self))
        }

        public var isConnected: Bool {
            switch self {
            case .connected, .connectedEmpty, .connectedNoMeetings: true
            default: false
            }
        }

        /// 화면에 보여 줄 한 줄. 문제없이 연결됐거나 사용자가 취소했으면 nil (조용히 반영한다).
        public var message: String? {
            switch self {
            case .connected, .denied: nil
            case .connectedEmpty: "Connected. Share pages with Taskforce in Notion to start."
            case .connectedNoMeetings: "Connected. No meetings to read yet."
            case .error, .unknown: "Couldn't connect. Try again."
            case .invalidState: "The link expired. Try again."
            }
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// OAuth 동의 성공: 이 id로 `/complete`를 불러야 연결이 생긴다
        case handoff(String)
        /// 실패 (또는 예전 서버가 바로 알려 준 결과)
        case status(Status)
    }

    public let provider: ConnectionProvider?
    public let outcome: Outcome

    public init(provider: ConnectionProvider?, outcome: Outcome) {
        self.provider = provider
        self.outcome = outcome
    }

    public static func parse(_ url: URL) -> ConnectionCallback? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "connections",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let provider = url.pathComponents.first { $0 != "/" }.flatMap(ConnectionProvider.init(rawValue:))
        func value(_ name: String) -> String? {
            components.queryItems?.first { $0.name == name }?.value?.trimmingCharacters(in: .whitespaces)
        }
        if let handoff = value("handoff"), !handoff.isEmpty {
            return ConnectionCallback(provider: provider, outcome: .handoff(handoff))
        }
        return ConnectionCallback(provider: provider, outcome: .status(Status(raw: value("status") ?? "")))
    }
}

/// `POST /connections/{provider}/complete`가 실패했을 때 할 일
public enum ConnectionCompleteFailure: Equatable, Sendable {
    /// 외부 AI 처리 동의가 먼저 필요함 (409 conflict): 동의한 뒤 같은 handoff로 다시 부른다
    case consentRequired
    /// 만료됐거나 내 것이 아님 (404 not_found) 등: 처음부터 다시
    case failed(String)

    public static let retryMessage = "Couldn't connect. Try again."

    public static func classify(_ error: APIError) -> ConnectionCompleteFailure {
        switch error {
        case .server(_, .conflict, _): .consentRequired
        case .server(_, .notFound, _), .unexpectedStatus(404): .failed(retryMessage)
        case .server(_, .rateLimited, _), .transport: .failed(error.userMessage)
        default: .failed(retryMessage)
        }
    }
}

struct CompleteConnectionRequest: Encodable {
    let handoff: String
}

struct CompleteConnectionResponse: Decodable {
    let status: ConnectionCallback.Status
}

/// `POST /connections/{provider}/start`가 실패했을 때 할 일
public enum ConnectionStartFailure: Equatable, Sendable {
    /// 서버에 아직 없는 서비스 (400 invalid_request, 또는 예전 서버의 404)
    case comingSoon
    /// 외부 AI 처리 동의가 먼저 필요함 (409 conflict)
    case consentRequired
    case other

    public static func classify(_ error: APIError) -> ConnectionStartFailure {
        switch error {
        case .server(_, .invalidRequest, _), .server(404, _, _), .unexpectedStatus(404): .comingSoon
        case .server(_, .conflict, _): .consentRequired
        default: .other
        }
    }
}

/// 개인정보 처리방침 · 이용약관 (App Store 5.1.1(i)): 계정 화면 · 설정 · 동의 화면에 둔다
public enum LegalLinks {
    public static let privacy = URL(string: "https://taskforcelabs.dev/privacy")!
    public static let terms = URL(string: "https://taskforcelabs.dev/terms")!
}
