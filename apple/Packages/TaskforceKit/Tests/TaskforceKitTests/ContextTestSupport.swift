import Foundation
import Synchronization
@testable import TaskforceKit

/// 서버 JSON 계약 fixture: 서버 head `0da883a` (S3b #125 = B3 `7328e93` + 커밋 4개, `handoffs/s3b-server-notes.md`) × 이 브랜치.
/// 이 모양이 바뀌면 `ContextContractTests`가 먼저 깨진다.
enum ContextContractFixtures {
    static let serverHead = "0da883add2ec21a43f0fb3b94d3d9237582ff0c8"
    static let serverBase = "7328e9360acff2f7013fa2c4ff641669b8e7f778"

    static func memberJSON(
        id: Int, ctx: UUID, action: UUID, origin: String = "user", confidence: String = "null", removedAt: String? = nil
    ) -> String {
        """
        {"id":"\(ContextFx.id(id, prefix: "d1e50000").uuidString.lowercased())","context_id":"\(ctx.uuidString.lowercased())","member_kind":"action","action_id":"\(action.uuidString.lowercased())","source_id":null,"person_id":null,
         "origin":"\(origin)","confidence":\(confidence),"removed_at":\(removedAt.map { "\"\($0)\"" } ?? "null"),"created_at":"2026-10-11T10:00:00.123456+00:00","updated_at":"2026-10-11T10:00:00.123456+00:00"}
        """
    }

    /// `POST /api/v2/contexts/{id}/members` 200 (서버 notes 예시 그대로의 모양)
    static func write(
        ctx: UUID, action: UUID, version: Int, added: Bool = true, removed: Bool = false, removedAt: String? = nil, origin: String = "user"
    ) -> String {
        let ref = "{\"context_id\":\"\(ctx.uuidString.lowercased())\",\"context_version\":\(version)}"
        return """
        {"member":\(memberJSON(id: 1, ctx: ctx, action: action, origin: origin, removedAt: removedAt)),"context_version":\(version),
         "change":{"added":[\(added ? ref : "")],"removed":[\(removed ? ref : "")]}}
        """
    }

    /// `POST /api/v2/contexts/{to}/members/move` 200 (A → B, 처음 A만이면 added에 B · removed에 A)
    static func move(
        from: UUID, to: UUID, action: UUID, fromVersion: Int, toVersion: Int, toWasAlreadyMember: Bool = false
    ) -> String {
        let toRef = "{\"context_id\":\"\(to.uuidString.lowercased())\",\"context_version\":\(toVersion)}"
        let fromRef = "{\"context_id\":\"\(from.uuidString.lowercased())\",\"context_version\":\(fromVersion)}"
        return """
        {"member":\(memberJSON(id: 2, ctx: to, action: action)),"from_member":\(memberJSON(id: 3, ctx: from, action: action, removedAt: "2026-10-11T10:00:00.123456+00:00")),
         "context_version":\(toVersion),"from_context_version":\(fromVersion),
         "change":{"added":[\(toWasAlreadyMember ? "" : toRef)],"removed":[\(fromRef)]}}
        """
    }
}

/// 행 만들기
enum ContextFx {
    static func id(_ n: Int, prefix: String = "c0000000") -> UUID {
        UUID(uuidString: String(format: "%@-0000-4000-8000-%012d", prefix, n))!
    }

    static func context(_ n: Int, _ name: String, archived: Bool = false, version: Int? = 1) -> WorkContext {
        WorkContext(id: id(n), name: name, status: archived ? .archived : .active, contextVersion: version)
    }

    static func member(
        _ n: Int, ctx: UUID, action: UUID?, origin: ContextMemberOrigin, confidence: Double? = nil, removed: Bool = false
    ) -> ContextMember {
        ContextMember(id: id(n, prefix: "d1e50000"), contextID: ctx, actionID: action, origin: origin, confidence: confidence, isRemoved: removed)
    }

    static func decodeWrite(_ json: String) throws -> ContextMemberWriteResponse {
        try TaskforceJSON.decoder().decode(ContextMemberWriteResponse.self, from: Data(json.utf8))
    }

    static func decodeMove(_ json: String) throws -> ContextMemberMoveResponse {
        try TaskforceJSON.decoder().decode(ContextMemberMoveResponse.self, from: Data(json.utf8))
    }
}

