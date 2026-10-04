import Foundation

// 실행 (U2, docs/EXECUTION.md) 모델. `src/lib/api/contract.ts` "실행" 묶음(runSummarySchema · stepSummarySchema · artifactSchema ·
// creditsResponseSchema)과 같은 이름 · 모양이다. 쓰기(run 만들기 · 멈추기)는 `APIClient`, run · 단계 · 초안 읽기는 `TaskforceReads`(RLS).
// 서버가 새 값을 더해도 앱이 깨지지 않게 모르는 상태 · 이유 · 결과는 `.unknown`으로 받는다.
// 요청 · 초안 본문 · 질문은 사용자 글이다: 메모리에만 두고 로그 · 디스크(저장본 · 캐시)에 남기지 않는다.

/// run 상태 (`execution_runs.state`). 끝 상태는 done · failed · stopped
public enum RunState: String, Sendable, Hashable, CaseIterable {
    case queued
    case running
    case waitingApproval = "waiting_approval"
    case done
    case failed
    case stopped
    /// 이 앱이 모르는 상태 (끝났다고도, 진행 중이라고도 보지 않는다)
    case unknown

    init(raw: String) { self = RunState(rawValue: raw) ?? .unknown }

    /// 끝나지 않은 상태 (멈출 수 있고, 폴링한다)
    public var isOpen: Bool { self == .queued || self == .running || self == .waitingApproval }
    public var isFinished: Bool { self == .done || self == .failed || self == .stopped }
}

/// 실행기가 막힌 이유 (`execution_runs.hold_reason`): 차단 스위치 · 도구 / 실행 주체 / 보내는 연결 없음 / 크레딧 부족
public enum RunHoldReason: String, Sendable, Hashable, CaseIterable {
    case blocked
    case actor
    case needsConnection = "needs_connection"
    case credit
    case unknown

    init(raw: String) { self = RunHoldReason(rawValue: raw) ?? .unknown }
}

/// 끝낸 결과 (`execution_runs.outcome`)
public enum RunOutcome: String, Sendable, Hashable, CaseIterable {
    case draftReady = "draft_ready"
    case needsConnection = "needs_connection"
    case needsInput = "needs_input"
    case unknown

    init(raw: String) { self = RunOutcome(rawValue: raw) ?? .unknown }
}

/// contract.ts `runSummarySchema` (`execution_runs` 행)
public struct RunSummary: Decodable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let actionID: UUID
    /// 지금은 "draft"뿐
    public let goal: String
    public let state: RunState
    public let holdReason: RunHoldReason?
    public let outcome: RunOutcome?
    public let budgetCredits: Int?
    public let createdAt: Date
    /// 멈춘 시각 (서버 U2 Mac PR1의 `stopped_at`). 그 전 서버 · 멈추지 않은 run은 nil
    public let stoppedAt: Date?

    /// RLS로 읽을 열. `stopped_at`이 없는 DB(마이그레이션 전)에서는 `columnsWithoutStop`으로 다시 읽는다 (`TaskforceReads`)
    public static let columns = columnsWithoutStop + ", stopped_at"
    static let columnsWithoutStop = "id, action_id, goal, state, hold_reason, outcome, budget_credits, created_at"

    enum CodingKeys: String, CodingKey {
        case id, goal, state, outcome
        case actionID = "action_id"
        case holdReason = "hold_reason"
        case budgetCredits = "budget_credits"
        case createdAt = "created_at"
        case stoppedAt = "stopped_at"
    }

    public init(
        id: UUID, actionID: UUID, goal: String = "draft", state: RunState, holdReason: RunHoldReason? = nil, outcome: RunOutcome? = nil,
        budgetCredits: Int? = nil, createdAt: Date, stoppedAt: Date? = nil
    ) {
        self.id = id
        self.actionID = actionID
        self.goal = goal
        self.state = state
        self.holdReason = holdReason
        self.outcome = outcome
        self.budgetCredits = budgetCredits
        self.createdAt = createdAt
        self.stoppedAt = stoppedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        actionID = try c.decode(UUID.self, forKey: .actionID)
        goal = try c.decode(String.self, forKey: .goal)
        state = RunState(raw: try c.decode(String.self, forKey: .state))
        holdReason = try c.decodeIfPresent(String.self, forKey: .holdReason).map(RunHoldReason.init(raw:))
        outcome = try c.decodeIfPresent(String.self, forKey: .outcome).map(RunOutcome.init(raw:))
        budgetCredits = try c.decodeIfPresent(Int.self, forKey: .budgetCredits)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        // 새 필드: 없거나(그 전 서버) 모양이 어긋나도 run은 읽는다
        stoppedAt = (try? c.decodeIfPresent(Date.self, forKey: .stoppedAt)) ?? nil
    }

    public var isOpen: Bool { state.isOpen }
}

