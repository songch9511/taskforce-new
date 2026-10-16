#if os(macOS)
import Darwin
import Foundation
import Synchronization

/// 한 spawn의 혈통 (OA D3a 9장 4 · 10장 1–4 · 11장 1–5 · 12장 1–8, 정정 제안 9-4): 그 spawn에서 나온 프로세스를 커널 unique id와 pid로 기억한다.
///
/// 구성원은 주로 책임 프로세스로 본다 (12장 1, `ClaudeResponsibility`). 그런데 뿌리가 끝나는 순간 그 자손은 스스로의 책임 프로세스가 되므로(측정, notes),
/// 뿌리가 살아 있을 때 본 구성원을 여기에 적어 둔다. 혈통은 그 기록과, 다시 뜬 앱이 뿌리 정체를 확인하는 데 쓴다 (보조).
/// 커널 계보: 프로세스마다 부팅 안에서 다시 쓰지 않는 unique id가 있고(exec해도 그대로), 자식은 fork · exec 때의 부모 id를 갖는다. 뿌리(띄운 CLI)의 id는
/// 반드시 적는다 (12장 6: 뿌리 id를 모르면 띄우지 않는다). 자손은 뿌리보다 뒤에 만들어져 id가 크다 (10장 3, 벽시계를 보지 않는다).
/// 감독하는 동안 본 프로세스마다 `NOTE_FORK`를 걸어 새 자식이 생기면 다시 훑고(훑기 사이 최소 30ms, 아니면 0.1초마다), 거두기 전의 좀비도 본다.
///
/// 파일 `<sessionsRoot>/lineage/<spawn id>.lineage`(0600, 형식 3): 머리 = 형식 · 부팅 id(`kern.bootsessionuuid`) · `root <id> <pid>` · `responsible yes|no`,
/// 그 뒤 `<id> <pid>` 한 줄씩. 새 id는 **바로 한 줄 덧붙이고**(11장 3), 0.5초마다 · 지켜보던 프로세스가 끝날 때 전체를 다시 쓴다(정리). 덧붙이기가 실패하거나
/// 줄이 잘리면 그 파일을 지우고(못 지우면 비우고) 다시 쓰기에 성공할 때까지 덧붙이지 않는다: 그동안 다시 뜬 앱은 증거 없음(unknown)으로 읽는다 (12장 5).
/// 끝을 증명하면 따로 `<spawn id>.ended`를 쓰고 혈통 파일을 지운다 (12장 8: `load`가 끝 기록을 먼저 본다 — 다른 쓰기가 끝 기록을 덮지 못한다).
/// 다른 부팅의 파일이면 그 spawn은 이미 끝났다. 파일이 있어야 할 spawn인데 없거나 읽지 못하면 증거가 없다 → 끝을 증명하지 못한다 (11장 1).
/// 글 · 경로 · 명령은 적지 않는다: 숫자뿐이다
public final class ClaudeLineage: Sendable {
    /// 파일에서 읽은 것
    enum Evidence: Equatable {
        /// 메모리 혈통 (파일 없음 또는 새 spawn): 지금 본 것이 전부다
        case memory
        /// 이번 부팅의 파일
        case thisBoot
        /// 다른 부팅의 파일: 그 spawn은 끝났다
        case otherBoot
        /// 끝을 증명해 둔 기록
        case ended
        /// 있어야 할 파일이 없거나 읽지 못했다: 끝을 증명할 수 없다
        case missing
    }

    /// 자손으로 본 프로세스 한 세대 (pid · 커널 시작 시각): 그 세대를 다시 읽지 못하면 그 훑기는 불완전하다 (11장 4)
    struct MemberKey: Hashable, Sendable {
        let pid: pid_t
        let seconds: Int64
        let micros: Int64
    }

