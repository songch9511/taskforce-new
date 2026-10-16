#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import Synchronization
import TaskforceAgentWire

/// 앱 전체에 하나인 bridge 소켓 (OA D3a 계약 2.6 · Q4). `BridgeHost`가 bridge가 켜졌을 때만 만들고 앱 종료 · 꺼짐 때 닫는다.
/// - 경로: `<Application Support>/<번들 id>/Bridge/hook.sock` (번들 id가 들어가 시험 호스트와 실사용 앱이 섞이지 않는다). 104바이트 `sun_path`를 넘으면 사용자 임시 폴더 아래.
/// - 폴더 0700 · 소유자 확인, 소켓 0600. 시작 때 남은 소켓 파일은 소유자가 이 사용자일 때만 지우고 다시 bind한다.
/// - 피어: `getpeereid`의 uid가 이 사용자가 아니면 읽지 않고 닫는다.
/// - nonce 등록부: nonce → spawn 처리기. 비교는 상수 시간. 등록 없는 nonce · 세션 불일치 = deny (L0). 끝난 spawn의 nonce는 2초 뒤 지운다.
/// - 판정은 하지 않는다: 처리기(결정기)가 한다. 처리기가 `responseBudget` 안에 확정하지 않으면 요청 상태를 `timedOut`으로 정하고 deny를 쓴다 (12장 9: 그 뒤의 처리기 결과는 기록되지 않는다)
public final class HookSocketServer: @unchecked Sendable {
    public struct Registration: Sendable {
        public var agentSessionID: String
        /// 그 spawn의 Claude Code 세션 id (훅 입력 `session_id`와 같아야 한다)
        public var providerSessionID: String?
        /// 요청 하나를 정한다. 정한 응답은 `HookCommit`에 확정해야 소켓이 쓴다 (12장 9)
        public var handler: @Sendable (HookRequest, HookCommit) async -> Void
        /// 답을 쓰기 **직전**에 그 tool_use id로 부른다 (자체 점검 ④ "bridge가 그 id에 소켓 답을 줬음": 시간 초과 deny도 답이다)
        public var onAnswer: (@Sendable (String) -> Void)?
        /// 기한이 지났을 때 `commit.timeOut()` 대신 부른다 (16장 2): 요청을 시간 초과로 정하는 것과 그 전이에서 함께 정할 것(미전달 답 닫기, 14장 7)을 한 경계에서.
        /// `commit.timeOut()`의 결과(처리기가 먼저 확정한 응답, 시간 초과면 nil)를 돌려준다. 막지 않는 일만. 없으면 `commit.timeOut()`
        public var timeOut: (@Sendable (HookCommit, String) -> HookResponse?)?

        /// 돌려준 응답을 그대로 확정하는 처리기 (시간 초과가 먼저면 쓰이지 않는다)
        public init(
            agentSessionID: String, providerSessionID: String?, handler: @escaping @Sendable (HookRequest) async -> HookResponse, onAnswer: (@Sendable (String) -> Void)? = nil
        ) {
            self.init(agentSessionID: agentSessionID, providerSessionID: providerSessionID, committing: { request, commit in
                _ = commit.commit(await handler(request))
            }, onAnswer: onAnswer)
        }

        /// 스스로 확정하는 처리기: 확정에 실패하면(소켓이 시간 초과로 이미 deny를 썼다) 그 결과를 기록하지 않는다
        public init(
            agentSessionID: String, providerSessionID: String?, committing handler: @escaping @Sendable (HookRequest, HookCommit) async -> Void,
            onAnswer: (@Sendable (String) -> Void)? = nil, timeOut: (@Sendable (HookCommit, String) -> HookResponse?)? = nil
        ) {
            self.agentSessionID = agentSessionID
            self.providerSessionID = providerSessionID
            self.handler = handler
            self.onAnswer = onAnswer
            self.timeOut = timeOut
        }
    }

    /// bridge가 답하는 시간 상한 (연결부터, 서버 1.0초 + 로컬). 훅은 `HookWire.budget`(4초)까지 기다리고 요청에 남은 시간을 싣는다 (16장 3)
    public static let responseBudget: TimeInterval = 1.2
    static let readBudget: TimeInterval = 1.0
    /// 훅이 실은 남은 시간보다 이만큼 앞서 정한다 (응답을 쓰고 훅이 읽을 여유)
    static let hookMargin: TimeInterval = 0.3
    public static let unknownSpawn = "This tool call is not from a Taskforce run."

    public let path: String
    private let peerUID: @Sendable (Int32) -> uid_t?
    private let log: any BridgeLogSink
    private let state = Mutex<(listener: Int32, registrations: [(nonce: [UInt8], registration: Registration, id: UUID)])>((-1, []))
    private let queue = DispatchQueue(label: "dev.taskforcelabs.bridge.hook-socket", attributes: .concurrent)

    public init(path: String, peerUID: @escaping @Sendable (Int32) -> uid_t? = HookSocketServer.peerUID, log: any BridgeLogSink = NoBridgeLog()) {
        self.path = path
        self.peerUID = peerUID
        self.log = log
    }

