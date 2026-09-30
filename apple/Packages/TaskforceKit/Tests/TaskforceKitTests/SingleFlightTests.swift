import Testing
@testable import TaskforceKit

/// 작업이 몇 번 돌았는지 세고, 테스트가 풀어 줄 때까지 붙잡아 둔다
@MainActor
private final class HeldWork {
    private(set) var runs = 0
    /// `run`을 부른 쪽 중 돌아온 수
    var returned = 0
    /// 끝났을 때 취소된 상태였던 작업 수
    private(set) var cancelledRuns = 0
    private var held: [CheckedContinuation<Void, Never>] = []

    func run() async {
        runs += 1
        await withCheckedContinuation { held.append($0) }
        if Task.isCancelled { cancelledRuns += 1 }
    }

    /// 붙잡힌 작업이 `count`개가 될 때까지 기다린다. 끝내 안 되면 조금 뒤 그만둔다 (틀렸을 때 멈추지 않고 실패하게)
    func settle(until count: Int) async {
        var tries = 0
        while held.count < count, tries < 1_000 {
            await Task.yield()
            tries += 1
        }
    }

    func releaseOldest() {
        held.removeFirst().resume()
    }

    func releaseAll() {
        for continuation in held { continuation.resume() }
        held = []
    }
}

@MainActor
struct SingleFlightTests {
    /// 도는 중에 또 부르면 새로 돌리지 않고 같은 작업의 끝을 기다린다
    @Test func overlappingCallsShareOneRun() async {
        let flight = SingleFlight()
        let work = HeldWork()
        let first = Task { await flight.run(work.run); work.returned += 1 }
        let second = Task { await flight.run(work.run); work.returned += 1 }
        await work.settle(until: 2)
        #expect(work.runs == 1)
        #expect(work.returned == 0)
        work.releaseAll()
        await first.value
        await second.value
        #expect(work.returned == 2)
    }

    /// 끝난 뒤에 부르면 다시 돈다
    @Test func callAfterFinishRunsAgain() async {
        let flight = SingleFlight()
        let work = HeldWork()
        let first = Task { await flight.run(work.run) }
        await work.settle(until: 1)
        work.releaseAll()
        await first.value
        let second = Task { await flight.run(work.run) }
        await work.settle(until: 1)
        #expect(work.runs == 2)
        work.releaseAll()
        await second.value
    }

    /// 로그아웃 · 계정 전환 뒤: 전 작업을 기다리지 않고 새로 돈다. 전 작업이 끝나도 새 작업을 잊지 않는다
    @Test func resetStartsAFreshRun() async {
        let flight = SingleFlight()
        let work = HeldWork()
        let old = Task { await flight.run(work.run) }
        await work.settle(until: 1)
        flight.reset()
        let fresh = Task { await flight.run(work.run) }
        await work.settle(until: 2)
        #expect(work.runs == 2)
        work.releaseOldest()
        await old.value
        let joiner = Task { await flight.run(work.run) }
        await work.settle(until: 2)
        #expect(work.runs == 2)
        work.releaseAll()
        await fresh.value
        await joiner.value
    }

    /// 먼저 부른 쪽이 취소돼도 작업은 끝까지 돌고, 함께 기다리던 쪽은 그 끝을 받는다
    @Test func cancelledCallerDoesNotCancelTheRun() async {
        let flight = SingleFlight()
        let work = HeldWork()
        let first = Task { await flight.run(work.run) }
        let second = Task { await flight.run(work.run) }
        await work.settle(until: 1)
        first.cancel()
        work.releaseAll()
        await second.value
        #expect(work.runs == 1)
        #expect(work.cancelledRuns == 0)
    }
}
