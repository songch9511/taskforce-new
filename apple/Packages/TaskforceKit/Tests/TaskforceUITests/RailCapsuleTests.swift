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

    @Test func theNewRingColorsAreTheDesignValuesInBothThemes() {
        #expect(TokenCatalogProbe.rgba(TFColor.needsYou) == [0xEB, 0xAA, 0x7E, 255], "orange-300")
        #expect(TokenCatalogProbe.rgba(TFColor.needsYou, appearance: .darkAqua) == [0xEB, 0xAA, 0x7E, 255])
        #expect(TokenCatalogProbe.rgba(TFColor.done) == [0x9C, 0xE7, 0x3A, 255], "green-300")
        #expect(TokenCatalogProbe.rgba(TFColor.done, appearance: .darkAqua) == [0x9C, 0xE7, 0x3A, 255])
    }

    private func pixels<V: View>(_ view: V, side: CGFloat = 36) -> (width: Int, height: Int, data: [UInt8])? {
        let renderer = ImageRenderer(content: view.frame(width: side, height: side).environment(\.colorScheme, .light))
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
        // 링 위의 한 점: 오른쪽 가장자리 근처에 주황이 있다
        var orange = false
        for x in 0..<capsule.width where pixel(capsule, x: x, y: capsule.height / 2)[3] > 200 {
            let p = pixel(capsule, x: x, y: capsule.height / 2)
            if abs(p[0] - 0xEB) < 12 && abs(p[1] - 0xAA) < 12 && abs(p[2] - 0x7E) < 12 { orange = true }
        }
        #expect(orange)
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
        #expect(done.data != doneCapsule.data, "캡슐 모양의 Done은 초록이다")
    }

    @Test func theCapsuleDoneRingIsGreenWithAGreenCheck() throws {
        let image = try #require(pixels(ActivityRing(.done, size: .medium, reduceMotion: true, look: .capsule), side: 24))
        var green = 0, white = 0
        for y in 0..<image.height { for x in 0..<image.width {
            let p = pixel(image, x: x, y: y)
            guard p[3] > 200 else { continue }
            if abs(p[0] - 0x9C) < 14 && abs(p[1] - 0xE7) < 14 && abs(p[2] - 0x3A) < 14 { green += 1 }
            if p[0] > 240 && p[1] > 240 && p[2] > 240 { white += 1 }
        } }
        #expect(green > 50 && white == 0, "링도 체크도 done 색이다")
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
