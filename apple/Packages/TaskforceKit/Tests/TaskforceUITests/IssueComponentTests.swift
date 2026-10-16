import CryptoKit
import SwiftUI
import Testing
import TaskforceKit
@testable import TaskforceUI

/// OA U2 부품의 규칙: StatusMark 셋 · 행 접근성 이름 · PropertyRow · Ask 알약 · SessionTab 수치 · ContextMenu 줄 이동 · 링의 빛 위 크기 · 프로젝트 아이콘 대응
@MainActor
struct IssueComponentTests {
    // MARK: StatusMark

    @Test func statusMarkHasExactlyThreeStatesAndTheirNames() {
        #expect(StatusMark.State.allCases == [.toDo, .inProgress, .done])
        #expect(StatusMark.State.allCases.map(\.label) == ["To Do", "In Progress", "Done"])
        #expect(StatusMark.State(WorkState.toDo) == .toDo && StatusMark.State(WorkState.inProgress) == .inProgress && StatusMark.State(WorkState.done) == .done)
        #expect(StatusMark.Size.md.points == 16 && StatusMark.Size.sm.points == 12)
        #expect(StatusMark.lineWidth == 1.5)
    }

    // MARK: 행의 접근성 이름

    @Test func projectRowSpeaksNameDashMeta() {
        let row = ProjectRowContent(kind: .project(UUID()), name: "Shape launch", icon: .megaphone, meta: "Needs your answer · Pricing tone")
        #expect(row.accessibilityName == "Shape launch — Needs your answer · Pricing tone")
        #expect(ProjectRowContent(kind: .ungrouped, name: "Ungrouped", icon: nil, meta: "").accessibilityName == "Ungrouped")
    }

    @Test func issueRowSpeaksTitleStateActivityAndDue() {
        let row = IssueRowContent(id: UUID(), title: "Late", state: .toDo, activity: nil, due: "Yesterday", urgent: true, overdue: true)
        #expect(row.accessibilityLabel == "Late — To Do, overdue, due Yesterday")
        #expect(WorkRow.accessibilityLabel(title: "Late", state: .toDo, activity: nil, due: "Yesterday", overdue: true) == row.accessibilityLabel, "기존 All work 행과 같은 말")
    }

    @Test func propertyRowSpeaksLabelColonValue() {
        #expect(PropertyRow<EmptyView>.accessibilityName(label: "Project", value: "Taskforce 0.2.0") == "Project: Taskforce 0.2.0")
        #expect(PropertyRow<EmptyView>.accessibilityName(label: "Due", value: "Yesterday", overdue: true) == "Due: Yesterday, overdue")
        #expect(PropertyRow<EmptyView>.labelWidth == 84)
    }

    @Test func theAskPillNamesNumberOrName() {
        #expect(AskPill.accessibilityName(number: 139, name: "Rewrite pricing page copy") == "Ask about #139")
        #expect(AskPill.accessibilityName(number: nil, name: "Shape launch") == "Ask about Shape launch")
        #expect(AskPill.title == "Ask" && AskPill.height == 24)
    }

    // MARK: SessionTab

    @Test func theTabIsTwentyFourCollapsedAndThirtySixExpanded() {
        #expect(SessionTabGeometry.collapsed.width == 24 && SessionTabGeometry.expanded.width == 36)
        #expect(SessionTabGeometry.collapsed.item == 20 && SessionTabGeometry.collapsed.ring == 12)
        #expect(SessionTabGeometry.expanded.item == 28 && SessionTabGeometry.expanded.ring == 18)
        #expect(SessionTabGeometry.collapsed.radius == 10 && SessionTabGeometry.expanded.radius == 12)
        #expect(SessionTabGeometry.collapsed.itemRadius == 6 && SessionTabGeometry.expanded.itemRadius == 8)
        #expect(SessionTabGeometry.fillet == 10 && SessionTabGeometry.crossfade == 0.22)
        #expect(SessionTabMetrics.expandedWidth == SessionTabGeometry.expanded.width, "Kit의 탭 폭과 부품의 폭이 같다")
        #expect(SessionTabMetrics.collapsedWidth == SessionTabGeometry.collapsed.width)
    }

