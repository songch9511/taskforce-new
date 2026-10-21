import AppKit
import Foundation
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// 새 Issues 화면(OA U2)의 Mac 쪽: 게이트(Release 늘 꺼짐) · 런타임 생성 · 셸의 화면 이동(⌘2 · 링 · 뒤로 · Esc) · 세션 패널의 열기 · 닫기 · 탭 · 칩 · 레일 `+` 자리.
/// 서버 응답은 가짜(`IssueSampleGateway` · `IssueSampleContextGateway`, 견본 하네스의 렌더 fixture)다: 실제 서버 · 계정 · AI 호출이 없다.
/// 게이트가 꺼진 셸은 지금 동작 그대로여야 한다 (같은 시험을 `issues == nil`로 한 번 더 건다)
@MainActor
struct EdgeIssuesTests {
    typealias Fx = IssueSnapshotData

    // MARK: 시험 장치

    @MainActor
    struct Rig {
        let shell: EdgeShellModel
        let issues: IssueRuntime
        let contexts: WorkContextStore
        let gateway: IssueSampleGateway
        let contextGateway: IssueSampleContextGateway
        let scope: AccountScope
        let seeds: [IssueSnapshotData.Seed]

        /// 앱의 `followWork` · `followIssues`처럼 번호 · 세션 · 프로젝트를 읽어 셸에 옮긴다
        func sync() async {
            await contexts.refresh()
            await issues.numbers.ensure(seeds.map { Fx.issue($0.number) })
            await issues.sessions.refresh()
            shell.sessionsChanged()
        }

        func openProject(_ id: UUID = Fx.taskforce) {
            shell.openAllWork()
            shell.openList(.project(id))
        }

        func openDetail(_ number: Int) {
            shell.openAllWork()
            shell.openIssue(Fx.issue(number))
        }
    }

    func make(
        sessions: IssueSampleGateway.SessionScenario = .basic, seeds: [IssueSnapshotData.Seed] = IssueSnapshotData.seeds,
        time: EdgeShellModelTests.ManualTime? = nil, gated: Bool = true
    ) async -> Rig {
        let gateway = IssueSampleGateway()
        gateway.sessions = sessions
        let contextGateway = IssueSampleContextGateway()
        contextGateway.seeds = seeds
        let scope = AccountScope(currentAccount: { SampleData.userID })
        let issues = IssueRuntime(gateway: gateway, scope: scope)
        let contexts = WorkContextStore(gateway: contextGateway, scope: scope)
        let shell: EdgeShellModel
        if let time {
            shell = EdgeShellModel(schedule: time.schedule, clock: time.clock, contexts: contexts, chatsEnabled: true, windowsEnabled: true, issues: gated ? issues : nil)
        } else {
            shell = EdgeShellModel(schedule: { _, _ in EdgeTimer() }, clock: { Date() }, contexts: contexts, chatsEnabled: true, windowsEnabled: true, issues: gated ? issues : nil)
        }
        shell.update(Fx.snapshot(seeds: seeds))
        let rig = Rig(shell: shell, issues: issues, contexts: contexts, gateway: gateway, contextGateway: contextGateway, scope: scope, seeds: seeds)
        await rig.sync()
        return rig
    }

    // MARK: 게이트

    @Test func theReleaseSurfacesNeverTurnTheIssueScreensOn() {
        #expect(!EdgeSurfaces.release.allowsIssueScreens(flag: true), "Release 표면은 projects가 꺼져 있어 값이 켜져도 꺼진다")
        #expect(!EdgeSurfaces.release.projects && !EdgeSurfaces.release.chats)
    }

    @Test func theGateNeedsTheFlagAndTheShellAndChatsAndProjects() {
        func gate(shell: Bool, chats: Bool, projects: Bool, flag: Bool) -> Bool {
            EdgeSurfaces(shell: shell, review: false, summary: false, chats: chats, projects: projects, settingsWindow: false).allowsIssueScreens(flag: flag)
        }
        #expect(gate(shell: true, chats: true, projects: true, flag: true))
        #expect(!gate(shell: false, chats: true, projects: true, flag: true), "셸이 꺼지면 꺼짐")
        #expect(!gate(shell: true, chats: false, projects: true, flag: true), "Chats가 꺼지면 꺼짐")
        #expect(!gate(shell: true, chats: true, projects: false, flag: true), "프로젝트 묶음이 꺼지면 꺼짐")
        #expect(!gate(shell: true, chats: true, projects: true, flag: false), "값이 꺼지면 꺼짐")
    }

