#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

extension ExternalSessionSuites {
    /// 레일에 오르는 데스크톱 세션의 순수 판정 (PR-D1 Kit, 계약 21.2 DR-S1b · 22장): busy → running, waiting → needsYou(approval · answer),
    /// 일하다가(busy · waiting) 쉬게 된 것을 Taskforce가 보면 done(`doneHold` 동안, 그 사이 열어 보면 바로 내림). 쉬는 것은 레일에 없다. 기억은 값으로 주고받는다
    struct ClaudeAppRailTests {
        typealias F = ExternalSessionFixture
        let a = F.uuid(0xB1)
        let b = F.uuid(0xB2)
        let c = F.uuid(0xB3)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        private func session(_ id: String, _ state: ClaudeAppSessionState, updated: TimeInterval? = nil) -> ClaudeAppSession {
            ClaudeAppSession(id: id, pid: 100, cwd: nil, procStart: nil, state: state, statusUpdatedAt: updated.map { Date(timeIntervalSince1970: $0) })
        }

        /// 한 세션 무리를 이어서 판정하는 짧은 도구 (기억을 이어 받는다)
        private struct Walk {
            var memory = ClaudeAppRailMemory()
            let t0: Date
            mutating func step(_ sessions: [ClaudeAppSession], at seconds: TimeInterval, opened: Set<String> = []) -> [ClaudeAppRailEntry] {
                let result = ClaudeAppRail.evaluate(sessions: sessions, memory: memory, now: t0.addingTimeInterval(seconds), opened: opened)
                memory = result.memory
                return result.entries
            }
        }