    @Test func theTabHeightStacksItemsWithGapTwoAndTheDesignPadding() {
        // 세션 셋 + New: 접힘 6 + 4×20 + 3×2 + 6 = 98, 펼침 4 + 4×28 + 3×2 + 4 = 126 (DS 값. Figma는 접힘 간격 0이라 92)
        #expect(SessionTabGeometry.collapsed.height(count: 4) == 98)
        #expect(SessionTabGeometry.expanded.height(count: 4) == 126)
        #expect(SessionTabGeometry.collapsed.height(count: 1) == 32, "세션 0개: `+`만")
        #expect(SessionTabGeometry.frameSize(count: 4) == CGSize(width: 36, height: 126 + 20), "필렛 위아래 10")
    }

    @Test func aFullTabOfSixSessionsMoreAndNewStillFitsAPanelOf320() {
        // 여섯 + More + New = 여덟 칸, 펼침 4 + 8×28 + 7×2 + 4 = 246, 위 40 + 246 + 필렛 10 = 296 ≤ 320 (DS: "fits eight expanded slots")
        let height = SessionTabGeometry.expanded.height(count: 8)
        #expect(height == 246)
        #expect(SessionTabMetrics.top + height + SessionTabGeometry.fillet <= 320)
    }

    @Test func theTabShapeReachesTenAboveAndBelowItsBodyAndHalfAPointIntoThePanel() {
        let shape = SessionTabShape(bodyWidth: 24, bodyHeight: 98, radius: 10)
        let rect = CGRect(x: 0, y: 0, width: 36, height: 118)
        let bounds = shape.path(in: rect).boundingRect
        #expect(abs(bounds.minY - rect.minY) < 0.01 && abs(bounds.maxY - (rect.minY + 10 + 98 + 10)) < 0.01, "위아래 필렛 10")
        #expect(SessionTabGeometry.overlap == 0.5, "DS `right: calc(100% - .5px)`")
        #expect(abs(bounds.maxX - (rect.maxX + 0.5)) < 0.01, "오른쪽은 패널 쪽으로 0.5 겹친다")
        #expect(abs(bounds.width - 24.5) < 0.01, "몸통 24 + 겹침 0.5")
    }

    @Test func tabItemsSpeakNameAndLine() {
        let session = AgentSessionItem(
            id: UUID(), name: "Pricing copy draft", agent: .claudeCode, agentName: "Claude Code", connectionID: UUID(), status: .bound, ring: .running, line: "Running",
            createdAt: Date(), updatedAt: Date(), issueIDs: [], currentIssueID: nil, conversationID: nil, hasOpenTask: true, pill: nil
        )
        let item = SessionTabItem(session, current: true)
        #expect(item.accessibilityName == "Pricing copy draft · Running" && item.ring == .running && item.current)
        #expect(SessionTab.groupLabel == "Sessions" && SessionTab.newLabel == "New session")
    }

    @Test func aTabItemForASessionWithoutARingIsIdle() {
        let session = AgentSessionItem(
            id: UUID(), name: "Pricing copy draft", agent: .claudeCode, agentName: "Claude Code", connectionID: UUID(), status: .closed, ring: nil, line: "Closed",
            createdAt: Date(), updatedAt: Date(), issueIDs: [], currentIssueID: nil, conversationID: nil, hasOpenTask: false, pill: nil
        )
        #expect(SessionTabItem(session, current: false).ring == .idle, "링이 없는 세션도 탭에는 idle 점으로 (지어낸 running이 아니다)")
    }

    // MARK: 링

    @Test func everySessionRingHasARingKindAndTheNamesAgree() {
        for ring in AgentSessionRing.allCases {
            #expect(ActivityRing.Kind(ring).accessibilityLabel == ring.label, "\(ring)")
        }
        #expect(AgentSessionRing.allCases.count == 7 && ActivityRing.Kind.allCases.count == 7)
    }

