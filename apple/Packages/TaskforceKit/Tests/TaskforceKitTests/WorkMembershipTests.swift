import Foundation
import Testing
@testable import TaskforceKit

/// S3b: WorkList 묶음 · Project 칩 · 검색이 실제 범위 멤버십을 따른다 (확인된 멤버 / 여러 범위 / 없음 / inferred 후보 / 보관됨 / 아직 모름)
struct WorkMembershipTests {
    static let shape = ContextFx.context(1, "Shape launch")
    static let acme = ContextFx.context(2, "Acme website")
    static let old = ContextFx.context(3, "Old project", archived: true)

    static func id(_ n: Int) -> UUID { WorkListTests.id(n) }

    func memberships(_ contexts: [WorkContext], _ members: [ContextMember], of n: Int) -> WorkMemberships {
        WorkMembershipIndex(contexts: contexts, members: members).memberships(of: Self.id(n))
    }

    func items(_ contexts: [WorkContext], _ members: [ContextMember], count: Int = 6, done: [Int] = []) -> [WorkItem] {
        let index = WorkMembershipIndex(contexts: contexts, members: members)
        return WorkItem.list(
            reviews: [], open: (1...count).filter { !done.contains($0) }.map { WorkListTests.action($0) },
            doneToday: done.map { WorkListTests.action($0, status: .done) }, memberships: index
        )
    }

    func ids(_ groups: [WorkListGroup]) -> [[Int]] {
        groups.map { $0.items.map { item in (1...99).first { Self.id($0) == item.id } ?? -1 } }
    }

    // MARK: 색인

    @Test func confirmedMembersAreGroupedByTheirRealOrigin() {
        let members = [
            ContextFx.member(1, ctx: Self.shape.id, action: Self.id(1), origin: .user),
            ContextFx.member(2, ctx: Self.acme.id, action: Self.id(2), origin: .auto),
        ]
        let one = memberships([Self.shape, Self.acme], members, of: 1)
        #expect(one.links.map(\.project.name) == ["Shape launch"] && one.links.map(\.origin) == [.user])
        let two = memberships([Self.shape, Self.acme], members, of: 2)
        #expect(two.links.map(\.origin) == [.auto])
        #expect(two.candidates.isEmpty)
    }

    /// 한 할 일이 여러 범위의 확인된 멤버면 둘 다 보인다 (하나로 지어내지 않는다)
    @Test func oneActionInTwoContextsKeepsBoth() {
        let members = [
            ContextFx.member(1, ctx: Self.shape.id, action: Self.id(1), origin: .user),
            ContextFx.member(2, ctx: Self.acme.id, action: Self.id(1), origin: .auto),
        ]
        let found = memberships([Self.shape, Self.acme], members, of: 1)
        #expect(found.links.map(\.project.name) == ["Acme website", "Shape launch"])
        #expect(found.links.map(\.origin) == [.auto, .user])
    }

    @Test func noMembershipMeansUngroupedOnlyOnceRead() {
        #expect(memberships([Self.shape], [], of: 1) == .none)
        #expect(memberships([Self.shape], [], of: 1).isUngrouped)
        #expect(WorkMembershipIndex.unknown.memberships(of: Self.id(1)) == .unknown)
        #expect(!WorkMembershipIndex.unknown.memberships(of: Self.id(1)).isUngrouped)
        #expect(WorkMembershipIndex.empty.memberships(of: Self.id(1)) == .none)
    }

    /// inferred 후보는 확인된 멤버로 묶지 않는다. 후보로만 보인다
    @Test func inferredIsACandidateNeverAConfirmedMember() {
        let members = [ContextFx.member(1, ctx: Self.shape.id, action: Self.id(1), origin: .inferred, confidence: 0.62)]
        let found = memberships([Self.shape], members, of: 1)
        #expect(found.links.isEmpty && found.isUngrouped)
        #expect(found.candidates.map(\.project.name) == ["Shape launch"] && found.candidates.first?.confidence == 0.62)
        // 모르는 origin도 확인된 멤버가 아니다
        let unknown = [ContextFx.member(2, ctx: Self.shape.id, action: Self.id(2), origin: .other("telepathy"))]
        #expect(memberships([Self.shape], unknown, of: 2).links.isEmpty)
    }

    /// 사용자가 뺀 행 · 읽을 수 없는 범위의 행 · 할 일이 아닌 멤버는 묶지 않는다
    @Test func removedUnreadableAndNonActionRowsAreIgnored() {
        let members = [
            ContextFx.member(1, ctx: Self.shape.id, action: Self.id(1), origin: .user, removed: true),
            ContextFx.member(2, ctx: ContextFx.id(77, prefix: "c0000000"), action: Self.id(2), origin: .user),
            ContextFx.member(3, ctx: Self.shape.id, action: nil, origin: .user),
        ]
        #expect(memberships([Self.shape], members, of: 1) == .none)
        #expect(memberships([Self.shape], members, of: 2) == .none)
    }