/// 단계 종류 (`execution_steps.kind`)
public enum StepKind: String, Sendable, Hashable {
    case plan, draft, external, unknown

    init(raw: String) { self = StepKind(rawValue: raw) ?? .unknown }
}

/// 단계 상태 (`execution_steps.state`)
public enum StepState: String, Sendable, Hashable {
    case pending, prepared, calling, called
    case unknownOutcome = "unknown_outcome"
    case failed, skipped
    case unknown

    init(raw: String) { self = StepState(rawValue: raw) ?? .unknown }
}

/// 계획 단계의 다음 단계 (`receipt.decision`)
public enum StepDecision: String, Sendable, Hashable {
    case draft
    case needsConnection = "needs_connection"
    case askUser = "ask_user"
    case done
    case unknown

    init(raw: String) { self = StepDecision(rawValue: raw) ?? .unknown }
}

/// contract.ts `stepReceiptSchema` (`execution_steps.receipt`). 모르는 키는 무시하고, 모양이 어긋난 값은 없는 것으로 본다.
/// `question` · `to`는 90일 뒤(또는 run이 끝나는 대로) 서버가 키째 지운다 (docs/EXECUTION.md 12장 실행의 글).
public struct StepReceipt: Decodable, Sendable, Hashable {
    public let decision: StepDecision?
    public let capability: String?
    public let question: String?
    public let to: [String]?
    public let model: String?
    public let promptVersion: String?
    /// 실패 까닭: consent · rejected · action_missing · retries_exhausted · unavailable …
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case decision, capability, question, to, model, error
        case promptVersion = "prompt_version"
    }

    public init(
        decision: StepDecision? = nil, capability: String? = nil, question: String? = nil, to: [String]? = nil, model: String? = nil,
        promptVersion: String? = nil, error: String? = nil
    ) {
        self.decision = decision
        self.capability = capability
        self.question = question
        self.to = to
        self.model = model
        self.promptVersion = promptVersion
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // try?는 Optional을 한 겹으로 편다 (SE-0230): 없음 · null · 모양이 어긋남 모두 nil
        let decision: String? = try? c.decodeIfPresent(String.self, forKey: .decision)
        self.decision = decision.map(StepDecision.init(raw:))
        capability = try? c.decodeIfPresent(String.self, forKey: .capability)
        question = try? c.decodeIfPresent(String.self, forKey: .question)
        to = try? c.decodeIfPresent([String].self, forKey: .to)
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        promptVersion = try? c.decodeIfPresent(String.self, forKey: .promptVersion)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
    }
}

/// contract.ts `stepSummarySchema` (`execution_steps` 행)
public struct StepSummary: Decodable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let runID: UUID
    public let seq: Int
    public let kind: StepKind
    public let state: StepState
    public let attempt: Int
    public let receipt: StepReceipt?
    public let createdAt: Date

    public static let columns = "id, run_id, seq, kind, state, attempt, receipt, created_at"

    enum CodingKeys: String, CodingKey {
        case id, seq, kind, state, attempt, receipt
        case runID = "run_id"
        case createdAt = "created_at"
    }

    public init(
        id: UUID, runID: UUID, seq: Int, kind: StepKind, state: StepState, attempt: Int = 0, receipt: StepReceipt? = nil, createdAt: Date
    ) {
        self.id = id
        self.runID = runID
        self.seq = seq
        self.kind = kind
        self.state = state
        self.attempt = attempt
        self.receipt = receipt
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        runID = try c.decode(UUID.self, forKey: .runID)
        seq = try c.decode(Int.self, forKey: .seq)
        kind = StepKind(raw: try c.decode(String.self, forKey: .kind))
        state = StepState(raw: try c.decode(String.self, forKey: .state))
        attempt = try c.decode(Int.self, forKey: .attempt)
        // receipt 모양이 어긋나도 단계는 읽는다
        receipt = (try? c.decodeIfPresent(StepReceipt.self, forKey: .receipt)) ?? nil
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }
}

