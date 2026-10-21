#if os(macOS)
import Foundation

// 서버로 가는 외부 세션 목록 (OA 외부 세션 PR1, 계약 16장 · 17장): 제목 · 상태 · 마지막 활동 시각 · 불투명 id뿐이다.
// 대화 본문 · 경로 · 폴더 이름 · Claude 세션 id는 보내지 않는다. 서버 route는 `PUT /api/v2/external-sessions` (`src/app/api/v2/external-sessions/route.ts`, 스냅샷 교체).

/// 서버 `externalSessionReportRequestSchema`의 행 한 개 (strict)
public struct ExternalSessionReportRow: Encodable, Equatable, Sendable {
    /// 불투명 id (`ExternalSessionKey.ref`, 소문자 hex 64자)
    public var id: String
    public var title: String?
    /// `available · running_claude_app · running_terminal · running_elsewhere · unknown · unavailable`
    public var state: String
    /// ISO 8601 UTC (`2026-10-21T09:00:00Z`)
    public var lastActivityAt: String

    enum CodingKeys: String, CodingKey {
        case id, title, state
        case lastActivityAt = "last_activity_at"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        // 서버 칸은 nullable이지만 있어야 한다 (strict): 제목이 없으면 null을 보낸다
        if let title { try container.encode(title, forKey: .title) } else { try container.encodeNil(forKey: .title) }
        try container.encode(state, forKey: .state)
        try container.encode(lastActivityAt, forKey: .lastActivityAt)
    }
}

struct ExternalSessionReportRequest: Encodable {
    let bridgeID: String
    let sessions: [ExternalSessionReportRow]

    enum CodingKeys: String, CodingKey {
        case bridgeID = "bridge_id"
        case sessions
    }
}

struct ExternalSessionReportResponse: Decodable, Equatable {
    let kept: Int
    let removed: Int
}

public enum ExternalSessionReport {
    /// 서버가 받는 목록의 상한 (`EXTERNAL_SESSIONS_MAX`)
    public static let maxRows = 50

    /// 보이는 이유를 서버 여섯 말로 접는다. 이미 이어받은 세션(`In Taskforce`)은 `agent_sessions`에 있으니 보내지 않는다 (nil)
    public static func state(for status: ExternalSessionStatus) -> String? {
        switch status {
        case .available: "available"
        case .held(.claudeApp): "running_claude_app"
        case .held(.terminal): "running_terminal"
        case .held(.background), .held(.unknown): "running_elsewhere"
        case .couldNotCheck: "unknown"
        case .cannotResume: "unavailable"
        case .inTaskforce: nil
        }
    }

    public static func rows(from rows: [ExternalSessionRow]) -> [ExternalSessionReportRow] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return rows.prefix(maxRows).compactMap { row in
            guard let state = state(for: row.status) else { return nil }
            return ExternalSessionReportRow(id: row.ref, title: row.title.flatMap(ExternalSessionRules.sanitizedTitle), state: state, lastActivityAt: formatter.string(from: row.lastActivity))
        }
    }
}

extension APIClient {
    /// 이 Mac의 외부 세션 목록을 스냅샷으로 알린다 (이번 목록에 없는 이 Mac의 행은 서버가 지운다). 오류는 던진다 — 부르는 쪽이 나중에 다시 보낸다
    public func reportExternalSessions(bridgeID: UUID, rows: [ExternalSessionReportRow]) async throws {
        let _: ExternalSessionReportResponse = try await send(.put, "external-sessions", body: ExternalSessionReportRequest(bridgeID: bridgeID.lowercased, sessions: rows), version: .v2)
    }
}

