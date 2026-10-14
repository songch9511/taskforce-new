import CoreGraphics
import Foundation
import Testing
@testable import TaskforceKit

/// Assistant 창의 자리 · 높이 (OA U1). 좌표는 화면 좌표(아래가 0)이고 창은 위 가장자리(top)를 기준으로 둔다 — 높이가 변해도 위가 움직이지 않는다
struct AssistantWindowGeometryTests {
    typealias G = AssistantWindowGeometry

    /// 1440 × 900 화면, 메뉴 막대 아래 보이는 영역은 y 0 ..< 875
    let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
    /// 레일: 폭 44, 화면 오른쪽 모서리 (펼친 레일 기준)
    var railFrame: CGRect { CGRect(x: 1440 - 44, y: 400, width: 44, height: 319) }

    // MARK: 첫 창

    @Test func theFirstWindowOpensTwelveLeftOfTheOpenPanelAndTopAlignedWithIt() {
        let panel = CGRect(x: 1440 - 44 - 12 - 380, y: 500, width: 380, height: 320)
        let origin = G.firstTopLeft(panelFrame: panel, railFrame: railFrame)
        #expect(origin.x == panel.minX - 12 - G.width)
        #expect(origin.y == panel.maxY, "패널 위 가장자리와 같다")
    }

    @Test func withoutAPanelTheFirstWindowOpensTwelveLeftOfTheRail() {
        let origin = G.firstTopLeft(panelFrame: nil, railFrame: railFrame)
        #expect(origin.x == railFrame.minX - 12 - G.width)
        #expect(origin.y == railFrame.maxY)
    }

    @Test func aSessionTabOnThePanelPushesTheWindowLeftOfTheTab() {
        let panel = CGRect(x: 1440 - 44 - 12 - 380, y: 500, width: 380, height: 320)
        let origin = G.firstTopLeft(panelFrame: panel, railFrame: railFrame, panelOuterInset: 24)
        #expect(origin.x == panel.minX - 24 - 12 - G.width, "패널의 바깥 가장자리(세션 탭 포함)에서 12pt")
    }

    // MARK: 화면 둘 (창은 자기가 있는 화면 기준)

    @Test func aWindowBelongsToTheScreenItCoversMostAndTheNearestWhenOffScreen() {
        let main = AssistantScreen(id: "1", visible: visible)
        let side = AssistantScreen(id: "2", visible: CGRect(x: 1440, y: 100, width: 1920, height: 1000))
        func id(_ frame: CGRect) -> String { G.screen(containing: frame, in: [main, side], fallback: main).id }
        #expect(id(CGRect(x: 1500, y: 300, width: 380, height: 440)) == "2")
        #expect(id(CGRect(x: 200, y: 300, width: 380, height: 440)) == "1")
        #expect(id(CGRect(x: 1440 - 100, y: 300, width: 380, height: 440)) == "2", "걸쳐 있으면 더 많이 덮는 쪽 (280 대 100)")
        #expect(id(CGRect(x: 1440 - 300, y: 300, width: 380, height: 440)) == "1", "300 대 80")
        #expect(id(CGRect(x: 9000, y: 300, width: 380, height: 440)) == "2", "어느 화면에도 없으면 가장 가까운 화면")
        #expect(G.screen(containing: CGRect(x: 0, y: 0, width: 10, height: 10), in: [], fallback: main).id == "1", "화면 목록이 비면 대비책")
    }

    // MARK: 겹쳐 열기

    @Test func eachNewWindowCascadesTwentyFourDownAndLeft() {
        let first = CGPoint(x: 800, y: 700)
        let second = G.cascaded(from: first)
        #expect(second == CGPoint(x: 800 - 24, y: 700 - 24))
        #expect(G.cascaded(from: second) == CGPoint(x: 800 - 48, y: 700 - 48))
        #expect(G.cascadeStep == 24)
    }

    // MARK: 화면 안 · 레일 밖

