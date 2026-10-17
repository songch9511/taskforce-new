import Foundation
import Testing
@testable import TaskforceKit

/// OA U3: 글자와 이름. Taskforce 대화의 confirm 메타는 프로젝트 이름만 말하고(U3-25), Release S4 · 타일의 글은 그대로다(U3-01).
struct ReviewCopyTaskforceTests {
    private static let shape = WorkProject(id: UUID(uuidString: "00000000-0000-4000-8000-00000000000a")!, name: "Shape launch")
    private static let acme = WorkProject(id: UUID(uuidString: "00000000-0000-4000-8000-00000000000b")!, name: "Acme website")
    private static let old = WorkProject(id: UUID(uuidString: "00000000-0000-4000-8000-00000000000c")!, name: "Old launch", isArchived: true)

    @Test func theTaskforceMetaNamesConfirmedProjectsOnlyAndNeverSaysNeedsYourAnswer() {
        #expect(TaskforceCopy.confirmMeta(memberships: .unknown) == "" && TaskforceCopy.confirmMeta(memberships: .none) == "", "이름이 없으면 메타 줄이 없다")
        #expect(TaskforceCopy.confirmMeta(memberships: .known(links: [WorkLink(project: Self.shape, origin: .user)], candidates: [])) == "Shape launch")
        #expect(TaskforceCopy.confirmMeta(memberships: .known(links: [], candidates: [WorkCandidate(project: Self.shape, confidence: 0.9)])) == "", "후보는 이름을 붙이지 않는다")
        let two = TaskforceCopy.confirmMeta(memberships: .known(links: [WorkLink(project: Self.acme, origin: .auto), WorkLink(project: Self.old, origin: .user)], candidates: []))
        #expect(two == "Acme website, Old launch · Archived")
        #expect(!two.contains("Needs your answer"))
    }

    @Test func theReleaseReviewMetaAndTileWordsAreUnchanged() {
        let known = WorkMemberships.known(links: [WorkLink(project: Self.shape, origin: .user)], candidates: [])
        #expect(ReviewCopy.meta(memberships: known) == "Needs your answer · Shape launch")
        #expect(ReviewCopy.meta(memberships: .none) == "Needs your answer")
        #expect(ReviewTileRules.tooltip(.needsYou(count: 1)) == "Review · Needs your answer", "Release 레일 타일은 지금 그대로다")
        #expect(ReviewTileRules.accessibilityName(.needsYou(count: 2)) == "Review · Needs your answer, 2 items")
    }

    @Test func theNextRowIsTheFirstOpenIssueOfNow() {
        let a = ProjectRowsTests.item(1, "Done earlier", state: .done)
        let b = ProjectRowsTests.item(2, "Wire EdgeRail rings", state: .inProgress, activity: "Running")
        let c = ProjectRowsTests.item(3, "Ask Mina", state: .toDo)
        let today = ProjectRowsTests.today
        let row = IssueListRules.nextRow(items: [a, b, c], sessions: [], today: today)
        #expect(row?.title == "Wire EdgeRail rings" && row?.id == b.id && row?.state == .inProgress)
        #expect(IssueListRules.nextRow(items: [a], sessions: [], today: today) == nil, "끝난 일뿐이면 Next가 없다 (Projects 버튼)")
        #expect(IssueListRules.nextRow(items: [], sessions: [], today: today) == nil)
        #expect(IssueListRules.nextRow(items: [a, c, b], sessions: [], today: today)?.id == c.id, "순서는 받은 그대로")
    }
}
