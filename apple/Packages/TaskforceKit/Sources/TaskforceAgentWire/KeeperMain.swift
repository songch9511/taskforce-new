#if os(macOS)
import Darwin
import Foundation

/// 지킴이 helper 본체 (OA D3a 13장, 사용자 결정 2026-10-17). 앱 번들 helper `Taskforce Agent`(화면 · Dock 없음)와 SwiftPM 짝 `tf-agent-keeper`가 부른다.
///
/// `--report-fd <n> --ended <기록 경로> --cwd <폴더> -- <실행 파일> <argv0> [인자…]`
/// 1. 앱이 disclaim으로 띄운다: 지킴이가 자기 책임 프로세스다. 지킴이는 앱이 준 stdin · stdout · stderr를 그대로 넘겨 `claude`를 띄운다(앱과 같은 spawn 위생,
///    환경은 앱이 지킴이에 준 것 그대로). 그다음 자기 0 · 1 · 2는 `/dev/null`로 바꾼다 (끝 표시 EOF는 `claude`와 그 자손의 것이다).
/// 2. 보고 fd에 `started <claude pid> <claude id> <지킴이 id> <1|0>`(책임 프로세스로 가를 수 있나), `claude`를 거두면 `exited <code|-> <signal|->`.
/// 3. `claude`가 끝난 뒤 0.2초마다 구성원(책임 프로세스 = 지킴이, unique id > 지킴이 id)을 훑고, 연속 두 번의 완전한 훑기에서 0이면 끝 기록을
///    원자적으로 쓰고 0으로 끝난다. 구성원이 남아 있는 동안은 산다 (앱이 죽어 있어도: 다시 뜬 앱이 지킴이로 구성원을 찾는다).
/// 4. 책임 함수가 없거나 지킴이가 자기 책임 프로세스가 아니면 구성원을 증명할 수 없다: `claude`가 끝나면 기록 없이 4로 끝난다 (앱은 unknown).
/// 5. SIGTERM은 앱이 정체를 적기 전에 그 spawn을 거두는 신호다: 아직 거두지 않은 `claude`를 SIGKILL하고 3–4처럼 이어 간다. 그 밖에 지킴이를 끝내는 것은 앱뿐이다.
/// 디스크에는 끝 기록(숫자 · 부팅 id)만 쓴다. 로그 · stderr 0
public enum KeeperMain {
    /// 종료 코드: 0만 "구성원 0을 증명하고 끝 기록을 썼다"이다
    public enum Exit: Int32 {
        case ended = 0
        case usage = 2
        case spawnFailed = 3
        case unprovable = 4
        case recordFailed = 5
    }

    struct Invocation: Equatable {
        var reportFD: Int32
        var ended: String
        var cwd: String
        var executable: String
        var argv0: String
        var arguments: [String]
    }

    static func parse(_ arguments: [String]) -> Invocation? {
        guard let split = arguments.firstIndex(of: "--") else { return nil }
        var options: [String: String] = [:]
        var index = 0
        while index + 1 < split {
            options[arguments[index]] = arguments[index + 1]
            index += 2
        }
        let command = Array(arguments[(split + 1)...])
        guard index == split, options.count == 3, let report = options["--report-fd"].flatMap(Int32.init), report > 2, let ended = options["--ended"], ended.hasPrefix("/"),
              let cwd = options["--cwd"], cwd.hasPrefix("/"), command.count >= 2, command[0].hasPrefix("/") else { return nil }
        return Invocation(reportFD: report, ended: ended, cwd: cwd, executable: command[0], argv0: command[1], arguments: Array(command.dropFirst(2)))
    }

    /// 구성원 훑기 간격 (13장 2)
    static let scanInterval: TimeInterval = 0.2

