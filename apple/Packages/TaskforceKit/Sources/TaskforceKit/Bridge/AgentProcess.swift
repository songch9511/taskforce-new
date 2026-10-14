#if os(macOS)
import Foundation

// adapter 하나의 실행 드라이버 (OA D2b 계약 2.3). D3a `ClaudeCodeProcess`(턴마다 프로세스) · D3b Codex(오래 사는 app-server)가 구현한다.
//
// - adapter는 **형태 있는 사건만** 낸다 (`AgentEvent`). event id · seq · 자르기 · `observed_at` · 원장 · outbox는 런타임 한 곳이 한다 (adapter가 DTO 봉투를 만들지 않는다).
// - 글(사용자 메시지 · 비밀값 답)은 메모리로만 넘긴다. 런타임은 디스크에 쓰지 않는다.
// - writer 하나: 런타임은 같은 세션에 살아 있는 실행이 있으면 그 세션의 `startTurn` · `deliverAnswer`를 부르지 않는다 (lease도 하지 않는다).
// - `startTurn`이 던지면 **아무것도 띄우지 않았다**는 뜻이다 (adapter가 정리한다). 던진 이유가 `AgentStartError`면 그 이유로 `failed` 사건을 낸다.
//
// adapter 규칙 (D3a · D3b가 지킨다, 검토 반영 7장 A3 · D):
// - **끝을 증명하지 못하면 `.unknown`이다.** `liveness`는 같은 프로세스가 없다는 것을 확인했을 때만 `.ended`를 주고, `terminateOrphan`은 신호를 보낸 뒤 사라진 것을 확인했을 때만 `.ended`를 준다.
//   모르면 `.unknown`(또는 끝내지 못했으면 `.alive`)이다. 런타임은 `.unknown`인 고아를 "확인 안 된 고아"로 두고 heartbeat `process_alive`를 true로 보내지 않으며 결과 확인에는 `unknown`으로만 답한다.
// - **프로세스 정체 확인을 강하게 한다.** pid만 믿지 않는다: 시작 시각(원장은 밀리초라 1ms 안에서 같아야 한다) · 프로세스 소유자(uid가 이 사용자) · 우리가 띄울 때 심은 marker가 모두 맞아야 같은 프로세스다.
//   `pid <= 1`에는 어떤 신호도 보내지 않는다. SIGTERM → SIGKILL로 올릴 때 **신호마다 정체를 다시 확인한다** (그 사이 pid가 재사용됐을 수 있다).
// - **종료 · 계정 삭제에서는 `interrupt`가 듣지 않아도 `terminateOrphan`이 끝낸다.** 런타임은 유예(3초) 뒤에 감독 중인 실행에 `terminateOrphan`을 부른다. 감독 밖 writer를 남기지 않는다.
// - 하위 프로세스에는 앱의 환경을 통째로 넘기지 않는다: `AgentChildEnvironment.allowlisted()`(HOME · PATH · LANG · USER)에 adapter가 필요한 것만 명시해서 더한다.

public enum AgentAccess: Sendable, Equatable {
    case write
    case readOnly
}

public enum AgentPolicyMode: Sendable, Equatable {
    case manual
    case auto
    case full
}

public enum AgentCancelScope: Sendable, Equatable {
    case turn
    case turnAndProcesses
}

/// 실행 구간의 프로세스 정체. 재시작 뒤 같은 프로세스인지 pid 재사용을 시작 시각으로 가려 본다
public struct AgentProcessIdentity: Sendable, Equatable {
    public var pid: Int?
    public var startedAt: Date
    public var processMarker: String
    /// adapter가 턴마다 주는 외부 작업 id (있으면 이후 사건 봉투에 싣는다)
    public var externalTaskID: String?
    /// Codex 멈춤 지점: `turn/start`를 보낸 시각 (ONE-TF-11 지연 측정, 계약 2.10). Claude Code는 `startedAt`이 멈춤 지점이다
    public var inputSentAt: Date?

