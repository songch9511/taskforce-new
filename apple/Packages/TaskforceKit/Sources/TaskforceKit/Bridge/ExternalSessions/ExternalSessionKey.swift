#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import Security

/// 서버에 가는 "불투명 id"를 만드는 열쇠 (OA 외부 세션 PR1, 계약 16장 · 17장 D1). 서버는 Claude 세션 UUID를 보지 못한다:
/// `ref = hex(HMAC-SHA256(열쇠, "tf-external-session-v1\n" + 소문자 UUID))`. 열쇠는 이 Mac의 파티션 폴더에만 있고(0600) 서버 · 로그 · 지표 어디에도 가지 않는다.
/// id ↔ UUID 대응은 이 Mac의 메모리에서만 만든다 (`ExternalSessionScanner`가 훑을 때마다 다시 계산한다).
public struct ExternalSessionKey: Sendable {
    static let byteCount = 32
    private let key: SymmetricKey

    public init(bytes: Data) {
        key = SymmetricKey(data: bytes)
    }

    public static func random() -> ExternalSessionKey {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        }
        return ExternalSessionKey(bytes: Data(bytes))
    }

    /// 소문자 hex 64자. 서버 `session_ref` 모양 (`^[0-9a-f]{64}$`)
    public func ref(forSessionID id: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(("tf-external-session-v1\n" + id.lowercased()).utf8), using: key)
        return code.map { String(format: "%02x", $0) }.joined()
    }

    /// 서버에 저장하는 대화 행의 불투명 ref (PR-D3k, 계약 25.2.1 `mac_ref`): `hex(HMAC-SHA256(열쇠, "tf-claude-app-chat-v1\n" + 씨앗))`. 씨앗은 세션 id · 줄 id뿐이고 글은 들어가지 않는다 (`ClaudeAppExchangeCollector`).
    /// 세션 ref와 접두가 달라 서로 겹치지 않는다. 같은 줄은 늘 같은 값이라 두 번 올려도 서버가 한 행으로 받는다
    public func chatRef(_ seed: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(("tf-claude-app-chat-v1\n" + seed).utf8), using: key)
        return code.map { String(format: "%02x", $0) }.joined()
    }

    /// 파일에 쓰는 글(소문자 hex 64자)
    func hex() -> String { key.withUnsafeBytes { Data($0).map { String(format: "%02x", $0) }.joined() } }

    static func parse(hex text: String) -> ExternalSessionKey? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count == byteCount * 2, trimmed.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }) else { return nil }
        var bytes = Data()
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let next = trimmed.index(index, offsetBy: 2)
            guard let byte = UInt8(trimmed[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return ExternalSessionKey(bytes: bytes)
    }
}

/// 열쇠를 두는 곳. 읽지도 만들지도 못하면 던진다 (그때는 서버에 아무것도 보내지 않는다)
public protocol ExternalSessionKeyStore: Sendable {
    func loadOrCreate() throws -> ExternalSessionKey
    /// Sign Out에서 열쇠를 지운다 (`ExternalSessionSignOut`: 서버 목록을 비운 뒤, 없으면 그대로). 계정 삭제는 파티션 폴더째 지워진다
    func delete()
}

public struct ExternalSessionKeyUnavailable: Error, Equatable, Sendable {}

/// 시험 · 메모리 저장소
public final class InMemoryExternalSessionKeyStore: ExternalSessionKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: ExternalSessionKey?

    public init(key: ExternalSessionKey? = nil) { self.key = key }

    public func loadOrCreate() throws -> ExternalSessionKey {
        lock.lock()
        defer { lock.unlock() }
        if let key { return key }
        let created = ExternalSessionKey.random()
        key = created
        return created
    }

    public func delete() {
        lock.lock()
        key = nil
        lock.unlock()
    }
}

/// 파티션 폴더의 `external-sessions.key` (0600, 소문자 hex 64자). 기호 링크 · 남의 파일 · 느슨한 권한 · 깨진 내용이면 지우고 새로 만든다 (그러면 id가 바뀌고 서버 목록은 다음 보고에 교체된다).
/// Sign Out 때 `delete()`로 지운다(그 뒤 로그인하면 새 열쇠). 파티션 폴더는 계정 삭제 때 통째로 지워지므로 열쇠도 함께 지워진다 (`BridgeStorage.deletePartition`)
public final class FileExternalSessionKeyStore: ExternalSessionKeyStore, @unchecked Sendable {
    public static let fileName = "external-sessions.key"
    private let directory: URL
    private let lock = NSLock()

    public init(directory: URL) { self.directory = directory }

    private var file: URL { directory.appending(path: Self.fileName) }

    public func loadOrCreate() throws -> ExternalSessionKey {
        lock.lock()
        defer { lock.unlock() }
        if let existing = Self.readExisting(file.path) { return existing }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        unlink(file.path)
        let created = ExternalSessionKey.random()
        let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ExternalSessionKeyUnavailable() }
        defer { close(fd) }
        let bytes = Array((created.hex() + "\n").utf8)
        guard write(fd, bytes, bytes.count) == bytes.count else {
            unlink(file.path)
            throw ExternalSessionKeyUnavailable()
        }
        return created
    }

    public func delete() {
        lock.lock()
        unlink(file.path)
        lock.unlock()
    }

    private static func readExisting(_ path: String) -> ExternalSessionKey? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_size <= 256 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 256)
        let count = read(fd, &buffer, buffer.count)
        guard count > 0 else { return nil }
        return ExternalSessionKey.parse(hex: String(decoding: buffer[0..<count], as: UTF8.self))
    }
}
#endif
