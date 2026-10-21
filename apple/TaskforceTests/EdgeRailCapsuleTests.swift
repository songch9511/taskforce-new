import AppKit
import Foundation
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// OA U3 11.3 · 5장: 캡슐 레일의 순수 자리 (그리기와 포인터 판정이 같은 값) · 상태 전이 (쉼 → 호버 120ms → 펼침 → 떠남 400ms → 접힘)
@MainActor
struct EdgeRailCapsuleTests {
    typealias L = EdgeRailCapsuleLayout

    func layout(_ mode: L.Mode, bell: Bool = false, compact: Int = 0, rings: Int = 0) -> L {
        L(mode: mode, bell: bell, compactRingCount: compact, ringCount: rings)
    }

    // MARK: 치수 (DS 미리보기를 재서 맞춘 값)

    @Test func theCapsuleHeightsAreTheMeasuredDesignSystemOnes() {
        #expect(L.bellHeight == 44 && L.thirdHeight == 146, "셋째 캡슐의 가장 큰 높이: 칸 넷 (Projects · Chats · On this Mac · More)")
        #expect(layout(.expanded).thirdCapsuleDrawn?.height == 112, "칸이 셋이면(게이트 꺼짐) 지금 그대로 112")
        #expect(L(mode: .expanded, bell: false, compactRingCount: 0, ringCount: 0, controls: [.allWork, .chats, .onThisMac, .more]).thirdCapsuleDrawn?.height == 146)
        #expect(L.sessionsHeight(rings: 4, expanded: true) == 182, "링 넷 + `+`")
        #expect(L.sessionsHeight(rings: 2, expanded: true) == 114 && L.sessionsHeight(rings: 0, expanded: true) == 46)
        #expect(L.sessionsHeight(rings: 3, expanded: false) == 116, "접힘 셋")
        #expect(L.sessionsHeight(rings: 0, expanded: false) == 0, "링 0이면 접힌 캡슐이 없다")
        #expect(Double(L.maxColumnHeight) == 384, "가장 큰 열 384 (44 + 6 + 182 + 6 + 146)")
        #expect(L.windowHeight == L.maxColumnHeight + 8 && L.windowWidth == 4 + 44 + 6)
    }

    @Test func theColumnIsAlwaysCenteredInTheWindowWhateverIsShown() {
        for bell in [false, true] {
            for rings in 0...4 {
                let expanded = layout(.expanded, bell: bell, compact: min(rings, 3), rings: rings)
                let compact = layout(.compact, bell: bell, compact: min(rings, 3), rings: rings)
                for l in [expanded, compact] {
                    let capsules = [l.bellCapsuleDrawn, l.sessionsCapsuleDrawn, l.thirdCapsuleDrawn].compactMap { $0 }
                    guard let top = capsules.map(\.minY).min(), let bottom = capsules.map(\.maxY).max() else { continue }
                    #expect(abs(top - (L.windowHeight - bottom)) < 0.001, "위아래 여백이 같다: 열은 늘 가운데 (bell \(bell) 링 \(rings) \(l.mode))")
                }
            }
        }
    }

    @Test func capsulesStackSixApartWithTheBellOnTopAndSharedXAxis() {
        let l = layout(.expanded, bell: true, compact: 3, rings: 4)
        let bell = l.bellCapsuleDrawn!, sessions = l.sessionsCapsuleDrawn!, third = l.thirdCapsuleDrawn!
        #expect(sessions.minY - bell.maxY == 6 && third.minY - sessions.maxY == 6, "캡슐 사이 6")
        #expect(bell.width == 44 && sessions.width == 44 && third.width == 44 && bell.minX == sessions.minX && sessions.minX == third.minX)
        #expect(bell.height == 44 && sessions.height == 182 && third.height == 112)
        #expect(bell.maxX == L.windowWidth - 6, "화면 끝에서 6 안쪽")
    }