    @Test func archivedContextsKeepConfirmedMembersButShowNoCandidates() {
        let members = [
            ContextFx.member(1, ctx: Self.old.id, action: Self.id(1), origin: .user),
            ContextFx.member(2, ctx: Self.old.id, action: Self.id(2), origin: .inferred, confidence: 0.5),
        ]
        let archived = memberships([Self.old], members, of: 1)
        #expect(archived.links.map(\.project.isArchived) == [true])
        #expect(memberships([Self.old], members, of: 2).candidates.isEmpty)
    }

    // MARK: 묶음

    @Test func listGroupsFollowRealMembershipsAndOneActionCanBeInTwoGroups() {
        let members = [
            ContextFx.member(1, ctx: Self.shape.id, action: Self.id(1), origin: .user),
            ContextFx.member(2, ctx: Self.shape.id, action: Self.id(2), origin: .auto),
            ContextFx.member(3, ctx: Self.acme.id, action: Self.id(2), origin: .user),
            ContextFx.member(4, ctx: Self.acme.id, action: Self.id(3), origin: .user),
        ]
        let list = items([Self.shape, Self.acme], members)
        let groups = WorkListLayout.groups(list, filter: WorkFilter(), pinned: [])
        // 처음 나온 차례: 1번 할 일이 Shape, 2번 할 일의 Acme가 그다음. 2번 할 일은 두 묶음에 모두 나온다
        #expect(groups.map(\.title) == ["Shape launch", "Acme website", "Ungrouped"])
        #expect(ids(groups) == [[1, 2], [2, 3], [4, 5, 6]])
    }

    @Test func groupHeadersCarryNoCounts() {
        let members = [ContextFx.member(1, ctx: Self.shape.id, action: Self.id(1), origin: .user)]
        for group in WorkListLayout.groups(items([Self.shape], members), filter: WorkFilter(), pinned: []) {
            #expect(group.title.rangeOfCharacter(from: .decimalDigits) == nil)
        }
    }

    @Test func candidatesStayUngrouped() {
        let members = [ContextFx.member(1, ctx: Self.shape.id, action: Self.id(1), origin: .inferred, confidence: 0.7)]
        let groups = WorkListLayout.groups(items([Self.shape], members, count: 2), filter: WorkFilter(), pinned: [])
        #expect(groups.map(\.title) == ["Ungrouped"] && ids(groups) == [[1, 2]])
        // 후보의 범위는 Project 칩도 만들지 않는다
        #expect(WorkListLayout.projectOptions(items([Self.shape], members, count: 2)) == [.all, .ungrouped])
    }

    /// 아직 읽지 못한 멤버십: 어느 프로젝트에도 Ungrouped에도 넣지 않는다 (이름 없는 한 묶음), 칩은 All뿐
    @Test func unreadMembershipsClaimNoGroupAndNoChips() {
        let list = (1...3).map { WorkListTests.item($0, memberships: .unknown) }
        let groups = WorkListLayout.groups(list, filter: WorkFilter(), pinned: [])
        #expect(groups.map(\.id) == ["unsorted"] && groups.first?.title == "" && ids(groups) == [[1, 2, 3]])
        #expect(WorkListLayout.projectOptions(list) == [.all])
        // 프로젝트 / Ungrouped 필터는 아무것도 고르지 않는다 (모르는 것을 속한다고 하지 않는다)
        #expect(WorkListLayout.groups(list, filter: WorkFilter(project: .ungrouped), pinned: []).isEmpty)
        #expect(WorkListLayout.groups(list, filter: WorkFilter(project: .project(WorkListTests.project("Shape launch"))), pinned: []).isEmpty)
    }

    @Test func archivedProjectsComeAfterUngroupedAndAreLabelled() {
        let members = [
            ContextFx.member(1, ctx: Self.old.id, action: Self.id(1), origin: .user),
            ContextFx.member(2, ctx: Self.shape.id, action: Self.id(2), origin: .user),
        ]
        let list = items([Self.shape, Self.old], members, count: 3, done: [3])
        let groups = WorkListLayout.groups(list, filter: WorkFilter(), pinned: [])
        #expect(groups.map(\.title) == ["Shape launch", "Old project · Archived", "Done today"])
        #expect(ids(groups) == [[2], [1], [3]])
        #expect(WorkListLayout.projectOptions(list).map(\.title) == ["All", "Old project · Archived", "Shape launch", "Ungrouped"])
    }

    @Test func projectFilterShowsTheActionOnlyInThatGroup() {
        let members = [
            ContextFx.member(1, ctx: Self.shape.id, action: Self.id(1), origin: .user),
            ContextFx.member(2, ctx: Self.acme.id, action: Self.id(1), origin: .user),
        ]
        let list = items([Self.shape, Self.acme], members, count: 2)
        let groups = WorkListLayout.groups(list, filter: WorkFilter(project: .project(WorkProject(id: Self.acme.id, name: "Acme website"))), pinned: [])
        #expect(groups.map(\.title) == ["Acme website"] && ids(groups) == [[1]])
    }

