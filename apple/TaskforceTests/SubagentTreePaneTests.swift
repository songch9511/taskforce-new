import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// 세션 패널 옆줄이 하위 에이전트를 트리로 그린다 (에이전트 트리 T1): 접힘 · 펼침 모델, 50개 자식이 있어도 갱신 중 선택 · 스크롤이 튀지 않고(`SessionEntriesWindowTests`와 같은 방식으로 진짜 창에 올려 잰다),
/// 접힘 · 펼침은 접근성 값("Collapsed" · "Expanded")으로 말한다. 새 문구는 없다 (기존 낱말과 숫자뿐)
@MainActor
struct SubagentTreePaneTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: 견본

    private func child(_ index: Int, parent: String = "root") -> BackgroundTaskEvent {
        .started(taskID: "c\(index)", toolUseID: nil, kind: .agent, name: "Child \(index)", at: at(TimeInterval(index + 1)), parentID: parent, depth: 2, foreground: index.isMultiple(of: 2))
    }

    /// 부모 하나(깊이 1, 백그라운드) 밑에 자식 `count`개 (모두 도는 중)
    private func family(children count: Int) -> BackgroundTaskList {
        var list = BackgroundTaskList()
        list.apply(.started(taskID: "root", toolUseID: nil, kind: .agent, name: "Root agent", at: at(0), parentID: nil, depth: 1, foreground: false), now: at(0))
        for index in 0..<count { list.apply(child(index), now: at(0)) }
        return list
    }

    private func model(_ tasks: BackgroundTaskList = BackgroundTaskList()) -> SessionSidePaneModel {
        let model = SessionSidePaneModel(store: InMemoryBackgroundTaskOpenStore(), clock: { Date(timeIntervalSince1970: 1_800_000_500) })
        model.attach(session: "s1")
        model.tasks = tasks
        return model
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    // MARK: 모델

    @Test func byDefaultTheRootIsOpenAndShowsItsFiftyChildrenWithTheTwoLevelRule() {
        let pane = model(family(children: 50))
        let rows = pane.treeRows
        #expect(rows.count == 51 && rows[0].task.id == "root" && rows[0].isExpanded && rows[0].level == 0)
        #expect(rows.dropFirst().allSatisfy { $0.level == 1 && !$0.hasChildren })
    }

    @Test func foldingTheRootHidesTheChildrenAndSaysHowManyRunAndFailedInExistingWordsOnly() {
        var tasks = family(children: 50)
        tasks.apply(.finished(taskID: "c3", kind: .agent, status: .failed, exitCode: nil, at: at(100)))
        tasks.apply(.finished(taskID: "c4", kind: .agent, status: .done, exitCode: nil, at: at(100)))
        let pane = model(tasks)
        pane.toggleBranch("root", level: 0)
        let rows = pane.treeRows
        #expect(rows.count == 1 && !rows[0].isExpanded && rows[0].hasChildren)
        #expect(rows[0].branchSummary == "Running 48 · Failed 1")
        pane.toggleBranch("root", level: 0)
        #expect(pane.treeRows.count == 51 && pane.treeRows[0].branchSummary == nil)
    }

    @Test func theChoiceSurvivesUpdatesIsForgottenWithTheTaskAndStartsOverOnANewSession() {
        let pane = model(family(children: 5))
        pane.toggleBranch("root", level: 0)
        var updated = family(children: 8)
        updated.apply(.finished(taskID: "c1", kind: .agent, status: .done, exitCode: nil, at: at(50)))
        pane.tasks = updated
        #expect(pane.treeRows.count == 1, "갱신이 와도 접어 둔 분기는 접혀 있다")
        pane.tasks = BackgroundTaskList()
        pane.tasks = family(children: 3)
        #expect(pane.treeRows.count == 4, "일이 목록에서 사라졌다 돌아오면 고른 것을 잊고 기본으로 돌아온다")
        pane.toggleBranch("root", level: 0)
        pane.attach(session: "s2")
        pane.tasks = family(children: 3)
        #expect(pane.treeRows.count == 4, "다른 세션은 기본으로 시작한다")
    }

    @Test func aClosedSessionStillDrawsItsTreeWithStoppedChildren() {
        let now = Date(timeIntervalSince1970: 1_800_000_900)
        let pane = SessionSidePaneModel(store: InMemoryBackgroundTaskOpenStore(), clock: { now })
        pane.attach(session: "s1")
        pane.tasks = family(children: 3)
        pane.setClosed(true)
        #expect(pane.treeRows.count == 4 && pane.treeRows.allSatisfy { $0.task.status == .stopped })
    }

    @Test func theSelectionAndItsTailSurviveUpdatesAndFoldingTheBranchDoesNotCloseIt() async {
        let pane = model(family(children: 50))
        pane.makeTail = { task in BackgroundTaskTailModel(taskID: task.id, read: { _ in .output(.text("ready", hasEarlier: false)) }) }
        pane.expand()
        pane.select("c25")
        let tail = pane.tail
        #expect(pane.selected?.id == "c25" && tail != nil)
        // 갱신: 몇 개가 끝나 줄 순서가 바뀌고 새 자식이 붙는다
        var updated = family(children: 55)
        for index in 0..<20 { updated.apply(.finished(taskID: "c\(index)", kind: .agent, status: index == 7 ? .failed : .done, exitCode: nil, at: at(200 + TimeInterval(index)))) }
        pane.tasks = updated
        #expect(pane.selected?.id == "c25" && pane.tail === tail, "같은 일이 열려 있고 꼬리 읽기도 그대로다")
        pane.toggleBranch("root", level: 0)
        #expect(pane.selected?.id == "c25" && pane.tail === tail, "분기를 접어도 열린 꼬리는 닫히지 않는다")
        #expect(await eventually { pane.tail?.state == .text("ready", hasEarlier: false) })
        pane.back()
        #expect(pane.selected == nil && pane.tail == nil)
    }

    // MARK: 진짜 창에서: 50개 자식 · 갱신 중 스크롤 · 접근성

    private func host<V: View>(_ view: V, width: CGFloat = 256, height: CGFloat = 420) -> (NSWindow, NSHostingView<V>) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    private func settle(_ hosting: NSView, for seconds: TimeInterval = 0.4) async {
        let end = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < end {
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func findScrollView(in root: NSView) -> NSScrollView? {
        var best: NSScrollView?
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView, (scroll.documentView?.frame.height ?? 0) > (best?.documentView?.frame.height ?? 0) { best = scroll }
            view.subviews.forEach(walk)
        }
        walk(root)
        return best
    }

    @Test func fiftyChildrenUpdatingWhileScrolledNeverMoveTheScrollPosition() async throws {
        guard EdgeRailPanelController.screen != nil else { return }
        let pane = model(family(children: 50))
        pane.expand()
        let (window, hosting) = host(SidePaneBody(model: pane, reduceMotion: true))
        defer { window.close() }
        await settle(hosting)
        let scrollView = try #require(findScrollView(in: hosting))
        let content = scrollView.documentView?.frame.height ?? 0
        let visible = scrollView.contentView.bounds.height
        #expect(content > visible * 2, "51줄은 한 화면을 훨씬 넘는다: \(content) / \(visible)")
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: (content - visible) / 2))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        await settle(hosting)
        let before = scrollView.contentView.bounds.origin.y
        #expect(before > 100)
        // 갱신 1: 열 개가 끝나 순서가 바뀐다 · 갱신 2: 새 자식 다섯 · 갱신 3: 하나가 실패한다
        var updated = family(children: 50)
        for index in 0..<10 { updated.apply(.finished(taskID: "c\(index)", kind: .agent, status: .done, exitCode: nil, at: at(100 + TimeInterval(index)))) }
        pane.tasks = updated
        await settle(hosting)
        #expect(abs(scrollView.contentView.bounds.origin.y - before) < 1, "순서가 바뀌어도 스크롤 자리는 그대로: \(scrollView.contentView.bounds.origin.y) / \(before)")
        for index in 50..<55 { updated.apply(child(index), now: at(120)) }
        pane.tasks = updated
        await settle(hosting)
        #expect(abs(scrollView.contentView.bounds.origin.y - before) < 1)
        updated.apply(.finished(taskID: "c30", kind: .agent, status: .failed, exitCode: nil, at: at(130)))
        pane.tasks = updated
        await settle(hosting)
        #expect(abs(scrollView.contentView.bounds.origin.y - before) < 1)
        #expect(pane.treeRows.count == 56)
    }

    @Test func selectingAChildKeepsItOpenWhileTheListBehindItUpdates() async throws {
        guard EdgeRailPanelController.screen != nil else { return }
        let pane = model(family(children: 50))
        pane.makeTail = { task in BackgroundTaskTailModel(taskID: task.id, read: { _ in .output(.text("ready", hasEarlier: false)) }) }
        pane.expand()
        let (window, hosting) = host(SidePaneBody(model: pane, reduceMotion: true))
        defer { window.close() }
        await settle(hosting)
        pane.select("c40")
        await settle(hosting)
        for round in 0..<3 {
            var updated = family(children: 50 + round)
            for index in 0..<(10 * (round + 1)) where index != 40 { updated.apply(.finished(taskID: "c\(index)", kind: .agent, status: .done, exitCode: nil, at: at(200 + TimeInterval(index)))) }
            pane.tasks = updated
            await settle(hosting, for: 0.2)
            #expect(pane.selected?.id == "c40", "갱신 \(round): 열린 일이 그대로다")
        }
        pane.back()
        pane.collapse()
    }

    /// 눌러 폈다 접는 줄의 말: 자식이 있는 줄만 접힘 · 펼침을 **값**으로 말하고 이름에는 새 낱말이 없다 (macOS의 SwiftUI는 단위 시험에서 접근성 나무를 만들지 않아 나무를 훑을 수 없다:
    /// 뷰가 쓰는 값 규칙 `SubagentTreeLook`을 옆줄의 진짜 줄 목록으로 고정하고, 뷰가 모델을 따르는지는 아래 누르기 시험이 본다)
    @Test func theRowsOfTheLivePaneSpeakCollapsedAndExpandedAndFoldingChangesTheValue() {
        var tasks = family(children: 3)
        tasks.apply(.started(taskID: "grand", toolUseID: nil, kind: .agent, name: "Grandchild", at: at(9), parentID: "c0", depth: 3, foreground: true), now: at(9))
        let pane = model(tasks)
        let now = at(30)
        func spoken() -> [(name: String, value: String?)] { pane.treeRows.map { (SubagentTreeLook.accessibilityName($0, now: now), SubagentTreeLook.accessibilityValue($0)) } }
        let before = spoken()
        // 형제는 새것 먼저(c2 · c1 · c0). root(level 0, 펴짐) · c0(level 1, 접힘, 자식 grand)만 값이 있다. 나머지 줄은 값이 없다
        #expect(before.map(\.name) == ["Agent, Root agent, Running", "Agent, Child 2, Running", "Agent, Child 1, Running", "Agent, Child 0, Running, Running 1"])
        #expect(before.map(\.value) == [SessionViewCopy.expanded, nil, nil, SessionViewCopy.collapsed])
        pane.toggleBranch("root", level: 0)
        let folded = spoken()
        #expect(folded.map(\.name) == ["Agent, Root agent, Running, Running 4"] && folded.map(\.value) == [SessionViewCopy.collapsed], "접힌 분기의 끝: 아래 모든 단계의 도는 일 수")
        pane.toggleBranch("root", level: 0)
        pane.toggleBranch("c0", level: 1)
        #expect(spoken().map(\.value) == [SessionViewCopy.expanded, nil, nil, SessionViewCopy.expanded, nil], "c0를 펴면 grand가 c0 바로 아래에 한 줄 늘고 c0는 Expanded다")
        for row in pane.treeRows { #expect(!SubagentTreeLook.accessibilityName(row, now: now).contains(row.task.id)) }
    }

    /// 꺾쇠를 진짜로 누르면 모델이 접히고 뷰의 줄이 줄어든다 (뷰가 모델을 따른다). 줄을 누르면 그 일의 꼬리가 열린다
    @Test func pressingTheChevronFoldsTheBranchInTheDrawnListAndPressingTheRowOpensItsTail() async throws {
        guard EdgeRailPanelController.screen != nil else { return }
        let pane = model(family(children: 6))
        pane.makeTail = { task in BackgroundTaskTailModel(taskID: task.id, read: { _ in .output(.text("ready", hasEarlier: false)) }) }
        pane.expand()
        let (window, hosting) = host(SidePaneBody(model: pane, reduceMotion: true), height: 520)
        defer { window.close() }
        await settle(hosting)
        let scrollView = try #require(findScrollView(in: hosting))
        let drawn = scrollView.documentView?.frame.height ?? 0
        #expect(pane.treeRows.count == 7 && drawn > 7 * 50, "펴진 root 밑에 자식 여섯: \(drawn)")
        // 첫 줄(root)의 꺾쇠: 목록 안쪽 여백 8 + 꺾쇠 칸 앞 여백 8 + 칸의 가운데 10, 줄의 세로 가운데
        let chevron = hosting.convert(NSPoint(x: 26, y: 29), from: scrollView.documentView)
        click(window, hosting, at: chevron)
        #expect(await eventually { pane.treeRows.count == 1 }, "꺾쇠를 누르니 분기가 접혔다")
        await settle(hosting)
        #expect((findScrollView(in: hosting)?.documentView?.frame.height ?? .greatestFiniteMagnitude) < drawn - 5 * 50, "그려진 줄도 줄었다")
        #expect(pane.selected == nil, "꺾쇠는 꼬리를 열지 않는다")
        // 줄의 제목 쪽을 누르면 그 일의 꼬리가 열린다
        let title = hosting.convert(NSPoint(x: 120, y: 29), from: findScrollView(in: hosting)?.documentView)
        click(window, hosting, at: title)
        #expect(await eventually { pane.selected?.id == "root" }, "줄을 누르니 꼬리가 열렸다")
        pane.back()
    }

    private func click(_ window: NSWindow, _ hosting: NSView, at point: CGPoint) {
        let location = hosting.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ) { window.sendEvent(event) }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
}
