import Foundation

// OA D4b-m-1: 비밀값 답의 자료형. 비밀값은 이 Mac의 메모리에만 있다 (서버에도 디스크에도 로그에도 없다, 계약 7장 · D4bm-45).
// 값을 담는 상자는 글로 찍어도 · 덤프해도 · 거울(Mirror)로 들여다봐도 값이 나오지 않는다. 값을 꺼내는 곳은 `reveal()` 하나뿐이고 보내는 순간에만 부른다.
// 실제 전달(heartbeat → `LocalSecretAnswers.put` → `POST /api/v1/bridge/answer-local`)은 D4b-m-2다: 여기는 프로토콜과 순서 규칙(`AgentQuestionSecretFlow.swift`)까지다.

/// 비밀값 하나. `description` · `debugDescription` · `customMirror` 모두 값을 말하지 않는다
public struct SecretBox: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let value: String

    public init(_ value: String) {
        self.value = value
    }

    /// 값이 없다 (보내지 않는다)
    public var isEmpty: Bool { value.isEmpty }

    /// 보내는 순간에만 부른다
    public func reveal() -> String { value }

    public var description: String { "<secret>" }
    public var debugDescription: String { "<secret>" }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

/// 이 Mac에만 두는 답 한 건 (비밀값이 섞인 요청의 모든 답, D4bm-43): 서버로 가지 않는다
public struct LocalSecretAnswer: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public enum Value: Sendable, Equatable {
        case plain(ConversationAnswerValue)
        case secret(SecretBox)
    }

    public let key: AgentQuestionKey
    public let answers: [String: Value]

    public init(key: AgentQuestionKey, answers: [String: Value]) {
        self.key = key
        self.answers = answers
    }

    /// 보내는 순간에만: 질문 id마다 값을 펼친다 (비밀값은 글로 풀린다)
    public func revealed() -> [String: ConversationAnswerValue] {
        answers.mapValues { value in
            switch value {
            case .plain(let plain): plain
            case .secret(let box): .text(box.reveal())
            }
        }
    }

    public var description: String { "LocalSecretAnswer(\(answers.count) answers)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

/// 이 Mac에 두는 답을 내보내는 곳. 앱의 실제 구현은 D4b-m-2가 넣는다 (D3a 병합 뒤): 그 전 앱은 구현이 없다 — `unavailable`을 돌려받으면 카드는 "Couldn't send"로 돌아온다.
/// 시험 · 견본은 가짜 구현을 쓴다
public protocol LocalSecretAnswerSubmitting: Sendable {
    func submit(_ answer: LocalSecretAnswer) async -> LocalSecretOutcome
}

/// 비밀값 답을 내보낸 결과 (F2 `answer-local` 결과 표를 카드가 쓰는 모양으로: `AgentQuestionSecretFlow.classify`)
public enum LocalSecretOutcome: Sendable, Equatable {
    /// 서버가 받았다 (`answered` · `duplicate`): 값은 lease가 가져간다
    case sent
    /// 질문이 닫혔다 (`question_closed` · `not_secret` · 404 · 401 · 403): 값을 지웠고, 질문을 다시 읽는다
    case questionClosed
    /// 끝내 알 수 없었다: 값을 지우고 카드를 되돌린다
    case failed(AgentQuestionFailure)
    /// 이 빌드에는 내보내는 구현이 없다
    case unavailable
}
