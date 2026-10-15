import Foundation
import Testing
@testable import TaskforceKit

/// 이슈 번호 읽기 (U2-33): v1 응답은 동결이라 `actions.number`를 RLS로 읽는다. 번호가 없으면 그 자리를 비운다 (지어내지 않는다)
final class FakeIssueNumberGateway: IssueNumberGateway, @unchecked Sendable {
    struct Failure: Error {}

    private let lock = NSLock()
    private var _calls: [[UUID]] = []
    private var _numbers: [UUID: Int] = [:]
    private var _failure: Error?
    private var _hold: Latch?

    var calls: [[UUID]] { lock.withLock { _calls } }
    func serve(_ numbers: [UUID: Int]) { lock.withLock { _numbers = numbers } }
    func fail(_ error: Error?) { lock.withLock { _failure = error } }
    func hold(_ latch: Latch?) { lock.withLock { _hold = latch } }

    func actionNumbers(ids: [UUID]) async throws -> [UUID: Int] {
        let (numbers, failure, latch) = lock.withLock { () -> ([UUID: Int], Error?, Latch?) in
            _calls.append(ids)
            return (_numbers, _failure, _hold)
        }
        if let latch { await latch.wait() }
        if let failure { throw failure }
        return numbers.filter { ids.contains($0.key) }
    }
}

@MainActor
struct IssueNumbersTests {
    private func id(_ n: Int) -> UUID { SessionFx.issue(n) }

    private func makeStore(_ gateway: FakeIssueNumberGateway, user: UUID = UUID()) -> (IssueNumberStore, AccountScope) {
        let scope = AccountScope(currentAccount: { user })
        return (IssueNumberStore(gateway: gateway, scope: scope), scope)
    }

    // MARK: 읽는 열

    @Test func theDetailReadAsksForTheNumberAndTheBatchReadAsksForIdAndNumberOnly() {
        #expect(ActionRecord.columns.hasSuffix(", number"))
        #expect(ActionRecord.columnsWithoutNumber == "id, title, scope_summary, owner, counterpart, due_date, status, needs_confirmation, confirm_reasons, started_at, last_activity_at, created_at")
        #expect(ActionRecord.columns == ActionRecord.columnsWithoutNumber + ", number")
        #expect(IssueNumberRow.columns == "id, number")
        // v1 목록 열은 그대로다 (운영 DB에 열이 없어도 옛 읽기가 깨지지 않는다)
        #expect(!ActionSummary.columns.contains("number"))
    }

    @Test func anActionRecordReadsTheNumberWhenThereIsOne() throws {
        func json(_ number: String) -> Data {
            Data("""
            {"id":"a0000000-0000-4000-8000-000000000001","title":"Rewrite pricing","scope_summary":null,"owner":"me","counterpart":null,"due_date":null,"status":"open",
             "needs_confirmation":false,"confirm_reasons":[],"started_at":null,"last_activity_at":"2026-10-14T01:00:00.000Z","created_at":"2026-10-13T01:00:00.000Z"\(number)}
            """.utf8)
        }
        let decoder = TaskforceJSON.decoder()
        #expect(try decoder.decode(ActionRecord.self, from: json(#","number":139"#)).number == 139)
        #expect(try decoder.decode(ActionRecord.self, from: json("")).number == nil, "열이 없는 DB의 응답")
        #expect(try decoder.decode(ActionRecord.self, from: json(#","number":null"#)).number == nil)
    }