    @Test func theDebugGateFollowsOnlyTheInjectedSuiteAndTheReleaseSwitchTurnsItOff() throws {
        let store = try TestDefaults()
        defer { store.cleanup() }
        #expect(!EdgeSurfaces.issueScreens(store.defaults), "기본은 꺼짐")
        store.defaults.set(true, forKey: EdgeSurfaces.issueScreensKey)
        #expect(!EdgeSurfaces.issueScreens(store.defaults), "값만 켜서는 안 켜진다")
        store.defaults.set(true, forKey: EdgeShellFlag.key)
        store.defaults.set(true, forKey: S3bFlag.key)
        #expect(EdgeSurfaces.issueScreens(store.defaults), "셸 · 프로젝트 · 값이 모두 켜지면 켜짐 (Chats는 셸을 따른다)")
        store.defaults.set(false, forKey: S3bFlag.key)
        #expect(!EdgeSurfaces.issueScreens(store.defaults))
        store.defaults.set(true, forKey: S3bFlag.key)
        store.defaults.set(true, forKey: EdgeSurfaces.releaseKey)
        #expect(!EdgeSurfaces.issueScreens(store.defaults), "-TF_RELEASE_SURFACES면 꺼짐")
        #expect(EdgeSurfaces.issueScreensKey == "TF_U2")
    }

    @Test func theHostRunHasTheGateOff() {
        #expect(!EdgeSurfaces.issueScreensForThisRun, "테스트 호스트에는 -TF_U2가 없다")
    }

    // MARK: 런타임 생성

    @Test func theRuntimeMakesTheIssueReadsOnlyWhenTheGateIsOnAndTheGatewayCanServeThem() throws {
        let account = try AppChatAccount.make()
        let capable = IssueSampleGateway()
        #expect(ChatRuntime(gateway: capable, scope: account.scope, issueScreens: false).issues == nil, "게이트가 꺼지면 읽기 저장소가 아예 없다")
        #expect(ChatRuntime(gateway: capable, scope: account.scope, issueScreens: true).issues != nil)
        let plain = PlainChatGateway()
        #expect(ChatRuntime(gateway: plain, scope: account.scope, issueScreens: true).issues == nil, "세션을 읽을 수 없는 연결(견본 · 시험용 가짜)에는 만들지 않는다")
    }

    // MARK: 이름 · 툴팁 · `+`

    @Test func theFirstRailControlIsCalledProjectsWithTheFolderIconOnlyWhenGated() async {
        let gated = await make()
        let plain = await make(gated: false)
        #expect(gated.shell.label(for: .allWork) == "Projects" && gated.shell.label(for: .chats) == "Chats")
        #expect(gated.shell.railIcon(for: .allWork) == .project && TFIcon.project.rawValue == "folder", "lucide folder")
        #expect(gated.shell.railIcon(for: .chats) == .talk && gated.shell.railIcon(for: .more) == .more, "다른 칸은 그대로")
        #expect(plain.shell.label(for: .allWork) == "All work", "꺼져 있으면 지금 이름 그대로")
        #expect(plain.shell.railIcon(for: .allWork) == .allWork && TFIcon.allWork.rawValue == "list-todo", "꺼져 있으면 list-todo 그대로")
    }

    @Test func theProjectsTooltipShowsTheShortcutAndThePlusTooltipShowsItsName() async {
        let time = EdgeShellModelTests.ManualTime()
        let rig = await make(time: time)
        rig.shell.pointer(inside: true)
        time.advance(0.12)
        #expect(rig.shell.isExpanded)
        rig.shell.hover(control: .allWork)
        let tooltip = rig.shell.tooltip
        #expect(tooltip?.title == "Projects" && tooltip?.detail == "⌘2")
        rig.shell.hover(plus: true)
        #expect(rig.shell.hoveredPlus && rig.shell.hoveredControl == nil)
        #expect(rig.shell.tooltip?.title == "New session" && rig.shell.tooltip?.detail == "")
        rig.shell.hover(control: .chats)
        #expect(!rig.shell.hoveredPlus || rig.shell.tooltip?.title == "Chats", "다른 칸으로 가면 + 툴팁은 내려간다")
    }

