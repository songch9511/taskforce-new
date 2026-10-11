#if DEBUG
import Foundation
import Supabase
import TaskforceKit

/// 디자인 비교 · 격리 확인용 가짜 서버 (Debug 빌드, `-TFSampleData`): 범위 · 멤버십을 메모리에서 서버처럼 돌려준다. 네트워크 · 계정 · 실제 AI 호출 없음.
/// 서버 head `0da883a`의 규칙을 같은 방식으로 따른다: 쓰기는 `expected_context_version`이 지금과 다르면 쓰기 0 + 409, 보관된 범위는 404,
/// add는 auto · inferred를 user로 승격하고 뺀 행을 되살린다, remove는 행을 남기고 뺀 표시, `change`는 **확인된 멤버가 실제로 바뀐 범위만**.
/// 견본 멤버십: 데모 준비(Set by you, Shape) · 온보딩 시안(Auto-linked, Shape) · 디자인 인계(Shape + Acme 둘 다) · 파트너 자료(Acme) ·
/// 데모 환경 배포(Shape가 확인되지 않은 후보) · QA 시나리오(보관된 Old project) · 나머지는 멤버십 없음.
/// `scenario`는 스냅샷이 상태를 바꿔 가며 담는 데 쓴다 (실사용 앱의 저장소 · 설정은 건드리지 않는다)
actor SampleContextGateway: ContextGateway {
    enum Scenario: String, Sendable {
        /// 범위 셋(하나는 보관됨) + 견본 멤버십
        case full
        /// 범위 없음
        case empty
        /// 읽기가 오프라인 / 서버 오류
        case offline, failed
        /// 서버 DB에 범위 테이블이 아직 없다 (PGRST205)
        case unavailable
        /// 읽기는 되지만 쓰기가 gate 꺼짐(404)
        case featureOff
        /// 읽기가 끝나지 않는다 (읽는 중)
        case readHangs
        /// 쓰기가 끝나지 않는다 (진행 중 표시)
        case writeHangs
        /// 쓰기를 서버가 처리하고도 응답을 잃는다 (전송 오류)
        case loseResponse
    }

    private struct Pair: Hashable {
        let context: UUID
        let action: UUID
    }

    private struct Row {
        var origin: ContextMemberOrigin
        var confidence: Double?
        var removed: Bool
    }

    /// 서버 쪽 데이터 (범위 · 멤버 행)
    private struct State {
        var contexts: [UUID: WorkContext] = [:]
        var rows: [Pair: Row] = [:]
        var order: [Pair] = []

        mutating func seed(_ context: UUID, _ action: UUID, _ origin: ContextMemberOrigin, confidence: Double? = nil) {
            let pair = Pair(context: context, action: action)
            order.append(pair)
            rows[pair] = Row(origin: origin, confidence: confidence, removed: false)
        }

        static func fixture(_ scenario: Scenario) -> State {
            var state = State()
            guard scenario != .empty else { return state }
            for context in [
                WorkContext(id: SampleContextIDs.shape, name: "Shape launch", contextVersion: 3),
                WorkContext(id: SampleContextIDs.acme, name: "Acme website", contextVersion: 5),
                WorkContext(id: SampleContextIDs.old, name: "Old project", status: .archived, contextVersion: 2),
            ] { state.contexts[context.id] = context }
            state.seed(SampleContextIDs.shape, SampleData.id(10), .user)
            state.seed(SampleContextIDs.shape, SampleData.id(11), .auto)
            state.seed(SampleContextIDs.shape, SampleData.id(12), .user)
            state.seed(SampleContextIDs.acme, SampleData.id(12), .auto)
            state.seed(SampleContextIDs.acme, SampleData.id(13), .user)
            state.seed(SampleContextIDs.shape, SampleData.id(14), .inferred, confidence: 0.62)
            state.seed(SampleContextIDs.old, SampleData.id(20), .user)
            return state
        }
    }

    private var scenario: Scenario
    private var contexts: [UUID: WorkContext]
    private var rows: [Pair: Row]
    private var order: [Pair]
    private var rowIDs: [Pair: Int] = [:]

    init(scenario: Scenario = .full) {
        self.scenario = scenario
        let state = State.fixture(scenario)
        contexts = state.contexts
        rows = state.rows
        order = state.order
    }

    /// 스냅샷이 상태를 바꿔 가며 담는다: 시나리오를 바꾸고 서버 쪽 데이터를 처음으로 되돌린다
    func setScenario(_ scenario: Scenario) {
        self.scenario = scenario
        let state = State.fixture(scenario)
        contexts = state.contexts
        rows = state.rows
        order = state.order
        rowIDs = [:]
    }

    /// 다른 기기가 같은 규칙으로 쓴다 (스냅샷의 충돌 상태용)
    func otherDevice(_ op: ContextMemberOp, context: UUID, action: UUID) {
        _ = apply(op, context: context, action: action)
    }

    func archive(_ context: UUID) {
        guard let current = contexts[context] else { return }
        contexts[context] = WorkContext(id: current.id, name: current.name, status: .archived, contextVersion: (current.contextVersion ?? 0) + 1)
    }

    private func bump(_ context: UUID) {
        guard let current = contexts[context] else { return }
        contexts[context] = WorkContext(id: current.id, name: current.name, status: current.status, contextVersion: (current.contextVersion ?? 0) + 1)
    }

    /// 한 범위에 쓴다. 반환: 확인된 멤버가 바뀌었나
    private func apply(_ op: ContextMemberOp, context: UUID, action: UUID) -> Bool {
        let pair = Pair(context: context, action: action)
        let existing = rows[pair]
        let wasConfirmed = existing.map { !$0.removed && $0.origin.isConfirmed } ?? false
        let next: Row
        switch op {
        case .add:
            if let existing, !existing.removed, existing.origin == .user { return false }
            next = Row(origin: .user, confidence: nil, removed: false)
        case .remove:
            if let existing, existing.removed { return false }
            next = Row(origin: .user, confidence: nil, removed: true)
        }
        if existing == nil { order.append(pair) }
        rows[pair] = next
        bump(context)
        return wasConfirmed != (!next.removed && next.origin.isConfirmed)
    }

    private func member(_ context: UUID, _ action: UUID) -> ContextMember {
        let pair = Pair(context: context, action: action)
        let row = rows[pair] ?? Row(origin: .user, confidence: nil, removed: true)
        if rowIDs[pair] == nil { rowIDs[pair] = rowIDs.count + 1 }
        return ContextMember(
            id: UUID(uuidString: String(format: "D1E50000-0000-4000-8000-%012d", rowIDs[pair] ?? 0))!, contextID: context, actionID: action,
            origin: row.origin, confidence: row.confidence, isRemoved: row.removed
        )
    }

    // MARK: 읽기

    private func read<T>(_ value: () -> T) throws -> T {
        switch scenario {
        case .offline: throw URLError(.notConnectedToInternet)
        case .failed: throw APIError.server(status: 500, code: .internalError, message: "x")
        case .unavailable: throw sampleMissingTable()
        default: return value()
        }
    }

    func workContexts() async throws -> [WorkContext] {
        if scenario == .readHangs { try await Task.sleep(for: .seconds(3600)) }
        return try read { contexts.values.sorted { $0.name < $1.name } }
    }

    func contextMembers() async throws -> [ContextMember] {
        try read { order.filter { rows[$0]?.removed == false && contexts[$0.context] != nil }.map { member($0.context, $0.action) } }
    }

    // MARK: 쓰기 (조건부)

    private func gate() throws {
        if scenario == .featureOff { throw APIError.server(status: 404, code: .notFound, message: APIError.featureOffMessage) }
    }

    private func missingContext() -> APIError { .server(status: 404, code: .notFound, message: APIError.missingContextMessage) }
    private func conflict() -> APIError { .server(status: 409, code: .conflict, message: "그 사이 범위가 바뀌었습니다. 다시 불러온 뒤 시도해 주세요.") }

    private func hangIfScripted() async throws {
        // 응답이 오지 않는다 (취소되면 끝난다)
        if scenario == .writeHangs { try await Task.sleep(for: .seconds(3600)) }
    }

    private func loseIfScripted() throws {
        if scenario == .loseResponse { throw APIError.transport("connection lost") }
    }

    func changeContextMember(contextID: UUID, op: ContextMemberOp, actionID: UUID, expectedVersion: Int) async throws -> ContextMemberWriteResponse {
        try gate()
        try await hangIfScripted()
        guard let target = contexts[contextID], target.isActive else { throw missingContext() }
        guard target.contextVersion == expectedVersion else { throw conflict() }
        let changed = apply(op, context: contextID, action: actionID)
        let version = contexts[contextID]?.contextVersion ?? 0
        let reference = ContextVersionRef(contextID: contextID, contextVersion: version)
        try loseIfScripted()
        return ContextMemberWriteResponse(
            member: member(contextID, actionID), contextVersion: version,
            change: changed ? (op == .add ? ContextChange(added: [reference]) : ContextChange(removed: [reference])) : ContextChange()
        )
    }

    func moveContextMember(
        actionID: UUID, from fromContextID: UUID, to toContextID: UUID, expectedToVersion: Int, expectedFromVersion: Int
    ) async throws -> ContextMemberMoveResponse {
        try gate()
        try await hangIfScripted()
        guard let to = contexts[toContextID], to.isActive, let from = contexts[fromContextID], from.isActive else { throw missingContext() }
        guard to.contextVersion == expectedToVersion, from.contextVersion == expectedFromVersion else { throw conflict() }
        let removedChanged = apply(.remove, context: fromContextID, action: actionID)
        let addedChanged = apply(.add, context: toContextID, action: actionID)
        let toVersion = contexts[toContextID]?.contextVersion ?? 0
        let fromVersion = contexts[fromContextID]?.contextVersion ?? 0
        try loseIfScripted()
        return ContextMemberMoveResponse(
            member: member(toContextID, actionID), fromMember: member(fromContextID, actionID), contextVersion: toVersion, fromContextVersion: fromVersion,
            change: ContextChange(
                added: addedChanged ? [ContextVersionRef(contextID: toContextID, contextVersion: toVersion)] : [],
                removed: removedChanged ? [ContextVersionRef(contextID: fromContextID, contextVersion: fromVersion)] : []
            )
        )
    }
}

/// PostgREST: 스키마 캐시에 테이블이 없음 (마이그레이션 적용 전)
private func sampleMissingTable() -> Error {
    PostgrestError(code: "PGRST205", message: "Could not find the table 'public.work_contexts'")
}

/// 견본 범위 id (`SampleChatIDs`의 프로젝트와 같은 id)
enum SampleContextIDs {
    static let shape = SampleChatIDs.shapeLaunch
    static let acme = SampleChatIDs.acme
    static let old = UUID(uuidString: "09D60000-0000-4000-8000-000000000003")!
}

extension SampleData {
    /// `-TFSampleContexts <이름>`: 시작 상태 (기본 full). 이름은 `SampleContextGateway.Scenario`
    static var contextScenario: SampleContextGateway.Scenario {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-TFSampleContexts"), arguments.indices.contains(index + 1) else { return .full }
        return SampleContextGateway.Scenario(rawValue: arguments[index + 1]) ?? .full
    }
}
#endif
