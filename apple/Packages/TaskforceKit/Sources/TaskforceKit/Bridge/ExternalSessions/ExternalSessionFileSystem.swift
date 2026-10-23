#if os(macOS)
import Darwin
import Foundation

/// 외부 세션 발견이 만지는 파일 시스템 사실 (OA 외부 세션 PR1, 계약 9장 T2 · T3 · T8). 시험은 임시 폴더 위의 가짜 홈으로 `.live(home:)`를 쓰거나 이 구조체의 닫힘을 바꿔 끼운다.
///
/// 읽는 이름은 허용 목록뿐이다 (`ExternalSessionReadAllowList`): `projects/<디렉터리>/<소문자 UUID>.jsonl`과 `sessions/<숫자>.json`.
/// `.credentials.json` · `~/.claude.json` · `sessions/*.key` · 데스크톱 앱 저장소는 열지 않는다. 모든 읽기는 기호 링크를 따라가지 않고 이 사용자 소유 일반 파일만 연다.
public struct ExternalSessionFileSystem: Sendable {
    public struct Entry: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case regular, directory, symlink, other }
        public var name: String
        public var kind: Kind
        public var owner: UInt32
        public var size: Int64
        public var modified: Date
        public var created: Date
        /// 권한 비트 (`st_mode & 0o7777`). 모르면 0 (아무도 쓸 수 없다고 본다)
        public var mode: UInt16

        public init(name: String, kind: Kind, owner: UInt32, size: Int64, modified: Date, created: Date, mode: UInt16 = 0) {
            self.name = name
            self.kind = kind
            self.owner = owner
            self.size = size
            self.modified = modified
            self.created = created
            self.mode = mode
        }

        /// 소유자가 아닌 쪽(그룹 · 모두)이 쓸 수 있다
        public var othersCanWrite: Bool { mode & 0o022 != 0 }
    }

    public enum Listing: Equatable, Sendable {
        case entries([Entry])
        /// 그 폴더가 없다 (`ENOENT`)
        case missing
        /// 있는데 읽을 수 없다
        case failed
    }

    public var userID: UInt32
    /// `realpath(3)`. 없거나 읽을 수 없으면 nil
    public var realpath: @Sendable (String) -> String?
    /// `lstat(2)`: 기호 링크를 따라가지 않는다. `name`은 마지막 성분
    public var lstat: @Sendable (String) -> Entry?
    /// 폴더 항목을 **최대 `limit`개까지만** 읽고 멈춘다 (큰 폴더를 끝까지 읽지 않는다). `limit`보다 많았는지는 호출하는 쪽이 `limit + 1`을 요청해 알아낸다
    public var list: @Sendable (_ path: String, _ limit: Int) -> Listing
    /// `[offset, offset + length)`를 읽는다 (파일이 짧으면 그만큼). 기호 링크 · 일반 파일 아님 · 남의 파일 · 열 수 없음은 nil
    public var read: @Sendable (_ path: String, _ offset: Int64, _ length: Int) -> Data?

    public init(
        userID: UInt32, realpath: @escaping @Sendable (String) -> String?, lstat: @escaping @Sendable (String) -> Entry?, list: @escaping @Sendable (String, Int) -> Listing,
        read: @escaping @Sendable (String, Int64, Int) -> Data?
    ) {
        self.userID = userID
        self.realpath = realpath
        self.lstat = lstat
        self.list = list
        self.read = read
    }

    public static let live = ExternalSessionFileSystem(
        userID: getuid(), realpath: { GateFileSystem.realpath($0) }, lstat: { Live.lstat($0) }, list: { Live.list($0, limit: $1) }, read: { Live.read($0, offset: $1, length: $2) }
    )

    enum Live {
        /// NUL로 끝나는 `[CChar]` → 글 (끝의 NUL 앞까지)
        static func string(fromCString buffer: [CChar]) -> String {
            String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }

        static func kind(of mode: mode_t) -> Entry.Kind {
            switch mode & S_IFMT {
            case S_IFREG: .regular
            case S_IFDIR: .directory
            case S_IFLNK: .symlink
            default: .other
            }
        }

        static func entry(name: String, _ info: stat) -> Entry {
            Entry(
                name: name, kind: kind(of: info.st_mode), owner: info.st_uid, size: Int64(info.st_size),
                modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9),
                created: Date(timeIntervalSince1970: TimeInterval(info.st_birthtimespec.tv_sec) + TimeInterval(info.st_birthtimespec.tv_nsec) / 1e9),
                mode: UInt16(truncatingIfNeeded: info.st_mode & 0o7777)
            )
        }

        static func lstat(_ path: String) -> Entry? {
            guard !path.utf8.contains(0) else { return nil }
            var info = stat()
            guard Darwin.lstat(path, &info) == 0 else { return nil }
            return entry(name: (path as NSString).lastPathComponent, info)
        }

        static func list(_ path: String, limit: Int) -> Listing {
            guard !path.utf8.contains(0) else { return .failed }
            guard let dir = opendir(path) else { return errno == ENOENT ? .missing : .failed }
            defer { closedir(dir) }
            let fd = dirfd(dir)
            var entries: [Entry] = []
            while entries.count < max(0, limit), let item = readdir(dir) {
                let name = withUnsafePointer(to: &item.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                entries.append(entry(name: name, info))
            }
            return .entries(entries)
        }

        /// 기호 링크를 따라가지 않고(`O_NOFOLLOW`), 막히지 않게(`O_NONBLOCK`) 열어 이 사용자 소유 일반 파일일 때만 읽는다. 중간 성분이 기호 링크로 바뀌었으면(열린 파일의 실제 경로가 다르면) 읽지 않는다
        static func read(_ path: String, offset: Int64, length: Int) -> Data? {
            guard !path.utf8.contains(0), offset >= 0, length > 0 else { return nil }
            let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else { return nil }
            var actual = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(fd, F_GETPATH, &actual) == 0, string(fromCString: actual) == path else { return nil }
            var buffer = [UInt8](repeating: 0, count: length)
            var filled = 0
            while filled < length {
                let count = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress!.advanced(by: filled), length - filled, off_t(offset) + off_t(filled)) }
                if count < 0 {
                    if errno == EINTR { continue }
                    return nil
                }
                if count == 0 { break }
                filled += count
            }
            return Data(buffer[0..<filled])
        }
    }
}

/// 열어도 되는 파일 이름의 허용 목록 (T8). 발견 코드는 이 검사를 지나지 않은 경로를 열지도 나열하지도 않는다
public enum ExternalSessionReadAllowList {
    /// `<projects>/<디렉터리>/<소문자 UUID>.jsonl`의 이름 부분
    public static func isTranscript(file name: String) -> Bool { ExternalSessionRules.sessionID(fromFileName: name) != nil }

    /// `<sessions>/<pid>.json`의 이름 부분: 숫자 1–10자 + `.json`뿐 (`<pid>.<hash>.key`는 열지 않는다)
    public static func isRegistry(file name: String) -> Bool {
        guard name.hasSuffix(".json") else { return false }
        let stem = name.dropLast(".json".count)
        return (1...10).contains(stem.utf8.count) && stem.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }

    /// 프로젝트 디렉터리 이름: 영숫자와 `-`뿐 (Claude Code가 cwd에서 만든 이름 · 해시 붙은 긴 이름)
    public static func isProjectDirectory(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 400 && name.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D }
    }
}
#endif
