import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// OA U3 16.1: 캡슐 레일의 ⋯는 macOS 기본 메뉴 대신 DS 카드(EdgeRail "More open")를 연다. 게이트 켜짐에서만, 게이트 꺼짐 · Release는 그대로 `NSMenu`다.
/// 키보드(↑ ↓ Return Esc) · VoiceOver 메뉴 역할 · 바깥 클릭으로 닫힘 · ⋯ 위 클릭은 토글 · 닫히면 포커스가 ⋯로 돌아온다
@MainActor
struct EdgeRailCapsuleMoreTests {
    private let capsule = CGRect(x: 1390, y: 300, width: 44, height: 112)

    private func parent() -> NSPanel {
        let panel = EdgePassivePanel(contentRect: CGRect(x: 1300, y: 200, width: 140, height: 400), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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
        #expect(window.frame == RailMoreCardGeometry.frame(size: window.frame.size, capsule: capsule, visible: visible))
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
        // 패널이 닫히면 창이 앞인 Chats만 칠해진다 (그때는 bell이 없다)
        rig.shell.dismiss()
        #expect(rig.shell.controls.filter { rig.shell.railControlHighlighted($0) } == [.chats])
        // 호버는 늘 칠한다 (포인터 피드백)
        rig.shell.assistantWindowFront = false
        rig.shell.hover(control: .allWork)
        #expect(rig.shell.railControlHighlighted(.allWork))
    }
}
