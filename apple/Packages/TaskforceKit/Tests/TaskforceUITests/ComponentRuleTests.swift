import Testing
@testable import TaskforceUI

/// 부품 안의 순수 규칙
struct ComponentRuleTests {
    /// Key: 키 하나에 상자 하나, ↩는 그린 기호
    @Test(arguments: [
        ("⌘K", [KeyHint.Key.text("⌘"), .text("K")]),
        ("⌘↩", [.text("⌘"), .returnKey]),
        ("↩", [.returnKey]),
        ("⌥Space", [.text("⌥"), .text("Space")]),
        ("esc", [.text("esc")]),
        ("⌘⌫", [.text("⌘"), .text("⌫")]),
        ("⇧⌘K", [.text("⇧"), .text("⌘"), .text("K")]),
        ("⌘ R", [.text("⌘"), .text("R")]),
        ("↑↓", [.text("↑"), .text("↓")]),
        ("", []),
    ])
    func keysSplitOnePerBox(_ shortcut: String, _ expected: [KeyHint.Key]) {
        #expect(KeyHint.keys(shortcut) == expected)
    }

    @Test func spokenKeys() {
        #expect(KeyHint.spokenName(KeyHint.keys("⌘K")) == "Command K")
        #expect(KeyHint.spokenName(KeyHint.keys("⌘↩")) == "Command Return")
        #expect(KeyHint.spokenName(KeyHint.keys("⌥Space")) == "Option Space")
    }

    /// M8 Use 칩: 4개까지 + `N more`
    @Test(arguments: [(0, 0, 0), (3, 3, 0), (4, 4, 0), (5, 4, 1), (6, 4, 2)])
    func chipFlowSplit(_ count: Int, _ shown: Int, _ more: Int) {
        let split = ChipFlow.split(count: count, limit: ChipFlow.visibleLimit)
        #expect(split.shown == shown)
        #expect(split.more == more)
    }

    @Test func chipFlowAccessibilityLabel() {
        let titles = ["제품 회의록", "데모 요청", "기획서 v1", "메모", "견적서", "인터뷰"]
        #expect(ChipFlow.accessibilityLabel(titles, limit: 4) == "Sources: 제품 회의록, 데모 요청, 기획서 v1, 메모, 2 more")
        #expect(ChipFlow.accessibilityLabel(["데모 요청"], limit: 4) == "Sources: 데모 요청")
    }

    /// 갈래 VoiceOver: "Taskforce, <상태>[, <부제>]"
    @Test func laneAccessibilityLabel() {
        #expect(LaneCard.accessibilityLabel(heading: "Taskforce", title: "Draft ready", subtitle: "AI draft · 14:20") == "Taskforce, Draft ready, AI draft · 14:20")
        #expect(LaneCard.accessibilityLabel(heading: "Taskforce", title: "Writing draft", subtitle: nil) == "Taskforce, Writing draft")
        #expect(LaneCard.accessibilityLabel(heading: "Taskforce", title: "Writing draft", subtitle: "") == "Taskforce, Writing draft")
        // 초안 제목이 제목이면 상태를 먼저 읽는다 (iPhone P2 "Taskforce, Draft ready")
        #expect(
            LaneCard.accessibilityLabel(heading: "Taskforce", title: "데모 예상 질문", subtitle: "AI draft · 14:20", spokenState: "Draft ready")
                == "Taskforce, Draft ready, 데모 예상 질문, AI draft · 14:20"
        )
    }

    /// VoiceOver: "제목, 기한[, Changed]"
    @Test func listRowAccessibilityLabel() {
        #expect(MacListRow.accessibilityLabel(title: "데모 환경 배포", accessory: "Fri", changed: true) == "데모 환경 배포, Fri, Changed")
        #expect(MacListRow.accessibilityLabel(title: "데모 환경 배포", accessory: nil, changed: false) == "데모 환경 배포")
    }
}
