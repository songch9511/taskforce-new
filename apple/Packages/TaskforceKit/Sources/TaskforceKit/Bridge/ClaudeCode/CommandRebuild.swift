#if os(macOS)
import Darwin
import Foundation

/// 파일 시스템 사실 (OA D3a 계약 2.7 · 13.4.1-1). 판정은 서버가 하고 Mac은 이 사실만 확인한다.
/// realpath는 `realpath(3)`로 본다 (Foundation `resolvingSymlinksInPath`는 쓰지 않는다, D3c-2 notes :346)
public struct GateFileSystem: Sendable {
    public var realpath: @Sendable (String) -> String?

    public init(realpath: @escaping @Sendable (String) -> String?) {
        self.realpath = realpath
    }

    public static let live = GateFileSystem(realpath: GateFileSystem.realpath)

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

    /// 실제 경로. 없는 경로는 있는 가장 가까운 조상의 realpath + 나머지. 나머지에 `.` · `..` · 빈 성분이 있거나 절대 경로가 아니면 nil (밖으로 본다)
    public func resolve(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
        if let real = realpath(path) { return real }
        var components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var remainder: [String] = []
        while components.count > 1 {
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

/// 서버가 허용한 읽기 전용 명령을 Mac에서 확인하고 다시 만든다 (계약 13.4.1-1 ①② · -4, P2).
/// ① `argv[0]`을 넘긴 PATH로 찾은 실행 파일의 realpath가 `/bin` · `/usr/bin` 바로 아래, ② 경로마다 realpath가 작업 폴더 안.
/// 다시 만든 명령: 첫 단어 = ①의 실제 경로, 경로 인자 = 확인한 실제 경로, `index: null` 경로는 끝에 덧붙이고, 모든 단어는 작은따옴표로 감싼다.
/// 하나라도 실패하면 nil (로컬 defer)
public enum CommandRebuild {
    static let systemFolders: Set<String> = ["/bin", "/usr/bin"]

    public static func rebuild(_ parse: BridgeV1ToolDecisionParse, childPATH: String, workspaceRealPath: String, fileSystem: GateFileSystem) -> String? {
        guard parse.wrapper == "none", let name = parse.argv.first else { return nil }
        guard let found = fileSystem.lookup(name, path: childPATH), let executable = fileSystem.realpath(found),
              systemFolders.contains((executable as NSString).deletingLastPathComponent) else { return nil }
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

    /// 작은따옴표로만 감싼다. 글자 안의 `'`는 `'\''`로 닫고 다시 연다
    public static func quote(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
#endif