    // MARK: 화면 이동

    @Test func commandTwoOpensProjectsAndClearsEverythingStacked() async {
        let rig = await make()
        rig.openDetail(139)
        rig.shell.openSession(Fx.session(1))
        #expect(rig.shell.nav.detailID == Fx.issue(139) && rig.shell.sessionPanelID == Fx.session(1))
        rig.shell.openAllWork()
        #expect(rig.shell.nav.current == .projects && rig.shell.sessionPanelID == nil && rig.shell.panelOpen && rig.shell.view == .allWork)
        #expect(rig.shell.currentID == nil)
    }

    @Test func projectsListTheProjectsByNameThenUngroupedThenDoneToday() async {
        let rig = await make()
        rig.shell.openAllWork()
        let rows = rig.shell.projectRows
        #expect(rows.map(\.name) == ["Hiring: founding designer", "October investor update", "Seoul office move", "Shape launch", "Taskforce 0.2.0", "Ungrouped", "Done today"])
        #expect(rig.shell.panelTitle == "Projects")
        #expect(!rig.shell.sessionPanelShown, "Projects에는 세션 패널이 없다")
    }

    @Test func aProjectListShowsTheNameAsTheTitleAndNoSessionPanelOpensFromAList() async {
        let rig = await make()
        rig.openProject()
        #expect(rig.shell.nav.current == .list(.project(Fx.taskforce)) && rig.shell.panelTitle == "Taskforce 0.2.0")
        #expect(rig.shell.nav.canGoBack)
        // 세션은 이슈 상세의 Sessions 목록에서만 연다 (OA U3-45): 목록 화면에서는 열리지 않는다
        rig.shell.openSession(Fx.session(1))
        #expect(rig.shell.sessionPanelID == nil && !rig.shell.sessionPanelShown)
        rig.shell.openList(.doneToday)
        rig.shell.openSession(Fx.session(1))
        #expect(rig.shell.sessionPanelID == nil)
        rig.shell.openList(.ungrouped)
        rig.shell.openSession(Fx.session(1))
        #expect(rig.shell.sessionPanelID == nil)
    }

    @Test func theDetailTitleIsTheNumberAndStaysEmptyUntilTheNumberIsRead() async {
        let rig = await make()
        rig.openDetail(139)
        #expect(rig.shell.panelTitle == "#139")
        // 번호도 상세도 읽지 못했으면 (상세 읽기 실패) 제목 자리를 비운다
        rig.gateway.detail = .failed
        rig.issues.numbers.reset()
        rig.issues.details.reset()
        #expect(rig.shell.panelTitle == "", "번호를 못 읽었으면 지어내지 않고 비운다")
    }

    @Test func backGoesToTheListThenToProjectsAndClosesTheSessionPanel() async {
        let rig = await make()
        rig.openProject()
        rig.shell.openIssue(Fx.issue(139))
        rig.shell.openSession(Fx.session(1))
        #expect(rig.shell.sessionPanelID != nil)
        rig.shell.goBack()
        #expect(rig.shell.nav.current == .list(.project(Fx.taskforce)) && rig.shell.sessionPanelID == nil && rig.shell.currentID == nil)
        rig.shell.goBack()
        #expect(rig.shell.nav.current == .projects && !rig.shell.nav.canGoBack)
        rig.shell.goBack()
        #expect(rig.shell.nav.current == .projects, "맨 아래에서는 더 뒤로 가지 않는다")
    }

    @Test func aRingClickOpensTheDetailAndBackGoesToTheIssuesFirstProject() async {
        let rig = await make()
        guard let entry = rig.shell.slots.first(where: { $0.id == Fx.issue(141) }) else {
            Issue.record("141의 링이 없다")
            return
        }
        rig.shell.openRailEntry(entry)
        #expect(rig.shell.panelOpen && rig.shell.view == .allWork && rig.shell.nav.detailID == Fx.issue(141))
        rig.shell.goBack()
        #expect(rig.shell.nav.current == .list(.project(Fx.taskforce)), "목록 밖에서 열었으면 그 이슈의 첫 프로젝트 목록으로")
    }