    @Test func idleDoesNotMoveAndTheLightRingIsTwelveAndEighteen() {
        #expect(ActivityRing.Kind.idle.period == nil && ActivityRing.Kind.idle.arcLength(reduceMotion: false) == nil)
        #expect(ActivityRing.Size.small.points(on: .bezel) == 14 && ActivityRing.Size.small.points(on: .light) == 12)
        #expect(ActivityRing.Size.medium.points(on: .bezel) == 18 && ActivityRing.Size.medium.points(on: .light) == 18)
    }

    // MARK: ContextMenu

    private func menu(_ ids: [String]) -> (ContextMenuModel, () -> [String]) {
        nonisolated(unsafe) var picked: [String] = []
        let items = ids.map { id -> ContextMenuItem in
            id == "-" ? .separator() : ContextMenuItem(id: id, label: id, action: { picked.append(id) })
        }
        let model = ContextMenuModel(items: items)
        return (model, { picked })
    }

    @Test func arrowKeysSkipSeparatorsAndDoNotWrap() {
        let (model, _) = menu(["rename", "icon", "-", "archive"])
        model.move(1)
        #expect(model.highlighted == 0)
        model.move(1); model.move(1)
        #expect(model.highlighted == 3, "구분선을 건너뛴다")
        model.move(1)
        #expect(model.highlighted == 3, "끝에서 돌지 않는다")
        model.move(-1); model.move(-1); model.move(-1); model.move(-1)
        #expect(model.highlighted == 0)
    }

    @Test func upFromNothingStartsAtTheLastRow() {
        let (model, _) = menu(["a", "b", "-", "c"])
        model.move(-1)
        #expect(model.highlighted == 3)
    }

    @Test func returnPicksTheHighlightedRowAndClosesTheMenu() {
        let (model, picked) = menu(["a", "-", "b"])
        var closed = 0
        model.onPick = { closed += 1 }
        model.activate()
        #expect(picked().isEmpty && closed == 0, "짚은 줄이 없으면 아무 일도 없다")
        model.move(1); model.move(1)
        model.activate()
        #expect(picked() == ["b"] && closed == 1)
        model.pick(1)
        #expect(picked() == ["b"], "구분선은 고르지 못한다")
        model.pick(9)
        #expect(closed == 1)
    }

    @Test func theMenuIsAtLeast240WideInsetFiveAndTheCheckIsOnTheRight() {
        #expect(ContextMenuView.minWidth == 240 && ContextMenuView.maxWidth == 460 && ContextMenuView.inset == 5)
        let checked = ContextMenuItem(id: "a", label: "A", checked: true)
        let sub = ContextMenuItem(id: "b", label: "B", hasSubmenu: true)
        #expect(checked.checked && !checked.hasSubmenu && sub.hasSubmenu && !sub.isSeparator && ContextMenuItem.separator().isSeparator)
    }

    // MARK: 프로젝트 아이콘 · 머리

