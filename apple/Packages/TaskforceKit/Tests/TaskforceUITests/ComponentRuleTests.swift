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

    /// VoiceOver: "제목, 기한[, Changed]"
    @Test func listRowAccessibilityLabel() {
        #expect(MacListRow.accessibilityLabel(title: "데모 환경 배포", accessory: "Fri", changed: true) == "데모 환경 배포, Fri, Changed")
        #expect(MacListRow.accessibilityLabel(title: "데모 환경 배포", accessory: nil, changed: false) == "데모 환경 배포")
    }
}
