import Foundation
import Testing
@testable import Taskforce

/// 내부 배포 빌드 변형 (OA 내부 DMG, 사용자 결정 2026-10-21): 내부 DMG에서는 0.2.0 표면(Edge 셸 전부 · 0.2.0 설정 창 · Claude Code bridge)을 켠다.
/// 기본 Release(`EdgeSurfaces.release`)는 그대로다. 스위치는 Info.plist `TaskforceInternalBuild`(빌드 설정 `TF_INTERNAL_BUILD`, 기본 NO) 하나이고
/// 스크립트 `scripts/release-mac-dmg.sh --internal`이 `TF_INTERNAL_BUILD=YES TF_BRIDGE_ENABLED=YES`로 아카이브할 때만 켜진다.
/// 한계: Debug 시험 호스트는 Release 쪽 분기(`#else`)를 실행하지 못한다 — 그 분기가 읽는 값(`EdgeSurfaces.shipped(info:)`)을 시험하고,
/// 분기가 그 값만 읽는지는 소스 검사로, 실제 바이너리는 Release 빌드 두 벌(기본 · 내부)의 Info.plist로 확인한다.
struct InternalBuildTests {
    static let key = "TaskforceInternalBuild"
    static var on: [String: Any] { [key: "YES"] }
    static var off: [String: Any] { [key: "NO"] }

    // MARK: 표면 값

    @Test func theInternalSetTurnsOnEveryZeroTwoZeroSurface() {
        let internalSet = EdgeSurfaces.internalBuild
        #expect(internalSet == EdgeSurfaces(shell: true, review: true, summary: true, chats: true, projects: true, settingsWindow: true))
        #expect(internalSet.assistantWindows, "Assistant 창")
        #expect(internalSet.agentQuestions, "에이전트 질문 카드")
        #expect(internalSet.allowsIssueScreens(flag: true), "Projects · 이슈 · 세션 패널")
        #expect(internalSet.allowsTaskforceConversation(issueScreens: internalSet.allowsIssueScreens(flag: true)), "Taskforce 대화")
        #expect(MacSettingsRootKind(surfaces: internalSet) == .window, "0.2.0 설정 창")
    }

    /// 내부 표면은 Debug의 다섯 인자(`-TF_EDGE_SHELL -TF_S4 -TF_C3 -TF_S3B -TF_U2`)가 켜는 것과 같다 — 새 조합을 만들지 않는다
    @Test func theInternalSetIsWhatDebugGivesWithEveryFlagOn() throws {
        let store = try TestDefaults()
        defer { store.cleanup() }
        for flagKey in [EdgeShellFlag.key, S4Flag.key, C3Flag.key, S3bFlag.key, EdgeSurfaces.issueScreensKey] { store.defaults.set(true, forKey: flagKey) }
        #expect(EdgeSurfaces.debug(store.defaults) == .internalBuild)
        #expect(EdgeSurfaces.issueScreens(store.defaults, debugBuild: true) == EdgeSurfaces.internalBuild.allowsIssueScreens(flag: true))
        #expect(EdgeSurfaces.taskforceConversation(store.defaults, debugBuild: true))
    }

    @Test func thePlainReleaseSetIsUnchanged() {
        let release = EdgeSurfaces.release
        #expect(release == EdgeSurfaces(shell: true, review: true, summary: true, chats: false, projects: false, settingsWindow: false))
        #expect(!release.assistantWindows && !release.agentQuestions && !release.allowsIssueScreens(flag: true))
        #expect(MacSettingsRootKind(surfaces: release) == .legacy)
    }

    // MARK: Info.plist 스위치

    @Test func theInfoPlistFlagPicksTheInternalSet() {
        #expect(EdgeSurfaces.shipped(info: Self.on) == .internalBuild)
        for yes in ["YES", "yes", "true", "1", " YES "] {
            #expect(EdgeSurfaces.shipped(info: [Self.key: yes]) == .internalBuild, "\(yes.debugDescription)")
        }
        #expect(EdgeSurfaces.shipped(info: [Self.key: true]) == .internalBuild)
    }

