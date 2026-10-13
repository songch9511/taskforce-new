#if os(macOS)
import Foundation
import OSLog

// macOS 전용: 샌드박스 컨테이너와 사용자 홈 디렉터리(`homeDirectoryForCurrentUser`)는 iOS에 없는 개념이다.
// TaskforceKit은 iOS(`Package.swift`의 `.iOS(.v18)`)에서도 컴파일돼야 하므로 이 파일은 통째로 macOS에서만 만들어진다.

/// 앱이 쓰는 UserDefaults 도메인: 표준 도메인(번들 id)과 이름 있는 suite 전부.
/// 샌드박스 컨테이너에서 새 위치로 1회 옮길 대상이다 (`LegacySandboxMigration`). 앱이 새 suite를 열면 여기에 더한다:
/// 목록에 없는 suite는 이전에서 빠지고, `AppDefaultsDomainsTests`가 소스가 여는 설정 도메인(`UserDefaults(` · `.init(suiteName:)` · `CFPreferences…`)과 맞는지 확인한다.
public enum AppDefaultsDomains {
    /// 앱이 여는 suite의 꼬리 전부 (표준 도메인 제외). suite 이름은 번들 id 뒤에 꼬리를 붙인다 (앱의 기본 설정 파일과 섞이지 않는다)
    public static let suiteSuffixes = [WorkPinStore.suiteSuffix]

