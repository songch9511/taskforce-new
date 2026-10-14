#if os(macOS)
import CryptoKit
import Foundation

// Mac bridge 런타임의 공용 값 (OA D2b 계약 2장). 판단(등급 · gate · 상태 전이)은 서버 몫이고 여기 있는 것은 "내가 실제로 무엇을 했는가"의 기록뿐이다.

// MARK: - 시계 · 파티션

/// 시각과 잠들기를 주입한다. 시험은 수동 시계로 lease 330초 · heartbeat 90초를 실제로 기다리지 않는다
public struct BridgeClock: Sendable {
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (Duration) async throws -> Void

    public init(now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.now = now
        self.sleep = sleep
    }

    public static let system = BridgeClock(now: { Date() }, sleep: { try await Task.sleep(for: $0) })
}

/// 디스크 파티션 = (API origin, 사용자 id) (계약 2.5 · Q4). 같은 사용자의 재로그인은 같은 파티션을 잇고,
/// 다른 사용자 · 다른 서버(로컬 · 운영)는 서로 섞이지 않는다. 원장 · outbox · 자격이 모두 이 이름으로 갈린다
public struct BridgePartition: Hashable, Sendable {
    public let apiOrigin: String
    public let userID: UUID

    public init(apiOrigin: String, userID: UUID) {
        self.apiOrigin = apiOrigin
        self.userID = userID
    }

    public init(apiBaseURL: URL, userID: UUID) {
        self.init(apiOrigin: Self.origin(of: apiBaseURL), userID: userID)
    }

