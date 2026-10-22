import AppKit
import Foundation
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// OA PR-D2 (사용자 결정 2026-10-22): 레일이 여는 패널(Projects · Chats · Sessions · More …)은 레일의 중심선에 세로 가운데로 선다. 보이는 화면 안으로 들어오고,
/// 레일과의 가로 간격은 그대로이며, 내용 높이가 바뀌면 위아래로 절반씩 다시 가운데로 간다. 세션 보기 창(레일의 링으로 연 Claude 세션 패널 · 메인 패널 왼쪽의 세션 패널)은 지금 자리 그대로다.
@MainActor
struct EdgePanelPlacementTests {
    typealias M = EdgePanelMetrics

    /// 1440 × 900 화면: 메뉴 막대 25(위) · Dock 70(아래)을 뺀 보이는 영역
    private let visible = CGRect(x: 0, y: 70, width: 1440, height: 805)
    private let centerY: CGFloat = 450

    // MARK: 세로 자리 (순수 계산)

    @Test func aShortPanelIsCenteredOnTheRailCenterLine() {
        let y = M.centeredOriginY(height: 320, centerY: centerY, visible: visible)
        #expect(y == 290 && y + 320 / 2 == centerY, "아래 모서리 290, 중심 450")
        let tiny = M.centeredOriginY(height: 120, centerY: centerY, visible: visible)
        #expect(tiny + 60 == centerY, "내용에 맞춘 아주 짧은 패널도 가운데")
    }

    @Test func aTallPanelIsCenteredToo() {
        let y = M.centeredOriginY(height: M.maxHeight, centerY: centerY, visible: visible)
        #expect(y == 190 && y + M.maxHeight / 2 == centerY)
        #expect(y >= visible.minY && y + M.maxHeight <= visible.maxY, "보이는 화면 안")
    }

    @Test func aPanelNearTheTopOrBottomEdgeIsPushedBackInsideTheVisibleScreen() {
        // 중심선이 위쪽으로 쏠린 화면: 위 끝(메뉴 막대 아래)에 닿는다
        let top = M.centeredOriginY(height: 520, centerY: 850, visible: visible)
        #expect(top + 520 == visible.maxY, "위 끝에 붙는다")
        // 아래쪽으로 쏠린 화면: 아래 끝(Dock 위)에 닿는다
        let bottom = M.centeredOriginY(height: 520, centerY: 100, visible: visible)
        #expect(bottom == visible.minY, "아래 끝에 붙는다")
        // 딱 맞는 높이는 그 높이 그대로 (위아래 둘 다 닿는다)
        let exact = M.centeredOriginY(height: visible.height, centerY: centerY, visible: visible)
        #expect(exact == visible.minY && exact + visible.height == visible.maxY)
    }

    @Test func aPanelTallerThanTheVisibleScreenKeepsItsHeaderOnScreenAndOverflowsBelow() {
        let small = CGRect(x: 0, y: 40, width: 1024, height: 450)
        let y = M.centeredOriginY(height: 520, centerY: 265, visible: small)
        #expect(y + 520 == small.maxY, "머리(위)를 맞춘다")
        #expect(y < small.minY, "넘치는 쪽은 아래다")
        #expect(y > -520, "그래도 화면 안에 걸쳐 있다")
    }

    @Test func aSecondDisplayAboveOrBesideTheMainOneWorksInItsOwnCoordinates() {
        let above = CGRect(x: -200, y: 900, width: 1600, height: 1000)
        let y = M.centeredOriginY(height: 400, centerY: 1400, visible: above)
        #expect(y == 1200 && y >= above.minY && y + 400 <= above.maxY)
        let clamped = M.centeredOriginY(height: 400, centerY: 920, visible: above)
        #expect(clamped == above.minY, "그 화면의 아래 끝에 붙는다")
    }

    @Test func theHorizontalGapToTheRailStaysAsItWasWhateverTheHeightIs() {
        for capsule in [true, false] {
            for height in [CGFloat(120), 320, 520] {
                let old = M.frame(height: height, railTop: 780, screenMaxX: 1440, capsule: capsule)
                let new = M.centeredFrame(height: height, centerY: centerY, visible: visible, screenMaxX: 1440, capsule: capsule)
                #expect(new.minX == old.minX && new.maxX == old.maxX && new.width == M.width && new.height == height, "가로 · 폭 · 높이는 그대로, 세로만 가운데")
            }
        }
        let capsuleFrame = M.centeredFrame(height: 320, centerY: centerY, visible: visible, screenMaxX: 1440, capsule: true)
        #expect(abs(capsuleFrame.maxX - (1440 - 6 - 44 - 12)) < 0.001, "레일(끝에서 6 안쪽 · 폭 44) 왼쪽 12pt (\(capsuleFrame.maxX))")
    }

