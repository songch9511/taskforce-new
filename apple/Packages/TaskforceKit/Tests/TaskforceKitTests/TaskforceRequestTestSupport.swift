import Foundation
@testable import TaskforceKit

/// 계정이 로그인 중인가를 시험이 바꾼다
@MainActor
final class TaskforceTestAccount {
    var user: UUID? = UUID(uuidString: "00000000-0000-4000-8000-0000000000aa")
    /// 시험 도우미라 순환 참조를 둔다 (저장소가 시계 · 계정을 먼저 놓아도 살아 있게)
    lazy var scope = AccountScope(currentAccount: { [self] in self.user })
}

/// 손으로 돌리는 시계: 예약된 일을 쌓아 두고 `advance`로 시간을 보낸다
@MainActor
final class TaskforceManualClock {
    private struct Entry {
        let id: Int
        let due: TimeInterval
        let work: @MainActor () -> Void
    }

    private var entries: [Entry] = []
    private var counter = 0
    private(set) var now: TimeInterval = 0
    private(set) var cancelled = 0
    private(set) var scheduled: [TimeInterval] = []

    var schedule: TaskforceSchedule {
        { [self] delay, work in
            counter += 1
            let id = counter
            scheduled.append(delay)
            entries.append(Entry(id: id, due: now + delay, work: work))
            return { [self] in
                if entries.contains(where: { $0.id == id }) { cancelled += 1 }
                entries.removeAll { $0.id == id }
            }
        }
    }

    var pending: Int { entries.count }

    /// 시간을 보낸다: 그 사이 도래한 일을 순서대로 부른다
    func advance(_ seconds: TimeInterval) {
        now += seconds
        while let next = entries.filter({ $0.due <= now }).min(by: { ($0.due, $0.id) < ($1.due, $1.id) }) {
            entries.removeAll { $0.id == next.id }
            next.work()
        }
    }
}

/// 가짜 서버: 호출을 세고, 읽기 · 상세 · 해소의 대답을 시험이 정한다. 붙잡기(`hold`)로 늦게 끝나는 요청을 만든다
final class FakeTaskforceGateway: TaskforceRequestGateway, @unchecked Sendable {
    struct Resolve: Equatable {
        let leaseID: UUID
        let keep: TaskforceConflictKeep
        let conflictVersion: Int
    }

    private let lock = NSLock()
    private var _reviewCalls = 0
    private var _detailCalls = 0
    private var _resolves: [Resolve] = []
    private var _review: @Sendable (Int) async throws -> TaskforceReviewResponse
    private var _details: @Sendable ([TaskforceConflictRef]) async throws -> [UUID: TaskforceConflictDetail]
    private var _resolve: @Sendable (Resolve) async throws -> TaskforceResolveConflictResponse

    init(
        review: @escaping @Sendable (Int) async throws -> TaskforceReviewResponse,
        details: @escaping @Sendable ([TaskforceConflictRef]) async throws -> [UUID: TaskforceConflictDetail] = { _ in [:] },
        resolve: @escaping @Sendable (Resolve) async throws -> TaskforceResolveConflictResponse = { _ in .resolved }
    ) {
        _review = review
        _details = details
        _resolve = resolve
    }

    var reviewCalls: Int { lock.withLock { _reviewCalls } }
    var detailCalls: Int { lock.withLock { _detailCalls } }
    var resolves: [Resolve] { lock.withLock { _resolves } }

    func setReview(_ review: @escaping @Sendable (Int) async throws -> TaskforceReviewResponse) { lock.withLock { _review = review } }
    func setDetails(_ details: @escaping @Sendable ([TaskforceConflictRef]) async throws -> [UUID: TaskforceConflictDetail]) { lock.withLock { _details = details } }
    func setResolve(_ resolve: @escaping @Sendable (Resolve) async throws -> TaskforceResolveConflictResponse) { lock.withLock { _resolve = resolve } }