    /// `sha256(origin + "\n" + 사용자 id(소문자))`의 앞 32자 (hex)
    public var id: String {
        let digest = SHA256.hash(data: Data("\(apiOrigin)\n\(userID.uuidString.lowercased())".utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    /// `scheme://host[:port]` (소문자, 경로 · 질의 없음)
    public static func origin(of url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host(percentEncoded: false)?.lowercased() ?? ""
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    /// `<뿌리>/<파티션>/` (뿌리는 보통 `<Application Support>/<번들 id>/Bridge/v1`, 시험은 임시 폴더를 넣는다)
    public func directory(in root: URL) -> URL {
        root.appending(path: id, directoryHint: .isDirectory)
    }
}

/// 깨우기 계기 (지연 측정용, 계약 2.10)
public enum BridgeWakeReason: String, Sendable {
    case realtime
    case longPoll = "long_poll"
    case heartbeat
    case startup
}

/// 요청 한도를 따로 세는 route (계약 2.11)
public enum BridgeRoute: String, Sendable, CaseIterable {
    case register, commands, ack, events, heartbeat
}

// MARK: - 로그 (글 0)

/// 로그에 남길 수 있는 값. 글(메시지 · 질문 · 답) · 비밀 · 경로를 넣을 자리가 없게 값 종류를 좁혔다 (계약 2.15)
public enum BridgeLogValue: Sendable, Equatable {
    case count(Int)
    case id(String)
    case code(String)
    case status(Int)
    case millis(Int)
}

public protocol BridgeLogSink: Sendable {
    func log(_ event: String, _ fields: [String: BridgeLogValue])
}

public struct NoBridgeLog: BridgeLogSink {
    public init() {}
    public func log(_ event: String, _ fields: [String: BridgeLogValue]) {}
}

// MARK: - 원장 기록

/// 명령 상태 (`commands.state`). 가운데 줄은 앞으로만 간다. 옆길 넷은 실행하지 않고 끝난 것이다 (계약 2.5)
public enum BridgeCommandState: String, Sendable, CaseIterable {
    case seen
    case leaseRequested = "lease_requested"
    case leased
    case startIntent = "start_intent"
    case started
    case inputSent = "input_sent"
    case accepted
    case ended
    case settled
    case withdrawn
    case stale
    case declined
    case gone

    /// 가운데 줄의 순서 (옆길은 nil)
    public var rank: Int? {
        switch self {
        case .seen: 0
        case .leaseRequested: 1
        case .leased: 2
        case .startIntent: 3
        case .started: 4
        case .inputSent: 5
        case .accepted: 6
        case .ended: 7
        case .settled: 8
        case .withdrawn, .stale, .declined, .gone: nil
        }
    }

    /// `start_intent` 이상: 이미 띄웠거나 띄웠을 수 있다. **다시 띄우지 않는다** (ONE-TF-04)
    public var hasStartIntent: Bool { (rank ?? 0) >= 3 }

    /// 더 할 일이 없는 기록 (보관 7일 뒤 지운다)
    public var isFinished: Bool {
        switch self {
        case .settled, .withdrawn, .stale, .declined, .gone: true
        default: false
        }
    }
}

public struct BridgeCommandRecord: Equatable, Sendable {
    public var commandID: String
    /// 서버 kind 원문 (`message` · `answer` · `cancel` 또는 모르는 값)
    public var kind: String
    public var agentSessionID: String
    public var agentTaskID: String
    public var turnSeq: Int
    public var cursor: Int
    public var stepID: String?
    public var adapter: String?
    public var marker: String?
    public var state: BridgeCommandState
    public var stateAt: Date
    public var reason: String?
    public var leaseExpiresAt: Date?
    // 지연 측정 시각 (계약 2.10). 서버 시각은 로컬 시계 차이를 `meta.clockOffsetMS`로 환산해 비교한다
    public var serverCreatedAt: Date?
    public var wakeSource: String?
    public var wakeAt: Date?
    public var listedAt: Date?
    public var leaseRequestedAt: Date?
    public var leasedAt: Date?
    public var serverLeasedAt: Date?
    public var spawnAt: Date?
    public var inputAt: Date?
    public var answerSentAt: Date?
    /// 이 명령의 실행 구간에서 첫 접수 신호(접수 또는 첫 활동 사건)를 낸 시각. 결과 확인(readback) 판정의 "접수 신호"다 (계약 2.8)
    public var signalAt: Date?
    // ack
    public var ackOp: String?
    public var ackResult: String?
    public var ackFinalAt: Date?

    public init(
        commandID: String, kind: String, agentSessionID: String, agentTaskID: String, turnSeq: Int, cursor: Int,
        state: BridgeCommandState, stateAt: Date
    ) {
        self.commandID = commandID
        self.kind = kind
        self.agentSessionID = agentSessionID
        self.agentTaskID = agentTaskID
        self.turnSeq = turnSeq
        self.cursor = cursor
        self.state = state
        self.stateAt = stateAt
    }
}

public struct BridgeTaskRecord: Equatable, Sendable {
    public var agentTaskID: String
    public var agentSessionID: String
    public var adapter: String
    public var turnSeq: Int
    public var externalSessionID: String?
    public var workspaceRef: String?
    public var externalTaskID: String?
    // 실행 중인 프로세스 (재시작 뒤 같은 프로세스인지 pid 재사용을 시작 시각으로 가른다)
    public var pid: Int?
    public var processStartedAt: Date?
    public var processMarker: String?
    public var alive: Bool
    public var lastSeq: Int
    /// bridge가 본 상태: dispatched · accepted · running · awaiting_answer · idle · failed · cancelled
    public var lastState: String
    public var acceptedAt: Date?
    /// 지금 이 task를 실행시키는 명령 (message 또는 answer). 사건이 나올 때 이 명령의 `signalAt`을 채운다
    public var currentCommandID: String?
    public var openRequestID: String?
    public var openRequestKind: String?
    /// 비밀값 질문 여부만 (값은 어디에도 쓰지 않는다)
    public var openRequestSecret: Bool
    public var closedRequestIDs: [String]
    /// nil · `requested`(중단 의도를 적음) · `signalled`
    public var cancelState: String?
    public var serverUnknownAt: Date?
    public var reconcileCount: Int
    /// 지금 실행 구간에서 낸 끝 사건 (`completed` · `failed` · `cancelled`). 새 구간(startTurn · deliverAnswer)마다 비운다
    public var segmentTerminal: String?
    public var updatedAt: Date

    public init(agentTaskID: String, agentSessionID: String, adapter: String, turnSeq: Int, updatedAt: Date) {
        self.agentTaskID = agentTaskID
        self.agentSessionID = agentSessionID
        self.adapter = adapter
        self.turnSeq = turnSeq
        self.alive = false
        self.lastSeq = 0
        self.lastState = "dispatched"
        self.openRequestSecret = false
        self.closedRequestIDs = []
        self.reconcileCount = 0
        self.updatedAt = updatedAt
    }

    /// bridge가 아직 끝나지 않았다고 보는 task (heartbeat · reconcile 대상)
    public var isUnfinished: Bool {
        alive || ["dispatched", "accepted", "running", "awaiting_answer"].contains(lastState)
    }
}

public struct BridgeLedgerMeta: Equatable, Sendable {
    public var schemaVersion: Int
    public var bridgeID: String?
    public var registeredAt: Date?
    /// 서버 시각 − 로컬 시각 (밀리초). 왕복 중간점으로 추정한다
    public var clockOffsetMS: Int?
    public var lastHeartbeatOKAt: Date?
    public var adaptersReportHash: String?
    public var heartbeatIntervalSeconds: Int?
    public var unreachableAfterSeconds: Int?
    public var longPollMaxSeconds: Int?

    public init(schemaVersion: Int) {
        self.schemaVersion = schemaVersion
    }
}

public struct OutboxRow: Equatable, Sendable {
    /// 삽입 순서 (같은 세션 안의 순서가 이 순서다)
    public var key: Int64
    public var eventID: String
    public var agentSessionID: String
    public var agentTaskID: String?
    public var seq: Int?
    public var type: String
    /// 서버로 보낼 사건 JSON 그대로 (자른 글 포함). 다시 보낼 때도 같은 글자열 · 같은 event id
    public var bodyJSON: String
    public var bytes: Int
    public var observedAt: Date
    public var attempts: Int
    public var nextAttemptAt: Date
    public var lastStatus: String?
    public var deadReason: String?
}

public struct AckRow: Equatable, Sendable {
    public var key: Int64
    public var commandID: String
    public var op: String
    public var bodyJSON: String
    public var attempts: Int
    public var nextAttemptAt: Date
}

/// 사건 번호 매기는 방식 (계약 2.7)
public enum EventNumbering: Sendable {
    /// seq = task의 마지막 seq + 1, event id `<task>:<seq>`
    case taskSequence
    /// seq 없음, event id `<session>:s<n>`
    case sessionScoped
    /// seq 없음, event id `<task>:r<n>` (서버가 `seq ≤ last_event_seq`를 `late`로 보기 때문)
    case reconcile
}

public struct BuiltEvent: Sendable {
    public var type: String
    public var json: String
    public var observedAt: Date
    /// 글을 32KB로 잘랐으면 전체 글 (View full용, 30일)
    public var fullText: String?

    public init(type: String, json: String, observedAt: Date, fullText: String? = nil) {
        self.type = type
        self.json = json
        self.observedAt = observedAt
        self.fullText = fullText
    }
}

public struct LedgerDiagnostics: Equatable, Sendable {
    public var journalMode: String
    public var synchronous: Int
    public var foreignKeys: Bool
    public var schemaVersion: Int
    public var quickCheck: String
}

public struct PruneReport: Equatable, Sendable {
    public var commands = 0
    public var outbox = 0
    public var deadLetters = 0
    public var fullTexts = 0
    public var expiredEvents = 0
}

public enum BridgeLedgerError: Error, Equatable, Sendable, CustomStringConvertible {
    case sqlite(code: Int, message: String)
    case unknownTask(String)
    case corrupt

    public var description: String {
        switch self {
        case .sqlite(let code, let message): "원장 sqlite \(code): \(message)"
        case .unknownTask(let id): "원장에 없는 task \(id)"
        case .corrupt: "원장 파일이 손상됐다"
        }
    }
}
#endif
