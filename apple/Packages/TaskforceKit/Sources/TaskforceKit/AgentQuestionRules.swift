import CryptoKit
import Foundation

// OA D4b-m-1 (계약 5장 · D4bm-10–17): 열린 질문 → 질문 카드. 화면 없는 순수 함수다: 서버 값을 모양으로 옮길 뿐이고 앱이 글을 만들거나 고치지 않는다.
// 종류는 위에서부터 먼저 맞는 줄: 승인 → 비밀값(이 Mac / 다른 기기) → 다중 → Other(선택지 있음) → 글만(선택지 0) → 단일. 메타 줄은 "왜 · 어디서"뿐이다 ("Needs your answer"를 쓰지 않는다, DS 2026-10-16).
// 화면 번호(Keycap)는 줄이 정확히 넷일 때만 그리고, 키 1–4는 그려진 것과 상관없이 앞 넷 줄에 동작한다.

/// 카드가 그려질 때 필요한 화면 밖 사실
public struct AgentQuestionContext: Equatable, Sendable {
    /// 에이전트 이름 (승인 카드의 메타): "Claude Code"
    public var agentName: String
    /// 그 세션 연결의 bridge가 이 Mac이다 (D4bm-40). 모르면 false — 다른 기기로 본다
    public var isThisMac: Bool
    /// 그 Mac의 이름 (`bridges.device_name`, 모르면 nil: 화면이 대체 문구를 쓴다)
    public var macName: String?

    public init(agentName: String, isThisMac: Bool, macName: String? = nil) {
        self.agentName = agentName
        self.isThisMac = isThisMac
        self.macName = macName
    }
}

public struct AgentQuestionPosition: Equatable, Sendable {
    public let current: Int
    public let total: Int

    public init(current: Int, total: Int) {
        self.current = current
        self.total = total
    }
}

/// 한 단계(질문 하나)의 카드
public struct AgentQuestionCard: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// 선택지 중 하나
        case single
        /// 체크 상자: 하나라도 체크한 뒤 Return · Send
        case multi
        /// 선택지 + 마지막 줄 Other (누르면 입력 칸이 그 자리에서 열린다)
        case other
        /// 선택지 없는 질문: 입력 칸 하나
        case text
        /// Allow · Deny
        case approval
        /// 비밀값, 이 Mac: 자물쇠 + 마스크 칸
        case secret
        /// 비밀값, 다른 기기: 자물쇠 + "Answer on <Mac>", 입력 없음
        case secretRemote
    }

    public struct Row: Equatable, Sendable {
        public let label: String
        /// 서버 설명 (화면에는 그리지 않고 도움말 · 접근성 힌트로만)
        public let hint: String?
        public let isOther: Bool

        public init(label: String, hint: String? = nil, isOther: Bool = false) {
            self.label = label
            self.hint = hint
            self.isOther = isOther
        }
    }

    public let promptID: String
    public let kind: Kind
    /// 질문 줄: 입력 질문은 `text`, 승인은 `header`(받은 글 그대로)
    public let title: String
    public let meta: String?
    public let position: AgentQuestionPosition?
    public let rows: [Row]
    /// 승인 카드의 한 줄 미리보기 (`text`의 첫 줄)
    public let preview: String?
    public let macName: String?

    public init(
        promptID: String, kind: Kind, title: String, meta: String? = nil, position: AgentQuestionPosition? = nil, rows: [Row] = [], preview: String? = nil, macName: String? = nil
    ) {
        self.promptID = promptID
        self.kind = kind
        self.title = title
        self.meta = meta
        self.position = position
        self.rows = rows
        self.preview = preview
        self.macName = macName
    }

    /// 번호(Keycap)가 보이는가: 고르는 카드가 정확히 네 줄일 때
    public var showsKeycaps: Bool {
        (kind == .single || kind == .other) && rows.count == 4
    }

    /// 숫자 키 1–4가 닿는 줄 (앞 넷). 체크 상자 · 입력 카드는 없다
    public var keyedRows: [Int] {
        switch kind {
        case .single, .other, .approval: Array(0..<min(4, rows.count))
        case .multi, .text, .secret, .secretRemote: []
        }
    }

    /// 입력 칸이 있는 카드 (글만 · 비밀값). Other는 줄을 눌러야 열린다
    public var hasOwnField: Bool { kind == .text || kind == .secret }

    /// 접근성 이름
    public var accessibilityName: String { title }
}

