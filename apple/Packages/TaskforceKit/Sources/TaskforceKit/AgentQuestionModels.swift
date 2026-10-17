import Foundation

// OA D4b-m-1: 에이전트의 열린 질문 읽기의 모양. 서버는 `agent_tasks.pending_question`(jsonb)에 질문 하나를 쥐고 있고, 모양은 서버 검증 함수 `agent_pending_question_valid`
// (`20261116000000_agent_events.sql`)가 지킨다: 키는 `question_key` · `provider_request_id` · `kind`(`input` | `approval`) · `structured` · `questions`(1–4개) · `asked_at`.
// 앱은 서버 값을 모양으로 옮길 뿐이다 (질문 글을 만들거나 고치지 않는다). 모르는 모양은 카드 없이 조용히 버린다: 크래시 0 · 질문 글 로그 0.
// 질문 글 · 선택지는 에이전트가 보낸 사용자 데이터라 메모리에만 둔다 (디스크 · 로그 없음). U2의 세션 열 목록(`AgentSessionModels.swift`)은 질문 글을 읽지 않는 채로 둔다 — 질문은 이 파일의 새 읽기가 따로 읽는다.

/// 열린 질문의 열쇠: 서버 `question_key` = [agent_task_id, provider_request_id]. 같은 task에 새 질문이 오면 `requestID`가 달라진다 (한 질문 = 한 열쇠)
public struct AgentQuestionKey: Hashable, Sendable {
    public let taskID: UUID
    public let requestID: String

    public init(taskID: UUID, requestID: String) {
        self.taskID = taskID
        self.requestID = requestID
    }
}

public struct PendingQuestionOption: Equatable, Sendable {
    public let label: String
    /// 서버가 주는 설명 (비어 있을 수 있다). 화면에는 그리지 않고 도움말 · 접근성 힌트로만 쓴다 (D4bm-13)
    public let description: String

    public init(label: String, description: String = "") {
        self.label = label
        self.description = description
    }
}

/// `questions[]`의 한 항목
public struct PendingQuestionPrompt: Equatable, Sendable, Identifiable {
    public let id: String
    public let header: String
    public let text: String
    public let options: [PendingQuestionOption]
    public let multiSelect: Bool
    public let allowOther: Bool
    public let secret: Bool

    public init(id: String, header: String, text: String, options: [PendingQuestionOption], multiSelect: Bool = false, allowOther: Bool = false, secret: Bool = false) {
        self.id = id
        self.header = header
        self.text = text
        self.options = options
        self.multiSelect = multiSelect
        self.allowOther = allowOther
        self.secret = secret
    }
}

