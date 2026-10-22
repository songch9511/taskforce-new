#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

extension ExternalSessionSuites {
    /// 레일에 오르는 데스크톱 세션의 순수 판정 (PR-D1 Kit, 계약 21.2 DR-S1b · 22장 · 23장): busy → running, waiting → needsYou(approval · answer),
    /// 일하던(busy · waiting) 세션이 쉬게 된 것을 Taskforce가 보면 done — **사용자가 열어 볼 때까지** 남는다(타이머 없음, 23장). 열어 보면 내리고, 새 턴이 오면 done이 running으로 바뀐다. 쉬는 것은 레일에 없다.
    /// 기억은 값으로 주고받고, 일하던 기억의 나이는 **단조 시간**이다 (벽시계는 done의 시각 표시에만 쓴다). 세션은 (id, pid)로 알아본다.
    /// done 표시(`doneMarks`)는 다시 켠 뒤에도 남도록 밖에 저장했다 되살릴 수 있다 (이 Mac에만, id · pid · 본 시각뿐)
    struct ClaudeAppRailTests {
        typealias F = ExternalSessionFixture
        let a = F.uuid(0xB1)
        let b = F.uuid(0xB2)
        let c = F.uuid(0xB3)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        private func session(_ id: String, _ state: ClaudeAppSessionState, pid: Int32 = 100, updated: TimeInterval? = nil) -> ClaudeAppSession {
            ClaudeAppSession(id: id, pid: pid, cwd: nil, procStart: nil, state: state, statusUpdatedAt: updated.map { Date(timeIntervalSince1970: $0) })
        }

        /// 한 세션 무리를 이어서 판정하는 짧은 도구 (기억을 이어 받는다). `seconds`는 단조 시간이 흐른 만큼, `wallShift`는 벽시계만 따로 어긋난 만큼
        private struct Walk {
            var memory = ClaudeAppRailMemory()
            let wall0: Date
            let mono0: TimeInterval = 5_000
            mutating func step(_ sessions: [ClaudeAppSession], at seconds: TimeInterval, wallShift: TimeInterval = 0, opened: Set<String> = []) -> [ClaudeAppRailEntry] {
                let result = ClaudeAppRail.evaluate(sessions: sessions, memory: memory, now: wall0.addingTimeInterval(seconds + wallShift), uptime: mono0 + seconds, opened: opened)
                memory = result.memory
                return result.entries
            }
        }

