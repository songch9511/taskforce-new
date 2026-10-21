#if os(macOS)
import Darwin
import Foundation

/// 작업 폴더의 프로젝트 지침 (`CLAUDE.md` · `.claude/CLAUDE.md`). Taskforce가 띄운 `claude`는 격리된 빈 cwd에서 `--setting-sources project`로 돌아
/// 저장소의 CLAUDE.md가 들어오지 않는다 (CC-14). 그래서 Taskforce가 읽어 시작 프롬프트(`--append-system-prompt-file`)에 붙인다 (사용자 결정, 외부 세션 계약 19장).
/// 새 세션과 이어받은 세션 · 다음 턴 · 답 · 닫기 모두 같은 규칙이다 (spawn마다 읽는다). 단 CLI의 시스템 프롬프트 스냅샷이 켜져 있으면(기본) 이어받은 턴은
/// 첫 spawn의 프롬프트를 그대로 쓴다: 중간에 바뀐 CLAUDE.md는 새 세션부터 적용된다 (`docs/agent-gateway.md`). `@import` 줄과 `CLAUDE.local.md`는 다루지 않는다.
///
/// 읽을 때 지키는 것 (글을 지어낼 수 없고 작업 폴더 밖을 읽지 못하게):
/// - `O_NOFOLLOW`로 열고 정규 파일 · 이 사용자 소유 · 하드 링크 아님 · 이 Mac의 로컬 볼륨(`MNT_LOCAL`)만 읽는다.
///   열린 파일의 실제 경로(`F_GETPATH`)가 작업 폴더 안이어야 한다 (중간 폴더가 밖을 가리키는 링크여도 열린 파일로 확인한다)
/// - 두 파일을 합쳐 64 KiB까지만 (글자 경계에서 자른다). 잘리거나 한도 때문에 못 들어온 파일은 프롬프트에 그렇게 적는다
/// - UTF-8만 (NUL이 든 글 · 다른 인코딩은 건너뛴다)
/// - 읽을 수 없으면 조용히 건너뛰고 건너뛴 수만 센다. 글 · 이름 · 경로는 로그 · 서버 어디에도 가지 않는다 (이 Mac → 모델 공급자로만)
public struct ClaudeProjectInstructions: Equatable, Sendable {
    public struct File: Equatable, Sendable {
        /// 작업 폴더 기준 고정 이름 (`CLAUDE.md` 또는 `.claude/CLAUDE.md`)
        public var name: String
        public var text: String
        /// 합쳐 64 KiB 한도 때문에 뒤가 잘렸다
        public var truncated: Bool

        public init(name: String, text: String, truncated: Bool) {
            self.name = name
            self.text = text
            self.truncated = truncated
        }
    }

    public struct Outcome: Equatable, Sendable {
        public var instructions: ClaudeProjectInstructions
        /// 있었지만 쓸 수 없어 건너뛴 파일 수 (링크 · 밖 · 정규 파일 아님 · 소유자 · 로컬 볼륨 아님 · UTF-8 아님 · 읽기 실패). 없는 파일 · 빈 파일은 세지 않는다
        public var skipped: Int

        public init(instructions: ClaudeProjectInstructions, skipped: Int) {
            self.instructions = instructions
            self.skipped = skipped
        }
    }

    /// 두 파일을 합친 상한 (바이트)
    public static let limitBytes = 64 * 1024
    /// 읽는 순서
    public static let candidates = ["CLAUDE.md", ".claude/CLAUDE.md"]

    public var files: [File]
    /// 한도가 이미 찼을 때 나중에 와서 아예 들어오지 못한(또는 한도에서 잘라 보일 것이 남지 않은) 파일 이름
    public var omitted: [String]

    public init(files: [File] = [], omitted: [String] = []) {
        self.files = files
        self.omitted = omitted
    }

    public var isEmpty: Bool { files.isEmpty && omitted.isEmpty }
    public var byteCount: Int { files.reduce(0) { $0 + $1.text.utf8.count } }
    public var wasCut: Bool { !omitted.isEmpty || files.contains(where: \.truncated) }