    @Test func aHeightChangeRecentersByHalfTheChangeOnBothEdgesWithoutMovingTheCenter() {
        let before = M.centeredFrame(height: 320, centerY: centerY, visible: visible, screenMaxX: 1440, capsule: true)
        let grown = M.centeredFrame(height: 460, centerY: centerY, visible: visible, screenMaxX: 1440, capsule: true)
        let shrunk = M.centeredFrame(height: 200, centerY: centerY, visible: visible, screenMaxX: 1440, capsule: true)
        #expect(grown.midY == before.midY && shrunk.midY == before.midY, "중심은 그대로")
        #expect(grown.maxY - before.maxY == 70 && before.minY - grown.minY == 70, "140 커지면 위로 70 · 아래로 70")
        #expect(before.maxY - shrunk.maxY == 60 && shrunk.minY - before.minY == 60, "120 줄면 위가 60 · 아래가 60 들어온다")
        // 창은 한 높이에서 다른 높이로 점프하지 않는다: 중간 높이들은 중심이 늘 같다
        for height in stride(from: CGFloat(200), through: 520, by: 20) {
            let frame = M.centeredFrame(height: height, centerY: centerY, visible: visible, screenMaxX: 1440, capsule: true)
            #expect(frame.midY == centerY, Comment(rawValue: "높이 \(height)"))
        }
    }

    @Test func centeringAnAlreadyPlacedWindowKeepsItsXAndSize() {
        let card = NSRect(x: 1180, y: 300, width: 170, height: 76)
        let centered = M.centered(card, centerY: centerY, visible: visible)
        #expect(centered.minX == 1180 && centered.size == card.size && centered.midY == centerY)
        let low = M.centered(card, centerY: 60, visible: visible)
        #expect(low.minY == visible.minY, "보이는 화면 안으로")
    }

    // MARK: 창 (메인 패널 · 세션 보기 창 · 세션 패널)

