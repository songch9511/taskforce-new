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

    struct Rig {
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
        let screen = customVisible ?? visible
        let railFrame = CGRect(x: screen.maxX - 44, y: screen.minY + 400, width: 44, height: 319)
        let manager = AssistantWindowManager(
            runtime: runtime, shell: shell, store: AssistantWindowPositionStore(defaults: store.defaults),
            environment: .init(visibleFrame: { screen }, railFrame: { railFrame }, panelFrame: { nil }, display: { display }, extraScreens: { extraScreens })
        )
        manager.presents = false
        let id = try #require(conversation.flatMap { manager.openWindow(for: $0) } ?? manager.openNewWindow())
        let controller = try #require(manager.controllers[id])
        return Rig(manager: manager, controller: controller, windowID: id, defaults: store, runtime: runtime, shell: shell, account: account)
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

    /// 창 안의 한 점을 누르는 왼쪽 마우스 이벤트 (위가 0)
    private func mouseDown(_ controller: AssistantWindowController, x: CGFloat, y: CGFloat, clickCount: Int = 1) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: x, y: controller.panel.frame.height - y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: controller.panel.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1
        ))
    }

    @Test func pressingTheHandleStartsAWindowDragAndADragLeavesTheKeyAlone() async throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        try await layOut(r.controller)
        defer { r.controller.panel.orderOut(nil) }
        let panel = r.controller.panel
        let view = try #require(hit(r.controller, x: panel.frame.width / 2, y: 8) as? AssistantDragRegion.DragNSView)
        var started: [NSWindow] = []
        view.performDrag = { window, _ in
            started.append(window)
            window.setFrameOrigin(NSPoint(x: window.frame.minX + 40, y: window.frame.minY - 20))   // 끌어서 옮겨졌다
        }
        #expect(!panel.isKeyWindow, "시작: 키 창이 아니다")
        view.mouseDown(with: try mouseDown(r.controller, x: panel.frame.width / 2, y: 8))
        #expect(started == [panel], "누르면 창 끌기를 시작한다")
        #expect(!panel.isKeyWindow, "끌기만으로는 키를 가져가지 않는다 (옮기려다 다른 앱에 치던 글이 입력창으로 들어가지 않게)")
    }

    @Test func aPressWithoutMovingIsAClickAndTheWindowBecomesKey() async throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        try await layOut(r.controller)
        defer { r.controller.panel.orderOut(nil) }
        let panel = r.controller.panel
        let view = try #require(hit(r.controller, x: 200, y: 34) as? AssistantDragRegion.DragNSView)
        var clicks = 0
        view.onClick = { clicks += 1 }
        view.performDrag = { _, _ in }   // 움직이지 않았다
        view.mouseDown(with: try mouseDown(r.controller, x: 200, y: 34))
        #expect(panel.isKeyWindow, "클릭: 창이 키 창이 된다 (Esc가 듣는다)")
        #expect(clicks == 1, "클릭을 알린다: 핸들은 여기서 포커스를 가져가 화살표 키 이동이 시작된다")
        view.performDrag = { window, _ in window.setFrameOrigin(NSPoint(x: window.frame.minX + 10, y: window.frame.minY)) }
        view.mouseDown(with: try mouseDown(r.controller, x: 200, y: 34))
        #expect(clicks == 1, "끈 뒤에는 클릭이 아니다")
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
        view.locate = { _ in points.removeFirst() }
        view.trackTimeout = 2
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
}
