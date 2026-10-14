import Foundation
import Testing
@testable import Taskforce

/// Sparkle 의존성 · 설정값 · 앱 연결 (OA M1b U3 · U4). 소스의 프로젝트 파일을 읽는 시험이라 전체 체크아웃에서만 돈다
/// (`MacEntitlementsTests`와 같은 방식). 서명 · 공증된 빌드에서 실제로 업데이트가 되는지는 확인하지 않는다.
enum UpdaterSources {
    static let apple = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    static func text(_ path: String) throws -> String {
        try String(contentsOf: apple.appending(path: path), encoding: .utf8)
    }

    /// 앱 소스(`Taskforce/**/*.swift`)의 (apple 기준 상대 경로, 내용)
    static func appSwiftSources() throws -> [(path: String, text: String)] {
        guard let enumerator = FileManager.default.enumerator(at: apple.appending(path: "Taskforce"), includingPropertiesForKeys: nil) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var files: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append((String(url.path.dropFirst(apple.path.count + 1)), try String(contentsOf: url, encoding: .utf8)))
        }
        return files
    }

    /// 생성된 project.pbxproj (옛 방식 plist라 PropertyListSerialization이 읽는다)의 `objects`
    static func pbxObjects() throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: apple.appending(path: "Taskforce.xcodeproj/project.pbxproj"))
        guard let root = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let objects = root["objects"] as? [String: [String: Any]] else { throw CocoaError(.propertyListReadCorrupt) }
        return objects
    }

    static func sparkleReferences(_ objects: [String: [String: Any]]) -> [(id: String, object: [String: Any])] {
        objects.compactMap { id, object in
            guard object["isa"] as? String == "XCRemoteSwiftPackageReference",
                  (object["repositoryURL"] as? String)?.lowercased().contains("sparkle-project/sparkle") == true else { return nil }
            return (id, object)
        }
    }

    /// xcconfig · project.yml에서 `이름 = 값`(또는 `이름: 값`) 줄의 값. 주석 줄(`//` · `#`)은 보지 않는다. 없으면 nil
    static func assignment(_ name: String, in text: String) -> String? {
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") || line.hasPrefix("#") { continue }
            for separator in ["=", ":"] where line.hasPrefix(name) {
                let rest = line.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix(separator) { return rest.dropFirst().trimmingCharacters(in: .whitespaces) }
            }
        }
        return nil
    }
}

struct UpdaterBuildSettingsTests {
    // MARK: U3 — 설정값은 빌드 설정에서 Info.plist로

