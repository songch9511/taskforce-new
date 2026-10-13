import Foundation
import Testing
@testable import TaskforceKit

/// ProjectLink 줄: origin → 기준 문구 매핑 (Set by you · Auto-linked · 확인되지 않은 후보 · No clear link), 이유는 서버 데이터(origin)에 있는 만큼만,
/// 팝업 선택지 · Undo/안내 자리. origin을 표시 문자열 · 이름 일치로 짐작하지 않는다
struct ProjectLinkRulesTests {
    let shape = WorkProject(id: ContextFx.id(1), name: "Shape launch")
    let acme = WorkProject(id: ContextFx.id(2), name: "Acme website")
    let old = WorkProject(id: ContextFx.id(3), name: "Old project", isArchived: true)

    func links(
        _ memberships: WorkMemberships, active: [WorkProject]? = nil, writesUnavailable: Bool = false, isBusy: Bool = false,
        undo: ProjectLinkRules.UndoAnchor? = nil, message: String? = nil
    ) -> [ProjectLinkContent] {
        ProjectLinkRules.links(
            memberships: memberships, active: active ?? [acme, shape], writesUnavailable: writesUnavailable, isBusy: isBusy, undo: undo, message: message
        ) ?? []
    }

    // MARK: origin 매핑

    @Test func originMapsToTheBasisLabels() {
        #expect(ProjectLinkBasis.user.label == "Set by you")
        #expect(ProjectLinkBasis.auto.label == "Auto-linked")
        #expect(ProjectLinkBasis.candidate.label == "Not confirmed")
        #expect(ProjectLinkBasis.none.label == "No clear link")
    }

    @Test func eachRealOriginShowsItsOwnBasisAndMeta() {
        let rows = links(.known(
            links: [WorkLink(project: acme, origin: .user), WorkLink(project: shape, origin: .auto)],
            candidates: []
        ))
        #expect(rows.map(\.basis) == [.user, .auto])
        #expect(rows.map(\.meta) == ["Project · Set by you", "Project · Auto-linked"])
        #expect(rows[0].reason == WorkProjectCopy.reasonUser && rows[1].reason == WorkProjectCopy.reasonAuto)
    }

    /// 이름이 같아도 origin을 짐작하지 않는다: 같은 이름의 user 링크와 auto 링크는 각자의 기준을 가진다
    @Test func originIsNeverGuessedFromTheName() {
        let twin = WorkProject(id: ContextFx.id(9), name: "Shape launch")
        let rows = links(.known(links: [WorkLink(project: shape, origin: .auto), WorkLink(project: twin, origin: .user)], candidates: []))
        #expect(Set(rows.map(\.basis)) == [.auto, .user] && rows.count == 2)
        #expect(rows.map(\.id).count == Set(rows.map(\.id)).count)
    }

    @Test func noConfirmedLinkIsNoClearLinkAndAnUnreadOneClaimsNothing() {
        let rows = links(.none)
        #expect(rows.count == 1 && rows[0].basis == .none && rows[0].name == "Ungrouped" && rows[0].meta == "Project · No clear link")
        #expect(rows[0].reason == WorkProjectCopy.reasonNone)
        #expect(ProjectLinkRules.links(memberships: .unknown, active: [shape], writesUnavailable: false, isBusy: false, undo: nil, message: nil) == nil)
    }

    /// inferred 후보는 확인되지 않음이 보이게, 사용자 선택처럼 꾸미지 않는다. 확인된 링크가 없다는 사실("No clear link")도 지우지 않는다
    @Test func aCandidateIsShownAsUnconfirmedNeverAsASetLink() {
        let rows = links(.known(links: [], candidates: [WorkCandidate(project: shape, confidence: 0.62)]))
        #expect(rows.map(\.basis) == [.none, .candidate])
        let candidate = rows[1]
        #expect(candidate.meta == "Project · Not confirmed" && candidate.name == "Shape launch")
        #expect(candidate.reason == WorkProjectCopy.reasonCandidate && !candidate.reason.contains("You linked"))
        #expect(candidate.choices.isEmpty, "후보에는 팝업이 아니라 Confirm / Dismiss가 있다")
        #expect(rows.allSatisfy { $0.basis != .user || $0.contextID != shape.id })
    }

    // MARK: 선택지

    @Test func choicesForASingleLinkAreUngroupedItselfAndOnlyUnlinkedActiveProjects() {
        let rows = links(.known(links: [WorkLink(project: shape, origin: .user)], candidates: []))
        #expect(rows[0].choices.map(\.name) == ["Ungrouped", "Shape launch", "Acme website"])
        #expect(rows[0].choices.map(\.contextID) == [nil, shape.id, acme.id])
    }

    @Test func choicesForNoLinkAreUngroupedAndEveryActiveProject() {
        let rows = links(.none)
        #expect(rows[0].choices.map(\.name) == ["Ungrouped", "Acme website", "Shape launch"])
    }

    @Test func archivedLinksAreReadOnlyWithAnArchivedNote() {
        let rows = links(.known(links: [WorkLink(project: old, origin: .user)], candidates: []))
        #expect(rows[0].isArchived && rows[0].choices.isEmpty && rows[0].note == WorkProjectCopy.archivedNote)
        #expect(rows[0].meta == "Project · Set by you · Archived")
    }

    @Test func noProjectsAtAllSaysSoInsteadOfAnEmptyPopup() {
        let rows = links(.none, active: [])
        #expect(rows[0].choices.isEmpty && rows[0].note == WorkProjectCopy.noProjects && rows[0].basis == .none)
    }

