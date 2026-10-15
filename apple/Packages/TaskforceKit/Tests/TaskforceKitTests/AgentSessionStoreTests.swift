import Foundation
import Supabase
import Testing
@testable import TaskforceKit

/// 가짜 세션 서버: 읽기 응답을 스크립트로 정하고 부른 횟수를 센다. 붙잡기 · 실패 · 다른 계정은 이 객체의 메서드로 만든다
final class FakeAgentSessionGateway: AgentSessionGateway, @unchecked Sendable {
    struct Failure: Error {}

    private let lock = NSLock()
    private var _snapshot = AgentSessionSnapshot.empty
    private var _failure: Error?
    private var _reads = 0
    private var _hold: Latch?

    var reads: Int { lock.withLock { _reads } }
    func serve(_ snapshot: AgentSessionSnapshot) { lock.withLock { _snapshot = snapshot } }
    func fail(_ error: Error?) { lock.withLock { _failure = error } }
    func hold(_ latch: Latch?) { lock.withLock { _hold = latch } }

    func agentSessionSnapshot() async throws -> AgentSessionSnapshot {
        let (snapshot, failure, latch) = lock.withLock { () -> (AgentSessionSnapshot, Error?, Latch?) in
            _reads += 1
            return (_snapshot, _failure, _hold)
        }
        if let latch { await latch.wait() }
        if let failure { throw failure }
        return snapshot
    }
}

/// 세션 저장소: 읽기 상태(읽는 중 · 받음 · 오프라인 · 실패) · 마지막에 시작한 읽기만 반영 · 계정 경계 · 방금 끝남 3초 · 5초 다시 읽기
@MainActor
struct AgentSessionStoreTests {
    typealias Fx = SessionFx

    /// 손으로 돌리는 시계 · 잠들기: 스케줄한 지연을 `fire()`로 부른다
    final class ManualSleeper: @unchecked Sendable {
        private let lock = NSLock()
        private var waiters: [(delay: TimeInterval, continuation: CheckedContinuation<Void, Never>)] = []
        private var _now = Fx.t0

        var now: Date { lock.withLock { _now } }
        func advance(_ seconds: TimeInterval) { lock.withLock { _now = _now.addingTimeInterval(seconds) } }
        var pendingDelays: [TimeInterval] { lock.withLock { waiters.map(\.delay) } }

        func sleep(_ delay: TimeInterval) async {
            await withCheckedContinuation { continuation in lock.withLock { waiters.append((delay, continuation)) } }
        }

        /// 가장 먼저 기다린 것을 깨운다 (시계도 그만큼 간다)
        func fire() {
            let next = lock.withLock { () -> (TimeInterval, CheckedContinuation<Void, Never>)? in
                guard !waiters.isEmpty else { return nil }
                let first = waiters.removeFirst()
                _now = _now.addingTimeInterval(first.delay)
                return (first.delay, first.continuation)
            }
            next?.1.resume()
        }
    }

    private func makeStore(
        _ gateway: FakeAgentSessionGateway, user: UUID = UUID(), sleeper: ManualSleeper = ManualSleeper()
    ) -> (AgentSessionStore, AccountScope, ManualSleeper) {
        let scope = AccountScope(currentAccount: { user })
        let store = AgentSessionStore(gateway: gateway, scope: scope, now: { sleeper.now }, sleep: { await sleeper.sleep($0) })
        return (store, scope, sleeper)
    }

    /// 조건이 설 때까지 기다린다 (양보 횟수로 짐작하지 않는다). 안전망 2초
    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    /// 아무 일도 일어나지 않았음을 보려고 잠깐 기다린다
    private func quiet() async {
        try? await Task.sleep(for: .milliseconds(60))
    }

    // MARK: 읽기 상태

    @Test func beforeTheFirstReadNothingIsClaimed() {
        let (store, _, _) = makeStore(FakeAgentSessionGateway())
        #expect(store.load == .loading && store.items.isEmpty && !store.hasRead)
    }

    @Test func aReadFillsTheItems() async {
        let gateway = FakeAgentSessionGateway()
        gateway.serve(Fx.snapshot(state: .running, name: "Pricing copy draft"))
        let (store, _, _) = makeStore(gateway)
        await store.refresh()
        #expect(store.load == .loaded(problem: nil) && store.hasRead)
        #expect(store.items.map(\.name) == ["Pricing copy draft"] && store.items[0].ring == .running)
    }

