#if os(macOS)
import Foundation
import Testing
@testable import TaskforceKit
@testable import TaskforceUI

/// 하위 에이전트 트리 줄의 값 규칙 (T1): 들여쓰기 · 접근성 이름과 값 · 둘째 줄 글. 새 문구는 없다 (기존 낱말과 숫자뿐). 이름은 모델이 쓴 description뿐이다
struct SubagentTreeRowTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func list() -> BackgroundTaskList {
        var list = BackgroundTaskList()
        list.apply(.started(taskID: "a1", toolUseID: nil, kind: .agent, name: "Review the copy", at: t0, parentID: nil, depth: 1, foreground: false))
        list.apply(.started(taskID: "b2", toolUseID: nil, kind: .agent, name: "Check a note", at: t0.addingTimeInterval(1), parentID: "a1", depth: 2, foreground: true))
        list.apply(.started(taskID: "c3", toolUseID: nil, kind: .agent, name: "Read the strings", at: t0.addingTimeInterval(2), parentID: "b2", depth: 3, foreground: true))
        list.apply(.started(taskID: "d4", toolUseID: nil, kind: .agent, name: "Check the tests", at: t0.addingTimeInterval(3), parentID: "b2", depth: 3, foreground: true))
        list.apply(.finished(taskID: "d4", kind: .agent, status: .failed, exitCode: nil, at: t0.addingTimeInterval(9)))
        return list
    }

    private func rows(_ expansion: SubagentTreeExpansion = SubagentTreeExpansion()) -> [SubagentTreeRow] {
        SubagentTree.rows(for: list(), expansion: expansion)
    }

    @Test func theIndentGrowsByTwelveAPointAndStopsAtTheFourthLevel() {
        #expect(SubagentTreeLook.indent(level: 0) == 0)
        #expect(SubagentTreeLook.indent(level: 1) == 12)
        #expect(SubagentTreeLook.indent(level: 4) == 48)
        #expect(SubagentTreeLook.indent(level: 9) == 48, "더 깊어도 옆줄 폭 256에서 제목이 모자라지 않게")
        #expect(SubagentTreeLook.indent(level: -3) == 0)
    }

    @Test func aRowWithChildrenSaysCollapsedOrExpandedAsItsValueAndOthersSayNothing() throws {
        let shown = rows()
        // 기본: a1(level 0, 펴짐) · b2(level 1, 접힘, 자식 c3 d4) 가 보인다
        #expect(shown.map(\.task.id) == ["a1", "b2"])
        #expect(SubagentTreeLook.accessibilityValue(shown[0]) == "Expanded" && SubagentTreeLook.accessibilityValue(shown[0]) == SessionViewCopy.expanded)
        #expect(SubagentTreeLook.accessibilityValue(shown[1]) == "Collapsed" && SubagentTreeLook.accessibilityValue(shown[1]) == SessionViewCopy.collapsed)
        let all = rows(SubagentTreeExpansion(visibleLevels: 100))
        #expect(all.map(\.task.id).count == 4)
        let leaf = try #require(all.first { $0.task.id == "c3" })
        #expect(SubagentTreeLook.accessibilityValue(leaf) == nil, "자식이 없는 줄에는 접힘 · 펼침 값이 없다")
    }

    @Test func theNameIsKindTitleAndStatusAndACollapsedBranchAddsItsCounts() {
        let now = t0.addingTimeInterval(30)
        let shown = rows()
        #expect(SubagentTreeLook.accessibilityName(shown[0], now: now) == "Agent, Review the copy, Running")
        // b2는 접혀 있고 그 아래에 도는 c3 하나와 실패한 d4 하나가 있다
        #expect(SubagentTreeLook.accessibilityName(shown[1], now: now) == "Agent, Check a note, Running, Running 1 · Failed 1")
        let all = rows(SubagentTreeExpansion(visibleLevels: 100))
        #expect(SubagentTreeLook.accessibilityName(all[1], now: now) == "Agent, Check a note, Running", "펴져 있으면 끝 글이 없다")
    }

    @Test func theNameNeverCarriesAnIdAPathOrAPrompt() {
        let now = t0.addingTimeInterval(30)
        for row in rows(SubagentTreeExpansion(visibleLevels: 100)) {
            let name = SubagentTreeLook.accessibilityName(row, now: now)
            #expect(!name.contains(row.task.id) && !name.contains("/") && !name.lowercased().contains("prompt"))
        }
    }

    @Test func aFailedRowsNameSaysFailedOnce() throws {
        let all = rows(SubagentTreeExpansion(visibleLevels: 100))
        let failed = try #require(all.first { $0.task.id == "d4" })
        #expect(SubagentTreeLook.accessibilityName(failed, now: t0.addingTimeInterval(30)) == "Agent, Check the tests, Failed")
    }

    @Test func theLayoutNumbersAreTheDesignedOnes() {
        #expect(SubagentTreeLook.indentStep == 12 && SubagentTreeLook.maxIndentLevels == 4 && SubagentTreeLook.chevronWidth == 20)
    }
}
#endif