    @Test func aNumberRowDecodes() throws {
        let rows = try TaskforceJSON.decoder().decode(
            [IssueNumberRow].self, from: Data(#"[{"id":"a0000000-0000-4000-8000-000000000001","number":139},{"id":"a0000000-0000-4000-8000-000000000002","number":140}]"#.utf8)
        )
        #expect(rows.map(\.number) == [139, 140])
    }

    // MARK: 저장소

    @Test func ensureReadsTheUnknownIdsInOneBatch() async {
        let gateway = FakeIssueNumberGateway()
        gateway.serve([id(1): 139, id(2): 140])
        let (store, _) = makeStore(gateway)
        await store.ensure([id(1), id(2), id(1)])
        #expect(gateway.calls.count == 1 && gateway.calls[0].count == 2 && Set(gateway.calls[0]) == [id(1), id(2)], "겹친 id는 한 번만")
        #expect(store.number(for: id(1)) == 139 && store.number(for: id(2)) == 140)
        #expect(store.number(for: id(3)) == nil)
    }

    @Test func knownIdsAreNotReadAgain() async {
        let gateway = FakeIssueNumberGateway()
        gateway.serve([id(1): 139, id(2): 140])
        let (store, _) = makeStore(gateway)
        await store.ensure([id(1)])
        await store.ensure([id(1), id(2)])
        #expect(gateway.calls.count == 2 && gateway.calls[1] == [id(2)])
        await store.ensure([id(1), id(2)])
        #expect(gateway.calls.count == 2, "다 알면 읽지 않는다")
    }

    @Test func anIdWithNoNumberIsRememberedAsMissingAndNotAskedAgain() async {
        let gateway = FakeIssueNumberGateway()
        gateway.serve([:])
        let (store, _) = makeStore(gateway)
        await store.ensure([id(1)])
        await store.ensure([id(1)])
        #expect(gateway.calls.count == 1 && store.number(for: id(1)) == nil)
    }

    @Test func aFailedReadLeavesTheNumbersEmptyAndTriesAgainNextTime() async {
        let gateway = FakeIssueNumberGateway()
        gateway.serve([id(1): 139])
        gateway.fail(FakeIssueNumberGateway.Failure())
        let (store, _) = makeStore(gateway)
        await store.ensure([id(1)])
        #expect(store.number(for: id(1)) == nil)
        gateway.fail(nil)
        await store.ensure([id(1)])
        #expect(store.number(for: id(1)) == 139)
        #expect(gateway.calls.count == 2)
    }

    @Test func anEmptyListDoesNotCallTheServer() async {
        let gateway = FakeIssueNumberGateway()
        gateway.serve([:])
        let (store, _) = makeStore(gateway)
        await store.ensure([])
        #expect(gateway.calls.isEmpty, "빈 목록은 부르지 않는다")
    }

    @Test func idsAlreadyBeingReadAreNotAskedTwice() async {
        let gateway = FakeIssueNumberGateway()
        gateway.serve([id(1): 139])
        let slow = Latch()
        gateway.hold(slow)
        let (store, _) = makeStore(gateway)
        let first = Task { await store.ensure([id(1)]) }
        #expect(await slow.waitForArrivals(1, timeout: .seconds(2)))
        gateway.hold(nil)
        await store.ensure([id(1)])
        #expect(gateway.calls.count == 1, "읽는 중인 id를 겹쳐 부르지 않는다")
        await slow.open()
        await first.value
        #expect(store.number(for: id(1)) == 139)
    }

    @Test func theAccountLeavingClearsTheNumbersAndDropsALateAnswer() async {
        let gateway = FakeIssueNumberGateway()
        gateway.serve([id(1): 139])
        let (store, scope) = makeStore(gateway)
        await store.ensure([id(1)])
        #expect(store.number(for: id(1)) == 139)
        scope.accountLeft()
        #expect(store.number(for: id(1)) == nil)
        let slow = Latch()
        gateway.hold(slow)
        let late = Task { await store.ensure([id(1)]) }
        #expect(await slow.waitForArrivals(1, timeout: .seconds(2)))
        scope.accountLeft()
        await slow.open()
        await late.value
        #expect(store.number(for: id(1)) == nil, "떠난 계정의 늦은 응답은 버린다")
    }

    // MARK: 보이는 글

    @Test func theNumberLabelIsHashAndNumber() {
        #expect(IssueNumberStore.label(139) == "#139")
        #expect(IssueNumberStore.label(nil) == nil)
    }

    @Test func aWorkItemCarriesTheNumberWhenOneIsGiven() {
        let action = ActionSummary(
            id: id(1), title: "Pricing", owner: .me, status: .open, dueDate: nil, counterpart: nil, needsConfirmation: false, confirmReasons: [],
            startedAt: nil, lastActivityAt: SessionFx.t0
        )
        let withNumber = WorkItem.list(reviews: [], open: [action], doneToday: [], numbers: [id(1): 139])
        let without = WorkItem.list(reviews: [], open: [action], doneToday: [])
        #expect(withNumber.first?.number == 139 && without.first?.number == nil)
    }
}
