#if os(macOS)
import Darwin
import Foundation

/// 파일 시스템 사실 (OA D3a 계약 2.7 · 13.4.1-1). 판정은 서버가 하고 Mac은 이 사실만 확인한다.
/// realpath는 `realpath(3)`로 본다 (Foundation `resolvingSymlinksInPath`는 쓰지 않는다, D3c-2 notes :346)
public struct GateFileSystem: Sendable {
    public var realpath: @Sendable (String) -> String?
    /// `lstat(2)`: 그 이름에 무엇이든 있으면 true (끊어진 기호 링크 · 읽을 수 없는 항목 · 파일 아래 경로 포함). 없을 때(`ENOENT`)만 false
    public var exists: @Sendable (String) -> Bool

    public init(realpath: @escaping @Sendable (String) -> String?, exists: @escaping @Sendable (String) -> Bool = GateFileSystem.lexists) {
        self.realpath = realpath
        self.exists = exists
    }

    public static let live = GateFileSystem(realpath: GateFileSystem.realpath)

    public static func lexists(_ path: String) -> Bool {
        guard !path.utf8.contains(0) else { return true }
        var info = stat()
        if lstat(path, &info) == 0 { return true }
        return errno != ENOENT
    }

    /// `realpath(3)`. 없거나 읽을 수 없으면 nil
    public static func realpath(_ path: String) -> String? {
        guard !path.isEmpty, !path.utf8.contains(0), let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// `root` 자신이거나 그 아래 (글자 접두가 아니라 경로 성분으로 본다)
    public static func isInside(_ path: String, root: String) -> Bool {
        if root == "/" { return path.hasPrefix("/") }
        return path == root || path.hasPrefix(root + "/")
    }

    /// 실제 경로. 없는 경로는 있는 가장 가까운 조상의 realpath + 나머지. 나머지에 `.` · `..` · 빈 성분이 있거나 절대 경로가 아니면 nil (밖으로 본다).
    /// realpath로 풀리지 않은 성분에 **무엇이든 있으면**(끊어진 기호 링크 · 읽을 수 없는 항목) nil이다: 정말 없는 성분만 이어 붙인다 (8장 1)
    public func resolve(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
        if let real = realpath(path) { return real }
        var components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var remainder: [String] = []
        while components.count > 1 {
            if exists(components.joined(separator: "/")) { return nil }
            remainder.insert(components.removeLast(), at: 0)
            let prefix = components.count == 1 ? "/" : components.joined(separator: "/")
            if let base = realpath(prefix) {
                guard !remainder.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
                return (base == "/" ? "" : base) + "/" + remainder.joined(separator: "/")
            }
        }
        return nil
    }

    /// `path`를 `cwd` 기준 절대 경로로 (이미 절대면 그대로). `~`로 시작하면 nil (셸 확장을 짐작하지 않는다)
    public static func absolute(_ path: String, cwd: String) -> String? {
        guard !path.isEmpty, !path.hasPrefix("~") else { return nil }
        return path.hasPrefix("/") ? path : (cwd.hasSuffix("/") ? cwd + path : cwd + "/" + path)
    }

    /// 넘긴 PATH에서 이름을 찾는다 (처음 있는 실행 파일, 셸과 같은 순서)
    public func lookup(_ name: String, path: String) -> String? {
        guard !name.isEmpty, !name.contains("/") else { return nil }
        for directory in path.split(separator: ":", omittingEmptySubsequences: true) where directory.hasPrefix("/") {
            let candidate = "\(directory)/\(name)"
            if access(candidate, X_OK) == 0, let real = realpath(candidate), FileManager.default.fileExists(atPath: real) {
                var info = stat()
                if stat(real, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG { return candidate }
            }
        }
        return nil
    }
}

/// 서버가 허용한 읽기 전용 명령을 Mac에서 확인하고 다시 만든다 (계약 13.4.1-1 ①② · -4, P2, 8장 3).
/// ⓪ `argv[0]`이 서버 목록(`allowedCommands`)에 있고, 원래 명령을 같은 단순 단어 규칙으로 나눈 결과가 서버 `argv`(경로 바꾸기 전)와 같다 (전송 안전 규칙, 판정 아님).
/// ① `argv[0]`을 넘긴 PATH로 찾은 실행 파일의 realpath가 `/bin` · `/usr/bin` 바로 아래이고 그 이름이 명령 이름과 같다 (PATH 링크 `cat → rm` 거절),
/// ② 경로마다 realpath가 작업 폴더 안.
/// 다시 만든 명령: 첫 단어 = ①의 실제 경로, 경로 인자 = 확인한 실제 경로, `index: null` 경로는 끝에 덧붙이고, 모든 단어는 작은따옴표로 감싼다.
/// 하나라도 실패하면 nil (로컬 defer)
public enum CommandRebuild {
    static let systemFolders: Set<String> = ["/bin", "/usr/bin"]
    /// `argv[0]`으로 받는 이름 = 서버 `COMMAND_FLAGS`(`src/lib/agents/command-flags.ts`)의 키 (8장 3). `claude-code-adapter.json`의 `readonly_commands`로
    /// `swift-fixtures.test.ts`가 서버 목록과 대조한다
    public static let allowedCommands: [String] = ["cat", "file", "find", "grep", "head", "ls", "pwd", "rg", "stat", "tail", "wc"]

    public static func rebuild(_ parse: BridgeV1ToolDecisionParse, command: String, childPATH: String, workspaceRealPath: String, fileSystem: GateFileSystem) -> String? {
        // 명령 글에 가상 루트 접두(`/taskforce/` · `/taskforce-`)가 있으면 다시 만들지 않는다: 서버가 그 글자를 경로로 돌려주면 되돌리기가 다른 실제 파일을 가리키게 된다 (재검토 1, Astra 3)
        guard !VirtualWorkspacePaths.commandPrefixes.contains(where: { command.contains($0) }) else { return nil }
        // Swift `==`는 정규 동등(é = e + ́)으로 비교한다: 코드 포인트로 비교한다
        guard parse.wrapper == "none", let name = parse.argv.first, allowedCommands.contains(name),
              split(command)?.map({ Array($0.unicodeScalars) }) == parse.argv.map({ Array($0.unicodeScalars) }) else { return nil }
        guard let found = fileSystem.lookup(name, path: childPATH), let executable = fileSystem.realpath(found),
              systemFolders.contains((executable as NSString).deletingLastPathComponent), (executable as NSString).lastPathComponent == name else { return nil }
        var words = parse.argv
        words[0] = executable
        var appended: [String] = []
        var replaced = Set<Int>()
        for path in parse.paths {
            guard let real = fileSystem.resolve(path.absolute), GateFileSystem.isInside(real, root: workspaceRealPath) else { return nil }
            if let index = path.index {
                guard index >= 1, index < words.count, replaced.insert(index).inserted else { return nil }
                words[index] = real
            } else {
                appended.append(real)
            }
        }
        return (words + appended).map(quote).joined(separator: " ")
    }

    /// 서버 파서(`command-parser.ts` `splitWords`)와 같은 단순 규칙으로만 나눈다: 공백 · 탭이 단어를 나누고, `'…'` · `"…"` 안은 글자 그대로 (따옴표는 벗긴다).
    /// 특수 글자 판정은 서버 몫이다 (여기서는 나눈 결과만 비교한다). 닫히지 않은 따옴표 · 빈 명령은 nil
    static func split(_ command: String) -> [String]? {
        // 서버처럼 코드 포인트 단위로 본다 (글자 묶음 단위면 따옴표 뒤 결합 문자가 따옴표를 가린다)
        var words: [String] = []
        var word = String.UnicodeScalarView()
        var quote: Unicode.Scalar?
        var started = false
        for scalar in command.unicodeScalars {
            if let open = quote {
                if scalar == open { quote = nil } else { word.append(scalar) }
            } else if scalar == "'" || scalar == "\"" {
                quote = scalar
                started = true
            } else if scalar == " " || scalar == "\t" {
                if started {
                    words.append(String(word))
                    word = String.UnicodeScalarView()
                    started = false
                }
            } else {
                word.append(scalar)
                started = true
            }
        }
        guard quote == nil else { return nil }
        if started { words.append(String(word)) }
        return words.isEmpty ? nil : words
    }

    /// 작은따옴표로만 감싼다. 글자 안의 `'`는 `'\''`로 닫고 다시 연다
    public static func quote(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
#endif
