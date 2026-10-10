import Auth
import Foundation
import Synchronization
@testable import TaskforceKit

/// 서버 JSON 계약 fixture: 서버 head `60a73b1` (B3 PR1 = B2 `aa017bd` + 6 커밋, `handoffs/b3-server-notes.md`) × 이 브랜치.
/// 이 모양이 바뀌면 `ChatContractTests`가 먼저 깨진다.
enum ChatContractFixtures {
    /// 이 fixture가 맞춘 서버 head
    static let serverHead = "60a73b150cd45ff29bb7085729d3da9577cb0702"
    static let serverBase = "aa017bd7f18f3e06c2fda43321719ce36d455ba0"

    static let userID = UUID(uuidString: "00000000-0000-4000-8000-0000000000aa")!
    static let conversationID = UUID(uuidString: "bcb50000-0000-4000-8000-000000000001")!
    static let contextID = UUID(uuidString: "09d60000-0000-4000-8000-000000000001")!
    static let otherContextID = UUID(uuidString: "09d60000-0000-4000-8000-000000000002")!
    static let sourceID = UUID(uuidString: "b1c10000-0000-4000-8000-000000000001")!

    static func id(_ n: Int, prefix: String = "c1a90000") -> UUID {
        UUID(uuidString: String(format: "%@-0000-4000-8000-%012d", prefix, n))!
    }

    /// `POST /api/v2/memory/{id}/confirm` 200 (서버 notes 예시 그대로)
    static let confirmed = """
    {"item": {"id":"c1a90000-0000-4000-8000-000000000002","kind":"fact","scope_kind":"context","context_id":"\(contextID.uuidString.lowercased())","action_id":null,"person_id":null,"agent_adapter":null,
      "subject":"launch day","statement":"출시는 목요일인 듯","value":{"day":"thu"},"origin":"explicit",
      "source_ref":{"source_id":"\(sourceID.uuidString.lowercased())","quote":"출시는 목요일"},"observed_at":"2026-10-10T15:27:33.247Z","valid_from":null,"valid_until":null,
      "superseded_by":null,"superseded_at":null,"revoked_at":null,"confidence":null,"source_purged":false,"version":1,
      "created_at":"2026-10-10T15:27:33.247Z","updated_at":"2026-10-10T15:27:33.247Z"}}
    """

    static let forgotten = """
    {"item": {"id":"c1a90000-0000-4000-8000-000000000001","kind":"fact","scope_kind":"global","context_id":null,"action_id":null,"person_id":null,"agent_adapter":null,
      "subject":null,"statement":"Keeps pricing-page FAQs short","value":{},"origin":"explicit","source_ref":null,"observed_at":"2026-10-10T15:00:00.000Z",
      "valid_from":null,"valid_until":null,"superseded_by":null,"superseded_at":null,"revoked_at":"2026-10-10T15:27:33.265Z","confidence":null,
      "source_purged":false,"version":2,"created_at":"2026-10-10T15:00:00.000Z","updated_at":"2026-10-10T15:27:33.265Z"}}
    """

    /// 범위 옮기기 200: 새 행의 `value.moved_from`이 옛 행 id
    static let moved = """
    {"item": {"id":"c1a90000-0000-4000-8000-000000000009","kind":"fact","scope_kind":"context","context_id":"\(contextID.uuidString.lowercased())","action_id":null,"person_id":null,"agent_adapter":null,
      "subject":null,"statement":"Keeps pricing-page FAQs short","value":{"moved_from":"c1a90000-0000-4000-8000-000000000001"},"origin":"explicit","source_ref":null,
      "observed_at":"2026-10-10T15:00:00.000Z","valid_from":null,"valid_until":null,"superseded_by":null,"superseded_at":null,"revoked_at":null,"confidence":null,
      "source_purged":false,"version":1,"created_at":"2026-10-10T15:30:00.000Z","updated_at":"2026-10-10T15:30:00.000Z"}}
    """

    static let conversation = """
    {"conversation": {"id":"\(conversationID.uuidString.lowercased())","title":null,"context_id":"\(contextID.uuidString.lowercased())","created_at":"2026-10-10T15:27:33.247Z","last_message_at":null,"last_read_at":null,"archived_at":null,"text_purged_at":null}}
    """

