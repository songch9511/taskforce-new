import Foundation
import Testing
@testable import TaskforceKit

/// 이슈 목록(프로젝트 · Ungrouped · Done today)과 IssueRow의 meta (U2-02 · 03 · 29 · 30): 상태별 그룹 In Progress → To Do → Done today, 서버 순서, meta 하나(활동 → 기한 → 없음)
struct IssueRowsTests {
    typealias Fx = SessionFx
    typealias P = ProjectRowsTests

    static let projectA = P.project(1, "Taskforce 0.2.0")
    static let projectB = P.project(2, "Shape launch")

    private func content(
        _ scope: IssueListScope, _ items: [WorkItem], contexts: [WorkContext] = [projectA, projectB], sessions: [AgentSessionItem] = []
    ) -> IssueListContent? {
        IssueListRules.content(scope: scope, items: items, contexts: contexts, sessions: sessions, today: P.today)
    }

    // MARK: 그룹 · 순서

    @Test func groupsAreInProgressThenToDoThenDoneTodayAndEmptyOnesAreNotDrawn() throws {
        let a = P.link(1, "Taskforce 0.2.0")
        let items = [
            P.item(1, "Todo A", links: [a]), P.item(2, "Doing A", state: .inProgress, links: [a]), P.item(3, "Done A", state: .done, links: [a]),
            P.item(4, "Todo B", links: [a]), P.item(5, "Doing B", state: .inProgress, links: [a]),
        ]
        let list = try #require(content(.project(Fx.id(1, prefix: "c0000000")), items))
        #expect(list.title == "Taskforce 0.2.0")
        #expect(list.groups.map(\.label) == ["In Progress", "To Do", "Done today"])
        #expect(list.groups[0].rows.map(\.title) == ["Doing A", "Doing B"], "서버 순서")
        #expect(list.groups[1].rows.map(\.title) == ["Todo A", "Todo B"])
        #expect(list.groups[2].rows.map(\.title) == ["Done A"])
        let onlyTodo = try #require(content(.project(Fx.id(1, prefix: "c0000000")), [P.item(1, "Todo A", links: [a])]))
        #expect(onlyTodo.groups.map(\.label) == ["To Do"])
    }

    @Test func doneTodayKeepsTheMostRecentFirstOrderItWasGiven() throws {
        let a = P.link(1, "Taskforce 0.2.0")
        let items = [P.item(1, "Latest", state: .done, links: [a]), P.item(2, "Earlier", state: .done, links: [a])]
        let list = try #require(content(.project(Fx.id(1, prefix: "c0000000")), items))
        #expect(list.groups.last?.rows.map(\.title) == ["Latest", "Earlier"])
    }

    @Test func aProjectListOnlyHasThatProjectsIssuesAndAnIssueInTwoShowsInBoth() throws {
        let a = P.link(1, "Taskforce 0.2.0"), b = P.link(2, "Shape launch")
        let items = [P.item(1, "Only A", links: [a]), P.item(2, "Only B", links: [b]), P.item(3, "Both", links: [a, b]), P.item(4, "None", links: [])]
        let inA = try #require(content(.project(a.project.id), items))
        let inB = try #require(content(.project(b.project.id), items))
        #expect(inA.groups.flatMap(\.rows).map(\.title) == ["Only A", "Both"])
        #expect(inB.groups.flatMap(\.rows).map(\.title) == ["Only B", "Both"])
        #expect(inA.issueIDs == [Fx.issue(1), Fx.issue(3)], "탭이 보는 이슈들")
    }

    @Test func ungroupedIncludesIssuesWhoseOnlyProjectsAreArchived() throws {
        let old = P.link(9, "Old", archived: true)
        let items = [P.item(1, "Loose", links: []), P.item(2, "In archived", links: [old]), P.item(3, "In live", links: [P.link(1, "Taskforce 0.2.0")])]
        let list = try #require(content(.ungrouped, items, contexts: [Self.projectA, P.project(9, "Old", archived: true)]))
        #expect(list.title == "Ungrouped")
        #expect(list.groups.flatMap(\.rows).map(\.title) == ["Loose", "In archived"])
        #expect(list.allowsAdd)
    }

    @Test func ungroupedHasItsOwnDoneTodayGroupToo() throws {
        let items = [P.item(1, "Open loose", links: []), P.item(2, "Done loose", state: .done, links: []), P.item(3, "Done in A", state: .done, links: [P.link(1, "Taskforce 0.2.0")])]
        let list = try #require(content(.ungrouped, items))
        #expect(list.groups.map(\.label) == ["To Do", "Done today"])
        #expect(list.groups[1].rows.map(\.title) == ["Done loose"])
    }

    @Test func doneTodayIsOneListWithoutALabelOrAnAddButton() throws {
        let items = [
            P.item(1, "Done in project", state: .done, links: [P.link(1, "Taskforce 0.2.0")]), P.item(2, "Done loose", state: .done, links: []),
            P.item(3, "Still open", links: []),
        ]
        let list = try #require(content(.doneToday, items))
        #expect(list.title == "Done today" && !list.allowsAdd)
        #expect(list.groups.count == 1 && list.groups[0].label == nil)
        #expect(list.groups[0].rows.map(\.title) == ["Done in project", "Done loose"], "프로젝트와 상관없이 오늘 끝낸 것 전부")
    }

    @Test func aProjectThatIsGoneOrArchivedHasNoList() {
        #expect(content(.project(Fx.id(7, prefix: "c0000000")), []) == nil, "없는 프로젝트")
        let archived = P.project(1, "Old", archived: true)
        #expect(content(.project(archived.id), [], contexts: [archived]) == nil, "보관한 프로젝트는 목록이 없다")
    }