    /// 프롬프트에 글로 넣어도 되는 경로인가: 비어 있지 않고 제어(Cc) · 서식(Cf: 보이지 않는 글자 · 방향 바꿈) · 줄(Zl) · 문단(Zp) 구분 글자가 없다.
    /// 폴더 이름으로 프롬프트에 글을 끼워 넣거나 보이는 모양을 속일 수 없게 한다 (검토 보안 P3-2)
    public static func isPlain(path: String) -> Bool {
        guard !path.isEmpty else { return false }
        return !path.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: true
            default: false
            }
        }
    }

    /// 지침 블록 표지에 쓰는 spawn마다 새 꼬리표 (무작위 64비트, 16자 16진수): 파일 글이 닫는 표지를 흉내 낼 수 없다
    public static func newTag() -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        arc4random_buf(&bytes, bytes.count)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// 열린 파일이 이 Mac의 로컬 볼륨에 있나 (`fstatfs`의 `MNT_LOCAL`). 네트워크 볼륨은 열기부터 막힐 수 있고 우리 것이라 믿을 수 없다 (검토 보안 P3-4)
    public static func isLocalVolume(_ fd: Int32) -> Bool {
        var info = statfs()
        guard fstatfs(fd, &info) == 0 else { return false }
        return info.f_flags & UInt32(MNT_LOCAL) != 0
    }

    private enum Read {
        case absent
        case blank
        case skipped
        case noRoom
        case file(File, bytes: Int)
    }

    /// 작업 폴더(절대 경로, 평범한 글자만)의 지침 파일들을 읽는다. 막힐 수 있는 파일 읽기라 호출하는 쪽이 actor 밖에서 · 기한을 두고 부른다.
    /// `isLocal`은 시험이 볼륨 판정을 바꾸는 자리다
    public static func read(workspace: String, limitBytes: Int = limitBytes, isLocal: (Int32) -> Bool = isLocalVolume) -> Outcome {
        let none = Outcome(instructions: ClaudeProjectInstructions(), skipped: 0)
        guard workspace.hasPrefix("/"), isPlain(path: workspace), let root = canonical(directory: workspace) else { return none }
        var instructions = ClaudeProjectInstructions()
        var skipped = 0
        var used = 0
        for name in candidates {
            switch readFile(root: root, name: name, room: limitBytes - used, isLocal: isLocal) {
            case .absent, .blank: continue
            case .skipped: skipped += 1
            case .noRoom: instructions.omitted.append(name)
            case .file(let file, let bytes):
                instructions.files.append(file)
                used += bytes
            }
        }
        return Outcome(instructions: instructions, skipped: skipped)
    }

    /// 열린 폴더의 실제 경로 (`F_GETPATH`: 열린 파일의 실제 경로와 같은 표기라 대소문자 · 유니코드 형태 차이로 "밖"이 되지 않는다)
    private static func canonical(directory path: String) -> String? {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        return openPath(fd)
    }

    private static func openPath(_ fd: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard fcntl(fd, F_GETPATH, &buffer) != -1 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func readFile(root: String, name: String, room: Int, isLocal: (Int32) -> Bool) -> Read {
        // 마지막 이름이 링크면 열리지 않는다 (ELOOP). FIFO에 막히지 않게 `O_NONBLOCK`
        let fd = open(root + "/" + name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY | O_CLOEXEC)
        if fd < 0 { return errno == ENOENT || errno == ENOTDIR ? .absent : .skipped }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1, isLocal(fd) else { return .skipped }
        // 열린 파일이 정말 작업 폴더 안인가 (`.claude`가 밖을 가리키는 링크인 경우까지)
        guard let real = openPath(fd), real != root, GateFileSystem.isInside(real, root: root) else { return .skipped }
        // 한도 + 1바이트까지 읽어 잘렸는지 안다
        let want = max(room, 0) + 1
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count < want {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, min($0.count, want - data.count)) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { return .skipped }
            if count == 0 { break }
            data.append(contentsOf: chunk[0..<count])
        }
        if data.isEmpty { return .blank }
        guard room > 0 else { return .noRoom }
        let cut = data.count > room
        if cut { data = data.prefix(room) }
        guard !data.contains(0), var text = decodeUTF8(data, cutAtLimit: cut) else { return .skipped }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 한도에서 잘라 보일 것이 남지 않았다(앞이 공백뿐이거나 첫 글자가 한도보다 크다): 뒤의 글이 조용히 사라지지 않게 못 들어온 파일로 적는다
        if text.isEmpty { return cut ? .noRoom : .blank }
        return .file(File(name: name, text: text, truncated: cut), bytes: data.count)
    }

    /// 엄격한 UTF-8. 한도에서 자른 글은 끝의 **미완성 글자**만 버린다 (중간의 잘못된 바이트는 그대로 거절)
    private static func decodeUTF8(_ data: Data, cutAtLimit: Bool) -> String? {
        let body = cutAtLimit ? data.dropLast(incompleteTail(of: data)) : data[...]
        return String(data: Data(body), encoding: .utf8)
    }

    /// 끝에 있는 미완성 UTF-8 글자의 바이트 수 (완전하면 0)
    private static func incompleteTail(of data: Data) -> Int {
        let bytes = Array(data.suffix(3))
        for back in 1...max(bytes.count, 1) where back <= bytes.count {
            let byte = bytes[bytes.count - back]
            if byte & 0xC0 == 0x80 { continue }
            let needed = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            return back < needed ? back : 0
        }
        return 0
    }
}
#endif
