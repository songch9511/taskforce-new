import Foundation
import Testing
@testable import TaskforceKit

/// 샌드박스를 끈 뒤 옛 컨테이너(`~/Library/Containers/<번들 id>/Data/Library/Preferences/<도메인>.plist`)의 UserDefaults를 1회 옮기는 규칙 (OA M1a).
/// 홈 디렉터리도 옮겨 받을 UserDefaults도 모두 임시 폴더 안이다: 실사용 앱의 설정 · 컨테이너(`dev.taskforcelabs.taskforce`)를 읽거나 쓰지 않고,
/// `~/Library/Preferences`에 파일을 남기지 않는다 (절대 경로 suite, `apple/TaskforceTests/TestDefaults.swift`와 같은 방식).
struct LegacySandboxMigrationTests {
    static let bundleID = "dev.test.taskforce"

    /// 임시 홈 + 옮겨 받을 도메인마다 임시 폴더의 plist를 쓰는 UserDefaults
    final class Fixture {
        let home: URL
        let bundleID: String
        private var destinations: [String: LegacySandboxMigration.Destination] = [:]

        init(bundleID: String = LegacySandboxMigrationTests.bundleID) throws {
            self.bundleID = bundleID
            home = FileManager.default.temporaryDirectory.appending(path: "LegacySandboxMigration-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }

        var preferences: URL {
            home.appending(path: "Library/Containers/\(bundleID)/Data/Library/Preferences", directoryHint: .isDirectory)
        }

        var container: URL {
            home.appending(path: "Library/Containers/\(bundleID)", directoryHint: .isDirectory)
        }

        func oldFile(_ domain: String) -> URL {
            preferences.appending(path: "\(domain).plist")
        }

        /// 옛 샌드박스 plist 한 개를 만든다 (실제 컨테이너처럼 바이너리 plist)
        func writeOld(_ domain: String, _ values: [String: Any]) throws {
            try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
            try data.write(to: oldFile(domain))
        }

        /// 새 도메인: 도메인마다 한 번 만들고 같은 것을 돌려준다
        func destination(_ domain: String) -> LegacySandboxMigration.Destination? {
            if let existing = destinations[domain] { return existing }
            let name = home.appending(path: "new/\(destinations.count)", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: name, withIntermediateDirectories: true)
            let path = name.appending(path: "defaults").path
            guard let defaults = UserDefaults(suiteName: path) else { return nil }
            let made = LegacySandboxMigration.Destination(defaults: defaults, persistentDomain: path)
            destinations[domain] = made
            return made
        }

        func newValues(_ domain: String) -> [String: Any] {
            guard let made = destination(domain) else { return [:] }
            return made.defaults.persistentDomain(forName: made.persistentDomain) ?? [:]
        }

        func setNew(_ domain: String, _ values: [String: Any]) {
            guard let made = destination(domain) else { return }
            for (key, value) in values { made.defaults.set(value, forKey: key) }
        }

        func migration() -> LegacySandboxMigration {
            LegacySandboxMigration(
                homeDirectory: home, bundleID: bundleID, domains: AppDefaultsDomains.all(bundleID: bundleID),
                destination: { [unowned self] in self.destination($0) }
            )
        }

        func cleanup() {
            for made in destinations.values { made.defaults.removePersistentDomain(forName: made.persistentDomain) }
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: oldFile(bundleID).path)
            try? FileManager.default.removeItem(at: home)
        }
    }

    var standard: String { Self.bundleID }
    var pins: String { WorkPinStore.suiteName(bundleID: Self.bundleID) }

    // MARK: T1 이전

    @Test func copiesKeysTheNewDomainLacksAndLeavesTheOnesItHas() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let when = Date(timeIntervalSince1970: 1_790_000_000)
        try fixture.writeOld(standard, [
            "settings.tab": "account", "launcher.hotKey": Data([1, 2, 3]), "count": 3, "flag": true, "when": when,
            "list": ["a", "b"], "nested": ["k": 1], "TFReduceMotion": true, "keep": "old",
        ])
        try fixture.writeOld(pins, ["pins.alice": ["id-1", "id-2"], "pins.bob": ["id-3"]])
        fixture.setNew(standard, ["keep": "new", "TFReduceMotion": false])
        fixture.setNew(pins, ["pins.bob": ["newer"]])

        let report = fixture.migration().run()

