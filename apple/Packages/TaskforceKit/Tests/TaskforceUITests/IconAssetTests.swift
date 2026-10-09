import Foundation
import Testing
@testable import TaskforceUI
#if canImport(AppKit)
import AppKit
#endif

/// Lucide 아이콘 자산 (0.2.0 디자인 시스템 Iconography): 역할표의 글리프가 모두 있고, 표에 없는 자산이 남지 않는다.
struct IconAssetTests {
    static let iconFolder = TokenCatalog.sourceCatalog.appending(path: "icon", directoryHint: .isDirectory)

    /// 소스 카탈로그의 `icon/*.imageset` 이름
    static func sourceIconSets() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: iconFolder.path)) ?? []
        return Set(names.filter { $0.hasSuffix(".imageset") }.map { String($0.dropLast(".imageset".count)) })
    }

    /// 역할마다 다른 글리프 (한 글리프가 두 역할을 맡지 않는다)
    @Test func oneGlyphPerRole() {
        #expect(Set(TFIcon.allCases.map(\.rawValue)).count == TFIcon.allCases.count)
    }

    /// 카탈로그의 아이콘 = 역할표 (빠진 것도, 남는 것도 없다)
    @Test func catalogMatchesTheRoleTable() {
        #expect(Self.sourceIconSets() == Set(TFIcon.allCases.map(\.rawValue)))
    }

    /// 각 자산은 SVG 하나, 벡터 보존, template(색은 쓰는 쪽이 칠한다)
    @Test(arguments: TFIcon.allCases)
    func everyIconIsATemplateVector(_ icon: TFIcon) throws {
        let set = Self.iconFolder.appending(path: "\(icon.rawValue).imageset", directoryHint: .isDirectory)
        let data = try Data(contentsOf: set.appending(path: "Contents.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let images = try #require(json["images"] as? [[String: Any]])
        #expect(images.count == 1)
        #expect(images.first?["filename"] as? String == "\(icon.rawValue).svg")
        let properties = try #require(json["properties"] as? [String: Any])
        #expect(properties["template-rendering-intent"] as? String == "template")
        #expect(properties["preserves-vector-representation"] as? Bool == true)

        // lucide-react `size={16} strokeWidth={1.75}`와 같은 모양
        let svg = try String(contentsOf: set.appending(path: "\(icon.rawValue).svg"), encoding: .utf8)
        #expect(svg.contains(#"width="16" height="16" viewBox="0 0 24 24""#))
        #expect(svg.contains(#"stroke-width="1.75""#))
        #expect(svg.contains(#"fill="none""#))
    }

    /// 컴파일된 카탈로그(xcodebuild)에서는 actool이 SVG를 받아들여 이미지로 풀려야 한다
    @Test(arguments: TFIcon.allCases)
    func everyIconLoadsFromTheCompiledCatalog(_ icon: TFIcon) throws {
        guard TokenCatalog.isCompiled else { return }
        #if canImport(AppKit)
        let image = try #require(TFColor.bundle.image(forResource: icon.assetName), "\(icon.assetName)를 컴파일된 카탈로그에서 찾지 못함")
        #expect(image.size == NSSize(width: 16, height: 16))
        #endif
    }

    /// ISC 라이선스(일부 Feather MIT)를 자산과 함께 싣는다
    @Test func lucideLicenseShips() throws {
        let url = try #require(TFColor.bundle.url(forResource: "Lucide-LICENSE", withExtension: "txt"))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasPrefix("ISC License"))
        #expect(text.contains("Lucide Icons and Contributors"))
        #expect(text.contains("Cole Bemis"))
    }

    /// 닫기 버튼은 없다: `x`는 목록에서 항목 하나를 빼는 역할에만 있다
    @Test func xIsOnlyForRemovingAnItem() {
        #expect(TFIcon.allCases.filter { $0.rawValue == "x" } == [.removeItem])
    }
}
