#if os(macOS)
import Foundation
import Testing
@testable import TaskforceKit

/// 프로젝트 이슈 목록의 Sessions 묶음(에이전트 트리 T3m)의 순수 규칙: 그 목록의 이슈(열린 · 오늘 끝난)에 묶인 세션의 합집합, 다른 프로젝트와의 공유,
/// 접힌 행의 "Running n", 다시 읽지 않는 30초. 화면도 파일 읽기도 없다
struct ProjectSessionsTests {
    typealias Fx = SessionFx
    typealias P = ProjectRowsTests

    private func session(_ n: Int, issues: [Int], created: Double? = nil, closed: Bool = false, agent: AgentMarkKind = .claudeCode) -> AgentSessionItem {
        AgentSessionItem(
            id: Fx.id(n), name: "S\(n)", agent: agent, agentName: agent == .codex ? "Codex" : "Claude Code", connectionID: Fx.claudeConnection,
            status: closed ? .closed : .bound, ring: closed ? nil : .running, line: closed ? "" : "Running", createdAt: Fx.at(created ?? Double(n)),
            updatedAt: Fx.at(created ?? Double(n)), issueIDs: issues.map { Fx.issue($0) }, currentIssueID: issues.first.map { Fx.issue($0) }, conversationID: nil,
            hasOpenTask: false, pill: nil
        )
    }

    private func ids(_ items: [AgentSessionItem]) -> [UUID] { items.map(\.id) }

    // MARK: 합집합

    @Test func aSessionOnTwoIssuesOfTheProjectIsListedOnce() {
        let items = [session(1, issues: [1, 2]), session(2, issues: [2])]
        let union = ProjectSessions.union(issueIDs: [Fx.issue(1), Fx.issue(2)], in: items)
        #expect(ids(union) == [Fx.id(1), Fx.id(2)], "이슈 둘에 묶인 세션 1은 한 번만")
    }

    @Test func theSameSessionTwiceInTheInputCountsOnce() {
        let one = session(1, issues: [1])
        #expect(ids(ProjectSessions.union(issueIDs: [Fx.issue(1)], in: [one, one])) == [Fx.id(1)])
    }

    @Test func sessionsOfOpenIssuesAndIssuesDoneTodayAreBothInTheUnion() {
        // 프로젝트의 이슈 목록 규칙이 정한 이슈 전부(`IssueListContent.issueIDs`)가 입력이다: 열린 이슈(1) + 오늘 끝난 이슈(2)
        let project = P.project(1, "Launch")
        let link = P.link(1, "Launch")
        let items = [P.item(1, "Open one", state: .inProgress, links: [link]), P.item(2, "Finished", state: .done, links: [link]), P.item(3, "Elsewhere", links: [])]
        let list = IssueListRules.content(scope: .project(project.id), items: items, contexts: [project], sessions: [], today: P.today)
        let sessions = [session(1, issues: [1]), session(2, issues: [2]), session(3, issues: [3])]
        let union = ProjectSessions.union(issueIDs: list?.issueIDs ?? [], in: sessions)
        #expect(Set(ids(union)) == [Fx.id(1), Fx.id(2)], "열린 이슈와 오늘 끝난 이슈의 세션은 들어오고, 프로젝트 밖 이슈의 세션은 아니다")
    }

    @Test func aSessionSharedWithAnotherProjectIsInBothProjectsUnions() {
        let shared = session(1, issues: [1, 2])
        let items = [shared, session(2, issues: [1])]
        #expect(ids(ProjectSessions.union(issueIDs: [Fx.issue(1)], in: items)) == [Fx.id(1), Fx.id(2)], "프로젝트 A(이슈 1)")
        #expect(ids(ProjectSessions.union(issueIDs: [Fx.issue(2)], in: items)) == [Fx.id(1)], "프로젝트 B(이슈 2)에도 같은 세션이 나온다")
    }

