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
        // 지난 · 오늘 기한: 목록 칸 · 상세 칸 · 설정 본문 (다크 #FF594F, 2026-10-03)
        ("status/overdue", "settings/sidebar"),
        ("status/overdue", "bg/elevated"),
        ("status/overdue", "settings/content"),
        ("text/link", "bg/elevated"),
        ("text/link", "settings/content"),
        ("source/text", "source/paper"),
        ("source/meta", "source/paper"),
        ("bg/canvas", "text/primary"),
        // iPhone 목록 (Figma P1 · P10): 바탕 bg/canvas 위 제목 · 섹션 개수 · 상태 줄 · 지난 · 오늘 기한, Review 카드의 Confirm
        ("text/primary", "bg/canvas"),
        ("text/secondary", "bg/canvas"),
        ("status/overdue", "bg/canvas"),
        ("text/inverse", "fill/inverse"),
    ], appearances)
    func baseText(_ pair: (text: String, background: String), _ dark: Bool) {
        let ratio = Contrast.ratio(Contrast.shipped(pair.text, dark: dark), Contrast.shipped(pair.background, dark: dark))
        #expect(ratio >= 4.5, "\(pair.text) on \(pair.background) \(dark ? "Dark" : "Light"): \(ratio)")
    }

    /// iPhone 할 일 행의 옅은 빈 원(누르면 Done): border/control을 `TaskRowMetrics.openMarkOpacity`로 bg/canvas 위에. 비문자 대비 3:1 (WCAG 1.4.11).
    /// Figma P1의 0.55는 Light 2.3:1 · Dark 2.8:1이라 올렸다
    @Test(arguments: appearances)
    func openTaskMark(_ dark: Bool) {
        let control = Contrast.shipped("border/control", dark: dark)
        let alpha = Int((TaskRowMetrics.openMarkOpacity * 255).rounded())
        let canvas = Contrast.shipped("bg/canvas", dark: dark)
        let mark = Contrast.composite(RGBA(r: control.r, g: control.g, b: control.b, a: alpha), over: canvas)
        let ratio = Contrast.ratio(mark, canvas)
        #expect(ratio >= 3, "open mark \(dark ? "Dark" : "Light"): \(ratio)")
    }

    /// U2 실행 부품의 글자 (U2 Mac 계획 PR2): 칩 글자 / fill/keycap, 갈래 제목 · 부제 · 폼 라벨 · 입력칸 자리 글 / bg/elevated(상세 칸 · 갈래 카드)
    @Test(arguments: [
        ("text/primary", "fill/keycap"),
        ("text/primary", "bg/elevated"),
        ("text/secondary", "bg/elevated"),
    ], appearances)
    func executionPartText(_ pair: (text: String, background: String), _ dark: Bool) {
        let ratio = Contrast.ratio(Contrast.shipped(pair.text, dark: dark), Contrast.shipped(pair.background, dark: dark))
        #expect(ratio >= 4.5, "\(pair.text) on \(pair.background) \(dark ? "Dark" : "Light"): \(ratio)")
    }

    /// 입력칸 경계 (`GrowingTextField`, 비문자 3:1, WCAG 1.4.11): 포커스 테두리 fill/accent, 포커스 없을 때 border/control.
    /// Figma의 border/default는 bg/elevated 위 Light 1.3:1이라 쓰지 않는다
    @Test(arguments: ["fill/accent", "border/control"], appearances)
    func textFieldBoundary(_ token: String, _ dark: Bool) {
        let ratio = Contrast.ratio(Contrast.shipped(token, dark: dark), Contrast.shipped("bg/elevated", dark: dark))
        #expect(ratio >= 3, "\(token) on bg/elevated \(dark ? "Dark" : "Light"): \(ratio)")
        #expect(Contrast.ratio(Contrast.shipped("border/default", dark: false), Contrast.shipped("bg/elevated", dark: false)) < 3)
    }

    /// 계산이 맞는지: 검정/흰색 21:1, 같은 색 1:1
    @Test func ratioSanity() {
        #expect(abs(Contrast.ratio(RGBA("#000000"), RGBA("#FFFFFF")) - 21) < 0.001)
        #expect(Contrast.ratio(RGBA("#636366"), RGBA("#636366")) == 1)
        #expect(Contrast.composite(RGBA("#00000014"), over: RGBA("#FFFFFF")) == RGBA("#EBEBEB"))
    }
}
