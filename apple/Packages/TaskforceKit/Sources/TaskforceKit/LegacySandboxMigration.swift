import Foundation
import OSLog

/// 앱이 쓰는 UserDefaults 도메인: 표준 도메인(번들 id)과 이름 있는 suite 전부.
/// 샌드박스 컨테이너에서 새 위치로 1회 옮길 대상이다 (`LegacySandboxMigration`). 앱이 새 suite를 열면 여기에 더한다:
/// 목록에 없는 suite는 이전에서 빠지고, `AppDefaultsDomainsTests`가 소스의 `UserDefaults(suiteName:)` 사용과 맞는지 확인한다.
public enum AppDefaultsDomains {
    /// 번들 id 뒤에 붙는 suite 이름 꼬리: All work 고정(`WorkPinStore`)
    static let workPinsSuffix = "work-pins"

    /// 앱이 여는 suite의 꼬리 전부 (표준 도메인 제외)
    public static let suiteSuffixes = [workPinsSuffix]

    /// 번들 id에 꼬리를 붙인 suite 이름 (앱의 기본 설정 파일과 섞이지 않는다)
    static func suiteName(bundleID: String, suffix: String) -> String {
        "\(bundleID).\(suffix)"
    }

    public static func suites(bundleID: String) -> [String] {
        suiteSuffixes.map { suiteName(bundleID: bundleID, suffix: $0) }
    }

    /// 표준 도메인(번들 id)이 먼저, 그 뒤 suite
    public static func all(bundleID: String) -> [String] {
        [bundleID] + suites(bundleID: bundleID)
    }
}

/// App Sandbox를 끄면 UserDefaults 파일 위치가 `~/Library/Containers/<번들 id>/Data/Library/Preferences/`에서 `~/Library/Preferences/`로 바뀐다.
/// 샌드박스 때 쌓인 설정이 사라진 것처럼 보이지 않게, 옛 컨테이너의 plist를 새 도메인으로 **한 번** 옮긴다.
///
/// - 표식 키(`markerKey`)가 표준 도메인에 있으면 아무것도 하지 않는다. 없으면 도메인마다 옛 plist를 읽어 **새 도메인에 없는 키만** 쓴다(새 값은 덮지 않는다).
/// - 끝나면 표식 키를 쓴다. 읽을 수 없는 도메인(파일 없음 · 깨진 plist · 권한 없음)은 건너뛰고 표식은 그래도 쓴다: 다시 시도하지 않는다.
/// - 옛 컨테이너의 파일은 지우지도 바꾸지도 않는다 (샌드박스 빌드로 돌아가도 그대로 있다).
/// - 샌드박스 안에서 돌면 부르지 않는다(`runAtLaunch`): 그때의 홈 디렉터리가 이미 컨테이너라 옮길 곳이 없다.
/// - 그 밖의 파일(App Group 컨테이너의 저장본 · Keychain)은 샌드박스와 상관없이 같은 위치라 옮기지 않는다. 캐시는 다시 만들어진다.
public struct LegacySandboxMigration {
    /// 표준 도메인에 쓰는 완료 표식
    public static let markerKey = "tf.legacySandboxMigration.v1"

    /// 옮겨 받을 UserDefaults와 그 안의 값을 읽을 도메인 이름 (`UserDefaults(suiteName:)`에 넘긴 이름, 표준은 번들 id).
    /// 시험은 임시 폴더 안의 절대 경로 suite를 쓰므로 `defaults`와 이름을 함께 받는다.
    public struct Destination {
        public let defaults: UserDefaults
        public let persistentDomain: String

        public init(defaults: UserDefaults, persistentDomain: String) {
            self.defaults = defaults
            self.persistentDomain = persistentDomain
        }

        /// 앱 안: 표준 도메인은 `UserDefaults.standard`, 나머지는 같은 이름의 suite
        public static func app(domain: String, bundleID: String) -> Destination? {
            if domain == bundleID { return Destination(defaults: .standard, persistentDomain: bundleID) }
            return UserDefaults(suiteName: domain).map { Destination(defaults: $0, persistentDomain: domain) }
        }