/// 가짜 `ContextGateway`: 응답을 스크립트로 정하고 부른 순서를 남긴다
final class FakeContextGateway: ContextGateway, @unchecked Sendable {
    struct Failure: Error {}

    /// 쓰기 요청이 보낸 값 (조건 version 포함)
    enum Call: Equatable, Sendable {
        case contexts
        case members
        case change(context: UUID, op: ContextMemberOp, action: UUID, version: Int)
        case move(action: UUID, from: UUID, to: UUID, toVersion: Int, fromVersion: Int)
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private func record(_ call: Call) {
        lock.lock()
        _calls.append(call)
        lock.unlock()
    }
    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }
    var writes: [Call] { calls.filter { if case .contexts = $0 { false } else if case .members = $0 { false } else { true } } }
    var reads: Int { calls.filter { $0 == .contexts }.count }

    nonisolated(unsafe) var contextsHandler: @Sendable () async throws -> [WorkContext] = { [] }
    nonisolated(unsafe) var membersHandler: @Sendable () async throws -> [ContextMember] = { [] }
    nonisolated(unsafe) var changeHandler: @Sendable (UUID, ContextMemberOp, UUID, Int) async throws -> ContextMemberWriteResponse = { _, _, _, _ in throw Failure() }
    nonisolated(unsafe) var moveHandler: @Sendable (UUID, UUID, UUID, Int, Int) async throws -> ContextMemberMoveResponse = { _, _, _, _, _ in throw Failure() }

    func workContexts() async throws -> [WorkContext] { record(.contexts); return try await contextsHandler() }
    func contextMembers() async throws -> [ContextMember] { record(.members); return try await membersHandler() }

    func changeContextMember(contextID: UUID, op: ContextMemberOp, actionID: UUID, expectedVersion: Int) async throws -> ContextMemberWriteResponse {
        record(.change(context: contextID, op: op, action: actionID, version: expectedVersion))
        return try await changeHandler(contextID, op, actionID, expectedVersion)
    }

    func moveContextMember(
        actionID: UUID, from fromContextID: UUID, to toContextID: UUID, expectedToVersion: Int, expectedFromVersion: Int
    ) async throws -> ContextMemberMoveResponse {
        record(.move(action: actionID, from: fromContextID, to: toContextID, toVersion: expectedToVersion, fromVersion: expectedFromVersion))
        return try await moveHandler(actionID, fromContextID, toContextID, expectedToVersion, expectedFromVersion)
    }

    /// 지금 서버 상태를 가리키는 읽기 (쓰기 뒤 다시 읽기에 쓴다)
    func serve(contexts: [WorkContext], members: [ContextMember]) {
        contextsHandler = { contexts }
        membersHandler = { members }
    }
}

/// 서버의 조건부 멤버십 쓰기를 메모리에서 같은 규칙으로 흉내 내는 가짜 서버 (`s3b-server-notes.md`의 계약):
/// version 조건이 다르면 쓰기 0 + 409, 보관된 범위는 404, add는 auto/inferred를 user로 승격하고 뺀 행을 되살린다, remove는 행을 남기고 뺀 표시,
/// `change`는 **확인된 멤버가 실제로 바뀐 범위만** (이미 멤버였던 도착 범위 · 후보를 뺌 · auto → user 승격은 비어 있다). 범위 version은 쓴 범위마다 오른다.
/// 읽기는 RLS 읽기처럼 지금 상태를 돌려준다. 응답 유실 · 느린 응답 · 다른 기기 변경은 이 객체의 메서드로 만든다
final class FakeContextServer: ContextGateway, @unchecked Sendable {
    struct Row: Equatable {
        var origin: ContextMemberOrigin
        var confidence: Double?
        var removed: Bool
    }

    private let lock = NSLock()
    private var _contexts: [UUID: WorkContext] = [:]
    private var rows: [Pair: Row] = [:]
    private var order: [Pair] = []
    private var rowIDs: [Pair: Int] = [:]
    private var _calls: [FakeContextGateway.Call] = []
    private var _gateOff = false
    private var _loseNext = 0
    private var _hold: Latch?
    private var _readHold: Latch?
    private var _readFailure: Error?

    struct Pair: Hashable { let context: UUID; let action: UUID }

