import Foundation

// 복귀 요약 (C3 ReturnSummary)의 앱 쪽 모양. 서버 `contract.ts` C3 절의 `returnSummaryResponseSchema` · `returnSummaryClearResponseSchema`를 읽는다:
// 서버 C3 head `6cfd382`(`handoffs/c3-server-notes.md` "Mac에 넘기는 JSON 계약") + A–D 후속 계약 `handoffs/c3-ad-contract.md` C(`baseline: initialized` · `init_token` · baseline 확정).
// `ReturnSummaryContractFixtures`가 그 JSON을 고정한다.
// 규칙:
// - 구조(필수 키 · 타입)는 엄격하다: 틀리면 디코딩 실패 = "읽지 못함"이지 빈 상태가 아니다 (일부 실패는 줄 하나가 아니라 응답 전체).
// - 변화(`changes[]`)의 값은 **지우지 않는다**: 모르는 enum은 `.unknown`이고, 문자열이어야 하는 필드(`kind` · `detail`)가 숫자 · 객체 같은 다른 타입이면 nil이나 정상으로 바꾸지 않고
//   그 변화를 **해석 못 한 변화**(`isMalformed`)로 둔다: 줄은 남기고 `Some changes couldn't be shown`, Clear · 기준점 확정을 막는다 (fail closed). 정말 없는 값(null · 키 없음)만 "없음"이다.
//   그 밖의 응답 수준 enum(baseline · sources)도 `.unknown`이고 그런 응답은 완전하지 않은 것으로 읽는다 (`ReturnSummaryResponse.isComplete`).
//   "변화 없음"을 보이는 데는 서버 `empty`뿐 아니라 이 재검증도 필요하다 (`isEmpty`).
// - 커서는 불투명 글자다: 열지 않고 시각으로 바꾸지 않고 그대로 Clear에 돌려준다. 클라이언트 시각은 서버로 보내지 않는다.
// - 서버는 문구를 만들지 않는다. 문구는 `ReturnSummaryCopy`가 토큰에서 만든다. 숫자(개수)는 내려오지도, 앱이 세지도 않는다.

/// 응답 토큰 하나를 읽는 규칙: 문자열이 아니면 모르는 값이다
private func token(_ decoder: Decoder) -> String {
    (try? decoder.singleValueContainer().decode(String.self)) ?? ""
}

public enum ReturnSummaryBaseline: Sendable, Hashable, Decodable {
    /// 한 번 Clear했다 (`since`가 마지막 Clear의 지평)
    case cleared
    /// 기준점은 있고 Clear는 아직 없다 (첫 정상 표시를 서버가 확정한 뒤, `POST /api/v2/return-summary/baseline`). `since`는 null일 수 있다
    case initialized
    /// 한 번도 Clear하지 않았고 기준점도 없다 (`since == nil`). 서버가 `init_token`을 주면 첫 정상 표시 뒤 기준점을 확정할 수 있다
    case neverCleared
    /// 변화 원천을 읽지 못했다 (서버가 말한 `unknown`이거나 이 앱이 모르는 값)
    case unknown

    public init(from decoder: Decoder) throws {
        switch token(decoder) {
        case "cleared": self = .cleared
        case "initialized": self = .initialized
        case "never_cleared": self = .neverCleared
        default: self = .unknown
        }
    }
}

/// `sources.changes` · `sources.decisions`: 그 원천을 읽었나. `ok`만 완전하다
public enum ReturnSummarySourceStatus: Sendable, Hashable, Decodable {
    case ok
    case unavailable
    /// 작업이 한도를 넘어 앞부분만 읽었다
    case truncated
    case unknown

    public init(from decoder: Decoder) throws {
        switch token(decoder) {
        case "ok": self = .ok
        case "unavailable": self = .unavailable
        case "truncated": self = .truncated
        default: self = .unknown
        }
    }
}

public enum ReturnSummaryWorkStatus: Sendable, Hashable, Decodable {
    case open, done, dropped, unknown

