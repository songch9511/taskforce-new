import Foundation
import Testing
@testable import Taskforce

/// `BRIDGE_ENABLED` (Mac, OA D2b 계약 2.14 · 4.2 M1) · Release에 가짜가 없다는 소스 검사 (M8의 앞부분, 바이너리 검사는 notes의 명령)
struct BridgeFlagTests {
    private static var on: [String: Any] { ["TaskforceBridgeEnabled": "YES"] }
    private static var off: [String: Any] { ["TaskforceBridgeEnabled": "NO"] }
    private static var argumentOn: [String: Any] { ["TF_BRIDGE": "YES"] }

    @Test func everyConfigurationDefaultsToOff() {
        for debug in [true, false] {
            #expect(!BridgeFlag.isEnabled(info: Self.off, arguments: [:], isDebugBuild: debug))
            #expect(!BridgeFlag.isEnabled(info: Self.off, arguments: Self.argumentOn, isDebugBuild: debug), "인자만으로는 켜지지 않는다")
            #expect(!BridgeFlag.isEnabled(info: nil, arguments: Self.argumentOn, isDebugBuild: debug))
        }
    }

    @Test func releaseFollowsTheBuildSettingAlone() {
        #expect(BridgeFlag.isEnabled(info: Self.on, arguments: [:], isDebugBuild: false))
        #expect(BridgeFlag.isEnabled(info: Self.on, arguments: Self.argumentOn, isDebugBuild: false))
    }

    @Test func debugNeedsBothTheBuildSettingAndTheLaunchArgument() {
        #expect(!BridgeFlag.isEnabled(info: Self.on, arguments: [:], isDebugBuild: true))
        #expect(!BridgeFlag.isEnabled(info: Self.on, arguments: ["TF_BRIDGE": "NO"], isDebugBuild: true))
        #expect(BridgeFlag.isEnabled(info: Self.on, arguments: Self.argumentOn, isDebugBuild: true))
        #expect(BridgeFlag.isEnabled(info: Self.on, arguments: ["TF_BRIDGE": true], isDebugBuild: true))
    }

    @Test func savedDefaultsNeverEnableIt() throws {
        let store = try TestDefaults()
        defer { store.cleanup() }
        store.defaults.set("YES", forKey: "TF_BRIDGE")
        // 저장된 값은 인자 영역에 없다: 인자 영역만 읽는다
        let arguments = store.defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        #expect(arguments["TF_BRIDGE"] == nil)
        #expect(!BridgeFlag.isEnabled(info: Self.on, arguments: arguments, isDebugBuild: true))
    }

    @Test func unresolvedOrUnknownValuesAreOff() {
        for value in ["$(TF_BRIDGE_ENABLED)", "", "   ", "maybe", "off", "2"] {
            #expect(!BridgeFlag.isEnabled(info: ["TaskforceBridgeEnabled": value], arguments: Self.argumentOn, isDebugBuild: false), "\(value.debugDescription)")
        }
        for value in ["YES", "yes", "true", " TRUE ", "1"] {
            #expect(BridgeFlag.isEnabled(info: ["TaskforceBridgeEnabled": value], arguments: [:], isDebugBuild: false), "\(value.debugDescription)")
        }
    }

    @Test func theFakeAgentExistsOnlyInDebugWithItsOwnArgument() {
        let local = URL(string: "http://localhost:3000")!
        #expect(!BridgeFlag.usesFakeAgent(arguments: [:], isDebugBuild: true, apiBaseURL: local))
        #expect(BridgeFlag.usesFakeAgent(arguments: ["TF_BRIDGE_FAKE_AGENT": "YES"], isDebugBuild: true, apiBaseURL: local))
        #expect(!BridgeFlag.usesFakeAgent(arguments: ["TF_BRIDGE_FAKE_AGENT": "YES"], isDebugBuild: false, apiBaseURL: local), "Release는 인자가 있어도 가짜를 쓰지 않는다")
    }

