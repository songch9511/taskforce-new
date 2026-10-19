import Foundation
import Testing

/// Mac 앱 권한 파일 (OA M1a, DEC-1 A): App Sandbox를 끈다. 샌드박스 앱이 띄운 자식 프로세스는 샌드박스를 물려받아 사용자의
/// `claude` · `codex` 로그인(`~/.claude`, Keychain)과 PATH에 닿지 못한다. 배포 빌드에서는 `scripts/release-mac-dmg.sh`가 서명 뒤 같은 것을 한 번 더 막는다.
/// 한계: 이 시험은 소스의 권한 파일과 빌드 설정을 읽는다. 서명된 앱에서 App Group · Keychain 접근이 그대로인지는 서명된 빌드에서만 확인된다.
struct MacEntitlementsTests {
    static let apple = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    static func entitlements() throws -> [String: Any] {
        let data = try Data(contentsOf: apple.appending(path: "Taskforce/Taskforce-macOS.entitlements"))
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return plist
    }

    @Test func theAppSandboxIsOff() throws {
        let plist = try Self.entitlements()
        #expect(plist["com.apple.security.app-sandbox"] == nil)
        // 샌드박스 전용 키: 샌드박스를 끈 앱에는 뜻이 없다
        #expect(plist["com.apple.security.network.client"] == nil)
    }

    @Test func theAppGroupTheKeychainGroupAndPushStay() throws {
        let plist = try Self.entitlements()
        #expect(plist["com.apple.security.application-groups"] as? [String] == ["$(APP_GROUP_ID)"])
        #expect(plist["keychain-access-groups"] as? [String] == ["$(AppIdentifierPrefix)$(APP_BUNDLE_ID)"])
        #expect(plist["com.apple.developer.aps-environment"] as? String == "development")
    }

    /// 빌드 설정 `ENABLE_APP_SANDBOX`를 켜는 줄이 있는지 (주석 줄은 보지 않는다).
    /// 쓰는 모양: xcconfig `= YES`, project.yml `: YES` · `: true` · `: "YES"`, pbxproj `= YES;` · `= "YES";`
    static func turnsTheSandboxOn(_ text: String) -> Bool {
        // 조건부 설정 `ENABLE_APP_SANDBOX[sdk=macosx*] = YES`도 포함. 값 뒤에 영숫자가 이어지면(예: YES_X) 다른 값이다
        guard let setting = try? Regex(#"^\s*ENABLE_APP_SANDBOX(\[[^\]]*\])?\s*[:=]\s*["']?(YES|true)["']?(?![A-Za-z0-9_])"#).ignoresCase() else { return true }
        return text.split(separator: "\n").contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("#") && line.firstMatch(of: setting) != nil
        }
    }

    @Test func theScannerSeesEveryWayToTurnTheSandboxOn() {
        for line in [
            "ENABLE_APP_SANDBOX = YES", "ENABLE_APP_SANDBOX=YES", "    ENABLE_APP_SANDBOX: YES", "ENABLE_APP_SANDBOX: true", "ENABLE_APP_SANDBOX: \"YES\"",
            "ENABLE_APP_SANDBOX: 'YES'", "\t\t\t\tENABLE_APP_SANDBOX = YES;", "ENABLE_APP_SANDBOX = \"YES\";", "ENABLE_APP_SANDBOX = yes", "ENABLE_APP_SANDBOX : TRUE",
            "ENABLE_APP_SANDBOX[sdk=macosx*] = YES",
        ] {
            #expect(Self.turnsTheSandboxOn(line), "켜짐: \(line)")
        }
        for line in [
            "ENABLE_APP_SANDBOX = NO", "ENABLE_APP_SANDBOX: NO", "ENABLE_APP_SANDBOX: false", "ENABLE_APP_SANDBOX: \"NO\"", "ENABLE_APP_SANDBOX = NO;",
            "// ENABLE_APP_SANDBOX = YES", "# ENABLE_APP_SANDBOX: YES", "  # ENABLE_APP_SANDBOX: true", "ENABLE_APP_SANDBOX_EXTRA = YES", "ENABLE_APP_SANDBOX = $(inherited)", "",
        ] {
            #expect(!Self.turnsTheSandboxOn(line), "꺼짐 · 주석: \(line)")
        }
    }