    public static func main(arguments: [String]) -> Int32 {
        guard let invocation = parse(arguments) else { return Exit.usage.rawValue }
        signal(SIGPIPE, SIG_IGN)
        let me = getpid()
        guard case .present(let own) = AgentProcesses.generation(pid: me) else { return report(invocation, .failed, exit: .spawnFailed) }
        var attributable = false
        if Responsibility.available, case .present(let responsible) = Responsibility.responsiblePID(me), responsible == me { attributable = true }
        guard let claude = AgentSpawn.spawn(
            executable: invocation.executable, argv0: invocation.argv0, arguments: invocation.arguments, environment: nil, cwd: invocation.cwd,
            fds: [(0, 0), (1, 1), (2, 2)], disclaim: false
        ) else { return report(invocation, .failed, exit: .spawnFailed) }
        // 거두기 전이라 그 pid는 우리 자식이다: 그 세대를 못 읽으면 정체를 알릴 수 없다 → 멈추고 거둔다
        guard case .present(let generation) = AgentProcesses.generation(pid: claude.pid) else {
            kill(claude.pid, SIGKILL)
            _ = reap(claude.pid)
            return report(invocation, .failed, exit: .spawnFailed)
        }
        let null = open("/dev/null", O_RDWR | O_CLOEXEC)
        for fd: Int32 in [0, 1, 2] { _ = dup2(null, fd) }
        if null > 2 { close(null) }
        // SIGTERM = 앱이 정체를 적기 전에 이 spawn을 거둔다: 아직 거두지 않은 `claude`만 SIGKILL (지킴이는 구성원 0을 증명하고 끝난다)
        let abort = Abort(pid: claude.pid)
        _ = send(invocation, .started(claudePID: claude.pid, claudeID: generation.own, keeperID: own.own, attributable: attributable))
        let status = abort.reap()
        _ = send(invocation, .exited(code: status.code, signal: status.signal))
        guard attributable else { return Exit.unprovable.rawValue }
        var clean = 0
        while clean < 2 {
            Thread.sleep(forTimeInterval: scanInterval)
            if let scan = KeeperMembers.scan(keeperPID: me, keeperID: own.own), scan.complete, scan.members.isEmpty {
                clean += 1
            } else {
                clean = 0
            }
        }
        guard let boot = AgentProcesses.bootSessionID(), KeeperRecord.write(URL(fileURLWithPath: invocation.ended), keeperID: own.own, boot: boot) else {
            return Exit.recordFailed.rawValue
        }
        return Exit.ended.rawValue
    }

    static func report(_ invocation: Invocation, _ line: KeeperReport, exit: Exit) -> Int32 {
        _ = send(invocation, line)
        return exit.rawValue
    }

    static func send(_ invocation: Invocation, _ line: KeeperReport) -> Bool {
        HookMain.writeAll(fd: invocation.reportFD, Data((line.line + "\n").utf8))
    }

    /// `claude`를 거두기 전까지만 SIGTERM으로 `claude`를 끝낸다: 끝난 것을 거두지 않고 먼저 보고(`WNOWAIT`, 좀비라 그 pid는 다시 쓰이지 않는다)
    /// 표시한 뒤에 거둔다. 그 뒤의 SIGTERM은 아무것에도 신호를 보내지 않는다
    final class Abort: @unchecked Sendable {
        let pid: pid_t
        private let lock = NSLock()
        private var reaped = false
        private let source: DispatchSourceSignal

        init(pid: pid_t) {
            self.pid = pid
            signal(SIGTERM, SIG_IGN)
            source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
            source.setEventHandler { [unowned self] in
                lock.withLock { if !reaped { kill(pid, SIGKILL) } }
            }
            source.resume()
        }