    /// 가짜 agent는 이 Mac의 개발 서버(loopback)일 때만: 실제 서버에서 받은 명령을 가짜가 수행한 것처럼 보고하지 않는다 (검토 반영 7장 D · security 9)
    @Test func theFakeAgentIsNeverConnectedToARealServer() {
        let arguments = ["TF_BRIDGE_FAKE_AGENT": "YES"]
        for loopback in ["http://localhost:3000", "http://127.0.0.1:3000", "http://[::1]:3000", "http://dev.localhost:3000"] {
            #expect(BridgeFlag.usesFakeAgent(arguments: arguments, isDebugBuild: true, apiBaseURL: URL(string: loopback)!), "\(loopback)")
        }
        for real in ["https://taskforce.example.com", "https://localhost.evil.com", "http://192.168.0.5:3000", "https://api.taskforcelabs.dev"] {
            #expect(!BridgeFlag.usesFakeAgent(arguments: arguments, isDebugBuild: true, apiBaseURL: URL(string: real)!), "\(real)")
        }
    }

    // MARK: 실제 Claude Code adapter (OA D3a Q14)

    @Test func theRealAgentArgumentWorksOnlyInDebugAgainstALoopbackServer() {
        let arguments: [String: Any] = ["TF_BRIDGE_REAL_AGENT": "YES"]
        let local = URL(string: "http://localhost:3000")!
        #expect(BridgeFlag.usesRealAgent(arguments: arguments, isDebugBuild: true, apiBaseURL: local))
        #expect(!BridgeFlag.usesRealAgent(arguments: arguments, isDebugBuild: false, apiBaseURL: local), "Release는 인자를 읽지 않는다")
        #expect(!BridgeFlag.usesRealAgent(arguments: [:], isDebugBuild: true, apiBaseURL: local))
        #expect(!BridgeFlag.usesRealAgent(arguments: ["TF_BRIDGE_REAL_AGENT": "NO"], isDebugBuild: true, apiBaseURL: local))
        #expect(!BridgeFlag.usesRealAgent(arguments: arguments, isDebugBuild: true, apiBaseURL: URL(string: "https://api.taskforcelabs.dev")!), "운영 서버에는 R2를 돌리지 않는다")
    }

    @Test func theDisposableWorkspaceArgumentIsDebugOnly() {
        #expect(BridgeFlag.disposableWorkspace(arguments: ["TF_BRIDGE_WORKSPACE": " /Users/u/tf-d3a/proj "], isDebugBuild: true) == "/Users/u/tf-d3a/proj")
        #expect(BridgeFlag.disposableWorkspace(arguments: ["TF_BRIDGE_WORKSPACE": "/Users/u/tf-d3a/proj"], isDebugBuild: false) == nil)
        #expect(BridgeFlag.disposableWorkspace(arguments: ["TF_BRIDGE_WORKSPACE": ""], isDebugBuild: true) == nil)
        #expect(BridgeFlag.disposableWorkspace(arguments: [:], isDebugBuild: true) == nil)
    }

