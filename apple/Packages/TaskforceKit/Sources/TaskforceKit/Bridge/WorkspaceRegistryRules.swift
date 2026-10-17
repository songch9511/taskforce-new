#if os(macOS)
import Darwin
import Foundation

/// 작업 폴더로 받아 줄 폴더의 규칙 (OA D4a2-04, 보안 재검토 3 F7, 계약 10장 5). 폴더 창이 고른 값을 등록하기 전에, 그리고 등록된 폴더를 쓰기 직전(`authorize` · resolver)에
/// 같은 규칙으로 다시 본다: 등록한 뒤에 폴더가 기호 링크로 바뀌었거나 지워졌을 수 있다.
///
/// 판정은 모두 `realpath(3)`로 푼 실제 경로로 한다 (기호 링크로 우회하지 못한다). 거절 이유는 진단용이고 사용자에게는 한 문장만 보인다
/// (`AgentWorkspaceCopy.rejected`). **경로 원문을 로그에 남기지 않는다.**
///
/// 거절: `/` · 홈 자체와 그 조상 · `~/Library` 안 · `~/.claude` 안 · 앱 데이터 폴더(`protectedRoots`)와 그 안 **그리고 그것을 품는 폴더** ·
/// `/System` · `/Library` · `/Applications` · `/usr` · `/bin` · `/sbin` · `/private` 안 · `/Volumes` 자체 · 이 사용자 소유가 아닌 폴더 · 디렉터리가 아닌 것.
/// 허용: 홈 아래 · 외장 볼륨(`/Volumes/<이름>`) 아래의 내 폴더.
public struct WorkspaceFolderRules: Sendable {
    public enum Rejection: String, Error, Sendable, Equatable {
        case notAbsolute, notFound, notADirectory, notOwnedByUser
        case root, homeOrAncestor, userLibrary, claudeConfig, appData, system, volumesRoot, outsideAllowedAreas
    }

    /// 파일 시스템 사실 둘 (시험은 가짜로 바꾼다)
    public struct Facts: Sendable {
        public var realpath: @Sendable (String) -> String?
        /// (디렉터리인가, 소유자 uid). 읽을 수 없으면 nil
        public var inspect: @Sendable (String) -> (isDirectory: Bool, owner: UInt32)?
        public var userID: UInt32

        public init(
            realpath: @escaping @Sendable (String) -> String?, inspect: @escaping @Sendable (String) -> (isDirectory: Bool, owner: UInt32)?, userID: UInt32
        ) {
            self.realpath = realpath
            self.inspect = inspect
            self.userID = userID
        }

        public static let live = Facts(
            realpath: { GateFileSystem.realpath($0) },
            inspect: { path in
                var info = stat()
                guard stat(path, &info) == 0 else { return nil }
                return ((info.st_mode & S_IFMT) == S_IFDIR, info.st_uid)
            },
            userID: getuid()
        )
    }

    /// 홈 (realpath)
    public let home: String
    /// 그 안(자기 포함)을 거절하는 폴더
    let denyInside: [(root: String, why: Rejection)]
    /// 자기 자신만 거절하는 폴더 (`/Volumes`)
    let denyExact: [(root: String, why: Rejection)]
    /// 그 안 **그리고 그것을 품는 폴더**를 거절하는 앱 데이터 폴더
    let denyAround: [String]
    let volumesRoot: String
    let facts: Facts

    public init(
        home: String, userLibrary: String? = nil, claudeConfig: String? = nil, systemRoots: [String], volumesRoot: String = "/Volumes", protectedRoots: [String] = [],
        facts: Facts = .live
    ) {
        let resolve: (String) -> String = { facts.realpath($0) ?? $0 }
        self.home = resolve(home)
        var inside: [(root: String, why: Rejection)] = []
        inside.append((resolve(userLibrary ?? (home + "/Library")), .userLibrary))
        inside.append((resolve(claudeConfig ?? (home + "/.claude")), .claudeConfig))
        inside += systemRoots.map { (resolve($0), .system) }
        denyInside = inside
        self.volumesRoot = resolve(volumesRoot)
        denyExact = [(self.volumesRoot, .volumesRoot)]
        denyAround = protectedRoots.map(resolve)
        self.facts = facts
    }

    /// 앱이 쓰는 규칙: 시스템 폴더 목록은 고정이다
    public static func standard(home: String, protectedRoots: [String]) -> WorkspaceFolderRules {
        WorkspaceFolderRules(
            home: home, systemRoots: ["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/private"], protectedRoots: protectedRoots
        )
    }

    /// 받아 줄 폴더면 그 realpath, 아니면 이유. 절대 경로가 아니거나 NUL이 있으면 거절한다
    public func validate(_ path: String) -> Result<String, Rejection> {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return .failure(.notAbsolute) }
        guard let real = facts.realpath(path) else { return .failure(.notFound) }
        guard let info = facts.inspect(real) else { return .failure(.notFound) }
        guard info.isDirectory else { return .failure(.notADirectory) }
        guard info.owner == facts.userID else { return .failure(.notOwnedByUser) }
        if real == "/" { return .failure(.root) }
        // 홈 자체와 그 조상 (홈은 이 폴더 안에 있다)
        if GateFileSystem.isInside(home, root: real) { return .failure(.homeOrAncestor) }
        for (root, why) in denyInside where GateFileSystem.isInside(real, root: root) { return .failure(why) }
        for (root, why) in denyExact where real == root { return .failure(why) }
        // 앱 데이터 폴더: 그 안이거나, 그것을 품는 폴더 (원장 · 세션 폴더를 품은 폴더를 작업 폴더로 받지 않는다)
        for root in denyAround where GateFileSystem.isInside(real, root: root) || GateFileSystem.isInside(root, root: real) { return .failure(.appData) }
        // 허용 구역: 홈 아래 또는 외장 볼륨 아래
        guard GateFileSystem.isInside(real, root: home) || GateFileSystem.isInside(real, root: volumesRoot) else { return .failure(.outsideAllowedAreas) }
        return .success(real)
    }
}
#endif