    @Test func anUngroupedIssueOpenedFromOutsideGoesBackToUngrouped() async {
        let rig = await make()
        rig.shell.open(itemID: Fx.issue(155))
        #expect(rig.shell.nav.detailID == Fx.issue(155))
        rig.shell.goBack()
        #expect(rig.shell.nav.current == .list(.ungrouped))
    }

    @Test func aNeedsYouRingOpensReviewOnlyWhenTheIssueIsQueuedThereElseItsDetail() async throws {
        let harness = try await ReviewHarness.make(reviews: 1, open: 0)
        let desk = ReviewDesk(now: harness.store, scope: harness.scope)
        let gateway = IssueSampleGateway()
        gateway.sessions = .basic
        let scope = AccountScope(currentAccount: { SampleData.userID })
        let issues = IssueRuntime(gateway: gateway, scope: scope)
        let shell = EdgeShellModel(schedule: { _, _ in EdgeTimer() }, review: desk, windowsEnabled: true, issues: issues)
        await harness.store.load()
        let seeded = Fx.snapshot(seeds: Fx.seeds)
        shell.update(EdgeWorkSnapshot(
            review: harness.store.sections.review, open: seeded.open, doneToday: seeded.doneToday, working: seeded.working, load: .loaded(problem: nil), doneSince: seeded.doneSince
        ))
        await issues.sessions.refresh()
        shell.sessionsChanged()
        let queued = try #require(shell.reviewQueue.newest)
        let queuedEntry = try #require(shell.slots.first { $0.id == queued.id })
        shell.openRailEntry(queuedEntry)
        #expect(shell.view == .review && shell.reviewID == queued.id, "큐에 있는 확인 요청은 Review로")
        let sessionOnly = try #require(shell.slots.first { $0.id == Fx.issue(141) && $0.kind == .needsYou })
        #expect(!shell.reviewQueue.contains(sessionOnly.id))
        shell.openRailEntry(sessionOnly)
        #expect(shell.view == .allWork && shell.nav.detailID == Fx.issue(141), "세션의 질문이라 큐에 없으면 다른 Review를 열지 않고 그 이슈 상세로")
    }

    @Test func escapeGoesSessionPanelThenDetailBackThenCollapses() async {
        let rig = await make()
        rig.openProject()
        rig.shell.openIssue(Fx.issue(139))
        rig.shell.openSession(Fx.session(1))
        rig.shell.escape()
        #expect(rig.shell.sessionPanelID == nil && rig.shell.nav.detailID == Fx.issue(139) && rig.shell.panelOpen, "먼저 세션 패널")
        rig.shell.escape()
        #expect(rig.shell.nav.current == .list(.project(Fx.taskforce)) && rig.shell.panelOpen, "그다음 목록으로")
        rig.shell.escape()
        #expect(rig.shell.nav.current == .list(.project(Fx.taskforce)) && !rig.shell.panelOpen, "목록에서는 패널을 접는다")
    }

    // MARK: 세션 패널

    @Test func theSessionPanelOpensOnlyWithATabAndTogglesOnTheSameSession() async {
        let rig = await make()
        rig.shell.openAllWork()
        rig.shell.openSession(Fx.session(1))
        #expect(rig.shell.sessionPanelID == nil, "Projects에는 탭이 없어 세션 패널도 없다")
        rig.shell.openList(.doneToday)
        rig.shell.openSession(Fx.session(1))
        #expect(rig.shell.sessionPanelID == nil, "Done today에도 없다")
        rig.openDetail(139)
        rig.shell.openSession(Fx.session(1))
        #expect(rig.shell.sessionPanelID == Fx.session(1) && rig.shell.openSessionItem?.name == "Pricing copy draft")
        rig.shell.openSession(Fx.session(2))
        #expect(rig.shell.sessionPanelID == Fx.session(2), "다른 세션이면 바꾼다")
        rig.shell.openSession(Fx.session(2))
        #expect(rig.shell.sessionPanelID == nil, "같은 세션이면 닫는다")
    }

