#if os(macOS)
import Foundation
import Supabase

/// 새 명령 깨우기 신호 (OA D2b 계약 2.10). `bridge_commands` INSERT를 사용자 세션(RLS)으로 구독한다 (`ActionChanges.swift` 방식).
/// 신호가 오면 `GET commands?wait=0`을 부른다. 구독이 붙어 있는 동안은 긴 대기를 돌리지 않는다 (서버 DB 부하, D2a Q26).
/// 끊겼거나 구독이 안 되면 `isSubscribed`가 false이고 런타임은 `wait=25` 긴 대기로 돌아간다. 안전망은 heartbeat `pending_commands`다.
public protocol BridgeWakeSource: Sendable {
    /// 구독을 시작하고 신호 스트림을 돌려준다 (`bridgeID`의 새 명령마다 하나)
    func start(bridgeID: String) async -> AsyncStream<Void>
    /// 지금 신호를 받을 수 있나 (채널이 `subscribed`이고 연결이 살아 있다)
    var isSubscribed: Bool { get async }
    func stop() async
}

/// Supabase Realtime 구현. 앱에서만 쓰고 시험은 `FakeBridgeWake`를 쓴다. 실제 스택 확인은 코디네이터 MS-1 단계다.
public final class SupabaseBridgeWake: BridgeWakeSource, @unchecked Sendable {
    private let supabase: SupabaseClient
    private let lock = NSLock()
    private var channel: RealtimeChannelV2?
    private var statusTask: Task<Void, Never>?
    private var subscribed = false

    public init(supabase: SupabaseClient) {
        self.supabase = supabase
    }

    /// 구독마다 다른 이름: 같은 이름이면 아직 지우는 중인 옛 채널을 돌려줘 새 구독이 등록되지 않는다
    static func channelName(bridgeID: String, nonce: UUID = UUID()) -> String {
        "bridge-commands-\(bridgeID.lowercased())-\(nonce.uuidString.lowercased())"
    }

    public func start(bridgeID: String) async -> AsyncStream<Void> {
        await stop()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let channel = supabase.channel(Self.channelName(bridgeID: bridgeID))
        // 내용은 쓰지 않으므로 id와 거르는 열만 받는다
        let inserts = channel.postgresChange(
            InsertAction.self, schema: "public", table: "bridge_commands", filter: .eq("bridge_id", value: bridgeID.lowercased()), select: ["id", "bridge_id"]
        )
        let statuses = channel.statusChange
        lock.withLock { self.channel = channel }
        let statusTask = Task { [weak self] in
            for await status in statuses {
                self?.lock.withLock { self?.subscribed = (status == .subscribed) }
            }
            self?.lock.withLock { self?.subscribed = false }
        }
        lock.withLock { self.statusTask = statusTask }
        Task {
            do {
                try await channel.subscribeWithError()
            } catch {
                // 구독이 안 되면 긴 대기가 이어서 돈다
                continuation.finish()
                return
            }
            for await _ in inserts { continuation.yield() }
            continuation.finish()
        }
        continuation.onTermination = { _ in
            Task { await self.supabase.removeChannel(channel) }
        }
        return stream
    }

    public var isSubscribed: Bool {
        get async { lock.withLock { subscribed } }
    }

    public func stop() async {
        let (channel, task): (RealtimeChannelV2?, Task<Void, Never>?) = lock.withLock {
            let pair = (self.channel, self.statusTask)
            self.channel = nil
            self.statusTask = nil
            self.subscribed = false
            return pair
        }
        task?.cancel()
        if let channel { await supabase.removeChannel(channel) }
    }
}

#if DEBUG
/// 시험 대역: 시험이 신호와 구독 상태를 직접 정한다
public final class FakeBridgeWake: BridgeWakeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<Void>.Continuation?
    private var subscribed: Bool
    public private(set) var startedBridgeIDs: [String] = []
    public private(set) var stopCount = 0

    public init(subscribed: Bool = true) {
        self.subscribed = subscribed
    }

    public func start(bridgeID: String) async -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        lock.withLock {
            self.continuation?.finish()
            self.continuation = continuation
            startedBridgeIDs.append(bridgeID)
        }
        return stream
    }

    public var isSubscribed: Bool {
        get async { lock.withLock { subscribed } }
    }

    public func stop() async {
        lock.withLock {
            continuation?.finish()
            continuation = nil
            stopCount += 1
        }
    }

    /// 새 명령 신호
    public func fire() {
        _ = lock.withLock { continuation?.yield() }
    }

    public func setSubscribed(_ value: Bool) {
        lock.withLock { subscribed = value }
    }
}
#endif
#endif
