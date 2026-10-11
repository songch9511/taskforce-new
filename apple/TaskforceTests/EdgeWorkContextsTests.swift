import Foundation
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// S3b 셸: All work의 묶음 · Project 칩 · 검색이 실제 범위 멤버십(가짜 서버 `SampleContextGateway`가 서버 규칙을 따른다)을 따른다.
/// 읽기 전 · 오프라인 · 읽기 실패에서는 Ungrouped라고 말하지 않고, 멤버십 변경은 줄 · 레일 · 실행 상태를 바꾸지 않으며, 계정이 떠나면 비운다
@MainActor
struct EdgeWorkContextsTests {
    static func action(_ n: Int) -> ActionSummary {
        ActionSummary(
            id: SampleData.id(n), title: "Work \(n)", owner: .me, status: .open, dueDate: nil, counterpart: nil, needsConfirmation: false,
            confirmReasons: [], startedAt: n == 11 ? Date(timeIntervalSinceReferenceDate: 0) : nil, lastActivityAt: Date(timeIntervalSinceReferenceDate: 0)
        )
    }

    /// 견본 멤버십: 10 Shape(user) · 11 Shape(auto) · 12 Shape(user)+Acme(auto) · 13 Acme(user) · 14 Shape(inferred 후보) · 20 Old(보관, user) · 21 없음
    static let numbers = [10, 11, 12, 13, 14, 20, 21]

    func make(_ scenario: SampleContextGateway.Scenario = .full) -> (shell: EdgeShellModel, store: WorkContextStore, gateway: SampleContextGateway, scope: AccountScope) {
        let scope = AccountScope(currentAccount: { SampleData.userID })
        let gateway = SampleContextGateway(scenario: scenario)
        let store = WorkContextStore(gateway: gateway, scope: scope)
        let shell = EdgeShellModel(schedule: { _, _ in EdgeTimer() }, clock: { Date() }, contexts: store)
        shell.update(EdgeWorkSnapshot(open: Self.numbers.map(Self.action), load: .loaded(problem: nil)))
        return (shell, store, gateway, scope)
    }

    func groups(_ shell: EdgeShellModel, filter: WorkFilter = WorkFilter()) -> [WorkListGroup] {
        WorkListLayout.groups(shell.workItems, filter: filter, pinned: [])
    }

    func numbers(_ group: WorkListGroup) -> [Int] {
        group.items.compactMap { item in Self.numbers.first { SampleData.id($0) == item.id } }
    }

    @Test func groupsFollowTheRealMembershipsOnceRead() async {
        let (shell, store, _, _) = make()
        // 읽기 전: 어느 프로젝트에도 Ungrouped에도 넣지 않는다
        #expect(groups(shell).map(\.id) == ["unsorted"] && WorkListLayout.projectOptions(shell.workItems) == [.all])
        await store.refresh()
        let found = groups(shell)
        #expect(found.map(\.title) == ["Shape launch", "Acme website", "Ungrouped", "Old project · Archived"])
        #expect(found.map(numbers) == [[10, 11, 12], [12, 13], [14, 21], [20]], "12는 두 프로젝트의 확인된 멤버라 두 묶음에, 후보 14는 Ungrouped에")
        #expect(WorkListLayout.projectOptions(shell.workItems).map(\.title) == ["All", "Shape launch", "Acme website", "Old project · Archived", "Ungrouped"])
        #expect(shell.projectsProblem == nil)
    }

    @Test func searchAndProjectChipsUseTheRealProjects() async {
        let (shell, store, _, _) = make()
        await store.refresh()
        #expect(groups(shell, filter: WorkFilter(query: "acme")).flatMap(numbers).sorted() == [12, 12, 13], "12는 Shape 묶음에도 나온다")
        #expect(groups(shell, filter: WorkFilter(query: "old project")).flatMap(numbers) == [20])
        // 후보(14)의 프로젝트 이름으로는 찾아지지 않는다
        #expect(!groups(shell, filter: WorkFilter(query: "work 14")).isEmpty)
        let shape = WorkListLayout.projectOptions(shell.workItems)[1]
        #expect(groups(shell, filter: WorkFilter(project: shape)).map(numbers) == [[10, 11, 12]])
        #expect(groups(shell, filter: WorkFilter(project: .ungrouped)).flatMap(numbers) == [14, 21])
    }

