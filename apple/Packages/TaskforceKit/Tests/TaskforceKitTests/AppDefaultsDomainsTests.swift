import Foundation
import Testing
@testable import TaskforceKit

/// 앱이 쓰는 UserDefaults 도메인 목록 (`AppDefaultsDomains`)이 코드의 `UserDefaults(suiteName:)` 사용과 맞는지 (OA M1a).
/// 목록에 없는 suite를 만들면 샌드박스 컨테이너의 그 suite 값이 1회 이전에서 빠진다. 새 suite를 만들면 이 시험이 실패해서 목록을 고치게 한다.
struct AppDefaultsDomainsTests {
    static let bundleID = "dev.test.taskforce"

    /// 앱 소스(Kit + 앱 타깃)에서 `UserDefaults(suiteName:)`를 부르는 곳의 인자 식. 파일 경로(apple/ 기준) → 인자들
    /// (주석 줄은 설명이므로 코드 줄만 본다)
    static func suiteCallSites() throws -> [String: [String]] {
        let apple = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let roots = ["Taskforce", "Packages/TaskforceKit/Sources"].map { apple.appending(path: $0, directoryHint: .isDirectory) }
        let start = try Regex(#"UserDefaults\s*\(\s*suiteName\s*:"#)
        var found: [String: [String]] = [:]
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                for line in code {
                    for match in line.matches(of: start) {
                        // 짝이 맞는 닫는 괄호까지가 인자 식
                        var depth = 0
                        var argument = ""
                        scan: for character in line[match.range.upperBound...] {
                            switch character {
                            case "(": depth += 1
                            case ")":
                                if depth == 0 { break scan }
                                depth -= 1
                            default: break
                            }
                            argument.append(character)
                        }
                        found[String(url.path.dropFirst(apple.path.count + 1)), default: []].append(argument.trimmingCharacters(in: .whitespaces))
                    }
                }
            }
        }
        return found
    }

    @Test func everySuiteTheAppOpensIsInTheDomainList() throws {
        let found = try Self.suiteCallSites()
        // 알려진 사용처: 고정 저장(`EdgeShell`)은 목록의 suite를 연다. 1회 이전(`Destination.app`)은 목록의 도메인을 그대로 연다.
        // 여기에 없는 새 `UserDefaults(suiteName:)`가 생기면 이 시험이 실패한다 → `AppDefaultsDomains.suiteSuffixes`에 더하고 이 표를 고친다.
        let known = [
            "Taskforce/Mac/Edge/EdgeShell.swift": ["WorkPinStore.suiteName(bundleID: bundleID)"],
            "Packages/TaskforceKit/Sources/TaskforceKit/LegacySandboxMigration.swift": ["domain"],
        ]
        #expect(found == known)

        // 알려진 사용처가 여는 이름이 곧 목록이다
        let opened = Set([WorkPinStore.suiteName(bundleID: Self.bundleID)])
        #expect(Set(AppDefaultsDomains.suites(bundleID: Self.bundleID)) == opened)
    }

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
