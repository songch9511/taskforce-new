import Foundation

// OA D4b-m-1 (계약 4.5, F2 notes 10장): 이 Mac에서 비밀값을 내보내는 **순서와 결과 표**. 실제 포트(heartbeat · `LocalSecretAnswers.put` · `POST /api/v1/bridge/answer-local`)는
// D3a가 바꾸는 파일(`BridgeClient` · `BridgeRuntime*` · `AgentProcess`)에 있어 D4b-m-2가 채운다. 여기는 포트를 받아 같은 순서를 지키는 규칙뿐이다 (가짜 포트로 시험한다).
// 순서: ① heartbeat가 성공한 **뒤에만** ② `put`을 **먼저** ③ 요청 (주소는 상수, 쿼리 · 경로 인자 0, 본문 키는 `bridge_id` · `agent_task_id` · `request_digest` 셋) ④ 결과에 따라 값을 두거나 지운다.
// 요청 포트에는 `provider_request_id`의 SHA-256(소문자 16진 64자)만 건넨다: 값도 `provider_request_id`도 요청 쪽으로 가지 않는다. 이 파일은 로그를 쓰지 않는다.

public enum AgentQuestionSecretFlow {
    /// `answer-local` 한 번의 결과 (F2 응답 · 오류 표)
    public enum Reply: Sendable, Equatable {
        /// 200 `answered`
        case answered
        /// 200 `duplicate` (`answered`와 같게)
        case duplicate
        /// 200 `stale` + 이유
        case stale(StaleReason)
        /// 그 밖 HTTP 상태 (400 · 401 · 403 · 404 · 409 · 429 · 5xx …)
        case http(Int)
        /// 네트워크 오류
        case network
    }

    public enum StaleReason: Sendable, Equatable {
        case questionClosed, notLive, notSecret
    }

    /// 답에 따라 할 일
    public enum Decision: Sendable, Equatable {
        /// 끝났다 (값은 lease가 가져가도록 둔다)
        case done(LocalSecretOutcome)
        /// 값을 지우고 끝낸다
        case erase(LocalSecretOutcome)
        /// 값을 두고 같은 요청을 다시 (멱등)
        case retry
        /// 값을 두고 heartbeat · reconcile로 작업을 되살린 뒤 한 번 다시
        case reviveAndRetry
    }

    /// 같은 요청을 보내 보는 최대 횟수 (첫 요청 포함). 끝내 모르면 값을 지우고 카드를 되돌린다
    public static let maxAttempts = 3

    /// 결과 표 (순수 함수). `attempt`는 지금까지 보낸 요청 수(1부터), `revived`는 이미 되살려 봤는가
    public static func decision(for reply: Reply, attempt: Int, revived: Bool) -> Decision {
        switch reply {
        case .answered, .duplicate:
            return .done(.sent)
        case .stale(.questionClosed), .stale(.notSecret):
            return .erase(.questionClosed)
        case .stale(.notLive):
            return revived ? .erase(.failed(.generic)) : .reviveAndRetry
        case .http(let status):
            switch status {
            case 404, 401, 403: return .erase(.questionClosed)
            case 400: return .erase(.failed(.generic))
            default: return attempt < maxAttempts ? .retry : .erase(.failed(.generic))
            }
        case .network:
            return attempt < maxAttempts ? .retry : .erase(.failed(.offline))
        }
    }

    /// 실제 일을 하는 곳 (D4b-m-2가 채운다)
    public struct Ports: Sendable {
        /// heartbeat가 성공했나 (잠에서 깬 직후 `not_live`를 막는다)
        public var heartbeat: @Sendable () async -> Bool
        /// `LocalSecretAnswers.put`
        public var put: @Sendable (LocalSecretAnswer) async -> Void
        /// 값을 지운다 (`take`해 버린다)
        public var erase: @Sendable (AgentQuestionKey) async -> Void
        /// 작업을 되살린다 (heartbeat · reconcile)
        public var reconcile: @Sendable () async -> Void
        /// `POST …/answer-local`: digest만 받는다
        public var post: @Sendable (_ digest: String) async -> Reply
        /// 다시 보내기 전 잠깐 기다린다 (초)
        public var pause: @Sendable (TimeInterval) async -> Void

        public init(
            heartbeat: @escaping @Sendable () async -> Bool, put: @escaping @Sendable (LocalSecretAnswer) async -> Void,
            erase: @escaping @Sendable (AgentQuestionKey) async -> Void, reconcile: @escaping @Sendable () async -> Void,
            post: @escaping @Sendable (_ digest: String) async -> Reply, pause: @escaping @Sendable (TimeInterval) async -> Void
        ) {
            self.heartbeat = heartbeat
            self.put = put
            self.erase = erase
            self.reconcile = reconcile
            self.post = post
            self.pause = pause
        }
    }

    public static func run(_ answer: LocalSecretAnswer, ports: Ports) async -> LocalSecretOutcome {
        guard await ports.heartbeat() else { return .failed(.generic) }
        await ports.put(answer)
        let digest = AgentQuestionRules.requestDigest(answer.key.requestID)
        var attempt = 0
        var revived = false
        while true {
            attempt += 1
            let reply = await ports.post(digest)
            switch decision(for: reply, attempt: attempt, revived: revived) {
            case .done(let outcome):
                return outcome
            case .erase(let outcome):
                await ports.erase(answer.key)
                return outcome
            case .retry:
                await ports.pause(0.5 * Double(attempt))
            case .reviveAndRetry:
                revived = true
                await ports.reconcile()
                guard await ports.heartbeat() else {
                    await ports.erase(answer.key)
                    return .failed(.generic)
                }
            }
        }
    }
}
