#if os(macOS)
import Foundation
import Testing
@testable import TaskforceKit

/// 앱이 쓰는 UserDefaults 도메인 목록 (`AppDefaultsDomains`)이 코드가 여는 설정 도메인과 맞는지 (OA M1a).
/// 목록에 없는 suite를 만들면 샌드박스 컨테이너의 그 suite 값이 1회 이전에서 빠진다. 새 suite를 만들면 이 시험이 실패해서 목록을 고치게 한다.
struct AppDefaultsDomainsTests {
    static let bundleID = "dev.test.taskforce"

    /// 소스 한 개에서 앱이 (표준 도메인 밖의) 설정 도메인을 여는 곳. 공백을 뺀 인자 식 / 이름:
    /// `UserDefaults(…)` 호출(여러 줄 포함) · `.init(suiteName:…)` · `CFPreferences…` 함수. 주석은 설명이므로 보지 않는다.
    static func domainUsages(in source: String) throws -> [String] {
        // 블록 주석(여러 줄 가능)과 줄 주석 줄을 뺀다
        let withoutBlocks = source.replacing(try Regex(#"/\*[\s\S]*?\*/"#), with: "")
        let code = withoutBlocks.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        /// `open` 바로 뒤부터 짝이 맞는 닫는 괄호 앞까지 (줄 바꿈 포함), 공백은 뺀다
        func arguments(from open: String.Index) -> String {
            var depth = 0
            var text = ""
            scan: for character in code[open...] {
                switch character {
                case "(": depth += 1
                case ")":
                    if depth == 0 { break scan }
                    depth -= 1
                default: break
                }
                if !character.isWhitespace { text.append(character) }
            }
            return text
        }

        var found: [(offset: Int, usage: String)] = []
        func collect(_ pattern: String, usage: (Regex<AnyRegexOutput>.Match) -> String) throws {
            for match in code.matches(of: try Regex(pattern)) {
                found.append((code.distance(from: code.startIndex, to: match.range.lowerBound), usage(match)))
            }
        }
        try collect(#"UserDefaults\s*\("#) { arguments(from: $0.range.upperBound) }
        try collect(#"\.init\s*\(\s*suiteName\s*:"#) { "suiteName:" + arguments(from: $0.range.upperBound) }
        try collect(#"CFPreferences\w*"#) { String(code[$0.range]) }
        return found.sorted { $0.offset < $1.offset }.map(\.usage)
    }

    /// 앱 소스(Kit + 앱 타깃) 전체: 파일 경로(apple/ 기준) → 사용처들
    static func repositoryUsages() throws -> [String: [String]] {
        let apple = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let roots = ["Taskforce", "Packages/TaskforceKit/Sources"].map { apple.appending(path: $0, directoryHint: .isDirectory) }
        var found: [String: [String]] = [:]
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let usages = try domainUsages(in: String(contentsOf: url, encoding: .utf8))
                if !usages.isEmpty { found[String(url.path.dropFirst(apple.path.count + 1))] = usages }
            }
        }
        return found
    }

    @Test func everySettingsDomainTheAppOpensIsInTheDomainList() throws {
        let found = try Self.repositoryUsages()
        // 알려진 사용처: 고정 저장(`EdgeShell`)은 목록의 suite를 연다. 1회 이전(`Destination.app`)은 목록의 도메인을 그대로 연다.
        // 여기에 없는 새 `UserDefaults(suiteName:)` · `.init(suiteName:)` · `CFPreferences…`가 생기면 이 시험이 실패한다
        // → `AppDefaultsDomains.suiteSuffixes`에 더하고 이 표를 고친다.
        let known = [
            "Taskforce/Mac/Edge/EdgeShell.swift": ["suiteName:WorkPinStore.suiteName(bundleID:bundleID)"],
            "Packages/TaskforceKit/Sources/TaskforceKit/LegacySandboxMigration.swift": ["suiteName:domain"],
        ]
        #expect(found == known)

        // 알려진 사용처가 여는 이름이 곧 목록이다
        let opened = Set([WorkPinStore.suiteName(bundleID: Self.bundleID)])
        #expect(Set(AppDefaultsDomains.suites(bundleID: Self.bundleID)) == opened)
    }

    // MARK: 검사기 자체

    @Test func theScannerSeesMultiLineCallsInitAndCFPreferences() throws {
        let source = """
        let a = UserDefaults(
            suiteName: WorkPinStore.suiteName(
                bundleID: bundleID
            )
        )
        let b: UserDefaults? = .init(suiteName: other)
        let c = UserDefaults.init(suiteName: viaInit)
        let d = UserDefaults(suiteName: "literal")
        let e = CFPreferencesCopyAppValue("k" as CFString, "dev.x" as CFString)
        CFPreferencesSetAppValue("k" as CFString, nil, "dev.x" as CFString)
        """
        #expect(try Self.domainUsages(in: source) == [
            "suiteName:WorkPinStore.suiteName(bundleID:bundleID)",
            "suiteName:other",
            "suiteName:viaInit",
            "suiteName:\"literal\"",
            "CFPreferencesCopyAppValue",
            "CFPreferencesSetAppValue",
        ])
    }

    @Test func theScannerIgnoresCommentsAndTheStandardDomain() throws {
        let source = """
        // UserDefaults(suiteName: a)
        /// 설명: UserDefaults(suiteName: b), CFPreferencesCopyAppValue
        /* UserDefaults(
             suiteName: c
           ) */
        let defaults: UserDefaults = .standard
        func load(from defaults: UserDefaults = .standard) -> UserDefaults? { defaults }
        let flag = UserDefaults.standard.bool(forKey: "k")
        """
        #expect(try Self.domainUsages(in: source).isEmpty)
    }

    // MARK: 목록

    @Test func theListIsTheStandardDomainPlusEverySuiteWithoutDuplicates() {
        let all = AppDefaultsDomains.all(bundleID: Self.bundleID)
        #expect(all.first == Self.bundleID, "표준 도메인(번들 id)이 먼저")
        #expect(Set(all).count == all.count)
        #expect(all.dropFirst().allSatisfy { $0.hasPrefix(Self.bundleID + ".") }, "suite는 번들 id 뒤에 붙는다 (앱의 기본 설정 파일과 섞이지 않는다)")
        #expect(all.count == 1 + AppDefaultsDomains.suiteSuffixes.count)
    }

    @Test func theWorkPinSuiteKeepsItsNameSoOldPinsStayReachable() {
        #expect(WorkPinStore.suiteName(bundleID: "dev.taskforcelabs.taskforce") == "dev.taskforcelabs.taskforce.work-pins")
        #expect(AppDefaultsDomains.all(bundleID: "dev.taskforcelabs.taskforce") == ["dev.taskforcelabs.taskforce", "dev.taskforcelabs.taskforce.work-pins"])
    }
}
#endif
