#if os(macOS)
import Foundation
import Testing
@testable import TaskforceKit

/// 세션 보기 V1의 순수 규칙 (DZ v2 E2 · E3 · E5 · E6): 단계 묶기(네 개부터) · 턴의 일한 시간 · 답 밑 줄(복사) · 도는 중 시계.
/// Claude 패널(기록)과 Taskforce 패널(대화)이 같은 규칙을 쓴다: 입력은 어느 쪽이든 같은 모양의 줄이다
struct SessionTimelineTests {
    typealias Item = SessionTimelineItem

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func user(_ id: String, _ seconds: TimeInterval?) -> Item { Item(id: id, role: .user, time: seconds.map { t0.addingTimeInterval($0) }, text: "ask \(id)") }
    private func answer(_ id: String, _ seconds: TimeInterval?, text: String? = nil) -> Item {
        Item(id: id, role: .assistant, time: seconds.map { t0.addingTimeInterval($0) }, text: text ?? "answer \(id)")
    }
    private func step(_ id: String, _ name: String = "Read", _ seconds: TimeInterval? = nil) -> Item {
        Item(id: id, role: .step, time: seconds.map { t0.addingTimeInterval($0) }, stepName: name)
    }
    private func event(_ id: String, _ seconds: TimeInterval? = nil) -> Item { Item(id: id, role: .other, time: seconds.map { t0.addingTimeInterval($0) }) }

    private func runs(_ entries: [SessionEntry]) -> [SessionStepRun] {
        entries.compactMap { if case .steps(let run) = $0 { run } else { nil } }
    }

    /// 첫 덩어리 (비어도 시험이 멈추지 않게 자리 값)
    private func first(_ runs: [SessionStepRun]) -> SessionStepRun { runs.first ?? SessionStepRun(id: "missing", stepIDs: [], label: "", isGroup: false, isLive: false) }

    private func footers(_ entries: [SessionEntry]) -> [SessionFooter] {
        entries.compactMap { if case .footer(let footer) = $0 { footer } else { nil } }
    }

    private func clock(_ entries: [SessionEntry]) -> SessionClock? {
        entries.compactMap { if case .clock(let clock) = $0 { clock } else { nil } }.first
    }

    /// 끝난 턴의 줄들 (사용자 결정 2026-10-23): 일한 시간은 답 **바로 위**, 복사는 답 **바로 밑**, 답 없는 턴의 시간은 턴의 끝
    private func worked(_ answerID: String, _ seconds: TimeInterval) -> SessionFooter {
        SessionFooter(id: "worked-\(answerID)", workedFor: seconds, copyText: nil, aboveAnswer: true)
    }
    private func copyLine(_ answerID: String, _ text: String? = nil) -> SessionFooter { SessionFooter(id: "footer-\(answerID)", workedFor: nil, copyText: text ?? "answer \(answerID)") }
    private func endLine(_ lastID: String, _ seconds: TimeInterval) -> SessionFooter { SessionFooter(id: "footer-\(lastID)", workedFor: seconds, copyText: nil) }

    /// 줄들의 모양 (순서 확인용): 항목 id · "steps:a,b" · "worked:<줄 id>" (답 위 시간) · "copy:<줄 id>" (답 밑 복사) · "end:<줄 id>" (턴 끝 시간) · "clock"
    private func shape(_ entries: [SessionEntry]) -> [String] {
        entries.map {
            switch $0 {
            case .item(let id): id
            case .steps(let run): "steps:" + run.stepIDs.joined(separator: ",")
            case .footer(let footer): footer.aboveAnswer ? "worked:\(footer.id)" : (footer.copyText != nil ? "copy:\(footer.id)" : "end:\(footer.id)")
            case .clock: "clock"
            }
        }
    }

    // MARK: 묶기 (E3)

    @Test func threeConsecutiveStepsStayAsLinesAndFourBecomeOneGroup() {
        let three = SessionTimeline.build([user("u", 0), step("a"), step("b"), step("c"), answer("r", 30)], state: .finished)
        #expect(runs(three).count == 1 && first(runs(three)).stepIDs == ["a", "b", "c"] && !first(runs(three)).isGroup)
        let four = SessionTimeline.build([user("u", 0), step("a"), step("b"), step("c"), step("d"), answer("r", 30)], state: .finished)
        #expect(runs(four).count == 1 && first(runs(four)).stepIDs == ["a", "b", "c", "d"] && first(runs(four)).isGroup)
        #expect(SessionTimeline.groupThreshold == 4 && SessionTimeline.visibleRecent == 6)
    }

