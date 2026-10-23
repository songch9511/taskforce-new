#if os(macOS) && DEBUG
import Darwin
import Foundation
import Testing
@testable import TaskforceKit

extension ExternalSessionSuites {
    /// 번들 mod `tf-relay`의 파일 해시 확인 (PR-D3k, 계약 25.4.2 · 위협 DT7): 띄우기 **전에** 파일 셋과 SHA-256이 상수와 한 글자도 다르지 않아야 한다.
    /// 저장소의 실제 mod 파일(`apple/Taskforce/Resources/tf-relay`)과 상수가 같은지도 시험이 늘 본다 (mod를 고치고 상수를 안 고치면 빌드가 먼저 알린다)
    struct ClaudeAppRelayModTests {
        /// 저장소의 mod 폴더 (이 시험 파일 기준 `apple/Taskforce/Resources/tf-relay`)
        static var repositoryMod: String {
            var url = URL(fileURLWithPath: #filePath)
            for _ in 0..<6 { url.deleteLastPathComponent() }
            return url.appending(path: "Taskforce/Resources/tf-relay", directoryHint: .isDirectory).path
        }

        private func copy(_ source: String = repositoryMod) throws -> String {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("tf-mod-\(UUID().uuidString.lowercased())", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let real = GateFileSystem.realpath(root.path) ?? root.path
            let target = real + "/tf-relay"
            try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
            for file in ClaudeAppRelayMod.files {
                let destination = target + "/" + file.path
                try FileManager.default.createDirectory(atPath: (destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try FileManager.default.copyItem(atPath: source + "/" + file.path, toPath: destination)
            }
            return target
        }

        private func cleanup(_ path: String) { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }

        @Test func theRepositoryModMatchesTheHashConstantsFileForFile() throws {
            // 저장소의 mod 폴더에는 mod 시험(`tests/`)도 있다: 앱 번들에 가는 세 파일만 복사해 본다 (project.yml이 같은 세 파일만 번들에 넣는다)
            let bundled = try copy()
            defer { cleanup(bundled) }
            #expect(ClaudeAppRelayMod.verify(directory: bundled) == .ok)
            #expect(ClaudeAppRelayMod.files.map(\.path).sorted() == [".claude-plugin/plugin.json", "hooks/hooks.json", "hooks/register.js"])
            #expect(ClaudeAppRelayMod.files.allSatisfy { $0.sha256.wholeMatch(of: /[0-9a-f]{64}/) != nil })
        }

        @Test func anUntouchedCopyPasses() throws {
            let copy = try copy()
            defer { cleanup(copy) }
            #expect(ClaudeAppRelayMod.verify(directory: copy) == .ok)
        }

        @Test func aFileChangedByOneByteIsRefusedAndNamed() throws {
            // DT7: 해시 다른 mod → 중계 띄우기 0
            for file in ClaudeAppRelayMod.files {
                let copy = try copy()
                defer { cleanup(copy) }
                let path = copy + "/" + file.path
                var bytes = try Data(contentsOf: URL(fileURLWithPath: path))
                bytes.append(0x20)
                try bytes.write(to: URL(fileURLWithPath: path))
                #expect(ClaudeAppRelayMod.verify(directory: copy) == .mismatch(file.path), "\(file.path)")
            }
        }

        @Test func aMissingFileOrAnExtraFileOrAFolderOfTheWrongKindIsRefused() throws {
            let missing = try copy()
            defer { cleanup(missing) }
            try FileManager.default.removeItem(atPath: missing + "/hooks/hooks.json")
            #expect(ClaudeAppRelayMod.verify(directory: missing) == .missing("hooks/hooks.json"))

            let extra = try copy()
            defer { cleanup(extra) }
            try "export const x = 1\n".write(toFile: extra + "/hooks/extra.js", atomically: false, encoding: .utf8)
            #expect(ClaudeAppRelayMod.verify(directory: extra) == .unexpected("hooks/extra.js"), "목록에 없는 파일은 허용하지 않는다")

            let nested = try copy()
            defer { cleanup(nested) }
            try FileManager.default.createDirectory(atPath: nested + "/tests", withIntermediateDirectories: true)
            try "x".write(toFile: nested + "/tests/a.ts", atomically: false, encoding: .utf8)
            #expect(ClaudeAppRelayMod.verify(directory: nested) != .ok)

            #expect(ClaudeAppRelayMod.verify(directory: "/nonexistent-tf-relay-folder") != .ok)
        }

        @Test func aSymlinkInsteadOfAFileOrFolderIsRefused() throws {
            let linkedFile = try copy()
            defer { cleanup(linkedFile) }
            let outside = (linkedFile as NSString).deletingLastPathComponent + "/outside.js"
            try FileManager.default.copyItem(atPath: linkedFile + "/hooks/register.js", toPath: outside)
            try FileManager.default.removeItem(atPath: linkedFile + "/hooks/register.js")
            try FileManager.default.createSymbolicLink(atPath: linkedFile + "/hooks/register.js", withDestinationPath: outside)
            #expect(ClaudeAppRelayMod.verify(directory: linkedFile) != .ok, "내용이 같아도 기호 링크는 안 된다")

            let linkedDirectory = try copy()
            defer { cleanup(linkedDirectory) }
            let alias = (linkedDirectory as NSString).deletingLastPathComponent + "/alias"
            try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: linkedDirectory)
            #expect(ClaudeAppRelayMod.verify(directory: alias) != .ok, "폴더 자체가 기호 링크면 읽지 않는다")
        }

        @Test func aFolderOrFileOthersCanWriteIsRefused() throws {
            let writableFile = try copy()
            defer { cleanup(writableFile) }
            chmod(writableFile + "/hooks/register.js", 0o666)
            #expect(ClaudeAppRelayMod.verify(directory: writableFile) == .unsafe("hooks/register.js"))

            let writableFolder = try copy()
            defer { cleanup(writableFolder) }
            chmod(writableFolder + "/hooks", 0o777)
            #expect(ClaudeAppRelayMod.verify(directory: writableFolder) == .unsafe("hooks"))
        }

        @Test func theModNameIsTheOneTheTranscriptCarriesAsThePeerPlugin() {
            #expect(ClaudeAppRelayMod.pluginName == ClaudeAppPeer.taskforceRelayPlugin)
        }
    }
}
#endif
