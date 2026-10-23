#if os(macOS)
import Foundation
import Testing
@testable import TaskforceKit

/// 세션 보기 본문이 한꺼번에 그리는 줄의 창 (#187 핫픽스): 가장 새 `renderWindow`(150)개만 그리고, 창의 첫 줄은 **덩어리의 첫 줄**이다 —
/// 단계 묶음 · "Worked for"와 그 아래 답 · 답과 그 밑 복사 줄을 쪼개지 않는다. 순수한 규칙이라 화면 없이 센다
struct SessionWindowTests {
    typealias Item = SessionTimelineItem

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// 턴 `count`개의 타임라인: 사용자 말 → 단계(0 · 3 · 4 · 7개) → 답(5초 또는 30초 일함: 30초면 답 위에 "Worked for"가 선다) · 가끔 답 없는 턴 · 이벤트 줄
    private func timeline(turns count: Int, running: Bool = false) -> [SessionEntry] {
        var items: [Item] = []
        for turn in 0..<count {
            let start = TimeInterval(turn * 1_000)
            items.append(Item(id: "u\(turn)", role: .user, time: t0.addingTimeInterval(start), text: "ask \(turn)"))
            for step in 0..<[0, 3, 4, 7][turn % 4] {
                items.append(Item(id: "s\(turn)-\(step)", role: .step, time: t0.addingTimeInterval(start + 1), stepName: "Read"))
            }
            if turn % 5 == 4 {
                items.append(Item(id: "e\(turn)", role: .other, time: t0.addingTimeInterval(start + 2)))
            } else {
                items.append(Item(id: "a\(turn)", role: .assistant, time: t0.addingTimeInterval(start + (turn % 2 == 0 ? 5 : 30)), text: "answer \(turn)"))
            }
        }
        return SessionTimeline.build(items, state: running ? .running : .finished)
    }

    private func isCopyOrEndFooter(_ entry: SessionEntry) -> Bool {
        if case .footer(let footer) = entry { !footer.aboveAnswer } else { false }
    }

    @Test func theWindowIsOneHundredFifty() {
        #expect(SessionTimeline.renderWindow == 150)
    }

    @Test func aTimelineThatFitsTheLimitIsDrawnWholeFromTheFirstEntry() {
        let entries = timeline(turns: 20)
        #expect(entries.count < SessionTimeline.renderWindow)
        #expect(SessionTimeline.windowStart(entries, limit: SessionTimeline.renderWindow) == 0)
        #expect(SessionTimeline.windowStart(entries, limit: entries.count) == 0)
        #expect(SessionTimeline.windowStart([], limit: 150) == 0)
    }

    @Test func theWindowHoldsAtMostTheLimitAndStartsOnTheNearestUnitStartAtOrAfterTheCut() {
        for turns in [60, 123, 200, 361] {
            let entries = timeline(turns: turns, running: turns % 2 == 1)
            for limit in [4, 5, 8, 13, 40, 150] where entries.count > limit {
                let start = SessionTimeline.windowStart(entries, limit: limit)
                let cut = entries.count - limit
                #expect(start >= cut && start < entries.count, "turns \(turns) limit \(limit): start \(start) cut \(cut)")
                #expect(entries.count - start <= limit, "그려지는 줄은 한도를 넘지 않는다")
                #expect(SessionTimeline.startsUnit(entries, at: start), "turns \(turns) limit \(limit): 창이 덩어리 한가운데서 시작한다 (\(entries[start]))")
                #expect(!(cut..<max(cut, start)).contains { SessionTimeline.startsUnit(entries, at: $0) }, "더 가까운 첫 줄이 있었다 (불필요하게 많이 잘랐다)")
            }
        }
    }