/// 사용자가 한 일
public enum AgentQuestionPick: Equatable, Sendable {
    /// 줄 하나를 골랐다 (단일 · 승인 · Other의 선택지 · Other 줄)
    case row(Int)
    /// 체크한 줄들 (다중)
    case rows(Set<Int>)
    /// 입력한 글 (Other · 글만)
    case text(String)
    /// 비밀값
    case secret(SecretBox)
}

/// 한 단계의 답: 보낼 값과 "Answer sent" 아래에 보일 글 (비밀값은 보이지 않는다)
public struct AgentQuestionAnswer: Equatable, Sendable {
    public let value: LocalSecretAnswer.Value
    public let display: String?

    public init(value: LocalSecretAnswer.Value, display: String?) {
        self.value = value
        self.display = display
    }
}

public enum AgentQuestionRules {
    /// 입력 글의 상한 (유니코드 스칼라, 서버 `answerAgentQuestionRequestSchema`가 2000자)
    public static let maxTextScalars = 2_000
    /// 선택지 줄 끝의 Other (DS 문구)
    public static let otherLabel = AgentQuestionCopy.otherField

    /// `provider_request_id`의 UTF-8 SHA-256 소문자 16진 64자: 서버가 답 사건 줄의 열쇠(`answer:<task>:<digest>`)와 비밀값 답 route(`request_digest`)에 쓰는 값
    public static func requestDigest(_ requestID: String) -> String {
        SHA256.hash(data: Data(requestID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 서버 상한에 맞춘 입력 글 (그 뒤 입력은 받지 않는다)
    public static func clamped(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard scalars.count > maxTextScalars else { return text }
        var result = String.UnicodeScalarView()
        result.append(contentsOf: scalars.prefix(maxTextScalars))
        return String(result)
    }

    /// 비밀값이 하나라도 섞이면 모든 답을 이 Mac에 둔다 (D4bm-43)
    public static func deliversLocally(_ question: AgentPendingQuestion) -> Bool { question.hasSecret }

    // MARK: 카드

    /// 단계마다 카드 하나. 다른 기기에서 본 비밀값 요청은 어떤 질문도 여기서 답할 수 없으니 읽기 전용 카드 하나다
    public static func cards(for question: AgentPendingQuestion, context: AgentQuestionContext) -> [AgentQuestionCard] {
        if question.kind == .input, question.hasSecret, !context.isThisMac {
            let prompt = question.prompts.first(where: \.secret) ?? question.prompts[0]
            return [AgentQuestionCard(
                promptID: prompt.id, kind: .secretRemote, title: prompt.text, meta: meta(position: nil, header: prompt.header, tail: AgentQuestionCopy.cantBeEnteredHere),
                position: nil, rows: [], preview: nil, macName: context.macName
            )]
        }
        let total = question.prompts.count
        return question.prompts.enumerated().map { index, prompt in
            card(for: prompt, of: question, position: total > 1 ? AgentQuestionPosition(current: index + 1, total: total) : nil, context: context)
        }
    }

    private static func card(for prompt: PendingQuestionPrompt, of question: AgentPendingQuestion, position: AgentQuestionPosition?, context: AgentQuestionContext) -> AgentQuestionCard {
        func rows(_ options: [PendingQuestionOption]) -> [AgentQuestionCard.Row] {
            options.map { AgentQuestionCard.Row(label: $0.label, hint: $0.description.isEmpty ? nil : $0.description, isOther: false) }
        }
        if question.kind == .approval {
            let lines = prompt.text.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            let reason = lines.count > 1 && !lines[1].isEmpty ? lines[1] : nil
            return AgentQuestionCard(
                promptID: prompt.id, kind: .approval, title: prompt.header, meta: [context.agentName.isEmpty ? nil : context.agentName, reason].compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
                position: nil, rows: rows(prompt.options), preview: lines.first.flatMap { $0.isEmpty ? nil : $0 }, macName: nil
            )
        }
        if prompt.secret {
            return AgentQuestionCard(
                promptID: prompt.id, kind: .secret, title: prompt.text, meta: meta(position: position, header: prompt.header, tail: AgentQuestionCopy.staysOnThisMac),
                position: position, rows: [], preview: nil, macName: nil
            )
        }
        let plainMeta = meta(position: position, header: prompt.header, tail: nil)
        if prompt.multiSelect {
            return AgentQuestionCard(promptID: prompt.id, kind: .multi, title: prompt.text, meta: plainMeta, position: position, rows: rows(prompt.options), preview: nil, macName: nil)
        }
        if prompt.options.isEmpty {
            return AgentQuestionCard(promptID: prompt.id, kind: .text, title: prompt.text, meta: plainMeta, position: position, rows: [], preview: nil, macName: nil)
        }
        if prompt.allowOther {
            let withOther = rows(prompt.options) + [AgentQuestionCard.Row(label: otherLabel, hint: nil, isOther: true)]
            return AgentQuestionCard(promptID: prompt.id, kind: .other, title: prompt.text, meta: plainMeta, position: position, rows: withOther, preview: nil, macName: nil)
        }
        return AgentQuestionCard(promptID: prompt.id, kind: .single, title: prompt.text, meta: plainMeta, position: position, rows: rows(prompt.options), preview: nil, macName: nil)
    }

    /// "n of m · header · tail": 비어 있는 조각은 건너뛴다 (header가 비면 줄이 없다)
    private static func meta(position: AgentQuestionPosition?, header: String, tail: String?) -> String? {
        [position.map { "\($0.current) of \($0.total)" }, header.isEmpty ? nil : header, tail].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
    }

    /// 질문이 열려 있는 동안 보낸 글이 대기열에 들어간 수 (전달 `queued` + 이유 `question_open`). 이 수가 늘면 포커스가 카드로 간다 (D4bm-31, DS: "Otherwise it queues and focus moves to the card")
    public static func queuedBehindQuestion(_ turns: [ChatTurn]) -> Int {
        turns.filter { $0.isUser && $0.delivery?.state == .queued && $0.delivery?.reason == .questionOpen }.count
    }

    // MARK: 답

    /// 사용자가 한 일 → 이 단계의 답. 보낼 수 없는 일이면 nil (없는 줄 · 빈 글 · 그 카드에 없는 입력 · 읽기 전용 카드)
    public static func answer(for card: AgentQuestionCard, pick: AgentQuestionPick) -> AgentQuestionAnswer? {
        switch (card.kind, pick) {
        case (.single, .row(let index)), (.other, .row(let index)):
            guard card.rows.indices.contains(index), !card.rows[index].isOther else { return nil }
            let label = card.rows[index].label
            return AgentQuestionAnswer(value: .plain(.text(label)), display: label)
        case (.approval, .row(let index)):
            // 서버는 allow · deny만 받는다: 줄 순서가 뜻이다 (첫 줄 Allow · 둘째 줄 Deny, DS `index.d.ts`)
            guard card.rows.indices.contains(index), index < 2 else { return nil }
            return AgentQuestionAnswer(value: .plain(.text(index == 0 ? "allow" : "deny")), display: card.rows[index].label)
        case (.other, .text(let text)), (.text, .text(let text)):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let clamped = clamped(text)
            return AgentQuestionAnswer(value: .plain(.text(clamped)), display: clamped)
        case (.multi, .rows(let indexes)):
            guard (1...10).contains(indexes.count), indexes.allSatisfy(card.rows.indices.contains) else { return nil }
            let labels = indexes.sorted().map { card.rows[$0].label }
            return AgentQuestionAnswer(value: .plain(.choices(labels)), display: labels.joined(separator: ", "))
        case (.secret, .secret(let box)):
            guard !box.isEmpty else { return nil }
            return AgentQuestionAnswer(value: .secret(box), display: nil)
        default:
            return nil
        }
    }

    /// 모든 단계의 답을 한 요청으로 (D4bm-16): 질문 id마다 하나, 빠지거나 모르는 id가 있으면 요청이 없다
    public static func request(for question: AgentPendingQuestion, collected: [String: ConversationAnswerValue]) -> AgentAnswerRequest? {
        guard Set(collected.keys) == Set(question.prompts.map(\.id)) else { return nil }
        return AgentAnswerRequest(providerRequestID: question.key.requestID, answers: collected)
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