    /// 없음 · NO · 빈 값 · 풀리지 않은 `$(…)` · 모르는 글자는 모두 기본 Release다 (기본 꺼짐)
    @Test func everythingElseKeepsThePlainReleaseSet() {
        let others: [[String: Any]?] = [
            nil, [:], Self.off, [Self.key: ""], [Self.key: "$(TF_INTERNAL_BUILD)"], [Self.key: "maybe"], [Self.key: "no"], [Self.key: false], [Self.key: 0],
            ["TaskforceBridgeEnabled": "YES"],
        ]
        for info in others {
            #expect(EdgeSurfaces.shipped(info: info) == .release, "\(String(describing: info))")
        }
    }

    /// Release 쪽 문(이슈 화면 · Taskforce 대화)도 같은 스위치를 따른다: 기본 Release는 늘 false, 내부 빌드는 true.
    /// Debug 빌드는 Info.plist를 보지 않고 launch argument만 따른다
    @Test func theNonDebugGatesFollowTheSwitchAndDebugIgnoresIt() throws {
        #expect(EdgeSurfaces.issueScreens(debugBuild: false, info: Self.on))
        #expect(!EdgeSurfaces.issueScreens(debugBuild: false, info: Self.off))
        #expect(!EdgeSurfaces.issueScreens(debugBuild: false, info: nil))
        #expect(EdgeSurfaces.taskforceConversation(debugBuild: false, info: Self.on))
        #expect(!EdgeSurfaces.taskforceConversation(debugBuild: false, info: Self.off))
        #expect(!EdgeSurfaces.taskforceConversation(debugBuild: false, info: nil))
        let store = try TestDefaults()
        defer { store.cleanup() }
        #expect(!EdgeSurfaces.issueScreens(store.defaults, debugBuild: true, info: Self.on), "Debug는 스위치가 켜져 있어도 인자가 없으면 꺼짐")
        #expect(!EdgeSurfaces.taskforceConversation(store.defaults, debugBuild: true, info: Self.on))
        #expect(EdgeSurfaces.shipped(info: Self.on).assistantWindows && !EdgeSurfaces.shipped(info: Self.off).assistantWindows)
        #expect(EdgeSurfaces.shipped(info: Self.on).agentQuestions && !EdgeSurfaces.shipped(info: Self.off).agentQuestions)
    }

    /// bridge는 기존 문(`TaskforceBridgeEnabled`)을 그대로 쓴다: 스위치(`TaskforceInternalBuild`)와 별개이고, Release는 Info.plist만 본다
    @Test func theBridgeKeepsItsOwnExistingGate() {
        #expect(BridgeFlag.infoKey == "TaskforceBridgeEnabled")
        #expect(BridgeFlag.isEnabled(info: ["TaskforceBridgeEnabled": "YES"], arguments: [:], isDebugBuild: false))
        #expect(!BridgeFlag.isEnabled(info: Self.on, arguments: [:], isDebugBuild: false), "내부 빌드 스위치만으로는 bridge가 켜지지 않는다 (스크립트가 둘을 함께 준다)")
    }

    // MARK: 지금 이 호스트 · 설정 파일

    /// 시험 호스트(Debug-Test)는 스위치가 꺼져 있다: 키는 있고 값은 NO
    @Test func theTestHostCarriesTheSwitchOff() throws {
        let info = try #require(Bundle.main.infoDictionary)
        #expect(info[Self.key] as? String == "NO")
        #expect(EdgeSurfaces.shipped(info: info) == .release)
        #expect(EdgeSurfaces.shippedForThisBuild == .release)
    }

