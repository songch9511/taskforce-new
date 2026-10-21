import AppKit
import Foundation
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// Assistant 창의 끌기 · 크기 조절 (실제 AppKit 창): 핸들 · 머리가 창을 끌고, 가장자리 · 모서리로 크기를 바꾸고, 크기 · 자리를 화면별로 기억한다.
/// 화면은 모형이다: 보이는 영역을 실제 화면 **밖**(-20000)에 둬서 창을 띄워도 사용자의 화면에 나타나지 않는다. 기억은 격리 suite에 둔다 (실사용 설정을 건드리지 않는다)
@MainActor
struct AssistantWindowDragResizeTests {
    let visible = CGRect(x: -20000, y: -20000, width: 1440, height: 875)
    var rail: CGRect { CGRect(x: visible.maxX - 44, y: visible.minY + 400, width: 44, height: 319) }

    /// 화면 크기가 바뀌는 모형 (해상도 · 모니터 연결 변경)
    final class ScreenBox {
        var visible: CGRect
        init(_ visible: CGRect) { self.visible = visible }
    }

    struct Rig {
        let screen: ScreenBox
        let manager: AssistantWindowManager
        let controller: AssistantWindowController
        let windowID: UUID
        let defaults: TestDefaults
        let runtime: ChatRuntime
        let shell: EdgeShellModel
        let account: AppChatAccount
    }

    private func rig(
        defaults: TestDefaults? = nil, display: String = "1", visible customVisible: CGRect? = nil, conversation: UUID? = nil, extraScreens: [AssistantScreen] = []
    ) throws -> Rig {
        let account = try AppChatAccount.make()
        let runtime = ChatRuntime(gateway: WindowTestGateway(), scope: account.scope, now: { Date() })
        let shell = EdgeShellModel(schedule: { _, _ in EdgeTimer() }, chatsEnabled: true, windowsEnabled: true)
        let store = try defaults ?? TestDefaults()
        let screen = ScreenBox(customVisible ?? visible)
        let manager = AssistantWindowManager(
            runtime: runtime, shell: shell, store: AssistantWindowPositionStore(defaults: store.defaults),
            environment: .init(
                visibleFrame: { screen.visible },
                railFrame: { CGRect(x: screen.visible.maxX - 44, y: screen.visible.minY + 400, width: 44, height: 319) },
                panelFrame: { nil }, display: { display }, extraScreens: { extraScreens }
            )
        )
        manager.presents = false
        let id = try #require(conversation.flatMap { manager.openWindow(for: $0) } ?? manager.openNewWindow())
        let controller = try #require(manager.controllers[id])
        return Rig(screen: screen, manager: manager, controller: controller, windowID: id, defaults: store, runtime: runtime, shell: shell, account: account)
    }

    /// 창을 (화면 밖에) 올리고 SwiftUI가 머리 · 입력 영역의 높이를 알릴 때까지 기다린다
    private func layOut(_ controller: AssistantWindowController) async throws {
        controller.panel.orderFront(nil)
        for _ in 0..<200 {
            controller.panel.contentView?.layoutSubtreeIfNeeded()
            if controller.presentation.headHeight > 0, controller.presentation.footerHeight > 0 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// 창 안의 한 점(위가 0)을 누르면 받는 뷰
    private func hit(_ controller: AssistantWindowController, x: CGFloat, y: CGFloat) -> NSView? {
        guard let content = controller.panel.contentView else { return nil }
        let inWindow = NSPoint(x: x, y: controller.panel.frame.height - y)
        return content.hitTest(content.convert(content.convert(inWindow, from: nil), to: content.superview))
    }

    // MARK: 끌기 영역

    @Test func theHandleCapsuleTheStripAroundItAndTheEmptyHeaderAllDragTheWindow() async throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        try await layOut(r.controller)
        defer { r.controller.panel.orderOut(nil) }
        let width = r.controller.panel.frame.width
        // 캡슐 한가운데(위 6–10pt)가 사용자가 잡는 곳이다: 그 위의 그림이 누름을 가로채지 않는다
        #expect(hit(r.controller, x: width / 2, y: 8) is AssistantDragRegion.DragNSView, "캡슐")
        #expect(hit(r.controller, x: width / 2, y: 12) is AssistantDragRegion.DragNSView, "캡슐 아래")
        #expect(hit(r.controller, x: 60, y: 8) is AssistantDragRegion.DragNSView, "핸들 띠의 빈 곳")
        #expect(hit(r.controller, x: 200, y: 34) is AssistantDragRegion.DragNSView, "머리의 빈 곳")
        #expect(!(hit(r.controller, x: width / 2, y: 300) is AssistantDragRegion.DragNSView), "본문은 끌지 않는다 (글을 고르다 창이 끌려가지 않는다)")
    }

    @Test func theTitleIsAGrabbingPlaceTooAndKeepsItsFullNameAsATooltip() async throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        try await layOut(r.controller)
        defer { r.controller.panel.orderOut(nil) }
        let width = r.controller.panel.frame.width
        // 머리 줄 전체(오른쪽 History · New chat 단추만 빼고)가 끌기 영역이다: 제목 글자 위도
        for y in [24.0, 34.0, 44.0] {
            for x in stride(from: 16.0, through: width - 100, by: 20.0) {
                #expect(hit(r.controller, x: x, y: y) is AssistantDragRegion.DragNSView, "(\(x), \(y))")
            }
        }
        let title = try #require(hit(r.controller, x: 40, y: 34))
        #expect(title.toolTip == r.controller.model.title, "긴 제목은 툴팁으로 전체를 본다 (`.help`가 만드는 뷰는 누름을 가로챈다)")
    }

    // MARK: 끌기 (창 끌기를 시작하는 길)

