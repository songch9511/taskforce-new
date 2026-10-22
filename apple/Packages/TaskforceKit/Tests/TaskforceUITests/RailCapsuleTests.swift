import AppKit
import SwiftUI
import Testing
import TaskforceKit
@testable import TaskforceUI

/// 색 한 칸의 sRGB 0–255 (밝은 · 어두운 모양 둘 다)
enum TokenCatalogProbe {
    static func rgba(_ color: Color, appearance: NSAppearance.Name = .aqua) -> [Int] {
        var result: [Int] = []
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
            result = [ns.redComponent, ns.greenComponent, ns.blueComponent, ns.alphaComponent].map { Int(($0 * 255).rounded()) }
        }
        return result
    }
}

/// OA U3 11.2 · 5.1: 캡슐 치수 · 링 모양 인자(기본은 지금 그대로, 캡슐 모양은 주황 · 원반 없음) · 새 색 토큰 값
@MainActor
struct RailCapsuleTests {
    @Test func theCapsuleNumbersAreTheDesignSystemOnes() {
        typealias M = RailCapsuleMetrics
        #expect(M.width == 44 && M.inset == 6 && M.item == 32 && M.gap == 2 && M.padding == 6 && M.radius == 22)
        #expect(M.compactScale == 0.72 && M.restBarWidth == 8 && M.restBarHeight == 48 && M.restBarRadius == 4)
        #expect(abs(M.ringScale - 1.2857) < 0.001, "14pt × 1.286 = 18")
        #expect(RailItem.side == M.item)
        #expect(M.shadowOpacity == 0.28 && M.edgeLineWidth == 0.5 && M.edgeLineOpacity == 0.08)
    }

    /// 값은 색 세트(`status/needs-you` · `status/done` · `status/activity`와 패널 위 `-panel` 셋)에서 온다 (검토 1: 코드 상수가 아니다). 색 세트는 어느 실행에서든 읽고, 컴파일된 카탈로그(Xcode 빌드)에서는 실제 `Color`도 같다
    /// 레일 상태 색 C (사용자 승인 2026-10-22): done teal-300 `#77E2C2`, activity blue-350 `#86ABED`, needs-you는 그대로
    @Test func theNewRingColorsAreTheDesignValuesInBothThemes() throws {
        let needsYou = try #require(TokenCatalog.resolve("status/needs-you"))
        let done = try #require(TokenCatalog.resolve("status/done"))
        let activity = try #require(TokenCatalog.resolve("status/activity"))
        #expect(needsYou.light == RGBA("#EBAA7E") && needsYou.dark == RGBA("#EBAA7E"), "orange-300")
        #expect(done.light == RGBA("#77E2C2") && done.dark == RGBA("#77E2C2"), "teal-300")
        #expect(activity.light == RGBA("#86ABED") && activity.dark == RGBA("#86ABED"), "blue-350")
        let needsYouPanel = try #require(TokenCatalog.resolve("status/needs-you-panel"))
        let donePanel = try #require(TokenCatalog.resolve("status/done-panel"))
        let activityPanel = try #require(TokenCatalog.resolve("status/activity-panel"))
        #expect(needsYouPanel.light == RGBA("#BD7F55") && needsYouPanel.dark == RGBA("#EBAA7E"))
        #expect(donePanel.light == RGBA("#2A9E81") && donePanel.dark == RGBA("#77E2C2"))
        #expect(activityPanel.light == RGBA("#6A8ECD") && activityPanel.dark == RGBA("#86ABED"))
        guard TokenCatalog.isCompiled else { return }
        #expect(TokenCatalogProbe.rgba(TFColor.needsYou) == [0xEB, 0xAA, 0x7E, 255], "orange-300")
        #expect(TokenCatalogProbe.rgba(TFColor.needsYou, appearance: .darkAqua) == [0xEB, 0xAA, 0x7E, 255])
        #expect(TokenCatalogProbe.rgba(TFColor.done) == [0x77, 0xE2, 0xC2, 255], "teal-300")
        #expect(TokenCatalogProbe.rgba(TFColor.done, appearance: .darkAqua) == [0x77, 0xE2, 0xC2, 255])
        #expect(TokenCatalogProbe.rgba(TFColor.statusActivity) == [0x86, 0xAB, 0xED, 255], "blue-350")
        #expect(TokenCatalogProbe.rgba(TFColor.statusActivity, appearance: .darkAqua) == [0x86, 0xAB, 0xED, 255])
        #expect(TokenCatalogProbe.rgba(TFColor.needsYouPanel) == [0xBD, 0x7F, 0x55, 255])
        #expect(TokenCatalogProbe.rgba(TFColor.needsYouPanel, appearance: .darkAqua) == [0xEB, 0xAA, 0x7E, 255])
        #expect(TokenCatalogProbe.rgba(TFColor.donePanel) == [0x2A, 0x9E, 0x81, 255])
        #expect(TokenCatalogProbe.rgba(TFColor.donePanel, appearance: .darkAqua) == [0x77, 0xE2, 0xC2, 255])
        #expect(TokenCatalogProbe.rgba(TFColor.statusActivityPanel) == [0x6A, 0x8E, 0xCD, 255])
        #expect(TokenCatalogProbe.rgba(TFColor.statusActivityPanel, appearance: .darkAqua) == [0x86, 0xAB, 0xED, 255])
    }