    /// D3a의 Debug 전용 이름도 앱 소스에서는 `#if DEBUG` 안에만 나온다 (M6의 앞부분)
    @Test func claudeCodeDebugToolsAreNamedOnlyInsideDebugConditionals() throws {
        let names = ["DisposableWorkspaces", "ClaudeCodeEvidenceRunner", "FakeClaudeCode"]
        for (path, text) in try UpdaterSources.appSwiftSources() {
            var depth = 0
            var debugDepth: [Int] = []
            for (number, raw) in text.components(separatedBy: "\n").enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("#if") {
                    depth += 1
                    if line.contains("DEBUG") && !line.contains("!DEBUG") { debugDepth.append(depth) }
                } else if line.hasPrefix("#else") || line.hasPrefix("#elseif") {
                    if debugDepth.last == depth { debugDepth.removeLast() }
                } else if line.hasPrefix("#endif") {
                    if debugDepth.last == depth { debugDepth.removeLast() }
                    depth -= 1
                }
                if line.hasPrefix("//") || line.hasPrefix("///") { continue }
                for name in names where line.contains(name) {
                    #expect(!debugDepth.isEmpty, "\(path):\(number + 1)의 \(name)는 #if DEBUG 안에 있어야 한다")
                }
            }
        }
    }

    @Test func thisTestHostRunsWithTheBridgeOffAndNoFakeAgent() {
        #expect(!BridgeFlag.current)
        #expect(!BridgeFlag.currentUsesFakeAgent(apiBaseURL: URL(string: "http://localhost:3000")!))
    }

    // MARK: Info.plist · 빌드 설정 (M1b U3 방식)

    @Test func theInfoPlistTakesTheKeyFromTheBuildSetting() throws {
        let data = try Data(contentsOf: UpdaterSources.apple.appending(path: "Taskforce/Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
        #expect(plist["TaskforceBridgeEnabled"] as? String == "$(TF_BRIDGE_ENABLED)")
        // 장치 secret의 Keychain 접근 그룹은 entitlements의 앱 전용 그룹과 같은 값이다 (App Group이 아니다)
        #expect(plist["TaskforceKeychainAccessGroup"] as? String == "$(AppIdentifierPrefix)$(APP_BUNDLE_ID)")
        let entitlements = try Data(contentsOf: UpdaterSources.apple.appending(path: "Taskforce/Taskforce-macOS.entitlements"))
        let values = try #require(try PropertyListSerialization.propertyList(from: entitlements, options: [], format: nil) as? [String: Any])
        #expect((values["keychain-access-groups"] as? [String]) == ["$(AppIdentifierPrefix)$(APP_BUNDLE_ID)"])
    }

    @Test func anUnsignedHostHasNoUsableKeychainAccessGroup() {
        #expect(BridgeFlag.keychainAccessGroup == nil, "서명 없는 빌드는 접두가 비어 그룹을 지정하지 않는다")
    }

    @Test func baseAndReleaseSetItToNOAndDebugTestInheritsIt() throws {
        let base = try UpdaterSources.text("Config/Base.xcconfig")
        #expect(UpdaterSources.assignment("TF_BRIDGE_ENABLED", in: base) == "NO")
        let release = try UpdaterSources.text("Config/Release.xcconfig")
        #expect(UpdaterSources.assignment("TF_BRIDGE_ENABLED", in: release) == "NO")
        let debugTest = try UpdaterSources.text("Config/DebugTest.xcconfig")
        #expect(UpdaterSources.assignment("TF_BRIDGE_ENABLED", in: debugTest) == nil, "Debug-Test는 Base 값을 그대로 쓴다")
    }

    @Test func theBuiltDebugHostCarriesTheKeyAsNO() throws {
        let info = try #require(Bundle.main.infoDictionary)
        #expect(info["TaskforceBridgeEnabled"] as? String == "NO")
    }

    // MARK: 가짜는 Debug에만 (소스 검사)

    /// 앱 소스에서 가짜 이름이 나오는 줄은 모두 `#if DEBUG` 안이다 (Release 바이너리에 가짜가 없다는 것의 앞부분. 바이너리 검사는 notes)
    @Test func fakesAreNamedOnlyInsideDebugConditionals() throws {
        let fakes = ["FakeAgentProcess", "FakeBridgeServer", "FakeBridgeWake", "ManualBridgeClock", "BridgeLatencyReport"]
        for (path, text) in try UpdaterSources.appSwiftSources() {
            var depth = 0
            var debugDepth: [Int] = []
            for (number, raw) in text.components(separatedBy: "\n").enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("#if") {
                    depth += 1
                    if line.contains("DEBUG") && !line.contains("!DEBUG") { debugDepth.append(depth) }
                } else if line.hasPrefix("#else") || line.hasPrefix("#elseif") {
                    if debugDepth.last == depth { debugDepth.removeLast() }
                } else if line.hasPrefix("#endif") {
                    if debugDepth.last == depth { debugDepth.removeLast() }
                    depth -= 1
                }
                if line.hasPrefix("//") || line.hasPrefix("///") { continue }
                for fake in fakes where line.contains(fake) {
                    #expect(!debugDepth.isEmpty, "\(path):\(number + 1)의 \(fake)는 #if DEBUG 안에 있어야 한다")
                }
            }
        }
    }
}
