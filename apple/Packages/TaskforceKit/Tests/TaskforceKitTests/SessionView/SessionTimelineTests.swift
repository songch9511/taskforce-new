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

    @Test func theLastAnswerOfAFinishedTurnGetsTheWorkedTimeAndItsCopyText() {
        let items = [user("u", 0), step("a"), answer("m", 4, text: "I'll read first."), step("b"), answer("r", 252, text: "Final **answer**")]
        let entries = SessionTimeline.build(items, state: .finished)
        #expect(footers(entries) == [SessionFooter(id: "footer-r", workedFor: 252, copyText: "Final **answer**")])
        #expect(entries.last == .footer(SessionFooter(id: "footer-r", workedFor: 252, copyText: "Final **answer**")), "줄은 마지막 답 바로 밑이다")
    }

    /// 리뷰 P3: 복사할 글은 턴의 **마지막 답**이다. 답 뒤에 이벤트 줄 · 단계가 붙어도 복사가 사라지지 않는다 (줄은 턴의 끝에 있다)
    @Test func anEventRowAfterTheAnswerDoesNotSuppressTheCopy() {
        let entries = SessionTimeline.build([user("u", 0), answer("r", 60, text: "The **answer**"), event("e", 61)], state: .finished)
        #expect(footers(entries) == [SessionFooter(id: "footer-r", workedFor: 61, copyText: "The **answer**")])
        #expect(entries.last == .footer(SessionFooter(id: "footer-r", workedFor: 61, copyText: "The **answer**")), "줄은 턴의 끝이다")
    }

    @Test func stepsAfterTheAnswerDoNotSuppressTheCopyEither() {
        let entries = SessionTimeline.build([user("u", 0), answer("r", 30, text: "done"), step("a", "Read", 40), step("b", "Grep", 41)], state: .finished)
        #expect(footers(entries).map(\.copyText) == ["done"])
    }

    @Test func theCopyIsTheLastAnswerOfTheTurnNotTheLastRow() {
        let items = [user("u", 0), answer("m1", 5, text: "first"), event("e1", 6), answer("m2", 20, text: "second"), event("e2", 21), event("e3", 22)]
        #expect(footers(SessionTimeline.build(items, state: .finished)).map(\.copyText) == ["second"])
        let blankLast = [user("u", 0), answer("m1", 5, text: "first"), answer("m2", 20, text: "  \n"), event("e", 21)]
        #expect(footers(SessionTimeline.build(blankLast, state: .finished)).first?.copyText == nil, "마지막 답이 비었으면 앞의 답을 대신 복사하지 않는다")
    }

    @Test func aTurnWithOnlyAnEventAfterTheAskHasNoCopy() {
        #expect(footers(SessionTimeline.build([user("u", 0), event("e", 3)], state: .finished)).isEmpty)
    }

    @Test func aTurnUnderTenSecondsKeepsTheCopyAndDropsTheTime() {
        let entries = SessionTimeline.build([user("u", 0), answer("r", 9)], state: .finished)
        #expect(footers(entries) == [SessionFooter(id: "footer-r", workedFor: nil, copyText: "answer r")])
        let ten = SessionTimeline.build([user("u", 0), answer("r", 10)], state: .finished)
        #expect(footers(ten).first?.workedFor == 10)
    }

    @Test func aTurnWithoutTimestampsHasNoTimeButStillCopies() {
        let entries = SessionTimeline.build([user("u", nil), answer("r", nil)], state: .finished)
        #expect(footers(entries) == [SessionFooter(id: "footer-r", workedFor: nil, copyText: "answer r")])
        let halfKnown = SessionTimeline.build([user("u", 0), answer("r", nil)], state: .finished)
        #expect(footers(halfKnown).first?.workedFor == nil)
    }

    @Test func aTurnWithNeitherAnAnswerNorATimeHasNoLine() {
        #expect(footers(SessionTimeline.build([user("u", 0)], state: .finished)).isEmpty)
        #expect(footers(SessionTimeline.build([user("u", 0), step("a", "Read", 3)], state: .finished)).isEmpty, "답도 없고 10초도 안 됐다")
    }

    @Test func aFinishedTurnWithoutAnAnswerButLongEnoughStillSaysHowLongItWorked() {
        let entries = SessionTimeline.build([user("u", 0), step("a", "Read", 20)], state: .finished)
        #expect(footers(entries) == [SessionFooter(id: "footer-a", workedFor: 20, copyText: nil)])
    }

    @Test func theCopyTextBelongsToTheLastAnswerEvenWhenAStepFollowsIt() {
        // 마지막 답 뒤에 단계가 더 있다 (v1은 복사를 버렸다: 리뷰 P3): 줄은 턴의 끝에 서고, 복사와 이름은 그 답의 것이다. 시간은 턴 전체다
        let entries = SessionTimeline.build([user("u", 0), answer("r", 20), step("a", "Bash", 40)], state: .finished)
        #expect(footers(entries) == [SessionFooter(id: "footer-r", workedFor: 40, copyText: "answer r")])
        #expect(entries.last == .footer(SessionFooter(id: "footer-r", workedFor: 40, copyText: "answer r")))
    }

    @Test func everyTurnOfAConversationHasItsOwnLine() {
        let items = [user("u1", 0), answer("r1", 18), user("u2", 100), step("a"), answer("r2", 163), user("u3", 400), answer("r3", 405)]
        let found = footers(SessionTimeline.build(items, state: .finished))
        #expect(found == [
            SessionFooter(id: "footer-r1", workedFor: 18, copyText: "answer r1"),
            SessionFooter(id: "footer-r2", workedFor: 63, copyText: "answer r2"),
            SessionFooter(id: "footer-r3", workedFor: nil, copyText: "answer r3"),
        ])
    }

    @Test func theEndOfATurnIsTheLatestTimeAmongItsItemsNotTheLastOne() {
        // 기록의 시각이 서로 어긋나 있어도 음수 · 줄어든 값이 나오지 않는다
        let entries = SessionTimeline.build([user("u", 0), answer("m", 90), answer("r", 40)], state: .finished)
        #expect(footers(entries).first?.workedFor == 90)
    }

    @Test func aTurnWithoutItsUserMessageHasNoStartSoNoTime() {
        let entries = SessionTimeline.build([answer("r", 500)], state: .finished)
        #expect(footers(entries) == [SessionFooter(id: "footer-r", workedFor: nil, copyText: "answer r")])
    }

    @Test func anAnswerWithNoTextGetsNoCopyText() {
        let blank = Item(id: "r", role: .assistant, time: t0.addingTimeInterval(30), text: "  \n ")
        let entries = SessionTimeline.build([user("u", 0), blank], state: .finished)
        #expect(footers(entries) == [SessionFooter(id: "footer-r", workedFor: 30, copyText: nil)])
    }

    // MARK: 도는 중 시계 (E6)

    @Test func aRunningTurnEndsWithTheClockAndHasNoFooter() {
        let items = [user("u1", 0), answer("r1", 40), user("u2", 100), step("a"), answer("m", 110)]
        let entries = SessionTimeline.build(items, state: .running)
        #expect(clock(entries) == SessionClock(id: "clock-u2", since: t0.addingTimeInterval(100)))
        #expect(entries.last == .clock(SessionClock(id: "clock-u2", since: t0.addingTimeInterval(100))))
        #expect(footers(entries).map(\.id) == ["footer-r1"], "끝난 앞 턴만 줄을 가진다")
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
}
#endif
