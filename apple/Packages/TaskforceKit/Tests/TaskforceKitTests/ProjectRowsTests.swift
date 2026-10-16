import Foundation
import Testing
@testable import TaskforceKit

/// Issues 첫 화면(Projects 목록, M1)의 행과 meta (U2-01 · 28 · 30 · 34): 활성 프로젝트(이름순) → Ungrouped → Done today.
/// meta는 "가장 행동할 한 줄": 답을 기다림 → 에이전트가 하는 것 → (누구를 기다림: 데이터 없음) → 기한 → 오늘 끝낸 것 → 첫 열린 이슈 → 빈 줄. 개수 없음
struct ProjectRowsTests {
    typealias Fx = SessionFx

    static let today = LocalDate(year: 2026, month: 10, day: 15)!

    static func project(_ n: Int, _ name: String, archived: Bool = false, icon: ProjectIconName = .rocket) -> WorkContext {
        WorkContext(id: Fx.id(n, prefix: "c0000000"), name: name, status: archived ? .archived : .active, contextVersion: 1, icon: icon, version: 1)
    }

    static func link(_ n: Int, _ name: String, archived: Bool = false) -> WorkLink {
        WorkLink(project: WorkProject(id: Fx.id(n, prefix: "c0000000"), name: name, isArchived: archived), origin: .user)
    }

    static func item(
        _ n: Int, _ title: String, state: WorkState = .toDo, links: [WorkLink] = [], activity: String? = nil, due: LocalDate? = nil,
        known: Bool = true
    ) -> WorkItem {
        let action = ActionSummary(
            id: Fx.issue(n), title: title, owner: .me, status: state == .done ? .done : .open, dueDate: due, counterpart: nil, needsConfirmation: false,
            confirmReasons: [], startedAt: state == .inProgress ? Fx.t0 : nil, lastActivityAt: Fx.t0
        )
        return WorkItem(
            action: action, state: state, memberships: known ? .known(links: links, candidates: []) : .unknown, activity: activity
        )
    }

    static func session(
        _ n: Int, issue: Int, ring: AgentSessionRing, agent: AgentMarkKind = .claudeCode, name: String = "Claude Code"
    ) -> AgentSessionItem {
        AgentSessionItem(
            id: Fx.id(n), name: "S\(n)", agent: agent, agentName: name, connectionID: Fx.claudeConnection, status: .bound, ring: ring, line: ring.label,
            createdAt: Fx.at(Double(n)), updatedAt: Fx.at(Double(n)), issueIDs: [Fx.issue(issue)], currentIssueID: Fx.issue(issue), conversationID: nil,
            hasOpenTask: false, pill: nil
        )
    }

    private func rows(_ items: [WorkItem], contexts: [WorkContext], sessions: [AgentSessionItem] = []) -> [ProjectRowContent] {
        ProjectListRules.rows(items: items, contexts: contexts, sessions: sessions, today: Self.today)
    }

    // MARK: 행 · 순서