    @Test func aFailureBeforeAnyReadIsFailedAndAfterOneItKeepsTheItems() async {
        let gateway = FakeAgentSessionGateway()
        gateway.fail(FakeAgentSessionGateway.Failure())
        let (store, _, _) = makeStore(gateway)
        await store.refresh()
        #expect(store.load == .failed && store.items.isEmpty)
        gateway.fail(nil)
        gateway.serve(Fx.snapshot(state: .running))
        await store.refresh()
        gateway.fail(FakeAgentSessionGateway.Failure())
        await store.refresh()
        #expect(store.load == .loaded(problem: .failed) && store.items.count == 1, "받은 것은 실패해도 그대로 둔다")
    }

    @Test func offlineIsSaidAsOfflineBeforeAnyReadAndAsAProblemAfter() async {
        let gateway = FakeAgentSessionGateway()
        gateway.fail(URLError(.notConnectedToInternet))
        let (store, _, _) = makeStore(gateway)
        await store.refresh()
        #expect(store.load == .offline)
        gateway.fail(nil)
        gateway.serve(Fx.snapshot(state: .idle))
        await store.refresh()
        store.pathChanged(online: false)
        gateway.fail(URLError(.notConnectedToInternet))
        await store.refresh()
        #expect(store.load == .loaded(problem: .offline))
    }

    @Test func aMissingTableIsNotAFailureButNoSessions() async {
        let gateway = FakeAgentSessionGateway()
        gateway.fail(PostgrestError(code: "PGRST205", message: "Could not find the table 'public.agent_sessions'"))
        let (store, _, _) = makeStore(gateway)
        await store.refresh()
        #expect(store.load == .loaded(problem: nil) && store.items.isEmpty && store.readsUnavailable)
    }

    @Test func onlyTheLastStartedReadIsApplied() async {
        let gateway = FakeAgentSessionGateway()
        let slow = Latch()
        gateway.serve(Fx.snapshot(state: .running, name: "Old"))
        gateway.hold(slow)
        let (store, _, _) = makeStore(gateway)
        let first = Task { await store.refresh() }
        #expect(await slow.waitForArrivals(1, timeout: .seconds(2)))
        gateway.hold(nil)
        gateway.serve(Fx.snapshot(state: .idle, name: "New"))
        await store.refresh()
        #expect(store.items.map(\.name) == ["New"])
        await slow.open()
        await first.value
        #expect(store.items.map(\.name) == ["New"], "늦게 끝난 옛 읽기가 새 상태를 되돌리지 않는다")
    }

    // MARK: 계정 경계

    @Test func theAccountLeavingClearsEverythingAndDropsALateRead() async {
        let gateway = FakeAgentSessionGateway()
        gateway.serve(Fx.snapshot(state: .running))
        let (store, scope, _) = makeStore(gateway)
        await store.refresh()
        #expect(store.items.count == 1)
        let slow = Latch()
        gateway.hold(slow)
        let late = Task { await store.refresh() }
        #expect(await slow.waitForArrivals(1, timeout: .seconds(2)))
        scope.accountLeft()
        #expect(store.items.isEmpty && store.load == .loading && !store.hasRead)
        await slow.open()
        await late.value
        #expect(store.items.isEmpty && !store.hasRead, "떠난 계정의 늦은 응답은 버린다")
    }

    /// 계정이 바뀌었는데 떠남 알림이 오지 않은 경우에도 (같은 세대에서 사용자만 달라짐) 옛 계정의 읽기는 버린다
    @Test func aReadStartedForAnotherUserIsDroppedEvenWithoutALeaveNotice() async {
        final class Box: @unchecked Sendable { var user = UUID() }
        let box = Box()
        let gateway = FakeAgentSessionGateway()
        gateway.serve(Fx.snapshot(state: .running))
        let slow = Latch()
        gateway.hold(slow)
        let scope = AccountScope(currentAccount: { box.user })
        let store = AgentSessionStore(gateway: gateway, scope: scope)
        let late = Task { await store.refresh() }
        #expect(await slow.waitForArrivals(1, timeout: .seconds(2)))
        box.user = UUID()
        await slow.open()
        await late.value
        #expect(store.items.isEmpty && !store.hasRead)
    }

    // MARK: 방금 끝남 3초