    @Test func theSessionPanelClosesOnBackCommandTwoAndAnotherIssue() async {
        let rig = await make()
        rig.openDetail(139)
        rig.shell.openSession(Fx.session(1))
        rig.shell.openList(.project(Fx.taskforce))
        #expect(rig.shell.sessionPanelID == nil, "다른 화면(목록)으로 가면 닫힌다")
        rig.shell.openIssue(Fx.issue(139))
        rig.shell.openSession(Fx.session(1))
        rig.shell.openIssue(Fx.issue(141))
        #expect(rig.shell.sessionPanelID == nil, "다른 이슈를 열면 닫힌다")
        rig.shell.openSession(Fx.session(8))
        #expect(rig.shell.sessionPanelID == Fx.session(8))
        rig.shell.goBack()
        #expect(rig.shell.sessionPanelID == nil)
        rig.openDetail(139)
        rig.shell.openSession(Fx.session(1))
        rig.shell.openAllWork()
        #expect(rig.shell.sessionPanelID == nil)
    }

    @Test func clickingTheRingOfTheSameOpenIssueKeepsTheSessionPanelButAnotherIssueClosesIt() async {
        let rig = await make()
        rig.openDetail(139)
        rig.shell.openSession(Fx.session(1))
        rig.shell.open(itemID: Fx.issue(139))
        #expect(rig.shell.sessionPanelID == Fx.session(1), "같은 이슈의 링은 세션 패널을 둔다")
        rig.shell.open(itemID: Fx.issue(141))
        #expect(rig.shell.sessionPanelID == nil && rig.shell.nav.detailID == Fx.issue(141))
    }

    @Test func aSessionThatDisappearsClosesItsPanelAndAClosedPanelStaysClosedWithoutTheTab() async {
        let rig = await make()
        rig.openDetail(139)
        rig.shell.openSession(Fx.session(1))
        rig.gateway.sessions = .none
        await rig.issues.sessions.refresh()
        // `openSession`이 띄운 읽기가 아직 돌고 있을 수 있다 (마지막에 시작한 읽기가 반영된다): 반영될 때까지 기다린다
        for _ in 0..<200 where !rig.issues.sessions.items.isEmpty { await Task.yield() }
        rig.shell.sessionsChanged()
        #expect(rig.shell.sessionPanelID == nil, "읽은 세션에서 사라지면 패널을 닫는다")
        #expect(rig.shell.nav.detailID == Fx.issue(139), "이슈 상세는 세션이 없어도 그대로 열려 있다")
    }

    @Test func anIssueThatDisappearsReturnsToItsList() async {
        let rig = await make()
        rig.openProject()
        rig.shell.openIssue(Fx.issue(139))
        let remaining = Fx.seeds.filter { $0.number != 139 }
        rig.shell.update(Fx.snapshot(seeds: remaining))
        #expect(rig.shell.nav.current == .list(.project(Fx.taskforce)), "지우거나 병합된 이슈의 상세는 목록으로 돌아간다")
    }

    @Test func aSignedOutAccountClearsTheScreensAndThePanel() async {
        let rig = await make()
        rig.shell.accountChanged(SampleData.userID)
        rig.openDetail(139)
        rig.shell.openSession(Fx.session(1))
        rig.shell.accountChanged(nil)
        #expect(rig.shell.nav.current == .projects && rig.shell.sessionPanelID == nil)
    }

    @Test func theSessionsListKeepsEverySessionOldestFirstWithClosedOnesAtTheBottom() async {
        let rig = await make(sessions: .nine)
        rig.openDetail(139)
        #expect(rig.shell.sessions(of: Fx.issue(139)).count == 9, "탭의 여섯 + More는 없다: 이슈 상세 목록이 모든 세션을 말한다")
        let closed = await make(sessions: .closedAndStates)
        closed.openDetail(139)
        #expect(closed.shell.sessions(of: Fx.issue(139)).last?.id == Fx.session(1), "닫힌 세션은 Sessions 목록의 맨 아래다")
    }

    @Test func aSessionPanelThatIsOpenWhenTheScreenLeavesTheDetailClosesOnTheNextReconcile() async {
        let rig = await make()
        rig.openDetail(139)
        rig.shell.openSession(Fx.session(1))
        #expect(rig.shell.sessionPanelShown)
        rig.shell.openList(.project(Fx.taskforce))
        #expect(rig.shell.sessionPanelID == nil && !rig.shell.sessionPanelShown, "목록 화면에서 열린 세션 패널은 닫힌다 (OA U3-53)")
    }