    /// `POST /api/v2/conversations/{id}/messages` 200: 저장한 사용자 메시지 + 답 (`reply`는 `segments` · `citations`도 가진다)
    static func posted(clientMessageID: UUID, text: String = "Use the shorter FAQ", reply: String = "Noted.", memory: [UUID] = []) -> String {
        let user = UUID(uuidString: "aaaa0000-0000-4000-8000-000000000001")!.uuidString.lowercased()
        let memoryRefs = memory.map { "\"\($0.uuidString.lowercased())\"" }.joined(separator: ",")
        return """
        {"message":{"id":"\(user)","conversation_id":"\(conversationID.uuidString.lowercased())","seq":1,"role":"user","client_message_id":"\(clientMessageID.uuidString.lowercased())",
          "text":"\(text)","refs":{"action_ids":[],"run_ids":[],"artifact_ids":[],"suggestion_ids":[],"dependency_ids":[],"memory_item_ids":[],"context_ids":[],"proposal":null},
          "intent":null,"created_at":"2026-10-10T15:27:34.000Z","reply_to":null,"content":null},
         "reply":{"id":"bbbb0000-0000-4000-8000-000000000002","conversation_id":"\(conversationID.uuidString.lowercased())","seq":2,"role":"assistant","client_message_id":null,
          "text":"\(reply)","refs":{"action_ids":[],"run_ids":[],"artifact_ids":[],"suggestion_ids":[],"dependency_ids":[],"memory_item_ids":[\(memoryRefs)],"context_ids":["\(contextID.uuidString.lowercased())"],"proposal":null},
          "intent":{"kind":"preference","confidence":0.9,"judge_version":"v1"},"created_at":"2026-10-10T15:27:35.000Z","reply_to":"\(user)",
          "content":{"segments":[{"text":"\(reply)","tier":"T2"}],"citations":[{"action_id":null,"source_id":"\(sourceID.uuidString.lowercased())","source_title":"Launch brief","source_kind":"doc","occurred_at":"2026-10-09T01:00:00.000Z","external_url":"https://www.notion.so/launch","quote":"Ship on Thursday"}],
            "proposal":null,"asks":null,"used":{"context_id":null,"context_version":null,"memory_item_ids":[],"source_ids":[],"action_ids":[]},"window":null},
          "segments":[{"text":"\(reply)","tier":"T2"}],"citations":[]}}
        """
    }

    static func error(_ code: String, _ message: String = "x") -> String {
        "{\"error\":{\"code\":\"\(code)\",\"message\":\"\(message)\"}}"
    }
}

extension Date {
    /// 테스트 시계: 2026-10-11 09:00 UTC 기준 초
    static func test(_ seconds: TimeInterval = 0) -> Date { Date(timeIntervalSince1970: 1_791_709_200 + seconds) }
}

// MARK: 가짜 서버

