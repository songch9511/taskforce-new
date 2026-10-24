import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// 프로젝트 이슈 목록 맨 위의 Sessions 묶음 (에이전트 트리 T3m)의 Mac 쪽: 합집합이 이슈 목록 규칙을 따르고, 목록에서 세션 패널이 열리고 닫히며, 자식 줄을 누르면 패널의 옆줄이 그 일의 꼬리 보기로 가고,
/// 열기 지표가 한 번만 나가고, 그리는 동안은 기록 파일을 읽지 않는다. 진짜 창에서 20개 세션 · 각 50개 자식이 끊기지 않게 그려지는지 잰다. 서버 · 계정 · 실제 `~/.claude`는 없다 (가짜 서버 · 가짜 면)
@MainActor
struct ProjectSessionsTests {
    typealias Fx = IssueSnapshotData

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    final class SendCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int { lock.withLock { _calls } }
        var send: @Sendable () async -> Bool {
            { [self] in
                lock.withLock { _calls += 1 }
                return true
            }
        }
    }

    struct Rig {
        let shell: EdgeShellModel
        let issues: IssueRuntime
        let board: BackgroundTaskBoard
        let transcripts: TranscriptFake
        let shown: SendCounter
        let opened: SendCounter
        let finds: FindCounter
    }

    final class FindCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.withLock { _count } }
        func bump() { lock.withLock { _count += 1 } }
    }

    private func make(sessions: IssueSampleGateway.SessionScenario = .basic, connect: Bool = true) async -> Rig {
        let gateway = IssueSampleGateway()
        gateway.sessions = sessions
        let contextGateway = IssueSampleContextGateway()
        let scope = AccountScope(currentAccount: { SampleData.userID })
        let shown = SendCounter(), opened = SendCounter()
        let metrics = AgentTreeMetrics(
            projectSessions: AgentTreeOpenedMetric(send: shown.send, scope: scope), subagentRow: AgentTreeOpenedMetric(send: opened.send, scope: scope)
        )
        let issues = IssueRuntime(gateway: gateway, scope: scope, agentTree: metrics)
        let contexts = WorkContextStore(gateway: contextGateway, scope: scope)
        let shell = EdgeShellModel(schedule: { _, _ in EdgeTimer() }, clock: { Date() }, contexts: contexts, chatsEnabled: true, windowsEnabled: true, issues: issues)
        shell.update(Fx.snapshot(seeds: Fx.seeds))
        await contexts.refresh()
        await issues.numbers.ensure(Fx.seeds.map { Fx.issue($0.number) })
        await issues.sessions.refresh()
        shell.sessionsChanged()
        let board = BackgroundTaskBoard()
        let transcripts = TranscriptFake()
        let finds = FindCounter()
        if connect {
            shell.projectSessions.connect(
                board: board,
                findTarget: { _ in
                    finds.bump()
                    return AgentLocalTranscriptTarget(providerSessionID: "claude-session", cwd: "/Users/tester/proj")
                },
                makeSource: { _, _ in transcripts }
            )
        }
        return Rig(shell: shell, issues: issues, board: board, transcripts: transcripts, shown: shown, opened: opened, finds: finds)
    }

    private func openProject(_ rig: Rig, _ id: UUID = Fx.taskforce) {
        rig.shell.openAllWork()
        rig.shell.openList(.project(id))
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private func list(_ rig: Rig, _ id: UUID = Fx.taskforce) -> IssueListContent? { rig.shell.issueList(.project(id)) }

    // MARK: 합집합

    @Test func theGroupHoldsEachSessionOfTheProjectsIssuesOnceInTheIssueDetailOrder() async throws {
        let rig = await make(sessions: .nine)
        openProject(rig)
        let content = try #require(list(rig))
        let items = rig.shell.projectSessionItems(of: content)
        #expect(items.count == 9, "아홉 세션은 모두 이슈 139 · 141 둘에 묶여 있어도 한 번씩")
        #expect(Set(items.map(\.id)).count == 9)
        #expect(items.map(\.id) == AgentSessionRules.listOrder(items).map(\.id), "이슈 상세 Sessions 목록과 같은 차례")
    }

    @Test func sessionsOfOtherProjectsAreNotInTheGroupAndAProjectWithoutSessionsHasNoGroup() async throws {
        let rig = await make(sessions: .basic)
        openProject(rig)
        #expect(rig.shell.projectSessionItems(of: try #require(list(rig))).count == 3)
        // Shape launch의 이슈(150 · 151)에는 세션이 없다
        #expect(rig.shell.projectSessionItems(of: try #require(list(rig, Fx.shape))).isEmpty, "다른 프로젝트의 세션은 섞이지 않는다 (묶음 없음)")
        let none = await make(sessions: .none)
        openProject(none)
        #expect(none.shell.projectSessionItems(of: try #require(list(none))).isEmpty)
    }

    @Test func aSessionBoundToIssuesOfTwoProjectsNamesTheOtherOneAndNothingElse() async {
        let rig = await make()
        let shared = sessionItem(1, issues: [139, 150])
        #expect(rig.shell.sharedProjectNames(of: shared, besides: Fx.taskforce) == "Shape launch", "Taskforce 목록에서는 Shape launch를")
        #expect(rig.shell.sharedProjectNames(of: shared, besides: Fx.shape) == "Taskforce 0.2.0", "Shape 목록에서는 Taskforce를")
        #expect(rig.shell.sharedProjectNames(of: sessionItem(2, issues: [139, 141]), besides: Fx.taskforce) == nil, "한 프로젝트의 이슈 둘은 공유가 아니다")
        #expect(rig.shell.sharedProjectNames(of: sessionItem(3, issues: [139, 156]), besides: Fx.taskforce) == nil, "보관한 프로젝트는 세지 않는다")
    }

    // MARK: 목록에서 세션 패널

    @Test func aSessionRowOfTheProjectListOpensTheSessionPanelAndTheSameRowClosesIt() async {
        let rig = await make()
        openProject(rig)
        rig.shell.openSession(Fx.session(1))
        #expect(rig.shell.sessionPanelID == Fx.session(1) && rig.shell.sessionPanelShown, "프로젝트 목록에서도 세션 패널이 열린다")
        rig.shell.reconcileIssues()
        #expect(rig.shell.sessionPanelID == Fx.session(1), "맞추기가 목록 위의 세션 패널을 닫지 않는다")
        rig.shell.openSession(Fx.session(2))
        #expect(rig.shell.sessionPanelID == Fx.session(2), "다른 세션이면 바꾼다")
        rig.shell.openSession(Fx.session(2))
        #expect(rig.shell.sessionPanelID == nil, "같은 세션을 다시 누르면 닫는다")
    }

    @Test func otherListsAndTheProjectsScreenStillHaveNoSessionPanel() async {
        let rig = await make()
        rig.shell.openAllWork()
        rig.shell.openSession(Fx.session(1))
        #expect(rig.shell.sessionPanelID == nil, "Projects 화면")
        rig.shell.openList(.ungrouped)
        rig.shell.openSession(Fx.session(1))
        #expect(rig.shell.sessionPanelID == nil, "Ungrouped 목록 (세션 묶음이 없다)")
    }

    @Test func leavingTheProjectListOrPressingEscapeClosesTheSessionPanelAsBefore() async {
        let rig = await make()
        openProject(rig)
        rig.shell.openSession(Fx.session(1))
        #expect(rig.shell.escapeIssues(), "Esc는 세션 패널부터 닫는다")
        #expect(rig.shell.sessionPanelID == nil && rig.shell.nav.current == .list(.project(Fx.taskforce)), "목록은 그대로")
        rig.shell.openSession(Fx.session(1))
        rig.shell.openIssue(Fx.issue(139))
        #expect(rig.shell.sessionPanelID == nil, "이슈 상세로 가면 닫힌다")
        rig.shell.goBack()
        rig.shell.openSession(Fx.session(1))
        #expect(rig.shell.sessionPanelID == Fx.session(1), "상세에서 돌아온 목록에서 다시 열 수 있다")
        rig.shell.goBack()
        #expect(rig.shell.sessionPanelID == nil, "목록에서 뒤로 가면 닫힌다")
    }

    // MARK: 자식 줄

    @Test func aChildRowOpensTheSessionPanelWithoutClosingAnOpenOneAndAsksItsSideRailToRevealTheTask() async {
        let rig = await make()
        openProject(rig)
        var revealed: [(UUID, String)] = []
        rig.shell.onRevealSessionTask = { session, task in revealed.append((session, task)) }
        rig.shell.openProjectSessionTask(session: Fx.session(1), task: "child-1", subagent: true)
        #expect(rig.shell.sessionPanelID == Fx.session(1) && revealed.count == 1 && revealed[0].0 == Fx.session(1) && revealed[0].1 == "child-1")
        rig.shell.openProjectSessionTask(session: Fx.session(1), task: "child-2", subagent: true)
        #expect(rig.shell.sessionPanelID == Fx.session(1), "이미 열려 있으면 닫지 않는다")
        #expect(revealed.map(\.1) == ["child-1", "child-2"])
        rig.shell.openProjectSessionTask(session: Fx.session(2), task: "other", subagent: true)
        #expect(rig.shell.sessionPanelID == Fx.session(2), "다른 세션의 자식이면 그 세션 패널로 바뀐다")
    }

    @Test func openingAChildRowSendsTheSubagentMetricOnce() async {
        let rig = await make()
        openProject(rig)
        for index in 0..<4 { rig.shell.openProjectSessionTask(session: Fx.session(1), task: "c\(index)", subagent: true) }
        #expect(await eventually { rig.opened.calls == 1 })
        try? await Task.sleep(for: .milliseconds(40))
        #expect(rig.opened.calls == 1 && rig.shown.calls == 0)
    }

    @Test func aBackgroundCommandRowOfTheProjectScreenIsNotASubagentOpen() async {
        let rig = await make()
        openProject(rig)
        rig.shell.openProjectSessionTask(session: Fx.session(1), task: "build", subagent: false)
        try? await Task.sleep(for: .milliseconds(40))
        #expect(rig.opened.calls == 0 && rig.shell.sessionPanelID == Fx.session(1), "패널은 열리지만 하위 에이전트 지표는 아니다")
    }

    @Test func openingATaskTailFromEitherSidePaneCountsAsOpeningASubagentRowButACommandDoesNot() async {
        let rig = await make()
        let agent = BackgroundTask(id: "a1", kind: .agent, name: "Research")
        let command = BackgroundTask(id: "b1", kind: .command, name: "Build")
        _ = rig.shell.makeBackgroundTail("session", "/Users/tester/proj", command)
        try? await Task.sleep(for: .milliseconds(40))
        #expect(rig.opened.calls == 0, "백그라운드 명령의 꼬리는 하위 에이전트 줄이 아니다")
        _ = rig.shell.makeBackgroundTail("session", "/Users/tester/proj", agent)
        _ = rig.shell.makeBackgroundTail("session", "/Users/tester/proj", agent)
        #expect(await eventually { rig.opened.calls == 1 }, "두 패널이 같이 쓰는 꼬리 열기 길에서 센다")
        try? await Task.sleep(for: .milliseconds(40))
        #expect(rig.opened.calls == 1)
    }

    // MARK: 계정

    @Test func changingTheAccountForgetsWhichRowsWereOpen() async {
        let rig = await make()
        let first = UUID(), second = UUID()
        rig.shell.accountChanged(first)
        let item = sessionItem(1, issues: [139])
        rig.shell.projectSessions.toggle(item)
        #expect(rig.shell.projectSessions.isExpanded(item.id))
        rig.shell.accountChanged(second)
        #expect(!rig.shell.projectSessions.isExpanded(item.id), "다른 계정에는 앞 계정의 펼침이 없다")
    }

    // MARK: 옆줄: 프로젝트 화면에서 온 부탁

    private func family(_ count: Int) -> BackgroundTaskList {
        var tasks = BackgroundTaskList()
        tasks.apply(.started(taskID: "root", toolUseID: nil, kind: .agent, name: "Root", at: t0, parentID: nil, depth: 1, foreground: false), now: t0)
        for index in 0..<count {
            tasks.apply(.started(taskID: "c\(index)", toolUseID: nil, kind: .agent, name: "Child \(index)", at: t0, parentID: "root", depth: 2, foreground: true), now: t0)
        }
        return tasks
    }

    @Test func theSideRailOpensEvenWhenItWasHiddenAndSelectsTheTaskItWasAskedFor() {
        let pane = SessionSidePaneModel(store: InMemoryBackgroundTaskOpenStore(), clock: { Date(timeIntervalSince1970: 1_800_000_500) })
        pane.attach(session: "s1")
        var tasks = family(3)
        for id in ["root", "c0", "c1", "c2"] { tasks.apply(.finished(taskID: id, kind: .agent, status: .done, exitCode: nil, at: t0.addingTimeInterval(5))) }
        pane.tasks = tasks
        pane.makeTail = { task in BackgroundTaskTailModel(taskID: task.id, read: { _ in .output(.text("ready", hasEarlier: false)) }) }
        pane.expand()
        pane.collapse()
        #expect(!pane.visible, "다 끝났고 열어 본 줄이라 옆줄이 없다")
        #expect(pane.reveal("c1") && pane.expanded && pane.selected?.id == "c1" && pane.tail != nil, "펼침이 곧 보이는 것이다")
        pane.back()
        #expect(!pane.reveal("ghost") && pane.selected == nil, "목록에 없는 일은 아무것도 하지 않는다")
    }

    @Test func aRequestBeforeTheTaskListArrivesWaitsAndOpensTheTailOnceTheTaskIsThere() {
        let presentation = EdgeSessionPanelPresentation()
        presentation.requestReveal(session: "s1", taskID: "c1")
        #expect(presentation.hasPendingReveal, "패널이 아직 그 세션이 아니다")
        presentation.beginSession("s1")
        presentation.pane.makeTail = { task in BackgroundTaskTailModel(taskID: task.id, read: { _ in .output(.text("ready", hasEarlier: false)) }) }
        presentation.tryReveal()
        #expect(presentation.hasPendingReveal && presentation.pane.selected == nil, "일 목록이 아직 비었다: 기다린다")
        presentation.pane.tasks = family(3)
        presentation.tryReveal()
        #expect(!presentation.hasPendingReveal && presentation.pane.selected?.id == "c1" && presentation.pane.expanded)
    }

    @Test func aRequestForAnotherSessionThanTheOneShownWaitsInsteadOfOpeningTheWrongTail() {
        let presentation = EdgeSessionPanelPresentation()
        presentation.beginSession("s1")
        presentation.pane.tasks = family(3)
        presentation.requestReveal(session: "s2", taskID: "c1")
        #expect(presentation.hasPendingReveal && presentation.pane.selected == nil, "다른 세션의 일은 이 옆줄에서 열지 않는다")
        presentation.beginSession("s2")
        presentation.pane.tasks = family(3)
        presentation.tryReveal()
        #expect(presentation.pane.selected?.id == "c1" && !presentation.hasPendingReveal)
    }

    @Test func collapseTreeHeaderOpensMainChatWithoutFoldingSubagentBranches() async {
        guard EdgeRailPanelController.screen != nil else { return }
        let pane = SessionSidePaneModel(store: InMemoryBackgroundTaskOpenStore())
        pane.usesAgentCanvas = true
        pane.attach(session: "s")
        pane.tasks = family(3)
        let view = AgentTreeCanvas(root: AgentTreeRoot(title: "Parent", agent: .claudeCode), rows: pane.canvasRows, now: t0,
            rootExpanded: Binding(get: { pane.rootExpanded }, set: { pane.rootExpanded = $0 }),
            focusedID: Binding(get: { pane.focusedCardID }, set: { pane.focusedCardID = $0 }),
            onOpen: { id in if let id { pane.openAgentChat(id) } else { pane.selectRootInTree() } }, onToggle: { _ in }, onCollapse: { pane.openRootChat() })
        let (window, hosting) = host(view, width: 784, height: 640)
        defer { window.close() }
        await settle(hosting)
        let point = NSPoint(x: 720, y: hosting.isFlipped ? 22 : hosting.bounds.height - 22)
        let location = hosting.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                window.sendEvent(event)
            }
        }
        #expect(await eventually { pane.rootChatOpen })
        #expect(pane.allowsRootInput && pane.rootExpanded && pane.canvasRows.count == 4)
        pane.returnToTree()
        #expect(pane.showsTree && pane.rootExpanded)
    }

    @Test func discoveredTreeResizesTheActualWindowAndOpeningAnimationCannotRestoreTheNarrowFrame() async throws {
        guard let screen = EdgeRailPanelController.screen else { return }
        let rig = await EdgeSessionsTests().rig(rows: [1], live: [EdgeSessionsTests.live(1, .busy)])
        rig.shell.reduceMotion = false
        let events = family(3).tasks.map { task in
            BackgroundTaskEvent.started(taskID: task.id, toolUseID: task.toolUseID, kind: task.kind, name: task.name,
                at: task.startedAt, parentID: task.parentID, depth: task.depth, foreground: task.foreground)
        }
        rig.shell.makeConversation = { id, cwd in
            ClaudeAppConversation(sessionID: id, cwd: cwd,
                source: SessionViewSnapshotTests.SampleSource(turns: [], signals: ClaudeAppTranscriptSignals(background: events)))
        }
        let controller = EdgeClaudeAppPanelController(shell: rig.shell)
        rig.shell.openRailEntry(try #require(rig.shell.slots.first { $0.source == .claudeApp(sessionID: EdgeSessionsTests.id(1)) }))
        controller.presentation.headHeight = 40
        controller.presentation.bodyHeight = 300
        #expect(controller.show())
        defer { controller.panel.orderOut(nil) }
        #expect(await eventually { controller.presentation.pane.hasAgentTree })
        try? await Task.sleep(for: .milliseconds(500))
        #expect(controller.presentation.pane.hasAgentTree, "The discovered family must still be attached")
        #expect(controller.presentation.shown && controller.panel.isVisible)
        let expectedHeight = min(640, screen.visibleFrame.height - 24)
        #expect(abs(controller.panel.frame.width - controller.presentation.pane.canvasWidth) < 1)
        #expect(controller.panel.frame.width > EdgePanelMetrics.width)
        #expect(abs(controller.panel.frame.height - expectedHeight) < 1)
        controller.presentation.pane.openRootChat()
        #expect(abs(controller.panel.frame.width - EdgePanelMetrics.width) < 1)
        controller.presentation.pane.returnToTree()
        #expect(abs(controller.panel.frame.width - controller.presentation.pane.canvasWidth) < 1)
        controller.presentation.pane.openAgentChat(try #require(controller.presentation.pane.tasks.tasks.first?.id))
        #expect(controller.presentation.pane.showsTree)
        #expect(abs(controller.panel.frame.width - controller.presentation.pane.canvasWidth) < 1)
        controller.presentation.pane.returnToTree()
        #expect(abs(controller.panel.frame.width - controller.presentation.pane.canvasWidth) < 1)
    }

    @Test func treeRootAllowsInputButSelectingChildDisablesAndResignsRootFocus() {
        let pane = SessionSidePaneModel(store: InMemoryBackgroundTaskOpenStore())
        pane.usesAgentCanvas = true
        pane.attach(session: "s")
        var resigned = 0
        pane.onRootInputHidden = { resigned += 1 }
        #expect(pane.allowsRootInput, "A session with no children opens its original composer")
        pane.tasks = family(2)
        #expect(pane.allowsRootInput && pane.showsTree && resigned > 0)
        pane.openRootChat()
        #expect(pane.allowsRootInput)
        let before = resigned
        pane.returnToTree()
        #expect(pane.allowsRootInput && pane.showsTree && resigned > before)
        pane.openRootChat()
        #expect(pane.reveal("c0"))
        #expect(!pane.allowsRootInput)
    }

    @Test func workspaceSelectionKeepsRootConversationMounted() async {
        let pane = SessionSidePaneModel(store: InMemoryBackgroundTaskOpenStore())
        pane.usesAgentCanvas = true
        pane.attach(session: "workspace")
        pane.tasks = family(2)
        var mounts = 0
        let view = SessionPanelFrame(pane: pane, reduceMotion: true,
            root: AgentTreeRoot(title: "Parent", agent: .claudeCode)) { width in
            Text("Root conversation").frame(width: width).onAppear { mounts += 1 }
        }
        let (window, hosting) = host(view, width: 784, height: 640)
        defer { window.close() }
        await settle(hosting)
        #expect(mounts == 1)
        for id in ["c0", "c1"] {
            pane.openAgentChat(id)
            await settle(hosting)
            #expect(pane.showsTree && !pane.allowsRootInput)
            #expect(mounts == 1, "Selecting a child must not restart the retained root transcript reader")
        }
        pane.selectRootInTree()
        await settle(hosting)
        #expect(pane.showsTree && pane.allowsRootInput && mounts == 1)
        pane.openRootChat()
        await settle(hosting)
        pane.returnToTree()
        await settle(hosting)
        #expect(pane.showsTree && mounts == 1)
    }

    @Test func childDraftsStayWithTheirNodeAndClearAtSessionBoundary() {
        let pane = SessionSidePaneModel(store: InMemoryBackgroundTaskOpenStore())
        pane.usesAgentCanvas = true
        pane.attach(session: "family")
        pane.tasks = family(2)
        pane.setDraft("hidden write", for: "c0")
        #expect(pane.draft(for: "c0").isEmpty)
        pane.openAgentChat("c0")
        pane.setDraft("Research note", for: "c0")
        pane.setDraft("wrong target", for: "c1")
        pane.openAgentChat("c1")
        pane.setDraft("Copy note", for: "c1")
        #expect(pane.showsTree && !pane.allowsRootInput)
        #expect(pane.draft(for: "c0") == "Research note")
        #expect(pane.draft(for: "c1") == "Copy note")
        pane.selectRootInTree()
        #expect(pane.showsTree && pane.allowsRootInput && pane.selectedID == nil)
        pane.setDraft("stale editor", for: "c1")
        #expect(pane.draft(for: "c1") == "Copy note")
        pane.attach(session: nil)
        pane.attach(session: "family")
        #expect(pane.draft(for: "c0").isEmpty && pane.draft(for: "c1").isEmpty)
    }

    @Test func acceptedChildDraftReconcilesAcrossSelectionButNeverOverwritesNewTextOrAccount() {
        let pane = SessionSidePaneModel(store: InMemoryBackgroundTaskOpenStore())
        pane.usesAgentCanvas = true
        pane.attach(session: "family")
        pane.tasks = family(2)
        let generation = pane.draftGeneration
        pane.openAgentChat("c0")
        pane.setDraft("Sent", for: "c0")
        pane.openAgentChat("c1")
        pane.reconcileDraft(for: "c0", matching: "Sent", generation: generation)
        #expect(pane.draft(for: "c0").isEmpty)
        pane.setDraft("New text", for: "c1")
        pane.reconcileDraft(for: "c1", matching: "Old text", generation: generation)
        #expect(pane.draft(for: "c1") == "New text")
        pane.attach(session: nil)
        pane.attach(session: "family")
        pane.tasks = family(2)
        pane.openAgentChat("c1")
        pane.setDraft("New text", for: "c1")
        pane.reconcileDraft(for: "c1", matching: "New text", generation: generation)
        #expect(pane.draft(for: "c1") == "New text")
    }

    @Test func accountResetClearsSameSessionNavigationAndPendingRequests() {
        let presentation = EdgeSessionPanelPresentation()
        presentation.beginSession("shared-id")
        presentation.pane.tasks = family(2)
        presentation.pane.focusedCardID = "c1"
        presentation.pane.rootExpanded = false
        presentation.pane.openRootChat()
        presentation.requestReveal(session: "future", taskID: "c1")
        presentation.reset()
        presentation.beginSession("shared-id")
        #expect(!presentation.hasPendingReveal && presentation.local == nil)
        #expect(presentation.pane.tasks.tasks.isEmpty && presentation.pane.selectedID == nil)
        #expect(presentation.pane.focusedCardID == nil && presentation.pane.rootExpanded && !presentation.pane.rootChatOpen)
        let desktop = EdgeClaudeAppPanelPresentation()
        desktop.beginSession("shared-id")
        desktop.pane.tasks = family(2)
        desktop.pane.openRootChat()
        desktop.reset()
        desktop.beginSession("shared-id")
        #expect(desktop.pane.tasks.tasks.isEmpty && !desktop.pane.rootChatOpen)
    }

    @Test func rediscoveringTheSameLocalTargetPreservesTheReaderAndHistoricalTree() {
        let presentation = EdgeSessionPanelPresentation()
        presentation.beginSession("historical")
        let target = AgentLocalTranscriptTarget(providerSessionID: "local-history", cwd: "/fixture")
        var creations = 0
        let make: (String, String?) -> ClaudeAppConversation = { id, cwd in
            creations += 1
            return ClaudeAppConversation(sessionID: id, cwd: cwd, source: SessionViewSnapshotTests.SampleSource(turns: []))
        }
        presentation.adoptLocal(target, forSession: "historical", make: make)
        let reader = presentation.local
        presentation.pane.tasks = family(3) // Local-only discovery; no BackgroundTaskBoard.
        presentation.adoptLocal(target, forSession: "historical", make: make)
        #expect(creations == 1 && presentation.local === reader)
        #expect(presentation.pane.showsTree && presentation.pane.canvasRows.count == 4)
    }

    @Test func canvasNavigationPreservesExpansionAndSelectsDistinctAgentTranscripts() async {
        let pane = SessionSidePaneModel(store: InMemoryBackgroundTaskOpenStore())
        pane.usesAgentCanvas = true
        pane.attach(session: "family")
        pane.tasks = family(3)
        var opened: [String] = []
        pane.makeTail = { task in
            opened.append(task.id)
            let text = "Transcript for \(task.id)"
            return BackgroundTaskTailModel(taskID: task.id, read: { _ in .output(.text(text, hasEarlier: false)) })
        }
        #expect(pane.showsTree)
        pane.canvasExpansion.toggle(id: "root", level: 0)
        let collapsed = pane.canvasRows.map(\.id)
        for id in ["root", "c0", "c1", "c2"] {
            pane.focusedCardID = id
            pane.openAgentChat(id)
            #expect(pane.selectedID == id && pane.showsTree && !pane.allowsRootInput)
            await pane.tail?.readOnce()
            #expect(await eventually { pane.tail?.state == .text("Transcript for \(id)", hasEarlier: false) })
            pane.returnToTree()
            #expect(pane.showsTree && pane.selectedID == nil && pane.tail == nil)
            #expect(pane.canvasRows.map(\.id) == collapsed && pane.focusedCardID == id)
        }
        #expect(opened == ["root", "c0", "c1", "c2"])
        pane.openRootChat()
        #expect(pane.rootChatOpen && !pane.showsTree && pane.tail == nil)
        #expect(pane.escape() && pane.showsTree)
        pane.attach(session: "plain")
        #expect(!pane.hasAgentTree && !pane.rootChatOpen && pane.focusedCardID == nil)
    }

    // MARK: 진짜 창에서

    private func sessionItem(_ n: Int, issues: [Int], agent: AgentMarkKind = .claudeCode, name: String? = nil, line: String = "Running", closed: Bool = false) -> AgentSessionItem {
        AgentSessionItem(
            id: Fx.session(n), name: name ?? "Session \(n)", agent: agent, agentName: agent == .codex ? "Codex" : "Claude Code", connectionID: agent == .codex ? Fx.codex : Fx.claude,
            status: closed ? .closed : .bound, ring: closed ? nil : .running, line: closed ? "" : line, createdAt: t0.addingTimeInterval(Double(n)), updatedAt: t0.addingTimeInterval(Double(n) + 60),
            issueIDs: issues.map { Fx.issue($0) }, currentIssueID: issues.first.map { Fx.issue($0) }, conversationID: nil, hasOpenTask: false, pill: nil
        )
    }

    private func host<V: View>(_ view: V, width: CGFloat = 380, height: CGFloat = 640, dark: Bool = false) -> (NSWindow, NSHostingView<V>) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    private func settle(_ hosting: NSView, for seconds: TimeInterval = 0.3) async {
        let end = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < end {
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(30))
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

    /// 패널 본문과 같은 모양: 위 여백 없이 가로 8, 스크롤
    private func panelBody(_ rig: Rig, sessions: [AgentSessionItem]) -> some View {
        ScrollView {
            ProjectSessionsGroup(shell: rig.shell, project: Fx.taskforce, sessions: sessions)
                .padding(EdgePanelMetrics.bodyInsets(issueScreens: true, view: .allWork))
        }
        .frame(width: 380, height: 640)
        .background(TFColor.bgPanel)
    }

    @Test func drawingTheGroupNeverReadsATranscriptAndOnlyAnExpandedRowReadsItsOwn() async {
        guard EdgeRailPanelController.screen != nil else { return }
        let rig = await make(sessions: .basic)
        let sessions = [sessionItem(1, issues: [139]), sessionItem(2, issues: [139], agent: .codex, line: "Idle"), sessionItem(8, issues: [141])]
        let (window, hosting) = host(panelBody(rig, sessions: sessions))
        defer { window.close() }
        await settle(hosting)
        #expect(rig.transcripts.opened.isEmpty && rig.finds.count == 0, "목록을 그리는 동안 기록을 읽지 않고 위치도 찾지 않는다")
        #expect(await eventually { rig.shown.calls == 1 }, "묶음이 행 1개 이상으로 보이자 열기 지표가 한 번 나갔다")
        // 다시 그려도 (판이 바뀌어도) 읽지 않는다
        rig.board.apply(.started(taskID: "r1", toolUseID: nil, kind: .agent, name: "Root", at: t0, parentID: nil, depth: 1, foreground: false), session: Fx.session(1).uuidString.lowercased())
        rig.shell.projectSessions.syncBoard()
        await settle(hosting)
        #expect(rig.transcripts.opened.isEmpty && rig.finds.count == 0)
        // 첫 행을 펴면 그 세션 하나만 읽는다
        rig.shell.projectSessions.toggle(sessions[0])
        #expect(await eventually { rig.finds.count == 1 && rig.transcripts.opened.count == 1 })
        await settle(hosting)
        #expect(rig.finds.count == 1 && rig.transcripts.opened.count == 1)
        rig.shell.projectSessions.toggle(sessions[2])
        #expect(await eventually { rig.finds.count == 2 })
        #expect(rig.shown.calls == 1, "그날 지표는 그대로 한 번")
    }

    /// 20개 세션 · 각 50개 자식이 모두 펴진 목록: 즉시 쌓기 `VStack`이라 한 번에 배치되고 끊기지 않는다 (21-7). 시간은 부하에 따라 달라 상한만 건다 (측정값은 출력)
    @Test func twentySessionsKeepTheProjectListCompactEvenWithFiftyChildrenEach() async throws {
        guard EdgeRailPanelController.screen != nil else { return }
        let rig = await make(sessions: .basic)
        let sessions = (1...20).map { sessionItem($0, issues: [139], name: "Session \($0)") }
        for session in sessions {
            let key = session.id.uuidString.lowercased()
            rig.board.apply(.started(taskID: "root-\(session.id.uuidString.prefix(4))", toolUseID: nil, kind: .agent, name: "Root", at: t0, parentID: nil, depth: 1, foreground: false), session: key)
            for index in 0..<50 {
                rig.board.apply(
                    .started(taskID: "c\(index)-\(session.id.uuidString.prefix(4))", toolUseID: nil, kind: .agent, name: "Child \(index)", at: t0, parentID: "root-\(session.id.uuidString.prefix(4))", depth: 2, foreground: index.isMultiple(of: 2)),
                    session: key
                )
            }
            rig.shell.projectSessions.toggle(session)
        }
        #expect(sessions.allSatisfy { rig.shell.projectSessions.visibleRows(of: $0).rows.count == 51 }, "세션마다 부모 하나 + 자식 50개, 창(150) 안이다")
        let started = ContinuousClock.now
        let (window, hosting) = host(panelBody(rig, sessions: sessions))
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        let firstLayout = ContinuousClock.now - started
        await settle(hosting, for: 0.5)
        let scrollView = try #require(findScrollView(in: hosting))
        let content = scrollView.documentView?.frame.height ?? 0
        print("T3M-PERF 20x50 first layout: \(firstLayout), content height: \(content)")
        #expect(firstLayout < .seconds(20), "첫 배치가 끝났다 (멈추지 않는다): \(firstLayout)")
        #expect(content >= 20 * 36 && content < 2_000, "Only parent sessions belong in the project list; children open in the card canvas: \(content)")
        // 갱신 중에도 스크롤 자리가 튀지 않는다
        let visible = scrollView.contentView.bounds.height
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: (content - visible) / 2))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        await settle(hosting)
        let before = scrollView.contentView.bounds.origin.y
        for session in sessions.prefix(5) {
            rig.board.apply(.finished(taskID: "c3-\(session.id.uuidString.prefix(4))", kind: .agent, status: .failed, exitCode: nil, at: t0.addingTimeInterval(30)), session: session.id.uuidString.lowercased())
        }
        rig.shell.projectSessions.syncBoard()
        await settle(hosting, for: 1.2)
        #expect(abs(scrollView.contentView.bounds.origin.y - before) <= 1 + 3 * 50 * 5, "다른 세션의 일이 바뀌어도 스크롤은 같은 근처에 있다")
    }

    // MARK: 화면 견본 (라이트 · 다크)

    /// 세션 셋 (자식 있는 세션 하나 펼침 · 공유 세션 하나 · 트리 없는 에이전트 하나): `TF_T3M_SHOTS` 폴더가 주어지면 PNG로 남긴다. 주어지지 않으면 크기 · 줄 수만 단언한다
    @Test func theGroupWithThreeSessionsOneOpenAndOneSharedDrawsAndLeavesAPicturePerAppearance() async throws {
        guard EdgeRailPanelController.screen != nil else { return }
        let rig = await make(sessions: .basic)
        let open = sessionItem(1, issues: [139], name: "Pricing copy draft")
        let plain = sessionItem(2, issues: [139], agent: .codex, name: "Lifetime plan section", line: "Idle")
        let shared = sessionItem(8, issues: [141, 150], name: "Rings and rail", line: "Needs your answer")
        let key = open.id.uuidString.lowercased()
        func start(_ id: String, _ name: String, parent: String?, depth: Int, foreground: Bool, at seconds: Double = 0) {
            rig.board.apply(.started(taskID: id, toolUseID: nil, kind: .agent, name: name, at: Date().addingTimeInterval(-300 + seconds), parentID: parent, depth: depth, foreground: foreground), session: key)
        }
        start("root", "Review the pricing copy", parent: nil, depth: 1, foreground: false)
        start("c1", "Check the trial wording", parent: "root", depth: 2, foreground: true, at: 20)
        start("c2", "Compare with the Oct 9 decision", parent: "root", depth: 2, foreground: true, at: 40)
        start("c3", "Verify the refund window", parent: "root", depth: 2, foreground: true, at: 60)
        start("g1", "Read the decision log", parent: "c2", depth: 3, foreground: true, at: 80)
        rig.board.apply(.finished(taskID: "c1", kind: .agent, status: .done, exitCode: nil, at: Date().addingTimeInterval(-120)), session: key)
        rig.board.apply(.finished(taskID: "c3", kind: .agent, status: .failed, exitCode: nil, at: Date().addingTimeInterval(-60)), session: key)
        rig.board.apply(.started(taskID: "s1", toolUseID: nil, kind: .agent, name: "Rail ring colors", at: Date().addingTimeInterval(-200), parentID: nil, depth: 1, foreground: false), session: shared.id.uuidString.lowercased())
        rig.shell.projectSessions.toggle(open)
        rig.shell.projectSessions.syncBoard()
        let sessions = [open, plain, shared]
        let directory = ProcessInfo.processInfo.environment["TF_T3M_SHOTS"]
        for dark in [false, true] {
            let (window, hosting) = host(panelBody(rig, sessions: sessions), height: 460, dark: dark)
            defer { window.close() }
            await settle(hosting, for: 0.5)
            let scrollView = try #require(findScrollView(in: hosting))
            let content = scrollView.documentView?.frame.height ?? 0
            #expect(content >= 3 * 36 && content < 460, "The group shows three parent sessions; agent cards belong in their session panel: \(content)")
            if let directory {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                let png = try #require(rep.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("project-sessions-\(dark ? "dark" : "light").png"))
            }
        }
    }
}