    /// 이름이 같은 두 범위는 다른 범위다 (이름으로 합치지 않는다)
    @Test func sameNameDifferentContextsStaySeparate() {
        let a = ContextFx.context(10, "Launch")
        let b = ContextFx.context(11, "Launch")
        let members = [
            ContextFx.member(1, ctx: a.id, action: Self.id(1), origin: .user),
            ContextFx.member(2, ctx: b.id, action: Self.id(2), origin: .user),
            ContextFx.member(3, ctx: b.id, action: Self.id(3), origin: .user),
        ]
        let list = items([a, b], members, count: 3, done: [3])
        let groups = WorkListLayout.groups(list, filter: WorkFilter(), pinned: [])
        #expect(groups.count == 3 && ids(groups).sorted { $0[0] < $1[0] } == [[1], [2], [3]])
        // 같은 이름의 다른 범위(a)를 고르면 b의 열린 일 · 끝낸 일이 섞이지 않는다
        let only = WorkListLayout.groups(list, filter: WorkFilter(project: WorkListLayout.projectOptions(list)[1]), pinned: [])
        #expect(only.count == 1 && ids(only) == [[1]])
        #expect(WorkListLayout.projectOptions(list)[1].matches(list[0]) && !WorkListLayout.projectOptions(list)[1].matches(list[2]))
    }

    // MARK: 검색

    @Test func searchCoversRealProjectNamesButNotCandidates() {
        let members = [
            ContextFx.member(1, ctx: Self.shape.id, action: Self.id(1), origin: .user),
            ContextFx.member(2, ctx: Self.acme.id, action: Self.id(1), origin: .auto),
            ContextFx.member(3, ctx: Self.acme.id, action: Self.id(2), origin: .inferred, confidence: 0.4),
            ContextFx.member(4, ctx: Self.old.id, action: Self.id(3), origin: .user),
        ]
        let list = items([Self.shape, Self.acme, Self.old], members, count: 4)
        func found(_ query: String) -> Set<Int> {
            Set(WorkListLayout.groups(list, filter: WorkFilter(query: query), pinned: []).flatMap { ids([$0]).flatMap { $0 } })
        }
        // 확인된 멤버십의 범위 이름 (여러 범위면 어느 이름이든)
        #expect(found("shape") == [1] && found("acme") == [1])
        // 후보(2번 할 일의 Acme)의 이름은 이 할 일의 프로젝트가 아니다. 보관된 범위 이름도 검색된다
        #expect(found("old project") == [3])
        // Ungrouped는 확인된 멤버십이 없는 할 일 (후보만 있어도)
        #expect(found("ungrouped") == [2, 4])
    }

    @Test func searchDoesNotSayUngroupedWhileMembershipsAreUnknown() {
        let list = [WorkListTests.item(1, memberships: .unknown)]
        #expect(WorkListLayout.groups(list, filter: WorkFilter(query: "ungrouped"), pinned: []).isEmpty)
        #expect(WorkListLayout.groups(list, filter: WorkFilter(query: "work"), pinned: []).count == 1)
    }

    /// Project 칩은 실제 범위다 (견본 이름 목록이 아니다)
    @Test func projectChipsAreTheRealContexts() {
        let members = [ContextFx.member(1, ctx: Self.shape.id, action: Self.id(1), origin: .user)]
        let list = items([Self.shape, Self.acme], members, count: 2)
        #expect(WorkListLayout.projectOptions(list).map(\.title) == ["All", "Shape launch", "Ungrouped"], "멤버가 없는 범위 Acme는 칩이 되지 않는다")
    }

    /// 멤버십은 줄의 상태 · 활동 · 수행자 · 순서를 바꾸지 않는다 (D13: 범위는 권한이 아니다)
    @Test func membershipsNeverChangeTheRowsOwnFields() {
        let open = (1...4).map { WorkListTests.action($0, started: $0 == 2) }
        let members = [
            ContextFx.member(1, ctx: Self.shape.id, action: Self.id(2), origin: .user),
            ContextFx.member(2, ctx: Self.acme.id, action: Self.id(3), origin: .auto),
        ]
        let plain = WorkItem.list(reviews: [], open: open, doneToday: [], working: [Self.id(2)])
        let grouped = WorkItem.list(
            reviews: [], open: open, doneToday: [], working: [Self.id(2)],
            memberships: WorkMembershipIndex(contexts: [Self.shape, Self.acme], members: members)
        )
        #expect(plain.map(\.id) == grouped.map(\.id))
        #expect(plain.map(\.state) == grouped.map(\.state) && plain.map(\.activity) == grouped.map(\.activity))
        #expect(plain.map(\.performer) == grouped.map(\.performer) && plain.map(\.reasons) == grouped.map(\.reasons))
        #expect(plain.map(\.action) == grouped.map(\.action))
    }
}
