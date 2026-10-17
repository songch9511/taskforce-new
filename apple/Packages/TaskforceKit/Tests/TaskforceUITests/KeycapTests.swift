import CoreText
import Foundation
import SwiftUI
import Testing
@testable import TaskforceUI

/// Keycap (DS Atoms, OA D4b-m-1): IBM Plex Mono 11px on `fill/keycap`, 18 × 18. 글꼴과 OFL 라이선스 파일 · 출처 기록은 이 모듈이 번들한다
struct KeycapTests {
    @Test func theDesignValuesAreElevenPointMonoAtEighteenSquare() {
        #expect(KeycapStyle.fontSize == 11 && KeycapStyle.minSize == 18 && KeycapStyle.horizontalPadding == 4)
        #expect(KeycapStyle.fontName == "IBMPlexMono-Regular" && KeycapStyle.familyName == "IBM Plex Mono")
    }

    @Test func theBundledFontIsRegisteredAndIsAnActualMonospacedPlexMono() throws {
        #expect(KeycapStyle.isFontAvailable, "번들한 글꼴이 올라갔다")
        let font = CTFontCreateWithName(KeycapStyle.fontName as CFString, KeycapStyle.fontSize, nil)
        #expect((CTFontCopyFamilyName(font) as String) == "IBM Plex Mono" && CTFontGetSize(font) == 11)
        #expect(CTFontGetSymbolicTraits(font).contains(.traitMonoSpace), "고정폭")
        // 숫자 폭이 모두 같다 (1–4)
        var characters = Array("1234".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: 4)
        #expect(CTFontGetGlyphsForCharacters(font, &characters, &glyphs, 4))
        var advances = [CGSize](repeating: .zero, count: 4)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, 4)
        #expect(Set(advances.map(\.width)).count == 1 && advances[0].width > 0)
    }

    @Test func theLicenseAndTheSourceRecordTravelWithTheFont() throws {
        let license = try #require(KeycapStyle.bundledURL(KeycapStyle.licenseFile, "txt"))
        let text = try String(contentsOf: license, encoding: .utf8)
        #expect(text.contains("SIL OPEN FONT LICENSE Version 1.1") && text.contains("IBM Corp."), "OFL 1.1 본문을 고치지 않고 함께 둔다")
        let source = try String(contentsOf: try #require(KeycapStyle.bundledURL(KeycapStyle.sourceFile, "txt")), encoding: .utf8)
        #expect(source.contains("@fontsource/ibm-plex-mono 5.3.0") && source.contains("01ca071138ce13e1a4e66adeda1de97cdb5f8d55a273cbd2365b60b497a5a05c"), "출처 · 해시를 적는다")
        #expect(KeycapStyle.bundledURL(KeycapStyle.fontFile, "ttf") != nil)
    }

    @Test func thisModuleBundlesOnlyTheRegularWeightUsedByTheKeycap() throws {
        let urls = (Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []) + (Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? [])
        #expect(urls.map(\.lastPathComponent) == ["IBMPlexMono-Regular.ttf"])
    }
}