        let migrated = fixture.newValues(standard)
        #expect(migrated["settings.tab"] as? String == "account")
        #expect(migrated["launcher.hotKey"] as? Data == Data([1, 2, 3]))
        #expect(migrated["count"] as? Int == 3)
        #expect(migrated["flag"] as? Bool == true)
        #expect(migrated["when"] as? Date == when)
        #expect(migrated["list"] as? [String] == ["a", "b"])
        #expect((migrated["nested"] as? [String: Int]) == ["k": 1])
        #expect(migrated["keep"] as? String == "new", "새 도메인에 있는 값은 덮지 않는다")
        #expect(migrated["TFReduceMotion"] as? Bool == false, "false도 '있는 값'이다")
        let pinned = fixture.newValues(pins)
        #expect(pinned["pins.alice"] as? [String] == ["id-1", "id-2"])
        #expect(pinned["pins.bob"] as? [String] == ["newer"])
        #expect(migrated[LegacySandboxMigration.markerKey] != nil, "표식은 표준 도메인에 쓴다")
        #expect(pinned[LegacySandboxMigration.markerKey] == nil)
        #expect(report == LegacySandboxMigration.Report(alreadyDone: false, copiedKeys: 7 + 1, keptKeys: 2 + 1, missingDomains: 0, unreadableDomains: 0))
    }

    // MARK: T2 멱등

    @Test func theSecondRunWritesNothingAndTheMarkerIgnoresChangedOldFiles() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeOld(standard, ["settings.tab": "account", "a": 1])
        try fixture.writeOld(pins, ["pins.alice": ["id-1"]])
        #expect(fixture.migration().run().copiedKeys == 3)
        let afterFirst = fixture.newValues(standard)
        let pinsAfterFirst = fixture.newValues(pins)

        // 사용자가 새 앱에서 지운 값 · 옛 파일에 생긴 새 값 · 바뀐 옛 값이 두 번째 실행으로 되살아나지 않는다
        fixture.destination(standard)?.defaults.removeObject(forKey: "settings.tab")
        try fixture.writeOld(standard, ["settings.tab": "connections", "a": 2, "b": 9])
        try fixture.writeOld(pins, ["pins.alice": ["changed"], "pins.carol": ["x"]])
        let second = fixture.migration().run()