    @Test func everyProjectIconNameHasItsOwnGlyphAndFolderIsTheFallback() {
        let glyphs = ProjectIconName.allCases.map { TFIcon.project($0).rawValue }
        #expect(Set(glyphs).count == ProjectIconName.allCases.count)
        #expect(TFIcon.project(.folder) == .project)
        for name in ProjectIconName.pool { #expect(TFIcon.project(name).rawValue == name.raw, "\(name)") }
        #expect(ProjectGlyph.icon(for: .ungrouped) == .ungrouped && ProjectGlyph.icon(for: .doneToday) == .doneToday)
    }

    @Test func theSessionPillKeepsItsWordsWhenDisabled() {
        let pill = PanelHeaderPill(title: "Open in Terminal", disabledReason: "Turn is running", action: {})
        #expect(pill.title == "Open in Terminal" && pill.disabledReason == "Turn is running")
        #expect(PanelHeaderPill(title: "Resume here", action: {}).disabledReason == nil)
    }

    // MARK: 끝난 세션 (사용자 결정 2026-10-15: 상태 말 없이 흐리게)

    @Test func aClosedSessionRowIsDimmedWithoutAStatusWordUsingTheDSDisabledValues() {
        let closed = SessionRow.Look.of(line: "", dimmed: true)
        #expect(closed.nameIsQuiet && closed.markOpacity == 0.45 && !closed.showsLine, "DS 비활성 값 .45 · text-secondary 이름 · 말 없음")
        let running = SessionRow.Look.of(line: "Running", dimmed: false)
        #expect(!running.nameIsQuiet && running.markOpacity == 1 && running.showsLine)
        #expect(!SessionRow.Look.of(line: "", dimmed: false).showsLine, "말이 없으면 그리지 않는다")
        #expect(!SessionRow.Look.of(line: "Closed", dimmed: true).showsLine, "끝난 행은 말이 와도 그리지 않는다")
    }

    // MARK: 긴 메뉴 (검토 반영 9)

    @Test func aMenuTallerThanTheScreenIsLimitedToTheVisibleHeightLeavingTheMargins() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        #expect(ContextMenuGeometry.maxHeight(visible: visible) == 875 - 2 * ContextMenuGeometry.screenMargin)
        let limited = ContextMenuGeometry.limited(natural: CGSize(width: 260, height: 2_400), visible: visible)
        #expect(limited == CGSize(width: 260, height: 859), "폭은 그대로, 높이만 줄인다")
        #expect(ContextMenuGeometry.limited(natural: CGSize(width: 260, height: 300), visible: visible).height == 300, "짧은 메뉴는 그대로")
        let frame = ContextMenuGeometry.frame(size: limited, row: CGRect(x: 1000, y: 400, width: 364, height: 54), pointerX: 1100, visible: visible)
        #expect(frame.minY >= visible.minY && frame.maxY <= visible.maxY, "줄인 메뉴는 화면 안에 놓인다")
    }

    // MARK: SourceMark (검토 반영 11)

    @Test func theFourServicesHaveTheirOwnMarkAndManualSourcesGetTheDashedBlankTile() {
        #expect(SourceMark.assetName(for: .slack) == "source-mark/slack")
        #expect(SourceMark.assetName(for: .notion) == "source-mark/notion")
        #expect(SourceMark.assetName(for: .gmail) == "source-mark/gmail")
        #expect(SourceMark.assetName(for: .googleMeet) == "source-mark/google-meet")
        #expect(SourceMark.assetName(for: .manual(.note)) == nil && SourceMark.assetName(for: .manual(.message)) == nil, "마크가 없으면 점선 빈 타일")
    }

    /// 마크는 DS 아티팩트의 SourceMark(thesvg `default.svg` 그대로)와 같은 파일이고 다시 칠하지 않는다 (original 렌더링): 파일 지문과 렌더링 의도를 고정한다
    @Test(arguments: [
        ("slack", "082fb39f58df"), ("notion", "0d94471649fb"), ("gmail", "a8de5ec713ee"), ("google-meet", "0645463c2db7"),
    ])
    func theMarksAreThePublishedFilesRenderedAsTheyAre(name: String, prefix: String) throws {
        let folder = TokenCatalog.sourceCatalog.appending(path: "source-mark/\(name).imageset", directoryHint: .isDirectory)
        let svg = try Data(contentsOf: folder.appending(path: "\(name).svg"))
        let digest = SHA256.hash(data: svg).map { String(format: "%02x", $0) }.joined()
        #expect(digest.hasPrefix(prefix), "\(name): DS의 SourceMark 파일과 다르다 (\(digest.prefix(12)))")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "Contents.json"))) as? [String: Any])
        let properties = try #require(json["properties"] as? [String: Any])
        #expect(properties["template-rendering-intent"] as? String == "original" && properties["preserves-vector-representation"] as? Bool == true)
        let text = String(decoding: svg, as: UTF8.self).lowercased()
        for banned in ["<script", "onload", "onclick", "onerror", "<image", "<foreignobject", "href="] {
            #expect(!text.contains(banned), "\(name): \(banned)")
        }
    }
}