    func taskforceReview() async throws -> TaskforceReviewResponse {
        let (call, review) = lock.withLock { () -> (Int, @Sendable (Int) async throws -> TaskforceReviewResponse) in
            _reviewCalls += 1
            return (_reviewCalls, _review)
        }
        return try await review(call)
    }

    func pathConflictDetails(_ refs: [TaskforceConflictRef]) async throws -> [UUID: TaskforceConflictDetail] {
        let details = lock.withLock { () -> @Sendable ([TaskforceConflictRef]) async throws -> [UUID: TaskforceConflictDetail] in
            _detailCalls += 1
            return _details
        }
        return try await details(refs)
    }

    func resolvePathConflict(leaseID: UUID, keep: TaskforceConflictKeep, conflictVersion: Int) async throws -> TaskforceResolveConflictResponse {
        let resolve = Resolve(leaseID: leaseID, keep: keep, conflictVersion: conflictVersion)
        let handler = lock.withLock { () -> @Sendable (Resolve) async throws -> TaskforceResolveConflictResponse in
            _resolves.append(resolve)
            return _resolve
        }
        return try await handler(resolve)
    }
}

extension TaskforceResolveConflictResponse {
    static var resolved: TaskforceResolveConflictResponse {
        try! JSONDecoder().decode(TaskforceResolveConflictResponse.self, from: Data(#"{"status":"resolved"}"#.utf8))
    }
}

/// 한 번만 열리는 문: 요청을 붙잡아 두었다가 시험이 놓아 준다
final class TaskforceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let open = lock.withLock { () -> Bool in
                if opened { return true }
                self.continuation = continuation
                return false
            }
            if open { continuation.resume() }
        }
    }

    func open() {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            opened = true
            defer { continuation = nil }
            return continuation
        }
        pending?.resume()
    }
}

/// 충돌 하나가 든 응답과 그 상세 (시험의 기본 장면)
enum TaskforceStoreFx {
    typealias Fx = TaskforceRequestFixtures

    static let holderSession = Fx.session
    static let laterSession = UUID(uuidString: "5e000000-0000-4000-8000-000000000002")!

    static var response: TaskforceReviewResponse { try! Fx.decode(Fx.review) }

    /// 충돌 항목의 version · conflict_version을 바꾼 응답
    static func response(conflictVersion: Int, itemVersion: String? = nil) -> TaskforceReviewResponse {
        let base = response
        return TaskforceReviewResponse(decisions: base.decisions?.map { group in
            TaskforceDecisionGroup(key: group.key, actionID: group.actionID, kind: group.kind, items: group.items.map { item in
                guard let ref = item.conflict else { return item }
                let changed = TaskforceConflictRef(
                    leaseID: ref.leaseID, conflictVersion: conflictVersion, holderActionID: ref.holderActionID, holderRunID: ref.holderRunID,
                    laterRunID: ref.laterRunID, released: ref.released, stopped: ref.stopped
                )
                return TaskforceDecisionItem(id: item.id, kind: item.kind, actionID: item.actionID, version: itemVersion ?? "conflict:\(ref.leaseID.uuidString.lowercased()):\(conflictVersion)", conflict: changed)
            })
        })
    }

    /// 충돌 항목이 빠진 응답 (다른 기기에서 해소됨)
    static var responseWithoutTheConflict: TaskforceReviewResponse {
        TaskforceReviewResponse(decisions: response.decisions?.filter { $0.kind != .pathConflict })
    }

    static var detail: TaskforceConflictDetail {
        TaskforceConflictDetail(
            leaseID: Fx.lease, relPath: "src/content/pricing.mdx", holderRunID: Fx.run, laterRunID: Fx.run, holderSessionID: holderSession, laterSessionID: laterSession
        )
    }

    static var conflictID: String { "path_conflict:\(Fx.lease.uuidString.lowercased())" }
}
