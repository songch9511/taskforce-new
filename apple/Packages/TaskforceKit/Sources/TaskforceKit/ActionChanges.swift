import Foundation
import Supabase

/// `actions` 테이블 Realtime 구독. 바뀐 내용은 쓰지 않고 "뭔가 바뀜" 신호로만 쓴다:
/// 지금 할 일은 항상 `/api/v1/now`를 다시 불러 서버가 정한 순서를 보여준다.
public enum ActionChanges {
    public static func signals(supabase: SupabaseClient, userID: UUID) -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        // 구독마다 다른 이름: 같은 이름이면 `channel(_:)`이 아직 지우는 중인 옛 채널(이미 구독됨)을 돌려줘
        // 새 postgresChange가 등록되지 않고 신호가 영영 오지 않는다.
        let channel = supabase.channel("actions-\(userID.lowercased)-\(UUID().lowercased)")
        let changes = channel.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "actions",
            filter: .eq("user_id", value: userID.lowercased),
            // 내용은 쓰지 않으므로 id만 받는다 (행에 큰 임베딩 벡터가 있다). 거르는 열(user_id)도 함께 받아 필터가 확실히 걸리게 한다.
            select: ["id", "user_id"]
        )
        let task = Task {
            do {
                try await channel.subscribeWithError()
            } catch {
                // 구독이 안 돼도 새로고침 · 화면 복귀 때 다시 불러오므로 조용히 끝낸다
                continuation.finish()
                return
            }
            for await _ in changes {
                continuation.yield()
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in
            task.cancel()
            Task { await supabase.removeChannel(channel) }
        }
        return stream
    }
}

/// 짧은 시간에 몰린 신호를 하나로 묶는다 (파이프라인이 Action 여러 개를 한꺼번에 쓸 때).
public enum Debounce {
    public static func signals(_ upstream: AsyncStream<Void>, interval: Duration) -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task {
            let pending = PendingFlag()
            await withTaskGroup(of: Void.self) { group in
                for await _ in upstream {
                    guard await pending.mark() else { continue }
                    group.addTask {
                        try? await Task.sleep(for: interval)
                        await pending.clear()
                        continuation.yield()
                    }
                }
                await group.waitForAll()
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private actor PendingFlag {
        private var pending = false

        /// 이미 기다리는 중이면 false
        func mark() -> Bool {
            if pending { return false }
            pending = true
            return true
        }

        func clear() {
            pending = false
        }
    }
}
