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
/// 실패는 삼키고 다음 호출에서 다시 시도한다. 제목 · id를 로그에 남기지 않는다
public actor ExternalSessionReporter {
    public typealias Send = @Sendable (_ bridgeID: UUID, _ rows: [ExternalSessionReportRow]) async throws -> Void

    public static let minimumInterval: TimeInterval = 30
    public static let keepalive: TimeInterval = 6 * 3600

    private let send: Send
    private let clock: @Sendable () -> Date
    private var lastSent: (bridge: UUID, rows: [ExternalSessionReportRow], at: Date)?
    private var lastAttempt: Date?

    public init(send: @escaping Send, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.send = send
        self.clock = clock
    }

    /// 보냈으면 true
    @discardableResult
    public func report(_ rows: [ExternalSessionRow], bridgeID: UUID) async -> Bool {
        let payload = ExternalSessionReport.rows(from: rows)
        let now = clock()
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < Self.minimumInterval { return false }
        if let lastSent, lastSent.bridge == bridgeID, lastSent.rows == payload, now.timeIntervalSince(lastSent.at) < Self.keepalive { return false }
        return await deliver(payload, bridgeID: bridgeID, at: now)
    }

    /// 이 Mac의 목록을 서버에서 비운다 (속도 조절 없이)
    @discardableResult
    public func clear(bridgeID: UUID) async -> Bool {
        await deliver([], bridgeID: bridgeID, at: clock())
    }

    /// 계정이 바뀌었다: 마지막으로 보낸 값을 잊는다
    public func reset() {
        lastSent = nil
        lastAttempt = nil
    }

    private func deliver(_ payload: [ExternalSessionReportRow], bridgeID: UUID, at now: Date) async -> Bool {
        lastAttempt = now
        do {
            try await send(bridgeID, payload)
            lastSent = (bridgeID, payload, now)
            return true
        } catch {
            return false
        }
    }
}
#endif