    @Test func anEmptyProjectKeepsItsTitleAndNothingElse() throws {
        let list = try #require(content(.project(Fx.id(1, prefix: "c0000000")), []))
        #expect(list.title == "Taskforce 0.2.0" && list.groups.isEmpty && list.isEmpty && list.allowsAdd)
    }

    @Test func issuesWithUnknownMembershipsAreInNoList() throws {
        let list = try #require(content(.ungrouped, [P.item(1, "Who knows", known: false)]))
        #expect(list.isEmpty)
    }

    // MARK: 행 meta (U2-02)

    private func row(_ item: WorkItem, sessions: [AgentSessionItem] = []) throws -> IssueRowContent {
        let list = try #require(content(.ungrouped, [item], sessions: sessions))
        return try #require(list.groups.flatMap(\.rows).first)
    }

    @Test func metaIsTheActivityFirst() throws {
        let overdue = LocalDate(year: 2026, month: 10, day: 1)!
        let needs = try row(P.item(1, "T", activity: WorkActivity.needsAnswer, due: overdue))
        #expect(needs.activity == "Needs your answer" && needs.metaText == "Needs your answer" && !needs.metaIsDue)
        let running = try row(P.item(1, "T", state: .inProgress, activity: WorkActivity.running))
        #expect(running.metaText == "Running")
        let stopping = try row(P.item(1, "T", state: .inProgress, activity: WorkActivity.stopRequested))
        #expect(stopping.metaText == "Stop requested · not confirmed")
    }

    @Test func aSessionsActivityJoinsTheV1ActivityByTheSameRingOrder() throws {
        let item = P.item(1, "T", state: .inProgress, activity: WorkActivity.running)
        #expect(try row(item, sessions: [P.session(1, issue: 1, ring: .unreachable)]).metaText == "Connection lost · progress unknown")
        #expect(try row(item, sessions: [P.session(1, issue: 1, ring: .needsYou)]).metaText == "Needs your answer")
        #expect(try row(P.item(1, "T", state: .inProgress), sessions: [P.session(1, issue: 1, ring: .stopping)]).metaText == "Stop requested · not confirmed")
        #expect(try row(P.item(1, "T", state: .inProgress), sessions: [P.session(1, issue: 1, ring: .running)]).metaText == "Running")
        // 다른 이슈의 세션은 이 행에 말하지 않는다
        #expect(try row(P.item(1, "T"), sessions: [P.session(1, issue: 2, ring: .running)]).activity == nil)
        // idle · done · waiting 세션은 활동 말이 없다
        for ring in [AgentSessionRing.idle, .done, .waiting] {
            #expect(try row(P.item(1, "T"), sessions: [P.session(1, issue: 1, ring: ring)]).activity == nil, "\(ring)")
        }
    }

    @Test func withoutAnActivityMetaIsTheDueDate() throws {
        let friday = LocalDate(year: 2026, month: 10, day: 17)!
        let due = try row(P.item(1, "T", due: friday))
        #expect(due.activity == nil && due.due == "Sat" && due.metaText == "Sat" && due.metaIsDue)
        #expect(try row(P.item(1, "T", due: P.today)).due == "Today")
        #expect(try row(P.item(1, "T", due: LocalDate(year: 2026, month: 10, day: 25)!)).due == "Oct 25")
        let none = try row(P.item(1, "T"))
        #expect(none.metaText == nil && none.due == nil)
    }

    @Test func anOverdueDateIsRedAndSaysOverdueAndTodayIsRedWithoutOverdue() throws {
        let past = try row(P.item(1, "T", due: LocalDate(year: 2026, month: 10, day: 14)!))
        #expect(past.due == "Yesterday" && past.urgent && past.overdue)
        let today = try row(P.item(1, "T", due: P.today))
        #expect(today.urgent && !today.overdue)
        let future = try row(P.item(1, "T", due: LocalDate(year: 2026, month: 10, day: 16)!))
        #expect(!future.urgent && !future.overdue)
    }

    @Test func aDoneRowIsNeverUrgentOrOverdue() throws {
        let done = try #require(content(.doneToday, [P.item(1, "T", state: .done, due: LocalDate(year: 2026, month: 10, day: 1)!)]))
        let row = try #require(done.groups.first?.rows.first)
        #expect(!row.urgent && !row.overdue && row.state == .done)
    }

    @Test func aDoneRowHasNoActivity() throws {
        let done = try #require(content(.doneToday, [P.item(1, "T", state: .done, activity: WorkActivity.needsAnswer)]))
        #expect(done.groups[0].rows[0].activity == nil)
    }

    @Test func accessibilityNameCarriesTitleStateActivityAndDue() throws {
        let friday = LocalDate(year: 2026, month: 10, day: 17)!
        let item = try row(P.item(1, "Rewrite pricing", state: .inProgress, activity: WorkActivity.running, due: friday))
        #expect(item.accessibilityLabel == "Rewrite pricing — In Progress · Running, due Sat")
        let overdue = try row(P.item(1, "Late", due: LocalDate(year: 2026, month: 10, day: 1)!))
        #expect(overdue.accessibilityLabel == "Late — To Do, overdue, due Oct 1")
        #expect(try row(P.item(1, "Plain")).accessibilityLabel == "Plain — To Do")
    }

    @Test func numbersStayOutOfTheRow() throws {
        let numbered = WorkItem(action: P.item(1, "T").action, state: .toDo, memberships: .none, number: 139)
        let item = try row(numbered)
        #expect(item.metaText == nil && !item.accessibilityLabel.contains("139"))
    }
}