        private func kinds(_ entries: [ClaudeAppRailEntry]) -> [String: ClaudeAppRailEntry.Kind] { Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.kind) }) }

        @Test func theNumbersAreTheDocumentedOnes() {
            #expect(ClaudeAppRail.maxRestoredMarks == 64, "다시 켤 때 되살리는 done 표시는 64개까지 (저장소가 커지지 않게)")
            #expect(ClaudeAppRail.activeLimit == 30, "마지막으로 일하는 것을 본 뒤 30초가 지나면 끝난 것을 새 소식으로 치지 않는다")
            #expect(ClaudeAppRail.missingGrace == 2, "잠깐(두 번) 안 보이는 것은 기억을 지키는 틈이다")
        }

        // MARK: 레일에 오르는 것

        @Test func aSessionThatIsIdleFromTheStartIsNeverOnTheRail() {
            var walk = Walk(wall0: t0)
            for second: TimeInterval in [0, 1, 2, 10, 100] { #expect(walk.step([session(a, .idle)], at: second).isEmpty, "\(second)") }
            #expect(walk.memory == ClaudeAppRailMemory(), "아무것도 기억할 것이 없다")
        }

        @Test func busyIsRunningAndWaitingIsNeedsYouWithItsKind() {
            var walk = Walk(wall0: t0)
            let entries = walk.step(
                [session(a, .busy, updated: 1_799_999_990), session(b, .waiting(.approval), updated: 1_799_999_995), session(c, .waiting(.answer), updated: 1_799_999_999)], at: 0
            )
            #expect(kinds(entries) == [a: .running, b: .needsYou(.approval), c: .needsYou(.answer)])
            #expect(entries.first { $0.id == a }?.since == Date(timeIntervalSince1970: 1_799_999_990))
        }

        @Test func anUnknownStateIsNotOnTheRail() {
            var walk = Walk(wall0: t0)
            #expect(walk.step([session(a, .unknown)], at: 0).isEmpty)
        }

        // MARK: done

        @Test func busyThenIdleIsDoneAndStaysUntilTheUserOpensIt() {
            var walk = Walk(wall0: t0)
            #expect(kinds(walk.step([session(a, .busy)], at: 0)) == [a: .running])
            #expect(kinds(walk.step([session(a, .busy)], at: 10)) == [a: .running])
            let done = walk.step([session(a, .idle)], at: 11)
            #expect(kinds(done) == [a: .done])
            #expect(done.first?.since == t0.addingTimeInterval(11), "본 때(벽시계)를 표시한다")
            // 타이머가 없다: 3초 · 1분 · 하루가 지나도 열어 보기 전까지 그대로다
            for second: TimeInterval in [12, 14, 15, 20, 1_000, 86_400, 1_000_000] {
                let entries = walk.step([session(a, .idle)], at: second)
                #expect(kinds(entries) == [a: .done], "\(second)")
                #expect(entries.first?.since == t0.addingTimeInterval(11), "표시 시각은 본 때 그대로 (\(second))")
            }
            #expect(walk.step([session(a, .idle)], at: 1_000_001, opened: [a]).isEmpty, "열어 보면 내린다")
            #expect(walk.memory == ClaudeAppRailMemory(), "열어 본 것은 기억에서도 지운다")
            #expect(walk.step([session(a, .idle)], at: 1_000_002).isEmpty, "열어 본 뒤에는 다시 오르지 않는다")
        }

        @Test func theDoneMarksAreExactlyTheUnopenedDonesWithTheirPidAndTime() {
            var walk = Walk(wall0: t0)
            _ = walk.step([session(a, .busy, pid: 100), session(b, .busy, pid: 200), session(c, .busy, pid: 300)], at: 0)
            _ = walk.step([session(a, .idle, pid: 100), session(b, .idle, pid: 200), session(c, .busy, pid: 300)], at: 5)
            #expect(walk.memory.doneMarks == [a: ClaudeAppDoneMark(pid: 100, at: t0.addingTimeInterval(5)), b: ClaudeAppDoneMark(pid: 200, at: t0.addingTimeInterval(5))], "일하는 중인 c는 표시가 없다")
            _ = walk.step([session(a, .idle, pid: 100), session(b, .idle, pid: 200), session(c, .busy, pid: 300)], at: 6, opened: [b])
            #expect(walk.memory.doneMarks == [a: ClaudeAppDoneMark(pid: 100, at: t0.addingTimeInterval(5))], "열어 본 b는 지워진다")
        }

        @Test func aRelaunchRestoresTheUnopenedDonesOfTheSameLiveProcess() {
            var before = Walk(wall0: t0)
            _ = before.step([session(a, .busy, pid: 100), session(b, .busy, pid: 200)], at: 0)
            _ = before.step([session(a, .idle, pid: 100), session(b, .idle, pid: 200)], at: 4)
            let saved = before.memory.doneMarks
            #expect(saved.count == 2)
            // 앱을 다시 켰다: 기억은 비었고 저장해 둔 표시만 있다. 그 사이 시간이 한참 흘렀다
            var after = Walk(memory: ClaudeAppRailMemory(restoring: saved), wall0: t0.addingTimeInterval(86_400))
            let entries = after.step([session(a, .idle, pid: 100), session(b, .idle, pid: 999)], at: 0)
            #expect(kinds(entries) == [a: .done], "같은 프로세스(pid)의 표시만 산다: b는 다시 시작한 프로세스라 옛 끝남이 아니다")
            #expect(entries.first?.since == t0.addingTimeInterval(4), "표시 시각은 처음 본 때 그대로")
            #expect(after.memory.doneMarks == [a: ClaudeAppDoneMark(pid: 100, at: t0.addingTimeInterval(4))], "맞지 않은 표시는 기억에서도 지운다")
        }

        @Test func aRestoredMarkIsReplacedByANewTurnAndForgottenWhenItsProcessIsGone() {
            let marks = [a: ClaudeAppDoneMark(pid: 100, at: t0), b: ClaudeAppDoneMark(pid: 200, at: t0)]
            var walk = Walk(memory: ClaudeAppRailMemory(restoring: marks), wall0: t0.addingTimeInterval(100))
            #expect(kinds(walk.step([session(a, .busy, pid: 100), session(b, .idle, pid: 200)], at: 0)) == [a: .running, b: .done], "새 턴이 오면 done을 running이 대신한다")
            #expect(walk.memory.doneMarks == [b: ClaudeAppDoneMark(pid: 200, at: t0)])
            for second: TimeInterval in [1, 2, 3] { _ = walk.step([session(a, .busy, pid: 100)], at: second) }
            #expect(walk.memory.doneMarks.isEmpty, "프로세스가 끝나 세 번 안 보이면 표시도 지운다")
        }

        @Test func restoringAcceptsOnlyCanonicalSessionIDsAndAtMostTheCap() {
            var marks: [String: ClaudeAppDoneMark] = ["NOT-A-UUID": ClaudeAppDoneMark(pid: 1, at: t0), a.uppercased(): ClaudeAppDoneMark(pid: 2, at: t0), b: ClaudeAppDoneMark(pid: 3, at: t0)]
            #expect(ClaudeAppRailMemory(restoring: marks).doneMarks == [b: ClaudeAppDoneMark(pid: 3, at: t0)], "소문자 정규 UUID만")
            marks = [:]
            for n in 0..<(ClaudeAppRail.maxRestoredMarks + 20) { marks[F.uuid(0x4000 + n)] = ClaudeAppDoneMark(pid: Int32(10 + n), at: t0.addingTimeInterval(Double(n))) }
            let restored = ClaudeAppRailMemory(restoring: marks).doneMarks
            #expect(restored.count == ClaudeAppRail.maxRestoredMarks)
            #expect(restored.values.map(\.at).min() == t0.addingTimeInterval(20), "넘치면 오래된 것부터 버린다")
        }

        @Test func aDoneMarkHasNoPidOrIDInItsPrintedForm() {
            let mark = ClaudeAppDoneMark(pid: 4242, at: t0)
            for value in [String(describing: mark), String(reflecting: mark)] { #expect(!value.contains("4242"), "\(value)") }
        }

        @Test func waitingThenIdleIsDoneToo() {
            var walk = Walk(wall0: t0)
            _ = walk.step([session(a, .waiting(.approval))], at: 0)
            #expect(kinds(walk.step([session(a, .idle)], at: 1)) == [a: .done], "사용자가 답한 뒤 Claude가 끝낸 것도 같은 신호다 (코디네이터 결정 2026-10-22)")
        }

        @Test func openingItWhileItIsDoneTakesTheDoneDownAtOnceAndItDoesNotComeBack() {
            var walk = Walk(wall0: t0)
            _ = walk.step([session(a, .busy)], at: 0)
            #expect(kinds(walk.step([session(a, .idle)], at: 1)) == [a: .done])
            #expect(walk.step([session(a, .idle)], at: 1.5, opened: [a]).isEmpty, "열어 보면 내린다")
            #expect(walk.step([session(a, .idle)], at: 1.6).isEmpty, "열었던 세션의 done은 다시 오르지 않는다")
        }

        @Test func aSessionThatIsOpenWhileItFinishesNeverShowsDone() {
            var walk = Walk(wall0: t0)
            _ = walk.step([session(a, .busy)], at: 0, opened: [a])
            #expect(walk.step([session(a, .idle)], at: 5, opened: [a]).isEmpty, "보고 있던 세션이 끝난 것은 알릴 일이 아니다")
            #expect(walk.step([session(a, .idle)], at: 6).isEmpty)
            // 다른 세션이 열려 있다고 이 세션의 done이 사라지지 않는다
            _ = walk.step([session(a, .busy), session(b, .busy)], at: 10)
            #expect(kinds(walk.step([session(a, .idle), session(b, .busy)], at: 11, opened: [b])) == [a: .done, b: .running])
        }

        @Test func runningAgainDuringDoneReplacesItAndTheNextFinishIsDoneAgain() {
            var walk = Walk(wall0: t0)
            _ = walk.step([session(a, .busy)], at: 0)
            #expect(kinds(walk.step([session(a, .idle)], at: 1)) == [a: .done])
            #expect(kinds(walk.step([session(a, .busy)], at: 2)) == [a: .running])
            _ = walk.step([session(a, .busy)], at: 19)
            let again = walk.step([session(a, .idle)], at: 20)
            #expect(kinds(again) == [a: .done])
            #expect(again.first?.since == t0.addingTimeInterval(20), "새 done은 새 시각부터")
        }

        // MARK: 읽기가 흔들릴 때 · 오래된 기억

        @Test func aGlitchOfUnknownBetweenBusyAndIdleDoesNotLoseTheDone() {
            var walk = Walk(wall0: t0)
            _ = walk.step([session(a, .busy)], at: 0)
            #expect(walk.step([session(a, .unknown)], at: 1).isEmpty)
            #expect(kinds(walk.step([session(a, .idle)], at: 2)) == [a: .done])
        }

        @Test func aSessionUnknownForLongerThanTheLimitIsForgottenSoItNeverFlashesDoneLate() {
            var walk = Walk(wall0: t0)
            _ = walk.step([session(a, .busy)], at: 0)
            #expect(walk.step([session(a, .unknown)], at: 29).isEmpty)
            #expect(kinds(walk.step([session(a, .idle)], at: 30)) == [a: .done], "30초 안: 아직 막 끝난 것이다")
            var late = Walk(wall0: t0)
            _ = late.step([session(a, .busy)], at: 0)
            #expect(late.step([session(a, .unknown)], at: 10).isEmpty)
            #expect(late.step([session(a, .unknown)], at: 31).isEmpty)
            #expect(late.step([session(a, .idle)], at: 32).isEmpty, "오래 모르던 세션이 이제 쉰다고 해서 방금 끝난 것으로 알리지 않는다")
            #expect(late.memory == ClaudeAppRailMemory())
        }

        @Test func aLongGapBetweenTheLastBusyAndTheFirstIdleIsNotAFreshFinishEither() {
            var walk = Walk(wall0: t0)
            _ = walk.step([session(a, .busy)], at: 0)
            // 폴을 오래 안 했다 (레일을 숨겼거나 잠들었다 깸)
            #expect(walk.step([session(a, .idle)], at: 600).isEmpty)
        }

        @Test func aSessionMissingForOneOrTwoPollsKeepsItsMemoryButNotForThree() {
            var walk = Walk(wall0: t0)
            _ = walk.step([session(a, .busy)], at: 0)
            #expect(walk.step([], at: 1).isEmpty, "안 보이는 동안 줄은 없다")
            #expect(walk.step([], at: 2).isEmpty)
            #expect(kinds(walk.step([session(a, .idle)], at: 3)) == [a: .done], "두 번까지는 읽기가 흔들린 것으로 본다")
            var gone = Walk(wall0: t0)
            _ = gone.step([session(a, .busy)], at: 0)
            for second: TimeInterval in [1, 2, 3] { #expect(gone.step([], at: second).isEmpty) }
            #expect(gone.memory == ClaudeAppRailMemory(), "세 번 안 보이면 프로세스가 끝난 것이다: 기억도 지운다")
            #expect(gone.step([session(a, .idle)], at: 4).isEmpty, "지난 일로 done이 되지 않는다")
        }

        @Test func aSessionRestartedWithTheSameIDButAnotherPidIsNotAFalseDone() {
            var walk = Walk(wall0: t0)
            _ = walk.step([session(a, .busy, pid: 100)], at: 0)
            #expect(walk.step([session(a, .idle, pid: 200)], at: 1).isEmpty, "옛 프로세스가 일하던 기억은 새 프로세스의 끝이 아니다")
            #expect(walk.memory == ClaudeAppRailMemory())
            // 새 프로세스가 일하다 쉬면 그것은 done이다
            _ = walk.step([session(a, .busy, pid: 200)], at: 2)
            #expect(kinds(walk.step([session(a, .idle, pid: 200)], at: 3)) == [a: .done])
        }

        @Test func aDoneEntryIsTakenDownWhenItsProcessEnds() {
            var walk = Walk(wall0: t0)
            _ = walk.step([session(a, .busy)], at: 0)
            #expect(kinds(walk.step([session(a, .idle)], at: 1)) == [a: .done])
            #expect(walk.step([], at: 2).isEmpty, "프로세스가 끝난 세션의 줄은 바로 내린다")
            for second: TimeInterval in [3, 4] { _ = walk.step([], at: second) }
            #expect(walk.memory == ClaudeAppRailMemory())
        }

        @Test func aSessionWhoseProcessEndsIsTakenDownWithoutADone() {
            var walk = Walk(wall0: t0)
            _ = walk.step([session(a, .busy), session(b, .busy)], at: 0)
            #expect(kinds(walk.step([session(b, .busy)], at: 1)) == [b: .running], "끝난 세션은 done도 없이 내린다")
            for second: TimeInterval in [2, 3] { _ = walk.step([session(b, .busy)], at: second) }
            #expect(Set(walk.memory.activeIDs) == [b], "끝난 세션의 기억은 사라진다")
        }

        // MARK: 시계

        @Test func aWallClockThatJumpsBackOrForwardNeverTakesTheDoneDownOrMovesItsTime() {
            var back = Walk(wall0: t0)
            _ = back.step([session(a, .busy)], at: 0)
            let done = back.step([session(a, .idle)], at: 1)
            #expect(kinds(done) == [a: .done])
            for second: TimeInterval in [2, 3.9, 4, 100] {
                let entries = back.step([session(a, .idle)], at: second, wallShift: -10_000)
                #expect(kinds(entries) == [a: .done], "벽시계가 뒤로 가도 done은 열어 보기 전까지 그대로다 (\(second))")
                #expect(entries.first?.since == done.first?.since, "표시 시각은 본 때의 벽시계 그대로")
            }
            var forward = Walk(wall0: t0)
            _ = forward.step([session(a, .busy)], at: 0)
            let shown = forward.step([session(a, .idle)], at: 1)
            for second: TimeInterval in [2, 100] {
                let entries = forward.step([session(a, .idle)], at: second, wallShift: 86_400)
                #expect(kinds(entries) == [a: .done], "벽시계가 앞서가도 done은 그대로다 (\(second))")
                #expect(entries.first?.since == shown.first?.since)
            }
            // 일하던 기억의 나이는 단조 시간이다: 벽시계가 어떻게 가도 30초(단조) 안이면 끝남이고 넘으면 아니다
            var young = Walk(wall0: t0)
            _ = young.step([session(a, .busy)], at: 0)
            #expect(kinds(young.step([session(a, .idle)], at: 29, wallShift: -10_000)) == [a: .done])
            var old = Walk(wall0: t0)
            _ = old.step([session(a, .busy)], at: 0)
            #expect(old.step([session(a, .idle)], at: 31, wallShift: 86_400).isEmpty)
        }

        // MARK: 순서 · 순수함 · 값의 모양

        @Test func entriesAreNeedsYouThenRunningThenDoneAndNewerFirstInsideAGroup() {
            var walk = Walk(wall0: t0)
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
            var walk = Walk(wall0: t0)
            let first = walk.step([session(c, .busy), session(a, .busy), session(b, .busy)], at: 0)
            #expect(first.map(\.id) == [a, b, c])
            #expect(walk.step([session(b, .busy), session(c, .busy), session(a, .busy)], at: 1).map(\.id) == [a, b, c])
        }

        @Test func theSameInputGivesTheSameResultAndTheCallersMemoryIsNotChanged() {
            let memory = ClaudeAppRailMemory()
            let sessions = [session(a, .busy), session(b, .waiting(.approval))]
            let one = ClaudeAppRail.evaluate(sessions: sessions, memory: memory, now: t0, uptime: 5_000)
            let two = ClaudeAppRail.evaluate(sessions: sessions, memory: memory, now: t0, uptime: 5_000)
            #expect(one == two)
            #expect(memory == ClaudeAppRailMemory())
            #expect(one.memory != memory)
        }

        @Test func theMemoryNeverGrowsBeyondTheSessionsThatAreThere() {
            var walk = Walk(wall0: t0)
            for n in 0..<50 {
                let id = F.uuid(0x2000 + n)
                _ = walk.step([session(id, .busy)], at: Double(n * 10))
                _ = walk.step([session(id, .idle)], at: Double(n * 10 + 1))
            }
            for second: TimeInterval in [1000, 1001, 1002] { _ = walk.step([], at: second) }
            #expect(walk.memory == ClaudeAppRailMemory())
        }

        @Test func theEntriesAndTheMemoryPrintNoSessionID() {
            var walk = Walk(wall0: t0)
            let entries = walk.step([session(a, .busy), session(b, .waiting(.approval))], at: 0)
            let result = ClaudeAppRail.evaluate(sessions: [session(a, .busy)], memory: walk.memory, now: t0, uptime: 5_001)
            for value in [String(describing: entries), String(reflecting: entries), String(describing: walk.memory), String(reflecting: walk.memory), String(describing: result), String(reflecting: result)] {
                #expect(!value.contains(a) && !value.contains(b), "\(value)")
            }
        }
    }
}
#endif
