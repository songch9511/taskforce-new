#if os(macOS)
import Darwin
import Foundation
import Synchronization

/// 한 spawn의 혈통 (OA D3a 9장 4 · 10장 1–4 · 11장 1–5, 정정 제안 9-4): 그 spawn에서 나온 프로세스를 커널 unique id로 기억한다.
///
/// 계약은 spawn marker 환경 변수를 `KERN_PROCARGS2`로 읽어 자손을 찾으라고 했지만, macOS 26.5에서는 같은 사용자 · 샌드박스 밖이라도 남의 프로세스 환경이 비어 온다
/// (notes 정정 제안 9-4 증거). 그래서 커널 계보를 쓴다: 프로세스마다 부팅 안에서 다시 쓰지 않는 unique id가 있고(exec해도 그대로), 자식은 fork · exec 때의
/// 부모 id를 갖는다 (그 뒤 부모가 끝나 launchd로 옮겨져도, setsid로 세션을 떠나도 그대로다). 그래서 한 번 본 프로세스와 그 자식은 언제든 찾는다.
/// 뿌리(띄운 CLI)의 id도 적는다: 자손은 뿌리보다 뒤에 만들어져 id가 크다 (10장 3, 벽시계를 보지 않는다).
/// 남는 틈: 한 번도 못 본 중간 프로세스가 자식을 만들고 끝나거나, 자식이 부모가 끝난 뒤에 exec하면(부모 id가 launchd 것이 된다) 그 자식은 놓친다.
/// 감독하는 동안 본 프로세스마다 `NOTE_FORK`를 걸어 새 자식이 생기면 다시 훑고(훑기 사이 최소 30ms, 아니면 0.1초마다), 거두기 전의 좀비도 본다.
///
/// 파일 `<sessionsRoot>/lineage/<spawn id>.lineage`(0600): 머리 = 형식 · 부팅 id(`kern.bootsessionuuid`) · 뿌리 id, 그 뒤 id 한 줄씩. 새 id는 **바로 한 줄 덧붙이고**
/// (11장 3: 앱이 그 순간 죽어도 남는다), 0.5초마다 · 지켜보던 프로세스가 끝날 때 전체를 다시 쓴다(정리). 끝을 증명하면 id를 지우고 "끝" 기록만 남긴다
/// (그 뒤의 확인도 끝이라고 답한다). 다른 부팅의 파일이면 그 spawn은 이미 끝났다. 파일이 있어야 할 spawn인데 없거나 읽지 못하면 증거가 없다 → 끝을 증명하지 못한다 (11장 1).
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
    struct MemberKey: Hashable {
        let pid: pid_t
        let seconds: Int64
        let micros: Int64
    }

    struct State {
        var ids: Set<UInt64> = []
        var memberKeys: Set<MemberKey> = []
        var rootID: UInt64?
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
    /// 끝이라는 증거가 이미 있다 (다른 부팅 · 끝 기록)
    var provenEnded: Bool { evidence == .otherBoot || evidence == .ended }
    /// 훑어서 끝을 증명할 수 있는 혈통인가 (있어야 할 파일이 없으면 아니다)
    var hasEvidence: Bool { evidence != .missing }

    /// - `fresh`: 이제 띄우는 spawn (파일은 곧 쓴다). 아니면 `file`을 읽는다 (다시 뜬 앱의 확인 · 끝내기)
    init(file: URL? = nil, fresh: Bool = false) {
        self.file = file
        guard let file, !fresh else {
            evidence = .memory
            return
        }
        switch Self.load(file) {
        case .thisBoot(let root, let ids):
            evidence = .thisBoot
            state.withLock {
                $0.ids = ids
                $0.rootID = root
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

    /// 띄운 프로세스 자신 (거두기 전이라 그 pid는 다른 프로세스가 쓸 수 없다): 뿌리 id
    func seed(_ pid: pid_t) {
        guard let generation = ClaudeProcessInspector.generation(pid: pid) else { return }
        adopt(root: generation.own)
    }

    /// 정체가 그대로인 부모(`same`)의 id를 뿌리로 (뿌리를 아직 모를 때만). 읽은 세대의 시작 시각이 정체와 같을 때만 (10장 2)
    func seed(_ identity: AgentProcessIdentity) {
        guard rootID == nil, let raw = identity.pid, raw > 1, raw <= Int(Int32.max),
              let generation = ClaudeProcessInspector.generation(pid: pid_t(raw)), abs(generation.start.timeIntervalSince(identity.startedAt)) <= 0.001 else { return }
        adopt(root: generation.own)
    }

    private func adopt(root: UInt64) {
        state.withLock {
            if $0.rootID == nil {
                $0.rootID = root
                $0.dirty = true
            }
            append(root, &$0)
        }
    }

    var rootID: UInt64? { state.withLock { $0.rootID } }

    func contains(_ id: UInt64) -> Bool {
        state.withLock { $0.ids.contains(id) }
    }

    /// 새 id는 바로 파일에 한 줄 덧붙인다 (11장 3)
    func insert(_ id: UInt64) {
        state.withLock { append(id, &$0) }
    }

    /// 자손으로 본 세대를 기억한다 (메모리만)
    func remember(_ key: MemberKey) {
        state.withLock { _ = $0.memberKeys.insert(key) }
    }

    func wasMember(_ key: MemberKey) -> Bool {
        state.withLock { $0.memberKeys.contains(key) }
    }

    private func append(_ id: UInt64, _ current: inout State) {
        guard current.ids.insert(id).inserted else { return }
        guard let file, current.headed, !current.stopped else {
            current.dirty = true
            return
        }
        let fd = open(file.path, O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            current.dirty = true
            return
        }
        defer { close(fd) }
        let line = Array((String(id) + "\n").utf8)
        if line.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) != line.count { current.dirty = true }
    }

    /// 환경에 marker가 있나 (프로세스마다 한 번만 읽는다)
    func marked(_ uniqueID: UInt64, read: () -> Bool) -> Bool {
        if state.withLock({ $0.unmarked.contains(uniqueID) }) { return false }
        if read() { return true }
        state.withLock { _ = $0.unmarked.insert(uniqueID) }
        return false
    }

    var isStopped: Bool { state.withLock { $0.stopped } }

    /// 전체를 다시 쓴다 (원자적 쓰기, 0600): 머리 + 모든 id. 0.5초에 한 번까지, `force`면 바로 (띄운 직후 · 지켜보던 프로세스가 끝났을 때)
    func save(force: Bool = false) {
        guard let file, evidence == .memory || evidence == .thisBoot else { return }
        state.withLock { current in
            guard !current.stopped, current.dirty || !current.headed || force, let boot = ClaudeProcessInspector.bootSessionID() else { return }
            let now = Date()
            if !force, let last = current.lastSave, now.timeIntervalSince(last) < Self.saveInterval { return }
            let lines = [Self.header, "boot " + boot, "root " + (current.rootID.map { String($0) } ?? "-")] + current.ids.sorted().map { String($0) }
            if Self.write(lines, to: file) {
                current.dirty = false
                current.headed = true
                current.lastSave = now
            }
        }
    }

    /// 파일이 이번 부팅의 혈통으로 읽히나 (띄운 직후 강제 저장 확인, 11장 2)
    var isRecorded: Bool {
        guard let file else { return false }
        if case .thisBoot = Self.load(file) { return true }
        return false
    }

    /// 끝을 증명한 뒤: 지켜보기를 멈추고 id를 지운 "끝" 기록만 남긴다 (그 뒤의 확인도 끝이다, 11장 1)
    func forget() {
        state.withLock { current in
            current.stopped = true
            guard let file, evidence != .otherBoot else { return }
            if let boot = ClaudeProcessInspector.bootSessionID(), Self.write([Self.header, "boot " + boot, "ended"], to: file) { return }
            // 끝 기록을 쓰지 못하면 지운다: 그 뒤의 확인은 증거가 없어 unknown이다 (끝이라고 하지 않는다)
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

    static let header = "taskforce-lineage 2"

    enum Loaded: Equatable {
        case thisBoot(root: UInt64?, ids: Set<UInt64>)
        case ended
        case otherBoot
        case unreadable
    }

    /// 형식이 맞는 파일만 (줄바꿈으로 끝난 숫자 줄만 받는다: 쓰다 끊긴 마지막 줄은 버린다). 부팅 id가 `boot`와 다르면 `otherBoot`, 부팅 id를 못 읽으면 `unreadable`
    static func load(_ file: URL, boot: String? = ClaudeProcessInspector.bootSessionID()) -> Loaded {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return .unreadable }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // 마지막 원소는 마지막 줄바꿈 뒤다: 비어 있지 않으면 쓰다 끊긴 줄이다
        lines.removeLast()
        guard lines.count >= 3, lines[0] == header, lines[1].hasPrefix("boot ") else { return .unreadable }
        let written = String(lines[1].dropFirst(5))
        guard UUID(uuidString: written) != nil, let boot else { return .unreadable }
        guard written == boot else { return .otherBoot }
        if lines[2] == "ended", lines.count == 3 { return .ended }
        guard lines[2].hasPrefix("root ") else { return .unreadable }
        func number(_ line: Substring) -> UInt64? {
            guard !line.isEmpty, line.allSatisfy({ $0.isASCII && $0.isNumber }), let id = UInt64(line), id > 1 else { return nil }
            return id
        }
        let rootText = lines[2].dropFirst(5)
        let root = rootText == "-" ? nil : number(rootText)
        if rootText != "-", root == nil { return .unreadable }
        var ids = Set<UInt64>()
        for line in lines.dropFirst(3) {
            guard let id = number(Substring(line)) else { return .unreadable }
            ids.insert(id)
        }
        return .thisBoot(root: root, ids: ids)
    }

    /// 앱이 뜰 때: 확인된 다른 부팅의 파일만 지운다 (11장 1). 부팅 id를 못 읽으면 아무것도 지우지 않는다
    static func purge(directory: URL, boot: String? = ClaudeProcessInspector.bootSessionID()) {
        guard let boot, let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasSuffix(".lineage") {
            let file = directory.appending(path: name)
            if load(file, boot: boot) == .otherBoot { try? FileManager.default.removeItem(at: file) }
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