    @Test func aWindowStaysInsideTheVisibleFrameAndNeverCoversTheRail() {
        // 레일 쪽으로 너무 간 창은 레일 왼쪽 12pt 안쪽으로
        let overRail = G.clamped(topLeft: CGPoint(x: 1300, y: 700), height: 400, visible: visible, railWidth: 44)
        #expect(overRail.x + G.width <= 1440 - 44, "레일을 덮지 않는다: \(overRail)")
        // 왼쪽 밖으로 간 창은 화면 안으로
        #expect(G.clamped(topLeft: CGPoint(x: -500, y: 700), height: 400, visible: visible, railWidth: 44).x == 0)
        // 위로 너무 간 창: 위 가장자리가 보이는 영역 위를 넘지 않는다
        #expect(G.clamped(topLeft: CGPoint(x: 100, y: 5000), height: 400, visible: visible, railWidth: 44).y == visible.maxY)
        // 아래로 너무 간 창: 아래 가장자리가 보이는 영역 아래를 넘지 않는다
        let low = G.clamped(topLeft: CGPoint(x: 100, y: 50), height: 400, visible: visible, railWidth: 44)
        #expect(low.y - 400 >= visible.minY)
        // 이미 안에 있으면 그대로
        let fine = CGPoint(x: 600, y: 700)
        #expect(G.clamped(topLeft: fine, height: 400, visible: visible, railWidth: 44) == fine)
    }

    @Test func aTallWindowBiggerThanTheVisibleFrameStillKeepsItsTopVisible() {
        let small = CGRect(x: 0, y: 0, width: 1440, height: 300)
        let clamped = G.clamped(topLeft: CGPoint(x: 100, y: 200), height: 560, visible: small, railWidth: 44)
        #expect(clamped.y == small.maxY, "높이가 화면보다 크면 위를 맞춘다 (머리가 늘 보인다)")
    }

    @Test func aRememberedPositionOnAGoneDisplayMovesBackInsideTheCurrentOne() {
        let remembered = CGPoint(x: 3000, y: 1800)
        let moved = G.clamped(topLeft: remembered, height: 440, visible: visible, railWidth: 44)
        #expect(moved.x + G.width <= visible.maxX - 44 && moved.y <= visible.maxY && moved.y - 440 >= 0)
    }

    // MARK: 높이

    @Test func heightHugsContentAndScrollsAtFiveSixty() {
        #expect(G.maxHeight == 560)
        #expect(G.height(content: 300, isEmpty: false) == 300)
        #expect(G.height(content: 559, isEmpty: false) == 559)
        #expect(G.height(content: 560, isEmpty: false) == 560)
        #expect(G.height(content: 2000, isEmpty: false) == 560, "560을 넘으면 본문이 스크롤한다")
    }

    @Test func anEmptyConversationHasAFloorOfFourForty() {
        #expect(G.emptyHeight == 440)
        #expect(G.height(content: 216, isEmpty: true) == 440)
        #expect(G.height(content: 500, isEmpty: true) == 500, "채워지면 내용을 따른다")
        #expect(G.height(content: 216, isEmpty: false) == 216, "글이 있는 대화는 내용에 맞춘다")
    }

    // MARK: 키보드 이동

    @Test func arrowKeysMoveTheFocusedHandleByEight() {
        let origin = CGPoint(x: 500, y: 600)
        #expect(G.moved(origin, by: .left) == CGPoint(x: 492, y: 600))
        #expect(G.moved(origin, by: .right) == CGPoint(x: 508, y: 600))
        #expect(G.moved(origin, by: .up) == CGPoint(x: 500, y: 608))
        #expect(G.moved(origin, by: .down) == CGPoint(x: 500, y: 592))
        #expect(G.keyboardStep == 8)
    }

    @Test func theWindowIsAlwaysThreeEightyWide() {
        #expect(G.width == 380)
    }
}