    @Test func theOrderIsTheIssueDetailRuleCreationOrderWithClosedSessionsLast() {
        let items = [
            session(5, issues: [2], created: 50), session(1, issues: [1], created: 10, closed: true), session(3, issues: [1], created: 30), session(2, issues: [2], created: 20),
        ]
        let union = ProjectSessions.union(issueIDs: [Fx.issue(2), Fx.issue(1)], in: items)
        #expect(ids(union) == [Fx.id(2), Fx.id(3), Fx.id(5), Fx.id(1)], "이슈 순서와 상관없이 만든 시각 순, 닫힌 세션은 맨 아래")
        #expect(ids(union) == AgentSessionRules.listOrder(AgentSessionRules.sessions(of: [Fx.issue(1), Fx.issue(2)], in: items)).map(\.id), "이슈 상세 Sessions 목록과 같은 규칙")
    }

    @Test func noIssuesOrNoSessionsGiveNothing() {
        #expect(ProjectSessions.union(issueIDs: [], in: [session(1, issues: [1])]).isEmpty)
        #expect(ProjectSessions.union(issueIDs: [Fx.issue(1)], in: []).isEmpty)
        #expect(ProjectSessions.union(issueIDs: [Fx.issue(9)], in: [session(1, issues: [1])]).isEmpty, "이슈가 없는 세션 · 다른 이슈의 세션")
    }

    // MARK: 다른 프로젝트와의 공유

    private func work(_ n: Int, links: [WorkLink]) -> WorkItem { P.item(n, "Issue \(n)", links: links) }

    @Test func aSessionBoundToAnIssueOfAnotherProjectNamesThatProjectAndNothingElse() {
        let a = P.link(1, "Alpha"), b = P.link(2, "Beta"), c = P.link(3, "Gamma")
        let items = [work(1, links: [a]), work(2, links: [b, c]), work(3, links: [])]
        let shared = session(1, issues: [1, 2])
        #expect(ProjectSessions.otherProjects(of: shared, besides: a.project.id, in: items) == ["Beta", "Gamma"], "지금 프로젝트(Alpha)는 빼고 이름순")
        #expect(ProjectSessions.otherProjects(of: shared, besides: b.project.id, in: items) == ["Alpha", "Gamma"], "Beta에서 보면 Alpha · Gamma")
        #expect(ProjectSessions.otherProjects(of: session(2, issues: [1]), besides: a.project.id, in: items).isEmpty, "한 프로젝트에만 묶인 세션은 공유가 아니다")
    }

    @Test func archivedProjectsAndLooseIssuesAndUnknownMembershipsDoNotCount() {
        let a = P.link(1, "Alpha"), old = P.link(2, "Old", archived: true)
        let items = [work(1, links: [a]), work(2, links: [old]), work(3, links: []), P.item(4, "Unread", links: [], known: false)]
        let shared = session(1, issues: [1, 2, 3, 4])
        #expect(ProjectSessions.otherProjects(of: shared, besides: a.project.id, in: items).isEmpty)
    }

    @Test func theSameOtherProjectOnSeveralIssuesIsNamedOnceAndSameNamesKeepAStableOrder() {
        let a = P.link(1, "Alpha"), b1 = P.link(2, "Beta"), b2 = P.link(3, "beta")
        let items = [work(1, links: [a]), work(2, links: [b1]), work(3, links: [b1]), work(4, links: [b2])]
        let shared = session(1, issues: [1, 2, 3, 4])
        #expect(ProjectSessions.otherProjects(of: shared, besides: a.project.id, in: items) == ["Beta", "beta"], "같은 프로젝트는 한 번, 이름이 같아도 서로 다른 프로젝트는 둘 (id 순)")
    }

    // MARK: 접힌 행의 "Running n"

    private func list(_ events: [BackgroundTaskEvent]) -> BackgroundTaskList {
        var list = BackgroundTaskList()
        for event in events { list.apply(event, now: Fx.at(100)) }
        return list
    }

    private func start(_ id: String, parent: String? = nil, depth: Int? = nil) -> BackgroundTaskEvent {
        .started(taskID: id, toolUseID: nil, kind: .agent, name: "Agent \(id)", at: Fx.at(1), parentID: parent, depth: depth, foreground: false)
    }

