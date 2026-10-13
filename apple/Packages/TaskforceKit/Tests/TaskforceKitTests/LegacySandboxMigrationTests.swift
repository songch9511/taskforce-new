#if os(macOS)
import Foundation
import OSLog
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

        var pinsDomain: String { WorkPinStore.suiteName(bundleID: bundleID) }

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

        func migration(domains: [String]? = nil, read: ((URL) throws -> Data)? = nil) -> LegacySandboxMigration {
            LegacySandboxMigration(
                homeDirectory: home, bundleID: bundleID, domains: domains ?? AppDefaultsDomains.all(bundleID: bundleID),
                read: read ?? { try Data(contentsOf: $0) },
                destination: { [unowned self] in self.destination($0) }
            )
        }

        func cleanup() {
            for made in destinations.values { made.defaults.removePersistentDomain(forName: made.persistentDomain) }
            // 권한을 뺀 시험이 남긴 것을 되돌려야 폴더째 지울 수 있다
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: preferences.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: oldFile(bundleID).path)
            try? FileManager.default.removeItem(at: home)
        }
    }

    /// 읽기 상태 상자: 시험이 실행 사이에 바꾼다
    final class Switch {
        var denied: Set<String>
        init(denied: Set<String> = []) { self.denied = denied }

        /// 이름이 `denied`에 있는 도메인의 plist만 권한 오류를 던지고 나머지는 실제로 읽는다
        func read(_ url: URL) throws -> Data {
            if denied.contains(url.deletingPathExtension().lastPathComponent) { throw CocoaError(.fileReadNoPermission) }
            return try Data(contentsOf: url)
        }
    }

    var standard: String { Self.bundleID }
    var pins: String { WorkPinStore.suiteName(bundleID: Self.bundleID) }

    typealias Report = LegacySandboxMigration.Report

    static func finished(
        copied: Int = 0, kept: Int = 0, missing: Int = 0, unreadable: Int = 0, denied: Int = 0, attempts: Int = 0, marker: Bool = true
    ) -> Report {
        Report(
            alreadyDone: false, copiedKeys: copied, keptKeys: kept, missingDomains: missing, unreadableDomains: unreadable,
            deniedDomains: denied, attempts: attempts, markerWritten: marker
        )
    }

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
        #expect(report == Self.finished(copied: 7 + 1, kept: 2 + 1))
    }

    /// 이전기의 표식 · 시도 키(`tf.legacySandboxMigration.` 접두어)는 옛 plist에 있어도 복사하지 않는다:
    /// 복사하면 옛 값이 새 도메인의 완료 표식이 되어(권한 오류로 끝나지 않은 이전도 끝난 것으로 보인다) 시도 횟수가 어긋난다
    @Test func theMigrationsOwnKeysAreNeverCopiedFromTheOldPlist() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        #expect(LegacySandboxMigration.markerKey.hasPrefix("tf.legacySandboxMigration.") && LegacySandboxMigration.attemptsKey.hasPrefix("tf.legacySandboxMigration."))
        try fixture.writeOld(standard, [
            "settings.tab": "account", LegacySandboxMigration.markerKey: "old-marker", LegacySandboxMigration.attemptsKey: 7, "tf.legacySandboxMigration.future": 1,
        ])
        try fixture.writeOld(pins, ["pins.alice": ["id-1"]])
        let reads = Switch(denied: [pins])

        let report = fixture.migration(read: reads.read).run()

        // 표식이 옛 값으로 생기지 않는다: 권한 오류가 난 이전은 아직 끝나지 않았다. 시도 횟수는 우리 값(1)이다
        #expect(report == Self.finished(copied: 1, denied: 1, attempts: 1, marker: false))
        let values = fixture.newValues(standard)
        #expect(values["settings.tab"] as? String == "account")
        #expect(values[LegacySandboxMigration.markerKey] == nil)
        #expect(values[LegacySandboxMigration.attemptsKey] as? Int == 1)
        #expect(values["tf.legacySandboxMigration.future"] == nil)
        // 끝나면 표식은 우리가 쓴 값(true)이다
        reads.denied = []
        #expect(fixture.migration(read: reads.read).run().markerWritten)
        #expect(fixture.newValues(standard)[LegacySandboxMigration.markerKey] as? Bool == true)
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

        #expect(second == Report(alreadyDone: true))
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

        #expect(report == Report(alreadyDone: true))
        #expect(fixture.newValues(standard)["settings.tab"] == nil)
    }

    // MARK: T3 실패에 크래시 없음 · 형식 오류와 파일 없음은 표식을 쓴다

    @Test func noOldContainerSkipsEveryDomainAndStillWritesTheMarker() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let report = fixture.migration().run()

        #expect(report == Self.finished(missing: AppDefaultsDomains.all(bundleID: Self.bundleID).count))
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

        #expect(report == Self.finished(copied: 1, unreadable: 1))
        #expect(fixture.newValues(pins)["pins.alice"] as? [String] == ["id-1"])
        #expect(fixture.newValues(standard)[LegacySandboxMigration.markerKey] != nil)
    }

    @Test func aPlistThatIsNotADictionarySkipsThatDomain() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.preferences, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["not", "a", "dictionary"], format: .xml, options: 0).write(to: fixture.oldFile(standard))

        let report = fixture.migration().run()

        #expect(report.unreadableDomains == 1 && report.copiedKeys == 0 && report.markerWritten)
        #expect(fixture.newValues(standard)[LegacySandboxMigration.markerKey] != nil)
    }

    /// 파일이 아닌 것(폴더)이 그 자리에 있으면 읽지 못한다: 권한 오류가 아니다 (root여도 같다)
    @Test func somethingThatIsNotAFileSkipsThatDomainLikeABrokenPlist() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.oldFile(standard), withIntermediateDirectories: true)
        try fixture.writeOld(pins, ["pins.alice": ["id-1"]])

        let report = fixture.migration().run()

        #expect(report == Self.finished(copied: 1, unreadable: 1))
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

        #expect(report == Self.finished(copied: 1, unreadable: 1))
    }

    /// 읽기 오류의 종류: 권한(EPERM · EACCES · 읽기 권한 없음)은 "완료 아님", 파일 없음은 건너뜀, 그 밖은 읽을 수 없음(형식 오류와 같은 취급)
    @Test func readErrorsAreToldApartByTheirKind() throws {
        struct Odd: Error {}
        func underlying(_ code: POSIXErrorCode, in cocoa: CocoaError.Code) -> NSError {
            NSError(domain: NSCocoaErrorDomain, code: cocoa.rawValue, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(code.rawValue))])
        }
        let denied: [any Error] = [
            CocoaError(.fileReadNoPermission), POSIXError(.EACCES), POSIXError(.EPERM),
            underlying(.EPERM, in: .fileReadUnknown), underlying(.EACCES, in: .fileReadUnknown),
        ]
        let missing: [any Error] = [CocoaError(.fileReadNoSuchFile), CocoaError(.fileNoSuchFile), POSIXError(.ENOENT), underlying(.ENOENT, in: .fileReadUnknown)]
        let unreadable: [any Error] = [CocoaError(.fileReadCorruptFile), POSIXError(.EIO), POSIXError(.EISDIR), CocoaError(.fileReadUnknown), Odd()]

        func report(throwing error: any Error) throws -> Report {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            return fixture.migration(domains: [Self.bundleID], read: { _ in throw error }).run()
        }
        for error in denied {
            #expect(try report(throwing: error) == Self.finished(denied: 1, attempts: 1, marker: false), "권한 오류: \(error)")
        }
        for error in missing {
            #expect(try report(throwing: error) == Self.finished(missing: 1), "파일 없음: \(error)")
        }
        for error in unreadable {
            #expect(try report(throwing: error) == Self.finished(unreadable: 1), "읽을 수 없음: \(error)")
        }
    }

    // MARK: 권한 오류는 완료가 아니다: 표식 없이 시도 횟수를 올리고, 3번째에 표식

    @Test func aPermissionErrorWritesNoMarkerAndCountsTheAttempt() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeOld(standard, ["settings.tab": "account"])
        try fixture.writeOld(pins, ["pins.alice": ["id-1"]])
        let reads = Switch(denied: [standard])

        let report = fixture.migration(read: reads.read).run()

        #expect(report == Self.finished(copied: 1, denied: 1, attempts: 1, marker: false))
        let values = fixture.newValues(standard)
        #expect(values[LegacySandboxMigration.markerKey] == nil)
        #expect(values[LegacySandboxMigration.attemptsKey] as? Int == 1)
        #expect(values["settings.tab"] == nil)
        #expect(fixture.newValues(pins)["pins.alice"] as? [String] == ["id-1"], "읽은 도메인의 키는 그대로 둔다")
    }

    @Test func theThirdPermissionErrorWritesTheMarkerSoItNeverRetriesForever() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeOld(standard, ["settings.tab": "account"])
        try fixture.writeOld(pins, ["pins.alice": ["id-1"]])
        let reads = Switch(denied: [standard])

        #expect(fixture.migration(read: reads.read).run() == Self.finished(copied: 1, denied: 1, attempts: 1, marker: false))
        // 다음 시도: 이미 옮긴 키는 중복 없이 그대로(kept), 표식은 아직 없다
        #expect(fixture.migration(read: reads.read).run() == Self.finished(kept: 1, denied: 1, attempts: 2, marker: false))
        #expect(fixture.newValues(standard)[LegacySandboxMigration.markerKey] == nil)
        // 3번째에도 권한 오류면 그때 표식
        #expect(fixture.migration(read: reads.read).run() == Self.finished(kept: 1, denied: 1, attempts: 3, marker: true))
        let values = fixture.newValues(standard)
        #expect(values[LegacySandboxMigration.markerKey] != nil)
        #expect(values[LegacySandboxMigration.attemptsKey] as? Int == 3)
        #expect(fixture.migration(read: reads.read).run() == Report(alreadyDone: true))
        #expect(fixture.newValues(pins)["pins.alice"] as? [String] == ["id-1"])
    }

    @Test func aDomainThatBecomesReadableOnALaterAttemptIsMigratedWithoutDuplicates() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeOld(standard, ["settings.tab": "account"])
        try fixture.writeOld(pins, ["pins.alice": ["id-1"]])
        let reads = Switch(denied: [standard])
        fixture.migration(read: reads.read).run()

        reads.denied = []
        let report = fixture.migration(read: reads.read).run()

        #expect(report == Self.finished(copied: 1, kept: 1))
        let values = fixture.newValues(standard)
        #expect(values["settings.tab"] as? String == "account")
        #expect(values[LegacySandboxMigration.markerKey] != nil)
        #expect(fixture.newValues(pins)["pins.alice"] as? [String] == ["id-1"])
        #expect(fixture.migration(read: reads.read).run() == Report(alreadyDone: true))
    }

    /// 진짜 파일 권한: 읽기 권한을 뺀 plist (root는 읽을 수 있어서 이 시험만 건너뛴다. 같은 동작은 위 시험이 주입한 오류로 root에서도 돈다)
    @Test(.disabled(if: getuid() == 0, "root는 읽기 권한 없는 파일도 읽는다"))
    func aFileWithoutReadPermissionIsAPermissionError() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeOld(standard, ["settings.tab": "account"])
        try fixture.writeOld(pins, ["pins.alice": ["id-1"]])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.oldFile(standard).path)

        let report = fixture.migration().run()

        #expect(report == Self.finished(copied: 1, denied: 1, attempts: 1, marker: false))
        #expect(fixture.newValues(standard)["settings.tab"] == nil)
        #expect(fixture.newValues(standard)[LegacySandboxMigration.markerKey] == nil)
    }

    /// 진짜 폴더 권한: 컨테이너 설정 폴더를 열 수 없는 경우 (macOS가 다른 앱의 데이터를 막을 때와 같은 EACCES · EPERM 모양)
    @Test(.disabled(if: getuid() == 0, "root는 막힌 폴더도 연다"))
    func anUnsearchableFolderIsAPermissionErrorForEveryDomain() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeOld(standard, ["settings.tab": "account"])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.preferences.path)

        let report = fixture.migration().run()

        #expect(report == Self.finished(denied: AppDefaultsDomains.all(bundleID: Self.bundleID).count, attempts: 1, marker: false))
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

    // MARK: 앱 시작 (샌드박스 감지 · Debug 빌드와 묶인 길)

    private func launch(
        _ fixture: Fixture, bundleID: String? = Self.bundleID, environment: [String: String] = [:], home: URL? = nil,
        isDebugBuild: Bool = false, debugOptIn: Bool = false
    ) -> Report? {
        LegacySandboxMigration.runAtLaunch(
            bundleID: bundleID, environment: environment, isDebugBuild: isDebugBuild, debugOptIn: debugOptIn,
            homeDirectory: home ?? fixture.home, destination: { fixture.destination($0) }
        )
    }

    @Test func launchRunsTheMigrationWhenTheAppIsNotSandboxed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeOld(standard, ["settings.tab": "account"])

        let report = launch(fixture)

        #expect(report?.copiedKeys == 1)
        #expect(fixture.newValues(standard)["settings.tab"] as? String == "account")
    }

    @Test func launchDoesNothingInsideTheSandbox() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeOld(standard, ["settings.tab": "account"])

        let report = launch(fixture, environment: [AgentRuntimeEnvironment.sandboxContainerKey: Self.bundleID])

        #expect(report == nil)
        #expect(fixture.newValues(standard).isEmpty, "표식도 쓰지 않는다: 샌드박스를 다시 끄는 날 옮길 수 있게")
    }

    /// 환경 변수가 없어도 홈 디렉터리가 컨테이너 안이면 샌드박스다 (보조 판정)
    @Test func launchDoesNothingWhenTheHomeDirectoryIsAContainer() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let container = URL(fileURLWithPath: "/Users/someone/Library/Containers/\(Self.bundleID)/Data")

        #expect(launch(fixture, home: container) == nil)
        #expect(fixture.newValues(standard).isEmpty)
    }

    @Test func launchWithoutABundleIdentifierDoesNothing() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        #expect(launch(fixture, bundleID: nil) == nil)
    }

    /// Debug 빌드는 실사용 번들 id를 쓰므로 개발 실행이 실사용 컨테이너를 읽고 표식을 미리 써서 나중의 DMG 이전을 소모하면 안 된다
    @Test func aDebugBuildDoesNotMigrateUnlessItIsAskedTo() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeOld(standard, ["settings.tab": "account"])

        #expect(launch(fixture, isDebugBuild: true, debugOptIn: false) == nil)
        #expect(fixture.newValues(standard).isEmpty, "표식도 쓰지 않는다")

        let asked = launch(fixture, isDebugBuild: true, debugOptIn: true)
        #expect(asked?.copiedKeys == 1)
        #expect(fixture.newValues(standard)["settings.tab"] as? String == "account")
    }

    @Test func aReleaseBuildMigratesWhateverTheDebugArgumentSays() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeOld(standard, ["settings.tab": "account"])

        #expect(launch(fixture, isDebugBuild: false, debugOptIn: false)?.copiedKeys == 1)
    }

    /// 실행 인자 `-TF_LEGACY_MIGRATION YES` (인자 영역의 값은 문자열이다)
    @Test func theDebugArgumentIsReadFromTheArgumentDomain() {
        #expect(LegacySandboxMigration.debugOptInKey == "TF_LEGACY_MIGRATION")
        #expect(LegacySandboxMigration.debugOptIn(arguments: ["TF_LEGACY_MIGRATION": "YES"]))
        #expect(LegacySandboxMigration.debugOptIn(arguments: ["TF_LEGACY_MIGRATION": "true"]))
        #expect(LegacySandboxMigration.debugOptIn(arguments: ["TF_LEGACY_MIGRATION": true]))
        #expect(!LegacySandboxMigration.debugOptIn(arguments: ["TF_LEGACY_MIGRATION": "NO"]))
        #expect(!LegacySandboxMigration.debugOptIn(arguments: ["TF_LEGACY_MIGRATION": false]))
        #expect(!LegacySandboxMigration.debugOptIn(arguments: ["TF_EDGE_SHELL": "YES"]))
        #expect(!LegacySandboxMigration.debugOptIn(arguments: [:]))
    }

    // MARK: 로그: 결과는 notice(저장됨), 권한 오류는 error, 키 이름 · 값 · 경로 없이 개수만

    @Test func theLogCarriesCountsAtNoticeAndPermissionErrorsAtErrorWithoutKeyNames() async throws {
        let bundleID = "dev.test.taskforce.log.\(UUID().uuidString)"
        let fixture = try Fixture(bundleID: bundleID)
        defer { fixture.cleanup() }
        try fixture.writeOld(bundleID, ["zz-secret-key-name": "zz-secret-value"])
        try fixture.writeOld(fixture.pinsDomain, ["zz-other-key-name": 1])
        let reads = Switch(denied: [fixture.pinsDomain])
        let started = Date().addingTimeInterval(-1)

        fixture.migration(read: reads.read).run()

        let store = try OSLogStore(scope: .currentProcessIdentifier)
        // 로그 저장소에 나타나기까지 몇 초 걸릴 수 있다 (읽기 한 번도 느리다). 오류 항목이 보이면 멈추고, 30초가 한계
        var entries: [OSLogEntryLog] = []
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            entries = try store.getEntries(at: store.position(date: started), matching: NSPredicate(format: "subsystem == %@", bundleID))
                .compactMap { $0 as? OSLogEntryLog }
            if entries.contains(where: { $0.level == .error }) { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        let notice = entries.filter { $0.level == .notice }
        let errors = entries.filter { $0.level == .error }
        #expect(notice.count == 1 && errors.count == 1, "notice \(notice.count) · error \(errors.count)")
        #expect(entries.allSatisfy { $0.category == "legacy-sandbox-migration" })
        let text = entries.map(\.composedMessage).joined(separator: "\n")
        #expect(text.contains("copied 1") && text.contains("denied 1"), "\(text)")
        #expect(!text.contains("zz-") && !text.contains(fixture.home.path) && !text.contains("plist"), "키 이름 · 값 · 경로가 로그에 없다")
    }
}
#endif