    public init(from decoder: Decoder) throws {
        switch token(decoder) {
        case "open": self = .open
        case "done": self = .done
        case "dropped": self = .dropped
        default: self = .unknown
        }
    }
}

/// StatusMark: 할 일 · 진행 중 · 완료. 취소된 작업(서버 null)과 모르는 값은 표시가 없다
public enum ReturnSummaryProgress: Sendable, Hashable, Decodable {
    case toDo, inProgress, done, unknown

    public init(from decoder: Decoder) throws {
        switch token(decoder) {
        case "to_do": self = .toDo
        case "in_progress": self = .inProgress
        case "done": self = .done
        default: self = .unknown
        }
    }
}

/// 결정 대기 종류 (서버 `pendingDecisionKindSchema`). 지금 실제로 오는 것은 앞의 넷이다
public enum ReturnSummaryDecisionKind: Sendable, Hashable, Decodable {
    case approval, reviewFailed, runInput, confirm
    case agentQuestion, suggestion, blockedDependency
    case unknown

    public init(from decoder: Decoder) throws {
        switch token(decoder) {
        case "approval": self = .approval
        case "review_failed": self = .reviewFailed
        case "run_input": self = .runInput
        case "confirm": self = .confirm
        case "agent_question": self = .agentQuestion
        case "suggestion": self = .suggestion
        case "blocked_dependency": self = .blockedDependency
        default: self = .unknown
        }
    }
}

public enum ReturnSummaryChangeSource: Sendable, Hashable, Decodable {
    /// 원문 · AI · 실행기가 바꾼 작업 (사용자 자기 수정 · 본 변화는 서버가 이미 뺐다)
    case actionEvent
    /// 실행 결과 전이
    case run
    /// 안 읽은 assistant / event 메시지
    case message
    case unknown

    public init(from decoder: Decoder) throws {
        switch token(decoder) {
        case "action_event": self = .actionEvent
        case "run": self = .run
        case "message": self = .message
        default: self = .unknown
        }
    }
}

/// 변화의 원문 상태 토큰: 지운 원문 · 접근 상실 · 보관 만료는 글이나 옛 제목으로 되살리지 않고 이 토큰으로만 말한다
public enum ReturnSummarySourceState: Sendable, Hashable, Decodable {
    case available, deleted, accessLost, textExpired, unknown

    public init(from decoder: Decoder) throws {
        switch token(decoder) {
        case "available": self = .available
        case "deleted": self = .deleted
        case "access_lost": self = .accessLost
        case "text_expired": self = .textExpired
        default: self = .unknown
        }
    }
}

public enum ReturnSummaryNextKind: Sendable, Hashable, Decodable {
    /// 답할 결정이 있다
    case answer
    /// 끝난 결과를 볼 차례
    case reviewResult
    /// 그 작업을 열어 본다
    case open
    case unknown

    public init(from decoder: Decoder) throws {
        switch token(decoder) {
        case "answer": self = .answer
        case "review_result": self = .reviewResult
        case "open": self = .open
        default: self = .unknown
        }
    }
}

/// 줄의 결정 하나. `id` · `version`은 Review의 항목 `id` · `version`과 같은 값이다 (상세 연결 키, 옛 version으로 행동하지 않는다)
public struct ReturnSummaryDecision: Sendable, Hashable, Decodable {
    public let id: String
    public let kind: ReturnSummaryDecisionKind
    public let version: String
    public let urgent: Bool

    public init(id: String, kind: ReturnSummaryDecisionKind, version: String, urgent: Bool) {
        self.id = id
        self.kind = kind
        self.version = version
        self.urgent = urgent
    }
}

