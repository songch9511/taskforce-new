#if os(macOS)
import Foundation

// Claude 데스크톱 대화의 서버 저장 · 보내기 지표 (OA PR-D3k, 계약 25.3 · 25.6 · 26장, 서버 노트 `oa-desktop-chat-server-notes.md` 5장): 모두 `/api/v2`.
// - `GET claude-app-chats/status`: **글을 보내기 전에** 저장이 켜졌는지 묻는다. 404면 서버로 글을 한 바이트도 보내지 않는다 (DT14)
// - `PUT claude-app-chats`: "Received"가 확인된 한 교환의 행들 (멱등)
// - `POST external-sessions/claude-app-sent`: 보내기 결과 지표 (글 0)
// 값에는 글 · 제목을 찍지 않는다: `description`은 칸 수만 말한다

/// `GET claude-app-chats/status`의 200 답
public struct ClaudeAppChatsStatus: Equatable, Sendable, Decodable {
    public let save: Bool
    /// 한 번에 올릴 행 수 상한 (서버 20)
    public let maxBatch: Int
    /// 요청 본문(JSON 전체) 상한 (서버 262144). 없으면 262144
    public let maxBytes: Int

    public init(save: Bool, maxBatch: Int = 20, maxBytes: Int = 262_144) {
        self.save = save
        self.maxBatch = maxBatch
        self.maxBytes = maxBytes
    }

    enum CodingKeys: String, CodingKey {
        case save
        case maxBatch = "max_batch"
        case maxBytes = "max_bytes"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        save = try container.decode(Bool.self, forKey: .save)
        maxBatch = min(20, max(1, try container.decodeIfPresent(Int.self, forKey: .maxBatch) ?? 20))
        maxBytes = max(4096, try container.decodeIfPresent(Int.self, forKey: .maxBytes) ?? 262_144)
    }
}

/// 한 세션의 저장 표시 (서버 `claude_app_chats`의 칸): 이 Mac의 HMAC `session_ref` · bridge id · 제목. **Claude 세션 id · 폴더 · 경로는 없다**
public struct ClaudeAppChatContext: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var bridgeID: UUID
    /// 소문자 hex 64자 (`ExternalSessionKey.ref(forSessionID:)`)
    public var sessionRef: String
    /// 1–200자 (`ExternalSessionRules.sanitizedTitle`). 없으면 nil: 요청에서 칸을 뺀다 (서버가 저장된 제목을 그대로 둔다)
    public var title: String?

    public init(bridgeID: UUID, sessionRef: String, title: String?) {
        self.bridgeID = bridgeID
        self.sessionRef = sessionRef
        self.title = title
    }

    public var description: String { "ClaudeAppChatContext()" }
    public var debugDescription: String { description }
}

/// `PUT claude-app-chats` 본문 (서버 strict 스키마: 모르는 칸은 400)
public struct ClaudeAppChatPutRequest: Encodable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public struct Message: Encodable, Equatable, Sendable {
        public let macRef: String
        public let role: String
        public let replyToRef: String?
        public let body: String
        public let truncated: Bool
        public let saidAt: String
        /// 답 글에만, 비어 있으면 칸을 뺀다
        public let toolNames: [String]?

        enum CodingKeys: String, CodingKey {
            case macRef = "mac_ref"
            case role
            case replyToRef = "reply_to_ref"
            case body, truncated
            case saidAt = "said_at"
            case toolNames = "tool_names"
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(macRef, forKey: .macRef)
            try container.encode(role, forKey: .role)
            try container.encodeIfPresent(replyToRef, forKey: .replyToRef)
            try container.encode(body, forKey: .body)
            try container.encode(truncated, forKey: .truncated)
            try container.encode(saidAt, forKey: .saidAt)
            try container.encodeIfPresent(toolNames, forKey: .toolNames)
        }
    }

    public let bridgeID: String
    public let sessionRef: String
    public let title: String?
    public let messages: [Message]

    enum CodingKeys: String, CodingKey {
        case bridgeID = "bridge_id"
        case sessionRef = "session_ref"
        case title, messages
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bridgeID, forKey: .bridgeID)
        try container.encode(sessionRef, forKey: .sessionRef)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(messages, forKey: .messages)
    }

    public init(context: ClaudeAppChatContext, rows: [ClaudeAppChatRow]) {
        bridgeID = context.bridgeID.uuidString.lowercased()
        sessionRef = context.sessionRef
        title = context.title
        messages = rows.map { row in
            Message(
                macRef: row.macRef, role: row.role.rawValue, replyToRef: row.replyToRef, body: row.body, truncated: row.truncated, saidAt: Self.timestamp(row.saidAt),
                toolNames: row.role == .assistant && !row.toolNames.isEmpty ? row.toolNames : nil
            )
        }
    }

    /// 시간대 있는 ISO 8601, 소수 초 3자리 (`2026-10-22T09:00:05.123Z`)
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// 요청 본문의 JSON 바이트 수 (서버 상한 256 KiB를 지키려고 나눌 때 센다)
    public var encodedSize: Int { (try? TaskforceJSON.encoder().encode(self).count) ?? Int.max }

    /// 칸 수만 말한다: 글 · 제목 · ref를 찍지 않는다
    public var description: String { "ClaudeAppChatPutRequest(messages: \(messages.count))" }
    public var debugDescription: String { description }
}