    /// 읽지 못했으면 Ungrouped라고 하지 않고 위 Notice가 말한다 (오프라인 / 읽기 실패)
    @Test func unreadMembershipsAreNeverCalledUngrouped() async {
        let (shell, store, _, _) = make(.offline)
        await store.refresh()
        #expect(groups(shell).map(\.id) == ["unsorted"] && shell.projectsProblem == .offline)
        let (failedShell, failedStore, _, _) = make(.failed)
        await failedStore.refresh()
        #expect(groups(failedShell).map(\.id) == ["unsorted"] && failedShell.projectsProblem == .failed)
        #expect(WorkListLayout.groups(failedShell.workItems, filter: WorkFilter(project: .ungrouped), pinned: []).isEmpty)
    }

    /// 서버에 범위 테이블이 아직 없다: 멤버십이 없는 것이다 (실패 Notice 없음)
    @Test func missingTablesMeanEverythingIsUngroupedWithoutAnError() async {
        let (shell, store, _, _) = make(.unavailable)
        await store.refresh()
        #expect(groups(shell).map(\.title) == ["Ungrouped"] && shell.projectsProblem == nil)
    }

    @Test func aMembershipChangeNeverTouchesTheRowsOrTheRail() async {
        let (shell, store, _, _) = make()
        await store.refresh()
        let before = (work: shell.work, slots: shell.slots, items: shell.workItems)
        let result = await store.move(SampleData.id(10), from: SampleContextIDs.shape, to: SampleContextIDs.acme)
        #expect(result == .applied(canUndo: true))
        #expect(shell.work == before.work && shell.slots == before.slots, "실행 · run · 레일 상태가 그대로")
        let after = shell.workItems
        #expect(after.map(\.id) == before.items.map(\.id))
        #expect(after.map(\.state) == before.items.map(\.state) && after.map(\.activity) == before.items.map(\.activity))
        #expect(after.map(\.performer) == before.items.map(\.performer) && after.map(\.action) == before.items.map(\.action))
        #expect(after.first { $0.id == SampleData.id(10) }?.memberships.links.map(\.project.name) == ["Acme website"])
    }

    /// 계정이 떠나면(화면 없이도) 멤버십을 비운다: 새 세션은 다시 읽기 전까지 아무 주장도 하지 않는다
    @Test func leavingTheAccountClearsMembershipsEvenWithoutAScreen() async {
        let (shell, store, _, scope) = make()
        await store.refresh()
        await store.move(SampleData.id(10), from: SampleContextIDs.shape, to: SampleContextIDs.acme)
        #expect(store.canUndo(SampleData.id(10)))
        scope.accountLeft()
        #expect(groups(shell).map(\.id) == ["unsorted"] && !store.canUndo(SampleData.id(10)) && !store.hasRead)
        #expect(await store.undoLast(SampleData.id(10)) == .ignored)
    }

    @Test func withoutAContextStoreEverythingStaysUngroupedLikeS3() {
        let shell = EdgeShellModel(schedule: { _, _ in EdgeTimer() }, clock: { Date() })
        shell.update(EdgeWorkSnapshot(open: Self.numbers.map(Self.action), load: .loaded(problem: nil)))
        #expect(groups(shell).map(\.title) == ["Ungrouped"] && shell.projectsProblem == nil)
    }

    @Test func theRuntimeBindsTheMembershipStoreToTheAccountScope() async {
        let runtime = ChatRuntime(gateway: SampleChatGateway(), contextGateway: SampleContextGateway(), scope: AccountScope(currentAccount: { SampleData.userID }))
        let store = try! #require(runtime.contexts)
        await store.refresh()
        #expect(store.hasRead)
        runtime.scope.accountLeft()
        #expect(!store.hasRead)
        #expect(ChatRuntime(gateway: SampleChatGateway()).contexts == nil)
    }

    /// 디자인 상태: 후보 / 없음 / 보관 / 여러 프로젝트 줄을 실제 데이터로 만든다 (ProjectLink origin 매핑이 서버 값 그대로)
    @Test func projectLinksCarryTheRealOrigins() async {
        let (_, store, _, _) = make()
        await store.refresh()
        func basis(_ n: Int) -> [ProjectLinkBasis] { store.projectLinks(for: SampleData.id(n))?.map(\.basis) ?? [] }
        #expect(basis(10) == [.user] && basis(11) == [.auto])
        #expect(basis(12) == [.auto, .user], "Acme(auto) · Shape(user) 이름 순, 하나로 합치지 않는다")
        #expect(basis(14) == [.none, .candidate] && basis(21) == [.none])
        #expect(store.projectLinks(for: SampleData.id(20))?.first?.isArchived == true)
    }
}
