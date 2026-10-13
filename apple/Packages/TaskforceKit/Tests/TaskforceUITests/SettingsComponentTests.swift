import Testing
@testable import TaskforceUI

/// 0.2.0 설정 창 부품의 순수 규칙: 디자인 README › Settings "Spatial rhythm" · KeyCombo 이름
struct SettingsComponentTests {
    /// 제목 → 트레이 6, 트레이 → 각주 6, 주제 사이 24, 제목 없는 이어지는 트레이 12, 행 40 이상(안쪽 8 · 12), 구분선 좌우 12
    @Test func trayRhythmMatchesTheDesign() {
        #expect(SettingsTray.titleGap == 6)
        #expect(SettingsTray.topicGap == 24)
        #expect(SettingsTray.followOnGap == 12)
        #expect(SettingsTray.rowMinHeight == 40)
        #expect(SettingsTray.rowPadding.top == 8 && SettingsTray.rowPadding.leading == 12)
        #expect(SettingsTray.separatorInset == 12)
    }

    /// 앞 마크(20)가 있는 행의 구분선은 글자에서 시작한다: 12 + 20 + 12
    @Test func leadRowsStartTheirSeparatorAtTheText() {
        #expect(SettingsTray.leadSeparatorInset == 44)
    }

    /// 설정 컨트롤은 24pt (`size="sm"`), TextField sm은 180 폭, Toggle은 34×20
    @Test func settingsControlsAreSmall() {
        #expect(SettingsTray.controlHeight == 24)
        #expect(SettingsTray.fieldWidth == 180)
        #expect(SettingsTray.toggleSize.width == 34 && SettingsTray.toggleSize.height == 20)
    }

    /// KeyCombo는 하나의 이름으로 읽힌다 ("Option Space"), 액션 바 KeyHint와 같은 이름
    @Test func keyComboReadsAsOneName() {
        #expect(KeyCombo.spokenName(["⌥", "Space"]) == "Option Space")
        #expect(KeyCombo.spokenName(["⌘", "2"]) == "Command 2")
        #expect(KeyCombo.spokenName(["⌃", "⌥", "⇧", "⌘", "K"]) == "Control Option Shift Command K")
    }
}
