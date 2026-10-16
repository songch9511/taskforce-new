import Foundation
import Observation

// OA U2: 이슈 번호 읽기 (U2-33). v1 응답(`actionSummarySchema`)은 동결이라 번호가 없다: Mac은 `actions.number`를 RLS로 읽는다
// (`20261120000000_action_numbers.sql`: 사용자별 · 재사용 없음 · 변경 불가). 상세는 `ActionRecord.number`, 목록 항목은 받은 id로 `select id, number`를 한 번 (배치 · 캐시).
// 번호를 모르면(열이 없는 DB · 읽기 실패 · 지워진 행) 그 자리를 비운다: 번호를 지어내지 않는다.

/// `select id, number` 한 줄
struct IssueNumberRow: Decodable, Sendable, Hashable {
    let id: UUID
    let number: Int

    static let columns = "id, number"
}

/// 번호 저장소가 서버와 닿는 면 (읽기 = Supabase RLS)
public protocol IssueNumberGateway: Sendable {
    /// 그 id들의 번호. 모르는 id(지워졌거나 남의 것 · 번호 열이 없는 DB)는 답에 없다
    func actionNumbers(ids: [UUID]) async throws -> [UUID: Int]
}

/// 이슈 번호 캐시. 이 객체의 메모리뿐이다 (디스크 없음). 계정이 떠나면 비운다
@MainActor
@Observable
public final class IssueNumberStore {
    public private(set) var numbers: [UUID: Int] = [:]
    @ObservationIgnored private var absent: Set<UUID> = []
    @ObservationIgnored private var inFlight: Set<UUID> = []
    @ObservationIgnored private let gateway: any IssueNumberGateway
    @ObservationIgnored private let scope: AccountScope

    public init(gateway: any IssueNumberGateway, scope: AccountScope) {
        self.gateway = gateway
        self.scope = scope
        scope.onLeft { [weak self] in self?.reset() }
    }

    public func reset() {
        numbers = [:]
        absent = []
        inFlight = []
    }

    public func number(for id: UUID) -> Int? { numbers[id] }

    /// "#139" (번호를 모르면 nil)
    nonisolated public static func label(_ number: Int?) -> String? {
        number.map { "#\($0)" }
    }

    /// 아직 모르는 id의 번호를 한 번에 읽는다. 아는 id · 번호가 없다고 확인된 id · 읽는 중인 id는 다시 부르지 않는다.
    /// 실패해도 화면은 그 자리를 비울 뿐이다 (다음에 다시 시도한다). 계정이 바뀐 뒤의 늦은 응답은 버린다
    public func ensure(_ ids: [UUID]) async {
        guard let token = scope.token else { return }
        var seen = Set<UUID>()
        let wanted = ids.filter { numbers[$0] == nil && !absent.contains($0) && !inFlight.contains($0) && seen.insert($0).inserted }
        guard !wanted.isEmpty else { return }
        inFlight.formUnion(wanted)
        defer { inFlight.subtract(wanted) }
        guard let read = try? await gateway.actionNumbers(ids: wanted), scope.isCurrent(token) else { return }
        numbers.merge(read) { _, new in new }
        absent.formUnion(wanted.filter { read[$0] == nil })
    }
}