    @Test func theSessionPanelOnlyExistsWhileThePanelIsOpen() async {
        let rig = await make()
        rig.openDetail(139)
        rig.shell.dismiss()
        #expect(!rig.shell.sessionPanelShown, "패널이 접히면 세션 패널 창이 없다")
        rig.shell.openSession(Fx.session(1))
        #expect(rig.shell.sessionPanelID == nil)
    }

    // MARK: 칩 · 새 세션

    @Test func theOpenItemIsTheInnermostThingOpen() async {
        let rig = await make()
        rig.shell.openAllWork()
        #expect(rig.shell.openItem == nil, "Projects에는 칩이 없다")
        rig.openProject()
        #expect(rig.shell.openItem == AssistantOpenItem(kind: .context, id: Fx.taskforce, title: "Taskforce 0.2.0"))
        rig.shell.openList(.ungrouped)
        #expect(rig.shell.openItem == nil, "Ungrouped에는 칩이 없다")
        rig.shell.openIssue(Fx.issue(139))
        #expect(rig.shell.openItem == AssistantOpenItem(kind: .action, id: Fx.issue(139), title: "Rewrite pricing page copy for the 3-day trial and Lifetime plan", number: 139))
        rig.shell.openSession(Fx.session(1))
        #expect(rig.shell.openItem == AssistantOpenItem(kind: .agentSession, id: Fx.session(1), title: "Pricing copy draft"), "세션 패널이 열리면 그 세션")
        rig.shell.dismiss()
        #expect(rig.shell.openItem == nil, "패널이 접히면 없다")
    }

    @Test func aNewSessionFromTheRailCarriesTheOpenItem() async {
        let rig = await make()
        var received: [AssistantOpenItem?] = []
        rig.shell.onNewSession = { received.append($0) }
        rig.shell.newSession(from: .rail)
        rig.openDetail(139)
        rig.shell.newSession(from: .rail)
        rig.shell.openSession(Fx.session(1))
        rig.shell.newSession(from: .rail)
        rig.openProject()
        rig.shell.newSession(from: .rail)
        let issue = AssistantOpenItem(kind: .action, id: Fx.issue(139), title: "Rewrite pricing page copy for the 3-day trial and Lifetime plan", number: 139)
        let project = AssistantOpenItem(kind: .context, id: Fx.taskforce, title: "Taskforce 0.2.0")
        #expect(received.count == 4)
        #expect(received[0] == nil, "패널이 닫혀 있으면 칩 없이")
        #expect(received[1] == issue)
        #expect(received[2] == AssistantOpenItem(kind: .agentSession, id: Fx.session(1), title: "Pricing copy draft"), "레일 + = 지금 패널에 열린 것")
        #expect(received[3] == project)
    }

    // MARK: 레일의 링

    @Test func theRingIsOnePerIssueWithTheFirstOfTheNeedsYouToDoneOrder() async {
        let rig = await make()
        let kinds = Dictionary(uniqueKeysWithValues: rig.shell.slots.map { ($0.id, $0.kind) })
        #expect(kinds[Fx.issue(141)] == .needsYou, "세션이 질문하면 v1 running보다 needs-you가 먼저")
        #expect(kinds[Fx.issue(139)] == .running, "세션 하나가 도는 이슈")
        #expect(rig.shell.slots.count == Set(rig.shell.slots.map(\.id)).count, "이슈마다 링 하나")
    }

    @Test func anIdleSessionIsNeverARailRing() async {
        let rig = await make(sessions: .external)
        let kinds = Dictionary(uniqueKeysWithValues: rig.shell.slots.map { ($0.id, $0.kind) })
        #expect(kinds[Fx.issue(139)] == nil, "idle · external 세션뿐인 이슈에는 링이 없다")
        #expect(kinds[Fx.issue(141)] == .running, "v1 run은 그대로")
    }

    @Test func aSessionOnlyIssueGetsARingWithoutAV1Run() async {
        let rig = await make(sessions: .awaiting)
        let kinds = Dictionary(uniqueKeysWithValues: rig.shell.slots.map { ($0.id, $0.kind) })
        #expect(kinds[Fx.issue(139)] == .needsYou, "v1 run이 없어도 세션의 질문이 링이 된다")
    }

