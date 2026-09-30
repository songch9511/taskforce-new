import Foundation

/// 겹쳐 부른 작업을 한 번만 돌린다: 돌고 있으면 새로 시작하지 않고 그 끝을 함께 기다린다.
/// 작업은 부른 쪽과 따로 돈다: 먼저 부른 화면이 사라져도(취소) 다른 쪽이 기다리는 작업은 끝까지 돈다.
/// 취소된 쪽도 작업이 끝날 때까지 기다렸다 돌아온다: 뒤이어 할 일은 부른 쪽이 `Task.isCancelled`를 보고 정한다.
@MainActor
public final class SingleFlight {
    private var running: Task<Void, Never>?

    public init() {}

    public func run(_ operation: @escaping @MainActor () async -> Void) async {
        if let running { return await running.value }
        let task = Task { await operation() }
        running = task
        await task.value
        if running == task { running = nil }
    }

    /// 돌고 있는 작업을 잊는다 (그 작업은 끝까지 돈다). 다음 `run`은 새로 시작한다: 로그아웃 · 계정 전환 뒤
    public func reset() {
        running = nil
    }
}