    @Test func aGateOffServerLeavesTheStateReadableButNotChangeable() {
        let rows = links(.known(links: [WorkLink(project: shape, origin: .user)], candidates: [WorkCandidate(project: acme, confidence: 0.4)]), writesUnavailable: true)
        #expect(rows.allSatisfy { $0.choices.isEmpty && $0.note == WorkProjectCopy.writesUnavailable })
        #expect(rows.map(\.basis) == [.user, .candidate])
    }

    // MARK: Undo · 안내 자리

    @Test func undoAndNoteSitOnTheNewlyLinkedRowOrTheFirstRow() {
        let memberships = WorkMemberships.known(links: [WorkLink(project: acme, origin: .user), WorkLink(project: shape, origin: .user)], candidates: [])
        let onShape = links(memberships, undo: .project(shape.id), message: "note")
        #expect(onShape.map(\.canUndo) == [false, true] && onShape.map(\.message) == [nil, "note"])
        let unlinked = links(memberships, undo: .unlinked)
        #expect(unlinked.map(\.canUndo) == [true, false], "빼기만 했으면 남은 첫 줄")
        let none = links(.none, undo: .unlinked, message: "x")
        #expect(none[0].canUndo && none[0].message == "x")
    }

    @Test func busyDisablesEveryRow() {
        let rows = links(.known(links: [WorkLink(project: shape, origin: .user)], candidates: [WorkCandidate(project: acme, confidence: nil)]), isBusy: true)
        #expect(rows.allSatisfy { $0.isBusy })
    }

    // MARK: 고른 것 → 서버 쓰기 하나

    @Test func choosingMapsToExactlyOneServerWrite() {
        let linked = links(.known(links: [WorkLink(project: shape, origin: .user)], candidates: [])).first!
        #expect(ProjectChange.choosing(acme.id, in: linked) == .move(from: shape.id, to: acme.id), "바꾸기는 한 요청 (넣기 + 빼기 두 요청이 아니다)")
        #expect(ProjectChange.choosing(nil, in: linked) == .remove(shape.id))
        #expect(ProjectChange.choosing(shape.id, in: linked) == nil, "이미 그 값")
        let none = links(.none).first!
        #expect(ProjectChange.choosing(acme.id, in: none) == .add(acme.id))
        #expect(ProjectChange.choosing(nil, in: none) == nil)
    }

    @Test func archivedAndCandidateRowsNeverChooseThroughThePopup() {
        let archived = links(.known(links: [WorkLink(project: old, origin: .user)], candidates: [])).first!
        #expect(ProjectChange.choosing(shape.id, in: archived) == nil && ProjectChange.choosing(nil, in: archived) == nil)
        let candidate = links(.known(links: [], candidates: [WorkCandidate(project: shape, confidence: 0.5)]))[1]
        #expect(ProjectChange.choosing(acme.id, in: candidate) == nil)
        #expect(ProjectChange.confirming(candidate) == .add(shape.id) && ProjectChange.dismissing(candidate) == .remove(shape.id))
        // 확인된 링크는 Confirm / Dismiss 대상이 아니다
        let linked = links(.known(links: [WorkLink(project: shape, origin: .auto)], candidates: [])).first!
        #expect(ProjectChange.confirming(linked) == nil && ProjectChange.dismissing(linked) == nil)
    }

    /// 안내는 사용자가 동작한 줄에 놓인다 (후보를 확인하다 실패하면 후보 줄에)
    @Test func aNoteSitsOnTheRowTheUserActedOn() {
        let memberships = WorkMemberships.known(links: [], candidates: [WorkCandidate(project: shape, confidence: 0.5)])
        let rows = ProjectLinkRules.links(
            memberships: memberships, active: [shape], writesUnavailable: false, isBusy: false, undo: nil, message: "note", messageAnchor: .project(shape.id)
        ) ?? []
        #expect(rows.map(\.basis) == [.none, .candidate] && rows.map(\.message) == [nil, "note"])
        // 범위 없음 줄에서 시작했거나 줄을 못 찾으면 첫 줄
        let fallback = ProjectLinkRules.links(
            memberships: memberships, active: [shape], writesUnavailable: false, isBusy: false, undo: nil, message: "note", messageAnchor: .unlinked
        ) ?? []
        #expect(fallback.map(\.message) == ["note", nil])
    }

    /// 대화 헤더의 ProjectLink도 같은 줄 모양이다 (명시적 선택만: Set by you · No clear link)
    @Test func theChatHeaderUsesTheSameRowShape() {
        let project = ChatProject(
            contextID: shape.id, name: "Shape launch", basis: .user, reason: ChatCopy.projectReasonUser,
            choices: [.init(contextID: nil, name: "Ungrouped"), .init(contextID: shape.id, name: "Shape launch")], canUndo: true, message: "m"
        )
        let content = project.content
        #expect(content.basis == .user && content.meta == "Project · Set by you" && content.canUndo && content.message == "m")
        #expect(content.choices.map(\.contextID) == [nil, shape.id] && content.contextID == shape.id)
        let none = ChatProject(contextID: nil, name: "Ungrouped", basis: .none, reason: ChatCopy.projectReasonNone, choices: [], canUndo: false, message: nil)
        #expect(none.content.basis == .none && none.content.meta == "Project · No clear link")
    }
}
