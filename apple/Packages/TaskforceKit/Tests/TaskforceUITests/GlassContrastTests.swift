import Foundation
import Testing
@testable import TaskforceUI

/// 런처 검색줄 · 액션 바 글자는 반투명 bg/glass 위에 있다 (U1 PR4). 대비는 창 뒤 바탕에 따라 바뀐다.
/// 여기서는 앱만으로 정해지는 짝을 고정한다: 투명도 줄이기(불투명 settings/window), 같은 모양의 바탕 위(흰 바탕 위 Light 유리 · 검은 바탕 위 Dark 유리),
/// 22pt 자리표시(큰 글자 3:1)는 가장 나쁜 바탕(Light는 검정, Dark는 흰색) 위에서도.
/// 13pt 보조 글자의 가장 나쁜 바탕 값(bg/glass만, 시스템 유리를 빼고 계산)은 PR 본문에 숫자로 적는다 (Light 3.5 · Dark 3.1, 실제로는 시스템 유리가 더해져 더 높다).
struct GlassContrastTests {
    static let appearances = [false, true]

    /// 같은 모양의 창 뒤 바탕 (Light 흰색 · Dark 검정)
    static func usualBackdrop(dark: Bool) -> RGBA { dark ? RGBA("#000000") : RGBA("#FFFFFF") }
    /// 가장 나쁜 창 뒤 바탕 (Light 검정 · Dark 흰색)
    static func worstBackdrop(dark: Bool) -> RGBA { dark ? RGBA("#FFFFFF") : RGBA("#000000") }

    static func glass(over backdrop: RGBA, dark: Bool) -> RGBA {
        Contrast.composite(Contrast.shipped("bg/glass", dark: dark), over: backdrop)
    }

    /// 투명도 줄이기: 유리 대신 불투명 settings/window. 13pt 보조 글자 · 본문 글자 모두 4.5:1 이상
    @Test(arguments: ["text/primary", "text/secondary"], appearances)
    func reduceTransparencySurface(_ token: String, _ dark: Bool) {
        let ratio = Contrast.ratio(Contrast.shipped(token, dark: dark), Contrast.shipped("settings/window", dark: dark))
        #expect(ratio >= 4.5, "\(token) on settings/window \(dark ? "Dark" : "Light"): \(ratio)")
    }

    /// 같은 모양 바탕 위 유리: 13pt 보조 글자(상태 문장 · 키) 4.5:1 이상
    @Test(arguments: ["text/primary", "text/secondary"], appearances)
    func glassOverUsualBackdrop(_ token: String, _ dark: Bool) {
        let background = Self.glass(over: Self.usualBackdrop(dark: dark), dark: dark)
        let ratio = Contrast.ratio(Contrast.shipped(token, dark: dark), background)
        #expect(ratio >= 4.5, "\(token) on bg/glass (usual) \(dark ? "Dark" : "Light"): \(ratio)")
    }

    /// 가장 나쁜 바탕 위 유리: 입력한 글자(text/primary)는 4.5:1, 22pt 자리표시(text/secondary, 큰 글자)는 3:1 이상
    @Test(arguments: appearances)
    func glassOverWorstBackdrop(_ dark: Bool) {
        let background = Self.glass(over: Self.worstBackdrop(dark: dark), dark: dark)
        let typed = Contrast.ratio(Contrast.shipped("text/primary", dark: dark), background)
        let placeholder = Contrast.ratio(Contrast.shipped("text/secondary", dark: dark), background)
        #expect(typed >= 4.5, "text/primary on bg/glass (worst) \(dark ? "Dark" : "Light"): \(typed)")
        #expect(placeholder >= 3, "text/secondary 22pt on bg/glass (worst) \(dark ? "Dark" : "Light"): \(placeholder)")
    }

    /// 범위 메뉴(bg/menu)는 런처 본문 카드(bg/elevated) 위에 뜬다: 범위 이름 · 개수 4.5:1 이상
    @Test(arguments: ["text/primary", "text/secondary"], appearances)
    func scopeMenuOverTheBodyCard(_ token: String, _ dark: Bool) {
        let background = Contrast.composite(Contrast.shipped("bg/menu", dark: dark), over: Contrast.shipped("bg/elevated", dark: dark))
        let ratio = Contrast.ratio(Contrast.shipped(token, dark: dark), background)
        #expect(ratio >= 4.5, "\(token) on bg/menu over bg/elevated \(dark ? "Dark" : "Light"): \(ratio)")
    }
}