    @Test func itemsAreThirtyTwoCirclesTwoApartSixFromTheCapsuleEnds() {
        let l = layout(.expanded, bell: true, compact: 3, rings: 4)
        let capsule = l.sessionsCapsuleDrawn!
        let rings = (0..<4).map { l.ringDrawn($0)! }
        #expect(rings.allSatisfy { $0.width == 32 && $0.height == 32 && $0.midX == capsule.midX })
        #expect(rings[0].minY - capsule.minY == 6, "캡슐 끝에서 6")
        #expect(rings[1].minY - rings[0].maxY == 2 && rings[2].minY - rings[1].maxY == 2, "칸 사이 2")
        #expect(rings[3].minY - rings[2].maxY == 4, "넘치는 칸 덩어리의 위 2가 더 있다 (DS)")
        let plus = l.plusDrawn!
        #expect(plus.minY - rings[3].maxY == 2 && capsule.maxY - plus.maxY == 6)
        #expect(l.ringDrawn(4) == nil, "링은 넷까지")
        let third = l.thirdCapsuleDrawn!
        let controls = EdgeShellModel.Control.allCases.map { l.controlDrawn($0)! }
        #expect(controls[0].minY - third.minY == 6 && third.maxY - controls[2].maxY == 6 && controls[1].minY - controls[0].maxY == 2)
    }

    @Test func compactScalesTheWholeColumnSeventyTwoPercentFromItsRightCenter() {
        let expanded = layout(.expanded, bell: true, compact: 3, rings: 3)
        let compact = layout(.compact, bell: true, compact: 3, rings: 3)
        #expect(compact.scale == 0.72 && expanded.scale == 1)
        let bell = compact.bellCapsuleFrame!
        #expect(abs(bell.width - 31.68) < 0.001 && abs(bell.height - 31.68) < 0.001, "44 × .72")
        #expect(abs(bell.maxX - (L.windowWidth - 6)) < 0.001, "오른쪽 가장자리는 화면 끝에서 6 그대로")
        #expect(compact.thirdCapsuleFrame == nil && compact.plusFrame == nil, "셋째 캡슐 · `+`는 접혀 있다")
        // 열 높이: bell 44 + 6 + 116 = 166 → 접힘은 .72배 (DS 미리보기: 172 × .72 = 123.84, 셋째 캡슐이 접혀 열이 줄어든 만큼)
        let top = compact.bellCapsuleFrame!.minY, bottom = compact.sessionsCapsuleFrame!.maxY
        #expect(abs((bottom - top) - 166 * 0.72) < 0.001)
        #expect(abs(compact.columnHeight - 166) < 0.001)
    }

    @Test func compactShowsUpToThreeRingsAndHidesAnEmptySessionsCapsule() {
        #expect(layout(.compact, bell: true, compact: 3, rings: 4).shownRings == 3)
        #expect(layout(.compact, bell: true).sessionsCapsuleDrawn == nil, "링이 없으면 캡슐도 없다 (bell만 접힘)")
        #expect(layout(.compact, bell: false, compact: 1, rings: 1).bellCapsuleDrawn == nil && layout(.compact, bell: false, compact: 1, rings: 1).sessionsCapsuleDrawn != nil)
        #expect(layout(.expanded, bell: false, rings: 0).sessionsCapsuleDrawn != nil && layout(.expanded, bell: false, rings: 0).plusDrawn != nil, "펼침은 링 0이어도 `+`")
    }

    @Test func theRestBarIsEightByFortyEightShownAtSeventyTwoPercent() {
        let rest = layout(.rest)
        let drawn = rest.restBarDrawn!
        #expect(drawn.width == 8 && drawn.height == 48)
        let bar = rest.restBarFrame!
        #expect(abs(bar.width - 5.76) < 0.001 && abs(bar.height - 34.56) < 0.001, "DS 미리보기가 그리는 크기 (8 × 48 × .72)")
        #expect(abs(bar.maxX - (L.windowWidth - 6)) < 0.001 && abs(bar.midY - L.windowHeight / 2) < 0.001, "세로 가운데, 화면 끝에서 6")
        #expect(rest.bellCapsuleFrame == nil && rest.sessionsCapsuleFrame == nil && rest.thirdCapsuleFrame == nil)
    }

