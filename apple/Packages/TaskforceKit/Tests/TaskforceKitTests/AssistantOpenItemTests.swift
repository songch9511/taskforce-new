import Foundation
import Testing
@testable import TaskforceKit

/// 패널에 열린 항목 → Assistant 창의 auto 칩 (U2-45): 가장 안쪽에 열린 것. 세션 패널 → 그 세션, 이슈 상세 → 그 이슈(번호 앞), 프로젝트 목록 → 그 프로젝트,
/// Ungrouped · Done today · Projects → 없음. 칩 종류는 서버 `attachmentKindSchema`(action · context · agent_session)다
struct AssistantOpenItemTests {
    typealias Fx = SessionFx
    typealias P = ProjectRowsTests

    private let project = P.project(1, "Taskforce 0.2.0")

    private func item(
        _ screen: IssueScreen, session: AgentSessionItem? = nil, numbers: [UUID: Int] = [:]
    ) -> AssistantOpenItem? {
        IssueOpenItemRules.openItem(
            screen: screen, session: session, items: [P.item(1, "Rewrite pricing page copy", links: [P.link(1, "Taskforce 0.2.0")])],
            contexts: [project], number: { numbers[$0] }
        )
    }

    @Test func anIssueDetailIsTheIssueChipWithItsNumberFirst() throws {
        let open = try #require(item(.detail(Fx.issue(1)), numbers: [Fx.issue(1): 139]))
        #expect(open.kind == .action && open.id == Fx.issue(1) && open.title == "Rewrite pricing page copy" && open.number == 139)
        let chip = AssistantChip(open: open)
        #expect(chip.origin == .auto && chip.kind == .action && chip.label == "#139 Rewrite pricing page copy")
        // 번호를 아직 못 읽었으면 이름만 (지어내지 않는다)
        #expect(try #require(item(.detail(Fx.issue(1)))).number == nil)
        #expect(AssistantChip(open: try #require(item(.detail(Fx.issue(1))))).label == "Rewrite pricing page copy")
    }

    @Test func aProjectListIsTheProjectChip() throws {
        let open = try #require(item(.list(.project(project.id))))
        #expect(open.kind == .context && open.id == project.id && open.title == "Taskforce 0.2.0" && open.number == nil)
        #expect(AssistantChip(open: open).attachment.kind == .context)
    }

    @Test func ungroupedDoneTodayAndProjectsHaveNoChip() {
        #expect(item(.list(.ungrouped)) == nil)
        #expect(item(.list(.doneToday)) == nil)
        #expect(item(.projects) == nil)
    }

    @Test func aMissingProjectOrIssueHasNoChip() {
        #expect(item(.list(.project(Fx.id(9, prefix: "c0000000")))) == nil)
        #expect(item(.detail(Fx.issue(9))) == nil)
        // 보관한 프로젝트의 목록은 열리지 않는다: 칩도 없다
        let archived = P.project(2, "Old", archived: true)
        let open = IssueOpenItemRules.openItem(screen: .list(.project(archived.id)), session: nil, items: [], contexts: [archived], number: { _ in nil })
        #expect(open == nil)
    }

    @Test func theSessionPanelOutranksTheIssueUnderIt() throws {
        let session = ProjectRowsTests.session(1, issue: 1, ring: .running)
        let open = try #require(item(.detail(Fx.issue(1)), session: session))
        #expect(open.kind == .agentSession && open.id == session.id && open.title == "S1" && open.number == nil)
        #expect(AssistantChip(open: open).attachment.kind == .agentSession)
    }
}
