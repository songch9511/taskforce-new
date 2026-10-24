import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftUI
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// OA U3 16.1: 캡슐 레일의 ⋯는 macOS 기본 메뉴 대신 DS 카드(EdgeRail "More open")를 연다. 게이트 켜짐에서만, 게이트 꺼짐 · Release는 그대로 `NSMenu`다.
/// 키보드(↑ ↓ Return Esc) · VoiceOver 메뉴 역할 · 바깥 클릭으로 닫힘 · ⋯ 위 클릭은 토글 · 닫히면 포커스가 ⋯로 돌아온다
@MainActor
struct EdgeRailCapsuleMoreTests {
    /// 레일은 화면 오른쪽 끝에 붙는다: 자리는 이 Mac 화면의 보이는 영역에서 잡는다.
    /// 고정 좌표(x 1390)는 CI 러너의 1024 폭 화면 밖이라 카드가 화면 안으로 밀려 ⋯ 옆이 아니게 된다
    private var screen: CGRect { NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1024, height: 768) }
    private var capsule: CGRect { CGRect(x: screen.maxX - 50, y: screen.minY + 300, width: 44, height: 112) }

    private func parent() -> NSPanel {
        let panel = EdgePassivePanel(contentRect: CGRect(x: screen.maxX - 140, y: screen.minY + 200, width: 140, height: 400), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        return panel
    }

    private func model(picked: @escaping (String) -> Void = { _ in }) -> ContextMenuModel {
        ContextMenuModel(items: [
            ContextMenuItem(id: "connections", icon: .connections, label: "Connections", action: { picked("connections") }),
            ContextMenuItem(id: "settings", icon: .settings, label: "Settings", action: { picked("settings") }),
        ])
    }

    private func key(_ code: Int, in window: NSWindow?) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window?.windowNumber ?? 0, context: nil,
            characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: UInt16(code)
        ))
    }

    private func click(in window: NSWindow?) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1
        ))
    }

    // MARK: 자리 · 모양 · VoiceOver

    @Test func theCardOpensBesideTheThirdCapsuleAsAMenuForVoiceOver() throws {
        let card = EdgeRailMoreCard()
        card.shows = false
        let host = parent()
        card.present(model: model(), label: "More", capsule: capsule, over: host) {}
        let window = try #require(card.window)
        let visible = (host.screen ?? NSScreen.main)?.visibleFrame ?? host.frame
        let beside = RailMoreCardGeometry.frame(size: window.frame.size, capsule: capsule, visible: visible)
        // 사용자 결정(2026-10-22): More 카드는 가운데로 옮기지 않는다. ⋯ 옆(DS `beside`): 셋째 캡슐 왼쪽 10pt, 아래 끝은 그 캡슐과 같다
        #expect(window.frame == beside, "DS beside 그대로 (레일 중심선에 가운데 맞춤이 아니다)")
        #expect(window.frame.maxX == capsule.minX - RailMoreCardGeometry.gap, "셋째 캡슐 왼쪽 10pt")
        #expect(window.frame.minY == min(capsule.minY, visible.maxY - window.frame.height), "아래 끝은 셋째 캡슐과 같다 (화면 위로 넘칠 때만 안으로)")
        #expect(abs(window.frame.midY - host.frame.midY) > 1, "레일 창의 가운데로 끌려가지 않는다")
        #expect(window.frame.width >= RailMoreCard.minWidth)
        let hosting = try #require(window.contentView as? EdgeRailMoreCardHostingView)
        #expect(hosting.accessibilityRole() == .menu && hosting.accessibilityLabel() == "More" && hosting.isAccessibilityElement())
        #expect(card.model?.items.map(\.label) == ["Connections", "Settings"])
    }

    // MARK: 키보드

    @Test func theCardHandlesArrowsReturnAndEscapeOnlyWhenTheKeyCameToItsOwnWindow() throws {
        let card = EdgeRailMoreCard()
        card.shows = false
        var picked: [String] = []
        var closed = 0
        card.present(model: model { picked.append($0) }, label: "More", capsule: capsule, over: parent()) { closed += 1 }
        let window = try #require(card.window)
        let elsewhere = parent()
        let downElsewhere = try key(kVK_DownArrow, in: elsewhere), returnElsewhere = try key(kVK_Return, in: elsewhere)
        #expect(!card.handle(downElsewhere) && !card.handle(returnElsewhere), "다른 창의 키는 가로채지 않는다")
        #expect(picked.isEmpty && card.model?.highlighted == nil)
        let down = try key(kVK_DownArrow, in: window), up = try key(kVK_UpArrow, in: window), enter = try key(kVK_Return, in: window)
        #expect(card.handle(down) && card.model?.highlighted == 0, "↓은 첫 줄")
        #expect(card.handle(down) && card.model?.highlighted == 1)
        #expect(card.handle(up) && card.model?.highlighted == 0, "↑")
        #expect(card.handle(enter) && picked == ["connections"], "Return은 짚은 줄을 고른다")
        #expect(!card.isOpen && closed == 1, "고르면 닫히고 닫힘을 알린다")
        // Esc
        card.present(model: model(), label: "More", capsule: capsule, over: parent()) { closed += 1 }
        let again = try #require(card.window)
        let escape = try key(kVK_Escape, in: again)
        #expect(card.handle(escape))
        #expect(!card.isOpen && closed == 2)
    }

    // MARK: 바깥 클릭 · 토글

    @Test func anOutsideClickClosesTheCardAndAClickInsideItDoesNot() throws {
        let card = EdgeRailMoreCard()
        card.shows = false
        var closed = 0
        card.present(model: model(), label: "More", capsule: capsule, over: parent()) { closed += 1 }
        let window = try #require(card.window)
        let inside = try click(in: window), outside = try click(in: parent())
        #expect(!card.outsideClick(inside) && card.isOpen, "카드 안 클릭은 닫지 않는다")
        #expect(!card.outsideClick(outside), "밖 클릭은 닫되 삼키지 않는다")
        #expect(!card.isOpen && closed == 1)
    }

    @Test func aClickOnTheMoreButtonThatClosesTheCardIsSwallowedSoItDoesNotReopenIt() throws {
        let card = EdgeRailMoreCard()
        card.shows = false
        card.swallowsOutsideClick = { _ in true }
        card.present(model: model(), label: "More", capsule: capsule, over: parent()) {}
        let outside = try click(in: parent())
        #expect(card.outsideClick(outside), "⋯ 위의 클릭은 카드를 닫고 삼켜진다")
        #expect(!card.isOpen)
    }

    // MARK: 레일 컨트롤러: 게이트 · 열림 · 닫힘 · 포커스

    @Test func theCapsuleRailOpensTheCardAndTheOldRailKeepsTheNativeMenu() async throws {
        let rig = try await TaskforceRig.make()
        let capsuleRail = EdgeRailPanelController(shell: rig.shell)
        #expect(capsuleRail.usesMoreCard, "게이트 켜짐 캡슐 레일은 카드")
        let notch = EdgeShellModel(schedule: { _, _ in EdgeTimer() })
        #expect(!EdgeRailPanelController(shell: notch).usesMoreCard, "게이트 꺼짐 · Release의 노치 레일은 지금의 NSMenu")
    }

    @Test func pressingMoreOpensTheCardMarksTheMenuOpenAndClosingReturnsTheFocusToMore() async throws {
        let rig = try await TaskforceRig.make()
        let rail = EdgeRailPanelController(shell: rig.shell)
        rail.moreCard.shows = false
        var opened: [String] = []
        rail.onConnections = { opened.append("connections") }
        rail.onSettings = { opened.append("settings") }
        // 카드는 펼친 레일에서만 열린다 (⋯는 펼친 셋째 캡슐에 있다)
        rig.shell.pointer(inside: true)
        rig.time.advance(0.2)
        #expect(rig.shell.isExpanded && rig.shell.capsuleLayout.thirdCapsuleFrame != nil)
        let focus = rig.shell.moreFocusSerial
        rail.toggleMoreCard()
        #expect(rail.moreCard.isOpen && rig.shell.menuOpen && rig.shell.railControlHighlighted(.more), "More 칸이 칠해진다")
        // 레일이 접히지 않는다: 카드가 열려 있는 동안은 펼친 채다
        rig.shell.pointer(inside: false)
        rig.time.advance(1)
        #expect(rig.shell.isExpanded, "카드가 열려 있으면 레일은 접히지 않는다")
        // 다시 누르면 닫힌다
        rail.toggleMoreCard()
        #expect(!rail.moreCard.isOpen && !rig.shell.menuOpen && rig.shell.moreFocusSerial == focus + 1, "닫히면 ⋯로 포커스가 돌아온다")
        // Settings를 고르면 설정이 열리고 카드가 닫힌다
        rig.shell.pointer(inside: true)
        rig.time.advance(0.2)
        rail.toggleMoreCard()
        rail.moreCard.model?.pick(1)
        #expect(opened == ["settings"] && !rail.moreCard.isOpen && rig.shell.moreFocusSerial == focus + 2)
    }

    /// 사용자 결정(2026-10-22): 레일이 여는 다른 패널은 레일 중심선에 가운데지만 More 카드는 ⋯ 옆(DS `beside`)이다 — 레일을 화면 어디에 두든 카드 아래 끝은 셋째 캡슐 아래 끝이다
    @Test func theCardStaysBesideTheMoreButtonWhereverTheRailStands() async throws {
        let rig = try await TaskforceRig.make()
        let rail = EdgeRailPanelController(shell: rig.shell)
        rail.moreCard.shows = false
        rig.shell.pointer(inside: true)
        rig.time.advance(0.2)
        #expect(rig.shell.isExpanded)
        var bottoms: [CGFloat] = []
        for originY in [CGFloat(120), 380] {
            rail.panel.setFrame(CGRect(origin: CGPoint(x: screen.maxX - EdgeRailCapsuleLayout.windowWidth, y: screen.minY + originY), size: EdgeRailCapsuleLayout.windowSize), display: false)
            rail.toggleMoreCard()
            let local = try #require(rig.shell.capsuleLayout.thirdCapsuleFrame)
            let capsule = rail.panel.convertToScreen(rail.hosting.convert(NSRect(x: local.minX, y: local.minY, width: local.width, height: local.height), to: nil))
            let window = try #require(rail.moreCard.window)
            let visible = (rail.panel.screen ?? NSScreen.main)?.visibleFrame ?? rail.panel.frame
            #expect(window.frame == RailMoreCardGeometry.frame(size: window.frame.size, capsule: capsule, visible: visible), "레일 창 아래 \(originY)")
            #expect(window.frame.maxX == capsule.minX - RailMoreCardGeometry.gap)
            bottoms.append(window.frame.minY)
            rail.toggleMoreCard()
        }
        #expect(abs(bottoms[1] - bottoms[0] - 260) < 0.001, "레일이 260 올라가면 카드도 같은 만큼 따라 올라간다 (가운데 맞춤이면 같은 자리에 머문다)")
    }

    // MARK: 칠해진 칸은 하나 (검토 1)

    @Test func exactlyOneRailItemLooksSelectedWhileTheTaskforceConversationIsOpen() async throws {
        let rig = try await TaskforceRig.make()
        await rig.read(TaskforceRig.response([TaskforceRig.confirm(rig.id(1))]))
        rig.shell.openTaskforce()
        await rig.settle()
        // Assistant 창이 앞에 있어도 Chats 칸이 따로 칠해지지 않는다: 칠해진 것은 열린 대화의 bell 하나뿐이다
        rig.shell.assistantWindowFront = true
        let lit = rig.shell.controls.filter { rig.shell.railControlHighlighted($0) }
        #expect(lit.isEmpty && rig.shell.taskforceBell?.selected == true, "Taskforce 대화가 열려 있으면 bell만 칠해진다")
        // 패널이 닫히면 칠해진 칸이 없다: 캡슐 레일에는 Chats 칸이 없어 창이 앞이어도 칠할 칸이 없다 (계약 24장)
        rig.shell.dismiss()
        #expect(rig.shell.controls.filter { rig.shell.railControlHighlighted($0) }.isEmpty)
        // 호버는 늘 칠한다 (포인터 피드백)
        rig.shell.assistantWindowFront = false
        rig.shell.hover(control: .allWork)
        #expect(rig.shell.railControlHighlighted(.allWork))
    }

    // MARK: More 카드를 닫으면 ⋯가 포커스를 받는다 (재검토 1 P2)

    /// 메인 런루프를 잠깐 돌린다 (async 맥락에서 `RunLoop`을 직접 부를 수 없다)
    private func spin(_ seconds: TimeInterval = 0.02) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// 레일 창이 SwiftUI를 한 바퀴 그리게 한다 (창은 화면에 올리지 않는다)
    private func pump(_ rail: EdgeRailPanelController) async {
        for _ in 0..<12 {
            rail.hosting.layoutSubtreeIfNeeded()
            rail.hosting.displayIfNeeded()
            await Task.yield()
            spin()
        }
    }

    enum Pointer { case onCard, farOutside, none, onRail }

    /// ⋯로 카드를 열고, 포인터를 `pointer`로 둔 채 Esc로 닫는다. 닫힌 직후 레일 뷰를 그려 본다.
    /// `panelOpen`이면 본문 패널이 열린 채(키보드만 쓰는 경우), 아니면 닫힌 채 포인터가 펼친 레일이다
    private func closeWithEscape(panelOpen: Bool, pointer: Pointer) async throws -> (rig: TaskforceRig, rail: EdgeRailPanelController) {
        let rig = try await TaskforceRig.make()
        let rail = EdgeRailPanelController(shell: rig.shell)
        rail.moreCard.shows = false
        rail.panel.setFrame(CGRect(origin: CGPoint(x: 1200, y: 200), size: EdgeRailCapsuleLayout.windowSize), display: false)
        if panelOpen {
            rig.shell.openAllWork()
        } else {
            rig.shell.pointer(inside: true)
            rig.time.advance(0.2)
        }
        #expect(rig.shell.isExpanded)
        await pump(rail)
        rail.toggleMoreCard()
        #expect(rail.moreCard.isOpen && rig.shell.menuOpen)
        let far = NSPoint(x: -5000, y: -5000)
        switch pointer {
        case .onCard:
            // 카드는 레일 창 왼쪽 밖에 뜬다: 포인터가 레일에서 카드로 옮겨 갔다
            rail.pointerLocation = { NSPoint(x: rail.panel.frame.minX - 60, y: rail.panel.frame.midY) }
            rig.shell.pointer(inside: false)
        case .farOutside:
            rail.pointerLocation = { far }
            rig.shell.pointer(inside: false)
        case .none:
            rail.pointerLocation = { far }
        case .onRail:
            let frame = try #require(rig.shell.capsuleLayout.controlFrame(.more))
            let point = CGPoint(x: frame.midX, y: frame.midY)
            let host = rail.hosting.isFlipped ? point : CGPoint(x: point.x, y: rail.hosting.bounds.height - point.y)
            let screen = rail.panel.convertPoint(toScreen: rail.hosting.convert(host, to: nil))
            rail.pointerLocation = { screen }
        }
        rig.time.advance(1)
        #expect(rig.shell.isExpanded, "카드가 열려 있는 동안 레일은 펼친 채다")
        let escape = try key(kVK_Escape, in: rail.moreCard.window)
        #expect(rail.moreCard.handle(escape))
        #expect(!rail.moreCard.isOpen && !rig.shell.menuOpen)
        await pump(rail)
        return (rig, rail)
    }

    /// 닫힌 직후: ⋯ 칸이 그려져 있고(펼친 채), 그 칸이 포커스 요청을 받았다
    private func expectFocusLanded(_ rig: TaskforceRig, _ rail: EdgeRailPanelController, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(rig.shell.isExpanded, "포커스가 닿을 때까지 레일은 펼친 채다", sourceLocation: sourceLocation)
        #expect(rig.shell.capsuleLayout.controlFrame(.more) != nil, "⋯ 칸이 그려져 있다", sourceLocation: sourceLocation)
        // 알림은 ⋯ 칸 뷰 자신이 보낸다 (칸이 그려져 있지 않으면 보내지 못한다): 실제 레일 뷰가 그 칸에 포커스를 주었다
        #expect(rig.shell.moreFocusSerial > 0 && rig.shell.moreFocusLandedSerial == rig.shell.moreFocusSerial, "포커스 요청이 ⋯ 칸에 닿았다", sourceLocation: sourceLocation)
    }

    @Test func escapeWithThePointerOnTheCardKeepsTheMoreButtonOnTheRailUntilFocusLandsOnIt() async throws {
        let (rig, rail) = try await closeWithEscape(panelOpen: false, pointer: .onCard)
        expectFocusLanded(rig, rail)
        // 그 다음 평소의 떠남 시간(400ms)으로 접힌다
        rig.time.advance(0.5)
        #expect(!rig.shell.isExpanded)
    }

    @Test func escapeWithThePointerFarOutsideTheRailDoesTheSame() async throws {
        let (rig, rail) = try await closeWithEscape(panelOpen: false, pointer: .farOutside)
        expectFocusLanded(rig, rail)
        rig.time.advance(0.5)
        #expect(!rig.shell.isExpanded)
    }

    @Test func escapeWithKeyboardOnlyAndTheBodyPanelOpenKeepsTheMoreButtonAndFocusLandsOnIt() async throws {
        let (rig, rail) = try await closeWithEscape(panelOpen: true, pointer: .none)
        expectFocusLanded(rig, rail)
        rig.time.advance(2)
        #expect(rig.shell.isExpanded, "본문 패널이 열려 있으면 레일은 그대로 펼친 채다")
    }

    @Test func escapeWithThePointerStillOnTheRailLeavesTheRailExpanded() async throws {
        let (rig, rail) = try await closeWithEscape(panelOpen: false, pointer: .onRail)
        expectFocusLanded(rig, rail)
        rig.time.advance(2)
        #expect(rig.shell.isExpanded, "포인터가 레일 위면 접히지 않는다")
    }

    // 레일을 펼친 채 붙잡는 규칙 (뷰 없이 모델만)

    @Test func theRailStaysExpandedUntilMoreTakesTheFocusAndThenFoldsOnTheNormalLeaveTiming() async throws {
        let rig = try await TaskforceRig.make()
        rig.shell.pointer(inside: true)
        rig.time.advance(0.2)
        rig.shell.setMenuOpen(true)
        rig.shell.pointer(inside: false)
        rig.time.advance(1)
        #expect(rig.shell.isExpanded, "카드가 열려 있는 동안은 펼친 채")
        rig.shell.moreCardClosed()
        let serial = rig.shell.moreFocusSerial
        #expect(rig.shell.moreFocusPending == serial && !rig.shell.menuOpen)
        rig.time.advance(1.5)
        #expect(rig.shell.isExpanded, "포커스가 ⋯에 닿기 전에는 평소 떠남 시간이 지나도 접히지 않는다")
        rig.shell.moreFocusLanded(serial)
        #expect(rig.shell.moreFocusPending == nil && rig.shell.isExpanded, "받은 직후는 아직 펼친 채")
        rig.time.advance(0.3)
        #expect(rig.shell.isExpanded, "평소의 떠남 시간(400ms) 안")
        rig.time.advance(0.2)
        #expect(!rig.shell.isExpanded, "받은 뒤 평소의 떠남 시간으로 접힌다")
    }

    @Test func ifMoreNeverTakesTheFocusTheHoldLimitFoldsTheRailAnyway() async throws {
        let rig = try await TaskforceRig.make()
        rig.shell.pointer(inside: true)
        rig.time.advance(0.2)
        rig.shell.setMenuOpen(true)
        rig.shell.pointer(inside: false)
        rig.time.advance(1)
        rig.shell.moreCardClosed()
        rig.time.advance(1.9)
        #expect(rig.shell.isExpanded && rig.shell.moreFocusPending != nil)
        rig.time.advance(0.2)
        #expect(rig.shell.moreFocusPending == nil, "상한이 풀어 준다")
        #expect(rig.shell.isExpanded, "풀린 뒤에도 평소 떠남 시간은 지켜진다")
        rig.time.advance(0.5)
        #expect(!rig.shell.isExpanded, "영영 펼쳐 있지 않다")
    }

    @Test func thePointerLeavingWhileMoreTakesTheFocusStillGetsTheNormalLeaveTimingAfterItLands() async throws {
        let rig = try await TaskforceRig.make()
        rig.shell.pointer(inside: true)
        rig.time.advance(0.2)
        rig.shell.setMenuOpen(true)
        rig.shell.moreCardClosed()
        let serial = rig.shell.moreFocusSerial
        rig.shell.pointer(inside: false)
        rig.time.advance(0.6)
        #expect(rig.shell.isExpanded && rig.shell.moreFocusPending == serial, "떠남 시간이 지나도 포커스가 닿기 전에는 접히지 않는다")
        rig.shell.moreFocusLanded(serial)
        #expect(rig.shell.isExpanded, "받은 직후는 아직 펼친 채")
        rig.time.advance(0.3)
        #expect(rig.shell.isExpanded)
        rig.time.advance(0.2)
        #expect(!rig.shell.isExpanded, "받은 뒤 평소의 떠남 시간으로 접힌다")
    }

    @Test func theBodyPanelClosingWhileMoreTakesTheFocusDoesNotFoldTheRailBeforeItLands() async throws {
        // 포인터가 펼친 레일 위에 있다가 나간 뒤 카드가 열렸다: 카드 밖 클릭이 카드를 닫고 같은 클릭이 본문 패널도 닫는다
        let hovered = try await TaskforceRig.make()
        hovered.shell.openAllWork()
        hovered.shell.pointer(inside: true)
        hovered.time.advance(0.2)
        hovered.shell.setMenuOpen(true)
        hovered.shell.pointer(inside: false)
        hovered.time.advance(1)
        hovered.shell.moreCardClosed()
        hovered.shell.dismiss()
        #expect(hovered.shell.isExpanded, "패널이 닫혀도 ⋯가 포커스를 받기 전에는 접히지 않는다")
        hovered.time.advance(1)
        #expect(hovered.shell.isExpanded)
        hovered.shell.moreFocusLanded(hovered.shell.moreFocusSerial)
        #expect(hovered.shell.isExpanded, "받은 직후는 아직 펼친 채: 평소의 떠남 시간이 시작된다")
        hovered.time.advance(0.3)
        #expect(hovered.shell.isExpanded)
        hovered.time.advance(0.2)
        #expect(!hovered.shell.isExpanded)
        // 레일이 패널 때문에만 펼쳐 있던 경우도 같다
        let panelOnly = try await TaskforceRig.make()
        panelOnly.shell.openAllWork()
        panelOnly.shell.setMenuOpen(true)
        panelOnly.shell.moreCardClosed()
        panelOnly.shell.dismiss()
        #expect(panelOnly.shell.isExpanded, "받기 전에는 접히지 않는다")
        panelOnly.shell.moreFocusLanded(panelOnly.shell.moreFocusSerial)
        panelOnly.time.advance(0.5)
        #expect(!panelOnly.shell.isExpanded)
    }

    // MARK: More가 열린 동안 칠해진 칸은 ⋯ 하나 (재검토 1 P3)

    @Test func whileTheMoreCardIsOpenOnlyMoreLooksSelectedWhicheverScreenIsOpen() async throws {
        let rig = try await TaskforceRig.make()
        await rig.read(TaskforceRig.response([TaskforceRig.confirm(rig.id(1))]))
        func litControls() -> [EdgeShellModel.Control] { rig.shell.controls.filter { rig.shell.railControlHighlighted($0) } }
        // Projects가 열려 있다: 그 칸이 선택이다
        rig.shell.openAllWork()
        #expect(litControls() == [.allWork])
        rig.shell.setMenuOpen(true)
        #expect(litControls() == [.more], "Projects가 열려 있어도 More 카드가 열려 있으면 칠해진 칸은 ⋯ 하나")
        rig.shell.setMenuOpen(false)
        #expect(litControls() == [.allWork], "카드가 닫히면 Projects 선택이 돌아온다 (선택은 지워진 적 없다)")
        // Assistant 창이 앞이다 (패널은 닫혀 있다): Chats 칸이 없어 칠해진 칸이 없다
        rig.shell.dismiss()
        rig.shell.assistantWindowFront = true
        #expect(litControls().isEmpty)
        rig.shell.setMenuOpen(true)
        #expect(litControls() == [.more])
        rig.shell.setMenuOpen(false)
        rig.shell.assistantWindowFront = false
        // 세션 링: 패널이 그 일을 보여 주는 중
        rig.shell.open(itemID: rig.id(1))
        #expect(rig.shell.railRingLit(rig.id(1)))
        rig.shell.setMenuOpen(true)
        #expect(!rig.shell.railRingLit(rig.id(1)) && litControls() == [.more], "링도 칠해지지 않는다")
        rig.shell.setMenuOpen(false)
        // Taskforce 대화: bell이 칠해진다
        rig.shell.openTaskforce()
        await rig.settle()
        #expect(rig.shell.taskforceBell?.selected == true && rig.shell.railBellSelectionShown)
        rig.shell.setMenuOpen(true)
        #expect(!rig.shell.railBellSelectionShown && litControls() == [.more], "열린 대화의 bell 칠도 그리지 않는다")
        #expect(rig.shell.taskforceBell?.selected == true, "접근성의 선택됨은 그대로다")
        // 카드 위에서 레일 쪽으로 돌아온 포인터의 호버도 칠하지 않는다: 칠해진 칸은 하나
        rig.shell.hover(control: .allWork)
        #expect(litControls() == [.more])
        rig.shell.hover(bell: true)
        #expect(!rig.shell.railBellHoverLit)
        rig.shell.hover(plus: true)
        #expect(!rig.shell.railPlusLit)
        rig.shell.hover(item: rig.id(1))
        #expect(!rig.shell.railRingLit(rig.id(1)))
        // 닫히면 호버는 다시 칠한다
        rig.shell.setMenuOpen(false)
        rig.shell.hover(control: .allWork)
        #expect(litControls() == [.allWork] && rig.shell.railBellSelectionShown)
        rig.shell.hover(bell: true)
        #expect(rig.shell.railBellHoverLit)
        rig.shell.hover(plus: true)
        #expect(rig.shell.railPlusLit)
    }

    /// 실제 레일 뷰를 그려 본다: 열린 대화의 bell 원은 칠해져 있다가 More 카드가 열리면 칠해지지 않는다 (칠해진 칸은 ⋯ 하나)
    @Test func theOpenConversationsBellFillIsNotDrawnWhileTheMoreCardIsOpen() async throws {
        let rig = try await TaskforceRig.make()
        await rig.read(TaskforceRig.response([]))
        rig.shell.openTaskforce()
        await rig.settle()
        let bell = try #require(rig.shell.taskforceBell)
        #expect(bell.selected && !bell.rings, "열린 대화의 bell (요청 0: 울리지 않는다)")
        let item = try #require(rig.shell.capsuleLayout.bellItemDrawn)
        // 원 안쪽 왼쪽 끝 (글리프는 가운데 16pt라 이 점은 칠만 있다)
        let point = (x: Int(item.minX) + 3, y: Int(item.midY))
        func rgb() throws -> [Int] {
            let renderer = ImageRenderer(content: EdgeRailCapsuleView(shell: rig.shell, onMore: { _ in }).environment(\.colorScheme, .light))
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            let context = try #require(CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
            // 비트맵 메모리의 첫 줄이 그림의 맨 위다
            let at = (point.y * image.width + point.x) * 4
            return [Int(data[at]), Int(data[at + 1]), Int(data[at + 2])]
        }
        let closed = try rgb()
        rig.shell.setMenuOpen(true)
        let open = try rgb()
        #expect(closed != open, "카드가 열려 있으면 bell 원의 칠이 사라진다")
        #expect(closed.reduce(0, +) > open.reduce(0, +), "칠(bezel-hover)은 캡슐 바탕보다 밝다")
    }
}