    /// 창 안의 한 점에서의 왼쪽 마우스 이벤트 (위가 0)
    private func mouseEvent(_ type: NSEvent.EventType = .leftMouseDown, _ controller: AssistantWindowController, x: CGFloat, y: CGFloat, clickCount: Int = 1) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: NSPoint(x: x, y: controller.panel.frame.height - y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: controller.panel.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1
        ))
    }

    private func mouseDown(_ controller: AssistantWindowController, x: CGFloat, y: CGFloat, clickCount: Int = 1) throws -> NSEvent {
        try mouseEvent(.leftMouseDown, controller, x: x, y: y, clickCount: clickCount)
    }

    /// 끌기 이벤트를 큐에 미리 넣고(끄는 이벤트 `count`개 + 놓기) 마우스 자리 순서를 정한다: 시험이 실제 끌기 따라가기(`AssistantMouseTracker`)를 그대로 돈다
    private func scriptMouse(_ tracker: inout AssistantMouseTracker, _ controller: AssistantWindowController, points: [CGPoint]) throws {
        var queue = points
        tracker.locate = { _ in queue.removeFirst() }
        tracker.timeout = 2
        tracker.buttonIsDown = { true }
        for index in 0..<(points.count - 1) {
            let type: NSEvent.EventType = index == points.count - 2 ? .leftMouseUp : .leftMouseDragged
            NSApp.postEvent(try mouseEvent(type, controller, x: 0, y: 0), atStart: false)
        }
    }

    @Test func pressingTheHandleMovesTheWindowByTheMouseAndLeavesTheKeyAlone() async throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        try await layOut(r.controller)
        defer { r.controller.panel.orderOut(nil) }
        let panel = r.controller.panel
        let view = try #require(hit(r.controller, x: panel.frame.width / 2, y: 8) as? AssistantDragRegion.DragNSView)
        let before = panel.frame.origin
        // 누른 곳 → (+40, −20) → (+90, −50) → 놓음 (화면 좌표, 아래가 0)
        try scriptMouse(&view.tracker, r.controller, points: [CGPoint(x: 500, y: 500), CGPoint(x: 540, y: 480), CGPoint(x: 590, y: 450), CGPoint(x: 590, y: 450)])
        #expect(!panel.isKeyWindow, "시작: 키 창이 아니다")
        view.mouseDown(with: try mouseDown(r.controller, x: panel.frame.width / 2, y: 8))
        #expect(panel.frame.origin == CGPoint(x: before.x + 90, y: before.y - 50), "마우스가 움직인 만큼 창이 따라온다")
        #expect(!panel.isKeyWindow, "끌기는 키를 가져가지 않는다 (옮기려다 다른 앱에 치던 글이 입력창으로 들어가지 않게)")
    }

    @Test func aPressWithoutMovingIsAClickAndTheWindowBecomesKey() async throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        try await layOut(r.controller)
        defer { r.controller.panel.orderOut(nil) }
        let panel = r.controller.panel
        let view = try #require(hit(r.controller, x: 200, y: 34) as? AssistantDragRegion.DragNSView)
        let before = panel.frame.origin
        // 2pt 흔들렸다: 끌기 문턱(3pt) 아래라 클릭이다
        try scriptMouse(&view.tracker, r.controller, points: [CGPoint(x: 500, y: 500), CGPoint(x: 501, y: 499), CGPoint(x: 501, y: 499)])
        view.mouseDown(with: try mouseDown(r.controller, x: 200, y: 34))
        #expect(panel.frame.origin == before, "작게 흔들린 누름은 창을 옮기지 않는다")
        #expect(panel.isKeyWindow, "클릭: 창이 키 창이 된다 (Esc가 듣는다)")
    }

    @Test func aLostMouseUpEndsAWindowDragToo() async throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        try await layOut(r.controller)
        defer { r.controller.panel.orderOut(nil) }
        let panel = r.controller.panel
        let view = try #require(hit(r.controller, x: 200, y: 34) as? AssistantDragRegion.DragNSView)
        let before = panel.frame.origin
        var points = [CGPoint(x: 500, y: 500), CGPoint(x: 560, y: 500)]
        view.tracker.locate = { _ in points.removeFirst() }
        view.tracker.timeout = 0.05
        var polls = 0
        view.tracker.buttonIsDown = { polls += 1; return polls < 3 }
        NSApp.postEvent(try mouseEvent(.leftMouseDragged, r.controller, x: 0, y: 0), atStart: false)   // 끄는 이벤트 하나, 놓는 이벤트는 없다
        view.mouseDown(with: try mouseDown(r.controller, x: 200, y: 34))
        #expect(polls >= 3 && panel.frame.origin == CGPoint(x: before.x + 60, y: before.y), "버튼이 올라간 것을 보고 끝맺는다 (창이 마우스에 영영 붙어 다니지 않는다)")
    }

    @Test func onlyTheHandleAndTheHeaderDragNotTheWindowBackground() throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        #expect(!r.controller.panel.isMovableByWindowBackground, "본문 어디서나 끌리면 글을 고르다 창이 움직인다")
        #expect(!AssistantDragRegion.DragNSView().mouseDownCanMoveWindow, "배경 끌기 길과 겹치지 않는다: 끌기는 mouseDown이 시작한다")
        #expect(AssistantDragRegion.DragNSView().acceptsFirstMouse(for: nil), "다른 앱이 앞이어도 첫 누름이 끌기를 시작한다")
    }

    @Test func theWindowStaysABorderlessNonActivatingPanelThatNeverBecomesMain() throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        let panel = r.controller.panel
        #expect(panel.styleMask.contains(.borderless) && panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.canBecomeKey && !panel.canBecomeMain)
        #expect(panel.isFloatingPanel && panel.level == .floating)
    }

    // MARK: 크기 조절 (끌기 한 번 = begin → resize → end)

    /// 창을 레일에서 떨어진 가운데로 옮겨 사방으로 늘릴 여유를 둔다 (처음 자리는 레일 12pt 왼쪽이라 오른쪽이 막혀 있다)
    private func centered(_ r: Rig) -> NSRect {
        r.controller.place(topLeft: CGPoint(x: visible.minX + 400, y: visible.maxY - 100))
        return r.controller.panel.frame
    }

    private func dragEdge(_ r: Rig, _ edge: AssistantWindowGeometry.ResizeEdge, dx: CGFloat = 0, dy: CGFloat = 0) {
        r.controller.beginResize(edge)
        r.controller.resize(by: CGPoint(x: dx, y: dy))
        r.controller.endResize()
    }

    private func saved(_ r: Rig, display: String = "1") -> AssistantWindowSize? {
        AssistantWindowPositionStore(defaults: r.defaults.defaults).load().size(display: display)
    }

    @Test func theBottomRightCornerGrowsTheWindowFromItsTopLeftAndRemembersTheSize() throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        let before = centered(r)
        r.controller.beginResize(.bottomRight)
        r.controller.resize(by: CGPoint(x: 100, y: -120))
        #expect(r.controller.panel.frame == NSRect(x: before.minX, y: before.minY - 120, width: before.width + 100, height: before.height + 120), "끄는 동안 창이 따라온다")
        r.controller.endResize()
        #expect(r.controller.preferredSize == AssistantWindowSize(width: 480, height: 560))
        #expect(r.controller.topLeft == CGPoint(x: before.minX, y: before.maxY), "왼쪽 위는 그대로")
        #expect(saved(r) == AssistantWindowSize(width: 480, height: 560), "이 화면의 크기로 기억한다")
    }

    @Test func aSideEdgeOnlyChangesTheWidthAndTheHeightKeepsHuggingTheContent() throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        let before = centered(r)
        dragEdge(r, .right, dx: 90)
        #expect(r.controller.panel.frame == NSRect(x: before.minX, y: before.minY, width: 470, height: before.height))
        #expect(r.controller.preferredSize == AssistantWindowSize(width: 470, height: nil), "높이는 정하지 않았다")
        // 내용이 자라면 예전처럼 따라 자란다 (560에서 멈춘다)
        r.controller.presentation.headHeight = 52
        r.controller.presentation.footerHeight = 100
        r.controller.presentation.bodyHeight = 300
        r.controller.applyFrame()
        #expect(r.controller.panel.frame.height == 452, "빈 대화는 내용에 맞춘다 (바닥 440 위)")
        r.controller.presentation.bodyHeight = 900
        r.controller.applyFrame()
        #expect(r.controller.panel.frame.height == 560 && r.controller.panel.frame.width == 470)
        #expect(r.controller.panel.frame.maxY == before.maxY, "위 가장자리는 움직이지 않는다")
    }

    @Test func aChosenHeightIsKeptWhateverTheContentDoes() throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        let before = centered(r)
        dragEdge(r, .bottom, dy: -260)
        #expect(r.controller.panel.frame.height == before.height + 260)
        #expect(r.controller.preferredSize == AssistantWindowSize(width: 380, height: 700))
        r.controller.presentation.headHeight = 52
        r.controller.presentation.footerHeight = 100
        r.controller.presentation.bodyHeight = 100
        r.controller.applyFrame()
        #expect(r.controller.panel.frame.height == 700, "내용이 적어도 정한 높이")
        r.controller.presentation.bodyHeight = 3000
        r.controller.applyFrame()
        #expect(r.controller.panel.frame.height == 700, "560을 넘는 내용도 정한 높이 (본문이 스크롤한다)")
    }

    @Test func theLeftAndTopEdgesMoveTheTopLeftAndTheNewSpotIsRemembered() throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        let conversation = try #require(r.manager.registry.conversationID(of: r.windowID))
        let before = centered(r)
        dragEdge(r, .topLeft, dx: -60, dy: 40)
        #expect(r.controller.panel.frame == NSRect(x: before.minX - 60, y: before.minY, width: 440, height: before.height + 40))
        #expect(r.controller.topLeft == CGPoint(x: before.minX - 60, y: before.maxY + 40), "위 · 왼쪽 가장자리를 끌면 자리가 바뀐다")
        #expect(r.controller.desiredTopLeft == r.controller.topLeft)
        let position = AssistantWindowPositionStore(defaults: r.defaults.defaults).load().position(conversation: conversation, display: "1")
        #expect(position == r.controller.topLeft, "새 자리도 기억한다")
    }

    @Test func resizingStopsAtTheMinimumAtTheScreenEdgesAndBeforeTheRail() throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        let before = centered(r)
        r.controller.beginResize(.bottomRight)
        r.controller.resize(by: CGPoint(x: -5000, y: 5000))
        #expect(r.controller.panel.frame.size == CGSize(width: AssistantWindowGeometry.minWidth, height: AssistantWindowGeometry.minHeight), "작게")
        r.controller.resize(by: CGPoint(x: 5000, y: -5000))
        let frame = r.controller.panel.frame
        #expect(frame.maxX == rail.minX, "오른쪽은 레일 앞에서 멈춘다")
        #expect(frame.minY == visible.minY, "아래는 화면 아래에서 멈춘다")
        #expect(frame.minX == before.minX && frame.maxY == before.maxY, "왼쪽 위는 그대로")
        r.controller.endResize()
        r.controller.beginResize(.topLeft)
        r.controller.resize(by: CGPoint(x: -50000, y: 50000))
        let corner = r.controller.panel.frame
        #expect(corner.minX == visible.minX && corner.maxY == visible.maxY && corner.maxX == frame.maxX && corner.minY == frame.minY)
        r.controller.endResize()
    }

    @Test func aStillClickOnAnEdgeChangesNothingAndRemembersNothing() throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        let before = centered(r)
        dragEdge(r, .bottom)
        #expect(r.controller.panel.frame == before)
        #expect(r.controller.preferredSize == .standard && saved(r) == nil, "움직이지 않은 눌림이 높이를 굳히지 않는다")
    }

    @Test func resizingDoesNotTakeTheKeyOrCloseTheWindow() async throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        _ = centered(r)
        try await layOut(r.controller)
        defer { r.controller.panel.orderOut(nil) }
        let generation = r.controller.generation
        dragEdge(r, .right, dx: 40)
        #expect(!r.controller.panel.isKeyWindow, "크기를 바꾸려다 다른 앱의 입력을 가져오지 않는다")
        #expect(r.controller.generation == generation && r.controller.panel.isVisible)
    }

    @Test func contentHeightChangesDoNotFightTheUserWhileTheMouseIsDown() throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        let before = centered(r)
        r.controller.beginResize(.right)
        r.controller.resize(by: CGPoint(x: 50, y: 0))
        r.controller.presentation.headHeight = 52
        r.controller.presentation.footerHeight = 100
        r.controller.presentation.bodyHeight = 500
        r.controller.applyFrame()
        #expect(r.controller.panel.frame == NSRect(x: before.minX, y: before.minY, width: 430, height: before.height), "끄는 도중에는 높이 맞춤이 창을 건드리지 않는다")
        r.controller.endResize()
        #expect(r.controller.panel.frame.height == 560, "놓으면 새 폭의 내용에 맞춘다")
    }

    @Test func aLostMouseUpEndsTheResizeOnceTheButtonIsSeenToBeUp() async throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        _ = centered(r)
        let container = try #require(r.controller.panel.contentView as? AssistantWindowContentView)
        let view = try #require(container.edgeViews[.right])
        var points = [CGPoint(x: 1000, y: 500), CGPoint(x: 1070, y: 500)]
        view.tracker.locate = { _ in points.removeFirst() }
        view.tracker.timeout = 0.05
        var polls = 0
        view.tracker.buttonIsDown = {
            polls += 1
            return polls < 3   // 두 번 보는 동안은 눌려 있고, 그다음 버튼이 올라가 있다 (놓는 이벤트는 오지 않았다)
        }
        let before = r.controller.panel.frame
        NSApp.postEvent(try mouseEvent(.leftMouseDragged, r.controller, x: 0, y: 0), atStart: false)   // 끄는 이벤트 하나, 놓는 이벤트는 없다
        view.mouseDown(with: try mouseDown(r.controller, x: before.width - 2, y: 200))
        #expect(polls >= 3, "버튼 상태를 다시 보았다")
        #expect(r.controller.panel.frame.width == before.width + 70 && r.controller.preferredSize == AssistantWindowSize(width: before.width + 70, height: nil), "끝맺었다: 끈 만큼 크기가 정해졌다")
        #expect(saved(r) == r.controller.preferredSize, "기억도 했다 (끌기가 영영 이어지지 않는다)")
    }

    @Test func aWindowClosedInTheMiddleOfAResizeRemembersNothingWhenTheMouseComesUp() throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        _ = centered(r)
        r.controller.beginResize(.right)
        r.controller.resize(by: CGPoint(x: 40, y: 0))
        r.manager.close(r.windowID)
        r.controller.endResize()
        #expect(saved(r) == nil && r.defaults.defaults.data(forKey: AssistantWindowPositionStore.key) == nil, "닫힌 창의 크기를 다시 쓰지 않는다 (계정이 떠난 뒤에 남지 않게)")
    }

    // MARK: 기본으로 되돌리기 · 키보드

    @Test func aDoubleClickOnAnEdgeGoesBackToTheStandardSizeAndForgetsTheChoice() throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        _ = centered(r)
        dragEdge(r, .bottomRight, dx: 100, dy: -200)
        #expect(saved(r) != nil)
        let top = r.controller.topLeft
        r.controller.resetSize()
        #expect(r.controller.preferredSize == .standard)
        #expect(r.controller.panel.frame.width == 380 && r.controller.panel.frame.height == AssistantWindowGeometry.emptyHeight)
        #expect(r.controller.topLeft == top, "왼쪽 위는 그대로")
        #expect(saved(r) == nil, "기본은 기억하지 않는다")
        r.controller.resetSize()
        #expect(r.controller.preferredSize == .standard, "이미 기본이면 아무 일도 없다")
    }

    @Test func optionArrowsResizeTheWindowBySixteenFromItsBottomRight() throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        let before = centered(r)
        r.controller.resize(by: .right)
        r.controller.resize(by: .right)
        #expect(r.controller.panel.frame == NSRect(x: before.minX, y: before.minY, width: 412, height: before.height))
        #expect(r.controller.preferredSize == AssistantWindowSize(width: 412, height: nil), "가로만 바꾸면 높이는 내용에 맞춘다")
        r.controller.resize(by: .down)
        #expect(r.controller.panel.frame == NSRect(x: before.minX, y: before.minY - 16, width: 412, height: before.height + 16))
        #expect(r.controller.preferredSize == AssistantWindowSize(width: 412, height: before.height + 16))
        #expect(saved(r) == r.controller.preferredSize)
        for _ in 0..<40 { r.controller.resize(by: .left) }
        #expect(r.controller.panel.frame.width == AssistantWindowGeometry.minWidth, "최소에서 멈춘다")
    }

    // MARK: 가장자리 뷰

    @Test func eightEdgeViewsSitOnTopOfTheContentAndFollowTheWindowSize() async throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        let container = try #require(r.controller.panel.contentView as? AssistantWindowContentView)
        container.layoutSubtreeIfNeeded()
        #expect(container.edgeViews.count == 8 && Set(container.edgeViews.keys) == Set(AssistantWindowGeometry.ResizeEdge.allCases))
        let t = AssistantWindowContentView.edgeThickness, c = AssistantWindowContentView.cornerSize
        let size = container.bounds.size
        #expect(container.edgeViews[.top]?.frame == CGRect(x: c, y: 0, width: size.width - 2 * c, height: t))
        #expect(container.edgeViews[.bottom]?.frame == CGRect(x: c, y: size.height - t, width: size.width - 2 * c, height: t))
        #expect(container.edgeViews[.left]?.frame == CGRect(x: 0, y: c, width: t, height: size.height - 2 * c))
        #expect(container.edgeViews[.right]?.frame == CGRect(x: size.width - t, y: c, width: t, height: size.height - 2 * c))
        #expect(container.edgeViews[.topLeft]?.frame == CGRect(x: 0, y: 0, width: c, height: c))
        #expect(container.edgeViews[.bottomRight]?.frame == CGRect(x: size.width - c, y: size.height - c, width: c, height: c))
        // 창이 커지면 따라온다
        _ = centered(r)
        dragEdge(r, .bottomRight, dx: 100, dy: -100)
        container.layoutSubtreeIfNeeded()
        #expect(container.edgeViews[.right]?.frame.minX == container.bounds.width - t)
        #expect(container.edgeViews[.bottom]?.frame.minY == container.bounds.height - t)
        let hostingIsBelow = container.subviews.firstIndex { !($0 is AssistantResizeEdgeView) } ?? .max
        #expect(container.subviews.enumerated().filter { $0.element is AssistantResizeEdgeView }.allSatisfy { $0.offset > hostingIsBelow }, "SwiftUI 뷰 위에 얹힌다: 누름을 먼저 받는다")
    }

    @Test func pressingTheWindowRimReachesTheMatchingEdgeAndTheInsideDoesNot() async throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        try await layOut(r.controller)
        defer { r.controller.panel.orderOut(nil) }
        let w = r.controller.panel.frame.width, h = r.controller.panel.frame.height
        func edge(_ x: CGFloat, _ y: CGFloat) -> AssistantWindowGeometry.ResizeEdge? { (hit(r.controller, x: x, y: y) as? AssistantResizeEdgeView)?.edge }
        #expect(edge(w / 2, 2) == .top && edge(w / 2, h - 2) == .bottom)
        #expect(edge(2, h / 2) == .left && edge(w - 2, h / 2) == .right)
        #expect(edge(3, 3) == .topLeft && edge(w - 3, 3) == .topRight)
        #expect(edge(3, h - 3) == .bottomLeft && edge(w - 3, h - 3) == .bottomRight)
        #expect(edge(w / 2, 8) == nil && hit(r.controller, x: w / 2, y: 8) is AssistantDragRegion.DragNSView, "캡슐은 끌기 영역이다")
        #expect(edge(w / 2, h / 2) == nil && edge(20, 200) == nil && edge(w - 20, 200) == nil)
    }

    @Test func eachEdgeShowsItsOwnResizeCursorEvenWhenTheAppIsNotActive() throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        let container = try #require(r.controller.panel.contentView as? AssistantWindowContentView)
        for (edge, view) in container.edgeViews {
            #expect(view.cursor.image.size.width > 0, "\(edge)")
            let area = try #require(view.trackingAreas.first { $0.options.contains(.cursorUpdate) }, "\(edge)")
            #expect(area.options.contains(.activeAlways) && area.options.contains(.inVisibleRect), "다른 앱이 앞이어도 · 크기가 바뀌어도")
            #expect(!view.isAccessibilityElement(), "접근성 트리를 어지럽히지 않는다")
        }
    }

    @Test func pressingAnEdgeRunsBeginDragEndFromTheMouseAndADoubleClickResets() async throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        _ = centered(r)
        let container = try #require(r.controller.panel.contentView as? AssistantWindowContentView)
        let view = try #require(container.edgeViews[.bottomRight])
        // 화면 좌표(아래가 0)의 마우스: 누른 곳, 끄는 두 곳, 놓은 곳
        var points = [CGPoint(x: 1000, y: 500), CGPoint(x: 1040, y: 480), CGPoint(x: 1100, y: 430), CGPoint(x: 1100, y: 430)]
        view.tracker.locate = { _ in points.removeFirst() }
        view.tracker.timeout = 2
        let before = r.controller.panel.frame
        let down = try mouseDown(r.controller, x: 370, y: 430)
        // 끌기 두 번과 놓기를 이벤트 큐에 미리 넣는다
        for type in [NSEvent.EventType.leftMouseDragged, .leftMouseDragged, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: r.controller.panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            NSApp.postEvent(event, atStart: false)
        }
        view.mouseDown(with: down)
        #expect(r.controller.panel.frame == NSRect(x: before.minX, y: before.minY - 70, width: before.width + 100, height: before.height + 70), "마지막 위치(+100, −70)까지")
        #expect(r.controller.preferredSize == AssistantWindowSize(width: 480, height: before.height + 70), "놓으면 끝맺는다")
        view.mouseDown(with: try mouseDown(r.controller, x: 370, y: 430, clickCount: 2))
        #expect(r.controller.preferredSize == .standard, "두 번 누르면 기본 크기")
    }

    // MARK: 기억 (화면별)

    @Test func aReopenedChatRestoresItsSpotAndSizeAndANewWindowGetsTheDisplaysSize() throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        let conversation = try #require(r.manager.registry.conversationID(of: r.windowID))
        _ = centered(r)
        dragEdge(r, .bottomRight, dx: 120, dy: -80)
        let chosen = r.controller.preferredSize, spot = r.controller.topLeft
        #expect(chosen == AssistantWindowSize(width: 500, height: 520))
        // 앱을 다시 켠 것처럼 새 관리자 (같은 suite)
        let again = try rig(defaults: r.defaults, conversation: conversation)
        #expect(again.controller.topLeft == spot && again.controller.panel.frame.size == CGSize(width: 500, height: 520), "그 대화의 자리와 이 화면의 크기")
        // 다른 대화의 새 창도 이 화면에서 정한 크기로 열린다
        let other = try rig(defaults: r.defaults)
        #expect(other.controller.preferredSize == chosen && other.controller.panel.frame.size == CGSize(width: 500, height: 520))
        // 다른 화면에는 그 화면의 기억이 없다
        let elsewhere = try rig(defaults: r.defaults, display: "2", conversation: conversation)
        #expect(elsewhere.controller.preferredSize == .standard && elsewhere.controller.panel.frame.size == CGSize(width: 380, height: AssistantWindowGeometry.emptyHeight))
    }

    @Test func aSavedSizeBiggerThanTheScreenIsClampedWhenTheWindowOpensThere() throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        _ = centered(r)
        dragEdge(r, .bottomRight, dx: 400, dy: -300)
        #expect(r.controller.panel.frame.size == CGSize(width: 780, height: 740))
        let small = CGRect(x: -20000, y: -20000, width: 700, height: 600)
        let again = try rig(defaults: r.defaults, visible: small)
        #expect(again.controller.preferredSize == AssistantWindowSize(width: 780, height: 740), "기억은 그대로")
        let frame = again.controller.panel.frame
        #expect(frame.width == 700 - 44 && frame.height == 600, "작은 화면 안으로 (레일 앞까지)")
        #expect(frame.minX >= small.minX && frame.maxX <= small.maxX - 44 && frame.minY >= small.minY && frame.maxY <= small.maxY)
    }

    @Test func movingToASmallerScreenShrinksTheWindowAndMovingBackGivesItsSizeBack() throws {
        let side = AssistantScreen(id: "2", visible: CGRect(x: visible.maxX + 100, y: visible.minY, width: 800, height: 600))
        let r = try rig(extraScreens: [side])
        defer { r.defaults.cleanup() }
        _ = centered(r)
        dragEdge(r, .bottomRight, dx: 300, dy: -250)
        let chosen = r.controller.preferredSize
        r.controller.place(topLeft: CGPoint(x: side.visible.minX + 20, y: side.visible.maxY - 20), onScreen: "2")
        #expect(r.controller.panel.frame.size == CGSize(width: 680, height: 600), "보조 화면 안으로 (높이 690 → 600)")
        #expect(r.controller.panel.frame.maxX <= side.visible.maxX && r.controller.panel.frame.maxY <= side.visible.maxY)
        #expect(r.controller.preferredSize == chosen, "화면에 맞춰 줄여도 사용자가 정한 값은 그대로다")
        r.controller.place(topLeft: CGPoint(x: visible.minX + 400, y: visible.maxY - 100), onScreen: "1")
        #expect(r.controller.panel.frame.size == CGSize(width: chosen.width, height: chosen.height ?? 0), "큰 화면으로 돌아오면 정한 크기")
    }

    @Test func leavingTheAccountForgetsTheChosenSizeToo() throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        r.manager.start()
        defer { r.manager.stop() }
        _ = centered(r)
        dragEdge(r, .right, dx: 60)
        #expect(saved(r) != nil)
        r.account.scope.accountLeft()
        #expect(r.defaults.defaults.data(forKey: AssistantWindowPositionStore.key) == nil)
        #expect(saved(r) == nil)
    }

    @Test func changingTheChatInTheSameWindowKeepsTheWindowsSize() throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        _ = centered(r)
        dragEdge(r, .bottomRight, dx: 100, dy: -100)
        let chosen = r.controller.preferredSize
        r.controller.model.newChat()
        r.controller.applyFrame()
        #expect(r.controller.preferredSize == chosen && r.controller.panel.frame.size == CGSize(width: 480, height: 540), "History · New chat은 창을 바꾸지 않는다")
    }

    @Test func aWindowMovedByTheMouseAfterResizingStaysInsideWithItsNewSize() async throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        _ = centered(r)
        dragEdge(r, .bottomRight, dx: 200, dy: 0)
        let width = r.controller.panel.frame.width
        r.controller.moveSettleDelay = .milliseconds(1)
        r.controller.mouseIsDown = { false }
        r.controller.panel.setFrameOrigin(CGPoint(x: rail.minX - 100, y: r.controller.panel.frame.minY))   // 레일 쪽으로 끌었다
        r.controller.windowDidMove(Notification(name: NSWindow.didMoveNotification))
        for _ in 0..<400 where r.controller.panel.frame.maxX > rail.minX { try await Task.sleep(for: .milliseconds(5)) }
        #expect(r.controller.panel.frame.maxX <= rail.minX && r.controller.panel.frame.width == width, "넓어진 창도 레일 앞까지 들어가고 크기는 그대로")
    }

    // MARK: 진짜 이벤트 경로 (`NSWindow.sendEvent`): 키를 가져가지 않는다

    // 시험 하네스 메모: 앞의 시험들은 `view.mouseDown` · `beginResize`를 직접 불러 `sendEvent`를 건너뛰었다. 비활성 패널은 `sendEvent`에서
    // 왼쪽 누름이 오면 뷰의 `mouseDown`보다 **먼저** 키 창이 되므로 그 시험들은 이 결함을 못 본다. 실제 하네스(CGEvent)는 창이 이미 키 창인 채 시작했다.
    // 아래는 키 창이 아닌 창에 이벤트를 `panel.sendEvent`로 넣는다.

    /// 입력창의 글 영역 (AppKit `NSTextView`)
    private func composerTextView(_ controller: AssistantWindowController) -> NSTextView? {
        func find(_ view: NSView?) -> NSTextView? {
            guard let view else { return nil }
            if let text = view as? NSTextView, text.isEditable { return text }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        return find(controller.panel.contentView)
    }

    @Test func aRealPressOnTheHandleOfAWindowThatIsNotKeyDragsWithoutTakingTheKey() async throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        try await layOut(r.controller)
        defer { r.controller.panel.orderOut(nil) }
        let panel = r.controller.panel
        #expect(!panel.isKeyWindow, "시작: 키 창이 아니다")
        let view = try #require(hit(r.controller, x: panel.frame.width / 2, y: 8) as? AssistantDragRegion.DragNSView)
        let before = panel.frame.origin
        try scriptMouse(&view.tracker, r.controller, points: [CGPoint(x: 500, y: 500), CGPoint(x: 530, y: 490), CGPoint(x: 530, y: 490)])
        panel.sendEvent(try mouseDown(r.controller, x: panel.frame.width / 2, y: 8))
        #expect(panel.frame.origin == CGPoint(x: before.x + 30, y: before.y - 10), "끌기 영역이 누름을 받아 창이 옮겨진다")
        #expect(!panel.isKeyWindow, "끌기는 키를 가져가지 않는다 (다른 앱에 치던 글이 입력창으로 들어가지 않게)")
    }

    @Test func aRealPressOnAnEdgeOfAWindowThatIsNotKeyResizesWithoutTakingTheKey() async throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        _ = centered(r)
        try await layOut(r.controller)
        defer { r.controller.panel.orderOut(nil) }
        let panel = r.controller.panel
        let container = try #require(panel.contentView as? AssistantWindowContentView)
        let view = try #require(container.edgeViews[.right])
        var points = [CGPoint(x: 1000, y: 500), CGPoint(x: 1050, y: 500), CGPoint(x: 1050, y: 500)]
        view.tracker.locate = { _ in points.removeFirst() }
        view.tracker.timeout = 2
        let before = panel.frame
        #expect(!panel.isKeyWindow)
        for type in [NSEvent.EventType.leftMouseDragged, .leftMouseUp] {
            NSApp.postEvent(try mouseEvent(type, r.controller, x: 0, y: 0), atStart: false)
        }
        panel.sendEvent(try mouseDown(r.controller, x: panel.frame.width - 2, y: 200))
        #expect(panel.frame.width == before.width + 50, "가장자리가 누름을 받아 크기가 바뀐다")
        #expect(!panel.isKeyWindow, "크기를 바꾸려다 키를 가져가지 않는다")
    }

    @Test func aRealClickOnTheHandleMakesTheWindowKeyButLeavesTheComposersFocusAlone() async throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        try await layOut(r.controller)
        defer { r.controller.panel.orderOut(nil) }
        let panel = r.controller.panel
        let field = try #require(composerTextView(r.controller))
        #expect(panel.makeFirstResponder(field))
        let responder = try #require(panel.firstResponder)
        let view = try #require(hit(r.controller, x: panel.frame.width / 2, y: 8) as? AssistantDragRegion.DragNSView)
        try scriptMouse(&view.tracker, r.controller, points: [CGPoint(x: 500, y: 500), CGPoint(x: 500, y: 500)])   // 움직이지 않은 누름 = 클릭
        panel.sendEvent(try mouseDown(r.controller, x: panel.frame.width / 2, y: 8))
        try await Task.sleep(for: .milliseconds(150))
        #expect(panel.isKeyWindow, "클릭: 창이 키 창이 된다 (Esc · ⌘W가 듣는다)")
        #expect(panel.firstResponder === responder, "핸들을 눌렀다고 입력창의 포커스를 빼앗지 않는다 (이어 치던 글이 사라지지 않게)")
    }

    @Test func aRealClickOnAHeaderButtonStillMakesTheWindowKey() async throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        try await layOut(r.controller)
        defer { r.controller.panel.orderOut(nil) }
        let panel = r.controller.panel
        // 오른쪽의 History 단추: 끌기 영역이 아닌 첫 곳
        let x = try #require(stride(from: panel.frame.width - 100, through: panel.frame.width - 12, by: 2).first { !(hit(r.controller, x: $0, y: 34) is AssistantDragRegion.DragNSView) })
        #expect(!panel.isKeyWindow)
        panel.sendEvent(try mouseDown(r.controller, x: x, y: 34))
        #expect(panel.isKeyWindow, "SwiftUI 단추를 누르면 창이 키 창이 된다")
        panel.sendEvent(try mouseEvent(.leftMouseUp, r.controller, x: x, y: 34))
    }

    // MARK: 저장한 폭 · 화면 변경 · 정착 · 새 화면 · 쓰기 횟수

    @Test func resizingOnlyTheHeightOnASmallerScreenKeepsTheLargerSavedWidth() throws {
        let side = AssistantScreen(id: "2", visible: CGRect(x: visible.maxX + 100, y: visible.minY, width: 800, height: 600))
        let r = try rig(extraScreens: [side])
        defer { r.defaults.cleanup() }
        _ = centered(r)
        dragEdge(r, .bottomRight, dx: 500, dy: -100)
        #expect(r.controller.preferredSize == AssistantWindowSize(width: 880, height: 540))
        r.controller.place(topLeft: CGPoint(x: side.visible.minX + 20, y: side.visible.maxY - 20), onScreen: "2")
        #expect(r.controller.panel.frame.width == 800, "작은 화면에서는 800으로 줄어 보인다")
        dragEdge(r, .bottom, dy: 20)
        #expect(r.controller.preferredSize.width == 880, "폭 가장자리를 끌지 않았다: 큰 화면에서 정한 폭을 덮어쓰지 않는다")
        #expect(saved(r, display: "2")?.width == 880)
        dragEdge(r, .right, dx: -100)
        #expect(r.controller.preferredSize.width == 700, "폭 가장자리를 끌면 그 폭")
    }

    @Test func aChangeOfTheDisplaysPullsEveryVisibleWindowBackOntoItsScreen() async throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        r.manager.start()
        defer { r.manager.stop() }
        _ = centered(r)
        dragEdge(r, .bottomRight, dx: 300, dy: -100)
        try await layOut(r.controller)
        defer { r.controller.panel.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(300))   // 내용 높이 맞춤이 끝난 뒤: 이 시험은 화면 변경 알림만이 창을 옮긴다
        let chosen = r.controller.preferredSize
        // 해상도가 낮아졌다: 보이는 영역이 600 × 400으로 줄었다
        let smaller = CGRect(x: visible.minX, y: visible.minY, width: 600, height: 400)
        r.screen.visible = smaller
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        for _ in 0..<200 where r.controller.panel.frame.maxX > smaller.maxX - 44 { try await Task.sleep(for: .milliseconds(5)) }
        let frame = r.controller.panel.frame
        #expect(frame.minX >= smaller.minX && frame.maxX <= smaller.maxX - 44 && frame.minY >= smaller.minY && frame.maxY <= smaller.maxY, "새 화면 안 · 레일 앞: \(frame)")
        #expect(r.controller.preferredSize == chosen, "정한 크기 값은 그대로 (화면이 돌아오면 다시 그 크기)")
    }

    @Test func startingAResizeWhileAMoveIsStillSettlingFinishesTheMoveFirst() throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        let conversation = try #require(r.manager.registry.conversationID(of: r.windowID))
        _ = centered(r)
        r.controller.moveSettleDelay = .seconds(60)   // 정착은 부르지 않으면 오지 않는다
        r.controller.mouseIsDown = { false }
        r.controller.panel.setFrameOrigin(CGPoint(x: rail.minX - 100, y: r.controller.panel.frame.minY))   // 레일 쪽으로 끌어다 놓았다
        r.controller.windowDidMove(Notification(name: NSWindow.didMoveNotification))
        r.controller.beginResize(.bottom)
        #expect(r.controller.panel.frame.maxX <= rail.minX, "끌기 정착(레일 밖으로 보정)이 먼저 끝난다 (취소되지 않는다)")
        let position = AssistantWindowPositionStore(defaults: r.defaults.defaults).load().position(conversation: conversation, display: "1")
        #expect(position == r.controller.topLeft, "그 자리를 기억한다")
        r.controller.resize(by: CGPoint(x: 0, y: -30))
        r.controller.endResize()
        #expect(r.controller.panel.frame.maxX <= rail.minX)
    }

    @Test func aWindowMovedToAnotherDisplayRemembersItsSizeThereToo() throws {
        let side = AssistantScreen(id: "2", visible: CGRect(x: visible.maxX + 100, y: visible.minY, width: 1200, height: 800))
        let r = try rig(extraScreens: [side])
        defer { r.defaults.cleanup() }
        _ = centered(r)
        dragEdge(r, .bottomRight, dx: 100, dy: -100)
        let chosen = r.controller.preferredSize
        #expect(saved(r, display: "2") == nil)
        r.controller.moveSettleDelay = .seconds(60)
        r.controller.mouseIsDown = { false }
        r.controller.panel.setFrameOrigin(CGPoint(x: side.visible.minX + 50, y: side.visible.minY + 50))
        r.controller.windowDidMove(Notification(name: NSWindow.didMoveNotification))
        r.controller.finishMove()
        #expect(saved(r, display: "2") == chosen, "옮겨 간 화면에서도 마지막으로 쓴 크기로 연다")
        #expect(saved(r, display: "1") == chosen)
    }

    @Test func aMovedDefaultSizeWindowDoesNotWipeTheSizeSavedForThatDisplay() throws {
        let side = AssistantScreen(id: "2", visible: CGRect(x: visible.maxX + 100, y: visible.minY, width: 1200, height: 800))
        let r = try rig(extraScreens: [side])
        defer { r.defaults.cleanup() }
        let conversation = try #require(r.manager.registry.conversationID(of: r.windowID))
        // 화면 2에는 사용자가 정한 크기가 있다
        var memory = AssistantWindowPositions()
        memory.rememberSize(AssistantWindowSize(width: 500, height: 600), display: "2")
        AssistantWindowPositionStore(defaults: r.defaults.defaults).save(memory)
        let again = try rig(defaults: r.defaults, conversation: conversation, extraScreens: [side])
        again.controller.moveSettleDelay = .seconds(60)
        again.controller.mouseIsDown = { false }
        again.controller.panel.setFrameOrigin(CGPoint(x: side.visible.minX + 50, y: side.visible.minY + 50))
        again.controller.windowDidMove(Notification(name: NSWindow.didMoveNotification))
        again.controller.finishMove()
        #expect(saved(again, display: "2") == AssistantWindowSize(width: 500, height: 600), "기본 크기 창을 옮겼다고 그 화면의 기억을 지우지 않는다")
    }

    /// 쓰기 횟수를 세는 설정 (격리 suite)
    final class CountingDefaults: UserDefaults, @unchecked Sendable {
        nonisolated(unsafe) var writes = 0
        override func set(_ value: Any?, forKey defaultName: String) {
            writes += 1
            super.set(value, forKey: defaultName)
        }
    }

    @Test func endingAResizeWritesTheMemoryOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TaskforceCountingDefaults-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = directory.appending(path: "defaults").path
        let counting = try #require(CountingDefaults(suiteName: suite))
        defer {
            counting.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let r = try rig()
        defer { r.defaults.cleanup() }
        let manager = AssistantWindowManager(
            runtime: r.runtime, shell: r.shell, store: AssistantWindowPositionStore(defaults: counting),
            environment: .init(visibleFrame: { r.screen.visible }, railFrame: { rail }, panelFrame: { nil }, display: { "1" })
        )
        manager.presents = false
        let id = try #require(manager.openNewWindow())
        let controller = try #require(manager.controllers[id])
        controller.place(topLeft: CGPoint(x: visible.minX + 400, y: visible.maxY - 100))
        let before = counting.writes
        controller.beginResize(.bottomRight)
        controller.resize(by: CGPoint(x: 40, y: -40))
        controller.endResize()
        #expect(counting.writes - before == 1, "크기와 자리를 한 번에 쓴다 (⌥ + 화살표를 누르고 있는 동안 두 번씩 쓰지 않는다)")
        let step = counting.writes
        controller.resize(by: .right)
        #expect(counting.writes - step == 1)
        controller.resetSize()
        #expect(counting.writes - step == 2)
    }

    // MARK: 스크롤 · 모서리

    @Test func scrollingOverAnEdgeStripReachesTheContentBelow() async throws {
        final class SpyView: NSView {
            var scrolls = 0
            override func scrollWheel(with event: NSEvent) { scrolls += 1 }
        }
        let spy = SpyView(frame: NSRect(x: 0, y: 0, width: 380, height: 440))
        let container = AssistantWindowContentView(content: spy)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 380, height: 440), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = container
        container.layoutSubtreeIfNeeded()
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 12, wheel2: 0, wheel3: 0))
        let event = try #require(NSEvent(cgEvent: cg))
        for edge in AssistantWindowGeometry.ResizeEdge.allCases {
            let view = try #require(container.edgeViews[edge])
            view.scrollWheel(with: event)
        }
        #expect(spy.scrolls == 8, "5pt 띠 위에서 굴려도 본문이 스크롤한다")
    }

    @Test func theCornerStripsLeaveTheComposerAndTheHeaderButtonsClickable() async throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        try await layOut(r.controller)
        defer { r.controller.panel.orderOut(nil) }
        let w = r.controller.panel.frame.width, h = r.controller.panel.frame.height
        func edge(_ x: CGFloat, _ y: CGFloat) -> AssistantWindowGeometry.ResizeEdge? { (hit(r.controller, x: x, y: y) as? AssistantResizeEdgeView)?.edge }
        let c = AssistantWindowContentView.cornerSize
        // 보내기 단추: 입력 영역 안쪽 여백(12) + 입력창 안쪽 여백(6) 안쪽에 있다 → 모서리 띠(15)에 닿지 않는다
        let sendInset = TFSpace.md + PromptBox.inset.trailing
        let sendBottom = TFSpace.md + PromptBox.inset.bottom
        #expect(sendInset >= c && sendBottom >= c, "보내기 단추가 모서리 띠 밖")
        #expect(edge(w - sendInset - 1, h - sendBottom - 1) == nil && edge(w - sendInset - PromptBox.sendSize / 2, h - sendBottom - PromptBox.sendSize / 2) == nil)
        // 머리의 New chat 단추는 머리 위(핸들 14 + 2)보다 아래에서 시작한다 → 위쪽 모서리 띠(15)에 닿지 않는다
        #expect(AssistantDragHandle.height + 2 >= c)
        #expect(edge(w - 20, c + 2) == nil && edge(20, c + 2) == nil)
        // 입력창의 둥근 모서리(반지름 12, 창 가장자리에서 12pt 안쪽)가 모서리 띠(15)에 걸치는 넓이: 0
        var covered = 0.0
        let step = 0.1
        var x = 0.0
        while x < Double(c) {
            var y = 0.0
            while y < Double(c) {
                let center = Double(TFSpace.md + TFRadius.panel)
                if (x - center) * (x - center) + (y - center) * (y - center) <= Double(TFRadius.panel * TFRadius.panel), x >= Double(TFSpace.md), y >= Double(TFSpace.md) { covered += step * step }
                y += step
            }
            x += step
        }
        #expect(covered == 0, "입력창 모서리와 모서리 띠가 겹치는 넓이 \(covered)pt²")
        #expect(edge(w - 10, h - 10) == .bottomRight && edge(10, h - 10) == .bottomLeft, "모서리 띠는 창 모서리 쪽 15pt")
    }
}