public struct ReturnSummaryChange: Sendable, Hashable, Decodable {
    public let source: ReturnSummaryChangeSource
    /// 코드 토큰 (`due_changed` · `done` · `assistant` …). 문구는 `ReturnSummaryCopy`가 만든다. 모르는 토큰은 문구가 없다
    public let kind: String
    /// 마이크로초 UTC 글자를 읽은 시각. **표시용이다**: 서버로 돌려주지 않는다
    public let at: Date
    /// run `done`이면 그 run의 outcome (`draft_ready` …), 그 밖에는 null이 계약이다. 숫자 · 객체 같은 다른 타입으로 오면 nil이 되지 않고 `isMalformed`다
    public let detail: String?
    /// action_event만 (`available` · `deleted` · …). 그 밖에는 null이 계약이다
    public let sourceState: ReturnSummarySourceState?
    /// 문자열이어야 하는 필드(`kind` · `detail`)가 문자열이 아닌 값으로 왔다: **지우지 않고** 해석 못 한 변화로 둔다 (nil이나 "정상"으로 바꾸지 않는다). 정말 없는 값(null · 키 없음)은 해당하지 않는다
    let isMalformed: Bool

    enum CodingKeys: String, CodingKey {
        case source, kind, at, detail
        case sourceState = "source_state"
    }

    public init(
        source: ReturnSummaryChangeSource, kind: String, at: Date, detail: String? = nil, sourceState: ReturnSummarySourceState? = nil, isMalformed: Bool = false
    ) {
        self.source = source
        self.kind = kind
        self.at = at
        self.detail = detail
        self.sourceState = sourceState
        self.isMalformed = isMalformed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(ReturnSummaryChangeSource.self, forKey: .source)
        at = try c.decode(Date.self, forKey: .at)
        var malformed = false
        if let text = try? c.decode(String.self, forKey: .kind) {
            kind = text
        } else {
            kind = ""
            malformed = true
        }
        // detail: 정말 없는 값(키 없음 · null)만 "없음"이다. 문자열이면 그 토큰, 그 밖의 타입은 지우지 않는다 (해석 못 한 변화)
        if !c.contains(.detail) || ((try? c.decodeNil(forKey: .detail)) ?? false) {
            detail = nil
        } else if let text = try? c.decode(String.self, forKey: .detail) {
            detail = text
        } else {
            detail = nil
            malformed = true
        }
        // source_state: 문자열이 아닌 값은 `.unknown`이 된다 (enum 디코더가 지우지 않는다). 없음 · null은 nil
        sourceState = try c.decodeIfPresent(ReturnSummarySourceState.self, forKey: .sourceState)
        isMalformed = malformed
    }

    /// 앱이 말로 옮길 수 있는 변화인가. **아니면 해석 못 한 변화다** (모르는 source · kind · detail · source_state · 타입이 틀린 값 — enum뿐 아니라 자유 문자열도):
    /// 표시는 남기고 Clear · 기준점 확정을 막는다 (`ReturnSummaryCopy.change`가 nil을 주는 경우)
    public var isInterpretable: Bool { ReturnSummaryCopy.change(self) != nil }
}

public struct ReturnSummaryNext: Sendable, Hashable, Decodable {
    public let kind: ReturnSummaryNextKind
    public let decisionKinds: [ReturnSummaryDecisionKind]

    enum CodingKeys: String, CodingKey {
        case kind
        case decisionKinds = "decision_kinds"
    }

    public init(kind: ReturnSummaryNextKind, decisionKinds: [ReturnSummaryDecisionKind] = []) {
        self.kind = kind
        self.decisionKinds = decisionKinds
    }
}

/// 한 줄 = 작업 하나. `actionID`가 안정 id다
public struct ReturnSummaryItem: Sendable, Hashable, Decodable, Identifiable {
    public let actionID: UUID
    /// 지금 제목 (옛 제목 · 원문 글 · 변경 전후 값은 서버가 내려주지 않는다)
    public let title: String
    public let status: ReturnSummaryWorkStatus
    /// nil = 취소된 작업(StatusMark 없음)
    public let state: ReturnSummaryProgress?
    public let needsAnswer: Bool
    public let urgent: Bool
    public let decisions: [ReturnSummaryDecision]
    public let changes: [ReturnSummaryChange]
    public let next: ReturnSummaryNext
    /// 줄의 변화 · 결정이 바뀌면 달라지는 글자
    public let version: String

    public var id: UUID { actionID }

