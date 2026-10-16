#if os(macOS)
import Darwin
import Foundation

// 프로세스 조회 · 책임 프로세스 · spawn (OA D3a 12장 7 · 13장). 앱(Kit `ClaudeCodeProcess`)과 지킴이 helper(`KeeperMain`)가 같은 코드를 쓴다

/// 프로세스 조회 하나의 결과 (12장 7): 있음 · 확인된 사라짐(없음 · 끝남 · 다른 프로세스로 바뀜) · 실패. 실패를 사라짐으로 바꾸는 길은 없다:
/// 구성원 훑기에서 `failed`는 언제나 불완전(→ 끝을 증명하지 못함 → unknown)으로만 이어진다. 값을 꺼내는 길은 세 경우를 모두 다루는 `switch`뿐이다
public enum ProcessLookup<Value> {
    case present(Value)
    case gone
    case failed
}

extension ProcessLookup: Sendable where Value: Sendable {}
extension ProcessLookup: Equatable where Value: Equatable {}

/// 프로세스 한 세대를 한 번에 읽은 것: 시작 시각 · 부모 pid · 그룹 · 사용자 · 상태와 커널 unique id가 같은 프로세스의 것이다.
/// unique id는 부팅 안에서 다시 쓰지 않고 exec해도 그대로다
public struct ProcessGeneration: Equatable, Sendable {
    public let pid: pid_t
    /// 커널 시작 시각 (초 · 마이크로초 그대로)
    public let startSeconds: UInt64
    public let startMicros: UInt64
    public let parentPID: pid_t
    public let group: pid_t
    public let uid: uid_t
    public let zombie: Bool
    public let own: UInt64
    public let parent: UInt64
    /// 커널 idversion (`p_idversion`): fork · exec마다 새로 매기는 번호 (15장 6: 부모가 그 뒤에 exec했는지 가른다)
    public let version: UInt32

    public init(
        pid: pid_t, startSeconds: UInt64, startMicros: UInt64, parentPID: pid_t, group: pid_t, uid: uid_t, zombie: Bool, own: UInt64, parent: UInt64, version: UInt32 = 0
    ) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicros = startMicros
        self.parentPID = parentPID
        self.group = group
        self.uid = uid
        self.zombie = zombie
        self.own = own
        self.parent = parent
        self.version = version
    }

    public var start: Date { Date(timeIntervalSince1970: TimeInterval(startSeconds) + TimeInterval(startMicros) / 1_000_000) }
}

/// 프로세스 목록(`sysctl KERN_PROC`)의 한 줄 (14장 4 · 6): 목록 한 번에 함께 읽은 값이다. 세대 조회(`proc_pidinfo`)와 달리 실효 사용자가 다른(setuid) 프로세스도 읽힌다
public struct ListedProcess: Equatable, Sendable {
    public let pid: pid_t
    public let parentPID: pid_t
    /// 실효 사용자
    public let uid: uid_t
    /// 실제 사용자
    public let ruid: uid_t
    /// 커널 시작 시각 (초 · 마이크로초 그대로)
    public let startSeconds: UInt64
    public let startMicros: UInt64

    public init(pid: pid_t, parentPID: pid_t, uid: uid_t, ruid: uid_t, startSeconds: UInt64, startMicros: UInt64) {
        self.pid = pid
        self.parentPID = parentPID
        self.uid = uid
        self.ruid = ruid
        self.startSeconds = startSeconds
        self.startMicros = startMicros
    }

    /// 이 세대와 같은 때나 그 뒤에 시작했다 (마이크로초까지)
    public func started(notBefore generation: ProcessGeneration) -> Bool {
        (startSeconds, startMicros) >= (generation.startSeconds, generation.startMicros)
    }
}

/// 작은 기록 파일 하나를 원자적으로 쓴다 (13장 3 · 14장 1): 같은 폴더의 새 임시 파일(0600, `O_EXCL` · `O_NOFOLLOW`)에 쓰고 `fsync` 뒤 이름을 바꾼다
public enum AgentFile {
    public static func writeAtomically(_ text: String, to url: URL) -> Bool {
        let temporary = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).\(getpid()).\(UInt32.random(in: 0...UInt32.max)).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return false }
        let written = HookMain.writeAll(fd: fd, Data(text.utf8)) && fsync(fd) == 0
        close(fd)
        guard written, rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            return false
        }
        return true
    }
}

