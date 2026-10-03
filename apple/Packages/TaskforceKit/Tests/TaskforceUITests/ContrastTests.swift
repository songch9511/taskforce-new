import Foundation
import Testing
@testable import TaskforceUI

/// WCAG 2 대비 (sRGB 상대 휘도)
enum Contrast {
    static func luminance(_ c: RGBA) -> Double {
        func linear(_ v: Int) -> Double {
            let s = Double(v) / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    /// 반투명 `top`을 불투명 `bottom` 위에 얹은 색
    static func composite(_ top: RGBA, over bottom: RGBA) -> RGBA {
        let a = Double(top.a) / 255
        func mix(_ t: Int, _ b: Int) -> Int { Int((Double(t) * a + Double(b) * (1 - a)).rounded()) }
        return RGBA(r: mix(top.r, bottom.r), g: mix(top.g, bottom.g), b: mix(top.b, bottom.b))
    }

    static func ratio(_ a: RGBA, _ b: RGBA) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func shipped(_ name: String, dark: Bool) -> RGBA {
        let value = TokenCatalog.resolve(name)!
        return dark ? value.dark : value.light
    }

    /// 선택 행 면: bg/selected를 목록 면(settings/sidebar) · 흰 면(bg/elevated) 위에 얹은 색
    static func selectionBackgrounds(dark: Bool) -> [(name: String, color: RGBA)] {
        let selected = shipped("bg/selected", dark: dark)
        return ["settings/sidebar", "bg/elevated"].map { base in
            ("bg/selected over \(base)", composite(selected, over: shipped(base, dark: dark)))
        }
    }
}

/// 글자 토큰은 놓이는 바탕 위에서 4.5:1 이상 (WCAG AA 본문)
struct ContrastTests {
    static let appearances = [false, true]

    /// 선택 행 위의 글자 (U1 PR3 계획): text/primary · text/secondary-selected · status/overdue-selected
    @Test(arguments: ["text/primary", "text/secondary-selected", "status/overdue-selected"], appearances)
    func selectedRowText(_ token: String, _ dark: Bool) {
        let text = Contrast.shipped(token, dark: dark)
        for background in Contrast.selectionBackgrounds(dark: dark) {
            let ratio = Contrast.ratio(text, background.color)
            #expect(ratio >= 4.5, "\(token) on \(background.name) \(dark ? "Dark" : "Light"): \(ratio)")
        }
    }

    /// 선택하지 않은 면 위의 글자 (Figma 156:6에서 실제로 놓이는 짝)
    @Test(arguments: [
        ("text/primary", "settings/sidebar"),
        ("text/primary", "bg/elevated"),
        ("text/primary", "settings/content"),
        ("text/primary", "settings/window"),
        ("text/primary", "settings/fill"),
        // 액션 바 Return 동작 알약 안의 키 (`KeyHint(onFill:)`). text/secondary는 다크 settings/fill 위 4.06:1이라 쓰지 않는다
        ("text/secondary-selected", "settings/fill"),
        ("text/secondary", "settings/sidebar"),
        ("text/secondary", "bg/elevated"),
        ("text/secondary", "settings/content"),
        ("text/secondary", "settings/window"),
        ("status/overdue", "settings/sidebar"),
        ("text/link", "bg/elevated"),
        ("text/link", "settings/content"),
        ("source/text", "source/paper"),
        ("source/meta", "source/paper"),
        ("bg/canvas", "text/primary"),
    ], appearances)
    func baseText(_ pair: (text: String, background: String), _ dark: Bool) {
        let ratio = Contrast.ratio(Contrast.shipped(pair.text, dark: dark), Contrast.shipped(pair.background, dark: dark))
        #expect(ratio >= 4.5, "\(pair.text) on \(pair.background) \(dark ? "Dark" : "Light"): \(ratio)")
    }

    /// 계산이 맞는지: 검정/흰색 21:1, 같은 색 1:1
    @Test func ratioSanity() {
        #expect(abs(Contrast.ratio(RGBA("#000000"), RGBA("#FFFFFF")) - 21) < 0.001)
        #expect(Contrast.ratio(RGBA("#636366"), RGBA("#636366")) == 1)
        #expect(Contrast.composite(RGBA("#00000014"), over: RGBA("#FFFFFF")) == RGBA("#EBEBEB"))
    }
}
