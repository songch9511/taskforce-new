#if os(macOS)
import CryptoKit
import Darwin
import Foundation

/// 번들 mod `tf-relay`의 파일 셋과 해시 (PR-D3k, 계약 25.4.2 · 위협 DT7). mod는 서명된 앱 번들 안 읽기 전용 경로(`Taskforce.app/Contents/Resources/tf-relay/`)에 있고,
/// `claude --plugin-dir`는 그 경로만 쓴다. **띄우기 전에** 파일 셋과 SHA-256이 이 상수와 한 글자도 다르지 않은지 본다: 다르면 중계를 띄우지 않는다.
/// mod를 고치면 이 상수도 함께 고친다 (시험이 저장소의 mod 파일과 이 상수를 늘 맞춰 본다)
public enum ClaudeAppRelayMod {
    /// mod 이름: 받는 쪽 기록의 peer `plugin` 칸이 이 이름이다 (`ClaudeAppPeer.taskforceRelayPlugin`)
    public static let pluginName = "tf-relay"
    /// `/tfping` 답의 `version` 칸: mod를 고치면서 선 규약이 바뀌면 올린다
    public static let version = "1"

    public struct File: Equatable, Sendable {
        /// mod 폴더 안의 경로
        public let path: String
        public let sha256: String
    }

    public enum Verification: Equatable, Sendable {
        case ok
        /// 있어야 할 파일(또는 폴더)이 없다
        case missing(String)
        /// 내용이 상수와 다르다
        case mismatch(String)
        /// 목록에 없는 항목이 있다
        case unexpected(String)
        /// 기호 링크 · 일반 파일 아님 · 남의 소유 · 다른 사용자가 쓸 수 있음 · 읽을 수 없음 (`.`은 폴더 자체)
        case unsafe(String)
    }

    /// 앱 번들에 들어가는 파일 전부 (`project.yml`이 같은 세 파일만 복사한다)
    public static let files: [File] = [
        File(path: ".claude-plugin/plugin.json", sha256: "271c3ac886b1811d5cae52c5d4ade63fd74118d6ef03a160208591f1fee6d41a"),
        File(path: "hooks/hooks.json", sha256: "6cf6e720e75976f93eb01f7c1337a5226a463e86ae105cedc887c4329849d66f"),
        File(path: "hooks/register.js", sha256: "165c7247d9855b0b11c5b9dba01528d4e248bd88a3380c016778dc48e6922ebe"),
    ]

    /// 한 파일의 상한: 이보다 큰 파일은 읽지 않는다 (mod는 작다)
    static let maxFileBytes = 64 * 1024

    /// 막히는 호출이다 (파일 읽기). 폴더 자체가 기호 링크이거나 파일 · 폴더가 기호 링크 · 남의 소유 · 다른 사용자가 쓸 수 있으면 읽지 않고 거절한다
    public static func verify(directory: String, fileSystem: ExternalSessionFileSystem = .live) -> Verification {
        guard let root = fileSystem.lstat(directory) else { return .missing(".") }
        guard isSafe(root, fileSystem), root.kind == .directory, let real = fileSystem.realpath(directory) else { return .unsafe(".") }
        let directories = Dictionary(grouping: files, by: { ($0.path as NSString).deletingLastPathComponent })
        // 최상위: 목록의 폴더만
        guard case .entries(let top) = fileSystem.list(real, 64) else { return .unsafe(".") }
        for entry in top where directories[entry.name] == nil { return .unexpected(entry.name) }
        for name in directories.keys.sorted() {
            guard let folder = fileSystem.lstat(real + "/" + name) else { return .missing(name) }
            guard folder.kind == .directory, isSafe(folder, fileSystem) else { return .unsafe(name) }
            guard case .entries(let inside) = fileSystem.list(real + "/" + name, 64) else { return .unsafe(name) }
            let expected = Set((directories[name] ?? []).map { ($0.path as NSString).lastPathComponent })
            for entry in inside where !expected.contains(entry.name) { return .unexpected(name + "/" + entry.name) }
        }
        for file in files {
            guard let entry = fileSystem.lstat(real + "/" + file.path) else { return .missing(file.path) }
            guard entry.kind == .regular, isSafe(entry, fileSystem), entry.size <= Int64(maxFileBytes) else { return .unsafe(file.path) }
            guard let data = fileSystem.read(real + "/" + file.path, 0, maxFileBytes + 1), data.count <= maxFileBytes else { return .unsafe(file.path) }
            guard hex(SHA256.hash(data: data)) == file.sha256 else { return .mismatch(file.path) }
        }
        return .ok
    }

    /// 이 사용자나 root의 것이고 그룹 · 모두가 쓸 수 없다
    private static func isSafe(_ entry: ExternalSessionFileSystem.Entry, _ fileSystem: ExternalSessionFileSystem) -> Bool {
        (entry.owner == fileSystem.userID || entry.owner == 0) && !entry.othersCanWrite
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
#endif