    @Test func aMessageBetweenStepsSplitsTheRunsAndEachRunIsCountedOnItsOwn() {
        let items = [user("u", 0), step("a"), step("b"), step("c"), answer("m", 5), step("d"), step("e"), step("f"), step("g"), answer("r", 40)]
        let found = runs(SessionTimeline.build(items, state: .finished))
        #expect(found.map(\.stepIDs) == [["a", "b", "c"], ["d", "e", "f", "g"]])
        #expect(found.map(\.isGroup) == [false, true], "세 개 + 네 개는 합쳐 일곱이 아니다")
    }

    @Test func aUserMessageEndsTheRunSoStepsOfTwoTurnsNeverMerge() {
        let items = [user("u1", 0), step("a"), step("b"), user("u2", 60), step("c"), step("d"), step("e"), step("f")]
        let found = runs(SessionTimeline.build(items, state: .finished))
        #expect(found.map(\.stepIDs) == [["a", "b"], ["c", "d", "e", "f"]])
    }

    @Test func anEventLineBetweenStepsAlsoSplitsTheRun() {
        let found = runs(SessionTimeline.build([user("u", 0), step("a"), step("b"), event("e"), step("c"), step("d")], state: .finished))
        #expect(found.map(\.stepIDs) == [["a", "b"], ["c", "d"]])
    }

    @Test func theGroupIsNamedByItsFirstStepSoItsIdentityHoldsWhileItGrows() {
        let growing = [user("u", 0), step("a"), step("b"), step("c"), step("d")]
        let before = first(runs(SessionTimeline.build(growing, state: .running)))
        let after = first(runs(SessionTimeline.build(growing + [step("e"), step("f")], state: .running)))
        #expect(before.id == "a" && after.id == "a")
        #expect(after.stepIDs.count == 6)
    }

    @Test func theGroupLabelListsToolNamesOnceInFirstUsedOrder() {
        let items = [user("u", 0), step("a", "Read"), step("b", "Grep"), step("c", "Read"), step("d", "Glob"), step("e", "Task")]
        #expect(first(runs(SessionTimeline.build(items, state: .finished))).label == "Read · Grep · Glob · Task")
    }

    @Test func stepsBeforeTheFirstUserMessageAreStillGrouped() {
        // Show earlier로 잘린 앞 턴: 사용자 말이 읽은 구간 밖이다
        let found = runs(SessionTimeline.build([step("a"), step("b"), step("c"), step("d"), answer("r", nil)], state: .finished))
        #expect(found.count == 1 && first(found).isGroup)
    }

    // MARK: 도는 턴의 마지막 묶음 (열림)

    @Test func onlyTheLastRunOfARunningTurnIsLive() {
        let items = [user("u1", 0), step("a"), step("b"), step("c"), step("d"), answer("m", 5), user("u2", 100), step("e"), step("f"), step("g"), step("h"), answer("m2", 110), step("i"), step("j"), step("k"), step("l")]
        let found = runs(SessionTimeline.build(items, state: .running))
        #expect(found.map(\.isLive) == [false, false, true])
    }

    @Test func nothingIsLiveWhenTheTurnIsFinishedOrWaitingForApproval() {
        let items = [user("u", 0), step("a"), step("b"), step("c"), step("d")]
        #expect(runs(SessionTimeline.build(items, state: .finished)).allSatisfy { !$0.isLive })
        #expect(runs(SessionTimeline.build(items, state: .frozen)).allSatisfy { !$0.isLive })
    }

    // MARK: 답 밑 줄 (E5)

    /// 사용자 결정(2026-10-23): 끝난 턴은 단계 · 이벤트 줄(묶음) → "Worked for …"(시간만) → 마지막 답 → 복사 아이콘(답 바로 밑)이다.
    /// 마지막 답 뒤에 이어진 단계는 시간 줄 앞으로 올라온다 (단계끼리의 순서는 그대로)
    @Test func theWorkedTimeSitsAboveTheLastAnswerAndItsCopyUnderIt() {
        let items = [user("u", 0), step("a"), answer("m", 4, text: "I'll read first."), step("b"), answer("r", 252, text: "Final **answer**")]
        let entries = SessionTimeline.build(items, state: .finished)
        #expect(shape(entries) == ["u", "steps:a", "m", "steps:b", "worked:worked-r", "r", "copy:footer-r"])
        #expect(footers(entries) == [worked("r", 252), copyLine("r", "Final **answer**")])
    }

