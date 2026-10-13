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

    /// Xcode 15+는 빌드 설정 `ENABLE_APP_SANDBOX = YES`가 있으면 권한 파일과 상관없이 샌드박스 권한을 넣는다
    @Test func noBuildSettingTurnsTheSandboxBackOn() throws {
        for file in ["project.yml", "Taskforce.xcodeproj/project.pbxproj"] {
            let text = try String(contentsOf: Self.apple.appending(path: file), encoding: .utf8)
            #expect(!text.contains("ENABLE_APP_SANDBOX = YES") && !text.contains("ENABLE_APP_SANDBOX: YES"), "\(file)")
        }
    }

    /// 공증에 필요한 Hardened Runtime은 그대로다
    @Test func hardenedRuntimeStaysOn() throws {
        let yml = try String(contentsOf: Self.apple.appending(path: "project.yml"), encoding: .utf8)
        #expect(yml.contains("ENABLE_HARDENED_RUNTIME: YES"))
    }

    // MARK: 배포 스크립트의 회귀 방지

    /// `scripts/release-mac-dmg.sh`의 `reject_sandbox_entitlement`만 떼어 가짜 권한 출력(`codesign -d --entitlements :-`의 plist)에 돌린다.
    /// 서명 · 공증 · DMG는 돌리지 않는다. 종료 코드와 stderr를 돌려준다.
    static func runSandboxCheck(onEntitlements plist: String) throws -> (status: Int32, stderr: String) {
        let script = try String(contentsOf: apple.deletingLastPathComponent().appending(path: "scripts/release-mac-dmg.sh"), encoding: .utf8)
        let lines = script.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("reject_sandbox_entitlement() {") }),
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
        process.arguments = ["-c", "set -euo pipefail; fail() { printf '%s\\n' \"$*\" >&2; exit 1; }; source \"$1\"; reject_sandbox_entitlement \"$2\"", "bash", function.path, entitlements.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
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
}