        func reap() -> (code: Int32?, signal: Int32?) {
            var info = siginfo_t()
            while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) < 0, errno == EINTR {}
            lock.withLock { reaped = true }
            source.cancel()
            return KeeperMain.reap(pid)
        }
    }

    /// 거둔 상태 (EINTR은 다시)
    static func reap(_ pid: pid_t) -> (code: Int32?, signal: Int32?) {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            if errno != EINTR { return (nil, nil) }
        }
        let low = status & 0x7f
        return low == 0 ? ((status >> 8) & 0xff, nil) : (nil, low)
    }

    public static func exitProcess(_ code: Int32) -> Never {
        exit(code)
    }
}

/// 지킴이가 앱에 보내는 줄 (보고 fd, 13장 1)
public enum KeeperReport: Equatable, Sendable {
    /// `claude`를 띄웠다: 그 pid · unique id, 지킴이 unique id, 책임 프로세스로 가를 수 있나
    case started(claudePID: pid_t, claudeID: UInt64, keeperID: UInt64, attributable: Bool)
    /// `claude`를 띄우지 못했다
    case failed
    /// `claude`를 거뒀다
    case exited(code: Int32?, signal: Int32?)

    public var line: String {
        switch self {
        case .started(let pid, let claudeID, let keeperID, let attributable): "started \(pid) \(claudeID) \(keeperID) \(attributable ? 1 : 0)"
        case .failed: "failed"
        case .exited(let code, let signal): "exited \(code.map(String.init) ?? "-") \(signal.map(String.init) ?? "-")"
        }
    }

    public init?(line: String) {
        let parts = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        func optional(_ text: String) -> Int32?? { text == "-" ? .some(nil) : Int32(text).map { .some($0) } }
        switch parts.first {
        case "started":
            guard parts.count == 5, let pid = Int32(parts[1]), pid > 1, let claudeID = UInt64(parts[2]), claudeID > 1, let keeperID = UInt64(parts[3]), keeperID > 1,
                  parts[4] == "1" || parts[4] == "0" else { return nil }
            self = .started(claudePID: pid, claudeID: claudeID, keeperID: keeperID, attributable: parts[4] == "1")
        case "failed":
            guard parts.count == 1 else { return nil }
            self = .failed
        case "exited":
            guard parts.count == 3, let code = optional(parts[1]), let signal = optional(parts[2]) else { return nil }
            self = .exited(code: code, signal: signal)
        default:
            return nil
        }
    }
}

/// 지킴이의 구성원 (13장 2): 이 사용자 프로세스 중 책임 프로세스가 지킴이이고(unique id 변형이 있으면 그 id로, 없으면 pid로) unique id가 지킴이 id보다 큰 것.
/// 지킴이 pid의 지금 세대가 지킴이 id일 때만 가른다 (아니면 nil: 지킴이가 없다). 조회는 3상태이고 실패는 불완전으로만 이어진다 (12장 7)
public enum KeeperMembers {
    public struct Lookups: Sendable {
        public var userPIDs: @Sendable () -> [pid_t]?
        public var generation: @Sendable (pid_t) -> ProcessLookup<ProcessGeneration>
        public var responsiblePID: @Sendable (pid_t) -> ProcessLookup<pid_t>
        /// nil이면 unique id 변형이 없다
        public var responsibleUniqueID: (@Sendable (pid_t) -> ProcessLookup<UInt64>)?

        public init(
            userPIDs: @escaping @Sendable () -> [pid_t]?, generation: @escaping @Sendable (pid_t) -> ProcessLookup<ProcessGeneration>,
            responsiblePID: @escaping @Sendable (pid_t) -> ProcessLookup<pid_t>, responsibleUniqueID: (@Sendable (pid_t) -> ProcessLookup<UInt64>)?
        ) {
            self.userPIDs = userPIDs
            self.generation = generation
            self.responsiblePID = responsiblePID
            self.responsibleUniqueID = responsibleUniqueID
        }

        public static var live: Lookups {
            Lookups(userPIDs: liveUserPIDs, generation: liveGeneration, responsiblePID: liveResponsiblePID, responsibleUniqueID: Responsibility.hasUniqueIDVariant ? liveResponsibleUniqueID : nil)
        }

