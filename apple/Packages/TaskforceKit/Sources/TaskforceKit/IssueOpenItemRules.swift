import Foundation

/// 패널에 지금 열린 항목 하나: Assistant 창의 auto 칩이 따라간다 (OA U2-45). 종류는 서버 칩 종류(`attachmentKindSchema`)다
public struct AssistantOpenItem: Equatable, Sendable {
    public let kind: ChatAttachmentKind
    public let id: UUID
    public let title: String
    /// 이슈 번호 (이슈만, 아직 못 읽었으면 nil)
    public let number: Int?

    public init(kind: ChatAttachmentKind, id: UUID, title: String, number: Int? = nil) {
        self.kind = kind
        self.id = id
        self.title = title
        self.number = number
    }
}

extension AssistantChip {
    /// 패널에서 열린 항목의 auto 칩
    public init(open item: AssistantOpenItem) {
        self.init(kind: item.kind, itemID: item.id, origin: .auto, title: item.title, number: item.number)
    }
}

public enum IssueOpenItemRules {
    /// 가장 안쪽에 열린 것: 세션 패널 → 그 세션, 이슈 상세 → 그 이슈(번호 앞), 프로젝트 목록 → 그 프로젝트.
    /// Ungrouped · Done today · Projects · 없는 항목은 칩이 없다
    public static func openItem(
        screen: IssueScreen, session: AgentSessionItem?, items: [WorkItem], contexts: [WorkContext], number: (UUID) -> Int?
    ) -> AssistantOpenItem? {
        if let session { return AssistantOpenItem(kind: .agentSession, id: session.id, title: session.name) }
        switch screen {
        case .detail(let id):
            return items.first { $0.id == id }.map { AssistantOpenItem(kind: .action, id: id, title: $0.action.title, number: number(id)) }
        case .list(.project(let id)):
            return contexts.first { $0.id == id && $0.isActive }.map { AssistantOpenItem(kind: .context, id: id, title: $0.name) }
        case .list(.ungrouped), .list(.doneToday), .projects:
            return nil
        }
    }
}