    @Test func aCopyLineOrAnEndLineNeverStartsTheWindowAndAnAnswerNeverStartsWithoutItsWorkedFor() {
        let entries = timeline(turns: 240)
        var cuts = 0
        for limit in 20...200 where entries.count > limit {
            let start = SessionTimeline.windowStart(entries, limit: limit)
            #expect(!isCopyOrEndFooter(entries[start]), "복사 줄 · 끝 줄로 시작했다 (limit \(limit))")
            if case .item = entries[start], start > 0, case .footer(let before) = entries[start - 1] { #expect(!before.aboveAnswer, "답 위 \"Worked for\"와 답 사이를 잘랐다 (limit \(limit))") }
            if start != entries.count - limit { cuts += 1 }
        }
        #expect(cuts > 5, "시험이 덩어리 한가운데 떨어지는 자리를 실제로 겪었다: \(cuts)")
    }

    @Test func aStepGroupAtTheCutIsKeptWholeAndMayStartTheWindow() {
        let run = SessionStepRun(id: "g", stepIDs: (0..<12).map { "g\($0)" }, label: "Read", isGroup: true, isLive: false)
        var entries: [SessionEntry] = (0..<10).map { .item("i\($0)") }
        entries.append(.steps(run))
        entries += (0..<9).map { .item("j\($0)") }
        // 컷이 정확히 묶음 자리: 묶음은 줄 하나라 통째로 그려진다 (창이 거기서 시작해도 된다)
        #expect(SessionTimeline.windowStart(entries, limit: entries.count - 10) == 10)
        guard case .steps(let kept) = entries[SessionTimeline.windowStart(entries, limit: entries.count - 10)] else {
            Issue.record("창의 첫 줄이 묶음이어야 한다")
            return
        }
        #expect(kept.stepIDs.count == 12, "묶음의 단계는 하나도 빠지지 않는다")
    }

    @Test func aWorkedForLineStaysWithItsAnswerAndTheirCopyLine() {
        let worked = SessionFooter(id: "worked-a", workedFor: 40, copyText: nil, aboveAnswer: true)
        let copy = SessionFooter(id: "footer-a", workedFor: nil, copyText: "answer a")
        let entries: [SessionEntry] = [.item("u"), .footer(worked), .item("a"), .footer(copy), .item("u2"), .item("a2")]
        // 컷이 "Worked for" 줄이면 그 덩어리가 통째로
        #expect(SessionTimeline.windowStart(entries, limit: 5) == 1)
        // 컷이 답이면 (줄과 갈라진다) · 복사 줄이면 다음 덩어리(u2)까지 민다
        #expect(SessionTimeline.windowStart(entries, limit: 4) == 4, "답 · 복사 줄은 첫 줄이 될 수 없다")
        #expect(SessionTimeline.windowStart(entries, limit: 3) == 4)
        #expect(SessionTimeline.windowStart(entries, limit: 2) == 4)
        #expect(SessionTimeline.startsUnit(entries, at: 0) && SessionTimeline.startsUnit(entries, at: 1))
        #expect(!SessionTimeline.startsUnit(entries, at: 2) && !SessionTimeline.startsUnit(entries, at: 3))
    }

    @Test func whenNothingNearerStartsAUnitTheWindowFallsBackToTheNearestOneBefore() {
        let copy = SessionFooter(id: "footer-a", workedFor: nil, copyText: "answer a")
        let entries: [SessionEntry] = [.item("u"), .item("a"), .footer(copy)]
        #expect(SessionTimeline.windowStart(entries, limit: 1) == 1, "마지막 줄이 복사 줄뿐이라 앞쪽 첫 줄까지 물러난다 (한 줄 더 그린다)")
    }

    @Test func unitStartWalksBackToTheFirstLineOfTheUnit() {
        let worked = SessionFooter(id: "worked-a", workedFor: 40, copyText: nil, aboveAnswer: true)
        let copy = SessionFooter(id: "footer-a", workedFor: nil, copyText: "answer a")
        let entries: [SessionEntry] = [.item("u"), .footer(worked), .item("a"), .footer(copy), .item("u2")]
        #expect(SessionTimeline.unitStart(entries, atOrBefore: 4) == 4)
        #expect(SessionTimeline.unitStart(entries, atOrBefore: 3) == 1, "복사 줄 → 답 → \"Worked for\" 줄에서 멈춘다")
        #expect(SessionTimeline.unitStart(entries, atOrBefore: 2) == 1)
        #expect(SessionTimeline.unitStart(entries, atOrBefore: 1) == 1)
        #expect(SessionTimeline.unitStart(entries, atOrBefore: 0) == 0)
        #expect(SessionTimeline.unitStart(entries, atOrBefore: -5) == 0)
        #expect(SessionTimeline.unitStart(entries, atOrBefore: 99) == 4, "범위 밖이면 끝으로 맞춘다")
    }

    @Test func theRunningClockNeverStartsTheWindow() {
        let entries = timeline(turns: 100, running: true)
        guard case .clock = entries.last else {
            Issue.record("도는 턴의 시계가 끝에 있어야 한다")
            return
        }
        for limit in 1...30 where entries.count > limit {
            #expect(!{ if case .clock = entries[SessionTimeline.windowStart(entries, limit: limit)] { true } else { false } }(), "시계로 시작했다 (limit \(limit))")
        }
    }
}
#endif
