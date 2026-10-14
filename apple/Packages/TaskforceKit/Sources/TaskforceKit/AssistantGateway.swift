import Foundation

/// Assistant 창이 서버와 닿는 면 (OA U1): 대상 목록 · 대상을 지정한 대화 만들기 · 칩을 실은 보내기. 모두 서버 `/api/v2` 쓰기다 (읽기는 `ChatGateway`의 RLS).
/// 저장소는 이 프로토콜만 안다: 시험은 가짜로 붙잡기 · 실패 · 순서를 정확히 다룬다 (실제 연결은 `LiveChatGateway`가 이 프로토콜도 따른다).
/// 이 프로토콜이 없는 런타임(견본 등)은 칩 없이 Taskforce 대상으로만 보낸다.
public protocol AssistantGateway: Sendable {
    func targets() async throws -> [AssistantTarget]
    func createConversation(id: UUID, title: String?, contextID: UUID?, target: ChatTarget) async throws -> ChatCreatedConversation
    /// Taskforce 대상: 칩을 싣고 보낸다. 응답은 기존 모양(답 포함)이다
    func postChatMessage(conversationID: UUID, clientMessageID: UUID, text: String, attachments: [ChatAttachment]) async throws -> ChatPostedMessage
    /// 에이전트 대상: 응답의 `reply`는 null이고 전달 표시가 온다
    func postAgentMessage(conversationID: UUID, clientMessageID: UUID, text: String, attachments: [ChatAttachment]) async throws -> AgentPostedMessage
}