    @Test func theBellCapsuleAppearingMovesTheColumnByHalfItsStep() {
        let without = layout(.expanded, bell: false, compact: 2, rings: 2)
        let with = layout(.expanded, bell: true, compact: 2, rings: 2)
        let step = (L.bellHeight + L.inset) / 2
        #expect(abs(with.sessionsCapsuleDrawn!.minY - without.sessionsCapsuleDrawn!.minY - step) < 0.001, "열이 가운데를 다시 맞춘다 (위로 25, 아래로 25)")
        #expect(abs(with.thirdCapsuleDrawn!.maxY - without.thirdCapsuleDrawn!.maxY - step) < 0.001)
    }

    // MARK: 포인터 판정 = 그리기

    @Test func hitTestingIsTheCapsuleShapeOnly() {
        let l = layout(.expanded, bell: true, compact: 3, rings: 3)
        let bell = l.bellCapsuleFrame!, sessions = l.sessionsCapsuleFrame!
        #expect(l.hitsRail(CGPoint(x: bell.midX, y: bell.midY)) && l.hitsRail(CGPoint(x: sessions.midX, y: sessions.midY)))
        #expect(!l.hitsRail(CGPoint(x: bell.midX, y: (bell.maxY + sessions.minY) / 2)), "캡슐 사이 6은 레일이 아니다 (클릭이 아래 앱으로 간다)")
        #expect(!l.hitsRail(CGPoint(x: bell.minX - 3, y: bell.midY)) && !l.hitsRail(CGPoint(x: bell.maxX + 3, y: bell.midY)))
        // 둥근 끝: 모서리 바깥은 판정 밖이다
        #expect(!l.hitsRail(CGPoint(x: bell.minX + 1, y: bell.minY + 1)))
        #expect(l.hitsRail(CGPoint(x: bell.midX, y: bell.minY + 0.5)))
    }

