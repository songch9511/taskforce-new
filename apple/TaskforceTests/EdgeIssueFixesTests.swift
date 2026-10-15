import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// OA U2 검토 반영 (계약 11장): 실제 키 이벤트 · 실제 플래그 조합 · 실제 셸 경로로 건다.
/// 가짜 서버는 견본 하네스의 `IssueSampleGateway` · `IssueSampleContextGateway`(렌더 fixture)다: 실제 서버 · 계정 · AI 호출이 없다
@MainActor
struct EdgeIssueFixesTests {
    typealias Fx = IssueSnapshotData

    // MARK: 시험 장치

    private func rig(
        sessions: IssueSampleGateway.SessionScenario = .basic, seeds: [IssueSnapshotData.Seed] = IssueSnapshotData.seeds, contexts: IssueSampleContextGateway.Scenario = .full
    ) async -> EdgeIssuesTests.Rig {
        let gateway = IssueSampleGateway()
        gateway.sessions = sessions
        let contextGateway = IssueSampleContextGateway()
        contextGateway.seeds = seeds
        contextGateway.scenario = contexts
        let scope = AccountScope(currentAccount: { SampleData.userID })
        let issues = IssueRuntime(gateway: gateway, scope: scope)
        let store = WorkContextStore(gateway: contextGateway, scope: scope)
        let shell = EdgeShellModel(schedule: { _, _ in EdgeTimer() }, clock: { Date() }, contexts: store, chatsEnabled: true, windowsEnabled: true, issues: issues)
        shell.update(Fx.snapshot(seeds: seeds))
        let rig = EdgeIssuesTests.Rig(shell: shell, issues: issues, contexts: store, gateway: gateway, contextGateway: contextGateway, scope: scope, seeds: seeds)
        await rig.sync()
        return rig
    }