/// 붙잡았다 놓는 문 (응답을 늦게 보내기)
actor Latch {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals = 0

    func wait() async {
        arrivals += 1
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// 가짜 `ChatGateway`: 응답을 스크립트로 정하고 부른 순서를 남긴다
final class FakeChatGateway: ChatGateway, @unchecked Sendable {
    struct Failure: Error {}

    private let lock = NSLock()
    private var _calls: [String] = []
    private func record(_ call: String) {
        lock.lock()
        _calls.append(call)
        lock.unlock()
    }
    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }
    func calls(prefix: String) -> [String] { calls.filter { $0.hasPrefix(prefix) } }

    // 읽기 스크립트
    nonisolated(unsafe) var conversationsHandler: @Sendable () async throws -> [ChatConversation] = { [] }
    nonisolated(unsafe) var lastMessagesHandler: @Sendable ([UUID]) async throws -> [UUID: ChatMessage] = { _ in [:] }
    nonisolated(unsafe) var messagesHandler: @Sendable (UUID) async throws -> [ChatMessage] = { _ in [] }
    nonisolated(unsafe) var messageHandler: @Sendable (UUID) async throws -> ChatMessage? = { _ in nil }
    nonisolated(unsafe) var contextsHandler: @Sendable () async throws -> [WorkContext] = { [] }
    nonisolated(unsafe) var currentMemoryHandler: @Sendable () async throws -> [MemoryItem] = { [] }
    nonisolated(unsafe) var memoryItemsHandler: @Sendable ([UUID]) async throws -> [MemoryItem] = { _ in [] }
    nonisolated(unsafe) var sourceHandler: @Sendable (UUID) async throws -> SourceSummary? = { _ in nil }
    // 쓰기 스크립트
    nonisolated(unsafe) var createHandler: @Sendable (UUID, String?, UUID?) async throws -> ChatConversation = { id, title, context in
        ChatConversation(id: id, title: title, contextID: context, createdAt: .test())
    }
    nonisolated(unsafe) var updateHandler: @Sendable (UUID, UUID?) async throws -> ChatConversation = { id, context in
        ChatConversation(id: id, contextID: context, createdAt: .test())
    }
    nonisolated(unsafe) var postHandler: @Sendable (UUID, UUID, String) async throws -> ChatPostedMessage = { _, _, _ in throw Failure() }
    nonisolated(unsafe) var confirmHandler: @Sendable (UUID, Int) async throws -> MemoryItem = { _, _ in throw Failure() }
    nonisolated(unsafe) var editHandler: @Sendable (UUID, MemoryEdit) async throws -> MemoryItem = { _, _ in throw Failure() }
    nonisolated(unsafe) var forgetHandler: @Sendable (UUID, Int) async throws -> MemoryItem = { _, _ in throw Failure() }
    nonisolated(unsafe) var moveHandler: @Sendable (UUID, Int, MemoryTarget) async throws -> MemoryItem = { _, _, _ in throw Failure() }

    func conversations() async throws -> [ChatConversation] { record("conversations"); return try await conversationsHandler() }
    func lastMessages(conversationIDs: [UUID]) async throws -> [UUID: ChatMessage] { record("lastMessages"); return try await lastMessagesHandler(conversationIDs) }
    func messages(conversationID: UUID) async throws -> [ChatMessage] { record("messages:\(conversationID.uuidString)"); return try await messagesHandler(conversationID) }
    func message(id: UUID) async throws -> ChatMessage? { record("message:\(id.uuidString)"); return try await messageHandler(id) }
    func workContexts() async throws -> [WorkContext] { record("contexts"); return try await contextsHandler() }
    func currentMemoryItems() async throws -> [MemoryItem] { record("currentMemory"); return try await currentMemoryHandler() }
    func memoryItems(ids: [UUID]) async throws -> [MemoryItem] { record("memoryItems"); return try await memoryItemsHandler(ids) }
    func sourceSummary(id: UUID) async throws -> SourceSummary? { record("source:\(id.uuidString)"); return try await sourceHandler(id) }

    func createConversation(id: UUID, title: String?, contextID: UUID?) async throws -> ChatConversation {
        record("create:\(id.uuidString)"); return try await createHandler(id, title, contextID)
    }
    func updateConversation(id: UUID, contextID: UUID?) async throws -> ChatConversation {
        record("update:\(id.uuidString):\(contextID?.uuidString ?? "nil")"); return try await updateHandler(id, contextID)
    }
    func postChatMessage(conversationID: UUID, clientMessageID: UUID, text: String) async throws -> ChatPostedMessage {
        record("post:\(conversationID.uuidString):\(clientMessageID.uuidString)"); return try await postHandler(conversationID, clientMessageID, text)
    }
    func confirmMemory(id: UUID, expectedVersion: Int) async throws -> MemoryItem {
        record("confirm:\(id.uuidString):v\(expectedVersion)"); return try await confirmHandler(id, expectedVersion)
    }
    func editMemory(id: UUID, edit: MemoryEdit) async throws -> MemoryItem {
        record("edit:\(id.uuidString):v\(edit.expectedVersion)"); return try await editHandler(id, edit)
    }
    func forgetMemory(id: UUID, expectedVersion: Int) async throws -> MemoryItem {
        record("forget:\(id.uuidString):v\(expectedVersion)"); return try await forgetHandler(id, expectedVersion)
    }
    func moveMemory(id: UUID, expectedVersion: Int, to target: MemoryTarget) async throws -> MemoryItem {
        record("move:\(id.uuidString):v\(expectedVersion)"); return try await moveHandler(id, expectedVersion, target)
    }
}

// MARK: 계정

/// 세션 하나가 저장돼 있는 로그인 저장소 (실제 `SessionStore`로 계정 경계를 시험한다). `save`로 다른 계정의 세션으로 바꾼다
final class ChatTestSessionStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data

    init(_ session: Session) throws { data = try JSONEncoder().encode(session) }

    func save(_ session: Session) throws {
        lock.lock()
        defer { lock.unlock() }
        data = try JSONEncoder().encode(session)
    }

    func store(key: String, value: Data) throws {}
    func retrieve(key: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
    func remove(key: String) throws {}
}

@MainActor
struct ChatTestAccount {
    let session: SessionStore
    let scope: AccountScope
    let storage: ChatTestSessionStorage
    let signedIn: Session

    static func session(userID: UUID) -> Session {
        let user = User(id: userID, appMetadata: [:], userMetadata: [:], aud: "authenticated", email: "\(userID.uuidString)@example.com", createdAt: Date(), updatedAt: Date())
        return Session(accessToken: "access", tokenType: "bearer", expiresIn: 3600, expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970, refreshToken: "refresh", user: user)
    }

    /// 로그인한 `SessionStore` + 앱 시작 때처럼 거기에 먼저 붙은 `AccountScope`
    static func make(userID: UUID = ChatContractFixtures.userID) throws -> ChatTestAccount {
        let signedIn = session(userID: userID)
        let storage = try ChatTestSessionStorage(signedIn)
        let auth = AuthClient(url: URL(string: "https://example.supabase.co/auth/v1")!, localStorage: storage, autoRefreshToken: false)
        let store = SessionStore(auth: auth)
        let scope = AccountScope()
        scope.bind(to: store)
        store.apply(event: .signedIn, session: signedIn)
        return ChatTestAccount(session: store, scope: scope, storage: storage, signedIn: signedIn)
    }

    /// 로그아웃 → 같은 사용자의 재로그인 (같은 UUID, 새 세션)
    func relogin() {
        session.apply(event: .signedOut, session: nil)
        session.apply(event: .signedIn, session: signedIn)
    }

    /// 항상 이 계정으로 로그인해 있는 범위 (세션 없이 저장소만 시험)
    static func fixedScope(_ userID: UUID = ChatContractFixtures.userID) -> AccountScope {
        AccountScope(currentAccount: { userID })
    }
}

// MARK: 행 만들기

enum Memories {
    static func item(
        _ n: Int, _ statement: String = "Keeps pricing-page FAQs short", origin: MemoryOrigin = .explicit, scope: MemoryScopeKind = .global,
        context: UUID? = nil, sourceRef: MemorySourceRef? = nil, version: Int = 1, superseded: Bool = false, revoked: Bool = false,
        supersededBy: UUID? = nil, purged: Bool = false, value: JSONValue = .object([:]), at: TimeInterval = 0
    ) -> MemoryItem {
        MemoryItem(
            id: ChatContractFixtures.id(n), scopeKind: scope, contextID: context, statement: purged ? "" : statement, value: value, origin: origin,
            sourceRef: sourceRef, observedAt: .test(at), supersededBy: supersededBy, supersededAt: superseded ? .test(at + 5) : nil,
            revokedAt: revoked ? .test(at + 5) : nil, confidence: origin == .inferred ? 0.7 : nil, sourcePurged: purged, version: version
        )
    }
}

enum Chats {
    static func conversation(_ n: Int, title: String? = nil, at: TimeInterval = 0, last: TimeInterval? = nil, context: UUID? = nil) -> ChatConversation {
        ChatConversation(
            id: ChatContractFixtures.id(n, prefix: "bcb50000"), title: title, contextID: context, createdAt: .test(at), lastMessageAt: last.map { .test($0) }
        )
    }

    static func message(
        _ n: Int, in conversation: UUID, seq: Int, role: ChatRole, text: String, cmid: UUID? = nil, replyTo: UUID? = nil,
        memory: [UUID] = [], citations: [ChatCitation] = [], at: TimeInterval = 0
    ) -> ChatMessage {
        ChatMessage(
            id: ChatContractFixtures.id(n, prefix: "aaaa0000"), conversationID: conversation, seq: seq, role: role, clientMessageID: cmid, text: text,
            refs: ChatRefs(memoryItemIDs: memory, contextIDs: [], actionIDs: []), createdAt: .test(at), replyTo: replyTo,
            content: citations.isEmpty ? nil : ChatMessageContent(citations: citations)
        )
    }

    /// 보낸 글에 대한 서버의 쌍 (사용자 글 n, 답 n + 1)
    static func pair(
        _ n: Int, in conversation: UUID, seq: Int, cmid: UUID, text: String, reply: String = "Noted.", memory: [UUID] = []
    ) -> ChatPostedMessage {
        let user = message(n, in: conversation, seq: seq, role: .user, text: text, cmid: cmid, at: Double(seq))
        let answer = message(n + 1, in: conversation, seq: seq + 1, role: .assistant, text: reply, replyTo: user.id, memory: memory, at: Double(seq + 1))
        return ChatPostedMessage(message: user, reply: answer)
    }
}
