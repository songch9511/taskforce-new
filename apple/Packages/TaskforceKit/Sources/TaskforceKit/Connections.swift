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
        case .gmail: "Beta · Google verification pending"
        default: nil
        }
    }

    /// 연결 전에 보여 주는 "읽는 것". 비어 있으면 확인 없이 바로 권한 화면으로 간다.
    /// Google · Gmail은 Google이 요구하는 앱 안 공개라 docs/go-live/google-verification.md 2-4의 문구를 그대로 쓴다.
    public var readsBeforeConnecting: [String] {
        switch self {
        case .google:
            [
                "Calendar: event titles, times, attendees",
                // G2(참석한 회의의 전사를 읽는가)는 dev 회의 시험 전이라 그대로 둔다. 못 읽으면 이 한 줄만 "meetings you host"로
                // (서버 google/unverified.ts LIST_ATTENDED_MEETINGS · 처리방침 3장과 같이): google-integration.md 3장
                "Meet: transcripts of meetings you attend",
                "Read-only. Sent to AI only after your consent. Taskforce asks AI providers not to use your text for training or keep it after a request. If no provider meets those conditions, we don't send it.",
            ]
        case .gmail:
            [
                "Read-only email access: messages you sent or received. Newsletters and promotions are skipped. Taskforce never sends or changes email.",
                "Read-only. Sent to AI only after your consent. Taskforce asks AI providers not to use your text for training or keep it after a request. If no provider meets those conditions, we don't send it.",
                "Google verification is pending. Google may show an unverified app warning before you connect.",
            ]
        case .slack:
            [
                "DMs and group DMs",
                "Channel threads you write in or are mentioned in",
                "New messages only. Taskforce never sends anything.",
            ]
        default: []
        }
    }

    /// 연결 끊기 확인 문구. Slack은 끊으면 Taskforce에 있던 Slack 글을 지운다 (docs/go-live/slack-integration.md D3)
    public var disconnectNote: String {
        switch self {
        case .slack: "Slack messages are removed from Taskforce. Tasks stay."
        default: Self.defaultDisconnectNote
        }
    }

    public static let defaultDisconnectNote = "Tasks already found stay."

    /// `connections.provider` 값으로 (모르는 서비스는 기본 문구)
    public static func disconnectNote(for provider: String) -> String {
        ConnectionProvider(rawValue: provider)?.disconnectNote ?? defaultDisconnectNote
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
    /// 서버가 동기화하는 동안의 잠금 (시작 시각). 끝나면 비운다 (`ConnectionSync`)
    public let syncStartedAt: Date?

    public static let columns = "id, provider, display_name, status, last_synced_at, last_error, sync_started_at"

    enum CodingKeys: String, CodingKey {
        case id, provider, status
        case displayName = "display_name"
        case lastSyncedAt = "last_synced_at"
        case lastError = "last_error"
        case syncStartedAt = "sync_started_at"
    }

    public init(
        id: UUID, provider: String, displayName: String?, status: ConnectionStatus?, lastSyncedAt: Date?, lastError: String?,
        syncStartedAt: Date? = nil
    ) {
        self.id = id
        self.provider = provider
        self.displayName = displayName
        self.status = status
        self.lastSyncedAt = lastSyncedAt
        self.lastError = lastError
        self.syncStartedAt = syncStartedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        provider = try c.decode(String.self, forKey: .provider)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        status = (try? c.decodeIfPresent(String.self, forKey: .status)).flatMap { $0.flatMap(ConnectionStatus.init(rawValue:)) }
        lastSyncedAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        syncStartedAt = try c.decodeIfPresent(Date.self, forKey: .syncStartedAt)
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

    /// 연결 목록 한 줄의 상태. 동기화 중이면 "Syncing…" (작은 진행 표시와 함께)
    public func statusLine(for provider: ConnectionProvider, syncing: Bool, comingSoon: Bool, now: Date = Date()) -> ConnectionStatusLine? {
        if comingSoon, !isConnected { return ConnectionStatusLine("Coming soon") }
        switch self {
        case .notConnected:
            return provider.note.map { ConnectionStatusLine($0) }
        case .needsReconnect:
            return ConnectionStatusLine("Reconnect to keep syncing", isAlert: true)
        case .connected, .syncFailed:
            if syncing { return ConnectionStatusLine(ConnectionSync.label, showsProgress: true) }
            guard case .connected(let record) = self else { return ConnectionStatusLine("Last sync failed", isAlert: true) }
            let synced = record.lastSyncedAt.map { "Synced \(WhenText.relative($0, now: now))" } ?? "Connected"
            return ConnectionStatusLine([record.displayName, synced].compactMap { $0 }.joined(separator: " · "))
        }
    }
}

public struct ConnectionStatusLine: Equatable, Sendable {
    public let text: String
    /// 빨강 (다시 연결 · 실패)
    public let isAlert: Bool
    /// 글자 앞 작은 진행 표시 (동기화 중)
    public let showsProgress: Bool

    public init(_ text: String, isAlert: Bool = false, showsProgress: Bool = false) {
        self.text = text
        self.isAlert = isAlert
        self.showsProgress = showsProgress
    }
}

/// 동기화 진행 표시 (C11 첫 동기화 경험). 서버 잠금(`sync_started_at`)이 기준이고,
/// 연결 직후 · Sync Now 직후 서버 잠금이 보이기 전까지는 앱이 먼저 "Syncing…"을 보여 준다 (`requestedAt`).
public enum ConnectionSync {
    public static let label = "Syncing…"
    /// 서버 잠금이 이보다 오래되면 중간에 죽은 실행으로 본다 (서버 `SYNC_LEASE_MINUTES`와 같다)
    public static let leaseTimeout: TimeInterval = 10 * 60
    /// 앱이 먼저 보여 주는 "Syncing…"의 최대 시간 (서버 잠금이 끝내 보이지 않으면 거둔다)
    public static let optimisticWindow: TimeInterval = 90
    /// 기기와 서버의 시계 차이
    static let clockTolerance: TimeInterval = 10
    /// 동기화 중일 때 연결을 다시 읽는 간격 (화면이 보이는 동안만)
    public static let pollInterval: Duration = .seconds(6)

    /// 서버가 이 연결을 지금 동기화하는 중인지
    public static func isLeased(_ record: ConnectionRecord, at now: Date) -> Bool {
        guard let started = record.syncStartedAt else { return false }
        return now.timeIntervalSince(started) < leaseTimeout
    }

    /// "Syncing…"을 보여 줄지. `requestedAt`: 이 서비스를 연결했거나 Sync Now를 누른 때 (앱 시계)
    public static func isSyncing(_ record: ConnectionRecord, requestedAt: Date?, at now: Date) -> Bool {
        if isLeased(record, at: now) { return true }
        guard let requestedAt, now.timeIntervalSince(requestedAt) < optimisticWindow else { return false }
        // 기다리기 시작한 뒤에 끝난 동기화가 있으면 끝남
        guard let last = record.lastSyncedAt else { return true }
        return last < requestedAt.addingTimeInterval(-clockTolerance)
    }

    /// 연결 중 하나라도 동기화 중인지 (빈 목록의 "Syncing…" 한 줄 · 다시 읽기를 이어 갈지)
    public static func anySyncing(_ records: [ConnectionRecord], requested: [String: Date], at now: Date) -> Bool {
        records.contains { isSyncing($0, requestedAt: requested[$0.provider], at: now) }
    }

    /// 연결을 새로 읽은 뒤 남길 앱 표시: 서버 잠금이 보였거나(그다음은 서버가 정한다) 동기화가 끝났거나 시간이 지난 것은 거둔다
    public static func pending(_ requested: [String: Date], after records: [ConnectionRecord], at now: Date) -> [String: Date] {
        requested.filter { provider, since in
            let mine = records.filter { $0.provider == provider }
            if mine.contains(where: { isLeased($0, at: now) }) { return false }
            return mine.contains { isSyncing($0, requestedAt: since, at: now) }
                || (mine.isEmpty && now.timeIntervalSince(since) < optimisticWindow)
        }
    }
}

/// `POST /connections/sync`(Sync Now)가 실패했을 때 할 일
public enum SyncNowFailure: Equatable, Sendable {
    /// 이미 동기화 중이거나 방금 동기화함 (429 rate_limited): 오류가 아니다. 연결을 다시 읽어 "Syncing…" · "Synced just now"로 보여 준다
    case alreadySyncing
    /// 외부 AI 처리 동의가 먼저 필요함 (409 conflict)
    case consentRequired
    case failed(String)

    public static func classify(_ error: APIError) -> SyncNowFailure {
        switch error {
        case .server(_, .rateLimited, _), .unexpectedStatus(429): .alreadySyncing
        case .server(_, .conflict, _): .consentRequired
        default: .failed(error.userMessage)
        }
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
        /// 연결됐지만 권한 화면에서 일부 권한의 체크를 뺌: 되는 쪽만 동기화한다 (Google, 서버 G10 `connected_partial`)
        case connectedPartial
        /// 권한 화면에서 필요한 권한의 체크를 빼서 연결하지 않음 (Gmail, 서버 G10 `missing_scope`)
        case missingScope
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
            case "connected_partial": self = .connectedPartial
            case "missing_scope": self = .missingScope
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
            case .connected, .connectedEmpty, .connectedNoMeetings, .connectedPartial: true
            default: false
            }
        }

        /// 화면에 보여 줄 한 줄. 문제없이 연결됐거나 사용자가 취소했으면 nil (조용히 반영한다).
        public var message: String? {
            switch self {
            case .connected, .denied: nil
            case .connectedEmpty: "Connected. Share pages with Taskforce in Notion to start."
            case .connectedNoMeetings: "Connected. No meetings to read yet."
            case .connectedPartial: "Connected. Some access is off."
            case .missingScope: "Allow access to connect."
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