    enum CodingKeys: String, CodingKey {
        case title, status, state, urgent, decisions, changes, next, version
        case actionID = "action_id"
        case needsAnswer = "needs_answer"
    }

    public init(
        actionID: UUID, title: String, status: ReturnSummaryWorkStatus = .open, state: ReturnSummaryProgress? = .inProgress,
        needsAnswer: Bool = false, urgent: Bool = false, decisions: [ReturnSummaryDecision] = [], changes: [ReturnSummaryChange] = [],
        next: ReturnSummaryNext = ReturnSummaryNext(kind: .open), version: String = "v"
    ) {
        self.actionID = actionID
        self.title = title
        self.status = status
        self.state = state
        self.needsAnswer = needsAnswer
        self.urgent = urgent
        self.decisions = decisions
        self.changes = changes
        self.next = next
        self.version = version
    }

    /// 이 줄에 앱이 말로 옮기지 못하는 변화가 있다. (줄의 표시용 값 — status · state · next · 결정 종류 — 을 몰라도 변화의 해석과는 상관없다: 마크 · 라우팅만 비어 있다)
    var hasUninterpretableChange: Bool { changes.contains { !$0.isInterpretable } }
}

/// `GET /api/v2/return-summary` 200
public struct ReturnSummaryResponse: Sendable, Hashable, Decodable {
    public struct Sources: Sendable, Hashable, Decodable {
        public let changes: ReturnSummarySourceStatus
        public let decisions: ReturnSummarySourceStatus

        public init(changes: ReturnSummarySourceStatus, decisions: ReturnSummarySourceStatus) {
            self.changes = changes
            self.decisions = decisions
        }
    }

    public let generatedAt: Date
    /// 마지막 Clear의 지평 ("Since …" 표시용). 읽음의 근거가 아니다. 한 번도 Clear하지 않았으면 nil
    public let since: Date?
    public let baseline: ReturnSummaryBaseline
    /// Clear에 그대로 돌려줄 **불투명** 글자. nil이면 Clear를 보이지 않는다 (변화 원천을 읽지 못했다 · 잘렸는데 서버가 보인 범위를 가리키지 못한다)
    public let cursor: String?
    /// 첫 정상 표시 뒤 기준점을 확정하는 **불투명** 글자 (서버가 만든 사용자 · 지평 · 기준점 범위 digest). `baseline == never_cleared`이고 변화 원천을 읽었을 때만 있다.
    /// 열지도 고치지도 않고 `POST /api/v2/return-summary/baseline`에 그대로 돌려준다. 이 값이 있다는 것은 "지금 확정하라"는 뜻이 아니다: 정상 표시가 된 뒤에만 보낸다
    public let initToken: String?
    /// 서버가 말한 완전성 / 빈 상태. 앱은 그대로 믿지 않고 `isComplete` · `isEmpty`로 다시 검증한다
    public let serverComplete: Bool
    public let serverEmpty: Bool
    public let sources: Sources
    public let items: [ReturnSummaryItem]

    enum CodingKeys: String, CodingKey {
        case since, baseline, cursor, sources, items
        case initToken = "init_token"
        case generatedAt = "generated_at"
        case serverComplete = "complete"
        case serverEmpty = "empty"
    }

    public init(
        generatedAt: Date, since: Date?, baseline: ReturnSummaryBaseline, cursor: String?, initToken: String? = nil, complete: Bool, empty: Bool,
        sources: Sources = Sources(changes: .ok, decisions: .ok), items: [ReturnSummaryItem]
    ) {
        self.generatedAt = generatedAt
        self.since = since
        self.baseline = baseline
        self.cursor = cursor
        self.initToken = initToken
        self.serverComplete = complete
        self.serverEmpty = empty
        self.sources = sources
        self.items = items
    }

    /// 앱이 말로 옮기지 못하는 변화가 보이는 줄(= 커서가 가리키는 표시된 작업)에 있다
    public var hasUninterpretableChange: Bool { items.contains { $0.hasUninterpretableChange } }