        #expect(second == LegacySandboxMigration.Report(alreadyDone: true))
        var expected = afterFirst
        expected["settings.tab"] = nil
        #expect(NSDictionary(dictionary: fixture.newValues(standard)).isEqual(to: expected))
        #expect(NSDictionary(dictionary: fixture.newValues(pins)).isEqual(to: pinsAfterFirst))
    }

    @Test func aMarkerThatAlreadyExistsMeansNothingIsReadOrCopied() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeOld(standard, ["settings.tab": "account"])
        fixture.setNew(standard, [LegacySandboxMigration.markerKey: true])

        let report = fixture.migration().run()

        #expect(report == LegacySandboxMigration.Report(alreadyDone: true))
        #expect(fixture.newValues(standard)["settings.tab"] == nil)
    }

    // MARK: T3 실패에 크래시 없음

    @Test func noOldContainerSkipsEveryDomainAndStillWritesTheMarker() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let report = fixture.migration().run()

        #expect(report == LegacySandboxMigration.Report(
            alreadyDone: false, copiedKeys: 0, keptKeys: 0, missingDomains: AppDefaultsDomains.all(bundleID: Self.bundleID).count, unreadableDomains: 0
        ))
        #expect(fixture.newValues(standard)[LegacySandboxMigration.markerKey] != nil, "다음 시작에 다시 찾지 않는다")
        #expect(fixture.migration().run().alreadyDone)
    }

    @Test func aBrokenPlistSkipsOnlyThatDomain() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.preferences, withIntermediateDirectories: true)
        try Data("this is not a property list".utf8).write(to: fixture.oldFile(standard))
        try fixture.writeOld(pins, ["pins.alice": ["id-1"]])

        let report = fixture.migration().run()

        #expect(report == LegacySandboxMigration.Report(alreadyDone: false, copiedKeys: 1, keptKeys: 0, missingDomains: 0, unreadableDomains: 1))
        #expect(fixture.newValues(pins)["pins.alice"] as? [String] == ["id-1"])
        #expect(fixture.newValues(standard)[LegacySandboxMigration.markerKey] != nil)
    }

    @Test func aPlistThatIsNotADictionarySkipsThatDomain() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.preferences, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["not", "a", "dictionary"], format: .xml, options: 0).write(to: fixture.oldFile(standard))

        let report = fixture.migration().run()

        #expect(report.unreadableDomains == 1 && report.copiedKeys == 0)
        #expect(fixture.newValues(standard)[LegacySandboxMigration.markerKey] != nil)
    }

    @Test(.disabled(if: getuid() == 0, "root는 읽기 권한 없는 파일도 읽는다"))
    func aFileWithoutReadPermissionSkipsThatDomain() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeOld(standard, ["settings.tab": "account"])
        try fixture.writeOld(pins, ["pins.alice": ["id-1"]])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.oldFile(standard).path)

        let report = fixture.migration().run()

        #expect(report == LegacySandboxMigration.Report(alreadyDone: false, copiedKeys: 1, keptKeys: 0, missingDomains: 0, unreadableDomains: 1))
        #expect(fixture.newValues(standard)["settings.tab"] == nil)
        #expect(fixture.newValues(standard)[LegacySandboxMigration.markerKey] != nil, "무한 재시도 없음")
    }

    /// 파일이 아닌 것(폴더)이 그 자리에 있으면 읽지 못한다: 권한과 상관없이 (root여도) 같다
    @Test func somethingThatIsNotAFileSkipsThatDomain() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.oldFile(standard), withIntermediateDirectories: true)
        try fixture.writeOld(pins, ["pins.alice": ["id-1"]])

        let report = fixture.migration().run()

        #expect(report == LegacySandboxMigration.Report(alreadyDone: false, copiedKeys: 1, keptKeys: 0, missingDomains: 0, unreadableDomains: 1))
        #expect(fixture.newValues(standard)[LegacySandboxMigration.markerKey] != nil)
    }

    @Test func aDomainTheAppCannotOpenIsSkippedLikeAnUnreadableFile() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeOld(standard, ["settings.tab": "account"])
        try fixture.writeOld(pins, ["pins.alice": ["id-1"]])
        let migration = LegacySandboxMigration(
            homeDirectory: fixture.home, bundleID: Self.bundleID, domains: AppDefaultsDomains.all(bundleID: Self.bundleID),
            destination: { $0 == pins ? nil : fixture.destination($0) }
        )

        let report = migration.run()

        #expect(report == LegacySandboxMigration.Report(alreadyDone: false, copiedKeys: 1, keptKeys: 0, missingDomains: 0, unreadableDomains: 1))
    }

    // MARK: T5 옛 파일은 그대로

    @Test func neverDeletesOrChangesTheOldContainer() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeOld(standard, ["settings.tab": "account"])
        try fixture.writeOld(pins, ["pins.alice": ["id-1"]])
        let other = fixture.container.appending(path: "Data/Library/Application Support/Taskforce/anything.json")
        try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: other)
        let before = try Self.snapshot(of: fixture.container)
        #expect(before.keys.filter { $0.hasSuffix(".plist") || $0.hasSuffix(".json") }.count == 3)

        fixture.migration().run()
        fixture.migration().run()

        #expect(try Self.snapshot(of: fixture.container) == before)
    }

    /// 상대 경로 → 내용 · 수정 시각 (폴더는 내용 없음)
    static func snapshot(of root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { throw CocoaError(.fileReadUnknown) }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            let relative = String(url.path.dropFirst(root.path.count))
            let body = values.isDirectory == true ? "dir" : try Data(contentsOf: url).base64EncodedString()
            result[relative] = "\(body)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }
        return result
    }

    // MARK: 앱의 목적지

    /// 앱 안의 목적지: 표준 도메인은 `UserDefaults.standard`, 나머지는 같은 이름의 suite. 읽기만 해서 `~/Library/Preferences`에 파일을 만들지 않는다
    /// (번들 id는 이 시험만의 이름이고 실사용 앱의 도메인이 아니다)
    @Test func theAppDestinationIsTheStandardDomainForTheBundleIDAndASuiteForTheRest() {
        let bundleID = "dev.test.taskforce.\(UUID().uuidString)"
        let standard = LegacySandboxMigration.Destination.app(domain: bundleID, bundleID: bundleID)
        #expect(standard?.defaults === UserDefaults.standard && standard?.persistentDomain == bundleID)

        let suiteName = WorkPinStore.suiteName(bundleID: bundleID)
        let suite = LegacySandboxMigration.Destination.app(domain: suiteName, bundleID: bundleID)
        #expect(suite?.persistentDomain == suiteName)
        #expect(suite?.defaults !== UserDefaults.standard)
        #expect(suite?.keys.isEmpty == true)
    }

    // MARK: 앱 시작 (샌드박스 감지와 묶인 길)

    @Test func launchRunsTheMigrationWhenTheAppIsNotSandboxed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeOld(standard, ["settings.tab": "account"])

        let report = LegacySandboxMigration.runAtLaunch(
            bundleID: Self.bundleID, environment: [:], homeDirectory: fixture.home, destination: { fixture.destination($0) }
        )

        #expect(report?.copiedKeys == 1)
        #expect(fixture.newValues(standard)["settings.tab"] as? String == "account")
    }

    @Test func launchDoesNothingInsideTheSandbox() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeOld(standard, ["settings.tab": "account"])

        let report = LegacySandboxMigration.runAtLaunch(
            bundleID: Self.bundleID, environment: [AgentRuntimeEnvironment.sandboxContainerKey: Self.bundleID],
            homeDirectory: fixture.home, destination: { fixture.destination($0) }
        )

        #expect(report == nil)
        #expect(fixture.newValues(standard).isEmpty, "표식도 쓰지 않는다: 샌드박스를 다시 끄는 날 옮길 수 있게")
    }

    @Test func launchWithoutABundleIdentifierDoesNothing() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        #expect(LegacySandboxMigration.runAtLaunch(bundleID: nil, environment: [:], homeDirectory: fixture.home, destination: { fixture.destination($0) }) == nil)
    }
}