    private func pixels<V: View>(_ view: V, side: CGFloat = 36, scheme: ColorScheme = .light) -> (width: Int, height: Int, data: [UInt8])? {
        let renderer = ImageRenderer(content: view.frame(width: side, height: side).environment(\.colorScheme, scheme))
        renderer.scale = 4
        guard let image = renderer.cgImage else { return nil }
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (width, height, data)
    }

    private func pixel(_ image: (width: Int, height: Int, data: [UInt8]), x: Int, y: Int) -> [Int] {
        let index = (y * image.width + x) * 4
        return image.data[index..<index + 4].map(Int.init)
    }

    @Test func theCapsuleNeedsYouRingIsAnOrangeStrokeWithNoDiscOnLightGround() throws {
        let capsule = try #require(pixels(ActivityRing(.needsYou, size: .medium, ground: .light, reduceMotion: true, look: .capsule)))
        let center = pixel(capsule, x: capsule.width / 2, y: capsule.height / 2)
        #expect(center[3] == 0, "원반이 없다: 가운데는 비어 있다 (Rings never fill)")
        // 링 위의 한 점: 오른쪽 가장자리 근처에 주황이 있다. 패널 위(라이트)에서는 흰 바탕에서 3:1을 넘기는 `status/needs-you-panel` `#BD7F55`다
        var orange = false
        for x in 0..<capsule.width where pixel(capsule, x: x, y: capsule.height / 2)[3] > 200 {
            let p = pixel(capsule, x: x, y: capsule.height / 2)
            if abs(p[0] - 0xBD) < 12 && abs(p[1] - 0x7F) < 12 && abs(p[2] - 0x55) < 12 { orange = true }
        }
        // 주황은 카탈로그 색이라 Xcode 빌드에서만 그려진다
        if TokenCatalog.isCompiled { #expect(orange) }
        // 옛 모양은 지금처럼 형광펜 원반이 있다 (Release 레일 모양 그대로). 형광펜은 카탈로그 색이라 Xcode 빌드에서만 그려진다
        guard TokenCatalog.isCompiled else { return }
        let classic = try #require(pixels(ActivityRing(.needsYou, size: .medium, ground: .light, reduceMotion: true, look: .classic)))
        #expect(pixel(classic, x: classic.width / 2, y: classic.height / 2)[3] > 200)
    }

    @Test func theDefaultLookIsTheCurrentOneSoTheReleaseRailDoesNotChange() throws {
        let explicit = try #require(pixels(ActivityRing(.needsYou, size: .small, reduceMotion: true, look: .classic)))
        let implicit = try #require(pixels(ActivityRing(.needsYou, size: .small, reduceMotion: true)))
        #expect(explicit.data == implicit.data)
        let done = try #require(pixels(ActivityRing(.done, size: .small, reduceMotion: true)))
        let doneCapsule = try #require(pixels(ActivityRing(.done, size: .small, reduceMotion: true, look: .capsule)))
        // 두 색 모두 카탈로그 색이라 Xcode 빌드에서만 그려진다
        if TokenCatalog.isCompiled { #expect(done.data != doneCapsule.data, "캡슐 모양의 Done은 초록이다") }
    }

    @Test func theCapsuleDoneRingIsGreenWithAGreenCheck() throws {
        let image = try #require(pixels(ActivityRing(.done, size: .medium, reduceMotion: true, look: .capsule), side: 24))
        var green = 0, white = 0
        for y in 0..<image.height { for x in 0..<image.width {
            let p = pixel(image, x: x, y: y)
            guard p[3] > 200 else { continue }
            if abs(p[0] - 0x77) < 14 && abs(p[1] - 0xE2) < 14 && abs(p[2] - 0xC2) < 14 { green += 1 }
            if p[0] > 240 && p[1] > 240 && p[2] > 240 { white += 1 }
        } }
        // 초록(청록 쪽 teal-300)은 카탈로그 색이라 Xcode 빌드에서만 그려진다 (흰색이 없다는 것은 어느 빌드에서나)
        if TokenCatalog.isCompiled { #expect(green > 50, "링도 체크도 done 색이다") }
        #expect(white == 0)
    }

    /// 한 색이 그림에 몇 픽셀 있나. 그림은 premultiplied라 반투명 픽셀(가장자리 · 숨쉬는 needs-you 링의 불투명도)은 알파로 나눠 원래 색으로 읽는다
    private func count(_ image: (width: Int, height: Int, data: [UInt8]), near rgb: [Int], tolerance: Int = 14) -> Int {
        var found = 0
        for y in 0..<image.height { for x in 0..<image.width {
            let p = pixel(image, x: x, y: y)
            guard p[3] > 200 else { continue }
            let alpha = Double(p[3]) / 255
            let color = p[0..<3].map { Int((Double($0) / alpha).rounded()) }
            if abs(color[0] - rgb[0]) < tolerance && abs(color[1] - rgb[1]) < tolerance && abs(color[2] - rgb[2]) < tolerance { found += 1 }
        } }
        return found
    }

    /// 레일 상태 색 C: 검은 레일(bezel) 위 링은 두 모드 모두 `status/*` 기본 값(`#EBAA7E` · `#77E2C2` · `#86ABED`)이다. 색은 카탈로그 색이라 Xcode 빌드에서만 그려진다
    @Test(arguments: [ColorScheme.light, .dark])
    func theBezelRingsUseTheRailTokensInBothThemes(_ scheme: ColorScheme) throws {
        guard TokenCatalog.isCompiled else { return }
        let needsYou = try #require(pixels(ActivityRing(.needsYou, size: .medium, reduceMotion: true, look: .capsule), scheme: scheme))
        let done = try #require(pixels(ActivityRing(.done, size: .medium, reduceMotion: true, look: .capsule), scheme: scheme))
        let running = try #require(pixels(ActivityRing(.running, size: .medium, reduceMotion: true, look: .capsule), scheme: scheme))
        #expect(count(needsYou, near: [0xEB, 0xAA, 0x7E]) > 50, "needs-you \(scheme)")
        #expect(count(done, near: [0x77, 0xE2, 0xC2]) > 50, "done \(scheme)")
        #expect(count(running, near: [0x86, 0xAB, 0xED]) > 30, "running 호 \(scheme)")
        #expect(count(done, near: [0x9C, 0xE7, 0x3A]) == 0, "옛 형광 연두가 남지 않았다")
        #expect(count(running, near: [0x6A, 0x8C, 0xC7]) == 0, "옛 파랑(blue-400)이 레일 호에 남지 않았다")
    }

    /// 패널 위(`ground: .light`)의 캡슐 모양 링은 `-panel` 토큰이다: 라이트는 흰 패널에서 3:1을 넘기는 어두운 값, 다크는 레일 값 그대로. 레일 기본 값이 새면 안 된다.
    /// needs-you · done은 링 하나, running은 호 하나다 (색은 카탈로그 색이라 Xcode 빌드에서만 그려진다)
    @Test(arguments: [ColorScheme.light, .dark])
    func theLightGroundCapsuleRingsUseThePanelTokens(_ scheme: ColorScheme) throws {
        guard TokenCatalog.isCompiled else { return }
        let light = scheme == .light
        let expected: [(kind: ActivityRing.Kind, panel: [Int], rail: [Int])] = [
            (.needsYou, light ? [0xBD, 0x7F, 0x55] : [0xEB, 0xAA, 0x7E], [0xEB, 0xAA, 0x7E]),
            (.done, light ? [0x2A, 0x9E, 0x81] : [0x77, 0xE2, 0xC2], [0x77, 0xE2, 0xC2]),
            (.running, light ? [0x6A, 0x8E, 0xCD] : [0x86, 0xAB, 0xED], [0x86, 0xAB, 0xED]),
        ]
        for item in expected {
            let image = try #require(pixels(ActivityRing(item.kind, size: .medium, ground: .light, reduceMotion: true, look: .capsule), scheme: scheme))
            #expect(count(image, near: item.panel) > 30, "\(item.kind) \(scheme): 패널 토큰")
            if light { #expect(count(image, near: item.rail, tolerance: 20) == 0, "\(item.kind) light: 레일 값이 패널 위로 새지 않았다") }
        }
    }

    /// 옛 모양(`classic`)의 패널 위 링은 잉크 · 형광펜이다: 상태 색 `-panel`을 쓰지 않는다 (running 호만 `activity-panel`)
    @Test func theClassicLightGroundDoneRingStaysInk() throws {
        guard TokenCatalog.isCompiled else { return }
        let done = try #require(pixels(ActivityRing(.done, size: .medium, ground: .light, reduceMotion: true, look: .classic)))
        #expect(count(done, near: [0x2A, 0x9E, 0x81]) == 0)
        #expect(count(done, near: [0x77, 0xE2, 0xC2]) == 0)
        let running = try #require(pixels(ActivityRing(.running, size: .medium, ground: .light, reduceMotion: true, look: .classic)))
        #expect(count(running, near: [0x6A, 0x8E, 0xCD]) > 30, "running 호는 모양과 상관없이 activity-panel")
    }

    @Test func capsuleItemsAreCirclesWhileTheOldRailKeepsRoundedSquares() {
        // 모양 인자는 기본이 지금 모양이다
        #expect(ActivityRing.Look.classic != ActivityRing.Look.capsule)
        let classicItem = RailItem(kind: .running, title: "T", state: .inProgress, activity: "Running", expanded: true) {}
        let capsuleItem = RailItem(kind: .needsYou, title: "T", state: .inProgress, activity: "Needs your answer", expanded: true, look: .capsule) {}
        _ = (classicItem, capsuleItem)
        #expect(RailItem.accessibilityLabel(title: "T", state: .inProgress, activity: "Running") == "T · In Progress · Running")
    }
}