public enum AgentProcesses {
    /// `proc_pidinfo(PROC_PIDT_BSDINFOWITHUNIQID = 18, arg 1 = 좀비도)`: `struct proc_bsdinfo`(136바이트) 뒤에 `struct proc_uniqidentifierinfo`
    /// (uuid 16 · uniqueid 8 · puniqueid 8 · idversion 4 · 예비 20 = 56바이트). 커널이 한 프로세스를 잡고 둘을 함께 채운다.
    /// SDK 공개 머리에 없는 flavor라 돌려준 크기가 맞을 때만 믿는다. 없는 pid(`ESRCH`)는 `gone`, 그 밖은 `failed`
    public static func generation(pid: pid_t) -> ProcessLookup<ProcessGeneration> {
        guard pid > 0 else { return .failed }
        let bsd = MemoryLayout<proc_bsdinfo>.size
        let total = bsd + 56
        var buffer = [UInt8](repeating: 0, count: total)
        errno = 0
        let size = proc_pidinfo(pid, 18, 1, &buffer, Int32(total))
        guard size == Int32(total) else { return size <= 0 && errno == ESRCH ? .gone : .failed }
        let info = buffer.withUnsafeBytes { $0.loadUnaligned(as: proc_bsdinfo.self) }
        let own = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: bsd + 16, as: UInt64.self) }
        let parent = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: bsd + 24, as: UInt64.self) }
        let version = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: bsd + 32, as: UInt32.self) }
        guard own > 1, info.pbi_pid == UInt32(bitPattern: pid) else { return .failed }
        return .present(ProcessGeneration(
            pid: pid, startSeconds: info.pbi_start_tvsec, startMicros: info.pbi_start_tvusec, parentPID: pid_t(bitPattern: info.pbi_ppid), group: pid_t(bitPattern: info.pbi_pgid),
            uid: info.pbi_uid, zombie: info.pbi_status == UInt32(SZOMB), own: own, parent: parent, version: version
        ))
    }

    /// 이 사용자의 모든 프로세스 pid (`KERN_PROC_UID`). 읽지 못하면 nil
    public static func userPIDs() -> [pid_t]? {
        list(KERN_PROC_UID)?.map(\.pid)
    }

    /// 지킴이가 훑는 목록 (14장 4): 실효 사용자가 이 사용자(`KERN_PROC_UID`) ∪ 실제 사용자가 이 사용자(`KERN_PROC_RUID`, setuid로 실효 사용자가 바뀐 자손).
    /// pid가 겹치면 하나만. 둘 중 하나라도 읽지 못하면 nil
    public static func userProcesses() -> [ListedProcess]? {
        guard let byUID = list(KERN_PROC_UID), let byRUID = list(KERN_PROC_RUID) else { return nil }
        var seen = Set<pid_t>()
        return (byUID + byRUID).filter { seen.insert($0.pid).inserted }
    }

    static func list(_ selector: Int32) -> [ListedProcess]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, selector, Int32(bitPattern: getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return nil }
        if size == 0 { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride + 16
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: count)
        size = count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &processes, &size, nil, 0) == 0 else { return nil }
        return processes.prefix(size / MemoryLayout<kinfo_proc>.stride).map { info in
            let start = info.kp_proc.p_un.__p_starttime
            return ListedProcess(
                pid: info.kp_proc.p_pid, parentPID: info.kp_eproc.e_ppid, uid: info.kp_eproc.e_ucred.cr_uid, ruid: info.kp_eproc.e_pcred.p_ruid,
                startSeconds: UInt64(max(0, start.tv_sec)), startMicros: UInt64(max(0, start.tv_usec))
            )
        }
    }

    /// 이번 부팅의 id (`kern.bootsessionuuid`). 벽시계와 무관하다
    public static func bootSessionID() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1, size < 128 else { return nil }
        var chars = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &chars, &size, nil, 0) == 0 else { return nil }
        let value = String(decoding: chars.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return UUID(uuidString: value) != nil ? value : nil
    }
}

/// 책임 프로세스 (12장 1 · 13장 1–2, 사용자 결정 2026-10-17): 앱은 지킴이를 disclaim으로 띄워 지킴이가 자기 책임 프로세스가 되게 하고, 그 아래 프로세스의
/// 책임 프로세스는 지킴이다. 공개 머리에 없는 libquarantine 함수라 `dlsym`로 런타임에 찾는다 (없으면 물러남 = 잠금).
/// 측정(macOS 26.5, notes 재검토 4): 책임 프로세스가 살아 있는 동안 setsid · 이중 fork · 못 본 중간 프로세스의 자손도 그것을 돌려준다. 책임 프로세스가 끝나면
/// 그 자손은 스스로의 책임 프로세스가 된다 — 그래서 지킴이는 구성원이 0이 될 때까지 산다. 끝난(좀비) 프로세스는 `ESRCH`다
public enum Responsibility {
    typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    typealias ResponsiblePID = @convention(c) (pid_t) -> pid_t
    typealias ResponsibleUniqueID = @convention(c) (pid_t) -> UInt64

