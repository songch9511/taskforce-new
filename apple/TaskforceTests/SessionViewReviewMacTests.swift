import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// 세션 보기 V1 리뷰 반영의 Mac 쪽 (P2: 단계 본문 캐시 · 이 Mac 기록 찾기 · 옆줄 창/내용 맞춤, P3: 접근성 · 복사 단추 · 말풍선 · 꼬리 읽기 직렬화 · 계정).
/// 이 Mac의 실제 Claude 기록 · 임시 폴더 · 클립보드 · 서버를 읽거나 쓰지 않는다 (가짜 읽기 · 가짜 클립보드 · 메모리 저장소)
@MainActor
struct SessionViewReviewMacTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = 0
        var value: Int { lock.withLock { _value } }
        @discardableResult func hit() -> Int { lock.withLock { _value += 1; return _value } }
    }

    final class Box<Value>: @unchecked Sendable {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    private func list(_ events: [BackgroundTaskEvent]) -> BackgroundTaskList {
        var list = BackgroundTaskList()
        for event in events { list.apply(event) }
        return list
    }

    private func started(_ id: String, _ seconds: TimeInterval = 0) -> BackgroundTaskEvent { .started(taskID: id, toolUseID: nil, kind: .command, name: "Run \(id)", at: at(seconds)) }

    // MARK: P2-1 단계 본문 캐시: 읽지 못한 것 · 아직 덜 쓰인 것은 저장하지 않는다

    @Test func aFailedReadOfAStepBodyIsRetriedWhenTheStepIsOpenedAgain() async {
        let state = SessionStepsState()
        let loads = Count()
        let good = ClaudeAppToolDetail(input: "{ }", result: "ok", truncated: false)
        let load: (String) async -> ClaudeAppToolDetail? = { _ in loads.hit() == 1 ? nil : good }
        state.toggle(step: "a", load: load)
        #expect(await eventually { state.details["a"] == SessionStepsState.Detail.none })
        state.toggle(step: "a", load: load)
        #expect(!state.isOpen(step: "a"))
        state.toggle(step: "a", load: load)
        #expect(await eventually { state.details["a"] == .loaded(good) }, "다시 열면 다시 읽는다")
        #expect(loads.value == 2)
    }

    @Test func aBodyWhoseResultIsNotWrittenYetIsReadAgainOnTheNextOpenAndACompleteOneIsKept() async {
        let state = SessionStepsState()
        let loads = Count()
        let early = ClaudeAppToolDetail(input: "{ \"command\": \"sleep 9\" }", result: nil, truncated: false)
        let complete = ClaudeAppToolDetail(input: "{ \"command\": \"sleep 9\" }", result: "done", truncated: false)
        let load: (String) async -> ClaudeAppToolDetail? = { _ in loads.hit() == 1 ? early : complete }
        state.toggle(step: "a", load: load)
        #expect(await eventually { state.details["a"] == .loaded(early) })
        state.toggle(step: "a", load: load)
        state.toggle(step: "a", load: load)
        #expect(await eventually { state.details["a"] == .loaded(complete) }, "결과가 아직 없던 본문은 다시 열 때 다시 읽는다")
        state.toggle(step: "a", load: load)
        state.toggle(step: "a", load: load)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(loads.value == 2 && state.details["a"] == .loaded(complete), "완성된 본문은 다시 읽지 않는다")
    }

    // MARK: 세션이 바뀌면 보던 자리 · 열어 둔 줄이 남지 않는다

    @Test func openingAnotherTaskforceSessionResetsTheScrollPinTheStepStateAndTheLocalLink() {
        let presentation = EdgeSessionPanelPresentation()
        presentation.beginSession("s1")
        presentation.scrollPinned = false
        presentation.steps.toggle(step: "x", load: { _ in nil })
        presentation.localTarget = AgentLocalTranscriptTarget(providerSessionID: "p", cwd: "/w")
        presentation.beginSession("s2")
        #expect(presentation.scrollPinned, "위로 올려 읽던 자리는 다른 세션에 이어지지 않는다")
        #expect(!presentation.steps.isOpen(step: "x") && presentation.localTarget == nil && presentation.local == nil && presentation.pane.sessionKey == "s2")
        presentation.scrollPinned = false
        presentation.beginSession("s2")
        #expect(!presentation.scrollPinned, "같은 세션을 다시 알려도 아무 일도 없다")
    }

    @Test func openingAnotherClaudeSessionForgetsTheOpenStepsOfTheSessionBefore() {
        let presentation = EdgeClaudeAppPanelPresentation()
        presentation.beginSession("s1")
        presentation.steps.toggle(step: "123-0", load: { _ in nil })
        #expect(presentation.steps.isOpen(step: "123-0"))
        presentation.beginSession("s2")
        #expect(!presentation.steps.isOpen(step: "123-0"), "줄 위치 id는 세션 사이에서 겹친다: 앞 세션의 열림이 다른 세션의 같은 id에 붙으면 안 된다")
        #expect(presentation.pane.sessionKey == "s2")
    }

    // MARK: P2-2 이 Mac의 기록 찾기

    private func target(_ id: String) -> AgentLocalTranscriptTarget { AgentLocalTranscriptTarget(providerSessionID: id, cwd: "/Users/tester/proj") }

    @Test func theFollowerKeepsLookingWithABackoffInsteadOfGivingUpAfterThirtyTries() async {
        let calls = Count()
        let follower = SessionLocalFollower(find: { calls.hit(); return nil }, isShown: { true }, taskKey: { "running" }, onChange: { _ in })
        for second in 0...3_000 { await follower.tick(now: TimeInterval(second)) }
        #expect(calls.value > 30, "30번에서 영영 멈추지 않는다")
        #expect(calls.value < 200, "30초 간격 상한: 3000초에 100번 안팎")
        #expect(follower.target == nil)
    }

    @Test func theFollowerNeitherLooksNorCountsWhileThePanelIsHidden() async {
        let calls = Count()
        let shown = Box(false)
        let follower = SessionLocalFollower(find: { calls.hit(); return nil }, isShown: { shown.value }, taskKey: { "running" }, onChange: { _ in })
        for second in 0..<300 { await follower.tick(now: TimeInterval(second)) }
        #expect(calls.value == 0)
        shown.value = true
        await follower.tick(now: 300)
        #expect(calls.value == 1, "보이면 바로 찾는다")
    }

    @Test func theFollowerChecksTheTargetAgainWhenTheTaskStateChangesAndReportsChangedOrVanishedTargets() async {
        let key = Box("running")
        let answer = Box<AgentLocalTranscriptTarget?>(target("p1"))
        let changes = Box<[String?]>([])
        let calls = Count()
        let follower = SessionLocalFollower(
            find: { calls.hit(); return answer.value }, isShown: { true }, taskKey: { key.value }, onChange: { changes.value.append($0?.providerSessionID) }
        )
        await follower.tick(now: 0)
        for second in 1...50 { await follower.tick(now: TimeInterval(second)) }
        #expect(calls.value == 1 && changes.value == ["p1"], "찾은 뒤에는 묻지 않고 같은 값은 다시 알리지 않는다")
        // 새 턴: 어댑터가 Claude 세션을 다시 묶었다
        answer.value = target("p2")
        key.value = "finished"
        await follower.tick(now: 60)
        #expect(calls.value == 2 && changes.value == ["p1", "p2"] && follower.target?.providerSessionID == "p2", "상태가 바뀌면 한 번 다시 확인하고 달라진 값으로 바꾼다")
        // 기록이 사라졌다
        answer.value = nil
        key.value = "running"
        await follower.tick(now: 70)
        #expect(changes.value == ["p1", "p2", nil] && follower.target == nil)
    }

    @Test func aTargetIsCheckedOnceWhenThePanelBecomesVisibleAgain() async {
        let calls = Count()
        let shown = Box(true)
        let follower = SessionLocalFollower(find: { calls.hit(); return target("p1") }, isShown: { shown.value }, taskKey: { "running" }, onChange: { _ in })
        await follower.tick(now: 0)
        shown.value = false
        for second in 1..<100 { await follower.tick(now: TimeInterval(second)) }
        shown.value = true
        await follower.tick(now: 100)
        await follower.tick(now: 101)
        #expect(calls.value == 2, "숨었다 다시 보이면 위치를 한 번 확인한다")
    }

    // MARK: P2-3 옆줄의 창 · 내용 맞춤

    private func visibleClaudePanel(_ w: EdgeSessionsTests.Rig) throws -> (EdgeClaudeAppPanelController, NSRect) {
        w.shell.reduceMotion = true
        let claude = EdgeClaudeAppPanelController(shell: w.shell)
        w.shell.openRailEntry(try #require(w.shell.slots.first { $0.source == .claudeApp(sessionID: EdgeSessionsTests.id(1)) }))
        claude.presentation.headHeight = 40
        claude.presentation.bodyHeight = 300
        #expect(claude.show())
        spin(0.4)
        return (claude, try #require(claude.panelFrame()))
    }

    @Test func theClaudePanelWindowIsResizedByTheSidePaneMutationItselfNotAfterAHop() async throws {
        guard EdgeRailPanelController.screen != nil else { return }
        let w = await EdgeSessionsTests().rig(rows: [1], live: [EdgeSessionsTests.live(1, .busy)])
        let (claude, base) = try visibleClaudePanel(w)
        defer { claude.panel.orderOut(nil) }
        let pane = claude.presentation.pane
        pane.attach(session: EdgeSessionsTests.id(1))
        #expect(claude.panel.frame.width == base.width)
        pane.tasks = list([started("a")])
        #expect(claude.panel.frame.width == base.width + 36 && claude.panel.frame.maxX == base.maxX, "일이 생긴 바로 그 호출에서 띠만큼 넓어진다 (다음 루프를 기다리지 않는다)")
        pane.expand()
        let wide = claude.panel.frame
        #expect(wide.width == base.width + 256 && wide.maxX == base.maxX, "펼치면 바로 왼쪽으로 256: 틀 \(wide) 처음 \(base) 여유 \(pane.room) 계획 \(pane.plan)")
        // 창 틀은 화면 픽셀에 맞춰져 y가 반 포인트까지 달라질 수 있다 (세로 가운데 맞춤의 .5)
        #expect(abs(wide.minY - base.minY) <= 0.5 && wide.height == base.height, "위 · 높이는 그대로: 틀 \(wide) 처음 \(base)")
        pane.collapse()
        #expect(claude.panel.frame.width == base.width + 36)
        pane.tasks = BackgroundTaskList()
        #expect(claude.panel.frame.width == base.width, "일이 없어지면 바로 좁아진다")
    }

    @Test func theTaskforcePanelWindowIsResizedByTheSidePaneMutationItselfToo() async throws {
        guard let screen = EdgeRailPanelController.screen else { return }
        let rig = EdgeExternalSessionsTests().make()
        let runtime = ChatRuntime(gateway: IssueSampleGateway(), scope: rig.scope, now: { Date() }, issueScreens: false)
        let controller = EdgeSessionPanelController(shell: rig.shell, runtime: runtime)
        let issuePanel = NSRect(x: screen.visibleFrame.minX + 1100, y: screen.visibleFrame.minY + 200, width: 380, height: 440)
        controller.issuePanelFrame = { issuePanel }
        controller.presentation.headHeight = 40
        controller.presentation.bodyHeight = 300
        rig.shell.reduceMotion = true
        #expect(controller.show())
        defer { controller.panel.orderOut(nil) }
        spin(0.4)
        let base = EdgeSessionPanelController.frame(issuePanel: issuePanel, height: controller.height())
        let pane = controller.presentation.pane
        pane.attach(session: "s1")
        pane.tasks = list([started("a")])
        #expect(controller.panel.frame.width == base.width + 36 && controller.panel.frame.maxX == base.maxX)
        pane.expand()
        #expect(controller.panel.frame.width == base.width + 256)
        pane.collapse()
        pane.tasks = BackgroundTaskList()
        #expect(controller.panel.frame.width == base.width)
    }

    /// 호스팅 뷰를 창에 넣어 그린다 (SwiftUI의 `onGeometryChange`는 창 안에서만 돈다)
    private func host<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> (NSWindow, NSHostingView<V>) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        spin(0.2)
        return (window, hosting)
    }

    @Test func thePanelContentIsPinnedToTheTrailingEdgeWhileTheWindowCatchesUp() {
        let pane = SessionSidePaneModel(store: InMemoryBackgroundTaskOpenStore())
        pane.attach(session: "s1")
        pane.tasks = list([started("a")])
        let frame = Box(CGRect.zero)
        let view = SessionPanelFrame(pane: pane, reduceMotion: true) { width in
            Color.clear.frame(width: width).frame(maxHeight: .infinity)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame.value = $0 }
        }
        // 창이 아직 모델을 따라오지 못한 한 박자: 창은 내용보다 넓다
        let (window, _) = host(view, width: 900, height: 400)
        defer { window.close() }
        #expect(frame.value.width > 0)
        #expect(abs(frame.value.maxX - 900) < 0.5, "패널(레일 쪽)은 오른쪽 가장자리에 붙어 있다 (가운데로 쏠리지 않는다): maxX \(frame.value.maxX)")
    }

    /// 호스팅 뷰의 가운데 줄에서 실제로 그려진(불투명도 0.5 넘는) 가장 왼쪽 ~ 오른쪽 픽셀 사이의 폭(pt).
    /// `onGeometryChange`는 애니메이션의 중간 값을 알리지 않으므로(처음과 끝만 본다) 그려진 픽셀을 잰다
    private func drawnWidth(_ hosting: NSView) -> CGFloat? {
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / max(hosting.bounds.width, 1)
        let row = rep.pixelsHigh / 2
        var first: Int?
        var last: Int?
        for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: row)?.alphaComponent ?? 0) > 0.5 {
            if first == nil { first = x }
            last = x
        }
        guard let first, let last else { return nil }
        return (CGFloat(last - first + 1) / scale).rounded()
    }

    @Test func theSidePaneNeverAnimatesItsWidthOnlyOpacityAndTransform() {
        let pane = SessionSidePaneModel(store: InMemoryBackgroundTaskOpenStore())
        pane.attach(session: "s1")
        pane.tasks = list([started("a")])
        // 접힘 36 → 펼침 256 (옆줄 폭 + 패널 폭). 움직임을 켠 채 그려진 폭을 프레임마다 잰다
        let view = SessionPanelFrame(pane: pane, reduceMotion: false) { content in Color.blue.frame(width: content).frame(maxHeight: .infinity) }
            .fixedSize(horizontal: true, vertical: false)
        let (window, hosting) = host(view, width: 900, height: 400)
        defer { window.close() }
        let collapsed = EdgePanelMetrics.width + 36
        let expanded = EdgePanelMetrics.width + 256
        #expect(drawnWidth(hosting) == collapsed)
        var seen = Set<CGFloat>()
        pane.expand()
        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            if let width = drawnWidth(hosting) { seen.insert(width) }
            spin(0.008)
        }
        #expect(seen.subtracting([collapsed, expanded]).isEmpty, "폭은 한 번에 바뀐다 (중간 폭이 없다): \(seen.sorted())")
        #expect(seen.contains(expanded))
        seen = []
        pane.collapse()
        let back = Date().addingTimeInterval(0.6)
        while Date() < back {
            if let width = drawnWidth(hosting) { seen.insert(width) }
            spin(0.008)
        }
        #expect(seen.subtracting([collapsed, expanded]).isEmpty && seen.contains(collapsed), "접을 때도 같다: \(seen.sorted())")
    }

    // MARK: P3 꼬리 읽기는 한 번에 하나, 마지막으로 부탁한 것이 이긴다

    /// 읽는 동안 붙잡는 가짜 (메인 밖 스레드에서 불린다)
    final class HeldReads: @unchecked Sendable {
        private let condition = NSCondition()
        private var released: Set<Int> = []
        private var _inFlight = 0
        private var _maxInFlight = 0
        private var _windows: [Int] = []

        func read(window: Int, result: BackgroundTaskTail.Result) -> BackgroundTaskTail.Result {
            condition.lock()
            _windows.append(window)
            _inFlight += 1
            _maxInFlight = max(_maxInFlight, _inFlight)
            let index = _windows.count
            while !released.contains(index) && !released.contains(0) { condition.wait() }
            _inFlight -= 1
            condition.unlock()
            return result
        }

        func release(_ index: Int) {
            condition.lock()
            released.insert(index)
            condition.broadcast()
            condition.unlock()
        }

        func releaseAll() { release(0) }
        var count: Int { condition.lock(); defer { condition.unlock() }; return _windows.count }
        var maxInFlight: Int { condition.lock(); defer { condition.unlock() }; return _maxInFlight }
    }

    @Test func tailReadsNeverOverlapEvenWhenShowEarlierAndTryAgainAreMashed() async {
        let held = HeldReads()
        let tail = BackgroundTaskTailModel(taskID: "a", read: { window in held.read(window: window, result: .output(.text("w\(window)", hasEarlier: true))) }, pause: { _ in })
        tail.start { false }
        #expect(await eventually { held.count == 1 })
        tail.showEarlier()
        tail.retry()
        tail.showEarlier()
        try? await Task.sleep(for: .milliseconds(80))
        held.releaseAll()
        #expect(await eventually { tail.state == .text("w\(tail.window)", hasEarlier: true) })
        #expect(held.maxInFlight == 1, "읽기는 한 번에 하나: 같은 파일을 겹쳐 읽지 않는다")
    }

    @Test func aSlowOlderReadNeverOverwritesTheNewerWindowsResult() async {
        let held = HeldReads()
        let tail = BackgroundTaskTailModel(taskID: "a", read: { window in held.read(window: window, result: .output(.text("w\(window)", hasEarlier: true))) }, pause: { _ in })
        tail.start { false }
        #expect(await eventually { held.count == 1 })
        tail.showEarlier()
        held.release(2)
        try? await Task.sleep(for: .milliseconds(80))
        held.release(1)
        #expect(await eventually { tail.state == .text("w\(tail.window)", hasEarlier: true) }, "마지막으로 부탁한 창의 결과가 남는다")
        try? await Task.sleep(for: .milliseconds(80))
        #expect(tail.state == .text("w\(tail.window)", hasEarlier: true))
        held.releaseAll()
    }

    // MARK: 보안 P3-1 계정과 함께 가는 것

    @Test func anAccountSwitchPrunesTheOpenTimesAndEmptiesTheBoardAndSigningOutEmptiesTheBoard() {
        let rig = EdgeExternalSessionsTests().make(signedIn: false)
        let store = InMemoryBackgroundTaskOpenStore()
        let board = BackgroundTaskBoard()
        rig.shell.backgroundSessions = BackgroundTaskAccount(openStore: store, board: board)
        let alice = UUID(uuidString: "00000000-0000-4000-8000-0000000000a1") ?? UUID()
        let bob = UUID(uuidString: "00000000-0000-4000-8000-0000000000b2") ?? UUID()
        store.setOwner(alice)
        store.markOpened(session: "s", at: t0)
        board.apply(started("a"), session: "s")
        rig.shell.accountChanged(alice)
        #expect(store.openedAt(session: "s") == t0 && board.tasks(session: "s").tasks.count == 1, "다시 켠 뒤 같은 계정의 첫 로그인은 저장해 둔 것을 그대로 둔다")
        rig.shell.accountChanged(bob)
        #expect(store.openedAt(session: "s") == nil && board.sessionCount == 0 && store.owner == bob, "다른 계정: 앞 계정의 열어 본 시각 · 일 목록이 남지 않는다")
        store.markOpened(session: "s", at: t0)
        board.apply(started("b"), session: "s")
        rig.shell.accountChanged(nil)
        #expect(board.sessionCount == 0, "로그아웃: 판을 비운다")
        rig.shell.accountChanged(alice)
        #expect(store.openedAt(session: "s") == nil && store.owner == alice, "다른 계정이 다시 들어오면 저장본의 주인이 달라 비운다")
    }

    @Test func aSavedOpenTimeWithoutAnOwnerIsNotTrustedByTheFirstAccount() {
        let rig = EdgeExternalSessionsTests().make(signedIn: false)
        let store = InMemoryBackgroundTaskOpenStore()
        rig.shell.backgroundSessions = BackgroundTaskAccount(openStore: store, board: BackgroundTaskBoard())
        store.markOpened(session: "s", at: t0)
        rig.shell.accountChanged(UUID(uuidString: "00000000-0000-4000-8000-0000000000a1") ?? UUID())
        #expect(store.openedAt(session: "s") == nil, "주인을 모르는 저장본은 이 계정의 것이 아니다 (끝남 표시와 같은 규칙)")
    }

    // MARK: 보안 P3-4 숨은 복사 아이콘은 눌리지 않는다

    private func click(_ window: NSWindow, _ hosting: NSView, at point: CGPoint) {
        let location = hosting.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ) { window.sendEvent(event) }
        }
        spin(0.05)
    }

    @Test func aHiddenCopyIconCannotBeClickedButARevealedOneCan() {
        let pasteboard = RecordingPasteboard()
        func button(revealed: Bool) -> some View {
            SessionCopyButton(text: "raw **markdown**", alwaysVisible: false, revealed: revealed).environment(\.sessionPasteboard, pasteboard).frame(width: 80, height: 60)
        }
        let (hiddenWindow, hiddenHost) = host(button(revealed: false), width: 80, height: 60)
        defer { hiddenWindow.close() }
        click(hiddenWindow, hiddenHost, at: CGPoint(x: 40, y: 30))
        #expect(pasteboard.copies.isEmpty, "보이지 않는 아이콘 자리를 눌러 복사되면 안 된다")
        let (shownWindow, shownHost) = host(button(revealed: true), width: 80, height: 60)
        defer { shownWindow.close() }
        click(shownWindow, shownHost, at: CGPoint(x: 40, y: 30))
        #expect(pasteboard.copies == ["raw **markdown**"])
    }

    // MARK: P3 접근성: 접힘 · 펼침 상태를 값으로 말하고 시계는 초마다 읽히지 않는다 (E6)
    //
    // SwiftUI는 접근성 클라이언트가 없으면 접근성 노드를 만들지 않는다 (시험 호스트에서 `NSHostingView.accessibilityChildren()`가 비어 있음을 실험으로 확인했다).
    // 그래서 뷰가 그대로 쓰는 말(`SessionAccessibility`)을 고정한다. 뷰에 실제로 붙었는지는 VoiceOver로 사람이 본다 (노트의 미확인 목록).

    @Test func anExpandableRowSaysItsStateAsAValueAndAFailureInItsName() {
        #expect(SessionAccessibility.state(expanded: false) == "Collapsed" && SessionAccessibility.state(expanded: true) == "Expanded")
        #expect(SessionAccessibility.name(SessionViewCopy.steps(5), failed: false) == "5 steps", "묶음 머리의 이름은 단계 수다")
        #expect(SessionAccessibility.name("Bash · Run the copy lint", failed: true) == "Bash · Run the copy lint, Failed", "실패는 값이 아니라 이름에 붙는다 (값은 펼침 상태 하나)")
        #expect(SessionAccessibility.name("Read · pricing.mdx", failed: false) == "Read · pricing.mdx")
    }

    @Test func theClockLabelIsAStaticWorkingAndNeverCarriesTheSeconds() {
        #expect(SessionViewCopy.working == "Working")
        #expect(!SessionViewCopy.working.contains(":") && !SessionViewCopy.working.contains("0"))
        #expect(SessionTime.workingLine(95).contains("1:35"), "보이는 줄에는 m:ss가 있고 접근성 이름에는 없다")
    }

    // MARK: 말풍선은 글 폭에 맞춘다

    @Test func markdownInsideAUsersBubbleHugsItsTextInsteadOfFillingTheRow() {
        let width = Box(CGFloat.zero)
        let view = Message(isUser: true) {
            SessionMarkdownView(source: "ok").onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width.value = $0 }
        }
        .padding(.horizontal, 16)
        .frame(width: 380, height: 120)
        let (window, _) = host(view, width: 380, height: 120)
        defer { window.close() }
        #expect(width.value > 0 && width.value < 80, "말풍선이 글 폭만큼만 자란다: 폭 \(width.value)")
    }

    // MARK: 꼬리 이어 읽기: 새로 붙은 줄만 받고, 자리를 들고 다닌다

    private func agentTurn(_ id: String, _ text: String) -> ClaudeAppTurn { ClaudeAppTurn(id: id, kind: .assistant(text)) }

    @Test func theTailModelAppendsOnlyNewAgentLinesAndHandsTheCursorBackOnTheNextRead() async {
        let first = agentTurn("t1", "one"), second = agentTurn("t2", "two"), third = agentTurn("t3", "three")
        let c1 = BackgroundTaskTail.Cursor(size: 10, position: 10), c2 = BackgroundTaskTail.Cursor(size: 20, position: 20), c3 = BackgroundTaskTail.Cursor(size: 30, position: 30)
        let seen = Box<[BackgroundTaskTail.Cursor?]>([])
        let step = Count()
        let tail = BackgroundTaskTailModel(taskID: "a", update: { _, cursor in
            seen.value.append(cursor)
            switch step.hit() {
            case 1: return .replace(.output(.agent([first], hasEarlier: true)), c1)
            case 2: return .unchanged
            case 3: return .append([second], c2)
            default: return .append([third], c3)
            }
        }, pause: { _ in })
        await tail.readOnce()
        #expect(tail.state == .agent([first], hasEarlier: true))
        await tail.readOnce()
        #expect(tail.state == .agent([first], hasEarlier: true), "그대로이면 화면을 건드리지 않는다")
        await tail.readOnce()
        #expect(tail.state == .agent([first, second], hasEarlier: true), "새 줄만 덧붙는다")
        await tail.readOnce()
        #expect(tail.state == .agent([first, second, third], hasEarlier: true))
        #expect(seen.value == [nil, c1, c1, c2], "읽을 때마다 앞 읽기가 남긴 자리를 돌려준다 (그대로였던 읽기는 자리를 바꾸지 않는다)")
    }

    @Test func appendedAgentLinesAreCappedAndTheTryAgainReadStartsFromScratch() async {
        let turns = (1...5).map { agentTurn("t\($0)", "line \($0)") }
        let seen = Box<[BackgroundTaskTail.Cursor?]>([])
        let step = Count()
        let cursor = BackgroundTaskTail.Cursor(size: 1, position: 1)
        let tail = BackgroundTaskTailModel(taskID: "a", limits: BackgroundTaskTail.Limits(maxTurns: 3), update: { _, since in
            seen.value.append(since)
            switch step.hit() {
            case 1: return .replace(.output(.agent(Array(turns[0..<2]), hasEarlier: false)), cursor)
            case 2: return .append(Array(turns[2..<5]), cursor)
            default: return .replace(.output(.agent([turns[4]], hasEarlier: false)), cursor)
            }
        }, pause: { _ in })
        await tail.readOnce()
        await tail.readOnce()
        #expect(tail.state == .agent(Array(turns[2..<5]), hasEarlier: true), "상한을 넘으면 오래된 줄부터 버리고 앞이 더 있다고 알린다")
        tail.retry()
        #expect(await eventually { tail.state == .agent([turns[4]], hasEarlier: false) })
        #expect(seen.value == [nil, cursor, nil], "Try again은 자리 없이 처음부터 읽는다")
    }

    // MARK: 같은 글을 다시 해석하지 않는다 (마크다운 판) · 같은 대화면 타임라인을 다시 만들지 않는다

    @Test func markdownIsParsedOncePerSourceAndTheCacheIsBoundedAndClearable() {
        let cache = SessionMarkdownCache()
        let a = cache.blocks(for: "**a**")
        #expect(cache.blocks(for: "**a**") == a && cache.parses == 1, "같은 글은 한 번만 해석한다")
        _ = cache.blocks(for: "b")
        #expect(cache.parses == 2)
        for index in 0..<(SessionMarkdownCache.capacity + 5) { _ = cache.blocks(for: "x\(index)") }
        let before = cache.parses
        _ = cache.blocks(for: "x\(SessionMarkdownCache.capacity + 4)")
        #expect(cache.parses == before, "가장 새 글은 남아 있다")
        _ = cache.blocks(for: "**a**")
        #expect(cache.parses == before + 1, "상한을 넘으면 오래된 글부터 버린다")
        cache.removeAll()
        _ = cache.blocks(for: "**a**")
        #expect(cache.parses == before + 2, "비우면 다시 해석한다")
    }

    @Test func theTimelineIsRebuiltOnlyWhenItsInputChanges() {
        let memo = SessionTimelineMemo<[Int], Int>()
        var built = 0
        func value(_ input: [Int]) -> Int { memo.value(for: input) { built += 1; return input.reduce(0, +) } }
        #expect(value([1, 2]) == 3 && value([1, 2]) == 3 && memo.builds == 1 && built == 1, "같은 입력이면 지난번 것")
        #expect(value([1, 2, 3]) == 6 && memo.builds == 2)
        memo.reset()
        #expect(value([1, 2, 3]) == 6 && memo.builds == 3, "세션을 바꾸면(reset) 처음부터")
    }

    @Test func thePanelPresentationsKeepOneTimelineMemoPerSessionAndForgetItWhenTheSessionChanges() {
        let claude = EdgeClaudeAppPanelPresentation()
        let input = ClaudeTimelineInput(turns: [ClaudeAppTurn(id: "a", kind: .user("hi")), ClaudeAppTurn(id: "b", kind: .assistant("yo"))], state: .finished)
        claude.beginSession("s1")
        let first = claude.timeline.value(for: input) { ClaudeTimeline(input) }
        _ = claude.timeline.value(for: input) { ClaudeTimeline(input) }
        #expect(claude.timeline.builds == 1 && first.entries.contains { if case .footer = $0 { true } else { false } } && first.turns.count == 2)
        claude.beginSession("s2")
        _ = claude.timeline.value(for: input) { ClaudeTimeline(input) }
        #expect(claude.timeline.builds == 2, "다른 세션의 타임라인은 이어 쓰지 않는다")
        let taskforce = EdgeSessionPanelPresentation()
        let panelInput = SessionPanelTimelineInput(turns: [], steps: [], state: .finished)
        taskforce.beginSession("s1")
        _ = taskforce.timeline.value(for: panelInput) { SessionPanelTimeline(panelInput) }
        _ = taskforce.timeline.value(for: panelInput) { SessionPanelTimeline(panelInput) }
        #expect(taskforce.timeline.builds == 1)
        taskforce.beginSession("s2")
        _ = taskforce.timeline.value(for: panelInput) { SessionPanelTimeline(panelInput) }
        #expect(taskforce.timeline.builds == 2)
    }

    // MARK: 옆줄 목록은 도는 일이 있을 때만 1초마다 다시 그린다

    @Test func theSidePaneClockTicksOnlyWhileSomethingRuns() {
        #expect(SidePaneClock.ticks(list([started("a")])))
        #expect(!SidePaneClock.ticks(BackgroundTaskList()), "일이 없다")
        let finished = list([started("a"), .finished(taskID: "a", kind: nil, status: .done, exitCode: 0, at: at(5))])
        #expect(!SidePaneClock.ticks(finished), "끝난 일뿐이면 목록을 1초마다 다시 그리지 않는다")
        #expect(SidePaneClock.ticks(list([started("a"), started("b", 1), .finished(taskID: "a", kind: nil, status: .done, exitCode: 0, at: at(5))])))
        let running = list([started("a")]).ordered[0]
        let done = finished.ordered[0]
        #expect(SidePaneClock.ticks(running) && !SidePaneClock.ticks(done), "꼬리의 머리도 도는 일만 초를 센다")
    }
}
