import Foundation
import Testing
@testable import TaskforceUI
#if canImport(AppKit)
import AppKit
#endif

/// sRGB 0–255 + 알파
struct RGBA: Equatable, CustomStringConvertible {
    let r: Int
    let g: Int
    let b: Int
    /// 0–255
    let a: Int

    init(r: Int, g: Int, b: Int, a: Int = 255) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// "#RRGGBB" · "#RRGGBBAA" (Figma 표기)
    init(_ hex: String) {
        let digits = Array(hex.dropFirst())
        func byte(_ i: Int) -> Int { Int(String(digits[i..<i + 2]), radix: 16)! }
        self.init(r: byte(0), g: byte(2), b: byte(4), a: digits.count == 8 ? byte(6) : 255)
    }

    var description: String {
        String(format: "#%02X%02X%02X", r, g, b) + (a == 255 ? "" : String(format: "%02X", a))
    }
}

/// Figma 변수 (jDMRGHWMRXeNUILfi11xvf, 컬렉션 Color, 모드 Light/Dark) — 2026-10-03 `use_figma`로 읽은 값
enum FigmaColor {
    static let values: [String: (light: String, dark: String)] = [
        "bg/canvas": ("#FFFFFF", "#000000"),
        "bg/surface": ("#F5F5F7", "#1C1C1E"),
        "bg/elevated": ("#FFFFFF", "#2C2C2E"),
        "bg/selected": ("#00000014", "#FFFFFF24"),
        "bg/glass": ("#FFFFFFC7", "#1E1E1ECC"),
        "bg/menu": ("#F6F6F6EB", "#2A2A2CF0"),
        "fill/accent": ("#4A6FA5", "#6A8CC7"),
        "fill/inverse": ("#1D1D1F", "#FFFFFF"),
        "fill/keycap": ("#EBEBF0", "#3A3A3C"),
        "fill/secondary": ("#FFFFFF", "#3A3A3C"),
        "text/primary": ("#1D1D1F", "#FFFFFF"),
        "text/secondary": ("#636366", "#9A9AA0"),
        "text/accent": ("#4A6FA5", "#6A8CC7"),
        "text/on-accent": ("#FFFFFF", "#FFFFFF"),
        "text/inverse": ("#FFFFFF", "#1D1D1F"),
        "text/link": ("#3F6199", "#7FA0D6"),
        "text/secondary-selected": ("#5A5A5E", "#ADADB2"),
        "status/overdue": ("#D70015", "#FF453A"),
        "status/overdue-selected": ("#BF0013", "#FF7A70"),
        "border/default": ("#E0E0E0", "#3A3A3C"),
        "border/control": ("#636366", "#9A9AA0"),
        "border/accent": ("#4A6FA5", "#6A8CC7"),
        "source/paper": ("#FCF9F4", "#2A2622"),
        "source/text": ("#1D1D1F", "#F2EEE8"),
        "source/meta": ("#67625B", "#A39C92"),
        "settings/window": ("#F7F7F7", "#1C1C1E"),
        "settings/sidebar": ("#FCFCFC", "#242426"),
        "settings/fill": ("#EBEBED", "#3A3A3C"),
        "settings/line": ("#ECECEC", "#38383A"),
        "settings/content": ("#FFFFFF", "#1C1C1E"),
    ]

    /// Figma 값이 선택 행(bg/selected 다크 흰색 14%) 위에서 4.5:1에 못 미쳐(ContrastTests) 앱만 밝힌 다크 값.
    /// 두 토큰은 Figma에서 "선택 행 위에서도 4.5:1"을 위해 만든 것이다. Figma를 고치면 이 표를 비운다.
    static let contrastAdjustedDark: [String: String] = [
        "text/secondary-selected": "#B9B9BE",
        "status/overdue-selected": "#FFA099",
    ]

    static func shipped(_ name: String) -> (light: RGBA, dark: RGBA)? {
        guard let figma = values[name] else { return nil }
        return (RGBA(figma.light), RGBA(contrastAdjustedDark[name] ?? figma.dark))
    }
}

/// 번들에 든 색 세트를 Light · Dark로 읽는다.
/// Xcode가 컴파일한 Asset Catalog(`Assets.car`)면 `NSColor(named:)`로만 읽는다 (actool이 받은 이름 · 값을 확인, CI `xcodebuild test -scheme TaskforceKit-Package`).
/// SwiftPM 명령행(`swift test`)은 카탈로그를 컴파일하지 않고 복사만 하므로 복사된 색 세트 JSON으로 읽는다.
enum TokenCatalog {
    /// 번들에 컴파일된 Asset Catalog가 있나 (Xcode 빌드)
    static var isCompiled: Bool {
        TFColor.bundle.url(forResource: "Assets", withExtension: "car") != nil
    }

    static var bundledCatalog: URL? {
        TFColor.bundle.resourceURL?.appending(path: "Tokens.xcassets", directoryHint: .isDirectory)
    }

    /// 소스의 Asset Catalog (남는 색 세트 확인용)
    static let sourceCatalog = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/TaskforceUI/Resources/Tokens.xcassets", directoryHint: .isDirectory)

    static func resolve(_ name: String) -> (light: RGBA, dark: RGBA)? {
        #if canImport(AppKit)
        if isCompiled {
            // 컴파일된 카탈로그에서 못 찾으면 JSON으로 돌아가지 않고 실패한다 (actool이 버린 색 세트를 놓치지 않게)
            guard let color = NSColor(named: name, bundle: TFColor.bundle) else { return nil }
            return (resolve(color, .aqua), resolve(color, .darkAqua))
        }
        #endif
        guard let catalog = bundledCatalog else { return nil }
        return parse(catalog.appending(path: "\(name).colorset/Contents.json"))
    }

