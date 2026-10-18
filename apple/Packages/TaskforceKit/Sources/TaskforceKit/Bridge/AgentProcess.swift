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
// - **작업 폴더 없이는 띄우지 않는다.** 런타임은 모든 실행(새 세션이든 재개든)에 이 Mac이 승인한 `workspaceRef`를 채워 부른다 (서버가 준 폴더는 resolver가 인정할 때만, 없으면 resolver가 정한다 — 없으면 접수 전 `spawn_failed`).
//   그래도 `workspaceRef == nil`로 불리면 `startTurn` · `closeRequest`는 `spawnFailed`를 던진다 (cwd를 짐작하지 않는다, 검토 반영 2 8장 2). `deliverAnswer`는 원장 task의 승인된 폴더로 불린다.
// - **marker는 UUID 모양만 받는다.** 런타임은 UUID 모양이 아닌 marker를 adapter에 넘기지 않는다(명령을 거절한다). adapter는 marker를 명령줄 인자나 파일 이름에 그대로 쓰지 말고, 쓰면 UUID로만 쓴다.
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
    /// 입력이 CLI에 닿았다 (Claude Code `system/init`, OA D3a Q5). **로컬 전용**: 서버 사건이 아니고 접수 신호도 아니다.
    /// 런타임은 명령의 `inputAt`이 비어 있으면 이 시각을 적고, 결과 확인에서 접수 신호 없이 끝난 명령을 `not_received`가 아니라 `unknown`으로 답한다 (계약 13.2 :519)
    case inputReached
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
    /// 값이 이 Mac에서 답한 비밀값이다 (`answered_locally`, OA D3a 10장 7): adapter가 그 값을 가리개에 쌓는다 (앱이 다시 떠도)
    public var answeredLocally: Bool

    public init(
        taskID: String, sessionID: String, turnSeq: Int, adapter: String, externalSessionID: String?, workspaceRef: String?, marker: String,
        access: AgentAccess, policyMode: AgentPolicyMode, requestID: String, kind: BridgeV1PendingQuestionKind, structured: Bool, value: AgentAnswerValue,
        answeredLocally: Bool = false
    ) {
        self.answeredLocally = answeredLocally
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
    /// 신호를 보냈다고 증명하지 못했다 (OA D4a2-09): 잠금을 끝내지 못했거나 · 정체를 모르거나 · 고아를 끝내지 못했다. 런타임은 "보냈다"고 적지 않는다 —
    /// 실행을 그대로 감독 · 잠그고 중단 상태를 `unproven`으로 둔다 (ack는 `complete(sent)` 그대로: 서버 말은 "Stop requested · not confirmed")
    case unknown
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

/// `startTurn`이 던지는 접수 전 실패: 입력을 건네지 않았다. `left`가 없으면 아무것도 띄우지 않았다
public struct AgentStartError: Error, Equatable, Sendable {
    public var reason: BridgeV1FailureReason
    /// 띄운 뒤에 실패했고 그 끝을 증명하지 못했다 (OA D3a 14장 1 · 15장 1: 시작 · 답 · 닫기 모두): 그 실행의 정체 (pid는 모를 수 있다).
    /// 런타임은 이 task를 끝났다고 적지 않고 그 실행을 Stop · 고아 정리 대상으로 둔다
    public var left: AgentProcessIdentity?

    public init(_ reason: BridgeV1FailureReason, left: AgentProcessIdentity? = nil) {
        self.reason = reason
        self.left = left
    }
}

/// 도구 결정 API 호출의 실패 (OA D3a Q11 · Q12): 폐기된 Mac(403)만 거절로, 그 밖(시간 초과 · 2xx 아님 · 등록 전 · 디코딩 실패)은 defer로 다룬다
public enum AgentToolDecisionError: Error, Equatable, Sendable {
    case revoked
    case unavailable
}

/// 런타임이 adapter에 넘기는 좁은 연결 (OA D3a Q12). bridge id · 장치 secret · 계정 세대는 런타임만 안다: adapter는 이것으로만 서버 판정을 받는다
public struct AgentRuntimeServices: Sendable {
    /// `POST /api/v1/bridge/tool-decision` (timeout 1.0초, 재시도 0). 이 런타임의 파티션으로만 간다 (ONE-TF-09)
    public var decideTool: @Sendable (BridgeV1ToolDecisionQuery) async throws -> BridgeV1ToolDecisionResponse
    /// 답 resume로 새 프로세스를 띄운 직후 그 정체(pid · 시작 시각 · marker)를 원장에 먼저 적는다. 답 전달 완료는 `deliverAnswer`의 반환으로 따로 적는다 (OA D3a 8장 14).
    /// 원장 commit이 성공했을 때만 true: adapter는 true를 받은 뒤에만 답을 준다 (9장 8)
    public var recordSpawn: @Sendable (_ taskID: String, _ identity: AgentProcessIdentity) async -> Bool

    public init(
        decideTool: @escaping @Sendable (BridgeV1ToolDecisionQuery) async throws -> BridgeV1ToolDecisionResponse,
        recordSpawn: @escaping @Sendable (_ taskID: String, _ identity: AgentProcessIdentity) async -> Bool = { _, _ in true }
    ) {
        self.decideTool = decideTool
        self.recordSpawn = recordSpawn
    }
}

public protocol AgentProcess: Sendable {
    /// registry id (`agent:claude-code`)
    var adapter: String { get }
    /// 런타임이 만들어질 때 한 번 부른다 (OA D3a Q12). 서버 판정이 필요 없는 adapter는 기본 구현(아무것도 안 함)을 쓴다
    func attach(_ services: AgentRuntimeServices)
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
    /// 세션의 지금 실행 (OA D3a 14장 2 · 15장 1: 그 세션의 생존 진실). 이 adapter가 그 세션에 띄운 마지막 실행(턴 · 답 · 닫기 · 내부 닫기)의 정체와 끝 증명.
    /// nil이면 세션 단위 상태가 없는 adapter다: 런타임은 원장 정체 · 끝 사건으로 본다 (기본)
    func sessionRun(_ sessionID: String) async -> AgentSessionRun?
    /// 그 세션의 지금 실행을 끝낸다 (고아 정리 · 앱 종료, 15장 1). `sessionRun`이 nil이 아닌 adapter에만 부른다
    func terminateSessionRun(_ sessionID: String) async -> AgentLiveness
    /// 앱 종료 · 계정 삭제가 시작됐다 (OA D3a 16장 1): 그 뒤에는 새 프로세스를 띄우지 않는다 (adapter 안에서 띄우는 것 포함). 기본: 할 일 없음
    func stopSpawning() async
    /// 이 adapter의 실행 등록부에 띄우기 의도부터 끝 증명까지의 spawn이 하나라도 있나 (OA D3a 17장 1: 종료 판단 · Quit 확인). 기본: false
    func hasRegisteredRuns() async -> Bool
    /// 그 세션을 잊는다 (OA D4a2-08): 건넨 비밀값의 가리개 · 열린 비밀 항목을 메모리에서 지운다. 런타임이 폐기(revoke) 때 원장의 모든 세션에 부르고, Settings의 Disconnect 성공 뒤에도 부른다. 기본: 할 일 없음
    func forgetSession(_ sessionID: String) async
    /// 이 Mac의 터미널이 그 세션을 이어받는 데 필요한 값 (OA D4a2-06): 이 adapter 상태(세션 폴더 상태 · 실행 파일)에서만 읽는다. 서버가 준 값은 쓰지 않는다.
    /// 터미널에서 이어받을 수 없으면(세션이 묶이지 않았다 · 실행 파일을 못 찾았다 · 이어받는 길이 없는 adapter) nil. 기본: nil
    func terminalSession(_ sessionID: String) async -> AgentTerminalSession?
}

/// 터미널에서 이어받는 데 필요한 adapter 쪽 값 셋 (OA D4a2-06): provider 세션 id(Claude Code `--resume <id>`) · 실행 파일의 realpath · 그 세션을 띄운 **세션 cwd**의 realpath.
/// Claude Code는 대화 기록을 cwd별로 두므로(`~/.claude/projects/<cwd>`) 터미널도 adapter가 띄운 cwd에서 이어받는다. 작업 폴더는 런타임이 등록부에서 더한다
public struct AgentTerminalSession: Sendable, Equatable {
    public var providerSessionID: String
    public var executableRealPath: String
    public var sessionCwd: String

    public init(providerSessionID: String, executableRealPath: String, sessionCwd: String) {
        self.providerSessionID = providerSessionID
        self.executableRealPath = executableRealPath
        self.sessionCwd = sessionCwd
    }
}

/// 세션의 지금 실행 (OA D3a 15장 1): 그 정체(모르면 nil)와 끝 증명
public struct AgentSessionRun: Sendable, Equatable {
    public var liveness: AgentLiveness
    public var identity: AgentProcessIdentity?

    public init(liveness: AgentLiveness, identity: AgentProcessIdentity?) {
        self.liveness = liveness
        self.identity = identity
    }
}

extension AgentProcess {
    public func attach(_ services: AgentRuntimeServices) {}
    public func supportsVersion(_ version: String?) -> Bool { true }
    public func readback(marker: String, session: AgentSessionRef) async -> AgentReadback { .unsupported }
    public func sessionRun(_ sessionID: String) async -> AgentSessionRun? { nil }
    public func terminateSessionRun(_ sessionID: String) async -> AgentLiveness { .unknown }
    public func stopSpawning() async {}
    public func hasRegisteredRuns() async -> Bool { false }
    public func forgetSession(_ sessionID: String) async {}
    public func terminalSession(_ sessionID: String) async -> AgentTerminalSession? { nil }
}

/// 새 세션의 작업 폴더를 정한다 (D4a가 채운다). 사용자 폴더를 짐작해 쓰기 권한을 주지 않는다 (Q26)
public protocol WorkspaceResolver: Sendable {
    func workspace(forSession sessionID: String, adapter: String) async -> String?
    /// 서버가 명령에 실어 준 `workspace_ref`를 이 Mac이 만든(사용자가 고른) 값으로 인정하나. 서버 값을 그대로 작업 폴더로 쓰지 않는다 (검토 반영 7장 C11):
    /// 침해된 서버가 임의 경로를 보내도 이 Mac이 고른 적 없는 폴더에서는 실행하지 않는다. 기본은 거절이다 (D4a의 폴더 레지스트리가 구현한다)
    func authorize(workspaceRef: String, session sessionID: String, adapter: String) async -> Bool
    /// 서버로 보낼 불투명 id (OA D4a2-03): 서버에는 경로를 보내지 않는다. 이 resolver가 등록한 폴더의 id를 돌려주고, 모르는 경로는 nil이다 (그러면 `workspace_ref`를 보내지 않는다). 기본: nil
    func workspaceRef(forPath path: String) async -> String?
    /// 서버가 명령에 실어 준 불투명 id가 가리키는 폴더 (런타임이 `authorize` 전에 바꾼다). 모르는 id는 nil이다. 기본: nil
    func workspacePath(forRef ref: String) async -> String?
    /// 서버가 준 값이 `authorize`를 통과하지 못해도, 이 Mac이 그 세션에 기록한 값과 같으면 인정하나 (옛 절대 경로 세션 · 정규화 차이). 기본: true.
    /// 등록부 resolver는 false다 — 규칙을 다시 본 `authorize`의 거절을 원장에 적힌 옛 경로로 뒤집지 못하게 한다
    var recognizesRecordedPaths: Bool { get }
    /// 세션이 영구히 닫혔고(폐기됨 · 잊음) 그 프로세스의 끝이 증명됐다: 그 세션의 작업 폴더 핀을 푼다 (재검토 2). 증명하지 못한 세션에는 부르지 않는다.
    /// 핀이 더는 없으면 true(풀었거나 원래 없었다), 쓰지 못해 남았으면 false — 런타임은 true일 때만 "닫힘" 표를 지운다. 기본: 할 일 없음(true)
    func releaseSession(_ sessionID: String) async -> Bool
}

extension WorkspaceResolver {
    public func releaseSession(_ sessionID: String) async -> Bool { true }
    public func authorize(workspaceRef: String, session sessionID: String, adapter: String) async -> Bool { false }
    public func workspaceRef(forPath path: String) async -> String? { nil }
    public func workspacePath(forRef ref: String) async -> String? { nil }
    public var recognizesRecordedPaths: Bool { true }
}

/// 비밀값 답은 이 Mac의 메모리에만 있다 (계약 3.6): 서버에도 디스크에도 없다. D4b-m의 입력 화면이 넣고 런타임이 한 번 꺼내 간다
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
