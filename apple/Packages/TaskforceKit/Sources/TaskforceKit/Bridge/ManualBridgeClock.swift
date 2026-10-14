#if os(macOS) && DEBUG
import Foundation

/// 수동 시계 (시험 전용, Release 바이너리에 없다): 시험이 시간을 직접 흘린다. lease 330초 · heartbeat 90초를 실제로 기다리지 않는다.
/// `sleep`은 `advance(by:)`가 마감 시각을 지나게 할 때까지 멈춰 있다 (취소하면 바로 `CancellationError`).
public final class ManualBridgeClock: @unchecked Sendable {
    private struct Sleeper {
        let id: Int
        let deadline: Date
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var current: Date
    private var sleepers: [Sleeper] = []
    private var nextID = 0

    public init(_ start: Date = Date(timeIntervalSince1970: 1_760_400_000)) {
        current = start
    }

    public var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    public var sleeperCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sleepers.count
    }

    /// 런타임에 넘길 시계
    public var clock: BridgeClock {
        BridgeClock(now: { [self] in now }, sleep: { [self] duration in try await sleep(duration) })
    }

    private func sleep(_ duration: Duration) async throws {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        let id: Int = lock.withLock {
            nextID += 1
            return nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if seconds <= 0 {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                sleepers.append(Sleeper(id: id, deadline: current.addingTimeInterval(seconds), continuation: continuation))
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let index = sleepers.firstIndex { $0.id == id }
            let sleeper = index.map { sleepers.remove(at: $0) }
            lock.unlock()
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// 시간을 흘린다: 마감이 지난 sleeper를 마감 순서대로 깨우고, 깨어난 일이 진행하도록 양보한다
    public func advance(by seconds: TimeInterval) async {
        let target = lock.withLock { current.addingTimeInterval(seconds) }
        while true {
            let due: Sleeper? = lock.withLock {
                let ready = sleepers.filter { $0.deadline <= target }.min { $0.deadline < $1.deadline }
                guard let ready else { return nil }
                sleepers.removeAll { $0.id == ready.id }
                if ready.deadline > current { current = ready.deadline }
                return ready
            }
            guard let due else { break }
            due.continuation.resume()
            for _ in 0..<20 { await Task.yield() }
        }
        lock.withLock { if target > current { current = target } }
        for _ in 0..<20 { await Task.yield() }
    }

    /// 시간을 흘리지 않고 시각만 옮긴다 (sleeper는 깨우지 않는다)
    public func jump(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}
#endif