    @Test func completedIsDoneForThreeSecondsOnlyWhenItWasSeenChanging() async {
        let gateway = FakeAgentSessionGateway()
        gateway.serve(Fx.snapshot(state: .running))
        let (store, _, sleeper) = makeStore(gateway)
        await store.refresh()
        gateway.serve(Fx.snapshot(state: .completed))
        await store.refresh()
        #expect(store.items[0].ring == .done && store.items[0].line == "Done just now")
        sleeper.advance(2.9)
        store.rebuild()
        #expect(store.items[0].ring == .done)
        sleeper.advance(0.2)
        store.rebuild()
        #expect(store.items[0].ring == .idle)
    }

    @Test func aTaskThatWasAlreadyCompletedAtTheFirstReadIsNotDone() async {
        let gateway = FakeAgentSessionGateway()
        gateway.serve(Fx.snapshot(state: .completed))
        let (store, _, _) = makeStore(gateway)
        await store.refresh()
        #expect(store.items[0].ring == .idle)
        await store.refresh()
        #expect(store.items[0].ring == .idle, "다시 읽어도 같은 완료는 방금 끝난 것이 아니다")
    }

    @Test func aNewTurnThatCompletesIsDoneAgain() async {
        let gateway = FakeAgentSessionGateway()
        gateway.serve(Fx.snapshot(state: .completed))
        let (store, _, sleeper) = makeStore(gateway)
        await store.refresh()
        var next = Fx.snapshot(state: .running)
        next.sessions[0] = Fx.session(1, turn: 2)
        next.tasks = [Fx.task(1, state: .running, turn: 2)]
        gateway.serve(next)
        await store.refresh()
        sleeper.advance(10)
        next.tasks = [Fx.task(1, state: .completed, turn: 2)]
        gateway.serve(next)
        await store.refresh()
        #expect(store.items[0].ring == .done)
    }

    // MARK: 5초 다시 읽기

    @Test func anOpenTaskKeepsRereadingEveryFiveSeconds() async {
        let gateway = FakeAgentSessionGateway()
        gateway.serve(Fx.snapshot(state: .running))
        let (store, _, sleeper) = makeStore(gateway)
        await store.refresh()
        #expect(await eventually { sleeper.pendingDelays == [5] })
        sleeper.fire()
        #expect(await eventually { gateway.reads == 2 })
        #expect(await eventually { sleeper.pendingDelays == [5] }, "다음 읽기가 다시 5초를 건다")
    }

    @Test func rereadingStopsWhenNoTaskIsOpenOrTheAppSleeps() async {
        let gateway = FakeAgentSessionGateway()
        gateway.serve(Fx.snapshot(state: .running))
        let (store, _, sleeper) = makeStore(gateway)
        await store.refresh()
        #expect(await eventually { sleeper.pendingDelays == [5] })
        store.setAsleep(true)
        sleeper.fire()
        await quiet()
        #expect(gateway.reads == 1, "잠자는 동안 멈춘다")
        #expect(sleeper.pendingDelays.isEmpty)
        gateway.serve(Fx.snapshot(state: .idle))
        store.setAsleep(false)
        #expect(await eventually { gateway.reads == 2 }, "깨면 한 번 읽는다")
        await quiet()
        #expect(sleeper.pendingDelays.isEmpty, "열린 task가 없으면 더 걸지 않는다")
    }

    @Test func comingBackOnlineReadsOnce() async {
        let gateway = FakeAgentSessionGateway()
        gateway.serve(Fx.snapshot(state: .idle))
        let (store, _, _) = makeStore(gateway)
        await store.refresh()
        store.pathChanged(online: false)
        store.pathChanged(online: true)
        #expect(await eventually { gateway.reads == 2 })
        store.pathChanged(online: true)
        await quiet()
        #expect(gateway.reads == 2, "이미 온라인이면 다시 읽지 않는다")
    }

    // MARK: 도우미

    @Test func theItemsOfAnIssueAndTheirRingComeFromTheStore() async {
        let gateway = FakeAgentSessionGateway()
        gateway.serve(Fx.snapshot(state: .awaitingAnswer))
        let (store, _, _) = makeStore(gateway)
        await store.refresh()
        #expect(store.sessions(of: [Fx.issue(1)]).count == 1)
        #expect(store.sessions(of: [Fx.issue(2)]).isEmpty)
        #expect(store.ring(of: Fx.issue(1), v1: nil) == .needsYou)
        #expect(store.ring(of: Fx.issue(2), v1: .running) == .running)
    }
}