/// contract.ts `artifactSchema` (`execution_artifacts` 행): 초안. 보관 기간(`retain_until`)이 지나면 서버가 본문만 비운다(`body = ''`, `body_purged_at`)
public struct Artifact: Decodable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let runID: UUID
    public let stepID: UUID
    public let actionID: UUID
    /// 지금은 "draft"뿐
    public let kind: String
    public let title: String
    /// 사용자 글: 메모리에만 둔다
    public let body: String
    public let model: String
    public let promptVersion: String
    public let retainUntil: Date
    public let bodyPurgedAt: Date?
    public let createdAt: Date

    public static let columns = "id, run_id, step_id, action_id, kind, title, body, model, prompt_version, retain_until, body_purged_at, created_at"

    enum CodingKeys: String, CodingKey {
        case id, kind, title, body, model
        case runID = "run_id"
        case stepID = "step_id"
        case actionID = "action_id"
        case promptVersion = "prompt_version"
        case retainUntil = "retain_until"
        case bodyPurgedAt = "body_purged_at"
        case createdAt = "created_at"
    }

    public init(
        id: UUID, runID: UUID, stepID: UUID, actionID: UUID, kind: String = "draft", title: String, body: String, model: String = "",
        promptVersion: String = "", retainUntil: Date, bodyPurgedAt: Date? = nil, createdAt: Date
    ) {
        self.id = id
        self.runID = runID
        self.stepID = stepID
        self.actionID = actionID
        self.kind = kind
        self.title = title
        self.body = body
        self.model = model
        self.promptVersion = promptVersion
        self.retainUntil = retainUntil
        self.bodyPurgedAt = bodyPurgedAt
        self.createdAt = createdAt
    }

    /// 보관 기간이 지나 본문을 지웠다 (제목 · 시각은 남는다)
    public var isPurged: Bool { bodyPurgedAt != nil }
}

/// contract.ts `creditsResponseSchema` (GET /api/v1/credits). 앞 세 필드는 처음부터 있고,
/// 나머지는 서버 U2 Mac PR1(S3 표시 필드)이 더한다: 없으면 기본값이라 그 전 서버도 읽는다.
public struct CreditsSummary: Decodable, Sendable, Hashable {
    /// 정산 보류 (원가 미확정, A46): 초안 단계를 끝냈는데 원가를 몰라 정산하지 않고 둔 예약
    public struct Settling: Decodable, Sendable, Hashable {
        public let steps: Int
        public let reserved: Int
        public let actionIDs: [UUID]

        public static let none = Settling(steps: 0, reserved: 0, actionIDs: [])

        enum CodingKeys: String, CodingKey {
            case steps, reserved
            case actionIDs = "action_ids"
        }

        public init(steps: Int, reserved: Int, actionIDs: [UUID]) {
            self.steps = steps
            self.reserved = reserved
            self.actionIDs = actionIDs
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            steps = max(0, (try? c.decodeIfPresent(Int.self, forKey: .steps)) ?? 0)
            reserved = max(0, (try? c.decodeIfPresent(Int.self, forKey: .reserved)) ?? 0)
            let ids: [String] = (try? c.decodeIfPresent([String].self, forKey: .actionIDs)) ?? []
            actionIDs = ids.compactMap(UUID.init(uuidString:))
        }
    }

    /// 기간 사용량: `since` 뒤 정산(settle) 합계
    public struct Used: Decodable, Sendable, Hashable {
        public let credits: Int
        public let since: Date

        enum CodingKeys: String, CodingKey {
            case credits, since
        }

        public init(credits: Int, since: Date) {
            self.credits = credits
            self.since = since
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            credits = max(0, try c.decode(Int.self, forKey: .credits))
            since = try c.decode(Date.self, forKey: .since)
        }
    }

    public let available: Int
    public let reserved: Int
    public let rateVersion: String?
    /// 끝내지 않은 단계에 열린 예약이 있는 run 수 ("Held for 1 running task…"). 없으면 0
    public let runningRuns: Int
    /// 없으면 `.none`
    public let settling: Settling
    /// 없으면 nil (화면은 값 대신 "—")
    public let used: Used?
    /// 전체 스위치가 열림: false면 `POST /runs`가 404라 `Run with AI…`를 미리 끈다. 없으면(그 전 서버) true
    public let acceptingRuns: Bool
    /// 초안 한 건의 예약 (서버 `DRAFT_ESTIMATE_CREDITS`). 없으면 nil (앱이 값을 짐작하지 않는다)
    public let draftEstimateCredits: Int?

    enum CodingKeys: String, CodingKey {
        case available, reserved, settling, used
        case rateVersion = "rate_version"
        case runningRuns = "running_runs"
        case acceptingRuns = "accepting_runs"
        case draftEstimateCredits = "draft_estimate_credits"
    }

