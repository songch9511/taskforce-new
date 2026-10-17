#if os(macOS)
import Darwin
import Foundation
import Security

/// 지킴이 helper 본체 (OA D3a 13장 · 14장, 사용자 결정 2026-10-17). 앱 번들 helper `Taskforce Agent`(화면 · Dock 없음)와 SwiftPM 짝 `tf-agent-keeper`가 부른다.
///
/// `--report-fd <n> --ended <기록 경로> --cwd <폴더> -- <실행 파일> <argv0> [인자…]`
/// 0. 맨 먼저 SIGTERM을 막는다 (14장 3). 부모가 서명된 Taskforce 앱일 때만 진행한다 (14장 12, `KeeperCaller`): ppid 1이거나 다르면 아무것도 띄우지 않고 6으로 끝난다.
/// 1. 앱이 disclaim으로 띄운다: 지킴이가 자기 책임 프로세스다. 지킴이는 앱이 준 stdin · stdout · stderr를 그대로 넘겨 `claude`를 띄운다(앱과 같은 spawn 위생,
///    환경은 앱이 준 것 중 다섯 키만 명시해서, 14장 10). 그다음 자기 0 · 1 · 2는 `/dev/null`로 바꾼다 (끝 표시 EOF는 `claude`와 그 자손의 것이다).
/// 2. 보고 fd에 `started <claude pid> <claude id> <지킴이 id> <1|0>`(책임 프로세스로 가를 수 있나), `claude`를 거두면 `exited <code|-> <signal|->`.
///    `claude`를 띄우지 못했거나 그 세대를 읽지 못했으면 `failed`(띄웠으면 SIGKILL로 끝내고 거둔 뒤).
/// 3. 그 뒤 0.2초마다 구성원(책임 프로세스 = 지킴이, unique id > 지킴이 id)을 훑고, 연속 두 번의 완전한 훑기에서 0이면 끝 기록을
///    원자적으로 쓰고 0으로 끝난다. 구성원이 남아 있는 동안은 산다 (앱이 죽어 있어도: 다시 뜬 앱이 지킴이로 구성원을 찾는다). 띄우기에 실패해도 같은 증명을 거친다:
///    앱은 지킴이의 0 종료로만 끝을 안다 (14장 1).
/// 4. 책임 함수가 없거나 지킴이가 자기 책임 프로세스가 아니면 구성원을 증명할 수 없다: 기록 없이 4로 끝난다 (앱은 unknown).
/// 5. SIGTERM은 앱이 정체를 적기 전에 그 spawn을 거두는 신호다: 아직 거두지 않은 `claude`를 SIGKILL하고(띄우기 전에 왔으면 띄운 직후) 3–4처럼 이어 간다.
///    그 밖에 지킴이를 끝내는 것은 앱뿐이다.
/// 디스크에는 끝 기록(숫자 · 부팅 id)만 쓴다. 로그 · stderr 0
public enum KeeperMain {
    /// 종료 코드: 0만 "구성원 0을 증명하고 끝 기록을 썼다"이다
    public enum Exit: Int32 {
        case ended = 0
        case usage = 2
        case spawnFailed = 3
        case unprovable = 4
        case recordFailed = 5
        /// 부모가 Taskforce 앱이 아니다 (14장 12): 아무것도 띄우지 않았다
        case callerRefused = 6
    }

    /// `claude`에 넘기는 환경의 키 (14장 10): 앱이 지킴이에 준 환경에서 이것만 명시해서 넘긴다. 지킴이 자신이 더한 값(Foundation의 `__CF_USER_TEXT_ENCODING` 등)은 넘기지 않는다.
    /// 마지막은 spawn marker (Kit `ClaudeProcessInspector.markerKey`와 같다)
    public static let childEnvironmentKeys: Set<String> = ["HOME", "USER", "LANG", "PATH", "TASKFORCE_SPAWN_ID"]