/// 서버가 task에 쥔 열린 질문 하나
public struct AgentPendingQuestion: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case input, approval
    }

    public let key: AgentQuestionKey
    public let kind: Kind
    public let structured: Bool
    public let prompts: [PendingQuestionPrompt]
    public let askedAt: Date?

    /// 질문 중 하나라도 비밀값이면 요청 전체가 비밀값이다: 답 route는 409 `secret_requires_local`이고 모든 답을 이 Mac에 둔다 (D4bm-43)
    public var hasSecret: Bool { prompts.contains(where: \.secret) }

    /// 서버 `pending_question` JSON을 읽는다. 서버 검증 모양이 아니면 nil (카드를 그리지 않는다).
    /// 서버가 task에 이미 보장하는 것(열쇠의 첫 값 = task id)과 답 route가 요구하는 것(승인은 질문 하나 · id `approval` · 선택지 둘)도 여기서 확인한다 — 어긋나면 답을 받아 줄 수 없는 카드이기 때문이다
    public init?(json: Data, taskID: UUID) {
        guard let wire = try? TaskforceJSON.decoder().decode(Wire.self, from: json) else { return nil }
        self.init(wire: wire, taskID: taskID)
    }

    init?(wire: Wire, taskID: UUID) {
        guard wire.questionKey.count == 2, wire.questionKey[1] == wire.providerRequestID, !wire.providerRequestID.isEmpty,
              wire.providerRequestID.count <= 200, UUID(uuidString: wire.questionKey[0]) == taskID else { return nil }
        let kind: Kind
        switch wire.kind {
        case "input": kind = .input
        case "approval": kind = .approval
        default: return nil
        }
        guard (1...4).contains(wire.questions.count) else { return nil }
        let prompts = wire.questions.map { prompt in
            PendingQuestionPrompt(
                id: prompt.id, header: prompt.header, text: prompt.text,
                options: prompt.options.map { PendingQuestionOption(label: $0.label, description: $0.description) },
                multiSelect: prompt.multiSelect, allowOther: prompt.allowOther, secret: prompt.secret
            )
        }
        guard wire.questions.allSatisfy({ $0.options.count <= 10 }), Set(prompts.map(\.id)).count == prompts.count else { return nil }
        if kind == .approval {
            guard prompts.count == 1, prompts[0].id == "approval", prompts[0].options.count == 2, !prompts[0].secret else { return nil }
        }
        key = AgentQuestionKey(taskID: taskID, requestID: wire.providerRequestID)
        self.kind = kind
        structured = wire.structured
        self.prompts = prompts
        askedAt = wire.askedAt
    }

    /// 서버 JSON의 모양 (`pending_question`). 앞의 init가 검증한다
    struct Wire: Decodable {
        struct Prompt: Decodable {
            struct Option: Decodable {
                let label: String
                let description: String
            }

            let id: String
            let header: String
            let text: String
            let options: [Option]
            let multiSelect: Bool
            let allowOther: Bool
            let secret: Bool

            enum CodingKeys: String, CodingKey {
                case id, header, text, options, secret
                case multiSelect = "multi_select"
                case allowOther = "allow_other"
            }
        }

        let questionKey: [String]
        let providerRequestID: String
        let kind: String
        let structured: Bool
        let questions: [Prompt]
        let askedAt: Date?

        enum CodingKeys: String, CodingKey {
            case kind, structured, questions
            case questionKey = "question_key"
            case providerRequestID = "provider_request_id"
            case askedAt = "asked_at"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            questionKey = try c.decode([String].self, forKey: .questionKey)
            providerRequestID = try c.decode(String.self, forKey: .providerRequestID)
            kind = try c.decode(String.self, forKey: .kind)
            structured = try c.decode(Bool.self, forKey: .structured)
            questions = try c.decode([Prompt].self, forKey: .questions)
            // 시각을 못 읽어도 질문은 읽는다
            askedAt = try? c.decodeIfPresent(Date.self, forKey: .askedAt)
        }
    }
}

/// `agent_tasks` 행 (질문 읽기가 쓰는 다섯 열). 질문이 없거나 모양이 깨졌으면 `question`이 nil이다 — 한 행의 깨진 질문이 다른 세션의 읽기를 막지 않는다
public struct AgentQuestionRecord: Decodable, Sendable, Equatable {
    public let taskID: UUID
    public let sessionID: UUID
    public let turnSeq: Int?
    public let state: AgentTaskState
    public let question: AgentPendingQuestion?
    /// `pending_question`이 있는데 서버 검증 모양으로 읽히지 않았다 (카드를 그리지 않는다)
    public let isMalformed: Bool

    public static let columns = "id, agent_session_id, turn_seq, state, pending_question"

    enum CodingKeys: String, CodingKey {
        case id, state
        case sessionID = "agent_session_id"
        case turnSeq = "turn_seq"
        case pendingQuestion = "pending_question"
    }

    public init(taskID: UUID, sessionID: UUID, turnSeq: Int? = 1, state: AgentTaskState = .awaitingAnswer, question: AgentPendingQuestion?, isMalformed: Bool = false) {
        self.taskID = taskID
        self.sessionID = sessionID
        self.turnSeq = turnSeq
        self.state = state
        self.question = question
        self.isMalformed = isMalformed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taskID = try c.decode(UUID.self, forKey: .id)
        sessionID = try c.decode(UUID.self, forKey: .sessionID)
        turnSeq = try c.decodeIfPresent(Int.self, forKey: .turnSeq)
        state = AgentTaskState(raw: try c.decode(String.self, forKey: .state))
        if try !c.contains(.pendingQuestion) || c.decodeNil(forKey: .pendingQuestion) {
            question = nil
            isMalformed = false
        } else if let wire = try? c.decode(AgentPendingQuestion.Wire.self, forKey: .pendingQuestion), let parsed = AgentPendingQuestion(wire: wire, taskID: taskID) {
            question = parsed
            isMalformed = false
        } else {
            question = nil
            isMalformed = true
        }
    }
}
