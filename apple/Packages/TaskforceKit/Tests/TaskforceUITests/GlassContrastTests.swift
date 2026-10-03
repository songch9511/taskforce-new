import Foundation
import Testing
@testable import TaskforceUI

/// 런처 검색줄 · 액션 바 글자는 반투명 bg/glass 위에 있다 (U1 PR4). 대비는 창 뒤 바탕에 따라 바뀐다.
/// 시스템 유리를 빼고 bg/glass만으로, 가장 나쁜 창 뒤 바탕(Light는 검정, Dark는 흰색) 위에서도:
/// - 액션 바 상태 문장 · 화면 이름 · 동작 이름 · 키(13pt · 11pt)와 입력한 글자는 text/primary로 4.5:1 이상 (사용자 결정 2026-10-03:
///   Figma의 text/secondary는 3.5 / 3.1:1이라 바꿈, 유리 불투명도는 그대로)
/// - 22pt 자리표시(`Search tasks`)는 text/secondary 그대로, 큰 글자 3:1 이상
/// 투명도 줄이기는 불투명 settings/window 위 4.5:1.
struct GlassContrastTests {
    static let appearances = [false, true]

    /// 같은 모양의 창 뒤 바탕 (Light 흰색 · Dark 검정)
    static func usualBackdrop(dark: Bool) -> RGBA { dark ? RGBA("#000000") : RGBA("#FFFFFF") }
    /// 가장 나쁜 창 뒤 바탕 (Light 검정 · Dark 흰색)
    static func worstBackdrop(dark: Bool) -> RGBA { dark ? RGBA("#FFFFFF") : RGBA("#000000") }

    static func glass(over backdrop: RGBA, dark: Bool) -> RGBA {
        Contrast.composite(Contrast.shipped("bg/glass", dark: dark), over: backdrop)
    }

    /// 투명도 줄이기: 유리 대신 불투명 settings/window. 본문 글자 · 보조 글자 모두 4.5:1 이상
    @Test(arguments: ["text/primary", "text/secondary"], appearances)
    func reduceTransparencySurface(_ token: String, _ dark: Bool) {
        let ratio = Contrast.ratio(Contrast.shipped(token, dark: dark), Contrast.shipped("settings/window", dark: dark))
        #expect(ratio >= 4.5, "\(token) on settings/window \(dark ? "Dark" : "Light"): \(ratio)")
    }

    /// 같은 모양 바탕 위 유리 (흔한 경우)
    @Test(arguments: ["text/primary", "text/secondary"], appearances)
    func glassOverUsualBackdrop(_ token: String, _ dark: Bool) {
        let background = Self.glass(over: Self.usualBackdrop(dark: dark), dark: dark)
        let ratio = Contrast.ratio(Contrast.shipped(token, dark: dark), background)
        #expect(ratio >= 4.5, "\(token) on bg/glass (usual) \(dark ? "Dark" : "Light"): \(ratio)")
    }

    /// 가장 나쁜 바탕 위 유리: 액션 바 글자 · 키 · 입력한 글자(text/primary) 4.5:1, 22pt 자리표시(text/secondary, 큰 글자) 3:1
    @Test(arguments: appearances)
    func glassOverWorstBackdrop(_ dark: Bool) {
        let background = Self.glass(over: Self.worstBackdrop(dark: dark), dark: dark)
        let barText = Contrast.ratio(Contrast.shipped("text/primary", dark: dark), background)
        let placeholder = Contrast.ratio(Contrast.shipped("text/secondary", dark: dark), background)
        #expect(barText >= 4.5, "text/primary (action bar, keys) on bg/glass (worst) \(dark ? "Dark" : "Light"): \(barText)")
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