    /// 변화 원천의 상태를 읽지 못했다: 상태를 모르거나(unknown) · 기준을 모르는데 원천은 ok라고 하거나 · 두 원천이 ok인데 서버가 complete가 아니라고 한다 (앞뒤가 맞지 않는 응답).
    /// 결정(질문) 원천의 상태는 여기 들지 않는다 — 결정 읽기 실패 · 모르는 결정 종류는 변화의 Clear와 분리된 상태다
    var hasUnreadableChangeStatus: Bool {
        sources.changes == .unknown || (baseline == .unknown && sources.changes == .ok)
            || (!serverComplete && sources.changes == .ok && sources.decisions == .ok)
    }

    /// 완전하다: 서버가 그렇다고 하고, 두 원천이 모두 `ok`이고, 변화 원천 상태가 앞뒤가 맞고, 해석 못 한 변화가 없다
    public var isComplete: Bool {
        serverComplete && sources.changes == .ok && sources.decisions == .ok && !hasUnreadableChangeStatus && !hasUninterpretableChange
    }

    /// "변화 없음 · 모두 처리됨"을 말해도 되는 유일한 경우: 완전하고 줄이 없다 (서버 `empty`가 거짓이면 아니다)
    public var isEmpty: Bool { serverEmpty && isComplete && items.isEmpty }

    /// 변화를 읽었고(ok · 정상 잘림) 그 변화를 안전하게 읽음 처리할 수 있다: 해석 못 한 변화가 없다. 정상 잘림 · 결정 읽기 실패 · 모르는 결정 종류는 막지 않는다
    public var canMarkChangesRead: Bool {
        (sources.changes == .ok || sources.changes == .truncated) && !hasUnreadableChangeStatus && !hasUninterpretableChange
    }

    public var isTruncated: Bool { sources.changes == .truncated }

    /// 읽음 처리할 변화가 보이는 줄에 하나라도 있다 (결정만 있는 줄은 Clear가 할 일이 없다)
    public var hasChangesToClear: Bool { items.contains { !$0.changes.isEmpty } }
}

/// `POST /api/v2/return-summary/clear` 200. `applied == false`는 쓸 것이 없었다 (재시도 · 다른 기기에서 먼저 Clear) — 성공이다
public struct ReturnSummaryClearResponse: Sendable, Hashable, Decodable {
    public let clearedThrough: Date
    public let applied: Bool

    enum CodingKeys: String, CodingKey {
        case applied
        case clearedThrough = "cleared_through"
    }

    public init(clearedThrough: Date, applied: Bool) {
        self.clearedThrough = clearedThrough
        self.applied = applied
    }
}

/// 요청 본문: 커서뿐이다 (서버 strict 스키마. 그 밖의 키 · 클라이언트 시각은 보내지 않는다)
struct ReturnSummaryClearRequest: Encodable {
    let cursor: String
}

/// `POST /api/v2/return-summary/baseline` 200. `initialized`(`applied: true`) = 이 요청이 기준점을 만들었다, `already_initialized`(`applied: false`) = 이미 기준점이 있거나 Clear한 적이 있다
/// (두 기기 · 응답 유실 재시도 · 늦은 확정): 아무것도 쓰지 않았다 — 둘 다 성공이다. 모르는 status도 디코딩은 깨지 않는다 (`.unknown`)
public struct ReturnSummaryBaselineResponse: Sendable, Hashable, Decodable {
    public enum Status: Sendable, Hashable, Decodable {
        case initialized, alreadyInitialized, unknown

        public init(from decoder: Decoder) throws {
            switch token(decoder) {
            case "initialized": self = .initialized
            case "already_initialized": self = .alreadyInitialized
            default: self = .unknown
            }
        }
    }

    public let status: Status
    public let applied: Bool

    public init(status: Status, applied: Bool) {
        self.status = status
        self.applied = applied
    }
}

/// 요청 본문: 토큰뿐이다 (서버 strict 스키마. 그 밖의 키 · 클라이언트 시각은 보내지 않는다)
struct ReturnSummaryBaselineRequest: Encodable {
    let initToken: String

    enum CodingKeys: String, CodingKey { case initToken = "init_token" }
}
