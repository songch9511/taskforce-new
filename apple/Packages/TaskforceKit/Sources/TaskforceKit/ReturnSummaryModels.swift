import Foundation

// 복귀 요약 (C3 ReturnSummary)의 앱 쪽 모양. 서버 `contract.ts` C3 절의 `returnSummaryResponseSchema` · `returnSummaryClearResponseSchema`를 읽는다:
// 서버 C3 head `6cfd382`(`handoffs/c3-server-notes.md` "Mac에 넘기는 JSON 계약", `ReturnSummaryContractFixtures`가 그 JSON을 고정한다).
// 규칙:
// - 구조(필수 키 · 타입)는 엄격하다: 틀리면 디코딩 실패 = "읽지 못함"이지 빈 상태가 아니다.
// - enum / 토큰은 관대하다: 모르는 값은 `.unknown`이고, 그런 응답은 **완전하지 않은 것**으로 읽는다 (`ReturnSummaryResponse.isComplete`).
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
    /// 한 번도 Clear하지 않았다 (`since == nil`, 첫 기준 시각은 열린 제품 결정)
    case neverCleared
    /// 변화 원천을 읽지 못했다 (서버가 말한 `unknown`이거나 이 앱이 모르는 값)
    case unknown

    public init(from decoder: Decoder) throws {
        switch token(decoder) {
        case "cleared": self = .cleared
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
    /// run `done`이면 그 run의 outcome (`draft_ready` …)
    public let detail: String?
    /// action_event만. 그 밖에는 nil
    public let sourceState: ReturnSummarySourceState?

    enum CodingKeys: String, CodingKey {
        case source, kind, at, detail
        case sourceState = "source_state"
    }

    public init(source: ReturnSummaryChangeSource, kind: String, at: Date, detail: String? = nil, sourceState: ReturnSummarySourceState? = nil) {
        self.source = source
        self.kind = kind
        self.at = at
        self.detail = detail
        self.sourceState = sourceState
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(ReturnSummaryChangeSource.self, forKey: .source)
        kind = (try? c.decode(String.self, forKey: .kind)) ?? ""
        at = try c.decode(Date.self, forKey: .at)
        detail = try? c.decodeIfPresent(String.self, forKey: .detail)
        sourceState = try c.decodeIfPresent(ReturnSummarySourceState.self, forKey: .sourceState)
    }
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

    /// 이 앱이 읽지 못하는 값이 들어 있다 (그 응답은 완전하다고 주장하지 않는다)
    var hasUnknownValues: Bool {
        status == .unknown || state == .unknown || next.kind == .unknown
            || next.decisionKinds.contains(.unknown) || decisions.contains { $0.kind == .unknown }
            || changes.contains { $0.source == .unknown || $0.sourceState == .unknown }
    }
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
    /// 서버가 말한 완전성 / 빈 상태. 앱은 그대로 믿지 않고 `isComplete` · `isEmpty`로 다시 검증한다
    public let serverComplete: Bool
    public let serverEmpty: Bool
    public let sources: Sources
    public let items: [ReturnSummaryItem]

    enum CodingKeys: String, CodingKey {
        case since, baseline, cursor, sources, items
        case generatedAt = "generated_at"
        case serverComplete = "complete"
        case serverEmpty = "empty"
    }

    public init(
        generatedAt: Date, since: Date?, baseline: ReturnSummaryBaseline, cursor: String?, complete: Bool, empty: Bool,
        sources: Sources = Sources(changes: .ok, decisions: .ok), items: [ReturnSummaryItem]
    ) {
        self.generatedAt = generatedAt
        self.since = since
        self.baseline = baseline
        self.cursor = cursor
        self.serverComplete = complete
        self.serverEmpty = empty
        self.sources = sources
        self.items = items
    }

    /// 이 앱이 읽지 못하는 값이 하나라도 있다
    public var hasUnknownValues: Bool {
        baseline == .unknown && sources.changes == .ok
            || sources.changes == .unknown || sources.decisions == .unknown || items.contains { $0.hasUnknownValues }
    }

    /// 완전하다: 서버가 그렇다고 하고, 두 원천이 모두 `ok`이고, 이 앱이 읽지 못한 값이 없다
    public var isComplete: Bool {
        serverComplete && sources.changes == .ok && sources.decisions == .ok && !hasUnknownValues
    }

    /// "변화 없음 · 모두 처리됨"을 말해도 되는 유일한 경우: 완전하고 줄이 없다 (서버 `empty`가 거짓이면 아니다)
    public var isEmpty: Bool { serverEmpty && isComplete && items.isEmpty }

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