    @Test func theInfoPlistTakesBothKeysFromBuildSettings() throws {
        let data = try Data(contentsOf: UpdaterSources.apple.appending(path: "Taskforce/Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
        #expect(plist["SUFeedURL"] as? String == "$(SPARKLE_FEED_URL)")
        #expect(plist["SUPublicEDKey"] as? String == "$(SPARKLE_PUBLIC_ED_KEY)")
    }

    /// Debug · Debug-Test(Base를 쓴다)는 빈 값. 출시 전 채우는 값은 Release.xcconfig에만 둔다
    @Test func debugConfigurationsLeaveBothValuesEmpty() throws {
        let base = try UpdaterSources.text("Config/Base.xcconfig")
        #expect(UpdaterSources.assignment("SPARKLE_FEED_URL", in: base) == "")
        #expect(UpdaterSources.assignment("SPARKLE_PUBLIC_ED_KEY", in: base) == "")
        let debugTest = try UpdaterSources.text("Config/DebugTest.xcconfig")
        #expect(UpdaterSources.assignment("SPARKLE_FEED_URL", in: debugTest) == nil, "Debug-Test는 Base 값을 그대로 쓴다")
        #expect(UpdaterSources.assignment("SPARKLE_PUBLIC_ED_KEY", in: debugTest) == nil)
    }

    /// 값은 사용자가 정한다: 여기서는 두 변수가 Release.xcconfig에 자리가 있는지만 본다 (채워도 이 시험은 통과한다)
    @Test func theReleaseConfigurationHasASlotForBothValues() throws {
        let release = try UpdaterSources.text("Config/Release.xcconfig")
        #expect(UpdaterSources.assignment("SPARKLE_FEED_URL", in: release) != nil)
        #expect(UpdaterSources.assignment("SPARKLE_PUBLIC_ED_KEY", in: release) != nil)
    }

    /// 지금 이 시험 호스트(Debug-Test)가 만든 Info.plist: 키는 있고 값은 비어 있다
    @Test func theBuiltDebugHostCarriesBothKeysEmpty() throws {
        let info = try #require(Bundle.main.infoDictionary)
        #expect(info["SUFeedURL"] as? String == "")
        #expect(info["SUPublicEDKey"] as? String == "")
    }

    /// 자동 확인은 Sparkle 기본 동작(두 번째 실행에서 사용자에게 묻는다)을 따른다: 설정 화면도 기본값을 바꾸는 키도 없다
    @Test func automaticCheckingKeepsSparkleDefaults() throws {
        let plist = try UpdaterSources.text("Taskforce/Info.plist")
        for key in ["SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUAllowsAutomaticUpdates", "SUScheduledCheckInterval", "SUEnableSystemProfiling"] {
            #expect(!plist.contains(key), "Info.plist에 \(key)")
        }
        for (path, text) in try UpdaterSources.appSwiftSources() {
            for name in ["automaticallyChecksForUpdates", "automaticallyDownloadsUpdates", "updateCheckInterval"] {
                #expect(!text.contains(name), "\(path)에 \(name)")
            }
        }
    }

    // MARK: U4 — 의존성: Mac 앱 타깃에만, 정확한 버전 하나

    @Test func sparkleIsPinnedToOneExactVersionEverywhere() throws {
        let objects = try UpdaterSources.pbxObjects()
        let references = UpdaterSources.sparkleReferences(objects)
        try #require(references.count == 1)
        let requirement = try #require(references[0].object["requirement"] as? [String: Any])
        #expect(requirement["kind"] as? String == "exactVersion")
        let version = try #require(requirement["version"] as? String)
        #expect(version.range(of: #"^2\.\d+\.\d+$"#, options: .regularExpression) != nil, "정식 2.x만 (범위 · 베타 금지): \(version)")

        // project.yml (생성의 원본)
        let yml = try UpdaterSources.text("project.yml")
        let lines = yml.components(separatedBy: "\n")
        let start = try #require(lines.firstIndex { $0.hasPrefix("  Sparkle:") })
        let block = lines[(start + 1)...].prefix { $0.hasPrefix("    ") || $0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n")
        #expect(UpdaterSources.assignment("exactVersion", in: block) == version)
        #expect(UpdaterSources.assignment("url", in: block)?.lowercased().contains("sparkle-project/sparkle") == true)
        for loose in ["from:", "branch:", "revision:", "minVersion", "maxVersion", "majorVersion", "minorVersion"] {
            #expect(!block.contains(loose), "범위 · 브랜치 금지: \(loose)")
        }

        // Package.resolved (커밋된 고정)
        let resolvedData = try Data(contentsOf: UpdaterSources.apple.appending(path: "Taskforce.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"))
        let resolved = try #require(try JSONSerialization.jsonObject(with: resolvedData) as? [String: Any])
        let pins = try #require(resolved["pins"] as? [[String: Any]])
        let sparkle = pins.filter { ($0["identity"] as? String)?.lowercased() == "sparkle" }
        try #require(sparkle.count == 1)
        let state = try #require(sparkle[0]["state"] as? [String: Any])
        #expect(state["version"] as? String == version)
        #expect((state["revision"] as? String)?.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil)
    }

    @Test func onlyTheMacAppTargetLinksSparkle() throws {
        let objects = try UpdaterSources.pbxObjects()
        let references = Set(UpdaterSources.sparkleReferences(objects).map(\.id))
        let sparkleProducts = Set(objects.compactMap { id, object -> String? in
            guard object["isa"] as? String == "XCSwiftPackageProductDependency", let package = object["package"] as? String, references.contains(package) else { return nil }
            return id
        })
        try #require(!sparkleProducts.isEmpty)
        let linking = objects.values.compactMap { object -> String? in
            guard object["isa"] as? String == "PBXNativeTarget",
                  let dependencies = object["packageProductDependencies"] as? [String],
                  !sparkleProducts.isDisjoint(with: dependencies) else { return nil }
            return object["name"] as? String
        }
        #expect(linking == ["Taskforce"])
    }

    @Test func taskforceKitDoesNotKnowSparkle() throws {
        for file in ["Packages/TaskforceKit/Package.swift", "Packages/TaskforceKit/Package.resolved"] {
            #expect(!(try UpdaterSources.text(file)).lowercased().contains("sparkle"), "\(file)")
        }
        for (path, text) in try UpdaterSources.appSwiftSources() where text.contains("import Sparkle") {
            #expect(path == "Taskforce/Mac/AppUpdater.swift", "Sparkle은 한 파일에서만 import한다")
        }
        let kitSources = UpdaterSources.apple.appending(path: "Packages/TaskforceKit/Sources")
        let enumerator = try #require(FileManager.default.enumerator(at: kitSources, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            #expect(!(try String(contentsOf: url, encoding: .utf8)).contains("import Sparkle"), "\(url.lastPathComponent)")
        }
    }

    /// 앱 번들에 Sparkle.framework가 들어 있다 (시험 호스트 = 빌드된 앱)
    @Test func theBuiltAppEmbedsTheFramework() throws {
        let framework = try #require(Bundle.main.privateFrameworksURL).appending(path: "Sparkle.framework")
        #expect(FileManager.default.fileExists(atPath: framework.path))
    }
}

/// 앱 연결: 업데이터 하나 · 메뉴 항목 · 시작 위치 · 종료 위임 지점 (소스 검사)
struct UpdaterWiringTests {
    static func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    @Test func oneUpdaterControllerForTheWholeApp() throws {
        var total = 0
        for (path, text) in try UpdaterSources.appSwiftSources() {
            let count = Self.occurrences(of: "SPUStandardUpdaterController(", in: text)
            total += count
            if count > 0 { #expect(path == "Taskforce/Mac/AppUpdater.swift") }
        }
        #expect(total == 1)
    }

    /// 표준 문구 "Check for Updates…" (줄임표는 U+2026 한 글자)가 한 곳에만 있고, 메뉴 막대 메뉴와 앱 메뉴(Settings 창이 앞일 때)가 그 버튼을 쓴다
    @Test func theStandardMenuItemIsInTheMenuBarMenuAndTheAppMenu() throws {
        var labels = 0
        for (_, text) in try UpdaterSources.appSwiftSources() { labels += Self.occurrences(of: "Button(\"Check for Updates\u{2026}\"", in: text) }
        #expect(labels == 1)
        let delegate = try UpdaterSources.text("Taskforce/Mac/MacAppDelegate.swift")
        let menu = try #require(delegate.components(separatedBy: "struct MenuBarMenu: View {").last?.components(separatedBy: "struct MenuBarLabel").first)
        #expect(menu.contains("CheckForUpdatesButton()"))
        let app = try UpdaterSources.text("Taskforce/TaskforceApp.swift")
        #expect(app.contains("CommandGroup(after: .appInfo)") && app.contains("CheckForUpdatesButton()"))
    }

    /// 시작은 시험 호스트 가드(`guard !TestHost.isTestHost()`) 뒤에서 한 번
    @Test func theUpdaterStartsOnceAfterTheTestHostGuard() throws {
        let delegate = try UpdaterSources.text("Taskforce/Mac/MacAppDelegate.swift")
        #expect(Self.occurrences(of: "AppUpdater.shared.start()", in: delegate) == 1)
        let guardRange = try #require(delegate.range(of: "guard !TestHost.isTestHost() else { return }"))
        let startRange = try #require(delegate.range(of: "AppUpdater.shared.start()"))
        #expect(guardRange.lowerBound < startRange.lowerBound)
        for (path, text) in try UpdaterSources.appSwiftSources() where path != "Taskforce/Mac/MacAppDelegate.swift" {
            #expect(!text.contains("AppUpdater.shared.start("), "\(path)")
        }
    }

    /// 종료(재시작) 위임 지점: 지금은 항상 허용. 실행 중인 에이전트 턴 확인은 bridge WP가 `UpdateRelaunchPolicy`에 더한다
    @Test func relaunchGoesThroughOnePolicyPoint() throws {
        let source = try UpdaterSources.text("Taskforce/Mac/AppUpdater.swift")
        let body = try #require(source.components(separatedBy: "func updaterShouldRelaunchApplication").last?.components(separatedBy: "\n    }").first)
        #expect(body.contains("UpdateRelaunchPolicy.allowsRelaunchNow()"))
    }
}