    struct State {
        /// unique id → pid (pid를 모르면 0)
        var ids: [UInt64: pid_t] = [:]
        var memberKeys: Set<MemberKey> = []
        var rootID: UInt64?
        var rootPID: pid_t?
        /// 책임 프로세스로 구성원을 가를 수 있다 (12장 2: disclaim을 켜고 띄웠고 두 함수가 있다)
        var attributable = ClaudeResponsibility.available
        /// 끝을 증명했다 (`forget`)
        var ended = false
        /// 환경을 읽어 marker가 없던 프로세스 (unique id): 다시 읽지 않는다
        var unmarked: Set<UInt64> = []
        /// 파일 머리를 썼거나 읽었다: 새 id를 덧붙일 수 있다
        var headed = false
        /// 덧붙이지 못한 id가 있다 (다음 정리에서 전체를 다시 쓴다)
        var dirty = false
        var lastSave: Date?
        var stopped = false
    }

    /// 전체 다시 쓰기(정리) 간격 (10장 4 · 11장 3)
    static let saveInterval: TimeInterval = 0.5
    /// `NOTE_FORK`가 몰려도 훑기 사이 최소 간격 (10장 4)
    static let minimumScanInterval: TimeInterval = 0.03

    private let state = Mutex(State())
    let file: URL?
    let evidence: Evidence

    var fromOtherBoot: Bool { evidence == .otherBoot }
    /// 끝이라는 증거가 이미 있다 (다른 부팅 · 끝 기록 · 이 객체가 끝을 증명함)
    var provenEnded: Bool { evidence == .otherBoot || evidence == .ended || state.withLock { $0.ended } }
    /// 훑어서 끝을 증명할 수 있는 혈통인가 (있어야 할 파일이 없으면 아니다)
    var hasEvidence: Bool { evidence != .missing }
    /// 구성원을 증명할 수 있다: 뿌리 id를 알고(12장 6) 책임 프로세스로 가를 수 있다(12장 2). 아니면 끝을 증명하지 않고 자손에 신호도 보내지 않는다
    var provable: Bool { state.withLock { $0.rootID != nil && $0.attributable } }
    var attributable: Bool { state.withLock { $0.attributable } }

    /// - `fresh`: 이제 띄우는 spawn (파일은 곧 쓴다). 아니면 `file`을 읽는다 (다시 뜬 앱의 확인 · 끝내기)
    /// - `boot`: 이번 부팅 id (못 읽으면 nil: 파일을 대조할 수 없어 증거 없음)
    init(file: URL? = nil, fresh: Bool = false, boot: () -> String? = { ClaudeProcessInspector.bootSessionID() }) {
        self.file = file
        guard let file, !fresh else {
            evidence = .memory
            return
        }
        switch Self.load(file, boot: boot()) {
        case .thisBoot(let record):
            evidence = .thisBoot
            state.withLock {
                $0.ids = record.ids
                $0.rootID = record.root
                $0.rootPID = record.rootPID
                $0.attributable = record.attributable
                $0.headed = true
            }
        case .ended: evidence = .ended
        case .otherBoot: evidence = .otherBoot
        case .unreadable: evidence = .missing
        }
    }

    /// 지금 정체가 그대로인 부모(`same`)에서 시작한다 (감독 밖: 다시 뜬 앱의 고아 정리, 시험)
    static func seeded(_ identity: AgentProcessIdentity, file: URL? = nil) -> ClaudeLineage {
        let lineage = ClaudeLineage(file: file)
        if !lineage.provenEnded, ClaudeProcessInspector.check(identity) == .same { lineage.seed(identity) }
        return lineage
    }

    /// 띄운 프로세스 자신 (거두기 전이라 그 pid는 다른 프로세스가 쓸 수 없다): 뿌리 id. 첫 세대 조회로 못 읽으면 뿌리 id가 없다 (12장 6: 띄우지 않는다).
    /// `disclaimed`: disclaim을 켜고 띄웠나 (아니면 구성원을 증명할 수 없다, 12장 2)
    func seed(_ pid: pid_t, disclaimed: Bool = ClaudeResponsibility.available) {
        guard case .present(let generation) = ClaudeProcessInspector.lookups.generation(pid) else { return }
        adopt(root: generation.own, pid: pid, attributable: disclaimed && ClaudeResponsibility.available)
    }

    /// 정체가 그대로인 부모(`same`)의 id를 뿌리로 (뿌리를 아직 모를 때만). 읽은 세대의 시작 시각이 정체와 같을 때만 (10장 2)
    func seed(_ identity: AgentProcessIdentity) {
        guard rootID == nil, let raw = identity.pid, raw > 1, raw <= Int(Int32.max),
              case .present(let generation) = ClaudeProcessInspector.lookups.generation(pid_t(raw)),
              abs(generation.start.timeIntervalSince(identity.startedAt)) <= 0.001 else { return }
        adopt(root: generation.own, pid: pid_t(raw), attributable: attributable)
    }