    public static func suites(bundleID: String) -> [String] {
        suiteSuffixes.map { "\(bundleID).\($0)" }
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
/// - 파일 없음 · 깨진 plist(형식 오류)는 그 도메인만 건너뛰고 표식을 쓴다: 다시 시도하지 않는다.
/// - **권한 오류**(EPERM · EACCES · 읽기 권한 없음: macOS가 다른 앱의 데이터 접근을 막을 때)는 완료가 아니다. 표식 없이 시도 횟수 키(`attemptsKey`)만 올리고,
///   `maxAttempts`번째에도 권한 오류면 그때 표식을 쓴다(무한 재시도 금지). 다른 도메인에서 옮긴 키는 그대로 두고, 다음 시도에서 키 단위로 건너뛰어 중복이 없다.
/// - 옛 컨테이너의 파일은 지우지도 바꾸지도 않는다 (샌드박스 빌드로 돌아가도 그대로 있다).
/// - 샌드박스 안이거나(`AgentRuntimeEnvironment`) Debug 빌드(실행 인자 없이)면 부르지 않는다(`runAtLaunch`).
/// - 그 밖의 파일(App Group 컨테이너의 저장본 · Keychain)은 샌드박스와 상관없이 같은 위치라 옮기지 않는다. 캐시는 다시 만들어진다.
public struct LegacySandboxMigration {
    /// 표준 도메인에 쓰는 완료 표식
    public static let markerKey = "tf.legacySandboxMigration.v1"
    /// 권한 오류로 끝난 시도 횟수 (표준 도메인)
    public static let attemptsKey = "tf.legacySandboxMigration.attempts"
    /// 권한 오류로 표식 없이 끝낼 수 있는 시도 수. 이 번째 시도에서도 권한 오류면 표식을 쓴다
    public static let maxAttempts = 3
    /// Debug 빌드에서 이전을 켜는 실행 인자 `-TF_LEGACY_MIGRATION YES` (기존 `-TF_EDGE_SHELL YES` 방식, 인자 영역만)
    public static let debugOptInKey = "TF_LEGACY_MIGRATION"

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

        /// 이 도메인에 실제로 저장된 값 (전역 도메인 · 등록 기본값은 빼고)
        var stored: [String: Any] {
            defaults.persistentDomain(forName: persistentDomain) ?? [:]
        }

        var keys: Set<String> { Set(stored.keys) }
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
        /// 옛 plist를 읽지 못한 도메인: 형식 오류 · 딕셔너리 아님 · 읽기 실패 · 새 도메인을 열지 못함 (권한 오류는 `deniedDomains`)
        public var unreadableDomains = 0
        /// 권한 오류로 읽지 못한 도메인
        public var deniedDomains = 0
        /// 권한 오류가 난 시도의 누적 횟수 (이번 실행에 권한 오류가 없었으면 0)
        public var attempts = 0
        /// 이번 실행에서 표식을 썼다
        public var markerWritten = false
    }

    public let homeDirectory: URL
    public let bundleID: String
    /// 옮길 도메인 전부 (`AppDefaultsDomains.all`). 표준 도메인(번들 id)이 있어야 표식을 쓸 수 있다
    public let domains: [String]
    /// 옛 plist를 읽는 함수. 오류의 종류(권한 · 없음 · 그 밖)로 완료 여부가 갈리므로 `FileManager`의 존재 확인 대신 읽기 오류를 그대로 받는다
    /// (`fileExists`는 접근이 막혀도 그냥 false라서 "없음"과 "막힘"을 가르지 못한다). 시험이 오류를 주입한다
    public let read: (URL) throws -> Data
    public let destination: (String) -> Destination?

    public init(
        homeDirectory: URL, bundleID: String, domains: [String],
        read: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) },
        destination: @escaping (String) -> Destination?
    ) {
        self.homeDirectory = homeDirectory
        self.bundleID = bundleID
        self.domains = domains
        self.read = read
        self.destination = destination
    }

    /// 옛 컨테이너의 한 도메인 plist 위치
    func legacyFile(domain: String) -> URL {
        homeDirectory.appending(path: "Library/Containers/\(bundleID)/Data/Library/Preferences/\(domain).plist")
    }

    private enum ReadFailure {
        case missing, denied, unreadable
    }

    private static func classify(_ error: Error) -> ReadFailure {
        let outer = error as NSError
        let layers = [outer] + [outer.userInfo[NSUnderlyingErrorKey] as? NSError].compactMap { $0 }
        func posix(_ code: POSIXErrorCode) -> Bool {
            layers.contains { $0.domain == NSPOSIXErrorDomain && $0.code == Int(code.rawValue) }
        }
        func cocoa(_ code: CocoaError.Code) -> Bool {
            layers.contains { $0.domain == NSCocoaErrorDomain && $0.code == code.rawValue }
        }
        if cocoa(.fileReadNoPermission) || posix(.EACCES) || posix(.EPERM) { return .denied }
        if cocoa(.fileReadNoSuchFile) || cocoa(.fileNoSuchFile) || posix(.ENOENT) { return .missing }
        return .unreadable
    }

    @discardableResult
    public func run() -> Report {
        // 표식을 쓸 표준 도메인이 없으면(앱에서는 일어나지 않는다) 하지 않는다: 표식 없이 매번 옮기지 않게
        guard let standard = destination(bundleID) else { return Report() }
        if standard.keys.contains(Self.markerKey) { return Report(alreadyDone: true) }

        var report = Report()
        for domain in domains {
            let data: Data
            do {
                data = try read(legacyFile(domain: domain))
            } catch {
                switch Self.classify(error) {
                case .missing: report.missingDomains += 1
                case .denied: report.deniedDomains += 1
                case .unreadable: report.unreadableDomains += 1
                }
                continue
            }
            guard let old = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
                  let target = destination(domain)
            else {
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

        if report.deniedDomains > 0 {
            // 권한 오류는 완료가 아니다: 표식 없이 횟수만 올리고, 마지막 시도에서만 표식을 쓴다
            report.attempts = (standard.stored[Self.attemptsKey] as? Int ?? 0) + 1
            standard.defaults.set(report.attempts, forKey: Self.attemptsKey)
            if report.attempts >= Self.maxAttempts { writeMarker(standard, &report) }
        } else {
            writeMarker(standard, &report)
        }
        log(report)
        return report
    }

    private func writeMarker(_ standard: Destination, _ report: inout Report) {
        standard.defaults.set(true, forKey: Self.markerKey)
        report.markerWritten = true
    }

    /// 결과는 `.notice`(저장되는 수준), 권한 오류는 `.error`. 개수만: 키 이름 · 값 · 경로는 남기지 않는다
    private func log(_ report: Report) {
        let log = Logger(subsystem: bundleID, category: "legacy-sandbox-migration")
        log.notice(
            "copied \(report.copiedKeys, privacy: .public) kept \(report.keptKeys, privacy: .public) missing \(report.missingDomains, privacy: .public) unreadable \(report.unreadableDomains, privacy: .public) denied \(report.deniedDomains, privacy: .public) marker \(report.markerWritten, privacy: .public)"
        )
        if report.deniedDomains > 0 {
            log.error(
                "permission denied for \(report.deniedDomains, privacy: .public) domain attempt \(report.attempts, privacy: .public) of \(Self.maxAttempts, privacy: .public)"
            )
        }
    }

    /// 실행 인자 영역(`UserDefaults.argumentDomain`)의 `-TF_LEGACY_MIGRATION YES`. 값은 문자열(`YES`)이거나 불리언이다
    public static func debugOptIn(arguments: [String: Any]) -> Bool {
        guard let value = arguments[debugOptInKey] else { return false }
        return (value as? Bool) ?? (value as? String).map { NSString(string: $0).boolValue } ?? false
    }

    /// 앱 시작에서 가장 먼저(어떤 UserDefaults 읽기보다 앞) 한 번 부른다.
    /// 번들 id를 모르거나, 샌드박스 안이거나(환경 변수 또는 홈 디렉터리가 컨테이너), Debug 빌드인데 `debugOptIn`이 꺼져 있으면 아무것도 하지 않고 nil — 표식도 쓰지 않는다
    /// (샌드박스를 끈 배포 빌드가 처음 뜰 때 옮길 수 있게. Debug는 실사용 번들 id를 쓰므로 개발 실행이 실사용 컨테이너를 읽고 표식을 미리 쓰면 안 된다).
    @discardableResult
    public static func runAtLaunch(
        bundleID: String?, environment: [String: String] = ProcessInfo.processInfo.environment, isDebugBuild: Bool, debugOptIn: Bool,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        read: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) },
        destination: ((String) -> Destination?)? = nil
    ) -> Report? {
        guard let bundleID,
              !AgentRuntimeEnvironment.isSandboxed(environment: environment, homeDirectory: homeDirectory.path),
              !isDebugBuild || debugOptIn
        else { return nil }
        return LegacySandboxMigration(
            homeDirectory: homeDirectory, bundleID: bundleID, domains: AppDefaultsDomains.all(bundleID: bundleID), read: read,
            destination: destination ?? { Destination.app(domain: $0, bundleID: bundleID) }
        ).run()
    }
}
#endif