    @Test func theHitItemFollowsTheDrawnFrames() {
        let slots = (1...3).map { RailEntry(id: UUID(uuidString: String(format: "E0000000-0000-4000-8000-%012d", $0))!, title: "T\($0)", kind: .running, state: .inProgress) }
        let l = layout(.expanded, bell: true, compact: 3, rings: 3)
        func center(_ rect: CGRect?) -> CGPoint { CGPoint(x: rect!.midX, y: rect!.midY) }
        #expect(l.hit(center(l.bellFrame), slots: slots).bell)
        for (index, slot) in slots.enumerated() { #expect(l.hit(center(l.ringFrame(index)), slots: slots).item == slot.id) }
        #expect(l.hit(center(l.plusFrame), slots: slots).plus)
        for control in EdgeShellModel.Control.allCases { #expect(l.hit(center(l.controlFrame(control)), slots: slots).control == control) }
        // 칸 사이(캡슐 안) · 캡슐 밖은 칸이 아니다
        let capsule = l.sessionsCapsuleFrame!
        #expect(l.hit(CGPoint(x: capsule.midX, y: l.ringFrame(0)!.maxY + 1), slots: slots) == .init(), "칸 사이 2")
        #expect(l.hit(CGPoint(x: -5, y: 5), slots: slots) == .init())
        // 접힘에서는 `+` · 셋째 캡슐 칸이 없다
        let compact = layout(.compact, bell: true, compact: 3, rings: 3)
        #expect(compact.hit(center(compact.ringFrame(0)), slots: slots).item == slots[0].id)
        #expect(compact.plusFrame == nil && compact.controlFrame(.chats) == nil)
    }

    @Test func theRestBarHitStretchesToTheScreenEdgeBecauseSixPointsOfNothingLieBeyondIt() {
        let rest = layout(.rest)
        let bar = rest.restBarFrame!
        #expect(rest.hitsRail(CGPoint(x: bar.midX, y: bar.midY)))
        #expect(rest.hitsRail(CGPoint(x: L.windowWidth - 1, y: bar.midY)), "막대와 화면 끝 사이")
        #expect(!rest.hitsRail(CGPoint(x: bar.minX - 2, y: bar.midY)) && !rest.hitsRail(CGPoint(x: bar.midX, y: bar.maxY + 2)))
        #expect(rest.hit(CGPoint(x: bar.midX, y: bar.midY), slots: []) == .init(), "쉼에서는 칸이 없다")
    }

    // MARK: 창 자리

    @Test func theWindowIsCenteredOnTheScreenMidYAndFlushRight() {
        let frame = L.windowFrame(screenMaxX: 1440, midY: 437.5)
        #expect(frame.maxX == 1440 && frame.midY == 437.5 && frame.size == L.windowSize)
    }

    @Test func theExpandedRailFrameIsTheRealColumnForTheAssistantWindow() {
        let frame = L.expandedRailFrame(screenMaxX: 1440, midY: 450, bell: true, rings: 4)
        #expect(frame.minX == 1440 - 6 - 44 && frame.width == 44 && frame.height == 384 && abs(frame.midY - 450) < 0.001)
        let small = L.expandedRailFrame(screenMaxX: 1440, midY: 450, bell: false, rings: 0)
        #expect(small.height == 46 + 6 + 146 && abs(small.midY - 450) < 0.001, "열이 줄면 가운데에서 줄어든다")
        let threeControls = L.expandedRailFrame(screenMaxX: 1440, midY: 450, bell: false, rings: 0, controls: [.allWork, .chats, .more])
        #expect(abs(threeControls.height - (46 + 6 + 112)) < 0.001, "칸이 셋인 레일의 실제 열")
    }
}

/// 상태 전이는 지금 레일과 같은 규칙이다: 호버 120ms → 펼침, 떠남 400ms → 접힘, 패널이 열려 있으면 펼친 채
@MainActor
struct EdgeRailCapsuleModelTests {
    let time = EdgeShellModelTests.ManualTime()

    func model(rings: Int = 0) -> EdgeShellModel {
        let shell = EdgeShellModel(schedule: time.schedule, clock: time.clock)
        let actions = (1...max(rings, 1)).prefix(rings).map { EdgeShellModelTests.action($0, started: true) }
        shell.update(EdgeWorkSnapshot(open: Array(actions), working: Set(actions.map(\.id)), load: .loaded(problem: nil)))
        return shell
    }

    @Test func restThenHoverOpensItAfterTwelveHundredthsAndLeavingFoldsItAfterFourHundred() {
        let shell = model()
        #expect(shell.railMode == .rest)
        shell.pointer(inside: true)
        time.advance(0.119)
        #expect(shell.railMode == .rest)
        time.advance(0.02)
        #expect(shell.railMode == .expanded && shell.capsuleLayout.expanded)
        shell.pointer(inside: false)
        time.advance(0.39)
        #expect(shell.railMode == .expanded, "떠나 400ms 전에는 그대로")
        time.advance(0.02)
        #expect(shell.railMode == .rest)
    }

    @Test func withRingsTheFoldedRailIsCompactNotRest() {
        let shell = model(rings: 4)
        #expect(shell.railMode == .compact && shell.capsuleLayout.compactRingCount == 3 && shell.capsuleLayout.ringCount == 4)
        #expect(shell.capsuleLayout.shownRings == 3)
        shell.pointer(inside: true)
        time.advance(0.2)
        #expect(shell.capsuleLayout.shownRings == 4, "펼치면 넷")
    }

    @Test func anOpenPanelKeepsTheRailExpandedEvenAfterLeaving() {
        let shell = model(rings: 1)
        shell.openAllWork()
        shell.pointer(inside: true)
        shell.pointer(inside: false)
        time.advance(1)
        #expect(shell.railMode == .expanded && shell.panelOpen)
    }

    @Test func theLayoutCarriesTheShellsControlsAndAnUngatedShellStillKnowsItsOldNotch() {
        let shell = model(rings: 2)
        #expect(shell.capsuleLayout.controls == shell.controls)
        #expect(!shell.issueScreensEnabled, "게이트가 꺼진 셸은 옛 노치 레일을 그린다 (EdgeRailRootView가 가른다)")
    }
}
