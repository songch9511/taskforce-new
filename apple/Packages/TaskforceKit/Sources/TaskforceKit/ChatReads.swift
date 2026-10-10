import Foundation
import Supabase

// 대화 · 기억 읽기 (RLS 본인 행, 새 서버 읽기 route 없음). 쓰기는 `APIClient`(`ChatEndpoints.swift`)로만 한다.
// 읽은 글(메시지 · 기억 · 인용)은 사용자 글이라 메모리에만 두고 로그 · 디스크에 남기지 않는다.

extension TaskforceReads {
    static let chatPageSize = 500
    /// 한 대화에서 읽는 최근 메시지 수의 상한 (긴 대화는 오래된 쪽이 잘린다)
    static let chatThreadCap = 1000
    private static let idChunkSize = 100

    /// 대화 목록: 보관하지 않은 것. 메시지가 있는 것 최근 100개 + 손대지 않은 빈 대화 최근 20개 (둘 다 새 것이 위, 합쳐서 `ChatHistoryRules`가 정렬한다)
    public func conversations() async throws -> [ChatConversation] {
        async let touched: [ChatConversation] = rows(
            supabase.from("conversations").select(ChatConversation.columns).filter("archived_at", operator: "is", value: "null")
                .not("last_message_at", operator: .is, value: "null")
                .order("last_message_at", ascending: false).order("id", ascending: false).limit(100)
        )
        async let untouched: [ChatConversation] = rows(
            supabase.from("conversations").select(ChatConversation.columns).filter("archived_at", operator: "is", value: "null")
                .filter("last_message_at", operator: "is", value: "null")
                .order("created_at", ascending: false).order("id", ascending: false).limit(20)
        )
        return try await touched + untouched
    }

    /// 목록 한 줄의 미리보기: 대화마다 마지막 글 (사용자 · 답). 읽은 최근 메시지 안에 없으면 그 대화는 빠진다 (미리보기 없음)
    public func lastMessages(conversationIDs: [UUID]) async throws -> [UUID: ChatMessage] {
        let ids = Array(Set(conversationIDs))
        guard !ids.isEmpty else { return [:] }
        var result: [UUID: ChatMessage] = [:]
        for start in stride(from: 0, to: ids.count, by: Self.idChunkSize) {
            let chunk = ids[start..<min(start + Self.idChunkSize, ids.count)]
            let page: [ChatMessage] = try await rows(
                supabase.from("conversation_messages").select("id, conversation_id, seq, role, text, created_at")
                    .in("conversation_id", values: chunk.map(\.lowercased)).in("role", values: ["user", "assistant"])
                    .order("created_at", ascending: false).order("seq", ascending: false).limit(chunk.count * 4)
            )
            for message in page where result[message.conversationID] == nil {
                result[message.conversationID] = message
            }
        }
        return result
    }

    /// 한 대화의 메시지, 오래된 것이 위 (`seq`). 최근 `chatThreadCap`개까지
    public func messages(conversationID: UUID) async throws -> [ChatMessage] {
        var newestFirst: [ChatMessage] = []
        var offset = 0
        while newestFirst.count < Self.chatThreadCap {
            let page: [ChatMessage] = try await rows(
                supabase.from("conversation_messages").select(ChatMessage.columns).eq("conversation_id", value: conversationID.lowercased)
                    .order("seq", ascending: false).range(from: offset, to: offset + Self.chatPageSize - 1)
            )
            newestFirst.append(contentsOf: page)
            guard page.count == Self.chatPageSize else { break }
            offset += page.count
        }
        return Array(newestFirst.prefix(Self.chatThreadCap).reversed())
    }

    /// 메시지 하나 (기억의 출처가 대화 발화일 때). 없으면(지워짐 · 남의 것) nil
    public func message(id: UUID) async throws -> ChatMessage? {
        let found: [ChatMessage] = try await rows(
            supabase.from("conversation_messages").select(ChatMessage.columns).eq("id", value: id.lowercased).limit(1)
        )
        return found.first
    }

    /// 내 범위(프로젝트). 이름은 모두(보관된 것 포함), 고르는 popup은 `isActive`만
    public func workContexts() async throws -> [WorkContext] {
        try await rows(supabase.from("work_contexts").select(WorkContext.columns).order("name", ascending: true).limit(500))
    }

    /// "지금 기억" 전부 (`superseded_at is null and revoked_at is null`), 새 것이 위. 범위 사이 우선은 서버 판정이라 흉내 내지 않고 항목마다 범위를 그대로 읽는다
    public func currentMemoryItems() async throws -> [MemoryItem] {
        var result: [MemoryItem] = []
        var offset = 0
        while true {
            let page: [MemoryItem] = try await rows(
                supabase.from("memory_items").select(MemoryItem.columns).filter("superseded_at", operator: "is", value: "null").filter("revoked_at", operator: "is", value: "null")
                    .order("observed_at", ascending: false).order("id", ascending: false)
                    .range(from: offset, to: offset + Self.chatPageSize - 1)
            )
            result.append(contentsOf: page)
            guard page.count == Self.chatPageSize else { return result }
            offset += page.count
        }
    }

    /// 그 id의 기억 (정정 · 잊음으로 지금 기억이 아닌 행도 읽는다: 옛 답의 `refs`가 가리킨다)
    public func memoryItems(ids: [UUID]) async throws -> [MemoryItem] {
        let ids = Array(Set(ids))
        guard !ids.isEmpty else { return [] }
        var result: [MemoryItem] = []
        for start in stride(from: 0, to: ids.count, by: Self.idChunkSize) {
            let chunk = ids[start..<min(start + Self.idChunkSize, ids.count)]
            result += try await rows(supabase.from("memory_items").select(MemoryItem.columns).in("id", values: chunk.map(\.lowercased)))
        }
        return result
    }

    /// 원문 요약 하나 (기억의 출처). 없으면(지워짐 · 연결 끊김) nil
    public func sourceSummary(id: UUID) async throws -> SourceSummary? {
        let found: [SourceSummary] = try await rows(
            supabase.from("sources").select(SourceSummary.columns).eq("id", value: id.lowercased).limit(1)
        )
        return found.first
    }
}