    #if canImport(AppKit)
    private static func resolve(_ color: NSColor, _ appearance: NSAppearance.Name) -> RGBA {
        var rgba = RGBA(r: -1, g: -1, b: -1, a: -1)
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            guard let srgb = color.usingColorSpace(.sRGB) else { return }
            rgba = RGBA(
                r: Int((srgb.redComponent * 255).rounded()), g: Int((srgb.greenComponent * 255).rounded()),
                b: Int((srgb.blueComponent * 255).rounded()), a: Int((srgb.alphaComponent * 255).rounded())
            )
        }
        return rgba
    }
    #endif

    static func parse(_ url: URL) -> (light: RGBA, dark: RGBA)? {
        struct ColorSet: Decodable {
            struct Entry: Decodable {
                struct Appearance: Decodable {
                    let appearance: String
                    let value: String
                }
                struct Value: Decodable {
                    let components: [String: String]
                }
                let appearances: [Appearance]?
                let color: Value
            }
            let colors: [Entry]
        }
        guard let data = try? Data(contentsOf: url), let set = try? JSONDecoder().decode(ColorSet.self, from: data) else { return nil }
        func rgba(_ entry: ColorSet.Entry) -> RGBA? {
            func channel(_ key: String) -> Int? {
                guard let raw = entry.color.components[key] else { return nil }
                if raw.hasPrefix("0x") { return Int(raw.dropFirst(2), radix: 16) }
                return Double(raw).map { Int(($0 <= 1 ? $0 * 255 : $0).rounded()) }
            }
            guard let r = channel("red"), let g = channel("green"), let b = channel("blue"), let a = channel("alpha") else { return nil }
            return RGBA(r: r, g: g, b: b, a: a)
        }
        let light = set.colors.first { $0.appearances == nil }.flatMap(rgba)
        let dark = set.colors.first { $0.appearances?.contains { $0.appearance == "luminosity" && $0.value == "dark" } == true }.flatMap(rgba)
        guard let light, let dark else { return nil }
        return (light, dark)
    }

    /// 소스 카탈로그의 모든 색 세트 이름 ("bg/canvas")
    static func sourceColorSets() -> Set<String> {
        let enumerator = FileManager.default.enumerator(at: sourceCatalog, includingPropertiesForKeys: nil)
        var names = Set<String>()
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "colorset" else { continue }
            let relative = url.path.replacingOccurrences(of: sourceCatalog.path + "/", with: "")
            names.insert(String(relative.dropLast(".colorset".count)))
        }
        return names
    }
}

struct ColorTokenTests {
    /// 모든 `TFColor` 토큰이 번들에서 Light · Dark로 풀린다
    @Test(arguments: TFColor.Name.allCases)
    func everyTokenResolvesInBothAppearances(_ name: TFColor.Name) throws {
        let resolved = try #require(TokenCatalog.resolve(name.rawValue), "\(name.rawValue) 색 세트를 번들에서 찾지 못함")
        let expected = try #require(FigmaColor.shipped(name.rawValue), "\(name.rawValue)의 Figma 값이 표에 없음")
        #expect(resolved.light == expected.light, "\(name.rawValue) Light")
        #expect(resolved.dark == expected.dark, "\(name.rawValue) Dark")
    }

    /// CI의 xcodebuild 단계는 `TF_REQUIRE_COMPILED_CATALOG=1`로 돌린다: 그때는 actool이 컴파일한 카탈로그(`NSColor(named:)`)로 읽었어야 한다.
    /// `swift test`(카탈로그를 복사만 함)에서는 이 값이 없어 JSON으로 읽는다.
    @Test func compiledCatalogWhenRequired() {
        guard ProcessInfo.processInfo.environment["TF_REQUIRE_COMPILED_CATALOG"] == "1" else { return }
        #expect(TokenCatalog.isCompiled, "Assets.car가 없다: 색 토큰을 컴파일된 카탈로그로 확인하지 못함")
    }

    /// 토큰 표와 Figma 변수 표가 같은 이름을 다룬다 (Figma 변수가 빠지거나 남지 않게)
    @Test func tokenNamesMatchTheFigmaTable() {
        #expect(Set(TFColor.Name.allCases.map(\.rawValue)) == Set(FigmaColor.values.keys))
    }

    /// 카탈로그에 토큰이 아닌 색 세트가 남아 있지 않다
    @Test func catalogHasNoOrphanColorSets() {
        #expect(TokenCatalog.sourceColorSets() == Set(TFColor.Name.allCases.map(\.rawValue)))
    }

    /// 선택 면은 Figma 변수 그대로: 라이트 검정 8% · 다크 흰색 14% (청색 아님)
    @Test func selectionIsTranslucentGray() throws {
        let selected = try #require(TokenCatalog.resolve("bg/selected"))
        #expect(selected.light == RGBA(r: 0, g: 0, b: 0, a: 20))
        #expect(selected.dark == RGBA(r: 255, g: 255, b: 255, a: 36))
    }

    /// 앱만 밝힌 값은 Figma 값이 실제로 4.5:1에 못 미칠 때만 둔다
    @Test(arguments: Array(FigmaColor.contrastAdjustedDark.keys))
    func adjustmentsOnlyWhereFigmaFails(_ name: String) throws {
        let figma = try #require(FigmaColor.values[name])
        let worst = Contrast.worstOnSelection(RGBA(figma.dark), dark: true)
        #expect(worst < 4.5, "\(name) Figma 다크 값이 이미 \(worst):1 — 조정 표에서 뺀다")
    }
}