    /// 조건이 설 때까지 기다린다 (양보 횟수로 짐작하지 않는다). 안전망 3초
    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    /// 실제 키 이벤트 (시스템이 보내는 모양 그대로: 방향키는 `.numericPad` · `.function`이 함께 온다)
    private func key(_ code: Int, flags: NSEvent.ModifierFlags = [], window: NSWindow? = nil) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window?.windowNumber ?? 0, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(code)
        ))
    }

    // MARK: 검토 반영 1 — 복귀 요약 baseline은 요약이 실제로 그려질 때만

    /// 실제 조합: U2 + C3를 함께 켠다 (Projects에는 요약 카드가 없다, 계약 10장 2)
    @Test func theRealFlagComboTurnsBothOnAndTheSummaryIsNotDrawnWhenTheIssueScreensAreOn() throws {
        let store = try TestDefaults()
        defer { store.cleanup() }
        store.defaults.set(true, forKey: EdgeShellFlag.key)
        store.defaults.set(true, forKey: S3bFlag.key)
        store.defaults.set(true, forKey: EdgeSurfaces.issueScreensKey)
        store.defaults.set(true, forKey: C3Flag.key)
        #expect(EdgeSurfaces.issueScreens(store.defaults) && C3Flag.isEnabled(store.defaults), "두 게이트가 함께 켜지는 조합이 실제로 있다")
    }

    @Test func withTheIssueScreensOnTheFirstSummaryDisplayIsNeverConfirmedBecauseNothingWasDrawn() async throws {
        let harness = try await ReviewHarness.make(reviews: 3, open: 2)
        let store = ReturnSummaryStore(gateway: LiveReturnSummaryGateway(services: harness.services), scope: harness.scope)
        let issues = IssueRuntime(gateway: IssueSampleGateway(), scope: harness.scope)
        let shell = EdgeShellModel(schedule: { _, _ in EdgeTimer() }, summary: store, issues: issues)
        await harness.store.load()
        let rig = SummaryRig(harness: harness, desk: nil, store: store, shell: shell)
        rig.sync()
        let baselines = EdgeSummaryBaselineTests()
        await rig.harness.server.scriptSummary(baselines.firstUse(rig), baselines.initialized(rig))
        #expect(!shell.drawsSummary, "U2 화면은 Projects에 요약 카드를 그리지 않는다")
        shell.openAllWork()
        await rig.store.refresh()
        #expect(await baselines.quiet(rig) == 0, "그려지지 않은 요약의 첫 표시 기준점을 서버에 확정하지 않는다")
        #expect(shell.considerSummaryBaseline() == nil)
        #expect(rig.store.summary?.initToken != nil, "서버 토큰은 그대로 남아 있다 (확정하지 않았다)")
    }

    @Test func withoutTheIssueScreensTheSameFlowStillConfirmsOnce() async throws {
        let rig = try await SummaryRig.make(review: false)
        let baselines = EdgeSummaryBaselineTests()
        await rig.harness.server.scriptSummary(baselines.firstUse(rig), baselines.initialized(rig))
        #expect(rig.shell.drawsSummary)
        rig.shell.openAllWork()
        await rig.store.refresh()
        #expect(await baselines.settled(rig, posts: 1), "게이트가 꺼진 지금 동작은 그대로다 (C3 기준점 시험과 같다)")
    }

    // MARK: 검토 반영 5 — 화면 진입 = 세션 refresh

    @Test func everyScreenEntryReadsTheSessionsAgainEvenWhenPollingIsStopped() async {
        let r = await rig(sessions: .external)
        #expect(r.issues.sessions.items.allSatisfy { !$0.hasOpenTask }, "idle · external뿐이라 5초 읽기가 멈춘 상태")
        func entered(_ name: String, _ action: () -> Void) async {
            let before = r.gateway.sessionReads
            action()
            #expect(await eventually { r.gateway.sessionReads > before }, "\(name)이 세션을 다시 읽는다")
        }
        await entered("Projects(⌘2)") { r.shell.openAllWork() }
        await entered("프로젝트 목록") { r.shell.openList(.project(Fx.taskforce)) }
        await entered("이슈 상세") { r.shell.openIssue(Fx.issue(139)) }
        await entered("뒤로") { r.shell.goBack() }
        await entered("레일 · 칩에서 이슈 열기") { r.shell.open(itemID: Fx.issue(141)) }
    }

    @Test func aChangeMadeElsewhereShowsUpWhenTheDetailIsEnteredWithPollingStopped() async {
        let r = await rig(sessions: .external)
        r.shell.openAllWork()
        r.shell.openList(.project(Fx.taskforce))
        #expect(r.shell.tabPlan.shown.first { $0.id == Fx.session(1) }?.line == "External · Open in Terminal")
        r.gateway.sessions = .awaiting
        r.shell.openIssue(Fx.issue(139))
        #expect(await eventually { r.shell.sessions(of: Fx.issue(139)).first { $0.id == Fx.session(1) }?.line == "Needs your answer" }, "다른 기기의 변경이 진입으로 반영된다")
    }

    // MARK: 검토 반영 7 — More 메뉴 방향키

    @Test func theMoreMenuMovesWithTheRealArrowKeyFlags() throws {
        let arrowFlags: NSEvent.ModifierFlags = [.numericPad, .function]
        for (code, expected) in [(kVK_UpArrow, EdgeContextMenu.Key.up), (kVK_DownArrow, .down)] {
            let event = try key(code, flags: arrowFlags)
            #expect(EdgeContextMenu.key(keyCode: Int(event.keyCode), flags: event.modifierFlags) == expected, "방향키는 .numericPad · .function이 함께 온다: \(code)")
        }
        #expect(EdgeContextMenu.key(keyCode: kVK_Return, flags: []) == .activate)
        #expect(EdgeContextMenu.key(keyCode: kVK_ANSI_KeypadEnter, flags: .numericPad) == .activate, "키패드 Enter")
        #expect(EdgeContextMenu.key(keyCode: kVK_Escape, flags: []) == .escape)
        #expect(EdgeContextMenu.key(keyCode: kVK_DownArrow, flags: [.command, .numericPad, .function]) == nil, "⌘가 함께면 메뉴 키가 아니다")
        #expect(EdgeContextMenu.key(keyCode: kVK_DownArrow, flags: [.shift, .numericPad, .function]) == nil)
        #expect(EdgeContextMenu.key(keyCode: kVK_ANSI_A, flags: []) == nil)
    }

    @Test func aRealArrowKeyEventToTheMenuWindowMovesTheHighlight() async throws {
        let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        let menu = EdgeContextMenu()
        menu.shows = false
        let model = ContextMenuModel(items: ["a", "b", "c"].map { ContextMenuItem(id: $0, label: $0) })
        menu.present(model: model, label: "More sessions", row: CGRect(x: 120, y: 300, width: 24, height: 20), pointerX: 130, over: parent) {}
        let panel = try #require(menu.window)
        panel.orderFrontRegardless()
        defer { menu.dismiss(notify: false); panel.orderOut(nil) }
        let down = try key(kVK_DownArrow, flags: [.numericPad, .function], window: panel)
        #expect(down.window === panel, "시험의 키 이벤트가 메뉴 창으로 간다")
        #expect(menu.handle(down))
        #expect(model.highlighted == 0)
        #expect(menu.handle(try key(kVK_DownArrow, flags: [.numericPad, .function], window: panel)) && model.highlighted == 1)
        #expect(menu.handle(try key(kVK_UpArrow, flags: [.numericPad, .function], window: panel)) && model.highlighted == 0)
        let other = try key(kVK_DownArrow, flags: [.numericPad, .function], window: parent)
        #expect(!menu.handle(other), "다른 창으로 온 키는 가로채지 않는다")
    }

    // MARK: 검토 반영 8 — Projects 빈 화면은 할 일 0 ∧ 보일 프로젝트 0

    @Test func activeProjectsWithNoIssuesAreStillReachable() async {
        let r = await rig(seeds: [])
        #expect(r.shell.workItems.isEmpty && !r.shell.projectRows.isEmpty, "할 일이 없어도 활성 프로젝트 행은 있다")
        r.shell.openAllWork()
        guard case .ready = IssuesLoadState.screen(r.shell) else {
            Issue.record("빈 화면(`Nothing on your plate yet.`)이 아니라 프로젝트 목록이어야 한다: \(IssuesLoadState.screen(r.shell))")
            return
        }
        r.shell.openList(.project(Fx.taskforce))
        #expect(r.shell.nav.current == .list(.project(Fx.taskforce)) && r.shell.panelTitle == "Taskforce 0.2.0", "빈 프로젝트에도 들어간다 (같은 제목만)")
    }

    @Test func noIssuesAndNoProjectsIsTheEmptyScreen() async {
        let r = await rig(seeds: [], contexts: .empty)
        r.shell.openAllWork()
        #expect(r.shell.projectRows.isEmpty)
        guard case .noWork = IssuesLoadState.screen(r.shell) else {
            Issue.record("할 일 0 · 프로젝트 0이면 빈 화면: \(IssuesLoadState.screen(r.shell))")
            return
        }
    }

    // MARK: 검토 반영 0 — 끝난 세션은 상태 말 없이 흐리게 (머리)

    @Test func theSessionHeaderHasNoStatusLineForAClosedSessionAndKeepsTheOthers() async {
        let r = await rig(sessions: .closedAndStates)
        r.openDetail(139)
        let items = r.shell.sessions(of: Fx.issue(139))
        let closed = items.first { $0.isClosed }
        let running = items.first { $0.id == Fx.session(3) }
        #expect(closed.map(SessionPanelView.statusLine(for:)) == .some(nil), "끝난 세션의 머리에는 상태 줄이 없다")
        #expect(running.map(SessionPanelView.statusLine(for:)) == .some("Stop requested · not confirmed"))
        #expect(items.last?.isClosed == true, "끝난 세션은 목록 맨 아래")
        #expect(closed?.rowAccessibilityName.contains("Closed") == false)
    }

    // MARK: 검토 반영 2 · 3 · 4 — 세션 패널 대화

    @Test func theComposerWaitsUntilTheConversationRowIsKnownThenOpens() async throws {
        let account = try AppChatAccount.make()
        let gateway = IssueSampleGateway()
        gateway.sessions = .basic
        let runtime = ChatRuntime(gateway: gateway, scope: account.scope, issueScreens: true)
        await runtime.issues?.sessions.refresh()
        let session = try #require(runtime.issues?.sessions.items.first { $0.id == Fx.session(1) })
        let conversation = try #require(session.conversationID)
        #expect(SessionPanelView.composerState(for: session, chat: runtime.chat) == .waiting, "대화(대상)를 읽기 전에는 보내지 못한다")
        #expect(SessionPanelView.waitingHint == "Loading this conversation")
        await runtime.chat.readConversation(conversation)
        #expect(SessionPanelView.composerState(for: session, chat: runtime.chat) == .ready(conversation))
        let closed = AgentSessionItem(
            id: UUID(), name: "Old", agent: .claudeCode, agentName: "Claude Code", connectionID: UUID(), status: .closed, ring: nil, line: "", createdAt: Date(), updatedAt: Date(),
            issueIDs: [], currentIssueID: nil, conversationID: conversation, hasOpenTask: false, pill: nil
        )
        #expect(SessionPanelView.composerState(for: closed, chat: runtime.chat) == .hidden, "끝난 세션은 읽기만")
    }

    @Test func openingASessionAsksForItsConversationAndAChangedConversationIDReadsAgain() async {
        let r = await rig(sessions: .basic)
        var asked: [UUID] = []
        r.shell.onLoadSessionConversation = { asked.append($0) }
        r.openDetail(139)
        r.shell.openSession(Fx.session(1))
        #expect(asked == [Fx.conversation(1)], "열 때 그 세션의 대화를 읽는다")
        r.shell.sessionsChanged()
        #expect(asked == [Fx.conversation(1)], "같은 대화면 다시 부르지 않는다")
        r.gateway.shiftsConversations = true
        await r.issues.sessions.refresh()
        // `openSession`이 띄운 읽기가 아직 돌고 있을 수 있다 (마지막에 시작한 읽기가 반영된다): 반영될 때까지 기다린다
        #expect(await eventually { r.shell.openSessionItem?.conversationID == Fx.conversation(101) })
        r.shell.sessionsChanged()
        #expect(asked == [Fx.conversation(1), Fx.conversation(101)], "패널의 대화 id가 바뀌면 다시 읽는다")
        r.shell.closeSessionPanel()
        r.shell.openSession(Fx.session(1))
        #expect(asked.last == Fx.conversation(101) && asked.count == 3, "닫았다 다시 열면 다시 읽는다")
        r.shell.openSession(Fx.session(2))
        #expect(asked.last == Fx.conversation(102), "다른 세션으로 바꾸면 그 대화")
        r.shell.openSession(Fx.session(2))
        #expect(r.shell.sessionPanelID == nil && asked.count == 4, "닫으면 읽지 않는다")
    }

    @Test func theControllerFeedsThePanelsConversationToTheOnlineRefreshSetAndReadsItByID() async throws {
        let account = try AppChatAccount.make()
        let gateway = IssueSampleGateway()
        let contextGateway = IssueSampleContextGateway()
        let runtime = ChatRuntime(gateway: gateway, contextGateway: contextGateway, scope: account.scope, issueScreens: true)
        let defaults = try TestDefaults()
        defer { defaults.cleanup() }
        let controller = EdgeShellController(
            launcher: LauncherModel(configurationError: "test"), chat: runtime, assistantWindows: true,
            positionStore: AssistantWindowPositionStore(defaults: defaults.defaults)
        )
        controller.assistant?.presents = false
        controller.shell.update(Fx.snapshot(seeds: Fx.seeds))
        await runtime.contexts?.refresh()
        await runtime.issues?.numbers.ensure(Fx.seeds.map { Fx.issue($0.number) })
        await runtime.issues?.sessions.refresh()
        controller.shell.sessionsChanged()
        #expect(runtime.chat.panelConversations().isEmpty, "패널이 닫혀 있으면 갱신 집합에 없다")
        controller.shell.openAllWork()
        controller.shell.openIssue(Fx.issue(139))
        controller.shell.openSession(Fx.session(1))
        #expect(runtime.chat.panelConversations() == [Fx.conversation(1)], "세션 패널이 보이는 대화는 공통 갱신 집합에 든다")
        #expect(await eventually { runtime.chat.screen(for: Fx.conversation(1)) == .ready(problem: nil) }, "열면 그 대화를 id로 읽는다 (History 목록에 기대지 않는다)")
        #expect(gateway.conversationReads == 1, "행을 id로 한 번 읽었다 (목록에 없던 대화)")
        controller.shell.closeSessionPanel()
        #expect(runtime.chat.panelConversations().isEmpty)
    }

    // MARK: 검토 반영 9 — 많은 세션의 More 메뉴

    @Test func aMenuWithManyItemsIsLimitedToTheVisibleHeightAndAShortOneIsNot() throws {
        let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        let visible = (parent.screen ?? NSScreen.main)?.visibleFrame ?? parent.frame
        let menu = EdgeContextMenu()
        menu.shows = false
        let many = ContextMenuModel(items: (0..<120).map { ContextMenuItem(id: "s\($0)", label: "Session \($0 + 1)", detail: "Running") })
        menu.present(model: many, label: "More sessions", row: CGRect(x: visible.midX, y: visible.midY, width: 24, height: 20), pointerX: visible.midX, over: parent) {}
        let tall = try #require(menu.window).frame
        #expect(tall.height == ContextMenuGeometry.maxHeight(visible: visible), "화면 높이에서 여백을 뺀 높이로 줄인다 (120줄이 화면 밖으로 넘치지 않는다)")
        #expect(tall.minY >= visible.minY && tall.maxY <= visible.maxY, "화면 안에 놓인다")
        menu.dismiss(notify: false)
        let few = ContextMenuModel(items: (0..<3).map { ContextMenuItem(id: "f\($0)", label: "Session \($0 + 1)") })
        menu.present(model: few, label: "More sessions", row: CGRect(x: visible.midX, y: visible.midY, width: 24, height: 20), pointerX: visible.midX, over: parent) {}
        let short = try #require(menu.window).frame
        #expect(short.height < 200 && short.height < tall.height, "짧은 메뉴는 줄 전부가 그대로 보인다")
        menu.dismiss(notify: false)
    }
}