    public init(pid: Int?, startedAt: Date, processMarker: String, externalTaskID: String? = nil, inputSentAt: Date? = nil) {
        self.pid = pid
        self.startedAt = startedAt
        self.processMarker = processMarker
        self.externalTaskID = externalTaskID
        self.inputSentAt = inputSentAt
    }
}

public struct AgentExit: Sendable, Equatable {
    public var code: Int?
    public var signal: Int?

    public init(code: Int?, signal: Int? = nil) {
        self.code = code
        self.signal = signal
    }

    public var isClean: Bool { code == 0 && signal == nil }
}

public struct AgentQuestionOption: Sendable, Equatable {
    public var label: String
    public var description: String

    public init(label: String, description: String) {
        self.label = label
        self.description = description
    }
}

public struct AgentQuestionItem: Sendable, Equatable {
    public var id: String
    public var header: String
    public var text: String
    public var options: [AgentQuestionOption]
    public var multiSelect: Bool
    public var allowOther: Bool
    public var secret: Bool

    public init(id: String, header: String, text: String, options: [AgentQuestionOption], multiSelect: Bool = false, allowOther: Bool = false, secret: Bool = false) {
        self.id = id
        self.header = header
        self.text = text
        self.options = options
        self.multiSelect = multiSelect
        self.allowOther = allowOther
        self.secret = secret
    }
}

public struct AgentQuestion: Sendable, Equatable {
    public var providerRequestID: String
    public var kind: BridgeV1PendingQuestionKind
    public var structured: Bool
    /// 사건 본문 글 (사람이 읽는 질문 요약)
    public var text: String
    public var items: [AgentQuestionItem]

    public init(providerRequestID: String, kind: BridgeV1PendingQuestionKind, structured: Bool, text: String, items: [AgentQuestionItem]) {
        self.providerRequestID = providerRequestID
        self.kind = kind
        self.structured = structured
        self.text = text
        self.items = items
    }
}

/// adapter가 내는 사건 (형태만). `ended`는 프로세스 종료 신호이고 서버로 가는 사건이 아니다
public enum AgentEvent: Sendable, Equatable {
    case sessionBound(externalSessionID: String, workspaceRef: String?)
    /// 접수 신호. Claude Code는 진짜 첫 assistant 메시지(synthetic 제외), Codex는 `turn/started` (adapter가 정한다)
    case accepted
    case progress
    case message(text: String)
    case question(AgentQuestion)
    case artifact(path: String, hash: String, summary: String)
    case turnCompleted
    case failed(BridgeV1FailureReason?)
    case cancelled
    case ended(AgentExit)
}

public struct AgentEventSink: Sendable {
    private let deliver: @Sendable (AgentEvent, Date?) async -> Void

    public init(_ deliver: @escaping @Sendable (AgentEvent, Date?) async -> Void) {
        self.deliver = deliver
    }

    /// `at`은 adapter가 그 일을 본 시각 (없으면 런타임이 받은 시각)
    public func emit(_ event: AgentEvent, at: Date? = nil) async {
        await deliver(event, at)
    }
}

public struct AgentTurnStart: Sendable {
    public var taskID: String
    public var sessionID: String
    public var turnSeq: Int
    public var adapter: String
    public var externalSessionID: String?
    public var workspaceRef: String?
    public var resume: Bool
    public var access: AgentAccess
    public var policyMode: AgentPolicyMode
    /// 서버 `execution_intents.marker`. Codex는 `clientUserMessageId`로 보내 결과 확인(readback)에 쓴다
    public var marker: String
    /// 사용자 메시지 글. 메모리로만 다룬다
    public var text: String

    public init(
        taskID: String, sessionID: String, turnSeq: Int, adapter: String, externalSessionID: String?, workspaceRef: String?, resume: Bool,
        access: AgentAccess, policyMode: AgentPolicyMode, marker: String, text: String
    ) {
        self.taskID = taskID
        self.sessionID = sessionID
        self.turnSeq = turnSeq
        self.adapter = adapter
        self.externalSessionID = externalSessionID
        self.workspaceRef = workspaceRef
        self.resume = resume
        self.access = access
        self.policyMode = policyMode
        self.marker = marker
        self.text = text
    }
}

