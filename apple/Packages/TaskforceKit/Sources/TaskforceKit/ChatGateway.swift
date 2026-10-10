import Foundation

/// 대화 · 기억 저장소가 서버와 닿는 면 (읽기 = Supabase RLS, 쓰기 = 서버 `/api/v2`).
/// 저장소는 이 프로토콜만 안다: 테스트는 가짜로 붙잡기 · 실패 · 순서를 정확히 다룬다 (실제 연결은 `LiveChatGateway`).
public protocol ChatGateway: Sendable {
    // 읽기 (RLS)
    func conversations() async throws -> [ChatConversation]
    func lastMessages(conversationIDs: [UUID]) async throws -> [UUID: ChatMessage]
    func messages(conversationID: UUID) async throws -> [ChatMessage]
    func message(id: UUID) async throws -> ChatMessage?
    func workContexts() async throws -> [WorkContext]
    func currentMemoryItems() async throws -> [MemoryItem]
    func memoryItems(ids: [UUID]) async throws -> [MemoryItem]
    func memorySource(id: UUID) async throws -> MemorySource?

    // 쓰기 (서버 API, Bearer)
    func createConversation(id: UUID, title: String?, contextID: UUID?) async throws -> ChatConversation
    func updateConversation(id: UUID, contextID: UUID?) async throws -> ChatConversation
    func postChatMessage(conversationID: UUID, clientMessageID: UUID, text: String) async throws -> ChatPostedMessage
    func confirmMemory(id: UUID, expectedVersion: Int) async throws -> MemoryItem
    func editMemory(id: UUID, edit: MemoryEdit) async throws -> MemoryItem
    func forgetMemory(id: UUID, expectedVersion: Int) async throws -> MemoryItem
    func moveMemory(id: UUID, expectedVersion: Int, to target: MemoryTarget) async throws -> MemoryItem
}

/// 실제 연결: `TaskforceReads`(RLS) + `APIClient`(쓰기)
public struct LiveChatGateway: ChatGateway {
    private let reads: TaskforceReads
    private let api: APIClient

    public init(reads: TaskforceReads, api: APIClient) {
        self.reads = reads
        self.api = api
    }

    public init(services: AppServices) {
        self.init(reads: services.reads, api: services.api)
    }

    public func conversations() async throws -> [ChatConversation] { try await reads.conversations() }
    public func lastMessages(conversationIDs: [UUID]) async throws -> [UUID: ChatMessage] {
        try await reads.lastMessages(conversationIDs: conversationIDs)
    }
    public func messages(conversationID: UUID) async throws -> [ChatMessage] { try await reads.messages(conversationID: conversationID) }
    public func message(id: UUID) async throws -> ChatMessage? { try await reads.message(id: id) }
    public func workContexts() async throws -> [WorkContext] { try await reads.workContexts() }
    public func currentMemoryItems() async throws -> [MemoryItem] { try await reads.currentMemoryItems() }
    public func memoryItems(ids: [UUID]) async throws -> [MemoryItem] { try await reads.memoryItems(ids: ids) }
    public func memorySource(id: UUID) async throws -> MemorySource? { try await reads.memorySource(id: id) }

    public func createConversation(id: UUID, title: String?, contextID: UUID?) async throws -> ChatConversation {
        try await api.createConversation(id: id, title: title, contextID: contextID)
    }
    public func updateConversation(id: UUID, contextID: UUID?) async throws -> ChatConversation {
        try await api.updateConversation(id: id, contextID: contextID)
    }
    public func postChatMessage(conversationID: UUID, clientMessageID: UUID, text: String) async throws -> ChatPostedMessage {
        try await api.postChatMessage(conversationID: conversationID, clientMessageID: clientMessageID, text: text)
    }
    public func confirmMemory(id: UUID, expectedVersion: Int) async throws -> MemoryItem {
        try await api.confirmMemory(id: id, expectedVersion: expectedVersion)
    }
    public func editMemory(id: UUID, edit: MemoryEdit) async throws -> MemoryItem { try await api.editMemory(id: id, edit: edit) }
    public func forgetMemory(id: UUID, expectedVersion: Int) async throws -> MemoryItem {
        try await api.forgetMemory(id: id, expectedVersion: expectedVersion)
    }
    public func moveMemory(id: UUID, expectedVersion: Int, to target: MemoryTarget) async throws -> MemoryItem {
        try await api.moveMemory(id: id, expectedVersion: expectedVersion, to: target)
    }
}
