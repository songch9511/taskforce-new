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

    /// 세션 읽기 횟수가 한동안(연속 5번 · 20ms) 늘지 않을 때까지 기다린다: 화면 진입이 기다리지 않고 보낸 읽기가 끝났다는 뜻이다
    private func quietSessionReads(_ gateway: IssueSampleGateway) async {
        var last = gateway.sessionReads
        var steady = 0
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while steady < 5, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
            steady = gateway.sessionReads == last ? steady + 1 : 0
            last = gateway.sessionReads
        }
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
        controller.shell.openPanel(.review)
        #expect(runtime.chat.panelConversations().isEmpty, "세션 패널이 보이지 않는 화면이면 갱신 집합에서 빠진다 (캐시를 붙들지 않는다)")
        controller.shell.dismiss()
        #expect(runtime.chat.panelConversations().isEmpty, "접어 두면 갱신 집합에서 빠진다")
        controller.shell.togglePanel()
        controller.shell.openPanel(.allWork)
        #expect(runtime.chat.panelConversations() == [Fx.conversation(1)], "다시 이슈 화면에서 세션 패널이 보이면 다시 든다")
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

    // MARK: 재검토 반영 1 — 접었던 세션 패널 복원

    /// History 범위 밖 대화 열기 → 패널 접기 → 온라인 복귀가 대화 캐시를 비움 → ⌥Space 복원. 같은 conversation id여도 숨김 → 표시 때 다시 읽는다 (빈 본문 · 끝나지 않는 로딩 없음)
    @Test func restoringACollapsedSessionPanelReadsTheOutOfHistoryConversationAgain() async throws {
        let account = try AppChatAccount.make()
        let gateway = IssueSampleGateway()
        gateway.hidesConversationsFromList = true
        let runtime = ChatRuntime(gateway: gateway, contextGateway: IssueSampleContextGateway(), scope: account.scope, issueScreens: true)
        let defaults = try TestDefaults()
        defer { defaults.cleanup() }
        let controller = EdgeShellController(
            launcher: LauncherModel(configurationError: "test"), chat: runtime, assistantWindows: true,
            positionStore: AssistantWindowPositionStore(defaults: defaults.defaults)
        )
        controller.assistant?.presents = false
        let shell = controller.shell
        shell.update(Fx.snapshot(seeds: Fx.seeds))
        await runtime.contexts?.refresh()
        await runtime.issues?.numbers.ensure(Fx.seeds.map { Fx.issue($0.number) })
        await runtime.issues?.sessions.refresh()
        shell.sessionsChanged()
        let chat = runtime.chat
        let conversation = Fx.conversation(1)
        // 1. 목록(History)에 없는 대화를 세션 패널로 연다
        shell.openAllWork()
        shell.openIssue(Fx.issue(139))
        shell.openSession(Fx.session(1))
        #expect(await eventually { chat.screen(for: conversation) == .ready(problem: nil) }, "id로 직접 읽어 열린다")
        let readsBefore = gateway.conversationReads
        // 2. 패널을 접는다
        shell.dismiss()
        #expect(!shell.panelOpen && shell.sessionPanelID == Fx.session(1), "접어도 세션 패널 선택은 남는다")
        // 3. 온라인 복귀가 대화 목록을 다시 읽고, 패널이 접혀 있어 그 대화의 캐시가 비워진다
        chat.pathChanged(online: false)
        chat.pathChanged(online: true)
        await chat.refresh()   // `ChatRuntime.followConnectivity`가 온라인 복귀에 하는 일과 같다
        await chat.settle()
        #expect(chat.screen(for: conversation) == .blank && !chat.isTargetKnown(conversation), "캐시가 비었다 (복원 전)")
        // 4. ⌥Space로 복원한다: 같은 conversation id여도 다시 읽는다
        shell.togglePanel()
        #expect(shell.panelOpen && shell.openSessionItem?.conversationID == conversation)
        #expect(await eventually { chat.screen(for: conversation) == .ready(problem: nil) && chat.isTargetKnown(conversation) }, "복원하면 본문이 다시 보이고 Composer가 열린다")
        #expect(gateway.conversationReads > readsBefore, "행을 id로 다시 읽었다")
        #expect(SessionPanelView.composerState(for: try #require(shell.openSessionItem), chat: chat) == .ready(conversation))
    }

    @Test func switchingAwayToChatsAndBackToIssuesReadsThePanelConversationAgainOnlyWhenItIsShown() async {
        let r = await rig(sessions: .basic)
        var asked: [UUID] = []
        r.shell.onLoadSessionConversation = { asked.append($0) }
        r.openDetail(139)
        r.shell.openSession(Fx.session(1))
        #expect(asked == [Fx.conversation(1)])
        r.shell.dismiss()
        r.shell.openPanel(.review)
        #expect(asked == [Fx.conversation(1)], "세션 패널이 보이지 않는 화면(Review)에서는 읽지 않는다")
        r.shell.openAllWork()
        #expect(r.shell.sessionPanelID == nil, "⌘2는 세션 패널을 닫는다")
        r.openDetail(139)
        r.shell.openSession(Fx.session(1))
        r.shell.dismiss()
        r.shell.togglePanel()
        #expect(asked.count == 3 && asked.last == Fx.conversation(1), "접었다 ⌥Space로 복원하면 같은 대화도 다시 읽는다")
    }

    // MARK: 재검토 반영 2 — Esc 뒤로도 세션 refresh

    @Test func escapingBackFromTheDetailReadsTheSessionsAgainWithPollingStopped() async {
        let r = await rig(sessions: .external)
        #expect(r.issues.sessions.items.allSatisfy { !$0.hasOpenTask }, "idle · external뿐이라 5초 읽기가 멈춘 상태")
        r.shell.openAllWork()
        r.shell.openList(.project(Fx.taskforce))
        r.shell.openIssue(Fx.issue(139))
        // 들어올 때 보낸 읽기(기다리지 않는 Task)가 끝난 뒤에 시작한다: 안 그러면 그 읽기가 Esc의 읽기로 보인다
        await quietSessionReads(r.gateway)
        r.gateway.sessions = .awaiting
        let before = r.gateway.sessionReads
        r.shell.escape()
        #expect(r.shell.nav.current == .list(.project(Fx.taskforce)), "Esc로 상세에서 목록으로")
        #expect(await eventually { r.gateway.sessionReads > before }, "Esc 뒤로도 세션을 다시 읽는다 (머리 뒤로와 같은 경로)")
        #expect(await eventually { r.shell.tabPlan.shown.first { $0.id == Fx.session(1) }?.line == "Needs your answer" }, "다른 기기의 변경이 Esc 복귀로 반영된다")
    }

    @Test func escapingWithAnOpenSessionPanelOnlyClosesItAndDoesNotNavigate() async {
        let r = await rig(sessions: .basic)
        r.openDetail(139)
        r.shell.openSession(Fx.session(1))
        r.shell.escape()
        #expect(r.shell.sessionPanelID == nil && r.shell.nav.detailID == Fx.issue(139), "먼저 세션 패널만 닫는다")
    }

    // MARK: 재검토 반영 3 — 지워진 · 보관된 대화는 끝나지 않는 로딩이 아니다

    @Test func aConversationTheServerNoLongerHasLeavesNoEndlessComposerLoadingAndShowsTheError() async throws {
        let account = try AppChatAccount.make()
        let gateway = IssueSampleGateway()
        gateway.hidesConversationsFromList = true
        let runtime = ChatRuntime(gateway: gateway, scope: account.scope, issueScreens: true)
        await runtime.issues?.sessions.refresh()
        let session = try #require(runtime.issues?.sessions.items.first { $0.id == Fx.session(1) })
        let conversation = try #require(session.conversationID)
        runtime.chat.panelConversations = { [conversation] }
        await runtime.chat.readConversation(conversation)
        #expect(SessionPanelView.composerState(for: session, chat: runtime.chat) == .ready(conversation))
        gateway.deletesConversations = true
        await runtime.chat.refresh()
        #expect(runtime.chat.screen(for: conversation) == .failed, "이전 본문이 아니라 오류 화면 + Try again")
        #expect(SessionPanelView.composerState(for: session, chat: runtime.chat) == .hidden, "끝나지 않는 \"Loading this conversation\"이 아니라 Composer를 두지 않는다")
        gateway.deletesConversations = false
        await runtime.chat.readConversation(conversation)
        #expect(runtime.chat.screen(for: conversation) == .ready(problem: nil), "Try again으로 다시 열린다")
        #expect(SessionPanelView.composerState(for: session, chat: runtime.chat) == .ready(conversation))
    }

    @Test func anOfflineFirstReadAlsoHidesTheComposerInsteadOfLoadingForever() async throws {
        let account = try AppChatAccount.make()
        let gateway = IssueSampleGateway()
        gateway.hidesConversationsFromList = true
        let runtime = ChatRuntime(gateway: gateway, scope: account.scope, issueScreens: true)
        await runtime.issues?.sessions.refresh()
        let session = try #require(runtime.issues?.sessions.items.first { $0.id == Fx.session(1) })
        let conversation = try #require(session.conversationID)
        #expect(SessionPanelView.composerState(for: session, chat: runtime.chat) == .waiting, "읽기 전에는 기다린다")
        gateway.conversationFailure = URLError(.notConnectedToInternet)
        await runtime.chat.readConversation(conversation)
        #expect(runtime.chat.screen(for: conversation) == .offline)
        #expect(SessionPanelView.composerState(for: session, chat: runtime.chat) == .hidden, "오류 화면(Try again)이 말한다: Composer는 로딩 힌트를 달고 기다리지 않는다")
    }

    @Test func whenTheSessionIsGoneTheSessionPanelClosesEvenIfItsConversationReadFailed() async {
        let r = await rig(sessions: .basic)
        r.openDetail(139)
        r.shell.openSession(Fx.session(1))
        r.gateway.sessions = .none
        await r.issues.sessions.refresh()
        #expect(await eventually { r.issues.sessions.items.isEmpty })
        r.shell.sessionsChanged()
        #expect(r.shell.sessionPanelID == nil, "세션이 사라졌으면 패널을 닫는다")
    }

    // MARK: 재검토 반영 4 — 본문 좌우 여백 8 (U2 화면만)

    @Test func theBodyMarginIsEightOnTheIssueScreensAndStaysSixteenElsewhere() {
        let issues = EdgePanelMetrics.bodyInsets(issueScreens: true, view: .allWork)
        #expect(issues.leading == 8 && issues.trailing == 8 && issues.bottom == 10 && issues.top == 0, "디자인 인계: 본문은 좌우 8 · 아래 10")
        let old = EdgePanelMetrics.bodyInsets(issueScreens: false, view: .allWork)
        #expect(old.leading == 16 && old.trailing == 16 && old.bottom == 12, "게이트가 꺼진 All work는 지금 그대로 (공통 16)")
        for view in [EdgeShellModel.View.chats, .review] {
            let other = EdgePanelMetrics.bodyInsets(issueScreens: true, view: view)
            #expect(other.leading == 16 && other.trailing == 16 && other.bottom == 12, "Chats · Review는 공통 16 그대로")
        }
    }
}
