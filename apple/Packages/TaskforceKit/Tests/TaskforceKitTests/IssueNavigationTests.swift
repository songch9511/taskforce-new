import Foundation
import Testing
@testable import TaskforceKit

/// Issues 패널의 화면 이동 (U2-01 · 24): Projects → 프로젝트 · Ungrouped · Done today 목록 → 이슈 상세. 뒤로는 연 목록으로, 목록 밖에서 열었으면 첫 프로젝트(이름순) 목록 또는 Ungrouped
struct IssueNavigationTests {
    typealias Fx = SessionFx
    typealias P = ProjectRowsTests

    let projectA = Fx.id(1, prefix: "c0000000")
    let projectB = Fx.id(2, prefix: "c0000000")

    @Test func itStartsAtProjectsWithNoBack() {
        let nav = IssueNavigation()
        #expect(nav.current == .projects && !nav.canGoBack && nav.stack == [.projects])
    }

    @Test func projectsToListToDetailAndBackOneStepAtATime() {
        var nav = IssueNavigation()
        nav.open(.project(projectA))
        #expect(nav.current == .list(.project(projectA)) && nav.canGoBack)
        nav.openDetail(Fx.issue(1))
        #expect(nav.current == .detail(Fx.issue(1)) && nav.detailID == Fx.issue(1))
        nav.back()
        #expect(nav.current == .list(.project(projectA)) && nav.detailID == nil)
        nav.back()
        #expect(nav.current == .projects)
        nav.back()
        #expect(nav.current == .projects, "맨 앞에서는 더 못 간다")
    }

    @Test func openingADetailFromAnotherDetailReplacesItInTheSameList() {
        var nav = IssueNavigation()
        nav.open(.ungrouped)
        nav.openDetail(Fx.issue(1))
        nav.openDetail(Fx.issue(2))
        #expect(nav.stack == [.projects, .list(.ungrouped), .detail(Fx.issue(2))])
    }

    @Test func openingFromOutsideRebuildsTheStackThroughTheFallbackList() {
        var nav = IssueNavigation()
        nav.open(.project(projectB))
        nav.openDetail(Fx.issue(1))
        nav.openDetail(Fx.issue(9), outside: .project(projectA))
        #expect(nav.stack == [.projects, .list(.project(projectA)), .detail(Fx.issue(9))])
        nav.back()
        #expect(nav.current == .list(.project(projectA)), "뒤로는 첫 프로젝트 목록")
        var fresh = IssueNavigation()
        fresh.openDetail(Fx.issue(3), outside: .ungrouped)
        #expect(fresh.stack == [.projects, .list(.ungrouped), .detail(Fx.issue(3))])
    }

    @Test func resetGoesBackToProjectsAndClearsTheStack() {
        var nav = IssueNavigation()
        nav.open(.project(projectA))
        nav.openDetail(Fx.issue(1))
        nav.reset()
        #expect(nav.stack == [.projects])
    }

    @Test func openingAListFromProjectsClearsWhateverWasDeeper() {
        var nav = IssueNavigation()
        nav.open(.project(projectA))
        nav.openDetail(Fx.issue(1))
        nav.open(.doneToday)
        #expect(nav.stack == [.projects, .list(.doneToday)])
    }

    // MARK: 경계가 사라질 때

    @Test func aDetailWhoseIssueIsGoneFallsBackToItsList() {
        var nav = IssueNavigation()
        nav.open(.project(projectA))
        nav.openDetail(Fx.issue(1))
        nav.reconcile(listExists: { _ in true }, issueExists: { _ in false })
        #expect(nav.stack == [.projects, .list(.project(projectA))])
    }

    @Test func aListWhoseProjectIsGoneFallsBackToProjects() {
        var nav = IssueNavigation()
        nav.open(.project(projectA))
        nav.reconcile(listExists: { _ in false }, issueExists: { _ in true })
        #expect(nav.stack == [.projects])
    }

    @Test func aGoneListUnderALiveDetailIsDroppedButTheDetailStays() {
        var nav = IssueNavigation()
        nav.open(.project(projectA))
        nav.openDetail(Fx.issue(1))
        nav.reconcile(listExists: { _ in false }, issueExists: { _ in true })
        #expect(nav.stack == [.projects, .detail(Fx.issue(1))])
        nav.back()
        #expect(nav.current == .projects)
    }

    @Test func nothingChangesWhenEverythingStillExists() {
        var nav = IssueNavigation()
        nav.open(.project(projectA))
        nav.openDetail(Fx.issue(1))
        let before = nav
        nav.reconcile(listExists: { _ in true }, issueExists: { _ in true })
        #expect(nav == before)
    }

    // MARK: 목록 밖에서 열 때의 목록

    @Test func theFallbackListIsTheFirstProjectByNameOrUngrouped() {
        let apple = P.link(5, "apple"), zebra = P.link(6, "Zebra"), old = P.link(7, "Aardvark", archived: true)
        #expect(IssueNavigation.fallbackScope(for: P.item(1, "T", links: [zebra, apple])) == .project(apple.project.id), "이름순 첫 프로젝트(대소문자 무시)")
        #expect(IssueNavigation.fallbackScope(for: P.item(1, "T", links: [])) == .ungrouped)
        #expect(IssueNavigation.fallbackScope(for: P.item(1, "T", links: [old])) == .ungrouped, "보관한 프로젝트는 목록이 없다")
        #expect(IssueNavigation.fallbackScope(for: P.item(1, "T", links: [old, zebra])) == .project(zebra.project.id))
        #expect(IssueNavigation.fallbackScope(for: P.item(1, "T", known: false)) == .ungrouped)
    }

    @Test func theScopeOfTheSessionTabIsTheOpenListOrTheOpenIssue() {
        var nav = IssueNavigation()
        #expect(nav.tabScope == nil, "Projects에는 탭이 없다")
        nav.open(.doneToday)
        #expect(nav.tabScope == nil, "Done today에는 탭이 없다")
        nav.open(.ungrouped)
        #expect(nav.tabScope == .list(.ungrouped))
        nav.openDetail(Fx.issue(1))
        #expect(nav.tabScope == .detail(Fx.issue(1)))
    }
}