    private func screen() throws -> NSScreen { try #require(EdgeRailPanelController.screen, "화면이 있어야 창 자리를 잰다") }

    @Test func theRailCenterLineIsTheScreenMidYBecauseTheCapsuleColumnGrowsFromTheWindowCenter() throws {
        let screen = try screen()
        #expect(EdgeRailPanelController.railCenterY(on: screen) == screen.frame.midY)
        let window = EdgeRailCapsuleLayout.windowFrame(screenMaxX: screen.frame.maxX, midY: EdgeRailPanelController.railCenterY(on: screen))
        #expect(window.midY == screen.frame.midY, "레일 창의 세로 가운데 = 중심선")
        // 열이 얼마나 자라도 그 중심이 창 가운데다 (`EdgeRailCapsuleTests`): 링 · bell이 늘어도 중심선은 그대로
        for rings in 0...4 {
            let layout = EdgeRailCapsuleLayout(mode: .expanded, bell: rings.isMultiple(of: 2), compactRingCount: min(rings, 3), ringCount: rings, sessionsButton: true)
            let top = layout.bellCapsuleDrawn?.minY ?? layout.sessionsCapsuleDrawn!.minY
            let bottom = layout.thirdCapsuleDrawn!.maxY
            #expect(abs((top + bottom) / 2 - EdgeRailCapsuleLayout.windowHeight / 2) < 0.001)
        }
    }

    /// 새 Issues 화면의 메인 패널(Projects · Chats · Sessions …)은 가운데, 게이트가 꺼진 노치 레일은 지금 그대로 위에서 120
    @Test func theMainPanelWindowIsCenteredForTheCapsuleRailAndKeepsTheOldTopForTheNotchRail() throws {
        let screen = try screen()
        let gated = EdgeExternalSessionsTests().make()
        let controller = EdgePanelController(shell: gated.shell, chat: nil)
        for body in [CGFloat(60), 200, 480] {
            controller.presentation.bodyHeight = body
            let frame = try #require(controller.targetFrame())
            let height = M.height(body: body, footer: 0, fits: true)
            #expect(frame.height == height)
            let expected = M.centeredFrame(height: height, centerY: screen.frame.midY, visible: screen.visibleFrame, screenMaxX: screen.frame.maxX, capsule: true)
            #expect(frame == expected)
            if screen.frame.midY - height / 2 >= screen.visibleFrame.minY, screen.frame.midY + height / 2 <= screen.visibleFrame.maxY {
                #expect(abs(frame.midY - screen.frame.midY) < 0.001, Comment(rawValue: "본문 \(body): 레일 중심선에 가운데"))
            }
        }
        let notch = EdgeExternalSessionsTests().make(gated: false)
        let legacy = EdgePanelController(shell: notch.shell, chat: nil)
        legacy.presentation.bodyHeight = 200
        let old = try #require(legacy.targetFrame())
        #expect(old.maxY == EdgeRailPanelController.railTop(on: screen), "노치 레일은 위가 화면 위에서 120 그대로")
        #expect(old.height == M.height(body: 200, footer: 0, fits: false) && old.height >= M.minHeight)
    }

    @Test func everyViewOfTheMainPanelSharesTheCenteredPlacement() throws {
        let gated = EdgeExternalSessionsTests().make()
        let controller = EdgePanelController(shell: gated.shell, chat: nil)
        controller.presentation.bodyHeight = 240
        let first = try #require(controller.targetFrame())
        for view in EdgeShellModel.View.allCases where view != .claudeApp {
            gated.shell.openPanel(view)
            #expect(try #require(controller.targetFrame()) == first, Comment(rawValue: "\(view): 같은 높이면 같은 자리 (화면마다 따로 자리를 두지 않는다)"))
        }
        gated.shell.dismiss()
    }

    @Test func theSessionViewWindowsKeepTheirPlacementTheOneBesideTheRailStaysAtTheTopAndTheOneBesideAPanelAlignsToItsTop() async throws {
        let screen = try screen()
        let w = await EdgeSessionsTests().rig(rows: [1], live: [EdgeSessionsTests.live(1, .busy)])
        let claude = EdgeClaudeAppPanelController(shell: w.shell)
        // 레일의 링으로 연 한 패널: 지금 자리 그대로(위가 화면 위에서 120)
        w.shell.openRailEntry(w.shell.slots.first { $0.source == .claudeApp(sessionID: EdgeSessionsTests.id(1)) }!)
        #expect(w.shell.view == .claudeApp)
        claude.presentation.headHeight = 40
        claude.presentation.bodyHeight = 100
        let standalone = try #require(claude.targetFrame())
        #expect(standalone.maxY == EdgeRailPanelController.railTop(on: screen), "세션 보기 한 패널은 가운데로 가지 않는다")
        #expect(standalone == M.frame(height: standalone.height, railTop: EdgeRailPanelController.railTop(on: screen), screenMaxX: screen.frame.maxX, capsule: true))
        // 메인 패널 왼쪽의 세션 패널 · Claude 세션 패널: 메인 패널(가운데)의 위에 맞춘다 (메인 패널이 가운데로 가면 따라간다)
        let main = M.centeredFrame(height: 300, centerY: screen.frame.midY, visible: screen.visibleFrame, screenMaxX: screen.frame.maxX, capsule: true)
        let beside = EdgeSessionPanelController.frame(issuePanel: main, height: 400)
        #expect(beside.maxY == main.maxY && beside.maxX == main.minX - SessionPanelMetrics.panelGap, "세션 패널은 메인 패널의 위 · 왼쪽 40")
        w.shell.dismiss()
        w.shell.openSessions()
        w.shell.openDesktopSession(EdgeSessionsTests.id(1), from: .list)
        claude.mainPanelFrame = { main }
        let left = try #require(claude.targetFrame())
        #expect(left.maxY == main.maxY && left.maxX == main.minX - SessionPanelMetrics.panelGap, "Sessions 왼쪽 Claude 세션 패널도 같은 규칙")
        w.shell.dismiss()
    }

    // MARK: 실제 레일 창과 실제 패널 창 (사용자 확인: 짧은 레일 · 긴 패널 · 낮거나 높은 레일)

    /// 캡슐 레일이 켜진 실제 컨트롤러 (창은 만들되 키 · 클릭으로 접히지 않게): 링 `rings`개
    private func controller(rings: Int) async throws -> EdgeShellController {
        let account = try AppChatAccount.make()
        let runtime = ChatRuntime(gateway: IssueSampleGateway(), contextGateway: IssueSampleContextGateway(), scope: account.scope, now: { Date() }, issueScreens: true)
        let controller = EdgeShellController(launcher: LauncherModel(configurationError: "test"), chat: runtime, assistantWindows: false)
        controller.ignoresExternalDismissal = true
        controller.shell.accountChanged(SampleData.userID)
        let actions = (1...max(rings, 1)).prefix(rings).map { EdgeShellModelTests.action($0, started: true) }
        controller.shell.update(EdgeWorkSnapshot(open: Array(actions), working: Set(actions.map(\.id)), load: .loaded(problem: nil)))
        return controller
    }

    /// 레일의 모든 캡슐을 펼친 모양 그대로(줄이기 전) 합친 가운데 (화면 좌표): 레일 창에서 따로 계산해 `centerLineY`와 견준다
    private func independentRailCenter(_ controller: EdgeShellController) -> CGFloat? {
        let layout = controller.shell.capsuleLayout
        let drawn = [layout.bellCapsuleDrawn, layout.sessionsCapsuleDrawn, layout.thirdCapsuleDrawn].compactMap { $0 }
        guard let top = drawn.map(\.minY).min(), let bottom = drawn.map(\.maxY).max() else { return nil }
        return controller.rail.panel.frame.maxY - (top + bottom) / 2
    }

    @Test func theMainPanelStandsOnTheMidpointOfTheWholeRailForAShortAndATallRailAndAShortAndATallPanel() async throws {
        let screen = try screen()
        for rings in 0...4 {
            for body in [CGFloat(80), 300, 900] {
                let c = try await controller(rings: rings)
                c.rail.show()
                defer {
                    c.shell.dismiss()
                    c.panel.hide()
                    c.rail.hide()
                }
                c.shell.openAllWork()
                let center = try #require(c.rail.centerLineY, Comment(rawValue: "링 \(rings): 레일이 떠 있다"))
                #expect(abs(center - (try #require(independentRailCenter(c)))) < 0.001, "레일 전체(모든 캡슐)의 가운데")
                #expect(abs(center - screen.frame.midY) < 2, Comment(rawValue: "링 \(rings): 열은 늘 화면 세로 가운데에서 자란다 (창 자리는 화소에 맞춰 1pt 안쪽으로 어긋날 수 있다: \(center) · \(screen.frame.midY))"))
                c.panel.presentation.bodyHeight = body
                let target = try #require(c.panel.targetFrame())
                let height = M.height(body: body, footer: 0, fits: true)
                #expect(target.height == height && height <= M.maxHeight)
                #expect(abs(target.midY - center) < 0.001, Comment(rawValue: "링 \(rings) 본문 \(body): 패널 가운데 = 레일 가운데"))
                #expect(target.minY >= screen.visibleFrame.minY - 0.001 && target.maxY <= screen.visibleFrame.maxY + 0.001, "보이는 화면 안")
                // 실제 창: 패널을 실제로 열면 창이 그려진 내용의 높이를 다시 재고(본문 높이는 화면이 정한다), 그 높이로도 레일 가운데에 선다 (가로는 여는 움직임 중일 수 있다)
                c.followPanel()
                // 그려진 내용의 높이가 정해지면(비동기) 컨트롤러의 관찰이 창을 그 높이로 다시 가운데에 맞춘다 (여기서 따로 맞추기를 부르지 않는다)
                var settled = false
                for _ in 0..<300 {
                    // (0.5pt 이하의 차이는 화소에 맞춘 창 자리라 움직이지 않는다: `EdgePanelMotion.move`)
                    if let real = c.panel.targetFrame(), abs(c.panel.panel.frame.midY - real.midY) <= 0.5, abs(c.panel.panel.frame.height - real.height) <= 0.5 {
                        settled = true
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                let real = try #require(c.panel.targetFrame())
                #expect(settled, Comment(rawValue: "링 \(rings): 창 \(c.panel.panel.frame) · 목표 \(real)"))
                #expect(abs(real.midY - center) < 0.001, Comment(rawValue: "링 \(rings): 그려진 내용(\(real.height)pt)으로도 가운데"))
            }
        }
    }

    @Test func thePanelFollowsARailThatIsLowOrHighAndStaysInsideTheVisibleScreenWhenTheRailIsAtAnEdge() async throws {
        let screen = try screen()
        let c = try await controller(rings: 2)
        c.rail.show()
        defer {
            c.shell.dismiss()
            c.panel.hide()
            c.rail.hide()
        }
        c.shell.openAllWork()
        c.panel.presentation.bodyHeight = 900
        c.followPanel()
        let home = c.rail.panel.frame
        func panelFrame(afterMovingTheRailBy dy: CGFloat) throws -> (target: NSRect, center: CGFloat) {
            c.rail.panel.setFrame(home.offsetBy(dx: 0, dy: dy), display: true)
            let center = try #require(c.rail.centerLineY)
            // 열려 있는 창의 본문 높이는 화면에 그려진 실제 내용으로 다시 재어진다: 긴 패널(520 상한)로 계산하려고 지금 값을 다시 준다
            c.panel.presentation.bodyHeight = 900
            return (try #require(c.panel.targetFrame()), center)
        }
        // 낮은 레일 · 높은 레일: 패널은 그 레일의 가운데를 따라간다 (잘리지 않는 한)
        let room = (screen.visibleFrame.height - M.maxHeight) / 2 - 1
        for dy in [-room / 2, room / 2, 0] {
            let (target, center) = try panelFrame(afterMovingTheRailBy: dy)
            #expect(abs(center - (screen.frame.midY + dy)) < 2, Comment(rawValue: "레일이 \(dy)만큼 옮겨졌다 (\(center))"))
            #expect(abs(target.midY - center) < 0.001, Comment(rawValue: "레일이 \(dy) 옮겨져도 패널 가운데 = 레일 가운데"))
        }
        // 레일이 화면 위 · 아래 끝에 붙은 경우: 520pt 패널도 보이는 화면 안에 들어오고 레일 쪽에 붙는다
        // (AppKit이 화면 끝의 창을 안쪽으로 되돌릴 수 있어 레일의 실제 가운데에서 기대값을 구한다)
        let top = try panelFrame(afterMovingTheRailBy: screen.frame.maxY - home.midY - 30)
        let topExpected = M.centeredOriginY(height: M.maxHeight, centerY: top.center, visible: screen.visibleFrame)
        #expect(abs(top.target.minY - topExpected) < 0.001 && top.target.maxY <= screen.visibleFrame.maxY + 0.001 && top.target.minY >= screen.visibleFrame.minY - 0.001, Comment(rawValue: "위 끝: 보이는 화면 안 (\(top.target) · 레일 \(top.center))"))
        let bottom = try panelFrame(afterMovingTheRailBy: screen.frame.minY - home.midY + 30)
        let bottomExpected = M.centeredOriginY(height: M.maxHeight, centerY: bottom.center, visible: screen.visibleFrame)
        #expect(abs(bottom.target.minY - bottomExpected) < 0.001 && bottom.target.maxY <= screen.visibleFrame.maxY + 0.001 && bottom.target.minY >= screen.visibleFrame.minY - 0.001, Comment(rawValue: "아래 끝: 보이는 화면 안 (\(bottom.target) · 레일 \(bottom.center))"))
        // 열려 있는 실제 패널 창도 다음 맞추기에서 그 자리로 간다
        let settled = try panelFrame(afterMovingTheRailBy: 0).target
        #expect(await until(c.panel) { abs($0.panel.frame.midY - settled.midY) < 0.5 }, "열려 있는 실제 패널 창도 다음 맞추기에서 레일 가운데로 돌아온다")
    }

    /// 어두운 모양에서도 같은 자리다 (자리 계산은 모양과 무관하다)
    @Test func theDarkAppearanceDoesNotChangeThePlacement() async throws {
        let screen = try screen()
        let c = try await controller(rings: 3)
        c.rail.show()
        defer {
            c.shell.dismiss()
            c.panel.hide()
            c.rail.hide()
        }
        c.shell.openAllWork()
        c.panel.presentation.bodyHeight = 300
        let light = try #require(c.panel.targetFrame())
        c.panel.panel.appearance = NSAppearance(named: .darkAqua)
        c.rail.panel.appearance = NSAppearance(named: .darkAqua)
        let dark = try #require(c.panel.targetFrame())
        #expect(light == dark && abs(dark.midY - screen.frame.midY) < 2, Comment(rawValue: "\(dark.midY) · \(screen.frame.midY)"))
    }

    private func until(_ panel: EdgePanelController, _ condition: @MainActor (EdgePanelController) -> Bool) async -> Bool {
        for _ in 0..<200 {
            panel.fitToContent()
            if condition(panel) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition(panel)
    }

    @Test func movingAWindowSkipsSubPointChangesAndAppliesTheRestAtOnceWithoutMotionOrOffScreen() {
        let panel = EdgeKeyPanel(contentRect: NSRect(x: 100, y: 100, width: 380, height: 300), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let start = panel.frame
        EdgePanelMotion.move(panel, to: start.offsetBy(dx: 0, dy: 0.3), reduceMotion: false)
        #expect(panel.frame == start, "0.5pt보다 작은 차이는 움직이지 않는다")
        let target = NSRect(x: 100, y: 60, width: 380, height: 380)
        EdgePanelMotion.move(panel, to: target, reduceMotion: true)
        #expect(panel.frame == target, "움직임 줄이기면 바로")
        let hidden = NSRect(x: 100, y: 10, width: 380, height: 420)
        EdgePanelMotion.move(panel, to: hidden, reduceMotion: false)
        #expect(panel.frame == hidden, "보이지 않는 창은 애니메이션 없이 바로")
        #expect(EdgePanelMetrics.recenterDuration == TFMotion.panelFade)
    }
}
