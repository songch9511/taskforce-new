import Foundation
import Supabase

/// Action 상세에 필요한 것 한 번에: 행, 근거(+원문 요약), 변경 이력
public struct ActionDetail: Sendable, Hashable {
    public let action: ActionRecord
    /// 최신이 위
    public let evidence: [EvidenceRecord]
    public let sources: [UUID: SourceSummary]
    public let events: [ActionEventRecord]
}

/// 원문 상세: 원문 + 이 원문에서 나온 근거 인용
public struct SourceDetail: Sendable, Hashable {
    public let source: SourceRecord
    public let evidence: [EvidenceRecord]
}

/// Supabase 직접 읽기 (RLS로 본인 행만, 읽기 전용). 쓰기는 `APIClient`로만 한다.
public struct TaskforceReads: Sendable {
    private let supabase: SupabaseClient

    public init(supabase: SupabaseClient) {
        self.supabase = supabase
    }

    /// `action_events.type` 중 변경 이력에서 빼는 것 (`POST /actions/:id/seen`이 남긴다)
    static let seenEventType = "user_seen"

    public func actionDetail(id: UUID) async throws -> ActionDetail {
        let idString = id.lowercased
        async let actionRows: [ActionRecord] = rows(
            supabase.from("actions").select(ActionRecord.columns).eq("id", value: idString).limit(1)
        )
        async let evidenceRows: [EvidenceRecord] = rows(
            supabase.from("evidence").select(EvidenceRecord.columns).eq("action_id", value: idString)
                .order("created_at", ascending: false).limit(50)
        )
        // `user_seen`(바뀜 점을 본 기록, U1 PR2)은 변경 이력이 아니라 빼고 읽는다: 이력에 보이지 않고 100개 한도도 먹지 않게
        async let eventRows: [ActionEventRecord] = rows(
            supabase.from("action_events").select(ActionEventRecord.columns).eq("action_id", value: idString)
                .neq("type", value: Self.seenEventType)
                .order("created_at", ascending: false).limit(100)
        )
        guard let action = try await actionRows.first else { throw APIError.server(status: 404, code: .notFound, message: "") }
        let evidence = try await evidenceRows
        let events = try await eventRows

        let sourceIDs = Array(Set(evidence.map(\.sourceID)))
        let sources: [SourceSummary] = sourceIDs.isEmpty
            ? []
            : try await rows(supabase.from("sources").select(SourceSummary.columns).in("id", values: sourceIDs.map(\.lowercased)))
        return ActionDetail(
            action: action,
            evidence: evidence,
            sources: Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            events: events
        )
    }

    /// 오늘 끝낸 할 일 (Done Today): `since`(기기 시간대의 오늘 0시) 뒤에 바뀐 완료 행, 최근 것이 위.
    /// 다른 사람 몫은 GET /now 목록에 보인 적이 없어 뺀다.
    public func doneToday(since start: Date, limit: Int = 10) async throws -> [ActionSummary] {
        try await rows(
            supabase.from("actions").select(ActionSummary.columns)
                .eq("status", value: ActionStatus.done.rawValue)
                .neq("owner", value: ActionOwner.other.rawValue)
                .gte("updated_at", value: start.ISO8601Format())
                .order("updated_at", ascending: false).limit(limit)
        )
    }

    /// 최근 원문. 할 일 도구 스냅샷(`task`)과 실행 receipt(`execution`)는 읽을 글이 아니라 뺀다.
    public func recentSources(limit: Int = 50) async throws -> [SourceSummary] {
        try await rows(
            supabase.from("sources").select(SourceSummary.columns).neq("kind", value: "task").neq("kind", value: SourceKind.execution.rawValue)
                .order("occurred_at", ascending: false).limit(limit)
        )
    }

    public func sourceDetail(id: UUID) async throws -> SourceDetail {
        let idString = id.lowercased
        async let sourceRows: [SourceRecord] = rows(
            supabase.from("sources").select(SourceRecord.columns).eq("id", value: idString).limit(1)
        )
        async let evidenceRows: [EvidenceRecord] = rows(
            supabase.from("evidence").select(EvidenceRecord.columns).eq("source_id", value: idString)
        )
        guard let source = try await sourceRows.first else { throw APIError.server(status: 404, code: .notFound, message: "") }
        return SourceDetail(source: source, evidence: try await evidenceRows)
    }

    /// 내 연결 (토큰은 서버에만 있고 여기서는 상태만 읽는다)
    public func connections() async throws -> [ConnectionRecord] {
        try await rows(supabase.from("connections").select(ConnectionRecord.columns).order("created_at", ascending: true))
    }

    /// 내가 "Want this"를 누른 2단계 서비스
    public func connectionRequests() async throws -> Set<ConnectionProvider> {
        struct Row: Decodable { let provider: String }
        let result: [Row] = try await rows(supabase.from("connection_requests").select("provider"))
        return Set(result.compactMap { ConnectionProvider(rawValue: $0.provider) })
    }

    /// 응답 본문을 앱의 디코더(마이크로초 시각 · 날짜)로 읽는다.
    private func rows<T: Decodable>(_ builder: PostgrestTransformBuilder) async throws -> [T] {
        let data = try await builder.execute().data
        return try TaskforceJSON.decoder().decode([T].self, from: data)
    }
}