    @Test func theUnreachableRingCarriesTheConnectionLostActivity() async {
        let rig = await make(sessions: .closedAndStates)
        let entry = rig.shell.slots.first { $0.id == Fx.issue(139) }
        #expect(entry?.kind == .unreachable && entry?.activity == "Connection lost · progress unknown")
    }

    @Test func theGatedOffRailKeepsTheOldRingRules() async {
        let rig = await make(sessions: .awaiting, gated: false)
        let kinds = Dictionary(uniqueKeysWithValues: rig.shell.slots.map { ($0.id, $0.kind) })
        #expect(kinds[Fx.issue(139)] == nil, "게이트가 꺼지면 세션은 링에 반영되지 않는다")
        #expect(kinds[Fx.issue(141)] == .running)
    }

    // MARK: 게이트가 꺼진 셸

    @Test func aShellWithoutTheGateKeepsAllWorkAndIgnoresTheIssueCommands() async {
        let rig = await make(gated: false)
        #expect(!rig.shell.issueScreensEnabled && rig.shell.issues == nil)
        rig.shell.openAllWork()
        rig.shell.openList(.project(Fx.taskforce))
        rig.shell.openIssue(Fx.issue(139))
        rig.shell.openSession(Fx.session(1))
        #expect(rig.shell.nav.current == .projects && rig.shell.sessionPanelID == nil && !rig.shell.sessionPanelShown)
        #expect(rig.shell.panelTitle == "Your work" && rig.shell.view == .allWork, "머리는 지금 그대로 (Your work)")
        rig.shell.open(itemID: Fx.issue(139))
        #expect(rig.shell.currentID == Fx.issue(139) && rig.shell.nav.current == .projects, "지금처럼 All work에서 그 행을 고른다")
        #expect(rig.shell.openItem == AssistantOpenItem(kind: .action, id: Fx.issue(139), title: "Rewrite pricing page copy for the 3-day trial and Lifetime plan"), "번호 · 종류 확장 없이 지금 칩")
        var newSessions = 0
        rig.shell.onNewSession = { _ in newSessions += 1 }
        rig.shell.newSession(from: .rail)
        #expect(newSessions == 0)
        rig.shell.escape()
        #expect(!rig.shell.panelOpen)
    }

    // MARK: 레일 `+` 자리

    @Test func thePlusRowAddsOneStepOnlyWhenGatedAndOnlyWhenTheRailIsExpanded() {
        #expect(EdgeRailLayout.windowHeight(plus: false) == EdgeRailLayout.windowHeight, "꺼져 있으면 지금 높이 그대로")
        #expect(EdgeRailLayout.windowHeight(plus: true) == EdgeRailLayout.windowHeight + EdgeRailLayout.item + EdgeRailLayout.gap)
        let base = EdgeRailLayout(notchCount: 2, restCount: 1, expanded: true, idle: false, controls: EdgeShellModel.Control.defaultControls)
        var withPlus = base
        withPlus.plus = true
        let step = EdgeRailLayout.item + EdgeRailLayout.gap
        #expect(base.plusFrame == nil, "+가 없는 레일에는 칸이 없다")
        let frame = withPlus.plusFrame
        #expect(frame?.height == EdgeRailLayout.item && frame?.minY == withPlus.restFrame(withPlus.restCount).minY, "링 바로 뒤")
        #expect(withPlus.ruleY == base.ruleY + step, "구분선이 한 칸 내려간다")
        #expect(withPlus.controlFrame(.allWork).minY == base.controlFrame(.allWork).minY + step && withPlus.controlFrame(.chats).minY == base.controlFrame(.chats).minY + step)
        let folded = EdgeRailLayout(notchCount: 2, restCount: 1, expanded: false, idle: false, controls: EdgeShellModel.Control.defaultControls, plus: true)
        #expect(folded.plusFrame == nil, "숨은 레일의 노치에는 +가 없다")
    }

