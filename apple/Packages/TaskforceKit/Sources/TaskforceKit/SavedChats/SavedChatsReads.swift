import Foundation
import Supabase

// 저장된 대화의 직접 읽기 (RLS 본인 행, 새 서버 읽기 route 없음). 쓰기(지우기)는 `APIClient`.
// 읽은 글(제목 · 말)은 메모리에만 두고 로그 · 디스크에 남기지 않는다.

/// `bridges`의 `id · device_name` (표시용 글자: 어떤 판정 · 열쇠에도 쓰지 않는다)
private struct SavedChatBridgeName: Decodable {
    let id: UUID
    let deviceName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case deviceName = "device_name"
    }
}

extension TaskforceReads {
    private static let savedChatBridgeChunk = 100

    /// 대화 목록: 새 대화가 위 (`last_message_at` 내림차순, 같으면 id), `offset`부터 `limit`개
    public func savedChats(offset: Int, limit: Int) async throws -> [SavedChatRecord] {
        try await rows(
            supabase.from("claude_app_chats").select(SavedChatRecord.columns)
                .order("last_message_at", ascending: false).order("id", ascending: false).range(from: offset, to: offset + limit - 1)
        )
    }

    /// bridge id → 기기 이름 (`bridges.device_name`, 열 단위 select 허용). 이름이 없는(null · 빈 글) Mac은 담지 않는다. id는 100개씩 묻는다
    public func savedChatDeviceNames(bridgeIDs: [UUID]) async throws -> [UUID: String] {
        let ids = Array(Set(bridgeIDs)).sorted { $0.uuidString < $1.uuidString }
        guard !ids.isEmpty else { return [:] }
        var names: [UUID: String] = [:]
        for start in stride(from: 0, to: ids.count, by: Self.savedChatBridgeChunk) {
            let chunk = ids[start..<min(start + Self.savedChatBridgeChunk, ids.count)]
            let found: [SavedChatBridgeName] = try await rows(
                supabase.from("bridges").select("id, device_name").in("id", values: chunk.map(\.lowercased))
            )
            for row in found {
                if let name = SavedChatRules.cleaned(row.deviceName) { names[row.id] = name }
            }
        }
        return names
    }

    /// 한 대화의 말, **새 것부터** `offset`부터 `limit`개 (`said_at` 내림차순, 같으면 `seq`). 보이는 순서(오래된 것이 위)는 `SavedChatMessages.ordered`
    public func savedChatMessages(chatID: UUID, offset: Int, limit: Int) async throws -> [SavedChatMessageRecord] {
        try await rows(
            supabase.from("claude_app_chat_messages").select(SavedChatMessageRecord.columns).eq("chat_id", value: chatID.lowercased)
                .order("said_at", ascending: false).order("seq", ascending: false).range(from: offset, to: offset + limit - 1)
        )
    }
}

/// 실제 연결로 만드는 저장소의 읽기 · 지우기 (시험은 가짜 서버를 보는 `TaskforceReads` · `APIClient`로 같은 길을 탄다)
public enum SavedChatsLive {
    public typealias ReadPage = @Sendable (_ offset: Int, _ limit: Int) async throws -> [SavedChatRow]
    public typealias ReadMessages = @Sendable (_ chatID: UUID, _ offset: Int, _ limit: Int) async throws -> [SavedChatMessageRecord]

    /// 서버 DB에 이 표가 아직 없다 (마이그레이션 전 · 꺼진 서버): 저장된 대화가 없는 것과 같다. 오류가 아니라서 절이 "Couldn't load saved chats"를 말하지 않고 그냥 없다
    static func isMissingTable(_ error: Error) -> Bool {
        ReadFailure.from(error, online: true) == .unavailable
    }

    /// 한 쪽: 대화 + 기기 이름을 합친 줄. 기기 이름을 못 읽어도 목록은 그대로다 (시각만 보인다)
    public static func readPage(reads: TaskforceReads, thisMac: @escaping @Sendable () async -> UUID?) -> ReadPage {
        { offset, limit in
            let records: [SavedChatRecord]
            do {
                records = try await reads.savedChats(offset: offset, limit: limit)
            } catch {
                if isMissingTable(error) { return [] }
                throw error
            }
            guard !records.isEmpty else { return [] }
            let names = (try? await reads.savedChatDeviceNames(bridgeIDs: records.map(\.bridgeID))) ?? [:]
            return SavedChatRules.rows(records, deviceNames: names, thisMac: await thisMac())
        }
    }

    /// 한 대화의 말 한 쪽 (새 것부터). 표가 없으면 빈 쪽: 보기가 "이미 지워진 대화"로 닫는다
    public static func readMessages(reads: TaskforceReads) -> ReadMessages {
        { chatID, offset, limit in
            do {
                return try await reads.savedChatMessages(chatID: chatID, offset: offset, limit: limit)
            } catch {
                if isMissingTable(error) { return [] }
                throw error
            }
        }
    }

    /// 앱이 쓰는 저장소: 읽기는 Supabase 직접, 지우기는 서버 API
    @MainActor
    public static func store(
        reads: TaskforceReads, api: APIClient, thisMac: @escaping @Sendable () async -> UUID?, scope: AccountScope,
        log: @escaping @Sendable (_ event: String, _ code: String) -> Void = { _, _ in }
    ) -> SavedChatsStore {
        SavedChatsStore(
            scope: scope, readPage: readPage(reads: reads, thisMac: thisMac), readMessages: readMessages(reads: reads),
            deleteChat: { try await api.deleteClaudeAppChat(id: $0) }, deleteAll: { _ = try await api.deleteAllClaudeAppChats() },
            pageSize: SavedChatRules.pageSize, log: log
        )
    }
}