    deinit {
        stop()
    }

    // MARK: 경로

    /// `<Application Support>/<번들 id>/Bridge/hook.sock`. 100바이트를 넘으면 `confstr(_CS_DARWIN_USER_TEMP_DIR)` 아래 `tf-<번들 id sha256 앞 8자>/hook.sock`
    public static func socketPath(applicationSupport: URL, bundleID: String) -> String {
        let preferred = applicationSupport.appending(path: bundleID, directoryHint: .isDirectory).appending(path: "Bridge/hook.sock").path
        if preferred.utf8.count <= 100 { return preferred }
        let digest = SHA256.hash(data: Data(bundleID.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8)
        return userTemporaryDirectory() + "tf-\(digest)/hook.sock"
    }

    static func userTemporaryDirectory() -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        guard length > 0 else { return NSTemporaryDirectory() }
        let value = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return value.hasSuffix("/") ? value : value + "/"
    }

    public static func peerUID(_ fd: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }

    // MARK: 수명

    /// 폴더를 만들고(0700 · 소유자 확인) 남은 소켓 파일을 정리한 뒤 bind · listen하고 받기를 시작한다
    public func start() throws {
        let folder = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(folder, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else { throw POSIXError(.EPERM) }
        guard chmod(folder, 0o700) == 0 else { throw POSIXError(.EPERM) }
        if lstat(path, &info) == 0 {
            // 남은 소켓: 이 사용자의 것만 지운다
            guard info.st_uid == getuid(), unlink(path) == 0 else { throw POSIXError(.EEXIST) }
        }
        let pathBytes = Array(path.utf8)
        guard pathBytes.count <= UnixSocket.maxPathBytes else { throw POSIXError(.ENAMETOOLONG) }
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        _ = fcntl(listener, F_SETFD, FD_CLOEXEC)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes + [0]) }
        let previous = umask(0o077)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(previous)
        guard bound == 0, chmod(path, 0o600) == 0, listen(listener, 16) == 0, fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK) == 0 else {
            close(listener)
            throw POSIXError(.EADDRINUSE)
        }
        state.withLock { $0.listener = listener }
        let thread = Thread { [weak self] in
            Self.acceptLoop(listener, server: { [weak self] in self })
            close(listener) // 받기 스레드가 닫는다 (다른 스레드가 쓰는 fd를 닫지 않게)
        }
        thread.name = "tf-hook-socket"
        thread.start()
    }

    /// 받기를 멈추고 소켓 파일을 지운다 (받기 스레드는 다음 확인 때 listener를 닫고 끝난다)
    public func stop(removeFile: Bool = true) {
        let listener = state.withLock { value -> Int32 in
            let fd = value.listener
            value.listener = -1
            return fd
        }
        guard listener >= 0 else { return }
        if removeFile { unlink(path) }
    }

    private func isRunning(_ listener: Int32) -> Bool {
        state.withLock { $0.listener == listener }
    }

    // MARK: 등록부

    public func register(nonce: String, _ registration: Registration) {
        state.withLock { $0.registrations.append((Array(nonce.utf8), registration, UUID())) }
    }

    /// 끝난 spawn의 nonce를 `after` 뒤에 지운다 (늦게 도착한 훅도 그 spawn의 결정기가 닫기 · deny로 답하게)
    public func unregister(nonce: String, after delay: Duration = .seconds(2)) {
        let bytes = Array(nonce.utf8)
        let id = state.withLock { $0.registrations.first { Self.constantTimeEqual($0.nonce, bytes) }?.id }
        guard let id else { return }
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            self?.state.withLock { $0.registrations.removeAll { $0.id == id } }
        }
    }

    /// 길이와 상관없이 모든 바이트를 본다 (길이가 다르면 다르다)
    static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        var difference = UInt8(a.count == b.count ? 0 : 1)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            difference |= x ^ y
        }
        return difference == 0
    }

    func lookup(_ nonce: String) -> Registration? {
        let bytes = Array(nonce.utf8)
        return state.withLock { value in
            var found: Registration?
            for entry in value.registrations where Self.constantTimeEqual(entry.nonce, bytes) { found = entry.registration }
            return found
        }
    }

    // MARK: 연결

    /// 서버가 살아 있고 이 listener가 지금 것인 동안 받는다 (서버를 붙잡지 않는다)
    private static func acceptLoop(_ listener: Int32, server: @escaping () -> HookSocketServer?) {
        while let current = server(), current.isRunning(listener) {
            var item = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let ready = poll(&item, 1, 200)
            guard ready > 0, current.isRunning(listener) else { continue }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            // 받은 연결은 막힘 모드로 읽고 쓴다 (기한은 poll로)
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            var on: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            current.queue.async { [weak current] in
                current?.serve(client)
                close(client)
            }
        }
    }

    private func serve(_ client: Int32) {
        // 피어 uid: 다른 사용자면 읽지 않고 닫는다
        guard let uid = peerUID(client), uid == getuid() else {
            log.log("hook_socket_peer_refused", [:])
            return
        }
        let started = Date()
        var response = HookResponse(decision: .deny, reason: HookReason.unreadable)
        var answered: (registration: Registration, toolUseID: String)?
        if let line = Self.readLine(client, deadline: started.addingTimeInterval(Self.readBudget)), let request = try? HookRequest.decode(line: line) {
            if let registration = registered(for: request) {
                response = respond(to: request, registration: registration, deadline: Self.deadline(started: started, read: Date(), remainingMS: request.remainingMS))
                answered = (registration, request.toolUseID)
            } else {
                // L0: 등록 없는 nonce · 세션 불일치
                log.log("tool_gate", ["source": .code("local"), "decision": .code("deny"), "reason": .code("nonce")])
                response = HookResponse(decision: .deny, reason: Self.unknownSpawn)
            }
        }
        guard let data = try? response.encodedLine() else { return }
        if let answered { answered.registration.onAnswer?(answered.toolUseID) }
        Self.writeAll(client, data)
    }

    /// nonce가 등록돼 있고 세션 id(Taskforce · Claude Code 둘 다)가 맞는 등록
    private func registered(for request: HookRequest) -> Registration? {
        guard request.hookEvent == "PreToolUse", let registration = lookup(request.nonce), registration.agentSessionID == request.sessionID,
              registration.providerSessionID == nil || registration.providerSessionID == request.providerSessionID else { return nil }
        return registration
    }

    /// 응답을 정하는 기한 (16장 3): 연결부터 `responseBudget`, 훅이 남은 시간을 실었으면 읽은 때부터 그 시간 − `hookMargin`까지 중 이른 쪽.
    /// 그래서 확정한 응답은 훅이 끊기 `hookMargin` 전에 정해진다 (그 안에 쓰고 읽는다)
    static func deadline(started: Date, read: Date, remainingMS: Int?) -> Date {
        let own = started.addingTimeInterval(responseBudget)
        guard let remainingMS else { return own }
        return min(own, read.addingTimeInterval(Double(remainingMS) / 1000 - hookMargin))
    }

    /// 처리기가 확정한 응답, 아니면 시간 초과 deny (12장 9): 기한이 지나면 요청 상태를 `timedOut`으로 정한다(등록의 `timeOut`이 있으면 그 경계에서).
    /// 처리기가 그보다 먼저 확정했으면 그 응답을 쓴다
    private func respond(to request: HookRequest, registration: Registration, deadline: Date) -> HookResponse {
        let commit = HookCommit()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await registration.handler(request, commit)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow))
        let won: HookResponse?
        if let settle = registration.timeOut { won = settle(commit, request.toolUseID) } else { won = commit.timeOut() }
        if let won { return won }
        log.log("tool_gate", ["source": .code("local"), "decision": .code("deny"), "reason": .code("bridge_timeout")])
        return HookResponse(decision: .deny, reason: HookReason.unavailable)
    }

    static func readLine(_ fd: Int32, deadline: Date) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while !data.contains(0x0A) {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return nil }
            var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&item, 1, Int32(max(1, (left * 1000).rounded(.up))))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { return nil }
            let count = buffer.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress!, $0.count) }
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
            guard data.count <= HookWire.maxLineBytes else { return nil }
        }
        guard let newline = data.firstIndex(of: 0x0A) else { return nil }
        return data.prefix(through: newline)
    }

    static func writeAll(_ fd: Int32, _ data: Data) {
        let bytes = [UInt8](data)
        var written = 0
        while written < bytes.count {
            let count = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress! + written, $0.count - written) }
            if count > 0 {
                written += count
            } else if count < 0, errno == EINTR || errno == EAGAIN {
                continue
            } else {
                return
            }
        }
    }
}

/// 훅 요청 하나의 결과를 한 번만 정한다 (OA D3a 12장 9): `pending` → 처리기가 확정(`committed`) 또는 소켓이 시간 초과(`timedOut`). 먼저 온 쪽이 이긴다
public final class HookCommit: Sendable {
    enum State: Sendable {
        case pending
        case committed(HookResponse)
        case timedOut
    }

    private let state = Mutex(State.pending)

    public init() {}

    /// 처리기: 그 응답으로 확정한다. 소켓이 이미 시간 초과로 정했으면 false (그 응답은 Claude에 닿지 않는다)
    public func commit(_ response: HookResponse) -> Bool {
        state.withLock { current in
            guard case .pending = current else { return false }
            current = .committed(response)
            return true
        }
    }

    /// 소켓: 기한이 지났다. 처리기가 먼저 확정했으면 그 응답, 아니면 `timedOut`으로 정하고 nil
    func timeOut() -> HookResponse? {
        state.withLock { current in
            switch current {
            case .committed(let response): return response
            case .pending:
                current = .timedOut
                return nil
            case .timedOut: return nil
            }
        }
    }
}
#endif
