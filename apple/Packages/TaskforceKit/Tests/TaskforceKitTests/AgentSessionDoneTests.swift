import Foundation
import Testing
@testable import TaskforceKit

/// 끝난 세션 링은 사용자가 열어 볼 때까지 남는다 (OA PR-D2, 계약 23장): 3초 뒤 내리던 `doneHold`를 "열 때까지"로 바꾼다.
/// 열어 보면 내리고 · 새 턴이 오면 새 상태가 대신하고 · 열기 기록(아직 안 연 끝남)은 이 Mac에 저장해 다시 켠 뒤에도 남는다.
/// `done` 저장소를 주지 않은 저장소(Assistant 창의 좁은 저장소)는 지금처럼 3초다 (`AgentSessionStoreTests`가 지킨다)
@MainActor
struct AgentSessionDoneTests {
    typealias Fx = SessionFx

    /// 잠들기를 부르면 영영 안 깬다: 5초 읽기 · 만료 예약이 시험 안에서 저절로 도는 일이 없다 (시험이 `refresh()`를 직접 부른다)
    private static let sleepForever: @Sendable (TimeInterval) async -> Void = { _ in try? await Task.sleep(for: .seconds(3600)) }

    private func makeStore(
        _ gateway: FakeAgentSessionGateway, done: InMemoryRailDoneStore = InMemoryRailDoneStore(), user: UUID = UUID(), clock: TestClock = TestClock()
    ) -> (AgentSessionStore, AccountScope, TestClock) {
        let scope = AccountScope(currentAccount: { user })
        let store = AgentSessionStore(gateway: gateway, scope: scope, now: { clock.now }, sleep: Self.sleepForever, done: done)
        return (store, scope, clock)
    }

