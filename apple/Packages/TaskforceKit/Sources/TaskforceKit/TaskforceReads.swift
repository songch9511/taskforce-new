import Foundation
import Supabase
import Synchronization

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
    /// `execution_runs.stopped_at` 열이 없음을 이번 실행에서 알았나 (서버 U2 Mac PR1 마이그레이션 전 DB: 매 읽기마다 실패 응답을 받지 않게)
    private let missingStoppedAt = MissingColumnMemo()

    public init(supabase: SupabaseClient) {
        self.supabase = supabase
    }

    /// `action_events.type` 중 변경 이력에서 빼는 것 (`POST /actions/:id/seen`이 남긴다)
    static let seenEventType = "user_seen"
    private static let pageSize = 500
    private static let evidenceActionChunkSize = 50
    private static let sourceIDChunkSize = 100

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
        guard limit > 0 else { return [] }
        return try await rows(
            doneTodayQuery(since: start).limit(limit)
        )
    }

    /// Complete Done Today list for the Mac launcher. Uses stable pagination without
    /// changing the existing limited `doneToday(since:limit:)` call contract.
    public func allDoneToday(since start: Date) async throws -> [ActionSummary] {
        var result: [ActionSummary] = []
        var offset = 0
        while true {
            let page: [ActionSummary] = try await rows(
                doneTodayQuery(since: start).range(from: offset, to: offset + Self.pageSize - 1)
            )
            result.append(contentsOf: page)
            guard page.count == Self.pageSize else { return result }
            offset += page.count
        }
    }

    /// Source services for collapsed launcher rows. Reads references and provider
    /// metadata in bounded batches; it never fetches quotes or source bodies.
    public func actionSourceServices(actionIDs: [UUID]) async throws -> [UUID: [SourceService]] {
        let actionIDs = Array(Set(actionIDs)).sorted { $0.uuidString < $1.uuidString }
        guard !actionIDs.isEmpty else { return [:] }

        var references: [ActionEvidenceSource] = []
        for start in stride(from: 0, to: actionIDs.count, by: Self.evidenceActionChunkSize) {
            let end = min(start + Self.evidenceActionChunkSize, actionIDs.count)
            let ids = actionIDs[start..<end].map(\.lowercased)
            var offset = 0
            while true {
                let page: [ActionEvidenceSource] = try await rows(
                    supabase.from("evidence").select("id, action_id, source_id, created_at")
                        .in("action_id", values: ids)
                        .order("action_id", ascending: true)
                        .order("created_at", ascending: true)
                        .order("id", ascending: true)
                        .range(from: offset, to: offset + Self.pageSize - 1)
                )
                references.append(contentsOf: page)
                guard page.count == Self.pageSize else { break }
                offset += page.count
            }
        }
        guard !references.isEmpty else { return [:] }

        let sourceIDs = Array(Set(references.map(\.sourceID))).sorted { $0.uuidString < $1.uuidString }
        var sources: [UUID: SourceService] = [:]
        for start in stride(from: 0, to: sourceIDs.count, by: Self.sourceIDChunkSize) {
            let end = min(start + Self.sourceIDChunkSize, sourceIDs.count)
            let ids = sourceIDs[start..<end].map(\.lowercased)
            let page: [SourceProviderRecord] = try await rows(
                supabase.from("sources").select("id, kind, external_url").in("id", values: ids)
            )
            for source in page {
                let service = SourceService.infer(externalURL: source.externalURL, kind: source.kind)
                if service != .manual(.execution) { sources[source.id] = service }
            }
        }

        var result: [UUID: [SourceService]] = [:]
        var seen: [UUID: Set<SourceService>] = [:]
        for reference in references {
            guard let service = sources[reference.sourceID], seen[reference.actionID, default: []].insert(service).inserted else { continue }
            result[reference.actionID, default: []].append(service)
        }
        return result
    }

    private func doneTodayQuery(since start: Date) -> PostgrestTransformBuilder {
        supabase.from("actions").select(ActionSummary.columns)
            .eq("status", value: ActionStatus.done.rawValue)
            .neq("owner", value: ActionOwner.other.rawValue)
            .gte("updated_at", value: start.ISO8601Format())
            .order("updated_at", ascending: false)
            .order("id", ascending: false)
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

    // MARK: 실행 (U2, RLS `execution_*` owner_select, 읽기만)

    /// 끝나지 않은 run 상태 (`execution_runs.state`)
    static let openRunStates = [RunState.queued, .running, .waitingApproval].map(\.rawValue)

    /// 그 할 일들의 run (최근 것이 위). 할 일마다 최신 run은 `RunSummary.latestByAction`, 멈출 run은 `RunStop.targets`
    public func latestRuns(actionIDs: [UUID], limit: Int = 50) async throws -> [RunSummary] {
        guard !actionIDs.isEmpty else { return [] }
        let ids = actionIDs.map(\.lowercased)
        return try await runRows { columns in
            supabase.from("execution_runs").select(columns).in("action_id", values: ids)
                .order("created_at", ascending: false).limit(limit)
        }
    }

    /// 끝나지 않은 run 전부 (queued · running · waiting_approval): 범위 `Taskforce Working`
    public func activeRuns(limit: Int = 100) async throws -> [RunSummary] {
        try await runRows { columns in
            supabase.from("execution_runs").select(columns).in("state", values: Self.openRunStates)
                .order("created_at", ascending: false).limit(limit)
        }
    }

    /// 크레딧이 모자라 멈춘 끝나지 않은 run (S3 "N AI drafts are paused")
    public func pausedRuns(limit: Int = 50) async throws -> [RunSummary] {
        try await runRows { columns in
            supabase.from("execution_runs").select(columns).eq("hold_reason", value: RunHoldReason.credit.rawValue)
                .in("state", values: Self.openRunStates)
                .order("created_at", ascending: false).limit(limit)
        }
    }

    /// run의 단계 (차례대로)
    public func steps(runID: UUID) async throws -> [StepSummary] {
        try await rows(
            supabase.from("execution_steps").select(StepSummary.columns).eq("run_id", value: runID.lowercased).order("seq", ascending: true)
        )
    }

    /// 할 일의 초안 (최근 것이 위). 본문은 사용자 글이라 메모리에만 둔다
    public func artifacts(actionID: UUID, limit: Int = 20) async throws -> [Artifact] {
        try await rows(
            supabase.from("execution_artifacts").select(Artifact.columns).eq("action_id", value: actionID.lowercased)
                .order("created_at", ascending: false).limit(limit)
        )
    }

    /// 초안 하나 (receipt 링크 `taskforce://artifacts/<id>`). 없으면(다른 계정 · 지워진 행) nil
    public func artifact(id: UUID) async throws -> Artifact? {
        let found: [Artifact] = try await rows(
            supabase.from("execution_artifacts").select(Artifact.columns).eq("id", value: id.lowercased).limit(1)
        )
        return found.first
    }

    /// run 행 읽기. `stopped_at` 열이 아직 없는 DB(서버 U2 Mac PR1 마이그레이션 전)면 그 열 없이 다시 읽고(`stoppedAt` = nil),
    /// 이번 실행 동안은 처음부터 그 열 없이 읽는다
    private func runRows(_ query: (String) -> PostgrestTransformBuilder) async throws -> [RunSummary] {
        if missingStoppedAt.isSet { return try await rows(query(RunSummary.columnsWithoutStop)) }
        do {
            return try await rows(query(RunSummary.columns))
        } catch let error as PostgrestError where error.code == Self.undefinedColumn {
            missingStoppedAt.set()
            return try await rows(query(RunSummary.columnsWithoutStop))
        }
    }

    /// Postgres undefined_column (PostgREST가 select의 없는 열에 돌려주는 코드)
    static let undefinedColumn = "42703"

    /// 응답 본문을 앱의 디코더(마이크로초 시각 · 날짜)로 읽는다.
    private func rows<T: Decodable>(_ builder: PostgrestTransformBuilder) async throws -> [T] {
        let data = try await builder.execute().data
        return try TaskforceJSON.decoder().decode([T].self, from: data)
    }
}

private struct ActionEvidenceSource: Decodable {
    let id: UUID
    let actionID: UUID
    let sourceID: UUID

    enum CodingKeys: String, CodingKey {
        case id
        case actionID = "action_id"
        case sourceID = "source_id"
    }
}

private struct SourceProviderRecord: Decodable {
    let id: UUID
    let kind: SourceKind
    let externalURL: URL?

    enum CodingKeys: String, CodingKey {
        case id, kind
        case externalURL = "external_url"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(SourceKind.self, forKey: .kind)
        externalURL = (try? container.decodeIfPresent(String.self, forKey: .externalURL))
            .flatMap { $0.flatMap(URL.init(string:)) }
    }
}

/// 한 번 알면 계속 참인 표시 (`TaskforceReads`는 값 타입이라 복사본끼리 같은 상자를 본다)
final class MissingColumnMemo: Sendable {
    private let flag = Mutex(false)

    var isSet: Bool { flag.withLock { $0 } }

    func set() { flag.withLock { $0 = true } }
}