    @Test func theSwitchComesFromABuildSettingThatDefaultsToNo() throws {
        let data = try Data(contentsOf: UpdaterSources.apple.appending(path: "Taskforce/Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
        #expect(plist[Self.key] as? String == "$(TF_INTERNAL_BUILD)")
        let base = try UpdaterSources.text("Config/Base.xcconfig")
        #expect(UpdaterSources.assignment("TF_INTERNAL_BUILD", in: base) == "NO")
        let release = try UpdaterSources.text("Config/Release.xcconfig")
        #expect(UpdaterSources.assignment("TF_INTERNAL_BUILD", in: release) == "NO", "기본 Release는 꺼짐으로 낸다")
        let debugTest = try UpdaterSources.text("Config/DebugTest.xcconfig")
        #expect(UpdaterSources.assignment("TF_INTERNAL_BUILD", in: debugTest) == nil, "Debug-Test는 Base 값을 그대로 쓴다")
        // 기본 Release의 bridge는 지금처럼 꺼짐 (내부 배포만 명령줄로 켠다)
        #expect(UpdaterSources.assignment("TF_BRIDGE_ENABLED", in: release) == "NO")
        #expect(UpdaterSources.assignment("TF_BRIDGE_ENABLED", in: base) == "NO")
    }

    /// Release 갈래는 `shipped`가 정한 값만 읽는다: 다른 곳에서 `EdgeSurfaces.release`를 바로 읽으면 내부 빌드에서 그 갈래만 꺼진 채로 남는다.
    /// (주석 줄과 Debug 전용 합성 조작 하네스 `EdgeInteractionRelease`는 제외. `EdgeSurfaces.swift`에서는 `shipped` 안의 한 곳만 허용)
    @Test func noNonDebugBranchReadsTheReleaseSetDirectly() throws {
        var readers: [String] = []
        for (path, text) in try UpdaterSources.appSwiftSources() where path != "Taskforce/Mac/Edge/EdgeInteractionRelease.swift" {
            for (index, raw) in text.components(separatedBy: "\n").enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("//") { continue }
                if line.contains("EdgeSurfaces.release") { readers.append("\(path):\(index + 1)") }
            }
        }
        #expect(readers == [], "EdgeSurfaces.shippedForThisBuild를 쓰세요: \(readers)")
    }

    // MARK: 배포 스크립트

    private static func scriptText() throws -> String { try ReleaseAppcastScriptTests.scriptText() }

    /// 함수 하나만 떼어 정해진 변수로 돌린다 (서명 · 공증 · 빌드는 돌지 않는다)
    private static func runFunction(_ name: String, variables: [String: String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let lines = try scriptText().components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("\(name)() {") }),
              let end = lines[start...].firstIndex(of: "}") else { throw CocoaError(.fileReadCorruptFile) }
        let directory = FileManager.default.temporaryDirectory.appending(path: "InternalBuildTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let function = directory.appending(path: "function.sh")
        try lines[start ... end].joined(separator: "\n").write(to: function, atomically: true, encoding: .utf8)
        let assignments = variables.sorted { $0.key < $1.key }.map { "\($0.key)='\($0.value)'" }.joined(separator: "; ")
        return try ReleaseAppcastScriptTests.bash(["-c", "set -euo pipefail; \(assignments); source \"$1\"; \(name)", "bash", function.path])
    }

    private static let common = ["VERSION": "0.2.0", "BUILD": "7", "SOURCE_COMMIT": "abc123", "BUILD_TIME_UTC": "2026-10-21T00:00:00Z"]

    private static func settings(internal isInternal: Bool) throws -> [String] {
        let result = try runFunction("archive_settings", variables: common.merging(["INTERNAL": isInternal ? "1" : "0"]) { $1 })
        #expect(result.status == 0, "\(result.stderr)")
        return result.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    /// --internal이 없으면 아카이브에 넘기는 설정은 지금과 한 글자도 다르지 않다 (기존 다섯 줄 그대로)
    @Test func withoutInternalTheArchiveSettingsAreExactlyTheOldFive() throws {
        #expect(try Self.settings(internal: false) == [
            "MARKETING_VERSION=0.2.0", "CURRENT_PROJECT_VERSION=7", "TF_RELEASE_CHANNEL=Beta", "TF_SOURCE_COMMIT=abc123", "TF_BUILD_TIME_UTC=2026-10-21T00:00:00Z",
        ])
    }

    @Test func internalAddsExactlyTheSwitchAndTheBridge() throws {
        let plain = try Self.settings(internal: false)
        let internalSettings = try Self.settings(internal: true)
        #expect(internalSettings == plain + ["TF_INTERNAL_BUILD=YES", "TF_BRIDGE_ENABLED=YES"])
    }

