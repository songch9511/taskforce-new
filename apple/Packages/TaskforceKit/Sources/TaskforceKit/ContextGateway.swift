import Foundation

/// 범위 멤버십 저장소가 서버와 닿는 면 (읽기 = Supabase RLS, 쓰기 = 서버 `/api/v2/contexts`).
/// 저장소는 이 프로토콜만 안다: 테스트는 가짜로 붙잡기 · 실패 · 순서를 정확히 다룬다 (실제 연결은 `LiveContextGateway`).
/// 이 면에는 실행 · 정책 · 승인 · run이 없다: 멤버십은 범위일 뿐 권한이 아니다 (D13)
public protocol ContextGateway: Sendable {
    // 읽기 (RLS)
    func workContexts() async throws -> [WorkContext]
    func contextMembers() async throws -> [ContextMember]

    // 쓰기 (서버 API, Bearer, 조건부)
    func changeContextMember(contextID: UUID, op: ContextMemberOp, actionID: UUID, expectedVersion: Int) async throws -> ContextMemberWriteResponse
    func moveContextMember(
        actionID: UUID, from fromContextID: UUID, to toContextID: UUID, expectedToVersion: Int, expectedFromVersion: Int
    ) async throws -> ContextMemberMoveResponse
}

/// 실제 연결: `TaskforceReads`(RLS) + `APIClient`(쓰기)
public struct LiveContextGateway: ContextGateway {
    private let reads: TaskforceReads
    private let api: APIClient

    public init(reads: TaskforceReads, api: APIClient) {
        self.reads = reads
        self.api = api
    }

    public init(services: AppServices) {
        self.init(reads: services.reads, api: services.api)
    }

    public func workContexts() async throws -> [WorkContext] { try await reads.workContexts() }
    public func contextMembers() async throws -> [ContextMember] { try await reads.contextMembers() }

    public func changeContextMember(contextID: UUID, op: ContextMemberOp, actionID: UUID, expectedVersion: Int) async throws -> ContextMemberWriteResponse {
        try await api.changeContextMember(contextID: contextID, op: op, actionID: actionID, expectedVersion: expectedVersion)
    }

    public func moveContextMember(
        actionID: UUID, from fromContextID: UUID, to toContextID: UUID, expectedToVersion: Int, expectedFromVersion: Int
    ) async throws -> ContextMemberMoveResponse {
        try await api.moveContextMember(
            actionID: actionID, from: fromContextID, to: toContextID, expectedToVersion: expectedToVersion, expectedFromVersion: expectedFromVersion
        )
    }
}
