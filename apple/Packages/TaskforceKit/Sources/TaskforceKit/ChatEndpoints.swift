import Foundation

// 대화 v2 · 기억 쓰기 (`/api/v2`, 서버 head `60a73b1`). v1은 동결이라 이 파일의 호출만 v2 경로를 쓴다.
// 오류는 모두 `{"error":{"code","message"}}`. 알 수 없는 코드는 `APIError`가 상태로 짐작한다 (v2 이유 코드 둘은 `APIErrorCode`가 안다).

extension APIError {
    /// 서버 gate(`CONVERSATIONS_V2_ENABLED` · `MEMORY_ENABLED`)가 꺼졌을 때 404의 메시지. 다른 404(없는 대화 · 기억 · 범위)와 이것으로만 가른다
    /// (서버가 따로 코드를 주면 거기로 옮긴다: `b3-mac-notes.md` 열린 질문)
    static let featureOffMessage = "없는 경로입니다."
    /// 외부 AI 처리 동의가 먼저 필요함 (메시지 보내기의 409). 같은 409 `conflict`에 `mismatch` · 처리 중 · 뒤 메시지 있음이 함께 있어 메시지로만 가른다
    static let consentRequiredMessage = "외부 AI 처리 동의가 필요해요."

    /// 기능이 꺼져 있다 (gate 꺼짐 404 · route가 없는 옛 서버의 404). "실패"가 아니다
    public var isFeatureOff: Bool {
        switch self {
        case .server(404, .notFound, let message): message == Self.featureOffMessage
        case .unexpectedStatus(404): true
        default: false
        }
    }

    /// 메시지 보내기: 동의가 먼저 필요함
    public var isChatConsentRequired: Bool {
        if case .server(409, .conflict, let message) = self { return message == Self.consentRequiredMessage }
        return false
    }

    /// 없는 대화 · 기억 · 범위 (gate 꺼짐이 아닌 404)
    public var isMissingTarget: Bool {
        if case .server(404, .notFound, let message) = self { return message != Self.featureOffMessage }
        return false
    }

    /// 확인할 수 없는 기억 (정책 보류: Slack 원문 · 글이 지워진 항목): Confirm을 감춘다
    public var isConfirmUnavailable: Bool {
        if case .server(_, .confirmUnavailable, _) = self { return true }
        return false
    }

    /// 옮길 수 없는 기억 (정책 보류: explicit이 아니거나 전체 · 프로젝트가 아닌 범위): 범위 popup을 감춘다
    public var isScopeUnavailable: Bool {
        if case .server(_, .scopeUnavailable, _) = self { return true }
        return false
    }
}

extension APIClient {
    /// 메시지 보내기를 기다리는 시간 (서버 `maxDuration = 60`보다 조금 길게)
    static let chatTimeout: TimeInterval = 70

    /// 대화 만들기. `id`는 앱이 정한다: 같은 id로 다시 보내면 서버가 그 대화를 돌려준다 (201 새로 · 200 이미 있음).
    /// 404 = gate 꺼짐 또는 내 범위가 아님 (`APIError.isFeatureOff`), 409 = 남이 쓴 id
    public func createConversation(id: UUID, title: String?, contextID: UUID? = nil) async throws -> ChatConversation {
        let response: ChatConversationResponse = try await send(
            .post, "conversations", body: CreateConversationRequest(id: id, title: title, contextID: contextID), version: .v2
        )
        return response.conversation
    }

    /// 대화 범위 바꾸기: 헤더 ProjectLink에서 사용자가 명시적으로 고른 범위 (nil = All work). 자동 추정 · 멤버십 쓰기는 없다
    public func updateConversation(id: UUID, contextID: UUID?) async throws -> ChatConversation {
        let response: ChatConversationResponse = try await send(
            .patch, "conversations/\(id.lowercased)", body: UpdateConversationRequest(contextID: contextID), version: .v2
        )
        return response.conversation
    }

    /// 메시지 보내기. 같은 `clientMessageID` · 같은 글이면 같은 제출이다: 두 번 저장 · 실행하지 않고 저장된 쌍을 돌려준다.
    /// 409 `conflict`는 동의 전 · 처리 중 · 뒤 메시지 있음 · 다른 글을 같은 id로 보냄 · 그 사이 기억이 바뀜을 함께 뜻한다 (`APIError.isChatConsentRequired`로 동의만 가른다)
    public func postChatMessage(conversationID: UUID, clientMessageID: UUID, text: String) async throws -> ChatPostedMessage {
        try await send(
            .post, "conversations/\(conversationID.lowercased)/messages", body: PostChatMessageRequest(clientMessageID: clientMessageID, text: text),
            timeout: Self.chatTimeout, version: .v2
        )
    }

    // MARK: 기억 (gate MEMORY_ENABLED, 응답의 `item`은 지금 상태의 행)

    /// 추정 확인: 새 explicit 행이 옛 추정을 정정한다. 응답 `item`은 새 행이다
    public func confirmMemory(id: UUID, expectedVersion: Int) async throws -> MemoryItem {
        let response: MemoryItemResponse = try await send(
            .post, "memory/\(id.lowercased)/confirm", body: MemoryVersionRequest(expectedVersion: expectedVersion), version: .v2
        )
        return response.item
    }

    /// 정정: 새 explicit 행 + 옛 행 `superseded_*`. 범위는 바뀌지 않는다
    public func editMemory(id: UUID, edit: MemoryEdit) async throws -> MemoryItem {
        let response: MemoryItemResponse = try await send(.patch, "memory/\(id.lowercased)", body: edit, version: .v2)
        return response.item
    }

    /// 잊기: 같은 요청을 다시 보내도 200이다 (이미 잊은 항목 = 누가 잊었든 같은 상태)
    public func forgetMemory(id: UUID, expectedVersion: Int) async throws -> MemoryItem {
        let response: MemoryItemResponse = try await send(
            .post, "memory/\(id.lowercased)/forget", body: MemoryVersionRequest(expectedVersion: expectedVersion), version: .v2
        )
        return response.item
    }

    /// 범위 옮기기 (explicit 항목만, 전체 ↔ 내 active 프로젝트): 새 행이 `value.moved_from`으로 옛 행을 가리키고 옛 행은 잊힌다
    public func moveMemory(id: UUID, expectedVersion: Int, to target: MemoryTarget) async throws -> MemoryItem {
        let response: MemoryItemResponse = try await send(
            .post, "memory/\(id.lowercased)/scope", body: MemoryScopeRequest(expectedVersion: expectedVersion, target: target), version: .v2
        )
        return response.item
    }
}