        var keys: Set<String> {
            defaults.persistentDomain(forName: persistentDomain).map { Set($0.keys) } ?? []
        }
    }

    /// 한 번의 실행 결과. 키 이름이나 값은 담지 않는다 (개수만).
    public struct Report: Equatable, Sendable {
        /// 표식이 이미 있어서 아무것도 하지 않았다
        public var alreadyDone = false
        public var copiedKeys = 0
        /// 새 도메인에 이미 있어 옛 값을 쓰지 않은 키
        public var keptKeys = 0
        /// 옛 plist가 없는 도메인
        public var missingDomains = 0
        /// 옛 plist를 읽지 못했거나 새 도메인을 열지 못한 도메인
        public var unreadableDomains = 0
    }

    public let homeDirectory: URL
    public let bundleID: String
    /// 옮길 도메인 전부 (`AppDefaultsDomains.all`). 표준 도메인(번들 id)이 있어야 표식을 쓸 수 있다
    public let domains: [String]
    public let fileManager: FileManager
    public let destination: (String) -> Destination?

    public init(
        homeDirectory: URL, bundleID: String, domains: [String], fileManager: FileManager = .default,
        destination: @escaping (String) -> Destination?
    ) {
        self.homeDirectory = homeDirectory
        self.bundleID = bundleID
        self.domains = domains
        self.fileManager = fileManager
        self.destination = destination
    }

    /// 옛 컨테이너의 한 도메인 plist 위치
    func legacyFile(domain: String) -> URL {
        homeDirectory.appending(path: "Library/Containers/\(bundleID)/Data/Library/Preferences/\(domain).plist")
    }

    @discardableResult
    public func run() -> Report {
        // 표식을 쓸 표준 도메인이 없으면(앱에서는 일어나지 않는다) 하지 않는다: 표식 없이 매번 옮기지 않게
        guard let standard = destination(bundleID) else { return Report() }
        if standard.keys.contains(Self.markerKey) { return Report(alreadyDone: true) }

        var report = Report()
        for domain in domains {
            let file = legacyFile(domain: domain)
            guard fileManager.fileExists(atPath: file.path) else {
                report.missingDomains += 1
                continue
            }
            guard let old = Self.readPlist(file), let target = destination(domain) else {
                report.unreadableDomains += 1
                continue
            }
            let existing = target.keys
            for (key, value) in old {
                if existing.contains(key) {
                    report.keptKeys += 1
                } else {
                    target.defaults.set(value, forKey: key)
                    report.copiedKeys += 1
                }
            }
        }
        standard.defaults.set(true, forKey: Self.markerKey)

        Logger(subsystem: bundleID, category: "legacy-sandbox-migration").info(
            "copied \(report.copiedKeys, privacy: .public) kept \(report.keptKeys, privacy: .public) missing \(report.missingDomains, privacy: .public) unreadable \(report.unreadableDomains, privacy: .public)"
        )
        return report
    }

    /// 딕셔너리 plist만 읽는다. 없거나 읽지 못하거나 형식이 다르면 nil
    private static func readPlist(_ file: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: file),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        return plist
    }

    /// 앱 시작에서 가장 먼저(어떤 UserDefaults 읽기보다 앞) 한 번 부른다. 샌드박스 안이거나 번들 id를 모르면 아무것도 하지 않고 nil.
    /// 그때는 표식도 쓰지 않는다: 샌드박스를 끈 빌드가 처음 뜰 때 옮길 수 있게.
    @discardableResult
    public static func runAtLaunch(
        bundleID: String?, environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, fileManager: FileManager = .default,
        destination: ((String) -> Destination?)? = nil
    ) -> Report? {
        guard let bundleID, !AgentRuntimeEnvironment.isSandboxed(environment: environment) else { return nil }
        return LegacySandboxMigration(
            homeDirectory: homeDirectory, bundleID: bundleID, domains: AppDefaultsDomains.all(bundleID: bundleID), fileManager: fileManager,
            destination: destination ?? { Destination.app(domain: $0, bundleID: bundleID) }
        ).run()
    }
}