    public init(
        available: Int, reserved: Int, rateVersion: String? = nil, runningRuns: Int = 0, settling: Settling = .none, used: Used? = nil,
        acceptingRuns: Bool = true, draftEstimateCredits: Int? = nil
    ) {
        self.available = available
        self.reserved = reserved
        self.rateVersion = rateVersion
        self.runningRuns = runningRuns
        self.settling = settling
        self.used = used
        self.acceptingRuns = acceptingRuns
        self.draftEstimateCredits = draftEstimateCredits
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 합계와 원장이 잠깐 어긋날 수 있어 음수는 0으로 (서버 PR1)
        available = max(0, try c.decode(Int.self, forKey: .available))
        reserved = max(0, try c.decode(Int.self, forKey: .reserved))
        rateVersion = try c.decodeIfPresent(String.self, forKey: .rateVersion)
        // 새 필드는 모양이 어긋나도 합계는 읽는다
        runningRuns = max(0, (try? c.decodeIfPresent(Int.self, forKey: .runningRuns)) ?? 0)
        settling = (try? c.decodeIfPresent(Settling.self, forKey: .settling)) ?? .none
        used = (try? c.decodeIfPresent(Used.self, forKey: .used)) ?? nil
        acceptingRuns = (try? c.decodeIfPresent(Bool.self, forKey: .acceptingRuns)) ?? true
        draftEstimateCredits = (try? c.decodeIfPresent(Int.self, forKey: .draftEstimateCredits)) ?? nil
    }

    /// S3 Reserved: 진행 중 run의 예약 (정산 보류는 Pending으로 따로 보인다)
    public var heldForRunning: Int { max(0, reserved - settling.reserved) }

    /// S3 Pending: 원가를 확인하는 중인 예약이 있다
    public var hasPending: Bool { settling.steps > 0 || settling.reserved > 0 }

    /// 잔액이 초안 한 건의 예약보다 적다 (M8 Cost 부제). 예약 값을 모르면 false
    public var isBelowDraftEstimate: Bool {
        guard let estimate = draftEstimateCredits else { return false }
        return available < estimate
    }
}

/// POST /api/v1/runs 본문 (contract.ts `createRunRequestSchema`). 예산(`budget_credits`)은 보내지 않는다: 잔액만 본다
public struct CreateRunRequest: Encodable, Sendable, Equatable {
    public let actionID: UUID
    public let goal: String
    /// 사용자가 맡긴 일 (1–2000자, 앞뒤 공백 없이). 사용자 글: 메모리에만
    public let request: String

    /// contract.ts `request` 최대 길이
    public static let maxRequestLength = 2000

    enum CodingKeys: String, CodingKey {
        case goal, request
        case actionID = "action_id"
    }

    /// 앞뒤 공백을 빼고(서버 zod `.trim()`처럼 U+FEFF도) 2000으로 자른다. 길이는 서버(zod)와 같이 UTF-16 단위로 세고 글자 중간에서 자르지 않는다
    public init(actionID: UUID, request: String) {
        self.actionID = actionID
        goal = "draft"
        self.request = Self.capped(request.trimmingCharacters(in: Self.trimmed))
    }

    /// JS `String.prototype.trim`이 빼는 문자 (Swift 공백 · 줄바꿈 + U+FEFF)
    static let trimmed = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))

    static func capped(_ text: String) -> String {
        var units = 0
        var result = ""
        for character in text {
            units += character.utf16.count
            guard units <= maxRequestLength else { break }
            result.append(character)
        }
        return result
    }

    /// 빈 요청 (보내지 않는다: 서버는 400)
    public var isEmpty: Bool { request.isEmpty }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(actionID.lowercased, forKey: .actionID)
        try c.encode(goal, forKey: .goal)
        try c.encode(request, forKey: .request)
    }
}

/// POST /api/v1/runs · POST /api/v1/runs/:id/stop 응답 `{ run }`
struct RunResponse: Decodable {
    let run: RunSummary
}

/// `Run with AI…` 시작이 실패했을 때 할 일 (`POST /runs`의 오류)
public enum RunStartFailure: Equatable, Sendable {
    /// 409: 외부 AI 처리 동의가 먼저 (기존 동의 화면)
    case consentNeeded
    /// 404: 실행을 쓸 수 없음 (플래그 · 실행 주체 · 전체 스위치) 또는 열린 할 일이 아님
    case unavailable
    /// 429: 10분에 10번을 넘음
    case rateLimited
    case other(APIError)

    public init(_ error: APIError) {
        switch error {
        case .server(_, .conflict, _): self = .consentNeeded
        case .server(_, .rateLimited, _): self = .rateLimited
        // 형식 없는 404(실행 route가 없는 옛 서버 · 앞단)도 쓸 수 없음
        case _ where error.status == 404: self = .unavailable
        default: self = .other(error)
        }
    }

    /// 화면 한 줄 (동의 필요는 동의 화면을 보이므로 nil). 문구는 후보 (U2 Mac 계획 PR2 · PR3)
    public var message: String? {
        switch self {
        case .consentNeeded: nil
        case .unavailable: "Run with AI isn't available right now."
        case .rateLimited: "Too many runs. Try again later."
        case .other(let error): error.userMessage
        }
    }
}