    @Test func theCollapsedSummaryCountsEveryRunningTaskAndSaysNothingWhenNoneRun() {
        #expect(ProjectSessions.runningSummary(BackgroundTaskList()) == nil)
        let tasks = list([start("a"), start("b", parent: "a", depth: 2), start("c"), .finished(taskID: "c", kind: .agent, status: .done, exitCode: nil, at: Fx.at(9))])
        #expect(ProjectSessions.runningSummary(tasks) == "Running 2", "중첩된 자식도 센다. 끝난 일은 세지 않는다: 기존 낱말 Running과 숫자뿐")
        let none = list([start("a"), .finished(taskID: "a", kind: .agent, status: .failed, exitCode: nil, at: Fx.at(9))])
        #expect(ProjectSessions.runningSummary(none) == nil, "도는 일이 없으면 아무것도 보이지 않는다 (Failed는 접힌 행에 쓰지 않는다)")
    }

    @Test func tasksWithoutAStatusAreNotCountedAsRunning() {
        let tasks = list([start("a")]).adding(subagents: [SubagentMeta(id: "n", parentID: "a", depth: 2, name: "Nested", requestShape: nil, toolUseID: nil)])
        #expect(tasks.tasks.count == 2)
        #expect(ProjectSessions.runningSummary(tasks) == "Running 1", "상태를 모르는 줄은 도는 일이 아니다")
    }

    // MARK: 30초 안에는 다시 읽지 않는다

    @Test func aTreeIsReadAgainOnlyAfterThirtySeconds() {
        #expect(ProjectSessions.rereadInterval == 30)
        #expect(ProjectSessions.shouldRead(lastReadAt: nil, now: 1_000), "읽은 적이 없으면 읽는다")
        #expect(!ProjectSessions.shouldRead(lastReadAt: 1_000, now: 1_000), "방금")
        #expect(!ProjectSessions.shouldRead(lastReadAt: 1_000, now: 1_029.9))
        #expect(ProjectSessions.shouldRead(lastReadAt: 1_000, now: 1_030), "30초가 지났다")
        #expect(ProjectSessions.shouldRead(lastReadAt: 1_000, now: 5_000))
    }

    @Test func theDisclosureSpeaksTheApprovedWordsOnly() {
        #expect(ProjectSessions.disclosureValue(isExpanded: true) == "Expanded" && ProjectSessions.disclosureValue(isExpanded: false) == "Collapsed")
        #expect(ProjectSessions.disclosureAction(isExpanded: true) == "Show less" && ProjectSessions.disclosureAction(isExpanded: false) == "Show all")
    }

    // MARK: 그리는 창

    @Test func aLongTreeIsCutAtTheDrawWindowUntilTheUserShowsAll() {
        func rows(_ count: Int) -> [SubagentTreeRow] {
            let tasks = list((0..<count).map { start("t\($0)") })
            return SubagentTree.rows(for: tasks, expansion: SubagentTreeExpansion())
        }
        let few = rows(ProjectSessions.treeRowWindow)
        #expect(ProjectSessions.visible(few, showsAll: false).rows.count == few.count && !ProjectSessions.visible(few, showsAll: false).isCut, "창 안이면 그대로")
        let many = rows(ProjectSessions.treeRowWindow + 40)
        let cut = ProjectSessions.visible(many, showsAll: false)
        #expect(cut.rows.count == ProjectSessions.treeRowWindow && cut.isCut && cut.rows.map(\.id) == Array(many.prefix(ProjectSessions.treeRowWindow)).map(\.id))
        #expect(ProjectSessions.visible(many, showsAll: true).rows.count == many.count && ProjectSessions.visible(many, showsAll: true).isCut, "모두 보이게 해도 잘렸었다는 사실은 남아 접을 수 있다")
        #expect(ProjectSessions.treeRowWindow == 150, "21-7의 그리는 창과 같은 크기")
    }
}
#endif
