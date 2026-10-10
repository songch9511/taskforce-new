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

    /// 화면에 쓰지 않는 말 (디자인 Content · Behaviors): "All caught up" · "Nothing here" · Claude/Anthropic 이름, 색 점 글리프.
    /// 소스의 문자열 글자만 본다(주석 제외). 빈 화면 부품(EmptyState.swift)도 포함 (리뷰 L2)
    @Test func workListSourcesAvoidBannedCopy() throws {
        for file in Self.drawnFiles + ["EmptyState.swift"] {
            let literals = Self.literals(in: try Self.source(file))
            #expect(!literals.isEmpty, "\(file)")
            for literal in literals {
                let phrase = ["caught up", "nothing here", "claude", "anthropic"].first { literal.localizedCaseInsensitiveContains($0) }
                #expect(phrase == nil, "\(file): \(literal)")
                let dot = ["●", "•", "◦", "🔴", "🟢", "🟡", "🔵", "✨"].first { literal.contains($0) }
                #expect(dot == nil, "\(file): \(literal)")
            }
        }
    }

    /// 상태는 모양(StatusMark)으로, 아이콘은 Lucide 자산(`TFIcon`)만: S3 부품에 SF Symbol · 색으로 채운 점(원 · 캡슐 · 둥근 사각형) ·
    /// 상태 색(초록 · 노랑 · 파랑 같은 시스템 색)이 없다
    @Test func workListDrawsNoColorDotsOrSymbols() throws {
        let dot = try NSRegularExpression(pattern: #"(Circle|Ellipse)\(\)\s*\.(fill|foregroundStyle|foregroundColor)"#)
        let systemColor = try NSRegularExpression(pattern: #"Color\.(green|yellow|orange|blue|red|purple|pink|mint|teal)\b|\.(green|yellow|orange|blue|purple)\b"#)
        for file in Self.drawnFiles {
            let code = Self.code(try Self.source(file))
            let range = NSRange(code.startIndex..., in: code)
            #expect(!code.contains("Image(systemName:"), "\(file)")
            #expect(dot.firstMatch(in: code, range: range) == nil, "\(file)")
            #expect(systemColor.firstMatch(in: code, range: range) == nil, "\(file)")
        }
    }

    /// S3가 새로 그리는 부품 파일
    static let drawnFiles = ["WorkList.swift", "WorkRow.swift", "ChoiceChips.swift", "SearchField.swift"]

    static func source(_ file: String) throws -> String {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/TaskforceUI")
        return try String(contentsOf: sources.appending(path: file), encoding: .utf8)
    }

    /// 주석 줄을 뺀 코드
    static func code(_ source: String) -> String {
        source.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
    }

    /// 코드의 "…" 글자
    static func literals(in source: String) -> [String] {
        let stripped = Self.code(source)
        let regex = try! NSRegularExpression(pattern: #""(?:[^"\\\n]|\\.)*""#)
        return regex.matches(in: stripped, range: NSRange(stripped.startIndex..., in: stripped))
            .compactMap { Range($0.range, in: stripped).map { String(stripped[$0]) } }
    }
}
