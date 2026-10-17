#if os(macOS)
import Foundation
import TaskforceKit

/// 이 Mac에서 비밀값 답을 내보내는 앱의 실제 구현 (OA D4b-m-2, 계약 16.3-4). 질문 저장소(`AgentQuestionStore`)가 2초 보류 뒤 부른다.
/// 일은 Kit의 `BridgeRuntime.submitLocalSecret`이 한다 (heartbeat → `LocalSecretAnswers.put` → `POST /api/v1/bridge/answer-local`). 이 구조체는 어느 런타임인지만 고른다:
/// - bridge가 꺼졌거나 런타임이 없으면 `unavailable` (카드는 "Couldn't send"로 돌아온다). 마무리 모드(`BRIDGE_ENABLED` 꺼짐 + 할 일)의 런타임은 런타임이 스스로 받지 않는다.
/// - 계정 경계 (D4bm2-05): 시작 · `put` 앞 · `POST` 앞마다 "런타임 파티션의 사용자 = 질문 저장소가 보는 계정"을 다시 본다. 활성 파티션은 계정 전환 중에 바뀐다 (`BridgeHost.activePartitionID`).
///   어긋나면 값을 지우고 보내지 않는다.
struct BridgeLocalSecretSubmitter: LocalSecretAnswerSubmitting {
    /// 질문 저장소가 보는 지금 로그인한 계정 (앱에서는 `AccountScope`가 묶인 것과 같은 세션 원천)
    private let account: @MainActor @Sendable () -> UUID?
    private let host: @MainActor @Sendable () -> BridgeHost?

    init(account: @escaping @MainActor @Sendable () -> UUID?, host: @escaping @MainActor @Sendable () -> BridgeHost? = { BridgeHost.shared }) {
        self.account = account
        self.host = host
    }

    private struct Target: Sendable {
        let runtime: BridgeRuntime
        let partitionID: String
        let userID: UUID
    }

    private enum Start: Sendable {
        case unavailable
        case accountMismatch
        case ready(Target)
    }

    func submit(_ answer: LocalSecretAnswer) async -> LocalSecretOutcome {
        let account = account
        let host = host
        let start: Start = await MainActor.run {
            guard let current = host(), let runtime = current.activeRuntime, let partition = current.activePartition else { return .unavailable }
            guard account() == partition.userID else { return .accountMismatch }
            return .ready(Target(runtime: runtime, partitionID: partition.id, userID: partition.userID))
        }
        switch start {
        case .unavailable:
            return .unavailable
        case .accountMismatch:
            return .failed(.generic)
        case .ready(let target):
            return await target.runtime.submitLocalSecret(answer, accountStillMatches: {
                await MainActor.run { host()?.activePartition?.id == target.partitionID && account() == target.userID }
            })
        }
    }
}
#endif