/// 목록을 서버에 알리는 속도 조절 (OA 외부 세션 PR1): 바뀐 것만, 30초 안에 다시 보내지 않고, 안 바뀌어도 6시간마다 한 번은 보낸다(서버 보관 14일이 끊기지 않게).
/// - 서버가 길을 닫아 둔 것(404: `EXTERNAL_SESSIONS_REPORT_ENABLED` 꺼짐 · 베타 밖)이면 6시간 물러난다. 30초마다 두드리지 않는다
/// - 400(`invalid_request`)이면 제목을 모두 null로 해서 한 번 더 보낸다. 그것도 거절하면(또는 보낼 제목이 없으면) 6시간 물러난다
/// - 그 밖의 실패(네트워크 · 5xx · 429 · 인증)는 삼키고 다음 호출에서 다시 시도한다
/// - 실패는 구간 코드만 로그에 남긴다. 제목 · id · 경로를 로그에 남기지 않는다
public actor ExternalSessionReporter {
    public typealias Send = @Sendable (_ bridgeID: UUID, _ rows: [ExternalSessionReportRow]) async throws -> Void

    public static let minimumInterval: TimeInterval = 30
    public static let keepalive: TimeInterval = 6 * 3600
    /// 서버가 길을 닫아 두었을 때(404)나 제목을 빼도 거절할 때(400) 물러나는 시간
    public static let backoff: TimeInterval = 6 * 3600

    private let send: Send
    private let clock: @Sendable () -> Date
    private let log: any BridgeLogSink
    private var lastSent: (bridge: UUID, rows: [ExternalSessionReportRow], at: Date)?
    private var lastAttempt: Date?
    private var backoffUntil: Date?

    public init(send: @escaping Send, clock: @escaping @Sendable () -> Date = { Date() }, log: any BridgeLogSink = NoBridgeLog()) {
        self.send = send
        self.clock = clock
        self.log = log
    }

    /// 보냈으면 true
    @discardableResult
    public func report(_ rows: [ExternalSessionRow], bridgeID: UUID) async -> Bool {
        let payload = ExternalSessionReport.rows(from: rows)
        let now = clock()
        guard isDue(payload, bridgeID: bridgeID, now: now) else { return false }
        return await deliver(payload, bridgeID: bridgeID, at: now, resendWithoutTitles: true)
    }

    /// 훑을 때 잡은 계정 · bridge로만 보낸다: 보내기 직전에 `current`(지금의 계정 · bridge)가 같지 않으면 버린다 (버린 것은 속도 조절을 쓰지 않는다).
    /// 속도 조절 · 물러남에 걸려 어차피 안 보낼 때는 `current`를 묻지도 않는다
    @discardableResult
    public func report(_ rows: [ExternalSessionRow], origin: ExternalSessionOrigin, current: @Sendable () async -> ExternalSessionOrigin?) async -> Bool {
        let payload = ExternalSessionReport.rows(from: rows)
        let now = clock()
        guard isDue(payload, bridgeID: origin.bridgeID, now: now) else { return false }
        guard await current() == origin else { return false }
        return await deliver(payload, bridgeID: origin.bridgeID, at: now, resendWithoutTitles: true)
    }

    /// 이 Mac의 목록을 서버에서 비운다 (속도 조절 · 물러남 없이: 로그아웃 때 한 번 하는 일이다)
    @discardableResult
    public func clear(bridgeID: UUID) async -> Bool {
        await deliver([], bridgeID: bridgeID, at: clock(), resendWithoutTitles: false)
    }

    /// 계정이 바뀌었다: 마지막으로 보낸 값과 물러남을 잊는다
    public func reset() {
        lastSent = nil
        lastAttempt = nil
        backoffUntil = nil
    }

    private func isDue(_ payload: [ExternalSessionReportRow], bridgeID: UUID, now: Date) -> Bool {
        if let backoffUntil, now < backoffUntil { return false }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < Self.minimumInterval { return false }
        if let lastSent, lastSent.bridge == bridgeID, lastSent.rows == payload, now.timeIntervalSince(lastSent.at) < Self.keepalive { return false }
        return true
    }

    private func deliver(_ payload: [ExternalSessionReportRow], bridgeID: UUID, at now: Date, resendWithoutTitles: Bool) async -> Bool {
        lastAttempt = now
        do {
            try await send(bridgeID, payload)
            succeeded(payload, bridgeID: bridgeID, at: now)
            return true
        } catch {
            // 400: 제목이 거절 이유일 수 있다 — 제목을 모두 빼고 한 번 더. 같은 목록이 다시 오면 보내지 않게 원래 목록을 보낸 것으로 적는다
            if resendWithoutTitles, Self.isInvalidRequest(error), payload.contains(where: { $0.title != nil }) {
                let bare = payload.map { row -> ExternalSessionReportRow in
                    var copy = row
                    copy.title = nil
                    return copy
                }
                do {
                    try await send(bridgeID, bare)
                    succeeded(payload, bridgeID: bridgeID, at: now)
                    return true
                } catch {
                    failed(error, at: now)
                    return false
                }
            }
            failed(error, at: now)
            return false
        }
    }

    private func succeeded(_ payload: [ExternalSessionReportRow], bridgeID: UUID, at now: Date) {
        lastSent = (bridgeID, payload, now)
        backoffUntil = nil
    }

    private func failed(_ error: Error, at now: Date) {
        if Self.isNotEnabled(error) || Self.isInvalidRequest(error) { backoffUntil = now.addingTimeInterval(Self.backoff) }
        log.log("external_sessions_report_failed", ["bucket": .code(Self.bucket(of: error))])
    }

    static func status(of error: Error) -> Int? { (error as? APIError)?.status }
    static func isNotEnabled(_ error: Error) -> Bool { status(of: error) == 404 }
    static func isInvalidRequest(_ error: Error) -> Bool { status(of: error) == 400 }

    /// 실패를 구간 코드로 접는다 (로그에는 이것만): 숫자 상태 · 오류 글 · 경로를 남기지 않는다
    static func bucket(of error: Error) -> String {
        if let api = error as? APIError {
            switch api {
            case .notSignedIn: return "auth"
            case .transport: return "network"
            case .decoding: return "other"
            case .server(let status, _, _), .unexpectedStatus(let status):
                switch status {
                case 404: return "not_enabled"
                case 400: return "rejected"
                case 401, 403: return "auth"
                case 429: return "rate_limited"
                case 500...599: return "server"
                default: return "other"
                }
            }
        }
        return error is URLError ? "network" : "other"
    }
}

/// 로그아웃 직전 정리 (`SessionStore.onSigningOut`): 옛 토큰이 아직 유효한 동안 이 Mac의 서버 목록(제목)을 비우고, 그 뒤 이 계정의 열쇠를 지운다.
/// 서버에 닿지 않아도(오프라인) 열쇠는 지운다: 남은 서버 행은 열쇠를 잃어 이 Mac과 이어지지 않고 14일 뒤 보관 정리가 지운다
public enum ExternalSessionSignOut {
    public static func run(bridgeID: UUID?, reporter: ExternalSessionReporter, keyStore: (any ExternalSessionKeyStore)?) async {
        if let bridgeID { await reporter.clear(bridgeID: bridgeID) }
        keyStore?.delete()
    }
}
#endif
