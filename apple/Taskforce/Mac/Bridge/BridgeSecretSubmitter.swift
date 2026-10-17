#if os(macOS)
import Foundation
import TaskforceKit

/// 이 Mac에서 비밀값 답을 내보내는 앱의 실제 구현 (OA D4b-m-2, 계약 16.3-4). 질문 저장소(`AgentQuestionStore`)가 2초 보류 뒤 부른다.
/// 일은 Kit의 `BridgeRuntime.submitLocalSecret`이 한다 (heartbeat → `LocalSecretAnswers.put` → `POST /api/v1/bridge/answer-local`). 이 구조체는 어느 런타임인지만 고른다:
/// - bridge가 꺼졌거나 런타임이 없으면 `unavailable` (카드는 "Couldn't send"로 돌아온다). 마무리 모드(`BRIDGE_ENABLED` 꺼짐 + 할 일)의 런타임은 런타임이 스스로 받지 않는다.
/// - 계정 경계 (D4bm2-05 · 검토 1 F-3): **질문 저장소와 같은 `AccountScope`의 토큰**(계정 + 세대)으로 본다. 시작에 잡은 토큰이 런타임 파티션의 사용자와 같아야 하고,
///   `put` 앞 · `POST` 앞마다 그 토큰이 여전히 현재이고(로그아웃 · 재로그인은 세대가 오른다) 활성 파티션이 그대로여야 한다. 어긋나면 값을 지우고 보내지 않는다.
///   (런타임은 여기에 더해 자기 원장이 그 요청을 열린 비밀값 요청으로 알 때만 값을 둔다.)
struct BridgeLocalSecretSubmitter: LocalSecretAnswerSubmitting {
    private let scope: AccountScope
    private let host: @MainActor @Sendable () -> BridgeHost?

    init(scope: AccountScope, host: @escaping @MainActor @Sendable () -> BridgeHost? = { BridgeHost.shared }) {
        self.scope = scope
        self.host = host
    }

    private struct Target: Sendable {
        let runtime: BridgeRuntime
        let partitionID: String
        let token: AccountScope.Token
    }

    private enum Start: Sendable {
        case unavailable
        case accountMismatch
        case ready(Target)
    }

    func submit(_ answer: LocalSecretAnswer) async -> LocalSecretOutcome {
        let scope = scope
        let host = host
        let start: Start = await MainActor.run {
            guard let current = host(), let runtime = current.activeRuntime, let partition = current.activePartition else { return .unavailable }
            guard let token = scope.token, token.userID == partition.userID else { return .accountMismatch }
            return .ready(Target(runtime: runtime, partitionID: partition.id, token: token))
        }
        switch start {
        case .unavailable:
            return .unavailable
        case .accountMismatch:
            return .failed(.generic)
        case .ready(let target):
            return await target.runtime.submitLocalSecret(answer, accountStillMatches: {
                await MainActor.run { host()?.activePartition?.id == target.partitionID && scope.isCurrent(target.token) }
            })
        }
    }
}
#endif
