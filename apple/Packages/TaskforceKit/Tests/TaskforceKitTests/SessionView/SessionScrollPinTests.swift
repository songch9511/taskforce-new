#if os(macOS)
import Foundation
import Testing
@testable import TaskforceKit

/// 스크롤 (DZ 열린 질문 12, 사용자 승인 "위로 스크롤 중엔 끌어내리지 않기"): 맨 아래를 따라가다가 사용자가 위로 올리면 새 글이 와도 끌어내리지 않고, 맨 아래로 내리면 다시 따라간다.
/// 새 글로 내용이 늘어나는 것은 사용자가 스크롤한 것이 아니다: 내용 · 보이는 크기가 바뀐 변화는 "붙어 있음"의 의도를 바꾸지 않는다
struct SessionScrollPinTests {
    typealias S = SessionScrollSnapshot

    private func snap(maxY: CGFloat, content: CGFloat, visible: CGFloat = 400) -> S { S(visibleMaxY: maxY, contentHeight: content, visibleHeight: visible) }

    @Test func theBottomIsWithinTheSlack() {
        #expect(SessionScrollPin.isAtBottom(snap(maxY: 1000, content: 1000)))
        #expect(SessionScrollPin.isAtBottom(snap(maxY: 976, content: 1000)), "24pt 안")
        #expect(!SessionScrollPin.isAtBottom(snap(maxY: 975, content: 1000)))
        #expect(SessionScrollPin.isAtBottom(snap(maxY: 300, content: 300, visible: 400)), "내용이 보이는 곳보다 짧으면 늘 맨 아래")
        #expect(SessionScrollPin.slack == 24)
    }

    @Test func scrollingUpUnpinsAndScrollingBackDownPinsAgain() {
        let bottom = snap(maxY: 1000, content: 1000)
        let up = snap(maxY: 600, content: 1000)
        #expect(!SessionScrollPin.next(pinned: true, old: bottom, new: up))
        #expect(SessionScrollPin.next(pinned: false, old: up, new: bottom))
        #expect(!SessionScrollPin.next(pinned: false, old: up, new: snap(maxY: 700, content: 1000)), "아직 아래가 아니다")
    }

    @Test func contentGrowingWhilePinnedDoesNotUnpin() {
        // 새 글이 붙어 내용이 늘면 보이는 아래 끝은 더 이상 맨 아래가 아니지만, 사용자가 올린 것이 아니다
        let before = snap(maxY: 1000, content: 1000)
        let grown = snap(maxY: 1000, content: 1200)
        #expect(SessionScrollPin.next(pinned: true, old: before, new: grown))
        let more = snap(maxY: 1000, content: 5000)
        #expect(SessionScrollPin.next(pinned: true, old: grown, new: more))
    }

    @Test func contentGrowingWhileScrolledUpStaysUnpinned() {
        let up = snap(maxY: 600, content: 1000)
        let grown = snap(maxY: 600, content: 1300)
        #expect(!SessionScrollPin.next(pinned: false, old: up, new: grown), "읽던 자리를 끌어내리지 않는다")
    }

    @Test func aResizedViewportKeepsTheIntentAndOnlyFollowsWhenAlreadyAtTheBottom() {
        let before = snap(maxY: 1000, content: 1000, visible: 400)
        let taller = snap(maxY: 1000, content: 1000, visible: 520)
        #expect(SessionScrollPin.next(pinned: true, old: before, new: taller))
        let up = snap(maxY: 600, content: 1000, visible: 400)
        #expect(!SessionScrollPin.next(pinned: false, old: up, new: snap(maxY: 600, content: 1000, visible: 520)))
    }

    @Test func contentShrinkingToFitMakesItPinnedBecauseThereIsNothingBelow() {
        let up = snap(maxY: 600, content: 1000)
        #expect(SessionScrollPin.next(pinned: false, old: up, new: snap(maxY: 500, content: 400, visible: 500)))
    }

    @Test func aClockTickThatChangesNothingKeepsTheState() {
        let up = snap(maxY: 600, content: 1000)
        #expect(!SessionScrollPin.next(pinned: false, old: up, new: up))
        let bottom = snap(maxY: 1000, content: 1000)
        #expect(SessionScrollPin.next(pinned: true, old: bottom, new: bottom))
    }

    @Test func theTailMayScrollOnlyWhenPinned() {
        #expect(SessionScrollPin.shouldFollowNewContent(pinned: true) && !SessionScrollPin.shouldFollowNewContent(pinned: false))
    }
}
#endif
