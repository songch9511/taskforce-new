#if os(macOS)
import Foundation
import Testing
@testable import TaskforceKit

/// Taskforce 세션 패널이 이 Mac의 Claude 기록 위치를 찾는 일정 (리뷰 P2): 첫 턴이 끝나기 전에는 어댑터가 아직 묶지 않았다.
/// - 못 찾으면 계속 찾는다 (간격은 1 · 2 · 4 · 8 · 15 · 30초, 30초가 상한). 이전에는 1초 간격 30번에서 영영 멈췄다
/// - 세는 것은 **패널이 보이는 동안**의 찾기뿐이다 (숨은 동안 쓴 횟수 때문에 보이기도 전에 포기하지 않는다)
/// - 마지막 일의 상태(키)가 바뀌면 처음부터 다시: 새 턴이 시작하면 어댑터가 새로 묶었을 수 있다. 찾은 위치도 그때 · 다시 보일 때 한 번 확인한다
struct LocalTranscriptLookupTests {
    /// 1초마다 한 번 묻는 패널을 흉내 낸다: `lookups`는 찾은 시각, `found`는 그 찾기의 결과 (시각 → 찾았나)
    private func run(
        seconds: ClosedRange<Int>, shown: (Int) -> Bool = { _ in true }, key: (Int) -> String? = { _ in "running" }, found: (Int) -> Bool = { _ in false },
        lookup: inout LocalTranscriptLookup, hasTarget: inout Bool
    ) -> [Int] {
        var looked: [Int] = []
        for second in seconds {
            let now = TimeInterval(second)
            guard lookup.shouldLook(now: now, shown: shown(second), hasTarget: hasTarget, key: key(second)) else { continue }
            looked.append(second)
            let result = found(second)
            lookup.record(found: result, now: now)
            hasTarget = result
        }
        return looked
    }

    @Test func aHiddenPanelNeverLooksAndNeverCounts() {
        var lookup = LocalTranscriptLookup()
        var target = false
        #expect(run(seconds: 0...300, shown: { _ in false }, lookup: &lookup, hasTarget: &target).isEmpty)
        #expect(lookup.failures == 0)
        // 보이는 순간 바로 찾는다 (숨어 있던 시간만큼 뒤로 밀리지 않는다)
        #expect(run(seconds: 301...301, lookup: &lookup, hasTarget: &target) == [301])
    }

    @Test func aMissingTargetIsLookedForAgainWithABackoffThatNeverGivesUp() {
        var lookup = LocalTranscriptLookup()
        var target = false
        let looked = run(seconds: 0...125, lookup: &lookup, hasTarget: &target)
        #expect(looked == [0, 1, 3, 7, 15, 30, 60, 90, 120], "1 · 2 · 4 · 8 · 15 · 30초, 이후 30초마다")
        #expect(LocalTranscriptLookup.delays == [1, 2, 4, 8, 15, 30])
        // 30번이 넘어도 포기하지 않는다
        var long = LocalTranscriptLookup()
        var none = false
        #expect(run(seconds: 0...3_000, lookup: &long, hasTarget: &none).count > 30)
    }

    @Test func onlyTheLooksMadeWhileShownAreCountedForTheBackoff() {
        var lookup = LocalTranscriptLookup()
        var target = false
        // 0~2초 보임(찾기 0 · 1), 3~100초 숨음, 101초에 다시 보임
        let looked = run(seconds: 0...110, shown: { $0 <= 2 || $0 >= 101 }, lookup: &lookup, hasTarget: &target)
        #expect(looked == [0, 1, 101, 105], "숨은 동안은 찾지도 세지도 않고, 보이면 밀린 때가 지났으니 바로 찾는다 (그 뒤 간격은 세 번째 실패의 4초)")
        #expect(lookup.failures == 4)
    }

    @Test func afterTheTargetIsFoundTheLookStopsUntilSomethingChanges() {
        var lookup = LocalTranscriptLookup()
        var target = false
        let looked = run(seconds: 0...200, found: { $0 >= 2 }, lookup: &lookup, hasTarget: &target)
        #expect(looked == [0, 1, 3], "0 · 1초에 못 찾고 3초에 찾는다: 그 뒤로는 묻지 않는다")
        #expect(target && lookup.failures == 0)
    }

    @Test func aChangeOfTheLastTaskStateChecksTheTargetOnceAndRestartsTheLookIfItIsGone() {
        var lookup = LocalTranscriptLookup()
        var target = false
        // 0초에 찾는다. 50초에 새 턴(상태가 바뀐다): 한 번 더 확인해 같은 값을 찾는다. 120초에 또 바뀌는데 그때는 기록이 사라졌다
        let state: (Int) -> String = { $0 < 50 ? "finished" : ($0 < 120 ? "running" : "finished-again") }
        let looked = run(seconds: 0...400, key: state, found: { $0 < 120 }, lookup: &lookup, hasTarget: &target)
        #expect(looked.prefix(3) == [0, 50, 120], "찾음 → 상태가 바뀐 50초에 확인 → 120초에 확인(없다)")
        #expect(!target)
        #expect(Array(looked.dropFirst(3).prefix(3)) == [121, 123, 127], "없어졌으면 처음부터: 1 · 2 · 4초 뒤에 다시")
    }

    @Test func aKeyChangeWhileWaitingOnALongBackoffLooksAtOnceAndStartsTheBackoffOver() {
        var lookup = LocalTranscriptLookup()
        var target = false
        let looked = run(seconds: 0...100, key: { $0 < 40 ? "running" : "finished" }, lookup: &lookup, hasTarget: &target)
        #expect(looked == [0, 1, 3, 7, 15, 30, 40, 41, 43, 47, 55, 70, 100], "30초 간격 중에도 상태가 바뀐 40초에 바로 찾고, 간격은 처음(1초)부터")
    }

    @Test func aTargetThatIsHiddenAndShownAgainIsCheckedOnce() {
        var lookup = LocalTranscriptLookup()
        var target = false
        let looked = run(seconds: 0...200, shown: { $0 < 10 || $0 >= 100 }, found: { _ in true }, lookup: &lookup, hasTarget: &target)
        #expect(looked == [0, 100], "숨었다 다시 보이면 위치를 한 번 확인한다")
    }

    @Test func theKeyNilAndAKeyThatNeverChangesBehaveTheSame() {
        var lookup = LocalTranscriptLookup()
        var target = false
        #expect(run(seconds: 0...20, key: { _ in nil }, found: { $0 >= 3 }, lookup: &lookup, hasTarget: &target) == [0, 1, 3])
    }
}
#endif