        private func kinds(_ entries: [ClaudeAppRailEntry]) -> [String: ClaudeAppRailEntry.Kind] { Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.kind) }) }

        @Test func theDoneHoldIsTheSameThreeSecondsAsOtherSessionRings() {
            #expect(ClaudeAppRail.doneHold == 3)
            #expect(ClaudeAppRail.doneHold == AgentSessionRules.doneHold)
        }

        // MARK: 레일에 오르는 것

        @Test func aSessionThatIsIdleFromTheStartIsNeverOnTheRail() {
            var walk = Walk(t0: t0)
            for second: TimeInterval in [0, 1, 2, 10, 100] { #expect(walk.step([session(a, .idle)], at: second).isEmpty, "\(second)") }
            #expect(walk.memory == ClaudeAppRailMemory(), "아무것도 기억할 것이 없다")
        }

        @Test func busyIsRunningAndWaitingIsNeedsYouWithItsKind() {
            var walk = Walk(t0: t0)
            let entries = walk.step(
                [session(a, .busy, updated: 1_799_999_990), session(b, .waiting(.approval), updated: 1_799_999_995), session(c, .waiting(.answer), updated: 1_799_999_999)], at: 0
            )
            #expect(kinds(entries) == [a: .running, b: .needsYou(.approval), c: .needsYou(.answer)])
            #expect(entries.first { $0.id == a }?.since == Date(timeIntervalSince1970: 1_799_999_990))
        }

        @Test func anUnknownStateIsNotOnTheRail() {
            var walk = Walk(t0: t0)
            #expect(walk.step([session(a, .unknown)], at: 0).isEmpty)
        }

        // MARK: done

        @Test func busyThenIdleIsDoneForTheHoldAndThenGoneForGood() {
            var walk = Walk(t0: t0)
            #expect(kinds(walk.step([session(a, .busy)], at: 0)) == [a: .running])
            #expect(kinds(walk.step([session(a, .busy)], at: 10)) == [a: .running])
            let done = walk.step([session(a, .idle)], at: 11)
            #expect(kinds(done) == [a: .done])
            #expect(done.first?.since == t0.addingTimeInterval(11), "본 때부터 센다")
            #expect(kinds(walk.step([session(a, .idle)], at: 12)) == [a: .done])
            #expect(kinds(walk.step([session(a, .idle)], at: 13.9)) == [a: .done], "3초가 되기 전")
            #expect(walk.step([session(a, .idle)], at: 14).isEmpty, "3초가 되면 내린다")
            for second: TimeInterval in [15, 20, 1000] { #expect(walk.step([session(a, .idle)], at: second).isEmpty, "\(second)") }
            #expect(walk.memory == ClaudeAppRailMemory(), "내린 것은 기억에서도 지운다")
        }

        @Test func waitingThenIdleIsDoneToo() {
            var walk = Walk(t0: t0)
            _ = walk.step([session(a, .waiting(.approval))], at: 0)
            #expect(kinds(walk.step([session(a, .idle)], at: 1)) == [a: .done])
        }

        @Test func openingItWhileItIsDoneTakesTheDoneDownAtOnceAndItDoesNotComeBack() {
            var walk = Walk(t0: t0)
            _ = walk.step([session(a, .busy)], at: 0)
            #expect(kinds(walk.step([session(a, .idle)], at: 1)) == [a: .done])
            #expect(walk.step([session(a, .idle)], at: 1.5, opened: [a]).isEmpty, "열어 보면 내린다")
            #expect(walk.step([session(a, .idle)], at: 1.6).isEmpty, "열었던 세션의 done은 다시 오르지 않는다")
        }

        @Test func aSessionThatIsOpenWhileItFinishesNeverShowsDone() {
            var walk = Walk(t0: t0)
            _ = walk.step([session(a, .busy)], at: 0, opened: [a])
            #expect(walk.step([session(a, .idle)], at: 5, opened: [a]).isEmpty, "보고 있던 세션이 끝난 것은 알릴 일이 아니다")
            #expect(walk.step([session(a, .idle)], at: 6).isEmpty)
            // 다른 세션이 열려 있다고 이 세션의 done이 사라지지 않는다
            _ = walk.step([session(a, .busy), session(b, .busy)], at: 10)
            #expect(kinds(walk.step([session(a, .idle), session(b, .busy)], at: 11, opened: [b])) == [a: .done, b: .running])
        }

        @Test func runningAgainDuringDoneReplacesItAndTheNextFinishIsDoneAgain() {
            var walk = Walk(t0: t0)
            _ = walk.step([session(a, .busy)], at: 0)
            #expect(kinds(walk.step([session(a, .idle)], at: 1)) == [a: .done])
            #expect(kinds(walk.step([session(a, .busy)], at: 2)) == [a: .running])
            let again = walk.step([session(a, .idle)], at: 20)
            #expect(kinds(again) == [a: .done])
            #expect(again.first?.since == t0.addingTimeInterval(20), "새 done은 새 시각부터")
        }

        @Test func aGlitchOfUnknownBetweenBusyAndIdleDoesNotLoseTheDone() {
            var walk = Walk(t0: t0)
            _ = walk.step([session(a, .busy)], at: 0)
            #expect(walk.step([session(a, .unknown)], at: 1).isEmpty)
            #expect(kinds(walk.step([session(a, .idle)], at: 2)) == [a: .done])
        }

        // MARK: 프로세스가 끝남

        @Test func aSessionWhoseProcessEndsIsTakenDownAndLeavesNothingBehind() {
            var walk = Walk(t0: t0)
            _ = walk.step([session(a, .busy), session(b, .busy)], at: 0)
            #expect(kinds(walk.step([session(b, .busy)], at: 1)) == [b: .running], "끝난 세션은 done도 없이 내린다")
            #expect(walk.memory.active == [b], "끝난 세션의 기억을 지운다")
            // 같은 id가 다시 쉬는 모습으로 나타나도 지난 일로 done이 되지 않는다
            #expect(walk.step([session(a, .idle), session(b, .busy)], at: 2).filter { $0.id == a }.isEmpty)
        }

        @Test func aDoneEntryIsTakenDownWhenItsProcessEnds() {
            var walk = Walk(t0: t0)
            _ = walk.step([session(a, .busy)], at: 0)
            #expect(kinds(walk.step([session(a, .idle)], at: 1)) == [a: .done])
            #expect(walk.step([], at: 2).isEmpty)
            #expect(walk.memory == ClaudeAppRailMemory())
        }

        // MARK: 순서 · 순수함

        @Test func entriesAreNeedsYouThenRunningThenDoneAndNewerFirstInsideAGroup() {
            var walk = Walk(t0: t0)
            let ids = (0..<6).map { F.uuid(0xC0 + $0) }
            _ = walk.step([session(ids[5], .busy)], at: 0)
            let entries = walk.step(
                [
                    session(ids[0], .busy, updated: 1_799_999_000), session(ids[1], .busy, updated: 1_799_999_500), session(ids[2], .waiting(.answer), updated: 1_799_999_100),
                    session(ids[3], .waiting(.approval), updated: 1_799_999_200), session(ids[4], .idle), session(ids[5], .idle),
                ], at: 1
            )
            #expect(entries.map(\.id) == [ids[3], ids[2], ids[1], ids[0], ids[5]], "needs-you(새것 먼저) → running(새것 먼저) → done")
        }

        @Test func sessionsWithoutATimeAreOrderedByIDSoTheOrderIsStable() {
            var walk = Walk(t0: t0)
            let first = walk.step([session(c, .busy), session(a, .busy), session(b, .busy)], at: 0)
            #expect(first.map(\.id) == [a, b, c])
            #expect(walk.step([session(b, .busy), session(c, .busy), session(a, .busy)], at: 1).map(\.id) == [a, b, c])
        }

        @Test func theSameInputGivesTheSameResultAndTheCallersMemoryIsNotChanged() {
            let memory = ClaudeAppRailMemory()
            let sessions = [session(a, .busy), session(b, .waiting(.approval))]
            let one = ClaudeAppRail.evaluate(sessions: sessions, memory: memory, now: t0)
            let two = ClaudeAppRail.evaluate(sessions: sessions, memory: memory, now: t0)
            #expect(one == two)
            #expect(memory == ClaudeAppRailMemory())
            #expect(one.memory != memory)
        }

        @Test func aClockThatMovedBackDoesNotEraseADoneEarly() {
            var walk = Walk(t0: t0)
            _ = walk.step([session(a, .busy)], at: 100)
            #expect(kinds(walk.step([session(a, .idle)], at: 101)) == [a: .done])
            #expect(kinds(walk.step([session(a, .idle)], at: 50)) == [a: .done], "시계가 뒤로 가도 3초를 채우기 전에는 내리지 않는다")
        }

        @Test func theMemoryNeverGrowsBeyondTheSessionsThatAreThere() {
            var walk = Walk(t0: t0)
            for n in 0..<50 {
                let id = F.uuid(0x2000 + n)
                _ = walk.step([session(id, .busy)], at: Double(n * 10))
                _ = walk.step([session(id, .idle)], at: Double(n * 10 + 1))
            }
            _ = walk.step([], at: 1000)
            #expect(walk.memory == ClaudeAppRailMemory())
        }
    }
}
#endif