    @Test func internalOnlyChangesTheOutputName() throws {
        for (flag, expected) in [("0", "Taskforce-0.2.0-7"), ("1", "Taskforce-0.2.0-7-internal")] {
            let result = try Self.runFunction("release_name", variables: Self.common.merging(["INTERNAL": flag]) { $1 })
            #expect(result.status == 0, "\(result.stderr)")
            #expect(result.stdout == expected, "INTERNAL=\(flag): \(result.stdout)")
        }
    }

    @Test func theFlagIsParsedAndDocumented() throws {
        let help = try ReleaseAppcastScriptTests.bash([ReleaseAppcastScriptTests.scriptURL.path, "--help"])
        #expect(help.status == 0)
        #expect(help.stdout.contains("--internal"))
        // 아직 --version이 없어서 (아무것도 하기 전에) 멈춘다: --internal은 모르는 인자가 아니다
        let accepted = try ReleaseAppcastScriptTests.bash([ReleaseAppcastScriptTests.scriptURL.path, "--internal"])
        #expect(accepted.status != 0)
        #expect(accepted.stderr.contains("--version") && !accepted.stderr.contains("모르는 인자"), "\(accepted.stderr)")
        let unknown = try ReleaseAppcastScriptTests.bash([ReleaseAppcastScriptTests.scriptURL.path, "--internl"])
        #expect(unknown.stderr.contains("모르는 인자"))
    }

    /// 아카이브는 설정을 한 곳(`archive_settings`)에서만 받는다: 명령줄에 손으로 쓴 설정이 따로 남아 있지 않다
    @Test func theArchiveTakesItsSettingsFromOnePlace() throws {
        let lines = try Self.scriptText().components(separatedBy: "\n")
        let archive = try #require(lines.firstIndex { $0.contains("xcodebuild archive") })
        let call = lines[archive...].prefix { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n")
        #expect(call.contains("\"${ARCHIVE_SETTINGS[@]}\""))
        for name in ["MARKETING_VERSION=", "CURRENT_PROJECT_VERSION=", "TF_RELEASE_CHANNEL=", "TF_SOURCE_COMMIT=", "TF_BUILD_TIME_UTC=", "TF_INTERNAL_BUILD=", "TF_BRIDGE_ENABLED="] {
            #expect(!call.contains(name), "명령줄에 손으로 쓴 \(name)")
        }
    }

    /// --internal은 공증 · 서명 · 권한 검사 · Gatekeeper를 건드리지 않는다: 그 줄들은 INTERNAL을 한 번도 말하지 않는다
    @Test func internalNeverTouchesNotarizationOrTheEntitlementGuards() throws {
        let script = try Self.scriptText()
        let guardWords = ["notarize", "stapler", "codesign", "reject_sandbox_entitlement", "reject_apple_signin_entitlement", "spctl", "SKIP_NOTARIZE", "aps-environment", "hdiutil"]
        for (index, raw) in script.components(separatedBy: "\n").enumerated() where raw.contains("INTERNAL") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            for word in guardWords {
                #expect(!line.contains(word), "\(index + 1): INTERNAL 줄이 \(word)을 말한다: \(line)")
            }
        }
        // 기존 검사는 그대로 있다
        for kept in ["reject_apple_signin_entitlement \"$ENTITLEMENTS\"", "reject_sandbox_entitlement \"$ENTITLEMENTS\"", "notarize \"$APP_ZIP\" app", "notarize \"$DMG\" dmg"] {
            #expect(script.contains(kept), Comment(rawValue: kept))
        }
    }

    /// 내부 DMG는 공개 업데이트 피드(appcast)에 올리지 않는다: --internal이면 appcast 단계를 건너뛴다 (공증은 한다)
    @Test func anInternalDmgIsKeptOutOfTheAppcast() throws {
        let lines = try Self.scriptText().components(separatedBy: "\n")
        let call = try #require(lines.firstIndex { $0.hasPrefix("  make_appcast ") })
        let guardIndex = try #require(lines[..<call].lastIndex { $0.contains("(( INTERNAL ))") && $0.hasPrefix("elif") })
        #expect(guardIndex < call)
        #expect(lines[guardIndex + 1].contains("appcast: 건너뜀") && lines[guardIndex + 1].contains("--internal"))
    }
}