/// `PUT`의 200 답. `chatID`가 nil이면 이 교환만 멈춘다 (사용자가 그 대화를 지웠다): 남은 행을 더 올리지 않는다
public struct ClaudeAppChatPutResponse: Equatable, Sendable, Decodable {
    public let chatID: UUID?
    public let saved: Int
    public let existing: Int
    public let orphan: Int

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case saved, existing, orphan
    }

    public init(chatID: UUID?, saved: Int, existing: Int, orphan: Int) {
        self.chatID = chatID
        self.saved = saved
        self.existing = existing
        self.orphan = orphan
    }
}

/// `POST external-sessions/claude-app-sent` 본문 (글 0): 저장이 꺼졌을 때의 `received`와 모든 `not_sent`, 올리기를 포기한 교환(`uploaded: false`)
public struct ClaudeAppSentReport: Encodable, Equatable, Sendable {
    public enum Result: String, Sendable { case received, notSent = "not_sent" }

    public let result: Result
    public let reason: ClaudeAppNotSentReason?
    /// `received`일 때만: 저장이 켜져 있는데 올리기를 포기했다
    public let uploaded: Bool?

    public init(result: Result, reason: ClaudeAppNotSentReason? = nil, uploaded: Bool? = nil) {
        self.result = result
        self.reason = reason
        self.uploaded = uploaded
    }

    public static let received = ClaudeAppSentReport(result: .received)
    public static let receivedButNotUploaded = ClaudeAppSentReport(result: .received, uploaded: false)
    public static func notSent(_ reason: ClaudeAppNotSentReason) -> ClaudeAppSentReport { ClaudeAppSentReport(result: .notSent, reason: reason) }

    enum CodingKeys: String, CodingKey {
        case result, reason, uploaded
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(result.rawValue, forKey: .result)
        try container.encodeIfPresent(reason?.code, forKey: .reason)
        try container.encodeIfPresent(uploaded, forKey: .uploaded)
    }
}

extension APIClient {
    /// 저장이 켜졌나 (앱 시작 · 로그인 때와 1시간마다). 404(저장 꺼짐 · 명단 밖)는 던진다: 부르는 쪽이 업로더를 만들지 않는다
    public func claudeAppChatsStatus() async throws -> ClaudeAppChatsStatus {
        try await send(.get, "claude-app-chats/status", version: .v2)
    }

    /// "Received"가 확인된 교환의 행들을 올린다 (멱등). 오류는 던진다 (`APIError.server(status:…)`: 400 버그 · 404 꺼짐 · 409 잠금 · 413 한도 · 429 속도 · 5xx)
    public func putClaudeAppChat(_ request: ClaudeAppChatPutRequest) async throws -> ClaudeAppChatPutResponse {
        try await send(.put, "claude-app-chats", body: request, version: .v2)
    }

    /// 보내기 결과 지표 (글 0). 서버는 204로 답한다
    public func claudeAppSent(_ report: ClaudeAppSentReport) async throws {
        struct Empty: Decodable {}
        do {
            let _: Empty = try await send(.post, "external-sessions/claude-app-sent", body: report, version: .v2)
        } catch APIError.decoding {
            // 204 본문 없음: 2xx라 여기까지 온 것이다
        }
    }
}
#endif
