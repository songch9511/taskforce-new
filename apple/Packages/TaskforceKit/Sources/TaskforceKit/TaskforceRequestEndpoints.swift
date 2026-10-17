import Foundation
import Supabase

// OA U3: Taskforce 대화가 서버와 닿는 길. 읽기 둘 + 쓰기 하나뿐이다 (새 서버 route 없음).
// - `GET /api/v2/review` (`REVIEW_V2_ENABLED`): 결정 목록. **이 GET은 읽기만 하지 않는다** — 제안 생산 · 노출 표시(`shown_at` · 그날 묶음 소비)를 한다 (`docs/review-summary.md` 1절).
//   그래서 정해진 주기로 읽지 않고, 사용자가 화면을 열거나 바뀔 까닭이 있을 때만 읽는다 (`TaskforceRequestStore`). 측정 공백은 U3 notes에 있다.
// - RLS select: 경로 충돌의 경로 (`agent_path_leases.rel_path`)와 두 run의 세션 (`execution_runs.agent_session_id`). 쓰기 0.
// - `POST /api/v2/path-conflicts/{lease_id}/resolve { keep, conflict_version }`: 되돌릴 수 없어서 보내기 전 2초 보류는 앱 몫이다 (`TaskforceRequestStore`).
//   200 resolved · 409 conflict(옛 version이거나 이미 해소됨: 쓰기 0, 자동 재시도 없이 다시 읽는다) · 404 · 400 · 401.

extension APIClient {
    /// 결정 목록 (서버 순서 그대로)
    public func taskforceReview() async throws -> TaskforceReviewResponse {
        try await send(.get, "review", version: .v2)
    }

    /// 경로 충돌 해소. `conflictVersion`은 Review 항목의 `conflict.conflict_version` 그대로 (1…2,147,483,647)
    public func resolvePathConflict(leaseID: UUID, keep: TaskforceConflictKeep, conflictVersion: Int) async throws -> TaskforceResolveConflictResponse {
        try await send(
            .post, "path-conflicts/\(leaseID.lowercased)/resolve",
            body: TaskforceResolveConflictRequest(keep: keep, conflictVersion: conflictVersion), version: .v2
        )
    }
}

/// 경로 충돌 상세 읽기에 쓰는 열 목록 (RLS select 둘)
struct TaskforceLeaseRow: Decodable {
    let id: UUID
    let relPath: String

    static let columns = "id, rel_path"

    enum CodingKeys: String, CodingKey {
        case id
        case relPath = "rel_path"
    }
}

struct TaskforceRunSessionRow: Decodable {
    let id: UUID
    let agentSessionID: UUID?

    static let columns = "id, agent_session_id"

    enum CodingKeys: String, CodingKey {
        case id
        case agentSessionID = "agent_session_id"
    }
}

extension TaskforceReads {
    /// 충돌들의 경로와 두 run의 세션. 읽지 못한 충돌은 결과에 없다 (지어내지 않는다)
    public func pathConflictDetails(_ refs: [TaskforceConflictRef]) async throws -> [UUID: TaskforceConflictDetail] {
        guard !refs.isEmpty else { return [:] }
        let leaseIDs = Array(Set(refs.map(\.leaseID))).sorted { $0.uuidString < $1.uuidString }
        let runIDs = Array(Set(refs.flatMap { [$0.holderRunID, $0.laterRunID] })).sorted { $0.uuidString < $1.uuidString }
        async let leaseRows: [TaskforceLeaseRow] = rows(
            supabase.from("agent_path_leases").select(TaskforceLeaseRow.columns).in("id", values: leaseIDs.map(\.lowercased))
        )
        async let runRows: [TaskforceRunSessionRow] = rows(
            supabase.from("execution_runs").select(TaskforceRunSessionRow.columns).in("id", values: runIDs.map(\.lowercased))
        )
        let paths = Dictionary(try await leaseRows.map { ($0.id, $0.relPath) }, uniquingKeysWith: { first, _ in first })
        let sessions = Dictionary(try await runRows.map { ($0.id, $0.agentSessionID) }, uniquingKeysWith: { first, _ in first })
        var details: [UUID: TaskforceConflictDetail] = [:]
        for ref in refs {
            guard let path = paths[ref.leaseID] else { continue }
            details[ref.leaseID] = TaskforceConflictDetail(
                leaseID: ref.leaseID, relPath: path, holderRunID: ref.holderRunID, laterRunID: ref.laterRunID,
                holderSessionID: sessions[ref.holderRunID] ?? nil, laterSessionID: sessions[ref.laterRunID] ?? nil
            )
        }
        return details
    }
}

/// Taskforce 대화 저장소가 서버와 닿는 면. 저장소는 이 프로토콜만 안다: 시험은 가짜로 붙잡기 · 실패 · 순서를 정확히 다룬다.
/// 기본 구현은 "이 서버는 아직 이 기능이 없다"(404)다: `IssueScreensGateway`를 따르는 옛 가짜들이 고쳐지지 않고 컴파일된다
public protocol TaskforceRequestGateway: Sendable {
    func taskforceReview() async throws -> TaskforceReviewResponse
    func pathConflictDetails(_ refs: [TaskforceConflictRef]) async throws -> [UUID: TaskforceConflictDetail]
    func resolvePathConflict(leaseID: UUID, keep: TaskforceConflictKeep, conflictVersion: Int) async throws -> TaskforceResolveConflictResponse
}

extension TaskforceRequestGateway {
    public func taskforceReview() async throws -> TaskforceReviewResponse { throw APIError.unexpectedStatus(404) }
    public func pathConflictDetails(_ refs: [TaskforceConflictRef]) async throws -> [UUID: TaskforceConflictDetail] { [:] }
    public func resolvePathConflict(leaseID: UUID, keep: TaskforceConflictKeep, conflictVersion: Int) async throws -> TaskforceResolveConflictResponse {
        throw APIError.unexpectedStatus(404)
    }
}

extension LiveChatGateway: TaskforceRequestGateway {
    public func taskforceReview() async throws -> TaskforceReviewResponse { try await api.taskforceReview() }

    public func pathConflictDetails(_ refs: [TaskforceConflictRef]) async throws -> [UUID: TaskforceConflictDetail] {
        try await reads.pathConflictDetails(refs)
    }

    public func resolvePathConflict(leaseID: UUID, keep: TaskforceConflictKeep, conflictVersion: Int) async throws -> TaskforceResolveConflictResponse {
        try await api.resolvePathConflict(leaseID: leaseID, keep: keep, conflictVersion: conflictVersion)
    }
}
