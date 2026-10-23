#if os(macOS)
import Foundation

/// 올릴 행 묶음: 한 교환(`exchangeID`)의 행들과 그 세션의 저장 표시. 같은 교환이 길어지면 앞 행을 포함해 다시 들어온다 (이미 본 행은 업로더가 거른다)
public struct ClaudeAppChatBatch: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var exchangeID: String
    public var context: ClaudeAppChatContext
    public var rows: [ClaudeAppChatRow]

    public init(exchangeID: String, context: ClaudeAppChatContext, rows: [ClaudeAppChatRow]) {
        self.exchangeID = exchangeID
        self.context = context
        self.rows = rows
    }

    public var description: String { "ClaudeAppChatBatch(rows: \(rows.count))" }
    public var debugDescription: String { description }
}

/// 저장 올리기 (PR-D3k, 계약 25.4.5 · 26장 · 서버 노트 5.2): **메모리 큐만**(디스크 0 · Keychain 0). 2초마다 묶어 PUT한다.
/// - 실패하면 2 · 4 · 8 · 16 · 32 · 60초(상한)로 물러나고, 10분이 지나면 버린다 (교환마다 한 번 `onGaveUp`: 서버에 "받았지만 올리지 못했다"를 알리는 자리)
/// - 한 요청은 행 20개 · 서버가 말한 본문 상한 안이다. 사용자 행이 올라가기 전에는 답 행만 따로 보내지 않는다 (서버에서 orphan이 된다)
/// - 답이 `chat_id: null`이면 사용자가 그 대화를 지운 것이다: 그 교환의 남은 행을 더 올리지 않는다 (업로더 전체는 끄지 않는다)
/// - `404`면 저장이 꺼진 것(또는 bridge를 모른다): 큐를 비우고 끈다 (`onDisabled`). `413`(한도)은 두드리지 않는다: 5분 한 번 뒤에 다시, 10분이면 버린다
/// - 로그아웃 때 `clear()`로 비운다. 로그는 `claude_app_chat_upload {result, rows_bucket}` 코드뿐이다 (글 · 제목 · ref 0)
public actor ClaudeAppChatUploader {
    public enum PutOutcome: Equatable, Sendable {
        /// 200. `chatID`가 nil이면 이 교환만 멈춘다
        case saved(chatID: UUID?)
        /// 401 · 409 · 429 · 5xx · 네트워크: 물러났다가 다시
        case retry
        /// 400: 버그다 (재시도하지 않는다)
        case invalid
        /// 404 `bridge_not_found`를 뺀 모든 404: 저장이 꺼졌다 (gate 꺼짐 · 명단 밖 · 앞단의 404 · 모르는 코드). 업로더 전체를 끈다
        case disabled
        /// 413: 사용자별 저장 한도
        case quota
        /// 404 `bridge_not_found`만 (없는 · 남의 · 해제된 bridge): 그 bridge의 교환만 버린다 (OA PR-D3 검토 P3-10 · 재검토)
        case bridgeGone
    }

    public typealias Put = @Sendable (ClaudeAppChatPutRequest) async -> PutOutcome
    public typealias Sleep = @Sendable (TimeInterval) async -> Void

    public struct Configuration: Sendable {
        public var flushInterval: TimeInterval
        public var maxBackoff: TimeInterval
        /// 큐에 들어온 지 이만큼 지나면 버린다
        public var giveUpAfter: TimeInterval
        /// 한도(413)에 닿았을 때 다시 두드리기까지
        public var quotaRetry: TimeInterval
        public var maxBatch: Int
        public var maxBytes: Int

        public init(
            flushInterval: TimeInterval = 2, maxBackoff: TimeInterval = 60, giveUpAfter: TimeInterval = 600, quotaRetry: TimeInterval = 300, maxBatch: Int = 20, maxBytes: Int = 262_144
        ) {
            self.flushInterval = flushInterval
            self.maxBackoff = maxBackoff
            self.giveUpAfter = giveUpAfter
            self.quotaRetry = quotaRetry
            self.maxBatch = maxBatch
            self.maxBytes = maxBytes
        }
    }

    /// 요청 본문 상한에서 남겨 두는 여유 (APIClient가 같은 인코더로 쓰지만 헤더 · 줄바꿈 차이를 흡수한다)
    static let byteMargin = 2048
    /// 이미 본 행을 기억하는 수 (오래된 것부터 잊는다: 잊은 행이 다시 들어오면 서버가 멱등으로 받는다)
    static let maxKnown = 4096

    private struct Entry {
        let exchangeID: String
        let context: ClaudeAppChatContext
        let row: ClaudeAppChatRow
        let enqueuedAt: Date
        var attempts = 0
        var nextTry: Date
    }

    private let configuration: Configuration
    private let put: Put
    private let now: @Sendable () -> Date
    private let sleep: Sleep
    private let log: any BridgeLogSink
    private let onGaveUp: @Sendable (String) -> Void
    private let onDisabled: @Sendable (UUID) -> Void
    /// 이 업로더의 정체: 버린 업로더의 늦은 `onDisabled` 알림을 주인이 걸러 낸다 (OA PR-D3 검토 P3-7)
    public nonisolated let id = UUID()

    private var queue: [Entry] = []
    private var known: [String] = []
    private var knownSet: Set<String> = []
    private var stopped: Set<String> = []
    /// 사용자 행이 서버에 올라간 교환 (서버가 `received`를 이미 센 교환)
    private var savedUsers: Set<String> = []
    /// 서버가 "그런 bridge가 없다"고 한 bridge (그 bridge의 교환만 버린다)
    private var goneBridges: Set<UUID> = []
    /// 버렸다: 다시 켜지지 않는다 (`clear()`로도)
    private var retired = false
    private var loop: Task<Void, Never>?
    public private(set) var isEnabled = true
    public private(set) var quotaReached = false

    public init(
        configuration: Configuration = Configuration(), put: @escaping Put, now: @escaping @Sendable () -> Date = { Date() }, sleep: @escaping Sleep = { try? await Task.sleep(for: .seconds($0)) },
        log: any BridgeLogSink = NoBridgeLog(), onGaveUp: @escaping @Sendable (String) -> Void = { _ in }, onDisabled: @escaping @Sendable (UUID) -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.put = put
        self.now = now
        self.sleep = sleep
        self.log = log
        self.onGaveUp = onGaveUp
        self.onDisabled = onDisabled
    }

    public var pendingRows: Int { queue.count }

    /// 이 교환의 사용자 행이 서버에 올라갔다 (서버가 `received`를 이미 셌다: 뒤의 답 행을 포기해도 다시 세지 않는다)
    public func userRowSaved(_ exchangeID: String) -> Bool { savedUsers.contains(exchangeID) }

    /// 버린다: 큐를 비우고 멈추며 다시 켜지지 않는다 (`clear()`로도). 이미 날아간 요청의 늦은 답은 아무것도 바꾸지 못한다
    public func retire() {
        retired = true
        isEnabled = false
        queue = []
        loop?.cancel()
        loop = nil
    }

    /// 서버 답을 업로더의 일로 옮긴다 (순수): 모르는 오류는 다시 시도한다
    public static func outcome(for error: Error) -> PutOutcome {
        guard let api = error as? APIError else { return .retry }
        switch api.status {
        case 404?:
            // `bridge_not_found`만 그 bridge가 사라진 것이다. 그 밖의 404(저장 gate가 꺼진 `not_found` · 명단 밖 · 앞단이 낸 404 · 모르는 새 코드)는 모두 꺼진 것이다: 모르면 닫는다
            if case .server(_, .bridgeNotFound, _) = api { return .bridgeGone }
            return .disabled
        case 413?: return .quota
        case 400?: return .invalid
        default: return .retry
        }
    }

    // MARK: 넣기

    /// 이 행들을 올릴 줄에 세운다. 이미 본 행 · 멈춘 교환의 행 · 꺼진 업로더는 아무 일도 없다
    public func enqueue(_ batch: ClaudeAppChatBatch) {
        guard isEnabled, !stopped.contains(batch.exchangeID), !goneBridges.contains(batch.context.bridgeID) else { return }
        let time = now()
        for row in batch.rows {
            let key = batch.context.sessionRef + "|" + row.macRef
            guard knownSet.insert(key).inserted else { continue }
            known.append(key)
            queue.append(Entry(exchangeID: batch.exchangeID, context: batch.context, row: row, enqueuedAt: time, nextTry: time))
        }
        if known.count > Self.maxKnown {
            for key in known.prefix(known.count - Self.maxKnown) { knownSet.remove(key) }
            known.removeFirst(known.count - Self.maxKnown)
        }
    }

    /// 로그아웃 · 계정 바뀜: 큐 · 본 행 · 멈춘 교환을 모두 비운다 (다시 켜진다. 단 버린 업로더는 다시 켜지지 않는다)
    public func clear() {
        queue = []
        known = []
        knownSet = []
        stopped = []
        savedUsers = []
        goneBridges = []
        quotaReached = false
        isEnabled = !retired
    }

    // MARK: 루프

    public func start() {
        guard loop == nil else { return }
        let interval = configuration.flushInterval
        let sleep = sleep
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await sleep(interval)
                guard !Task.isCancelled else { return }
                await self?.flush()
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    // MARK: 한 번 훑기

    /// 때가 된 행을 한 번 올려 본다 (루프가 2초마다 부른다. 시험은 시계를 올리고 직접 부른다)
    public func flush() async {
        guard isEnabled else { return }
        dropExpired()
        let time = now()
        // 교환마다: 때가 된 행(사용자 행이 아직 안 올라갔으면 사용자 행이 때가 된 때만)
        var order: [String] = []
        for entry in queue where !order.contains(entry.exchangeID) { order.append(entry.exchangeID) }
        for exchange in order {
            guard isEnabled else { return }
            let mine = queue.filter { $0.exchangeID == exchange }
            let userPending = mine.contains { $0.row.role == .user }
            let due = mine.filter { $0.nextTry <= time }
            // 사용자 행이 아직 큐에 있으면 그 행이 때가 된 때만 보낸다 (답 행이 앞질러 가지 않는다)
            guard !due.isEmpty, !userPending || due.contains(where: { $0.row.role == .user }) else { continue }
            // 사용자 행이 맨 앞 (서버는 사용자 행이 답 행보다 앞이어야 `reply_to`를 푼다)
            await send(exchange: exchange, entries: due.filter { $0.row.role == .user } + due.filter { $0.row.role != .user })
        }
    }

    private func send(exchange: String, entries: [Entry]) async {
        let requests = split(entries)
        for request in requests {
            guard isEnabled, !stopped.contains(exchange) else { return }
            let refs = Set(request.messages.map(\.macRef))
            let outcome = await put(request.request)
            switch outcome {
            case .saved(let chat):
                finish(refs, exchange: exchange)
                // 사용자 행이 올라갔다: 서버가 `received`를 이미 셌다 (뒤의 답 행을 포기해도 다시 세지 않는다)
                if request.messages.contains(where: { $0.role == "user" }) { savedUsers.insert(exchange) }
                if chat == nil {
                    stopped.insert(exchange)
                    queue.removeAll { $0.exchangeID == exchange }
                    note("stopped", rows: refs.count)
                    return
                }
                note("saved", rows: refs.count)
            case .retry:
                reschedule(refs, exchange: exchange) { attempts in min(self.configuration.maxBackoff, pow(2, Double(attempts))) }
                note("retry", rows: refs.count)
                return
            case .invalid:
                finish(refs, exchange: exchange)
                note("invalid", rows: refs.count)
            case .bridgeGone:
                // 그 bridge의 것만 버린다 (업로더 전체는 켜 둔다): 큐의 그 bridge 행도 새로 들어오는 그 bridge의 묶음도
                if let bridge = request.entries.first?.context.bridgeID {
                    goneBridges.insert(bridge)
                    queue.removeAll { $0.context.bridgeID == bridge }
                }
                note("bridge_gone", rows: refs.count)
                return
            case .disabled:
                queue = []
                isEnabled = false
                note("disabled", rows: refs.count)
                onDisabled(id)
                return
            case .quota:
                quotaReached = true
                reschedule(refs, exchange: exchange) { _ in self.configuration.quotaRetry }
                note("quota", rows: refs.count)
                return
            }
        }
    }

    private struct Request {
        let request: ClaudeAppChatPutRequest
        let entries: [Entry]
        var messages: [ClaudeAppChatPutRequest.Message] { request.messages }
    }

    /// 행 20개 · 본문 상한 안으로 나눈다. 혼자서도 상한을 넘는 행은 버린다 (`row_too_large`)
    private func split(_ entries: [Entry]) -> [Request] {
        guard let context = entries.first?.context else { return [] }
        let limit = configuration.maxBytes - Self.byteMargin
        var out: [Request] = []
        var current: [Entry] = []
        func close() {
            guard !current.isEmpty else { return }
            out.append(Request(request: ClaudeAppChatPutRequest(context: context, rows: current.map(\.row)), entries: current))
            current = []
        }
        for entry in entries {
            if ClaudeAppChatPutRequest(context: context, rows: [entry.row]).encodedSize > limit {
                finish([entry.row.macRef], exchange: entry.exchangeID)
                note("row_too_large", rows: 1)
                continue
            }
            let candidate = current + [entry]
            if candidate.count > configuration.maxBatch || ClaudeAppChatPutRequest(context: context, rows: candidate.map(\.row)).encodedSize > limit { close() }
            current.append(entry)
        }
        close()
        return out
    }

    private func finish(_ refs: Set<String>, exchange: String) {
        queue.removeAll { $0.exchangeID == exchange && refs.contains($0.row.macRef) }
    }

    private func reschedule(_ refs: Set<String>, exchange: String, delay: (Int) -> TimeInterval) {
        let time = now()
        for index in queue.indices where queue[index].exchangeID == exchange && refs.contains(queue[index].row.macRef) {
            queue[index].attempts += 1
            queue[index].nextTry = time.addingTimeInterval(delay(queue[index].attempts))
        }
    }

    /// 10분이 지난 행을 버린다 (교환마다 한 번 알린다)
    private func dropExpired() {
        let time = now()
        let expired = queue.filter { time.timeIntervalSince($0.enqueuedAt) >= configuration.giveUpAfter }
        guard !expired.isEmpty else { return }
        queue.removeAll { time.timeIntervalSince($0.enqueuedAt) >= configuration.giveUpAfter }
        for exchange in Set(expired.map(\.exchangeID)).sorted() {
            note("gave_up", rows: expired.filter { $0.exchangeID == exchange }.count)
            onGaveUp(exchange)
        }
    }

    private func note(_ result: String, rows: Int) {
        log.log("claude_app_chat_upload", ["result": .code(result), "rows_bucket": .code(rows <= 1 ? "1" : (rows <= 5 ? "2-5" : "6-20"))])
    }
}

/// 저장 켜짐 확인 + 업로더의 주인 (PR-D3k, 계약 25.4.5 · DT14): **글을 보내기 전에** `status`를 묻고, 저장이 켜졌을 때만 업로더를 만든다.
/// 404(꺼짐 · 명단 밖) · `save: false`면 업로더를 만들지 않는다 (서버로 글 0). 처음 보내는 글 앞에서(`ensureAsked`) 묻고 그 뒤 1시간마다 다시 묻는다 (확인하지 못했으면 1분 뒤). 보내기는 저장과 무관하다 (⑧)
public actor ClaudeAppChatSaver {
    public typealias Status = @Sendable () async throws -> ClaudeAppChatsStatus
    public typealias Sleep = @Sendable (TimeInterval) async -> Void

    /// 켜졌는지 다시 묻는 간격
    public static let refreshInterval: TimeInterval = 3600
    /// 확인하지 못했을 때 다시 묻기까지
    public static let failedRetryInterval: TimeInterval = 60

    private let status: Status
    private let put: ClaudeAppChatUploader.Put
    private let now: @Sendable () -> Date
    private let sleep: Sleep
    private let log: any BridgeLogSink
    private let onGaveUp: @Sendable (String) -> Void
    /// 대화 흐름이 나중에 다는 "올리기를 포기한 교환" 알림 (서버에 "받았지만 올리지 못했다"를 알리는 자리)
    private var gaveUpHandler: (@Sendable (String) -> Void)?
    private var uploader: ClaudeAppChatUploader?
    private var loop: Task<Void, Never>?
    private var generation = 0
    /// 서버에 저장이 켜졌는지 한 번이라도 물었다 (`ensureAsked`)
    private var asked = false

    public init(
        status: @escaping Status, put: @escaping ClaudeAppChatUploader.Put, now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping Sleep = { try? await Task.sleep(for: .seconds($0)) }, log: any BridgeLogSink = NoBridgeLog(), onGaveUp: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.status = status
        self.put = put
        self.now = now
        self.sleep = sleep
        self.log = log
        self.onGaveUp = onGaveUp
    }

    /// 지금 올릴 수 있다 (저장이 켜졌고 업로더가 있다)
    public var isSaving: Bool { uploader != nil }

    /// 올리기를 포기한 교환을 알려 달라고 건다 (교환마다 한 번)
    public func setGaveUpHandler(_ handler: @escaping @Sendable (String) -> Void) {
        gaveUpHandler = handler
    }

    private func gaveUp(_ exchangeID: String) {
        onGaveUp(exchangeID)
        gaveUpHandler?(exchangeID)
    }

    /// 서버에 저장이 켜졌는지 묻는다. 켜졌으면 업로더를 (없을 때만) 만들고, 아니면 업로더를 버린다. 확인하지 못했으면 true를 돌려준다 (다시 물을 때가 됐다)
    @discardableResult
    public func refresh() async -> Bool {
        let started = generation
        let answer: Result<ClaudeAppChatsStatus, Error>
        do { answer = .success(try await status()) } catch { answer = .failure(error) }
        guard started == generation else { return false }
        switch answer {
        case .success(let state) where state.save:
            if uploader == nil {
                var configuration = ClaudeAppChatUploader.Configuration()
                configuration.maxBatch = state.maxBatch
                configuration.maxBytes = state.maxBytes
                let made = ClaudeAppChatUploader(
                    configuration: configuration, put: put, now: now, sleep: sleep, log: log, onGaveUp: { [weak self] id in Task { await self?.gaveUp(id) } },
                    onDisabled: { [weak self] id in Task { await self?.uploaderDisabled(id) } }
                )
                uploader = made
                await made.start()
                log.log("claude_app_chat_status", ["result": .code("on")])
            }
            return false
        case .success:
            await discardUploader()
            log.log("claude_app_chat_status", ["result": .code("off")])
            return false
        case .failure(let error):
            // 404 = 꺼짐 · 명단 밖: 다시 묻는 것은 1시간 뒤. 그 밖의 오류(네트워크 · 5xx · 인증)는 1분 뒤
            if (error as? APIError)?.status == 404 {
                await discardUploader()
                log.log("claude_app_chat_status", ["result": .code("off")])
                return false
            }
            // 물어보지 못했다: 이미 돌고 있는 업로더는 그대로 둔다 (네트워크가 잠깐 끊겨도 큐를 버리지 않는다)
            log.log("claude_app_chat_status", ["result": .code("unknown")])
            return true
        }
    }

    /// 곧바로 한 번 묻고, 그 뒤 1시간마다 (못 물었으면 1분 뒤)
    public func startRefreshing() {
        guard loop == nil else { return }
        asked = true
        runLoop(askFirst: true, retrySoon: false)
    }

    /// **글을 보내기 전에** 부른다: 아직 한 번도 안 물었으면 지금 묻고 그 뒤 1시간마다 다시 묻는 루프를 건다. 이미 물었으면 아무 일도 없다.
    /// (앱 시작에 미리 묻지 않는다: 이 대화를 한 번도 쓰지 않는 사용자에게는 서버 호출이 0이다. 보낼 글이 없으면 올릴 것도 없다)
    public func ensureAsked() async {
        guard !asked else { return }
        asked = true
        let soon = await refresh()
        runLoop(askFirst: false, retrySoon: soon)
    }

    private func runLoop(askFirst: Bool, retrySoon: Bool) {
        guard loop == nil else { return }
        let sleep = sleep
        loop = Task { [weak self] in
            var soon = retrySoon
            var ask = askFirst
            while !Task.isCancelled {
                if ask {
                    guard let again = await self?.refresh() else { return }
                    soon = again
                }
                ask = true
                await sleep(soon ? Self.failedRetryInterval : Self.refreshInterval)
            }
        }
    }

    public func stopRefreshing() {
        loop?.cancel()
        loop = nil
    }

    /// 업로더가 있을 때만 큐에 올린다 (없으면 서버로 가는 것이 하나도 없다: DT14)
    public func enqueue(_ batch: ClaudeAppChatBatch) async {
        await uploader?.enqueue(batch)
    }

    /// 로그아웃: 큐를 비우고 업로더를 버리고 다시 묻는 루프도 멈춘다. 다시 로그인해 처음 보내는 글 앞에서 `ensureAsked()`가 새로 묻는다
    public func clear() async {
        generation += 1
        loop?.cancel()
        loop = nil
        asked = false
        await discardUploader()
    }

    /// 버린 업로더는 다시 켜지지 않는다 (`retire()`): 이미 날아간 요청의 늦은 답이 새 업로더의 일을 건드리지 못한다
    private func discardUploader() async {
        let old = uploader
        uploader = nil
        await old?.retire()
    }

    /// 지금 업로더의 정체 (없으면 nil)
    var uploaderIdentity: UUID? { uploader?.id }

    /// 업로더가 스스로 꺼졌다고 알린다: **정체가 지금 업로더일 때만** 받는다 (버린 업로더의 늦은 알림은 새 업로더를 끄지 못한다, OA PR-D3 검토 P3-7)
    func uploaderDisabled(_ id: UUID) async {
        guard uploader?.id == id else { return }
        await discardUploader()
    }

    /// 이 교환의 사용자 행이 서버에 올라갔다 (서버가 `received`를 이미 셌다)
    public func userRowSaved(_ exchangeID: String) async -> Bool {
        await uploader?.userRowSaved(exchangeID) ?? false
    }

    /// 오래 걸리는 status 호출을 시간 안에서만 기다린다: 넘으면 모르는 답(`APIError.transport`)으로 끝난다 (저장은 켜지 않고 1분 뒤 다시 묻는다). 취소에 반응하는 호출이어야 일찍 돌아온다 (`URLSession`은 그렇다)
    public static func timed<T: Sendable>(seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw APIError.transport("status timed out")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw APIError.transport("status timed out") }
            return first
        }
    }
}
#endif