    var calls: [FakeContextGateway.Call] { lock.withLock { _calls } }
    var writes: [FakeContextGateway.Call] { calls.filter { if case .contexts = $0 { false } else if case .members = $0 { false } else { true } } }

    init(contexts: [WorkContext]) {
        _contexts = Dictionary(contexts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// 서버 gate가 꺼짐 (쓰기가 404 "없는 경로입니다.")
    func setGateOff(_ off: Bool = true) { lock.withLock { _gateOff = off } }
    /// 다음 `n`개 쓰기는 서버가 처리하고도 응답을 잃는다 (전송 오류)
    func loseNextResponses(_ n: Int = 1) { lock.withLock { _loseNext = n } }
    /// 쓰기를 처리하기 전에 붙잡는다 (늦은 응답)
    func holdWrites(_ latch: Latch?) { lock.withLock { _hold = latch } }
    /// 멤버 읽기를 붙잡는다 (늦은 읽기)
    func holdReads(_ latch: Latch?) { lock.withLock { _readHold = latch } }
    func failReads(_ error: Error?) { lock.withLock { _readFailure = error } }

    func seed(_ ctx: UUID, _ action: UUID, origin: ContextMemberOrigin, confidence: Double? = nil, removed: Bool = false, bump: Bool = false) {
        lock.withLock {
            let pair = Pair(context: ctx, action: action)
            if rows[pair] == nil { order.append(pair) }
            rows[pair] = Row(origin: origin, confidence: confidence, removed: removed)
            if bump { bumpLocked(ctx) }
        }
    }

    func version(_ ctx: UUID) -> Int { lock.withLock { _contexts[ctx]?.contextVersion ?? 0 } }
    func row(_ ctx: UUID, _ action: UUID) -> Row? { lock.withLock { rows[Pair(context: ctx, action: action)] } }
    func archive(_ ctx: UUID) {
        lock.withLock {
            guard let c = _contexts[ctx] else { return }
            _contexts[ctx] = WorkContext(id: c.id, name: c.name, status: .archived, contextVersion: (c.contextVersion ?? 0) + 1)
        }
    }
    func deleteContext(_ ctx: UUID) {
        lock.withLock {
            _contexts[ctx] = nil
            rows = rows.filter { $0.key.context != ctx }
            order.removeAll { $0.context == ctx }
        }
    }

    /// 다른 기기가 같은 규칙으로 쓴다 (version 조건 없이 그 시점의 사용자 결정)
    func otherDevice(_ op: ContextMemberOp, ctx: UUID, action: UUID) {
        lock.withLock { _ = apply(op, ctx: ctx, action: action) }
    }

    private func bumpLocked(_ ctx: UUID) {
        guard let c = _contexts[ctx] else { return }
        _contexts[ctx] = WorkContext(id: c.id, name: c.name, status: c.status, contextVersion: (c.contextVersion ?? 0) + 1)
    }

    /// 한 범위에 쓴다. 반환: (행, 확인된 멤버가 바뀌었나)
    private func apply(_ op: ContextMemberOp, ctx: UUID, action: UUID) -> (Row, Bool) {
        let pair = Pair(context: ctx, action: action)
        let existing = rows[pair]
        let wasConfirmed = existing.map { !$0.removed && $0.origin.isConfirmed } ?? false
        var next: Row
        switch op {
        case .add:
            if let existing, !existing.removed, existing.origin == .user { return (existing, false) }
            next = Row(origin: .user, confidence: nil, removed: false)
        case .remove:
            if let existing, existing.removed { return (existing, false) }
            next = Row(origin: .user, confidence: nil, removed: true)
        }
        if existing == nil { order.append(pair) }
        rows[pair] = next
        bumpLocked(ctx)
        let isConfirmed = !next.removed && next.origin.isConfirmed
        return (next, wasConfirmed != isConfirmed)
    }

    private func memberRow(_ ctx: UUID, _ action: UUID) -> ContextMember {
        let pair = Pair(context: ctx, action: action)
        let row = rows[pair]!
        if rowIDs[pair] == nil { rowIDs[pair] = rowIDs.count + 1 }
        return ContextMember(
            id: ContextFx.id(rowIDs[pair]!, prefix: "d1e50000"), contextID: ctx, actionID: action,
            origin: row.origin, confidence: row.confidence, isRemoved: row.removed
        )
    }

    // MARK: 읽기 (RLS)

    func workContexts() async throws -> [WorkContext] {
        lock.withLock { _calls.append(.contexts) }
        if let failure = lock.withLock({ _readFailure }) { throw failure }
        return lock.withLock { _contexts.values.sorted { $0.name < $1.name } }
    }

    func contextMembers() async throws -> [ContextMember] {
        lock.withLock { _calls.append(.members) }
        if let failure = lock.withLock({ _readFailure }) { throw failure }
        let snapshot = lock.withLock { () -> [ContextMember] in
            order.filter { rows[$0]?.removed == false && _contexts[$0.context] != nil }.map { memberRow($0.context, $0.action) }
        }
        if let hold = lock.withLock({ _readHold }) { await hold.wait() }
        return snapshot
    }

    // MARK: 쓰기 (조건부)

    private func gate() throws {
        if lock.withLock({ _gateOff }) { throw APIError.server(status: 404, code: .notFound, message: APIError.featureOffMessage) }
    }

    private func conflict() -> APIError { .server(status: 409, code: .conflict, message: "그 사이 범위가 바뀌었습니다. 다시 불러온 뒤 시도해 주세요.") }
    private func missingContext() -> APIError { .server(status: 404, code: .notFound, message: APIError.missingContextMessage) }

    private func loseIfScripted() throws {
        let lose = lock.withLock { () -> Bool in
            if _loseNext > 0 {
                _loseNext -= 1
                return true
            }
            return false
        }
        if lose { throw APIError.transport("connection lost") }
    }

    func changeContextMember(contextID: UUID, op: ContextMemberOp, actionID: UUID, expectedVersion: Int) async throws -> ContextMemberWriteResponse {
        lock.withLock { _calls.append(.change(context: contextID, op: op, action: actionID, version: expectedVersion)) }
        if let hold = lock.withLock({ _hold }) { await hold.wait() }
        try gate()
        let response: ContextMemberWriteResponse = try lock.withLock {
            guard let context = _contexts[contextID], context.isActive else { throw missingContext() }
            guard context.contextVersion == expectedVersion else { throw conflict() }
            let (_, changed) = apply(op, ctx: contextID, action: actionID)
            let version = _contexts[contextID]?.contextVersion ?? 0
            let ref = ContextVersionRef(contextID: contextID, contextVersion: version)
            let change = changed
                ? (op == .add ? ContextChange(added: [ref]) : ContextChange(removed: [ref]))
                : ContextChange()
            return ContextMemberWriteResponse(member: memberRow(contextID, actionID), contextVersion: version, change: change)
        }
        try loseIfScripted()
        return response
    }

    func moveContextMember(
        actionID: UUID, from fromContextID: UUID, to toContextID: UUID, expectedToVersion: Int, expectedFromVersion: Int
    ) async throws -> ContextMemberMoveResponse {
        lock.withLock { _calls.append(.move(action: actionID, from: fromContextID, to: toContextID, toVersion: expectedToVersion, fromVersion: expectedFromVersion)) }
        if let hold = lock.withLock({ _hold }) { await hold.wait() }
        try gate()
        let response: ContextMemberMoveResponse = try lock.withLock {
            guard let to = _contexts[toContextID], to.isActive, let from = _contexts[fromContextID], from.isActive else { throw missingContext() }
            guard to.contextVersion == expectedToVersion, from.contextVersion == expectedFromVersion else { throw conflict() }
            let (_, removedChanged) = apply(.remove, ctx: fromContextID, action: actionID)
            let (_, addedChanged) = apply(.add, ctx: toContextID, action: actionID)
            let toVersion = _contexts[toContextID]?.contextVersion ?? 0
            let fromVersion = _contexts[fromContextID]?.contextVersion ?? 0
            return ContextMemberMoveResponse(
                member: memberRow(toContextID, actionID), fromMember: memberRow(fromContextID, actionID), contextVersion: toVersion,
                fromContextVersion: fromVersion,
                change: ContextChange(
                    added: addedChanged ? [ContextVersionRef(contextID: toContextID, contextVersion: toVersion)] : [],
                    removed: removedChanged ? [ContextVersionRef(contextID: fromContextID, contextVersion: fromVersion)] : []
                )
            )
        }
        try loseIfScripted()
        return response
    }
}
