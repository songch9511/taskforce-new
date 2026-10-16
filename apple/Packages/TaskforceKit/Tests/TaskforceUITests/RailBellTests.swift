import SwiftUI
import Testing
import TaskforceKit
@testable import TaskforceUI

/// OA U3 11.2 · 5.3: Taskforce bell의 이름 · 선택됨과 needs-you 움직임(도착 → 숨쉬기 → echo → 흔들림, 움직임 줄이기는 불투명도만)
@MainActor
struct RailBellTests {
    typealias M = NeedsYouMotion

    @Test func theBellIsAButtonNamedByItsStateAndSelectedWhileTheConversationIsOpen() {
        let ringing = TaskforceBell(rings: true, selected: false, count: 3)
        #expect(ringing.accessibilityName == "Taskforce · Needs your answer, 3 items")
        #expect(RailBell.glyph == 16, "DS size={16}, 확대 없음")
        #expect(TFIcon.taskforce.assetName == "icon/bell", "Settings Reports와 같은 Lucide bell")
        #expect(TFIcon.taskforce == .reports, "별도 case가 아니라 같은 글리프의 이름이다")
    }

    @Test func theArrivalBouncesThroughTheDesignKeyframes() {
        #expect(M.frame(elapsed: 0, reduceMotion: false, bell: false).scale == 0.6)
        #expect(M.frame(elapsed: 0, reduceMotion: false, bell: false).opacity == 0)
        let peak = M.frame(elapsed: TFMotion.needsYouArrive * 0.45, reduceMotion: false, bell: false)
        #expect(abs(peak.scale - 1.18) < 0.001 && peak.opacity == 1)
        let undershoot = M.frame(elapsed: TFMotion.needsYouArrive * 0.72, reduceMotion: false, bell: false)
        #expect(abs(undershoot.scale - 0.96) < 0.001)
        let settled = M.frame(elapsed: TFMotion.needsYouArrive - 0.0001, reduceMotion: false, bell: false)
        #expect(abs(settled.scale - 1) < 0.01 && settled.opacity == 1)
    }

    @Test func afterTheArrivalItBreathesToOnePointOneTwoEveryTwoPointFourSeconds() {
        let start = TFMotion.needsYouArrive
        let rest = M.frame(elapsed: start, reduceMotion: false, bell: false)
        let peak = M.frame(elapsed: start + 1.2, reduceMotion: false, bell: false)
        let again = M.frame(elapsed: start + 2.4, reduceMotion: false, bell: false)
        #expect(rest.scale == 1 && abs(peak.scale - 1.12) < 0.0001 && abs(again.scale - 1) < 0.0001)
        #expect(TFMotion.needsYouBreath == 2.4)
        // 한 주기 안에서 1 ~ 1.12를 벗어나지 않는다
        for step in 0...240 {
            let scale = M.frame(elapsed: start + Double(step) * 0.01, reduceMotion: false, bell: false).scale
            #expect(scale >= 1 - 0.0001 && scale <= 1.12 + 0.0001)
        }
    }

    @Test func eachBreathSendsOneEchoThatFadesOutToOnePointSevenFiveTimes() {
        let start = TFMotion.needsYouArrive
        let begin = M.frame(elapsed: start, reduceMotion: false, bell: false)
        #expect(begin.echoScale == 1 && abs(begin.echoOpacity - 0.6) < 0.0001)
        let late = M.frame(elapsed: start + 2.4 * 0.7, reduceMotion: false, bell: false)
        #expect(abs(late.echoScale - 1.75) < 0.001 && late.echoOpacity < 0.001, "70% 지점에서 0")
        #expect(M.frame(elapsed: start + 2.0, reduceMotion: false, bell: false).echoOpacity == 0)
        var last = 0.6
        for step in 1...70 {
            let opacity = M.frame(elapsed: start + 2.4 * Double(step) / 100, reduceMotion: false, bell: false).echoOpacity
            #expect(opacity <= last + 0.0001, "echo는 사라지기만 한다")
            last = opacity
        }
    }

    @Test func onlyTheBellSwingsAndOnlyInTheFirstThirtyPercentOfABreath() {
        let start = TFMotion.needsYouArrive
        let ringAt5 = M.frame(elapsed: start + 2.4 * 0.05, reduceMotion: false, bell: true)
        let ringAt10 = M.frame(elapsed: start + 2.4 * 0.10, reduceMotion: false, bell: true)
        #expect(abs(ringAt5.rotation + 14) < 0.001 && abs(ringAt10.rotation - 12) < 0.001, "-14° → 12°")
        #expect(M.frame(elapsed: start + 2.4 * 0.5, reduceMotion: false, bell: true).rotation == 0)
        #expect(M.frame(elapsed: start + 2.4 * 0.05, reduceMotion: false, bell: false).rotation == 0, "세션 링은 흔들리지 않는다")
        for step in 0...1000 {
            let rotation = M.frame(elapsed: start + 2.4 * Double(step) / 1000, reduceMotion: false, bell: true).rotation
            #expect(abs(rotation) <= 14.0001)
            if Double(step) / 1000 >= 0.30 { #expect(abs(rotation) < 0.0001) }
        }
    }

    @Test func reducedMotionIsOpacityOnlyBetweenOneAndPointFortyFive() {
        for step in 0...500 {
            let frame = M.frame(elapsed: Double(step) * 0.01, reduceMotion: true, bell: true)
            #expect(frame.scale == 1 && frame.rotation == 0 && frame.echoOpacity == 0 && frame.echoScale == 1, "크기 · 각도 · echo가 없다")
            #expect(frame.opacity >= 0.45 - 0.0001 && frame.opacity <= 1.0001)
        }
        #expect(M.frame(elapsed: 0, reduceMotion: true, bell: false).opacity == 1)
        #expect(abs(M.frame(elapsed: 1.2, reduceMotion: true, bell: false).opacity - 0.45) < 0.0001)
        #expect(abs(M.frame(elapsed: 2.4, reduceMotion: true, bell: false).opacity - 1) < 0.0001)
    }

    @Test func aMomentBeforeArrivalIsAtRest() {
        #expect(M.frame(elapsed: -1, reduceMotion: false, bell: true) == .rest)
        #expect(M.Frame.rest.scale == 1 && M.Frame.rest.opacity == 1 && M.Frame.rest.echoOpacity == 0 && M.Frame.rest.rotation == 0)
    }

    @Test func theBellStaysWhiteInBothThemes() throws {
        // 레일의 ink 토큰은 두 모양 모두 흰색이다 (bell은 이 색 하나만 쓴다: 주황이 되지 않는다)
        let ink = try #require(TokenCatalog.resolve("bezel/ink"))
        #expect(ink.light == RGBA("#FFFFFF") && ink.dark == RGBA("#FFFFFF"))
    }
}