    /// Xcode 15+는 빌드 설정 `ENABLE_APP_SANDBOX = YES`가 있으면 권한 파일과 상관없이 샌드박스 권한을 넣는다.
    /// 설정이 들어올 수 있는 곳 전부: project.yml · 생성된 pbxproj · `Config/*.xcconfig`(로컬 Secrets.xcconfig 포함)
    @Test func noBuildSettingTurnsTheSandboxBackOn() throws {
        let configs = try FileManager.default.contentsOfDirectory(at: Self.apple.appending(path: "Config"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xcconfig" }
        #expect(configs.count >= 3, "Base · Release · DebugTest는 늘 있다")
        let files = [Self.apple.appending(path: "project.yml"), Self.apple.appending(path: "Taskforce.xcodeproj/project.pbxproj")] + configs
        for file in files {
            #expect(!Self.turnsTheSandboxOn(try String(contentsOf: file, encoding: .utf8)), "\(file.lastPathComponent)")
        }
    }

    /// 공증에 필요한 Hardened Runtime은 그대로다
    @Test func hardenedRuntimeStaysOn() throws {
        let yml = try String(contentsOf: Self.apple.appending(path: "project.yml"), encoding: .utf8)
        #expect(yml.contains("ENABLE_HARDENED_RUNTIME: YES"))
    }

    // MARK: 배포 스크립트의 회귀 방지

    /// `scripts/release-mac-dmg.sh`의 검사 함수 하나(`reject_sandbox_entitlement` · `reject_apple_signin_entitlement`)만 떼어 가짜 권한 출력(`codesign -d --entitlements :-`의 plist)에 돌린다.
    /// 서명 · 공증 · DMG는 돌리지 않는다. 종료 코드와 stderr를 돌려준다.
    static func runCheck(_ name: String, onEntitlements plist: String) throws -> (status: Int32, stderr: String) {
        let script = try String(contentsOf: apple.deletingLastPathComponent().appending(path: "scripts/release-mac-dmg.sh"), encoding: .utf8)
        let lines = script.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("\(name)() {") }),
              let end = lines[start...].firstIndex(of: "}") else { throw CocoaError(.fileReadCorruptFile) }
        let directory = FileManager.default.temporaryDirectory.appending(path: "MacEntitlementsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let function = directory.appending(path: "function.sh")
        let entitlements = directory.appending(path: "entitlements.plist")
        try lines[start ... end].joined(separator: "\n").write(to: function, atomically: true, encoding: .utf8)
        try plist.write(to: entitlements, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "set -euo pipefail; fail() { printf '%s\\n' \"$*\" >&2; exit 1; }; source \"$1\"; \"$3\" \"$2\"", "bash", function.path, entitlements.path, name]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func runSandboxCheck(onEntitlements plist: String) throws -> (status: Int32, stderr: String) {
        try runCheck("reject_sandbox_entitlement", onEntitlements: plist)
    }

    static func runAppleSignInCheck(onEntitlements plist: String) throws -> (status: Int32, stderr: String) {
        try runCheck("reject_apple_signin_entitlement", onEntitlements: plist)
    }

    static func plist(_ entries: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>\(entries)</dict></plist>
        """
    }

    static let keptEntries = """
    <key>com.apple.developer.aps-environment</key><string>production</string>
    <key>com.apple.security.application-groups</key><array><string>group.dev.taskforcelabs.taskforce</string></array>
    <key>keychain-access-groups</key><array><string>U9DWQKQFMW.dev.taskforcelabs.taskforce</string></array>
    """

    @Test func theReleaseScriptStopsWhenTheSignedAppKeepsTheSandbox() throws {
        let result = try Self.runSandboxCheck(onEntitlements: Self.plist(Self.keptEntries + "<key>com.apple.security.app-sandbox</key><true/><key>com.apple.security.network.client</key><true/>"))
        #expect(result.status == 1)
        #expect(result.stderr.contains("com.apple.security.app-sandbox"))
        // 키가 있으면(값이 false여도) 멈춘다: Xcode는 끈 샌드박스에 키를 쓰지 않는다
        #expect(try Self.runSandboxCheck(onEntitlements: Self.plist(Self.keptEntries + "<key>com.apple.security.app-sandbox</key><false/>")).status == 1)
    }

    @Test func theReleaseScriptPassesAnAppWithoutTheSandbox() throws {
        let result = try Self.runSandboxCheck(onEntitlements: Self.plist(Self.keptEntries))
        #expect(result.status == 0)
        #expect(result.stderr.isEmpty)
    }

    /// 읽지 못하는 권한 출력은 통과가 아니라 멈춤이다 (열려서 통과하지 않는다)
    @Test func theReleaseScriptStopsWhenTheEntitlementsCannotBeRead() throws {
        #expect(try Self.runSandboxCheck(onEntitlements: "").status == 1)
        #expect(try Self.runSandboxCheck(onEntitlements: "not a plist").status == 1)
    }

    // MARK: Sign in with Apple 권한 (OA 로그인 계약 5.8)

    /// Developer ID Mac 앱은 `com.apple.developer.applesignin` 권한을 프로필로 받을 수 없다 (Apple "Supported capabilities (macOS)": Developer ID 열이 비었다).
    /// 권한 파일에 이 키가 있으면 10-05처럼 Developer ID export가 실패한다. Mac의 Apple 로그인은 브라우저 창(Apple 웹 로그인)이라 이 권한이 필요 없다.
    @Test func theEntitlementsFileHasNoSignInWithApple() throws {
        let plist = try Self.entitlements()
        #expect(plist["com.apple.developer.applesignin"] == nil)
        #expect(!plist.keys.contains { $0.contains("applesignin") })
        let raw = try String(contentsOf: Self.apple.appending(path: "Taskforce/Taskforce-macOS.entitlements"), encoding: .utf8)
        #expect(!raw.contains("applesignin"))
    }

    /// 어느 `.entitlements`에도 없어야 한다 (Mac 앱 · helper 셋)
    @Test func noEntitlementsFileAsksForSignInWithApple() throws {
        let files = try FileManager.default.subpathsOfDirectory(atPath: Self.apple.path).filter { $0.hasSuffix(".entitlements") && !$0.contains("/.build/") && !$0.hasPrefix(".build") }
        #expect(files.contains("Taskforce/Taskforce-macOS.entitlements"))
        for file in files {
            let text = try String(contentsOf: Self.apple.appending(path: file), encoding: .utf8)
            #expect(!text.contains("applesignin"), "\(file)")
        }
    }

    @Test func theReleaseScriptStopsWhenTheSignedAppAsksForSignInWithApple() throws {
        let result = try Self.runAppleSignInCheck(onEntitlements: Self.plist(Self.keptEntries + "<key>com.apple.developer.applesignin</key><array><string>Default</string></array>"))
        #expect(result.status == 1)
        #expect(result.stderr.contains("com.apple.developer.applesignin"))
        // 값이 비어도 키가 있으면 멈춘다
        #expect(try Self.runAppleSignInCheck(onEntitlements: Self.plist(Self.keptEntries + "<key>com.apple.developer.applesignin</key><array/>")).status == 1)
    }

    @Test func theReleaseScriptPassesAnAppWithoutSignInWithApple() throws {
        let result = try Self.runAppleSignInCheck(onEntitlements: Self.plist(Self.keptEntries))
        #expect(result.status == 0)
        #expect(result.stderr.isEmpty)
    }

    /// 읽지 못하는 권한 출력은 통과가 아니라 멈춤이다
    @Test func theAppleSignInCheckStopsWhenTheEntitlementsCannotBeRead() throws {
        #expect(try Self.runAppleSignInCheck(onEntitlements: "").status == 1)
        #expect(try Self.runAppleSignInCheck(onEntitlements: "not a plist").status == 1)
    }

    /// 검사는 샌드박스 검사 바로 뒤, 프로필 검사 · 공증 전에 불린다 (공증까지 가기 전에 멈춘다)
    @Test func theReleaseScriptRunsTheAppleSignInCheckRightAfterTheSandboxCheck() throws {
        let script = try String(contentsOf: Self.apple.deletingLastPathComponent().appending(path: "scripts/release-mac-dmg.sh"), encoding: .utf8)
        let lines = script.components(separatedBy: "\n")
        let sandbox = try #require(lines.firstIndex { $0.hasPrefix("reject_sandbox_entitlement \"$ENTITLEMENTS\"") })
        let appleSignIn = try #require(lines.firstIndex { $0.hasPrefix("reject_apple_signin_entitlement \"$ENTITLEMENTS\"") })
        #expect(appleSignIn > sandbox)
        #expect(appleSignIn - sandbox <= 4)
        let notarize = try #require(lines.firstIndex { $0.hasPrefix("  notarize \"$APP_ZIP\" app") })
        #expect(appleSignIn < notarize)
    }
}