    private func adopt(root: UInt64, pid: pid_t, attributable: Bool) {
        state.withLock {
            if $0.rootID == nil {
                $0.rootID = root
                $0.rootPID = pid
                $0.attributable = attributable
                $0.dirty = true
            }
            append(root, pid: pid, &$0)
        }
    }

    var rootID: UInt64? { state.withLock { $0.rootID } }

    /// 혈통에 적힌 pid (뿌리 포함): 보조 규칙의 그룹 (12장 4)
    var pids: Set<pid_t> {
        state.withLock { current in
            var pids = Set(current.ids.values.filter { $0 > 1 })
            if let root = current.rootPID, root > 1 { pids.insert(root) }
            return pids
        }
    }

    func contains(_ id: UInt64) -> Bool {
        state.withLock { $0.ids[id] != nil }
    }

    /// 새 id는 바로 파일에 한 줄 덧붙인다 (11장 3)
    func insert(_ id: UInt64, pid: pid_t = 0) {
        state.withLock { append(id, pid: pid, &$0) }
    }

    /// 자손으로 본 세대를 기억한다 (메모리만)
    func remember(_ key: MemberKey) {
        state.withLock { _ = $0.memberKeys.insert(key) }
    }

    func wasMember(_ key: MemberKey) -> Bool {
        state.withLock { $0.memberKeys.contains(key) }
    }

    /// 뿌리가 살아 있는데 자기 책임 프로세스가 아니다 (disclaim이 듣지 않았다, 12장 2): 이 spawn의 구성원은 증명할 수 없다. 파일에도 적는다
    func markUnattributable() {
        let changed = state.withLock { current -> Bool in
            guard current.attributable else { return false }
            current.attributable = false
            current.dirty = true
            return true
        }
        if changed { save(force: true) }
    }