    @Test func thePlusHitTestFollowsItsFrameAndIgnoresAnIdleRail() {
        let layout = EdgeRailLayout(notchCount: 1, restCount: 0, expanded: true, idle: false, controls: EdgeShellModel.Control.defaultControls, plus: true)
        let frame = layout.plusFrame!
        #expect(layout.hitsPlus(CGPoint(x: frame.midX, y: frame.midY)))
        #expect(!layout.hitsPlus(CGPoint(x: frame.midX, y: frame.maxY + 40)))
        let idle = EdgeRailLayout(notchCount: 0, restCount: 0, expanded: true, idle: true, controls: EdgeShellModel.Control.defaultControls, plus: true)
        if let frame = idle.plusFrame { #expect(!idle.hitsPlus(CGPoint(x: frame.midX, y: frame.midY))) }
    }

    // MARK: 창 자리

    @Test func thePanelRightEdgeIsSixtyTwoFromTheScreenEdgeOnlyWithTheCapsuleRail() {
        let notch = EdgePanelMetrics.frame(height: 400, railTop: 800, screenMaxX: 1440)
        let capsule = EdgePanelMetrics.frame(height: 400, railTop: 800, screenMaxX: 1440, capsule: true)
        #expect(notch.width == 380 && notch.maxX == 1440 - EdgeRailLayout.railWidth - EdgePanelMetrics.gap, "노치 레일은 지금 자리 그대로")
        #expect(capsule.width == 380 && capsule.maxX == 1440 - 62, "캡슐 레일: 화면 끝 − 6 − 44 − 12 (DS .tf-screen > .tf-panel)")
        #expect(capsule.maxY == notch.maxY, "위는 지금 그대로 (화면 위에서 120, U3-11)")
    }

    @Test func thePanelHasNoHeightFloorOnlyOnTheCapsuleScreens() {
        #expect(EdgePanelMetrics.height(body: 100, fits: true) == EdgePanelMetrics.headerHeight + 100, "내용에 맞춘다 (OA U3-31)")
        #expect(EdgePanelMetrics.height(body: 100) == 320, "게이트 꺼짐은 320 바닥 그대로")
        #expect(EdgePanelMetrics.height(body: 900, fits: true) == 520)
    }

    @Test func theSessionPanelSitsFortyLeftOfTheIssuePanelTopAligned() {
        let issue = EdgePanelMetrics.frame(height: 440, railTop: 800, screenMaxX: 1440, capsule: true)
        let frame = EdgeSessionPanelController.frame(issuePanel: issue, height: 380)
        #expect(frame.width == 380 && frame.maxX == issue.minX - 40, "이슈 패널 본체에서 40 (지금 보이는 간격 그대로)")
        #expect(frame.maxY == issue.maxY && frame.height == 380, "위를 맞춘다")
    }
}

/// 세션을 읽는 길이 없는 연결 (`IssueScreensGateway`가 아닌 시험용 가짜)
private final class PlainChatGateway: ChatGateway, @unchecked Sendable {
    func conversations() async throws -> [ChatConversation] { [] }
    func lastMessages(conversationIDs: [UUID]) async throws -> [UUID: ChatMessage] { [:] }
    func messages(conversationID: UUID) async throws -> [ChatMessage] { [] }
    func message(id: UUID) async throws -> ChatMessage? { nil }
    func workContexts() async throws -> [WorkContext] { [] }
    func currentMemoryItems() async throws -> [MemoryItem] { [] }
    func memoryItems(ids: [UUID]) async throws -> [MemoryItem] { [] }
    func memorySource(id: UUID) async throws -> MemorySource? { nil }
    func createConversation(id: UUID, title: String?, contextID: UUID?) async throws -> ChatConversation { throw URLError(.badURL) }
    func updateConversation(id: UUID, contextID: UUID?) async throws -> ChatConversation { throw URLError(.badURL) }
    func postChatMessage(conversationID: UUID, clientMessageID: UUID, text: String) async throws -> ChatPostedMessage { throw URLError(.badURL) }
    func confirmMemory(id: UUID, expectedVersion: Int) async throws -> MemoryItem { throw URLError(.badURL) }
    func editMemory(id: UUID, edit: MemoryEdit) async throws -> MemoryItem { throw URLError(.badURL) }
    func forgetMemory(id: UUID, expectedVersion: Int) async throws -> MemoryItem { throw URLError(.badURL) }
    func moveMemory(id: UUID, expectedVersion: Int, to target: MemoryTarget) async throws -> MemoryItem { throw URLError(.badURL) }
}