    @Test func stepsAfterTheAnswerMoveUpBeforeTheTimeLineKeepingTheirOrder() {
        let entries = SessionTimeline.build([user("u", 0), answer("r", 30, text: "done"), step("a", "Read", 40), step("b", "Grep", 41)], state: .finished)
        #expect(shape(entries) == ["u", "steps:a,b", "worked:worked-r", "r", "copy:footer-r"])
        #expect(footers(entries) == [worked("r", 41), copyLine("r", "done")], "시간은 턴 전체 (가장 늦은 항목까지)")
    }

    @Test func stepsAfterTheAnswerJoinTheStepsBeforeItInOneFoldedGroup() {
        let entries = SessionTimeline.build([user("u", 0), step("a"), step("b"), step("c"), answer("r", 30), step("d")], state: .finished)
        #expect(runs(entries).count == 1 && first(runs(entries)).stepIDs == ["a", "b", "c", "d"] && first(runs(entries)).isGroup, "이어 붙은 단계는 한 묶음이다")
        #expect(shape(entries) == ["u", "steps:a,b,c,d", "worked:worked-r", "r", "copy:footer-r"])
    }

    @Test func anEventRowAfterTheAnswerKeepsItsPlaceAfterTheCopy() {
        let entries = SessionTimeline.build([user("u", 0), answer("r", 60, text: "The **answer**"), event("e", 61)], state: .finished)
        #expect(shape(entries) == ["u", "worked:worked-r", "r", "copy:footer-r", "e"], "이벤트 줄은 시간순 그대로 답 · 복사 뒤에")
        #expect(footers(entries) == [worked("r", 61), copyLine("r", "The **answer**")])
    }

    @Test func stepsAndEventsAfterTheAnswerOnlyTheStepsMoveUp() {
        let entries = SessionTimeline.build([user("u", 0), answer("r", 60), event("e", 61), step("s", "Bash", 62)], state: .finished)
        #expect(shape(entries) == ["u", "steps:s", "worked:worked-r", "r", "copy:footer-r", "e"])
    }

    @Test func theCopyIsTheLastAnswerOfTheTurnNotTheLastRowAndSitsUnderIt() {
        let items = [user("u", 0), answer("m1", 5, text: "first"), event("e1", 6), answer("m2", 20, text: "second"), event("e2", 21), event("e3", 22)]
        let entries = SessionTimeline.build(items, state: .finished)
        #expect(shape(entries) == ["u", "m1", "e1", "worked:worked-m2", "m2", "copy:footer-m2", "e2", "e3"], "시간은 마지막 답 바로 위, 복사는 바로 밑")
        #expect(footers(entries) == [worked("m2", 22), copyLine("m2", "second")])
        let blankLast = [user("u", 0), answer("m1", 5, text: "first"), answer("m2", 20, text: "  \n"), event("e", 21)]
        let blank = SessionTimeline.build(blankLast, state: .finished)
        #expect(footers(blank).compactMap(\.copyText).isEmpty, "마지막 답이 비었으면 앞의 답을 대신 복사하지 않는다")
        #expect(shape(blank) == ["u", "m1", "m2", "e", "end:footer-e"], "답이 없는 턴처럼 시간은 턴의 끝")
    }

    @Test func underTenSecondsThereIsNoTimeLineButStepsStillMoveAboveTheAnswer() {
        let entries = SessionTimeline.build([user("u", 0), answer("r", 3, text: "quick"), step("s", "Read", 4)], state: .finished)
        #expect(shape(entries) == ["u", "steps:s", "r", "copy:footer-r"], "10초 미만이면 시간 줄이 없다 (자리는 그대로 안정적이다)")
        #expect(footers(entries) == [copyLine("r", "quick")])
    }

    @Test func everyFooterIdOfAConversationIsUniqueSoOnlyTheHoveredAnswerRevealsItsCopy() {
        let items = [
            user("u1", 0), answer("r1", 20, text: "one"), event("e1", 21), user("u2", 100), step("a", "Read", 110), answer("r2", 130, text: "two"), step("b", "Grep", 140),
            user("u3", 200), answer("r3", 230, text: "three"),
        ]
        let ids = footers(SessionTimeline.build(items, state: .finished)).map(\.id)
        #expect(Set(ids).count == ids.count && ids.contains("footer-r1") && ids.contains("footer-r2") && ids.contains("footer-r3"))
        #expect(ids.contains("worked-r1") && ids.contains("worked-r2") && ids.contains("worked-r3"))
    }