public struct AgentAnswerValue: Sendable, Equatable {
    public var answers: [String: BridgeV1AnswerValue]?
    public var text: String?

    public init(answers: [String: BridgeV1AnswerValue]? = nil, text: String? = nil) {
        self.answers = answers
        self.text = text
    }
}

public struct AgentAnswerDelivery: Sendable {
    public var taskID: String
    public var sessionID: String
    public var turnSeq: Int
    public var adapter: String
    public var externalSessionID: String?
    public var workspaceRef: String?
    public var marker: String
    public var access: AgentAccess
    public var policyMode: AgentPolicyMode
    public var requestID: String
    public var kind: BridgeV1PendingQuestionKind
    public var structured: Bool
    /// 서버가 준 값이거나(비밀값이 아닐 때) 이 Mac의 메모리에서 가져온 값(`answered_locally`). 디스크에 쓰지 않는다
    public var value: AgentAnswerValue

    public init(
        taskID: String, sessionID: String, turnSeq: Int, adapter: String, externalSessionID: String?, workspaceRef: String?, marker: String,
        access: AgentAccess, policyMode: AgentPolicyMode, requestID: String, kind: BridgeV1PendingQuestionKind, structured: Bool, value: AgentAnswerValue
    ) {
        self.taskID = taskID
        self.sessionID = sessionID
        self.turnSeq = turnSeq
        self.adapter = adapter
        self.externalSessionID = externalSessionID
        self.workspaceRef = workspaceRef
        self.marker = marker
        self.access = access
        self.policyMode = policyMode
        self.requestID = requestID
        self.kind = kind
        self.structured = structured
        self.value = value
    }
}

public enum AgentAnswerResult: Sendable, Equatable {
    case delivered(AgentProcessIdentity)
    /// 그 요청이 이미 닫혀 있었다 (adapter 쪽에서). 런타임은 `request_closed`로 알린다
    case requestClosed
}

public struct AgentRequestRef: Sendable, Equatable {
    public var taskID: String
    public var sessionID: String
    public var requestID: String
    public var externalSessionID: String?
    public var workspaceRef: String?

    public init(taskID: String, sessionID: String, requestID: String, externalSessionID: String?, workspaceRef: String?) {
        self.taskID = taskID
        self.sessionID = sessionID
        self.requestID = requestID
        self.externalSessionID = externalSessionID
        self.workspaceRef = workspaceRef
    }
}

public struct AgentTurnRef: Sendable, Equatable {
    public var taskID: String
    public var sessionID: String
    public var identity: AgentProcessIdentity?

    public init(taskID: String, sessionID: String, identity: AgentProcessIdentity?) {
        self.taskID = taskID
        self.sessionID = sessionID
        self.identity = identity
    }
}

public struct AgentSessionRef: Sendable, Equatable {
    public var sessionID: String
    public var externalSessionID: String?
    public var workspaceRef: String?

    public init(sessionID: String, externalSessionID: String?, workspaceRef: String?) {
        self.sessionID = sessionID
        self.externalSessionID = externalSessionID
        self.workspaceRef = workspaceRef
    }
}

public enum AgentInterruptResult: Sendable, Equatable {
    /// 중단 신호를 보냈다 (끝남은 `ended`로 알려 온다)
    case signalled
    /// 돌고 있는 실행이 없다
    case notRunning
}

public enum AgentLiveness: Sendable, Equatable {
    case alive
    case ended(AgentExit)
    /// 확인할 수 없다. **끝났다고 보고하지 않는다**
    case unknown
}

public enum AgentReadback: Sendable, Equatable {
    case received
    /// `processEnded`가 false면 `not_received`로 보낼 수 없다 (살아 있는 프로세스는 늦게 받을 수 있다, 계약 13.1)
    case notReceived(processEnded: Bool)
    case unknown
    /// 결과 확인을 지원하지 않는다 (Claude Code: 원장만, transcript 파싱 금지 — 계약 13.2)
    case unsupported
}