    @Test func projectsComeByNameThenUngroupedThenDoneToday() {
        let contexts = [Self.project(1, "zeta"), Self.project(2, "Alpha"), Self.project(3, "beta")]
        let items = [
            Self.item(1, "Loose", links: []),
            Self.item(2, "Finished", state: .done, links: [Self.link(1, "zeta")]),
        ]
        let result = rows(items, contexts: contexts)
        #expect(result.map(\.name) == ["Alpha", "beta", "zeta", "Ungrouped", "Done today"], "대소문자를 가리지 않는 이름순")
        #expect(result.map(\.kind) == [
            .project(Fx.id(2, prefix: "c0000000")), .project(Fx.id(3, prefix: "c0000000")), .project(Fx.id(1, prefix: "c0000000")), .ungrouped, .doneToday,
        ])
    }

    @Test func sameNamesAreOrderedByIdSoTheOrderNeverShakes() {
        let contexts = [Self.project(2, "Launch"), Self.project(1, "launch")]
        #expect(rows([], contexts: contexts).map(\.id) == [
            "project:\(Fx.id(1, prefix: "c0000000").uuidString)", "project:\(Fx.id(2, prefix: "c0000000").uuidString)",
        ])
    }

    @Test func archivedProjectsAreNotRowsAndTheirIssuesAreUngrouped() {
        let contexts = [Self.project(1, "Old", archived: true), Self.project(2, "Live")]
        let items = [Self.item(1, "Left behind", links: [Self.link(1, "Old", archived: true)])]
        let result = rows(items, contexts: contexts)
        #expect(result.map(\.name) == ["Live", "Ungrouped"])
        #expect(result[1].meta == "Left behind")
    }

    @Test func anIssueWithAnArchivedAndALiveProjectBelongsToTheLiveOneOnly() {
        let contexts = [Self.project(1, "Old", archived: true), Self.project(2, "Live")]
        let items = [Self.item(1, "Both", links: [Self.link(1, "Old", archived: true), Self.link(2, "Live")])]
        let result = rows(items, contexts: contexts)
        #expect(result.map(\.name) == ["Live"], "Ungrouped는 비었다")
        #expect(result[0].meta == "Both")
    }

    @Test func emptyUngroupedAndDoneTodayRowsAreNotDrawn() {
        let result = rows([Self.item(1, "In project", links: [Self.link(1, "A")])], contexts: [Self.project(1, "A")])
        #expect(result.map(\.name) == ["A"])
        #expect(rows([], contexts: []).isEmpty)
    }

    @Test func anEmptyProjectIsStillARowWithAnEmptyMeta() {
        let result = rows([], contexts: [Self.project(1, "Empty")])
        #expect(result.count == 1 && result[0].meta == "" && result[0].accessibilityName == "Empty")
    }

    @Test func anIssueInTwoProjectsShowsInEach() {
        let contexts = [Self.project(1, "A"), Self.project(2, "B")]
        let items = [Self.item(1, "Shared", links: [Self.link(1, "A"), Self.link(2, "B")])]
        let result = rows(items, contexts: contexts)
        #expect(result.map(\.meta) == ["Shared", "Shared"])
    }

    @Test func issuesWhoseMembershipsAreStillUnknownAreInNoRow() {
        let result = rows([Self.item(1, "Who knows", known: false)], contexts: [Self.project(1, "A")])
        #expect(result.map(\.name) == ["A"] && result[0].meta == "")
    }

    @Test func projectRowsCarryTheirIconAndTheFixedRowsCarryNone() {
        let result = rows([Self.item(1, "Loose")], contexts: [Self.project(1, "A", icon: .megaphone)])
        #expect(result[0].icon == .megaphone && result[1].icon == nil)
    }

    // MARK: meta (U2-28)

    @Test func metaFirstSaysWhatNeedsYourAnswer() {
        let items = [
            Self.item(1, "Due soon", links: [Self.link(1, "A")], due: Self.today),
            Self.item(2, "Pricing tone", links: [Self.link(1, "A")], activity: WorkActivity.needsAnswer),
            Self.item(3, "Other ask", links: [Self.link(1, "A")], activity: WorkActivity.needsAnswer),
        ]
        #expect(rows(items, contexts: [Self.project(1, "A")])[0].meta == "Needs your answer · Pricing tone", "서버 순서의 첫 이슈")
    }

    @Test func aSessionAwaitingAnAnswerCountsAsNeedingYou() {
        let items = [Self.item(1, "Lifetime plan", links: [Self.link(1, "A")])]
        let sessions = [Self.session(1, issue: 1, ring: .needsYou)]
        #expect(rows(items, contexts: [Self.project(1, "A")], sessions: sessions)[0].meta == "Needs your answer · Lifetime plan")
    }

    @Test func thenWhatAnAgentIsDoingWithTheAgentName() {
        let items = [
            Self.item(1, "Idle one", links: [Self.link(1, "A")], due: Self.today),
            Self.item(2, "Pricing copy", links: [Self.link(1, "A")]),
        ]
        for ring in [AgentSessionRing.running, .stopping, .unreachable] {
            let sessions = [Self.session(1, issue: 2, ring: ring), Self.session(2, issue: 1, ring: .idle)]
            #expect(rows(items, contexts: [Self.project(1, "A")], sessions: sessions)[0].meta == "Claude Code · Pricing copy", "\(ring)")
        }
        let codex = [Self.session(1, issue: 2, ring: .running, agent: .codex, name: "Codex")]
        #expect(rows(items, contexts: [Self.project(1, "A")], sessions: codex)[0].meta == "Codex · Pricing copy")
    }

    @Test func aDoneOrWaitingSessionIsNotWhatAnAgentIsDoing() {
        let items = [Self.item(1, "Plain", links: [Self.link(1, "A")])]
        for ring in [AgentSessionRing.done, .waiting, .idle] {
            let sessions = [Self.session(1, issue: 1, ring: ring)]
            #expect(rows(items, contexts: [Self.project(1, "A")], sessions: sessions)[0].meta == "Plain", "\(ring)")
        }
    }

    @Test func aV1RunWithoutASessionNamesNoAgent() {
        // v1 run(`Running`)에는 이름 붙은 에이전트가 없다: 그 줄은 건너뛰고 다음 단계로 간다
        let items = [Self.item(1, "Draft", links: [Self.link(1, "A")], activity: WorkActivity.running)]
        #expect(rows(items, contexts: [Self.project(1, "A")])[0].meta == "Draft")
    }

    @Test func thenWhatIsDueWithTheShortDate() {
        let friday = LocalDate(year: 2026, month: 10, day: 16)!
        let items = [
            Self.item(1, "No date", links: [Self.link(1, "A")]),
            Self.item(2, "Metrics section", links: [Self.link(1, "A")], due: friday),
        ]
        #expect(rows(items, contexts: [Self.project(1, "A")])[0].meta == "Due Tomorrow · Metrics section")
        let later = LocalDate(year: 2026, month: 10, day: 20)!
        #expect(rows([Self.item(1, "Later", links: [Self.link(1, "A")], due: later)], contexts: [Self.project(1, "A")])[0].meta == "Due Tue · Later")
        #expect(rows([Self.item(1, "Past", links: [Self.link(1, "A")], due: LocalDate(year: 2026, month: 10, day: 1)!)], contexts: [Self.project(1, "A")])[0].meta == "Due Oct 1 · Past")
    }

    @Test func thenWhatFinishedToday() {
        let items = [
            Self.item(1, "Lease signed", state: .done, links: [Self.link(1, "A")]),
            Self.item(2, "Older done", state: .done, links: [Self.link(1, "A")]),
            Self.item(3, "Plain open", links: [Self.link(1, "A")]),
        ]
        #expect(rows(items, contexts: [Self.project(1, "A")])[0].meta == "Done today · Lease signed", "가장 최근에 끝낸 것이 먼저 온다")
    }

    @Test func thenTheFirstOpenIssueThenNothing() {
        let items = [Self.item(1, "First", links: [Self.link(1, "A")]), Self.item(2, "Second", links: [Self.link(1, "A")])]
        #expect(rows(items, contexts: [Self.project(1, "A")])[0].meta == "First")
        #expect(rows([], contexts: [Self.project(1, "A")])[0].meta == "")
    }

    @Test func aDoneIssueNeverCountsAsNeedingAnAnswerOrRunning() {
        let items = [Self.item(1, "Finished", state: .done, links: [Self.link(1, "A")], activity: WorkActivity.needsAnswer)]
        let sessions = [Self.session(1, issue: 1, ring: .running)]
        #expect(rows(items, contexts: [Self.project(1, "A")], sessions: sessions)[0].meta == "Done today · Finished")
    }

    @Test func ungroupedFollowsTheSameRulesAndDoneTodayShowsTheLatestFinishedTitle() {
        let items = [
            Self.item(1, "Send the proposal", links: []),
            Self.item(2, "Privacy policy beta", state: .done, links: [Self.link(1, "A")]),
            Self.item(3, "Older", state: .done, links: []),
        ]
        let result = rows(items, contexts: [Self.project(1, "A")])
        #expect(result.map(\.name) == ["A", "Ungrouped", "Done today"])
        #expect(result[1].meta == "Done today · Older", "Ungrouped도 같은 단계: 끝낸 것이 첫 열린 이슈보다 먼저다")
        #expect(result[2].meta == "Privacy policy beta", "Done today 행은 가장 최근에 끝낸 이슈 제목만")
    }

    @Test func accessibilityNameIsNameDashMeta() {
        let items = [Self.item(1, "Pricing tone", links: [Self.link(1, "Shape launch")], activity: WorkActivity.needsAnswer)]
        #expect(rows(items, contexts: [Self.project(1, "Shape launch")])[0].accessibilityName == "Shape launch — Needs your answer · Pricing tone")
    }

    @Test func noRowShowsACount() {
        let items = (1...7).map { Self.item($0, "Issue \($0)", links: [Self.link(1, "A")]) }
        for row in rows(items, contexts: [Self.project(1, "A")]) {
            #expect(!row.meta.contains("7") && !row.accessibilityName.contains("7"))
        }
    }
}
