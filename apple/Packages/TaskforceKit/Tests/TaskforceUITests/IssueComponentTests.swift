import CryptoKit
import SwiftUI
import Testing
import TaskforceKit
@testable import TaskforceUI

/// OA U2 부품의 규칙: StatusMark 셋 · 행 접근성 이름 · PropertyRow · Ask 알약 · ContextMenu 줄 이동 · 링의 빛 위 크기 · 프로젝트 아이콘 대응
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

    // MARK: 링

    /// 링의 VoiceOver 이름(`ActivityRing.Kind`)과 세션 링의 말(`AgentSessionRing.label`)은 끝남 하나만 다르다: 끝난 링은 열어 볼 때까지 남아 몇 시간이 될 수 있어
    /// 링의 이름은 "Done"이고(OA PR-D2, 계약 23장), 링의 말 "Done just now"는 끝남을 3초만 두는 옛 모드의 활동 글이다 (열 때까지 남는 모드는 활동 글을 "Done"으로 덮는다)
    @Test func everySessionRingHasARingKindAndTheNamesAgree() {
        for ring in AgentSessionRing.allCases where ring != .done {
            #expect(ActivityRing.Kind(ring).accessibilityLabel == ring.label, "\(ring)")
        }
        #expect(ActivityRing.Kind(AgentSessionRing.done).accessibilityLabel == "Done" && AgentSessionRing.done.label == "Done just now")
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

    // MARK: 프로젝트 Sessions 묶음의 세션 행 (에이전트 트리 T3m): 공유 · 접힌 행의 끝 글 · 펼침 표시. 새 문구 없음

    #if os(macOS)
    private func sessionItem(closed: Bool = false, line: String = "Running") -> AgentSessionItem {
        AgentSessionItem(
            id: UUID(), name: "Pricing copy", agent: .claudeCode, agentName: "Claude Code", connectionID: UUID(), status: closed ? .closed : .bound, ring: closed ? nil : .running,
            line: closed ? "" : line, createdAt: .distantPast, updatedAt: .distantPast, issueIDs: [], currentIssueID: nil, conversationID: nil, hasOpenTask: false, pill: nil
        )
    }

    @Test func theSecondLineJoinsTheStatusWordAndTheOtherProjectsAndAClosedSessionKeepsOnlyTheProjects() {
        #expect(SessionRow.secondLine(line: "Running", dimmed: false, shared: nil) == "Running", "공유가 없으면 지금까지와 같다")
        #expect(SessionRow.secondLine(line: "Running", dimmed: false, shared: "Acme, Beta") == "Running · Acme, Beta")
        #expect(SessionRow.secondLine(line: "", dimmed: true, shared: "Acme") == "Acme", "끝난 세션은 상태 말이 없고 프로젝트 이름만 남는다")
        #expect(SessionRow.secondLine(line: "Closed", dimmed: true, shared: nil) == nil, "끝난 행은 말이 와도 그리지 않는다")
        #expect(SessionRow.secondLine(line: "", dimmed: false, shared: nil) == nil && SessionRow.secondLine(line: "", dimmed: false, shared: "") == nil)
    }

    @Test func theRowNameKeepsItsShapeAndAppendsTheOtherProjectsAndTheCollapsedSummary() {
        let item = sessionItem()
        #expect(SessionRow.accessibilityName(item) == item.rowAccessibilityName, "덧붙일 것이 없으면 지금 그대로")
        #expect(SessionRow.accessibilityName(item, shared: "Acme") == "Pricing copy — Claude Code — Running — Acme")
        #expect(SessionRow.accessibilityName(item, summary: "Running 2") == "Pricing copy — Claude Code — Running, Running 2")
        #expect(SessionRow.accessibilityName(sessionItem(closed: true), shared: "Acme") == "Pricing copy — Claude Code — Acme")
    }

    @Test func theDisclosureSpeaksAValueAndAnActionOnlyWhenTheRowCanOpen() {
        let open = SessionRowDisclosure(isExpanded: true, canToggle: true, accessibilityValue: "Expanded", toggleActionName: "Show less", onToggle: {})
        #expect(open.accessibilityValue == "Expanded" && open.toggleActionName == "Show less")
        let none = SessionRowDisclosure(isExpanded: false, canToggle: false, accessibilityValue: "Collapsed", toggleActionName: "Show all", onToggle: {})
        #expect(none.accessibilityValue == nil && none.toggleActionName == nil, "트리가 없는 에이전트의 줄은 값도 동작도 없다 (빈 칸만 같은 폭으로 남는다)")
    }
    #endif

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
