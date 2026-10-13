import Foundation

// 범위 멤버십 쓰기 (`/api/v2/contexts`, 서버 head `0da883a`). 조건부 쓰기다: 요청이 본 범위 version이 지금과 다르면 서버는 쓰기 0 + 409 `conflict`.
// 성공은 200 응답뿐이다: 409 · 오류 · 응답 유실 뒤에 다시 읽은 지금 상태는 이 요청의 성공 증거가 아니다 (`WorkContextStore`가 지킨다).
// 이 쓰기는 AI · 승인 · 정책 · run을 부르지 않는다 (멤버십은 권한이 아니다, D13): 이 파일의 호출은 `contexts/…/members` 둘뿐이다.

extension APIError {
    /// 없는 · 남의 · 보관된 범위 (gate 꺼짐이 아닌 404, 서버 메시지로만 가른다)
    public static let missingContextMessage = "범위가 없습니다."
    /// 없는 · 남의 할 일
    public static let missingActionMessage = "할 일이 없습니다."

    /// 범위가 없다: 지워졌거나 남의 것이거나 **보관됐다** (서버가 보관된 범위를 같은 404로 답한다)
    public var isMissingContext: Bool {
        if case .server(404, .notFound, let message) = self { return message == Self.missingContextMessage }
        return false
    }

    /// 할 일이 없다 (지워졌거나 남의 것)
    public var isMissingAction: Bool {
        if case .server(404, .notFound, let message) = self { return message == Self.missingActionMessage }
        return false
    }
}

extension APIClient {
    /// 넣기 · 빼기: 그 범위에 origin **user** 멤버를 만들거나(add: 후보 · 자동 행이면 user로 승격, 뺀 행이면 되살림) 뺀 표시를 남긴다(remove).
    /// `expectedVersion`: 요청이 본 그 범위의 `work_contexts.context_version`. 다르면 409(쓰기 0). 404 = gate 꺼짐 · 없는/남의/보관된 범위 · 없는 할 일
    public func changeContextMember(contextID: UUID, op: ContextMemberOp, actionID: UUID, expectedVersion: Int) async throws -> ContextMemberWriteResponse {
        try await send(
            .post, "contexts/\(contextID.lowercased)/members",
            body: ContextMemberWriteRequest(op: op, actionID: actionID, expectedContextVersion: expectedVersion), version: .v2
        )
    }

    /// 옮기기 A → B (경로 = 도착 범위 B): 한 트랜잭션에서 A에서 빼고 B에 넣는다. 전체 교체가 아니다 (그 할 일의 다른 범위 멤버십은 그대로).
    /// 두 범위의 version 중 하나라도 다르면 409(쓰기 0), 둘 다 내 active 범위여야 한다 (아니면 404, 아무것도 쓰지 않는다)
    public func moveContextMember(
        actionID: UUID, from fromContextID: UUID, to toContextID: UUID, expectedToVersion: Int, expectedFromVersion: Int
    ) async throws -> ContextMemberMoveResponse {
        try await send(
            .post, "contexts/\(toContextID.lowercased)/members/move",
            body: ContextMemberMoveRequest(
                actionID: actionID, fromContextID: fromContextID, expectedContextVersion: expectedToVersion,
                expectedFromContextVersion: expectedFromVersion
            ),
            version: .v2
        )
    }
}