/// `startTurn`이 던지는 접수 전 실패: 아무것도 띄우지 않았다
public struct AgentStartError: Error, Equatable, Sendable {
    public var reason: BridgeV1FailureReason

    public init(_ reason: BridgeV1FailureReason) {
        self.reason = reason
    }
}

public protocol AgentProcess: Sendable {
    /// registry id (`agent:claude-code`)
    var adapter: String { get }
    /// 설치 · 버전 · 로그인 · managed settings 보고. 자격 값은 읽지 않는다 (I16)
    func probe() async -> BridgeV1AdapterReport
    /// 이 버전을 이 adapter가 다룰 수 있나 (시작 직전 확인). 기본은 모두 허용
    func supportsVersion(_ version: String?) -> Bool
    func startTurn(_ turn: AgentTurnStart, events: AgentEventSink) async throws -> AgentProcessIdentity
    /// 던지면 아무것도 전달하지 않았다. 런타임은 그 요청을 닫고(deny) `request_closed`로 알린다
    func deliverAnswer(_ answer: AgentAnswerDelivery, events: AgentEventSink) async throws -> AgentAnswerResult
    /// 요청을 거절로 닫는다 (`close_before` · 버려진 요청 · 비밀값 분실)
    func closeRequest(_ request: AgentRequestRef) async throws
    func interrupt(_ target: AgentTurnRef, scope: AgentCancelScope) async -> AgentInterruptResult
    /// 재시작 뒤 고아 확인
    func liveness(_ identity: AgentProcessIdentity) async -> AgentLiveness
    func terminateOrphan(_ identity: AgentProcessIdentity) async -> AgentLiveness
    func readback(marker: String, session: AgentSessionRef) async -> AgentReadback
}

extension AgentProcess {
    public func supportsVersion(_ version: String?) -> Bool { true }
    public func readback(marker: String, session: AgentSessionRef) async -> AgentReadback { .unsupported }
}

/// 새 세션의 작업 폴더를 정한다 (D4a가 채운다). 사용자 폴더를 짐작해 쓰기 권한을 주지 않는다 (Q26)
public protocol WorkspaceResolver: Sendable {
    func workspace(forSession sessionID: String, adapter: String) async -> String?
    /// 서버가 명령에 실어 준 `workspace_ref`를 이 Mac이 만든(사용자가 고른) 값으로 인정하나. 서버 값을 그대로 작업 폴더로 쓰지 않는다 (검토 반영 7장 C11):
    /// 침해된 서버가 임의 경로를 보내도 이 Mac이 고른 적 없는 폴더에서는 실행하지 않는다. 기본은 거절이다 (D4a의 폴더 레지스트리가 구현한다)
    func authorize(workspaceRef: String, session sessionID: String, adapter: String) async -> Bool
}

extension WorkspaceResolver {
    public func authorize(workspaceRef: String, session sessionID: String, adapter: String) async -> Bool { false }
}

/// 비밀값 답은 이 Mac의 메모리에만 있다 (계약 3.6): 서버에도 디스크에도 없다. D4a의 입력 화면이 넣고 런타임이 한 번 꺼내 간다
public actor LocalSecretAnswers {
    private var values: [String: AgentAnswerValue] = [:]
    private var onChange: (@Sendable (Bool) -> Void)?

    public init() {}

    /// 아직 전달하지 않은 비밀값이 있는지 바뀔 때 알린다 (종료 확인의 "바쁨")
    public func observe(_ onChange: @escaping @Sendable (Bool) -> Void) {
        self.onChange = onChange
    }

    public func put(requestID: String, value: AgentAnswerValue) {
        values[requestID] = value
        onChange?(true)
    }

    public func take(requestID: String) -> AgentAnswerValue? {
        let value = values.removeValue(forKey: requestID)
        if values.isEmpty { onChange?(false) }
        return value
    }

    public var hasPending: Bool { !values.isEmpty }

    public func clear() {
        values.removeAll()
        onChange?(false)
    }
}
#endif