    private func append(_ id: UInt64, pid: pid_t, _ current: inout State) {
        guard current.ids[id] == nil else { return }
        current.ids[id] = pid
        guard let file, current.headed, !current.stopped else {
            current.dirty = true
            return
        }
        let line = Array("\(id) \(pid)\n".utf8)
        let fd = open(file.path, O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW)
        let written = fd >= 0 ? line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) } : -1
        if fd >= 0 { close(fd) }
        guard written != line.count else { return }
        // 덧붙이지 못했거나 일부만 썼다 (12장 5): 그 파일은 이제 이 spawn의 혈통 전부가 아니다. 지워서(못 지우면 비워서) 다시 뜬 앱이 증거 없음으로 읽게 하고,
        // 전체 다시 쓰기에 성공할 때까지 덧붙이지 않는다
        if unlink(file.path) != 0 { truncate(file.path, 0) }
        current.headed = false
        current.dirty = true
    }

    /// 환경에 marker가 있나 (프로세스마다 한 번만 읽는다)
    func marked(_ uniqueID: UInt64, read: () -> Bool) -> Bool {
        if state.withLock({ $0.unmarked.contains(uniqueID) }) { return false }
        if read() { return true }
        state.withLock { _ = $0.unmarked.insert(uniqueID) }
        return false
    }

    var isStopped: Bool { state.withLock { $0.stopped } }

    /// 전체를 다시 쓴다 (원자적 쓰기, 0600): 머리 + 모든 id. 0.5초에 한 번까지, `force`면 바로 (띄운 직후 · 지켜보던 프로세스가 끝났을 때).
    /// 뿌리 id를 모르면 쓰지 않는다 (12장 6)
    func save(force: Bool = false) {
        guard let file, evidence == .memory || evidence == .thisBoot else { return }
        state.withLock { current in
            guard !current.stopped, current.dirty || !current.headed || force, let root = current.rootID, let boot = ClaudeProcessInspector.bootSessionID() else { return }
            let now = Date()
            if !force, let last = current.lastSave, now.timeIntervalSince(last) < Self.saveInterval { return }
            let lines = [Self.header, "boot " + boot, "root \(root) \(current.rootPID ?? 0)", "responsible " + (current.attributable ? "yes" : "no")]
                + current.ids.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
            if Self.write(lines, to: file) {
                current.dirty = false
                current.headed = true
                current.lastSave = now
            }
        }
    }

    /// 파일이 이번 부팅의 이 뿌리 혈통으로 읽히나 (띄운 직후 강제 저장 확인, 11장 2 · 12장 6: 뿌리 id가 있어야 한다)
    var isRecorded: Bool {
        guard let file, let root = rootID else { return false }
        if case .thisBoot(let record) = Self.load(file), record.root == root { return true }
        return false
    }

    /// 끝을 증명한 뒤: 지켜보기를 멈추고 끝 기록(`<id>.ended`)을 쓴 뒤 혈통 파일을 지운다 (그 뒤의 확인도 끝이다, 11장 1 · 12장 8)
    func forget() {
        state.withLock { current in
            current.stopped = true
            current.ended = true
            guard let file, evidence != .otherBoot, evidence != .ended else { return }
            if let boot = ClaudeProcessInspector.bootSessionID() { _ = Self.write([Self.header, "boot " + boot, "ended"], to: Self.endedFile(file)) }
            // 끝 기록을 쓰지 못했으면 혈통 파일만 지운다: 그 뒤의 확인은 증거가 없어 unknown이다 (끝이라고 하지 않는다)
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func write(_ lines: [String], to file: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return true
        } catch {
            return false
        }
    }

    static let header = "taskforce-lineage 3"

    /// 끝 기록 파일 (`<spawn id>.ended`, 12장 8)
    static func endedFile(_ file: URL) -> URL {
        file.deletingPathExtension().appendingPathExtension("ended")
    }

    struct Record: Equatable {
        var root: UInt64
        var rootPID: pid_t
        var attributable: Bool
        var ids: [UInt64: pid_t]
    }

    enum Loaded: Equatable {
        case thisBoot(Record)
        case ended
        case otherBoot
        case unreadable
    }

    /// 끝 기록(`<id>.ended`)을 먼저 보고, 없으면 혈통 파일. 형식이 맞는 것만: 모든 줄이 줄바꿈으로 끝나고(잘린 줄이 있으면 읽지 못함, 12장 5) 뿌리 id가 있어야 한다.
    /// 부팅 id가 `boot`와 다르면 `otherBoot`, 부팅 id를 못 읽으면 `unreadable`
    static func load(_ file: URL, boot: String? = ClaudeProcessInspector.bootSessionID()) -> Loaded {
        let ended = endedFile(file)
        if FileManager.default.fileExists(atPath: ended.path) {
            guard let lines = lines(ended), lines.count == 3, lines[2] == "ended" else { return .unreadable }
            return bootOf(lines, boot) ?? .ended
        }
        guard let lines = lines(file), lines.count >= 4 else { return .unreadable }
        if let other = bootOf(lines, boot) { return other }
        func number(_ text: Substring) -> UInt64? {
            guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), let value = UInt64(text) else { return nil }
            return value
        }
        /// `<id> <pid>`: id > 1, pid는 0(모름) 또는 양수
        func entry(_ text: Substring) -> (id: UInt64, pid: pid_t)? {
            let parts = text.split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count == 2, let id = number(parts[0]), id > 1, let pid = number(parts[1]), pid <= UInt64(Int32.max) else { return nil }
            return (id, pid_t(pid))
        }
        guard lines[2].hasPrefix("root "), let root = entry(lines[2].dropFirst(5)) else { return .unreadable }
        let attributable: Bool
        switch lines[3] {
        case "responsible yes": attributable = true
        case "responsible no": attributable = false
        default: return .unreadable
        }
        var ids: [UInt64: pid_t] = [:]
        for line in lines.dropFirst(4) {
            guard let member = entry(Substring(line)) else { return .unreadable }
            ids[member.id] = member.pid
        }
        return .thisBoot(Record(root: root.id, rootPID: root.pid, attributable: attributable, ids: ids))
    }

    /// 줄 목록 (머리 확인). 마지막 줄바꿈 뒤에 글이 있으면(잘린 줄) nil
    private static func lines(_ file: URL) -> [String]? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.removeLast().isEmpty, lines.count >= 2, lines[0] == header, lines[1].hasPrefix("boot ") else { return nil }
        return lines
    }

    /// 머리의 부팅 id가 이번 부팅이면 nil, 다르면 `otherBoot`, 읽지 못하면 `unreadable`
    private static func bootOf(_ lines: [String], _ boot: String?) -> Loaded? {
        let written = String(lines[1].dropFirst(5))
        guard UUID(uuidString: written) != nil, let boot else { return .unreadable }
        return written == boot ? nil : .otherBoot
    }

    /// 앱이 뜰 때 (11장 1, 결정 11-1): 다시 부팅했다는 것은 그 부팅의 프로세스가 모두 끝났다는 증명이다. 확인된 다른 부팅의 혈통 파일은 이번 부팅의
    /// 끝 기록(`<id>.ended`)으로 바꾸고 혈통 파일을 지운다 (그 spawn을 나중에 물어도 끝이다). 부팅 id를 못 읽으면 아무것도 바꾸지 않는다.
    /// 끝 기록은 task 정리를 adapter가 알 길이 없어 지우지 않는다 (숫자 · 부팅 id뿐, 계정 삭제가 파티션째 지운다)
    static func purge(directory: URL, boot: String? = ClaudeProcessInspector.bootSessionID()) {
        guard let boot, let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasSuffix(".lineage") {
            let file = directory.appending(path: name)
            if load(file, boot: boot) == .otherBoot, write([header, "boot " + boot, "ended"], to: endedFile(file)) { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// 감독하는 동안 지켜본다 (막히는 스레드 하나): 본 프로세스마다 `NOTE_FORK`를 걸어 새 자식이 생기면 다시 훑는다(훑기 사이 최소 30ms). 아니면 0.1초마다.
    /// 지켜보던 프로세스가 끝나면(`NOTE_EXIT`) 파일 전체를 바로 다시 쓴다 (11장 3). `forget()`까지
    func watch(_ identity: AgentProcessIdentity) {
        guard let raw = identity.pid, raw > 1, raw <= Int(Int32.max) else { return }
        let queue = kqueue()
        guard queue >= 0 else { return }
        let thread = Thread { [self] in
            var watched = Set<pid_t>()
            // `kevent`는 함수와 구조체가 같은 이름이다: 인자 형을 적어 함수로 풀리게 한다
            let fork = UInt32(NOTE_FORK)
            let exit = UInt32(NOTE_EXIT)
            let noEvents: UnsafeMutablePointer<Darwin.kevent>? = nil
            let noChanges: UnsafePointer<Darwin.kevent>? = nil
            let noWait: UnsafePointer<timespec>? = nil
            func follow(_ pid: pid_t) {
                guard !watched.contains(pid) else { return }
                var change = Darwin.kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_CLEAR), fflags: fork | exit, data: 0, udata: nil)
                let added: Int32 = kevent(queue, &change, 1, noEvents, 0, noWait)
                if added == 0 { watched.insert(pid) }
            }
            follow(pid_t(raw))
            var events = [Darwin.kevent](repeating: Darwin.kevent(), count: 32)
            var lastScan = Date.distantPast
            while !isStopped {
                // 포크가 몰려도 훑기는 최소 간격을 둔다 (10장 4)
                let since = Date().timeIntervalSince(lastScan)
                if since < Self.minimumScanInterval { Thread.sleep(forTimeInterval: Self.minimumScanInterval - since) }
                lastScan = Date()
                for member in ClaudeProcessInspector.descendants(identity, lineage: self) ?? [] { follow(member.pid) }
                var timeout = timespec(tv_sec: 0, tv_nsec: 100_000_000)
                let capacity: Int32 = 32
                let count: Int32 = kevent(queue, noChanges, 0, &events, capacity, &timeout)
                var exited = false
                for event in events.prefix(max(0, Int(count))) where event.fflags & exit != 0 {
                    watched.remove(pid_t(event.ident))
                    exited = true
                }
                if exited { save(force: true) }
            }
            close(queue)
        }
        thread.qualityOfService = .userInitiated
        thread.start()
    }
}
#endif