    final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Fx.t0
        var now: Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
    }

    /// 한 세션이 끝난 것을 본 상태까지 만든다 (running → completed)
    private func finish(_ store: AgentSessionStore, _ gateway: FakeAgentSessionGateway) async {
        gateway.serve(Fx.snapshot(state: .running))
        await store.refresh()
        gateway.serve(Fx.snapshot(state: .completed))
        await store.refresh()
    }

    // MARK: 열 때까지 남는다

    @Test func aCompletionStaysDoneForAsLongAsItTakesUntilTheUserOpensIt() async {
        let gateway = FakeAgentSessionGateway()
        let (store, _, clock) = makeStore(gateway)
        await finish(store, gateway)
        #expect(store.items[0].ring == .done && store.items[0].line == AgentSessionRules.done)
        for seconds: TimeInterval in [2.9, 3.1, 60, 3600, 86_400, 30 * 86_400] {
            clock.advance(seconds)
            store.rebuild()
            await store.refresh()
            #expect(store.items[0].ring == .done, "\(seconds)초 뒤에도 그대로: 타이머가 없다")
        }
    }

    @Test func theLineSaysDoneNotDoneJustNow() async {
        #expect(AgentSessionRules.done == "Done")
        let gateway = FakeAgentSessionGateway()
        let (store, _, _) = makeStore(gateway)
        await finish(store, gateway)
        #expect(store.items[0].line == "Done", "링이 몇 시간 남으니 \"just now\"는 거짓이다 (DZ RL3)")
    }

    @Test func openingTheSessionTakesTheDoneDownAndItDoesNotComeBack() async {
        let gateway = FakeAgentSessionGateway()
        let (store, _, _) = makeStore(gateway)
        await finish(store, gateway)
        store.markOpened(Fx.id(1))
        #expect(store.items[0].ring == .idle && store.items[0].line == "Idle", "그 자리에서 내린다 (다음 읽기를 기다리지 않는다)")
        await store.refresh()
        await store.refresh()
        #expect(store.items[0].ring == .idle, "다시 읽어도 같은 완료는 다시 오르지 않는다")
    }

    @Test func aNewTurnReplacesTheDoneAndItsCompletionIsDoneAgain() async {
        let gateway = FakeAgentSessionGateway()
        let (store, _, _) = makeStore(gateway)
        await finish(store, gateway)
        var next = Fx.snapshot(state: .running)
        next.sessions[0] = Fx.session(1, turn: 2)
        next.tasks = [Fx.task(1, state: .running, turn: 2)]
        gateway.serve(next)
        await store.refresh()
        #expect(store.items[0].ring == .running, "새 턴이 오면 done을 running이 대신한다")
        next.tasks = [Fx.task(1, state: .completed, turn: 2)]
        gateway.serve(next)
        await store.refresh()
        #expect(store.items[0].ring == .done, "새 턴의 끝도 열어 보기 전까지 남는다")
    }

    @Test func aCompletionThatWasAlreadyThereAtTheFirstReadIsNotDone() async {
        let gateway = FakeAgentSessionGateway()
        gateway.serve(Fx.snapshot(state: .completed))
        let (store, _, _) = makeStore(gateway)
        await store.refresh()
        await store.refresh()
        #expect(store.items[0].ring == .idle, "처음 읽을 때 이미 끝나 있던 것은 방금 끝난 것이 아니다 (표시도 없다)")
    }

    @Test func aSessionThatStopsBeingCompletedLosesItsMarkAndAClosedOneShowsNothing() async {
        let gateway = FakeAgentSessionGateway()
        let done = InMemoryRailDoneStore()
        let (store, _, _) = makeStore(gateway, done: done)
        await finish(store, gateway)
        #expect(done.load().sessions.keys.contains(Fx.id(1)))
        gateway.serve(Fx.snapshot(state: .idle))
        await store.refresh()
        #expect(store.items[0].ring == .idle && done.load().sessions.isEmpty, "더는 completed가 아니면 표시를 지운다")
        gateway.serve(Fx.snapshot(state: .running))
        await store.refresh()
        gateway.serve(Fx.snapshot(status: .closed, state: .completed))
        await store.refresh()
        #expect(store.items[0].ring == nil, "닫힌 세션은 링이 없다 (표시가 있어도 링 · 말을 만들지 않는다)")
    }

    @Test func aMarkOfASessionThatIsNoLongerThereIsDropped() async {
        let gateway = FakeAgentSessionGateway()
        let done = InMemoryRailDoneStore()
        done.save(RailDoneMarks(sessions: [Fx.id(1): Fx.t0, Fx.id(9): Fx.t0], issues: [Fx.issue(1): Fx.t0]))
        gateway.serve(Fx.snapshot(state: .completed))
        let (store, _, _) = makeStore(gateway, done: done)
        await store.refresh()
        #expect(store.items[0].ring == .done, "저장해 둔 표시가 있고 지금도 completed이면 done이다")
        #expect(done.load().sessions.keys.sorted { $0.uuidString < $1.uuidString } == [Fx.id(1)], "읽은 세션에 없는 표시는 지운다")
        #expect(done.load().issues == [Fx.issue(1): Fx.t0], "이슈 칸은 세션 저장소가 만지지 않는다")
    }

    // MARK: 다시 켠 뒤에도 남는다 · 열어 본 것은 남지 않는다

    @Test func aRelaunchKeepsTheUnopenedDoneAndForgetsTheOpenedOne() async {
        let done = InMemoryRailDoneStore()
        let gateway = FakeAgentSessionGateway()
        do {
            let (store, _, _) = makeStore(gateway, done: done)
            await finish(store, gateway)
            #expect(store.items[0].ring == .done)
        }
        // 앱을 다시 켰다: 새 저장소가 같은 저장본을 읽는다. 첫 읽기에서 세션은 이미 completed다
        gateway.serve(Fx.snapshot(state: .completed))
        let (again, _, _) = makeStore(gateway, done: done)
        #expect(again.items.isEmpty)
        await again.refresh()
        #expect(again.items[0].ring == .done && again.items[0].line == "Done", "열어 보지 않은 끝남은 다시 켠 뒤에도 초록이다")
        again.markOpened(Fx.id(1))
        #expect(done.load().sessions.isEmpty, "연 기록이 저장된다")
        let (third, _, _) = makeStore(gateway, done: done)
        await third.refresh()
        #expect(third.items[0].ring == .idle, "열어 본 것은 다시 켜도 남지 않는다")
    }

    @Test func aNewCompletionWhileTheAppWasOffReplacesTheOldMark() async {
        let done = InMemoryRailDoneStore()
        done.save(RailDoneMarks(sessions: [Fx.id(1): Fx.t0]))
        let gateway = FakeAgentSessionGateway()
        var next = Fx.snapshot(state: .completed)
        next.sessions[0] = Fx.session(1, turn: 3)
        next.tasks = [Fx.task(1, state: .completed, turn: 3)]
        gateway.serve(next)
        let (store, _, _) = makeStore(gateway, done: done)
        await store.refresh()
        #expect(store.items[0].ring == .done, "표시가 있고 지금도 끝나 있으면 (더 새 턴이어도) 열어 보기 전까지 done이다")
    }

    @Test func leavingTheAccountClearsWhatWasSaved() async {
        let done = InMemoryRailDoneStore()
        let gateway = FakeAgentSessionGateway()
        let box = UserBox()
        let scope = AccountScope(currentAccount: { box.user })
        let store = AgentSessionStore(gateway: gateway, scope: scope, sleep: Self.sleepForever, done: done)
        await finish(store, gateway)
        done.update { $0.issues[Fx.issue(1)] = Fx.t0 }
        #expect(!done.load().sessions.isEmpty)
        box.user = UUID()
        scope.accountLeft()
        #expect(done.load() == RailDoneMarks(), "다른 계정에 옛 계정의 표시를 남기지 않는다")
        #expect(store.items.isEmpty)
    }

    final class UserBox: @unchecked Sendable {
        var user = UUID()
    }

    // MARK: 지금과 같은 것

    @Test func withoutADoneStoreTheThreeSecondHoldIsUnchanged() async {
        let gateway = FakeAgentSessionGateway()
        let clock = TestClock()
        let user = UUID()
        let store = AgentSessionStore(gateway: gateway, scope: AccountScope(currentAccount: { user }), now: { clock.now }, sleep: Self.sleepForever)
        await finish(store, gateway)
        #expect(store.items[0].ring == .done && store.items[0].line == AgentSessionRules.doneJustNow)
        clock.advance(3.1)
        store.rebuild()
        #expect(store.items[0].ring == .idle, "저장소를 주지 않으면 지금처럼 3초 뒤 내린다")
        store.markOpened(Fx.id(1))
        #expect(store.items[0].ring == .idle)
    }

    /// 셸 컨트롤러가 실제 앱 경로에서 이미 만들어진 U2 저장소를 "열 때까지"로 올린다 (저장소는 `ChatRuntime`이 만든다)
    @Test func aStoreCanBeUpgradedToUntilOpenedAfterItWasCreatedAndLoadsWhatWasSaved() async {
        let gateway = FakeAgentSessionGateway()
        let clock = TestClock()
        let user = UUID()
        let store = AgentSessionStore(gateway: gateway, scope: AccountScope(currentAccount: { user }), now: { clock.now }, sleep: Self.sleepForever)
        gateway.serve(Fx.snapshot(state: .completed))
        await store.refresh()
        #expect(store.items[0].ring == .idle)
        let done = InMemoryRailDoneStore()
        done.save(RailDoneMarks(sessions: [Fx.id(1): Fx.t0]))
        store.useDoneStore(done)
        #expect(store.items[0].ring == .done && store.items[0].line == "Done", "저장해 둔 표시가 있으면 그 자리에서 done이다")
        clock.advance(86_400)
        store.rebuild()
        #expect(store.items[0].ring == .done, "더는 3초가 아니다")
        store.markOpened(Fx.id(1))
        #expect(done.load().sessions.isEmpty && store.items[0].ring == .idle)
        // 이미 올린 저장소는 다시 바꾸지 않는다
        let other = InMemoryRailDoneStore()
        other.save(RailDoneMarks(sessions: [Fx.id(1): Fx.t0]))
        store.useDoneStore(other)
        #expect(store.items[0].ring == .idle, "처음 준 저장소가 그대로다")
    }

    @Test func openingAnUnknownSessionOrOneWithoutAMarkChangesNothing() async {
        let gateway = FakeAgentSessionGateway()
        let done = InMemoryRailDoneStore()
        let (store, _, _) = makeStore(gateway, done: done)
        await finish(store, gateway)
        let before = done.load()
        store.markOpened(Fx.id(77))
        store.markOpened([])
        #expect(done.load() == before && store.items[0].ring == .done)
    }

    @Test func openingSeveralSessionsAtOnceTakesDownEachOfThem() async {
        let gateway = FakeAgentSessionGateway()
        let (store, _, _) = makeStore(gateway)
        func two(_ first: AgentTaskState, _ second: AgentTaskState) -> AgentSessionSnapshot {
            AgentSessionSnapshot(
                sessions: [Fx.session(1), Fx.session(2, name: "Lifetime")], tasks: [Fx.task(1, state: first), Fx.task(2, state: second)],
                runs: [Fx.run(session: 1, action: Fx.issue(1)), Fx.run(session: 2, action: Fx.issue(1))], connections: Fx.connections, conversations: []
            )
        }
        gateway.serve(two(.running, .running))
        await store.refresh()
        gateway.serve(two(.completed, .completed))
        await store.refresh()
        #expect(store.items.map(\.ring) == [.done, .done])
        store.markOpened([Fx.id(1), Fx.id(2)])
        #expect(store.items.map(\.ring) == [.idle, .idle])
    }
}
