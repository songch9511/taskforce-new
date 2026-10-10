import Foundation
import Testing
import TaskforceKit
@testable import TaskforceUI

/// 0.2.0 All work 부품 (S3): 빈 화면 다섯 제목 · WorkRow 접근성 이름 · 필터 버튼 이름 · 버튼 크기 · 아이콘 역할 · 금지 문자열
struct WorkComponentTests {
    /// 디자인 EmptyState README의 다섯 화면 글자 그대로
    @Test func emptyScreensUseTheFiveDesignTitles() {
        #expect(PanelEmptyKind.allCases.map(\.title) == [
            "Nothing on your plate yet.", "No decisions waiting", "You're offline", "Couldn't load your work", "No matching work",
        ])
        for title in PanelEmptyKind.allCases.map(\.title) {
            #expect(!title.localizedCaseInsensitiveContains("caught up"))
            #expect(title != "Nothing here")
        }
    }

    @Test func workRowNameIsTitleStateActivityDue() {
        #expect(WorkRow.accessibilityLabel(title: "Pricing page", state: .inProgress, activity: "Needs your answer", due: "Fri", overdue: false)
            == "Pricing page — In Progress · Needs your answer, due Fri")
        #expect(WorkRow.accessibilityLabel(title: "Report", state: .toDo, activity: nil, due: "Oct 8", overdue: true)
            == "Report — To Do, overdue, due Oct 8")
        #expect(WorkRow.accessibilityLabel(title: "Notes", state: .done, activity: nil, due: nil, overdue: false) == "Notes — Done")
    }

    /// 둘째 줄은 활동이 먼저, 그다음 수행자
    @Test func workRowMetaPutsActivityFirst() {
        #expect(WorkRow.meta(activity: "Running", performer: "You") == "Running · You")
        #expect(WorkRow.meta(activity: nil, performer: "You") == "You")
        #expect(WorkRow.meta(activity: nil, performer: nil) == nil)
    }

    /// 행의 활동 글은 레일 링과 같은 말이다
    @Test func activityWordsMatchTheRail() {
        #expect(WorkActivity.needsAnswer == ActivityRing.Kind.needsYou.accessibilityLabel)
        #expect(WorkActivity.running == ActivityRing.Kind.running.accessibilityLabel)
        #expect(WorkActivity.stopRequested == "Stop requested · not confirmed")
    }

    @Test func filterButtonNamesTheActiveFilters() {
        #expect(WorkList.filtersLabel(WorkFilter()) == "Filters")
        #expect(WorkList.filtersLabel(WorkFilter(query: "deck")) == "Filters")
        #expect(WorkList.filtersLabel(WorkFilter(project: .ungrouped, status: .waiting)) == "Filters: Ungrouped, Waiting")
        #expect(WorkList.searchLabel == "Search work")
        #expect(WorkList.searchPrompt == "Search work…")
    }

    /// 디자인 버튼 높이: md 32 · text md 28 · sm 24
    @Test func buttonSizesFollowTheDesign() {
        #expect(TFButtonStyle.Size.md.height(.primary) == 32)
        #expect(TFButtonStyle.Size.md.height(.secondary) == 32)
        #expect(TFButtonStyle.Size.md.height(.text) == 28)
        #expect(TFButtonStyle.Size.sm.height(.text) == 24)
        #expect(TFButtonStyle.Size.sm.height(.primary) == 24)
    }

    /// All work의 아이콘은 Lucide 역할표 그대로 (Filters `list-filter` · Pin `pin` · Search `search`)
    @Test func workListIconsComeFromTheRoleTable() {
        #expect(TFIcon.filters.rawValue == "list-filter")
        #expect(TFIcon.pin.rawValue == "pin")
        #expect(TFIcon.search.rawValue == "search")
    }

    /// 화면에 쓰지 않는 말 (디자인 Content · Behaviors): "All caught up", Claude 로고 · 이름, 설명 문구 대신 쓰는 "Nothing here"
    @Test func workListSourcesAvoidBannedCopy() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/TaskforceUI")
        for file in ["WorkList.swift", "WorkRow.swift", "ChoiceChips.swift", "SearchField.swift"] {
            let text = try String(contentsOf: sources.appending(path: file), encoding: .utf8)
            #expect(!text.localizedCaseInsensitiveContains("caught up"), "\(file)")
            #expect(!text.localizedCaseInsensitiveContains("Nothing here"), "\(file)")
            #expect(!text.localizedCaseInsensitiveContains("claude"), "\(file)")
            // 아이콘은 Lucide 자산(`TFIcon`)만, SF Symbol · 색 점 없음
            #expect(!text.contains("Image(systemName:"), "\(file)")
            #expect(!text.contains("Circle().fill"), "\(file)")
        }
    }
}