    static let setDisclaim: SetDisclaim? = symbol("responsibility_spawnattrs_setdisclaim")
    static let pidFunction: ResponsiblePID? = symbol("responsibility_get_pid_responsible_for_pid")
    /// 있으면 이것으로 가른다 (12-2: pid 재사용과 무관)
    static let uniqueIDFunction: ResponsibleUniqueID? = symbol("responsibility_get_uniqueid_responsible_for_pid")

    /// disclaim과 책임 pid 함수가 모두 있다
    public static var available: Bool { setDisclaim != nil && pidFunction != nil }
    public static var hasUniqueIDVariant: Bool { uniqueIDFunction != nil }

    /// `RTLD_DEFAULT` = `(void *)-2`
    private static func symbol<T>(_ name: String) -> T? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: T.self) }
    }

    /// spawn 속성에 disclaim을 켠다. 두 함수가 모두 있고 켜졌을 때만 true
    public static func disclaim(_ attributes: inout posix_spawnattr_t?) -> Bool {
        guard available, let setDisclaim else { return false }
        return setDisclaim(&attributes, 1) == 0
    }

    /// 그 pid의 책임 프로세스 pid. 끝났거나(좀비 포함) 없으면 `gone`, 함수가 없거나 그 밖의 실패는 `failed`
    public static func responsiblePID(_ pid: pid_t) -> ProcessLookup<pid_t> {
        guard let pidFunction, pid > 0 else { return .failed }
        errno = 0
        let value = pidFunction(pid)
        if value > 0 { return .present(value) }
        return errno == ESRCH ? .gone : .failed
    }

    /// 그 pid의 책임 프로세스 unique id. 함수가 없으면 nil (그때는 pid로 가른다)
    public static func responsibleUniqueID(_ pid: pid_t) -> ProcessLookup<UInt64>? {
        guard let uniqueIDFunction else { return nil }
        guard pid > 0 else { return .failed }
        errno = 0
        let value = uniqueIDFunction(pid)
        if value != UInt64.max, value > 1 { return .present(value) }
        return errno == ESRCH ? .gone : .failed
    }
}

/// posix_spawn 위생 하나 (계약 2.5 · 13장 1): 앱 fd를 물려주지 않음(`POSIX_SPAWN_CLOEXEC_DEFAULT`, 준 fd만) · 새 프로세스 그룹 · 신호 기본값 · 빈 신호 마스크 · cwd.
/// 앱이 지킴이를 띄울 때와 지킴이가 `claude`를 띄울 때 같은 함수를 쓴다
public enum AgentSpawn {
    public struct Spawned: Equatable, Sendable {
        public let pid: pid_t
        /// disclaim을 켜고 띄웠다
        public let disclaimed: Bool
    }

    /// - `environment`: nil이면 이 프로세스의 환경을 그대로 (지킴이가 앱이 준 환경을 `claude`에 넘긴다)
    /// - `fds`: 자식 fd 번호 → 이 프로세스의 fd. 같은 번호면 그대로 물려준다
    /// - `argv0`: 자식이 보는 이름 (없으면 `executable`). 실행하는 파일은 언제나 `executable`이다
    public static func spawn(
        executable: String, argv0: String? = nil, arguments: [String], environment: [String: String]?, cwd: String, fds: [(child: Int32, parent: Int32)], disclaim: Bool
    ) -> Spawned? {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd in fds {
            if fd.child == fd.parent {
                posix_spawn_file_actions_addinherit_np(&actions, fd.child)
            } else {
                posix_spawn_file_actions_adddup2(&actions, fd.parent, fd.child)
            }
        }
        posix_spawn_file_actions_addchdir_np(&actions, cwd)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGINT, SIGTERM, SIGPIPE, SIGHUP, SIGQUIT, SIGCHLD] { sigaddset(&defaults, signal) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)
        let disclaimed = disclaim && Responsibility.disclaim(&attributes)

        let argv: [UnsafeMutablePointer<CChar>?] = ([argv0 ?? executable] + arguments).map { strdup($0) } + [nil]
        let entries = environment.map { $0.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" } }
        let envp: [UnsafeMutablePointer<CChar>?]? = entries.map { $0.map { strdup($0) } + [nil] }
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp ?? [] { free(pointer) }
        }
        var pid: pid_t = 0
        let status: Int32
        if let envp {
            status = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        } else {
            status = posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
        }
        guard status == 0, pid > 0 else { return nil }
        return Spawned(pid: pid, disclaimed: disclaimed)
    }
}
#endif