    @Test func aTurnWithOnlyAnEventAfterTheAskHasNoCopy() {
        #expect(footers(SessionTimeline.build([user("u", 0), event("e", 3)], state: .finished)).isEmpty)
    }

    @Test func aTurnUnderTenSecondsKeepsTheCopyAndDropsTheTime() {
        let entries = SessionTimeline.build([user("u", 0), answer("r", 9)], state: .finished)
        #expect(footers(entries) == [copyLine("r")])
        let ten = SessionTimeline.build([user("u", 0), answer("r", 10)], state: .finished)
        #expect(footers(ten) == [worked("r", 10), copyLine("r")], "10초부터 시간 줄이 답 위에 선다")
    }

    @Test func aTurnWithoutTimestampsHasNoTimeButStillCopies() {
        let entries = SessionTimeline.build([user("u", nil), answer("r", nil)], state: .finished)
        #expect(footers(entries) == [copyLine("r")])
        let halfKnown = SessionTimeline.build([user("u", 0), answer("r", nil)], state: .finished)
        #expect(footers(halfKnown) == [copyLine("r")], "끝을 모르면 시간 줄이 없다")
    }

    @Test func aTurnWithNeitherAnAnswerNorATimeHasNoLine() {
        #expect(footers(SessionTimeline.build([user("u", 0)], state: .finished)).isEmpty)
        #expect(footers(SessionTimeline.build([user("u", 0), step("a", "Read", 3)], state: .finished)).isEmpty, "답도 없고 10초도 안 됐다")
    }

    @Test func aFinishedTurnWithoutAnAnswerButLongEnoughStillSaysHowLongItWorked() {
        let entries = SessionTimeline.build([user("u", 0), step("a", "Read", 20)], state: .finished)
        #expect(footers(entries) == [endLine("a", 20)])
        #expect(shape(entries) == ["u", "steps:a", "end:footer-a"], "답이 없는 턴의 시간은 턴의 끝 (그대로)")
    }

    @Test func theCopyTextBelongsToTheLastAnswerEvenWhenAStepFollowsIt() {
        // 마지막 답 뒤에 단계가 더 있다 (v1은 복사를 버렸다: 리뷰 P3): 단계는 시간 줄 앞으로 올라오고, 복사는 그 답 바로 밑이다
        let entries = SessionTimeline.build([user("u", 0), answer("r", 20), step("a", "Bash", 40)], state: .finished)
        #expect(footers(entries) == [worked("r", 40), copyLine("r")])
        #expect(shape(entries) == ["u", "steps:a", "worked:worked-r", "r", "copy:footer-r"])
        #expect(entries.last == .footer(copyLine("r")), "복사 아이콘이 턴의 끝이다")
    }

