import Foundation
import Testing
@testable import Taskforce

/// 테스트 격리 규칙 (apple/README.md "테스트 격리"). 호스트가 이미 뜬 뒤의 확인이라 늦은 안전망이다:
/// 호스트가 뜨기 전의 거부는 TaskforceTests 빌드 단계(`Scripts/check-test-host-isolation.sh`)가 한다.
struct TestIsolationTests {
    /// 테스트 호스트는 실사용 앱(`dev.taskforcelabs.taskforce`)과 다른 번들 ID다. `xcodebuild test`의 기본은 `dev.taskforcelabs.unittest.taskforce`
    @Test func hostIsNotTheRealApp() throws {
        let bundleID = try #require(Bundle.main.bundleIdentifier)
        #expect(bundleID.lowercased() != "dev.taskforcelabs.taskforce")
        #expect(bundleID.lowercased() != "group.dev.taskforcelabs.taskforce")
    }

    /// 테스트 소유 suite는 임시 폴더 안에서만 살고 cleanup이 폴더째 지운다. ~/Library/Preferences에는 파일이 생기지 않는다
    @Test func testOwnedDefaultsLiveOnlyInsideTheirTemporaryFolder() throws {
        let store = try TestDefaults()
        let preferences = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Preferences")
        let before = try Set(FileManager.default.contentsOfDirectory(atPath: preferences.path))
        defer { store.cleanup() }

        store.defaults.set("account", forKey: "settings.tab")
        #expect(store.defaults.string(forKey: "settings.tab") == "account")
        #expect(FileManager.default.fileExists(atPath: store.directory.path))
        #expect(store.directory.path.hasPrefix(FileManager.default.temporaryDirectory.path))

        store.cleanup()
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
        #expect(store.defaults.string(forKey: "settings.tab") == nil)
        let after = try Set(FileManager.default.contentsOfDirectory(atPath: preferences.path))
        #expect(after.subtracting(before).filter { $0.contains(store.directory.lastPathComponent) }.isEmpty)
    }
}