    static func childEnvironment(_ environment: [String: String]) -> [String: String] {
        environment.filter { childEnvironmentKeys.contains($0.key) }
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

    public static func main(arguments: [String], caller: KeeperCaller.Policy) -> Int32 {
        // SIGTERM은 처음부터 막아 둔다 (14장 3): 처리기가 생기기 전 · `claude`를 띄우는 사이에 온 것도 보류됐다가 `Abort`가 받는다. 자식은 빈 마스크 (`AgentSpawn`)
        Abort.blockTerminate()
        guard let invocation = parse(arguments) else { return Exit.usage.rawValue }
        guard KeeperCaller.allows(caller) else { return Exit.callerRefused.rawValue }
        signal(SIGPIPE, SIG_IGN)
        let me = getpid()
        guard case .present(let own) = AgentProcesses.generation(pid: me) else { return report(invocation, .failed, exit: .spawnFailed) }
        var attributable = false
        if Responsibility.available, case .present(let responsible) = Responsibility.responsiblePID(me), responsible == me { attributable = true }
        let abort = Abort()
        let claude = AgentSpawn.spawn(
            executable: invocation.executable, argv0: invocation.argv0, arguments: invocation.arguments,
            environment: childEnvironment(ProcessInfo.processInfo.environment), cwd: invocation.cwd, fds: [(0, 0), (1, 1), (2, 2)], disclaim: false
        )
        // 거두기 전이라 그 pid는 우리 자식이다. 띄우기 전에 SIGTERM이 왔으면 여기서 바로 SIGKILL
        let generation = claude.map { AgentProcesses.generation(pid: $0.pid) }
        if let claude { abort.track(claude.pid) }
        let null = open("/dev/null", O_RDWR | O_CLOEXEC)
        for fd: Int32 in [0, 1, 2] { _ = dup2(null, fd) }
        if null > 2 { close(null) }
        if let claude, case .present(let read)? = generation {
            _ = send(invocation, .started(claudePID: claude.pid, claudeID: read.own, keeperID: own.own, attributable: attributable))
            let status = abort.reap()
            _ = send(invocation, .exited(code: status.code, signal: status.signal))
        } else {
            // 띄우지 못했거나 그 세대를 읽지 못해 정체를 알릴 수 없다: 띄웠으면 끝내고 거둔 뒤 알린다. 그래도 아래 증명을 거친다 (14장 1)
            if let claude {
                kill(claude.pid, SIGKILL)
                _ = abort.reap()
            }
            _ = send(invocation, .failed)
        }
        guard attributable else { return Exit.unprovable.rawValue }
        var clean = 0
        // 지금까지 본 구성원 (15장 3: 그 id가 부모인 스스로 책임 프로세스는 우리 자손이었을 수 있다). `claude`부터
        var seen: Set<UInt64> = []
        if case .present(let read)? = generation { seen.insert(read.own) }
        while clean < 2 {
            Thread.sleep(forTimeInterval: scanInterval)
            let scan = KeeperMembers.scan(keeperPID: me, keeperID: own.own, seen: seen)
            seen.formUnion(scan?.members.map(\.own) ?? [])
            if let scan, scan.complete, scan.members.isEmpty {
                clean += 1
            } else {
                clean = 0
            }
        }
        guard let boot = AgentProcesses.bootSessionID(), KeeperRecord.write(URL(fileURLWithPath: invocation.ended), keeperID: own.own, boot: boot) else {
            return Exit.recordFailed.rawValue
        }
        // 앱이 부모로서 받는 정상 끝의 짝 (15장 4): 끝 기록 뒤에 보고 줄 `ended`를 쓰고 0으로 끝난다 (보고 fd는 끝나며 닫힌다)
        _ = send(invocation, .ended)
        return Exit.ended.rawValue
    }

    static func report(_ invocation: Invocation, _ line: KeeperReport, exit: Exit) -> Int32 {
        _ = send(invocation, line)
        return exit.rawValue
    }

    static func send(_ invocation: Invocation, _ line: KeeperReport) -> Bool {
        HookMain.writeAll(fd: invocation.reportFD, Data((line.line + "\n").utf8))
    }

    /// SIGTERM = 앱이 정체를 적기 전에 이 spawn을 거둔다 (14장 3). SIGTERM은 `blockTerminate`로 모든 스레드에서 막혀 있고(그 뒤 만든 스레드는 마스크를 물려받고,
    /// GCD 작업 스레드는 신호를 모두 막는다) 이 객체의 스레드 하나가 `sigwait`로 받는다: 처리기가 생기기 전에 온 것도 보류됐다가 받힌다.
    /// 받으면 중단 요청을 적고, 아직 거두지 않은 `claude`가 있으면 SIGKILL한다 (`track` 전이면 `track`이 바로). `claude`는 끝난 것을 거두지 않고 먼저 보고(`WNOWAIT`,
    /// 좀비라 그 pid는 다시 쓰이지 않는다) 표시한 뒤에 거둔다. 그 뒤의 SIGTERM은 아무것에도 신호를 보내지 않는다
    final class Abort: @unchecked Sendable {
        private let lock = NSLock()
        private var pid: pid_t = 0
        private var reaped = false
        private var requested = false

        /// 이 스레드(지킴이의 첫 스레드)의 마스크에 SIGTERM을 더한다. 다른 스레드를 만들기 전에 부른다
        static func blockTerminate() {
            var set = sigset_t()
            sigemptyset(&set)
            sigaddset(&set, SIGTERM)
            pthread_sigmask(SIG_BLOCK, &set, nil)
        }

        init() {
            let thread = Thread { [self] in
                var set = sigset_t()
                sigemptyset(&set)
                sigaddset(&set, SIGTERM)
                var received: Int32 = 0
                while sigwait(&set, &received) == 0 {
                    lock.withLock {
                        requested = true
                        if pid > 0, !reaped { kill(pid, SIGKILL) }
                    }
                }
            }
            thread.start()
        }

        /// 띄운 `claude`. 중단 요청이 이미 왔으면 바로 SIGKILL
        func track(_ pid: pid_t) {
            lock.withLock {
                self.pid = pid
                if requested { kill(pid, SIGKILL) }
            }
        }

        func reap() -> (code: Int32?, signal: Int32?) {
            let pid = lock.withLock { self.pid }
            var info = siginfo_t()
            while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) < 0, errno == EINTR {}
            lock.withLock { reaped = true }
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
    /// 구성원 0을 증명하고 끝 기록을 썼다 (곧 0으로 끝난다, 15장 4)
    case ended

    public var line: String {
        switch self {
        case .started(let pid, let claudeID, let keeperID, let attributable): "started \(pid) \(claudeID) \(keeperID) \(attributable ? 1 : 0)"
        case .failed: "failed"
        case .exited(let code, let signal): "exited \(code.map(String.init) ?? "-") \(signal.map(String.init) ?? "-")"
        case .ended: "ended"
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
        case "ended":
            guard parts.count == 1 else { return nil }
            self = .ended
        default:
            return nil
        }
    }
}

/// 지킴이의 구성원 (13장 2): 이 사용자 프로세스 중 책임 프로세스가 지킴이이고(unique id 변형이 있으면 그 id로, 없으면 pid로) unique id가 지킴이 id보다 큰 것.
/// 지킴이 pid의 지금 세대가 지킴이 id일 때만 가른다 (아니면 nil: 지킴이가 없다). 조회는 3상태이고 실패는 불완전으로만 이어진다 (12장 7).
/// 증명하지 못하는 것이 보이면 그 훑기는 불완전이다 (14장 4–6): 실효 사용자가 바뀐 자손 · 다시 disclaim한 자손 · 목록과 조회 사이에 사라진 지킴이 뒤의 프로세스
public enum KeeperMembers {
    public struct Lookups: Sendable {
        /// 실효 ∪ 실제 사용자가 이 사용자인 목록 (14장 4)
        public var listing: @Sendable () -> [ListedProcess]?
        public var generation: @Sendable (pid_t) -> ProcessLookup<ProcessGeneration>
        public var responsiblePID: @Sendable (pid_t) -> ProcessLookup<pid_t>
        /// nil이면 unique id 변형이 없다
        public var responsibleUniqueID: (@Sendable (pid_t) -> ProcessLookup<UInt64>)?
        /// 21장: 그 pid의 지금 프로세스 unique id만 (세대 조회와 달리 다른 사용자의 프로세스 — launchd — 도 읽힌다)
        public var uniqueID: @Sendable (pid_t) -> ProcessLookup<UInt64>

        public init(
            listing: @escaping @Sendable () -> [ListedProcess]?, generation: @escaping @Sendable (pid_t) -> ProcessLookup<ProcessGeneration>,
            responsiblePID: @escaping @Sendable (pid_t) -> ProcessLookup<pid_t>, responsibleUniqueID: (@Sendable (pid_t) -> ProcessLookup<UInt64>)?,
            uniqueID: @escaping @Sendable (pid_t) -> ProcessLookup<UInt64> = { AgentProcesses.uniqueID(pid: $0) }
        ) {
            self.listing = listing
            self.generation = generation
            self.responsiblePID = responsiblePID
            self.responsibleUniqueID = responsibleUniqueID
            self.uniqueID = uniqueID
        }

        public static var live: Lookups {
            Lookups(listing: liveListing, generation: liveGeneration, responsiblePID: liveResponsiblePID, responsibleUniqueID: Responsibility.hasUniqueIDVariant ? liveResponsibleUniqueID : nil)
        }

        @Sendable static func liveListing() -> [ListedProcess]? { AgentProcesses.userProcesses() }
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

    /// - `seen`: 지킴이가 앞선 훑기에서 본 구성원 id (15장 3)
    public static func scan(keeperPID: pid_t, keeperID: UInt64, seen: Set<UInt64> = [], lookups: Lookups = .live) -> Scan? {
        guard let keeper = keeperAlive(keeperPID, keeperID, lookups), let listed = lookups.listing() else { return nil }
        let uid = getuid()
        var members: [ProcessGeneration] = []
        var complete = true
        /// 실제 사용자는 이 사용자인데 실효 사용자가 바뀌었고 지킴이 뒤에 시작한 프로세스 (세대 · 책임 조회가 막힌다: 부모로 가른다)
        var changed: [ListedProcess] = []
        /// 이 스냅숏의 pid별 행 (두 목록에서 온 것까지)
        var rows: [pid_t: [ListedProcess]] = [:]
        for entry in listed { rows[entry.pid, default: []].append(entry) }
        // 19장 2: 두 목록이 같은 pid를 다른 부모 · 시작 시각 · 사용자로 말하면 그 사이에 pid가 다시 쓰였을 수 있다 — 이 훑기는 불완전
        if rows.values.contains(where: { group in group.dropFirst().contains { !$0.agrees(with: group[0]) } }) { complete = false }
        /// 19장 1: 그 pid의 행이 추적 중이 아니고(`P_TRACED`) 원래 부모가 적혀 있지 않다(`p_oppid == 0`) — 추적 중이면 지금 부모는 tracer다. 행이 없으면 아니다
        func untraced(_ pid: pid_t) -> Bool {
            guard let group = rows[pid] else { return false }
            return group.allSatisfy { !$0.traced && $0.originalParentPID == 0 }
        }
        var visited = Set<pid_t>()
        for entry in listed where entry.pid > 1 && entry.pid != keeperPID && visited.insert(entry.pid).inserted {
            // 목록 행에는 unique id가 없어 지킴이 뒤 시작은 달력 시각으로 가른다 (20장 남는 위험: 시계 후퇴 중 사라진 구성원은 지킴이 앞으로 보일 수 있다)
            let afterKeeper = entry.started(notBefore: keeper)
            guard entry.uid == uid else {
                if entry.ruid == uid, afterKeeper { changed.append(entry) }
                continue
            }
            let generation: ProcessGeneration
            switch lookups.generation(entry.pid) {
            case .present(let read): generation = read
            case .gone:
                // 14장 6: 지킴이 뒤에 시작해 목록과 조회 사이에 끝났다 (fork 사슬이 그 사이에 목록에 없는 자식을 남겼을 수 있다). 부모가 무관함을 증명할 때만 아니다 (21장)
                if afterKeeper, !excusedByParent(entry, child: nil, untraced: untraced(entry.pid), keeperPID, keeperID, seen, lookups) {
                    complete = false
                }
                continue
            case .failed:
                complete = false
                continue
            }
            guard generation.uid == uid, generation.own > keeperID else { continue }
            /// 책임 조회에서 사라졌거나 조회 때 좀비다: 부모가 무관함을 증명하면 구성원일 수 없다 (18장 · 21장)
            let vanishedHarmlessly = { excusedByParent(entry, child: generation, untraced: untraced(entry.pid), keeperPID, keeperID, seen, lookups) }
            // 19.1: 지킴이 뒤에 생겨 목록에 있던 프로세스가 조회 때 좀비다 — 사라짐과 같다 (목록 뒤에 목록에 없는 자식을 남기고 끝났을 수 있고, launchd가 아직 거두지 않았다)
            if generation.zombie {
                if !vanishedHarmlessly() { complete = false }
                continue
            }
            // 지킴이 뒤에 생긴 프로세스다: 책임 조회가 실패면 불완전, 사라짐이면 18장의 부모 증명이 없을 때 불완전 (14장 6)
            let member: Bool
            let selfResponsible: Bool
            if let byID = lookups.responsibleUniqueID {
                let lookup = byID(entry.pid)
                guard case .present(let responsible) = lookup else {
                    if case .gone = lookup, vanishedHarmlessly() { continue }
                    complete = false
                    continue
                }
                member = responsible == keeperID
                selfResponsible = responsible == generation.own
            } else {
                let lookup = lookups.responsiblePID(entry.pid)
                guard case .present(let responsible) = lookup else {
                    if case .gone = lookup, vanishedHarmlessly() { continue }
                    complete = false
                    continue
                }
                member = responsible == keeperPID
                selfResponsible = responsible == entry.pid
            }
            if member {
                members.append(generation)
            } else if selfResponsible,
                      !excusedByParent(entry, child: generation, untraced: untraced(entry.pid), keeperPID, keeperID, seen, lookups, olderThanKeeperSuffices: true) {
                // 14장 5 · 15장 3 · 21장: 지킴이 뒤에 생긴 스스로 책임 프로세스는 구성원이 다시 disclaim해 띄웠을 수 있다 — 부모가 무관함을 증명할 때만 아니다
                // (Claude 데스크톱 · Chrome native host 같은 다른 앱의 disclaim, launchd가 띄운 앱 · XPC 서비스)
                complete = false
            }
        }
        // 14장 4: 실효 사용자가 바뀐 프로세스의 부모가 launchd(고아) · 지킴이 · 구성원(`claude` 포함)이면 구성원의 자손이었을 수 있다
        let parents = Set(members.map(\.pid)).union([1, keeperPID])
        if changed.contains(where: { parents.contains($0.parentPID) }) { complete = false }
        // pid로 가를 때는 훑기 뒤에도 그 pid가 지킴이여야 한다 (그 사이 지킴이가 끝나 pid가 다시 쓰였으면 가른 것을 믿지 않는다)
        guard lookups.responsibleUniqueID != nil || keeperAlive(keeperPID, keeperID, lookups) != nil else { return nil }
        return Scan(members: members, complete: complete)
    }

    /// 21장: 지킴이 뒤에 생긴 프로세스(자식)를 그 부모로 무시해도 되는가 — 부모를 근거로 쓰는 모든 길(세대 조회에서 사라짐 `.gone` · 좀비 · 책임 조회 중 사라짐 ·
    /// 15장 3 스스로 책임)이 이것 하나를 거친다. 책임 프로세스는 부모에게서 물려받고(disclaim이면 자기 자신) 바뀌지 않으며, 부모는 고아가 되면 launchd로, 추적이면 tracer로,
    /// detach면 원래 부모 pid의 지금 프로세스(재사용된 pid면 새 프로세스)로 바뀐다. 추적 중 exec은 부모 unique id를 그 tracer로 갱신한다 (XNU `kern_proc.c:2742–2758`).
    /// 그래서 아래가 모두 증명돼야 부모를 근거로 쓴다 — 하나라도 아니면(조회 실패 · 사라짐 · 불일치 포함) 아니다:
    /// 1. 추적 아님: 목록 행(`untraced`, 부른 쪽이 그 pid의 모든 행을 본다)과, 자식 세대를 읽었으면 그 조회 때의 표시
    /// 2. 자식 세대를 읽었으면 목록 부모 pid의 지금 프로세스가 그 세대의 부모 unique id다 (목록 뒤 attach → exec · detach 뒤 남은 부모 id를 거른다)
    /// 3. 부모 pid ≠ 1 · ≠ 지킴이, 살아 있고 좀비 아님, 책임 조회 앞뒤로 같은 unique id (19장 3, `responsibleIsNotKeeper`)
    /// 4. 순서: 자식 세대를 읽었으면 부모 id < 자식 id, 못 읽었으면 부모 id < 지킴이 id (20장 — fork · spawn마다 전역 카운터로 늘어나고 exec에서 그대로다)
    /// 5. 부모 책임 ≠ 지킴이 · 부모 id ∉ `seen`
    /// - `olderThanKeeperSuffices`: 15장 3 — 1 · 2를 증명했고 세대의 부모 id < 지킴이 id면(지킴이보다 먼저 생긴 부모: 구성원이 다시 disclaim해 띄운 것이 아니다) 3–5 없이 된다.
    ///   launchd가 띄운 앱 · XPC 서비스(부모 pid 1, 세대 조회는 다른 사용자라 실패)도 그렇게 가른다: 2는 unique id 조회로 본다
    static func excusedByParent(
        _ entry: ListedProcess, child: ProcessGeneration?, untraced: Bool, _ keeperPID: pid_t, _ keeperID: UInt64, _ seen: Set<UInt64>, _ lookups: Lookups,
        olderThanKeeperSuffices: Bool = false
    ) -> Bool {
        guard untraced, child?.traced != true else { return false }
        if olderThanKeeperSuffices, let child, child.parent < keeperID {
            guard case .present(let id) = lookups.uniqueID(entry.parentPID), id == child.parent else { return false }
            return true
        }
        guard entry.parentPID > 1, entry.parentPID != keeperPID, case .present(let parent) = lookups.generation(entry.parentPID), !parent.zombie else { return false }
        if let child {
            guard parent.own == child.parent, parent.own < child.own else { return false }
        } else {
            guard parent.own < keeperID else { return false }
        }
        guard !seen.contains(parent.own) else { return false }
        return responsibleIsNotKeeper(parent, keeperPID, keeperID, lookups)
    }

    /// 그 프로세스의 책임 프로세스를 읽었고 지킴이가 아니다 (unique id 변형이 있으면 그것으로). 부른 쪽이 바로 앞에 읽은 세대(`process`)와
    /// 책임을 읽은 뒤의 세대가 같은 unique id이고 좀비가 아니어야 한다 (19장 3): 그 사이 끝나 pid가 다시 쓰였으면 읽은 책임은 다른 프로세스의 것일 수 있다
    static func responsibleIsNotKeeper(_ process: ProcessGeneration, _ keeperPID: pid_t, _ keeperID: UInt64, _ lookups: Lookups) -> Bool {
        let notKeeper: Bool
        if let byID = lookups.responsibleUniqueID {
            guard case .present(let responsible) = byID(process.pid) else { return false }
            notKeeper = responsible != keeperID
        } else {
            guard case .present(let responsible) = lookups.responsiblePID(process.pid) else { return false }
            notKeeper = responsible != keeperPID
        }
        guard notKeeper, case .present(let after) = lookups.generation(process.pid), after.own == process.own, !after.zombie else { return false }
        return true
    }

    /// 지킴이 pid의 지금 세대가 지킴이 id이고 끝나지 않았으면 그 세대
    static func keeperAlive(_ pid: pid_t, _ id: UInt64, _ lookups: Lookups) -> ProcessGeneration? {
        if case .present(let now) = lookups.generation(pid), now.own == id, !now.zombie { return now }
        return nil
    }
}

/// 지킴이를 부른 쪽 확인 (14장 12, 기준 밖 권고 수용): 부모 프로세스가 서명된 Taskforce 앱일 때만 진행한다. ppid가 1(부모가 끝났다)이거나 다르면 아무것도 띄우지 않는다.
/// 부모 pid는 확인 뒤 다시 본다: 부모가 살아 있는 동안 그 pid는 다른 프로세스가 쓸 수 없고, 끝나면 ppid가 1이 된다
public enum KeeperCaller {
    public enum Policy: Sendable {
        /// Release: 부모가 `anchor apple generic` + 지킴이와 같은 팀 + identifier(지킴이 번들 id에서 `.agent`를 뗀 값)로 서명된 코드
        case signedApp
        /// 부모가 이 코드 서명 요구사항을 만족한다 (SwiftPM 시험 지킴이)
        case requirement(String)
        #if DEBUG
        /// Debug · 시험 호스트: 부모 실행 파일이 든 앱 번들의 id가 지킴이 번들 id에서 `.agent`를 뗀 값(격리 접두어 포함)이고 지킴이가 그 번들의 `Contents/Helpers` 안에 있다.
        /// 서명은 보지 않는다 (Debug-Test 호스트는 서명하지 않는다). Release 요구사항과 따로다
        case debugApp
        /// SwiftPM 시험 지킴이: 부모가 살아 있기만 하면 (앱 번들에 넣지 않는다)
        case liveParent
        #endif
    }

    /// 정책을 만족한 뒤 (15장 6): 부모의 idversion(fork · exec마다 새로 매긴다)이 지킴이 자신의 것보다 작아야 한다 — 부모가 지킴이를 띄운 뒤 다른 실행 파일로
    /// exec했으면(서명 확인은 지금 실행 파일을 본다) 거절한다. 그다음 확인하는 동안 부모가 그대로였는지 본다
    static func allows(
        _ policy: Policy, parent: pid_t = getppid(), parentNow: () -> pid_t = { getppid() }, version: (pid_t) -> UInt32? = idVersion, me: pid_t = getpid()
    ) -> Bool {
        guard parent > 1 else { return false }
        let satisfied: Bool
        switch policy {
        case .signedApp: satisfied = signedAppRequirement().map { satisfies(pid: parent, requirement: $0) } ?? false
        case .requirement(let text): satisfied = satisfies(pid: parent, requirement: text)
        #if DEBUG
        case .debugApp:
            satisfied = executablePath(parent).map { debugAppMatches(parentExecutable: $0, keeperBundle: Bundle.main.bundleURL, keeperID: Bundle.main.bundleIdentifier) } ?? false
        case .liveParent: satisfied = true
        #endif
        }
        guard satisfied, let parentVersion = version(parent), let ownVersion = version(me), parentVersion < ownVersion else { return false }
        return parentNow() == parent
    }

    static func idVersion(_ pid: pid_t) -> UInt32? {
        if case .present(let generation) = AgentProcesses.generation(pid: pid) { return generation.version }
        return nil
    }

    /// 지킴이 번들 id `<앱 id>.agent` → 앱 id. 글자는 영숫자 · `.` · `-`만
    static func appIdentifier(fromKeeper id: String?) -> String? {
        guard let id, id.hasSuffix(".agent"), plain(id) else { return nil }
        let app = String(id.dropLast(".agent".count))
        return app.isEmpty ? nil : app
    }

    static func plain(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2E || $0 == 0x2D }
    }

    /// Release 요구사항: 지킴이 자신의 번들 id · 팀에서 만든다. 둘 중 하나라도 없으면 nil (진행하지 않는다)
    static func signedAppRequirement(keeperID: String? = Bundle.main.bundleIdentifier, team: String? = ownTeam()) -> String? {
        guard let app = appIdentifier(fromKeeper: keeperID), let team, plain(team) else { return nil }
        return "anchor apple generic and identifier \"\(app)\" and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// 그 pid의 실행 중인 코드가 요구사항을 만족하나 (동적 서명 확인)
    static func satisfies(pid: pid_t, requirement text: String) -> Bool {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// 지킴이 자신의 서명 팀
    static func ownTeam() -> String? {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var code: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any] else { return nil }
        return values[kSecCodeInfoTeamIdentifier as String] as? String
    }

    #if DEBUG
    /// 부모 실행 파일 `<앱>.app/Contents/MacOS/<이름>`의 앱 번들 id가 지킴이 번들 id에서 `.agent`를 뗀 값이고, 지킴이 번들이 그 앱의 `Contents/Helpers` 바로 안에 있다 (실제 경로로 비교)
    static func debugAppMatches(parentExecutable: String, keeperBundle: URL, keeperID: String?) -> Bool {
        guard let app = appIdentifier(fromKeeper: keeperID), let executable = realpath(parentExecutable), let keeper = realpath(keeperBundle.path) else { return false }
        let appBundle = URL(fileURLWithPath: executable).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard appBundle.pathExtension == "app", URL(fileURLWithPath: executable).deletingLastPathComponent().lastPathComponent == "MacOS",
              Bundle(url: appBundle)?.bundleIdentifier == app else { return false }
        return URL(fileURLWithPath: keeper).deletingLastPathComponent().path == appBundle.appending(path: "Contents/Helpers").path
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func realpath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
    #endif
}

/// 지킴이의 끝 기록 (13장 3): 구성원 0을 증명한 지킴이가 끝나기 직전에 원자적으로 쓴다. 숫자 · 부팅 id뿐
public enum KeeperRecord {
    public static let header = "taskforce-keeper 1"

    /// 같은 폴더의 임시 파일에 쓰고 이름을 바꾼다 (0600)
    public static func write(_ url: URL, keeperID: UInt64, boot: String) -> Bool {
        AgentFile.writeAtomically([header, "boot " + boot, "keeper \(keeperID)", "ended"].joined(separator: "\n") + "\n", to: url)
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