    @Test func everyTurnOfAConversationHasItsOwnLine() {
        let items = [user("u1", 0), answer("r1", 18), user("u2", 100), step("a"), answer("r2", 163), user("u3", 400), answer("r3", 405)]
        let entries = SessionTimeline.build(items, state: .finished)
        #expect(footers(entries) == [worked("r1", 18), copyLine("r1"), worked("r2", 63), copyLine("r2"), copyLine("r3")])
        #expect(shape(entries) == [
            "u1", "worked:worked-r1", "r1", "copy:footer-r1",
            "u2", "steps:a", "worked:worked-r2", "r2", "copy:footer-r2",
            "u3", "r3", "copy:footer-r3",
        ])
    }

    @Test func theEndOfATurnIsTheLatestTimeAmongItsItemsNotTheLastOne() {
        // 기록의 시각이 서로 어긋나 있어도 음수 · 줄어든 값이 나오지 않는다
        let entries = SessionTimeline.build([user("u", 0), answer("m", 90), answer("r", 40)], state: .finished)
        #expect(footers(entries).first?.workedFor == 90)
    }

    @Test func aTurnWithoutItsUserMessageHasNoStartSoNoTime() {
        let entries = SessionTimeline.build([answer("r", 500)], state: .finished)
        #expect(footers(entries) == [copyLine("r")])
    }

    @Test func anAnswerWithNoTextGetsNoCopyText() {
        let blank = Item(id: "r", role: .assistant, time: t0.addingTimeInterval(30), text: "  \n ")
        let entries = SessionTimeline.build([user("u", 0), blank], state: .finished)
        #expect(footers(entries) == [endLine("r", 30)], "비었으면 답이 없는 것처럼 시간은 턴의 끝")
    }

    // MARK: 도는 중 시계 (E6)

    @Test func aRunningTurnEndsWithTheClockAndHasNoFooter() {
        let items = [user("u1", 0), answer("r1", 40), user("u2", 100), step("a"), answer("m", 110)]
        let entries = SessionTimeline.build(items, state: .running)
        #expect(clock(entries) == SessionClock(id: "clock-u2", since: t0.addingTimeInterval(100)))
        #expect(entries.last == .clock(SessionClock(id: "clock-u2", since: t0.addingTimeInterval(100))))
        #expect(footers(entries).map(\.id) == ["worked-r1", "footer-r1"], "끝난 앞 턴만 줄을 가진다")
        #expect(shape(entries) == ["u1", "worked:worked-r1", "r1", "copy:footer-r1", "u2", "steps:a", "m", "clock"], "도는 턴은 순서를 바꾸지 않고 시계가 늘 끝이다")
    }

    @Test func aRunningTurnKeepsTheStepsAfterItsAnswerWhereTheyAre() {
        let items = [user("u", 0), answer("r", 30), step("s", "Read", 40)]
        let entries = SessionTimeline.build(items, state: .running)
        #expect(shape(entries) == ["u", "r", "steps:s", "clock"], "도는 동안은 단계를 올리지 않고 줄도 없다")
    }

    @Test func theClockIsAbsentWhenTheStartIsUnknown() {
        #expect(clock(SessionTimeline.build([answer("m", nil)], state: .running)) == nil)
        #expect(clock(SessionTimeline.build([user("u", nil), answer("m", nil)], state: .running)) == nil)
        #expect(clock(SessionTimeline.build([], state: .running)) == nil)
    }

    @Test func aRunningStateWithoutAnyUserMessageHasNoClock() {
        // Show earlier로 잘려 사용자 말이 구간 밖이다: 시작을 지어내지 않는다
        #expect(clock(SessionTimeline.build([step("a"), answer("m", 5)], state: .running)) == nil)
    }

    @Test func aTurnWaitingForApprovalFreezesAtItsLastItemAndSaysWorkedFor() {
        // 승인을 기다리는 동안은 "Working"이 아니다: 마지막으로 움직인 때까지의 값으로 멈춘다 (v2 그림 1: "Worked for 1m 48s")
        let items = [user("u", 0), step("a", "Edit", 50), step("b", "Bash", 108)]
        let entries = SessionTimeline.build(items, state: .frozen)
        #expect(clock(entries) == nil)
        #expect(footers(entries) == [SessionFooter(id: "footer-b", workedFor: 108, copyText: nil)])
    }

    @Test func entryIdsAreUniqueAndDoNotChangeWhenTheSameItemsAreBuiltAgain() {
        let items = [user("u", 0), step("a"), step("b"), step("c"), step("d"), answer("r", 30)]
        let first = SessionTimeline.build(items, state: .finished)
        let second = SessionTimeline.build(items, state: .finished)
        #expect(first.map(\.id) == second.map(\.id))
        #expect(Set(first.map(\.id)).count == first.count)
    }

    @Test func everyItemAppearsExactlyOnceInOrder() {
        let items = [user("u", 0), step("a"), step("b"), answer("m", 3), step("c"), step("d"), step("e"), step("f"), event("ev"), answer("r", 30)]
        var seen: [String] = []
        for entry in SessionTimeline.build(items, state: .finished) {
            switch entry {
            case .item(let id): seen.append(id)
            case .steps(let run): seen += run.stepIDs
            case .footer, .clock: break
            }
        }
        #expect(seen == items.map(\.id))
    }

    @Test func everyItemStillAppearsExactlyOnceWhenStepsAfterTheAnswerMoveUp() {
        let items = [user("u", 0), step("a"), answer("r", 30), step("b"), event("ev"), step("c"), user("u2", 100), answer("r2", 110)]
        var seen: [String] = []
        for entry in SessionTimeline.build(items, state: .finished) {
            switch entry {
            case .item(let id): seen.append(id)
            case .steps(let run): seen += run.stepIDs
            case .footer, .clock: break
            }
        }
        #expect(seen == ["u", "a", "b", "c", "r", "ev", "u2", "r2"], "단계는 시간 줄 앞으로, 이벤트는 제자리, 단계끼리 · 턴끼리 순서는 그대로")
        #expect(Set(seen) == Set(items.map(\.id)) && seen.count == items.count)
    }
}
#endif