        @Sendable static func liveUserPIDs() -> [pid_t]? { AgentProcesses.userPIDs() }
        @Sendable static func liveGeneration(_ pid: pid_t) -> ProcessLookup<ProcessGeneration> { AgentProcesses.generation(pid: pid) }
        @Sendable static func liveResponsiblePID(_ pid: pid_t) -> ProcessLookup<pid_t> { Responsibility.responsiblePID(pid) }

        @Sendable static func liveResponsibleUniqueID(_ pid: pid_t) -> ProcessLookup<UInt64> {
            guard let found = Responsibility.responsibleUniqueID(pid) else { return ProcessLookup<UInt64>.failed }
            return found
        }
    }

    public struct Scan: Equatable, Sendable {
        public var members: [ProcessGeneration]
        public var complete: Bool
    }

    public static func scan(keeperPID: pid_t, keeperID: UInt64, lookups: Lookups = .live) -> Scan? {
        guard keeperAlive(keeperPID, keeperID, lookups), let pids = lookups.userPIDs() else { return nil }
        let uid = getuid()
        var members: [ProcessGeneration] = []
        var complete = true
        for pid in pids where pid > 1 && pid != keeperPID {
            let generation: ProcessGeneration
            switch lookups.generation(pid) {
            case .present(let read): generation = read
            case .gone: continue
            case .failed:
                complete = false
                continue
            }
            guard generation.uid == uid, generation.own > keeperID, !generation.zombie else { continue }
            let member: Bool
            if let byID = lookups.responsibleUniqueID {
                switch byID(pid) {
                case .present(let responsible): member = responsible == keeperID
                case .gone: continue
                case .failed:
                    complete = false
                    continue
                }
            } else {
                switch lookups.responsiblePID(pid) {
                case .present(let responsible): member = responsible == keeperPID
                case .gone: continue
                case .failed:
                    complete = false
                    continue
                }
            }
            if member { members.append(generation) }
        }
        // pid로 가를 때는 훑기 뒤에도 그 pid가 지킴이여야 한다 (그 사이 지킴이가 끝나 pid가 다시 쓰였으면 가른 것을 믿지 않는다)
        guard lookups.responsibleUniqueID != nil || keeperAlive(keeperPID, keeperID, lookups) else { return nil }
        return Scan(members: members, complete: complete)
    }

    static func keeperAlive(_ pid: pid_t, _ id: UInt64, _ lookups: Lookups) -> Bool {
        if case .present(let now) = lookups.generation(pid), now.own == id, !now.zombie { return true }
        return false
    }
}

/// 지킴이의 끝 기록 (13장 3): 구성원 0을 증명한 지킴이가 끝나기 직전에 원자적으로 쓴다. 숫자 · 부팅 id뿐
public enum KeeperRecord {
    public static let header = "taskforce-keeper 1"

    /// 같은 폴더의 임시 파일에 쓰고 이름을 바꾼다 (0600)
    public static func write(_ url: URL, keeperID: UInt64, boot: String) -> Bool {
        let text = [header, "boot " + boot, "keeper \(keeperID)", "ended"].joined(separator: "\n") + "\n"
        let temporary = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).\(getpid()).tmp")
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

    /// 형식이 맞는 기록의 지킴이 id · 부팅 id (모든 줄이 줄바꿈으로 끝나야 한다)
    public static func read(_ url: URL) -> (keeperID: UInt64, boot: String)? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.removeLast().isEmpty, lines.count == 4, lines[0] == header, lines[1].hasPrefix("boot "), lines[2].hasPrefix("keeper "), lines[3] == "ended",
              let id = UInt64(lines[2].dropFirst(7)), id > 1 else { return nil }
        let boot = String(lines[1].dropFirst(5))
        guard UUID(uuidString: boot) != nil else { return nil }
        return (id, boot)
    }
}
#endif
