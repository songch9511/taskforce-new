import Foundation

// 에이전트 대화의 새 UI 문구 (OA D4a 계약 7장). **승인 전 후보를 한 곳에 모은다**: 새 문구는 늘 사용자 승인이다 (오케스트레이션 §3A · §4).
// - `AgentUnapprovedCopy.approved`: 지금 앱이 쓰는 값. 새 말이 하나도 없다 — DS에 없는 이유는 일반 줄("Not sent")로, 링크 · 접근성 동작 이름은 말 없이 떨어진다
// - `AgentUnapprovedCopy.candidates`: 7장의 후보. **견본 앱(Debug, `AgentNewCopy.isPreviewing`)에서만** 보인다. Release 빌드에는 켜는 길이 없다
// 승인되면 `approved`의 값을 후보로 바꾸고(이 파일 한 곳) `candidates`를 지운다.

public struct AgentUnapprovedCopy: Equatable, Sendable {
    /// `version_unsupported` 이유 (DS "no copy yet")
    public var versionUnsupported: String?
    /// `usage_limited` 이유 (DS "no copy yet")
    public var usageLimited: String?
    /// `spawn_failed` 이유 (DS "no copy yet")
    public var spawnFailed: String?
    /// `not_received` 이유
    public var notReceived: String?
    /// `session_closed` 이유 (닫힌 세션: Send again 없음)
    public var sessionClosed: String?
    /// `cancelled` 이유
    public var cancelled: String?
    /// `needs_referent` 줄의 링크
    public var chooseReferent: String?
    /// auto 칩을 눌러 더하는 접근성 동작 이름의 틀 (`%@` = 칩 이름)
    public var addChipFormat: String?
    /// Stop 뒤 명령이 남을 수 있다 (계약 v3 :310, DS에 없음)
    public var stoppedMayContinue: String?

    public init(
        versionUnsupported: String? = nil, usageLimited: String? = nil, spawnFailed: String? = nil, notReceived: String? = nil, sessionClosed: String? = nil,
        cancelled: String? = nil, chooseReferent: String? = nil, addChipFormat: String? = nil, stoppedMayContinue: String? = nil
    ) {
        self.versionUnsupported = versionUnsupported
        self.usageLimited = usageLimited
        self.spawnFailed = spawnFailed
        self.notReceived = notReceived
        self.sessionClosed = sessionClosed
        self.cancelled = cancelled
        self.chooseReferent = chooseReferent
        self.addChipFormat = addChipFormat
        self.stoppedMayContinue = stoppedMayContinue
    }

    /// 지금 앱이 쓰는 새 문구: 없다
    public static let approved = AgentUnapprovedCopy()

    #if DEBUG
    /// 계약 7장의 후보 (승인 전, 견본 · 시험 전용). **Debug 빌드에만 있다**: Release 바이너리에는 이 글자들이 들어가지 않는다
    public static let candidates = AgentUnapprovedCopy(
        versionUnsupported: "Unsupported version", usageLimited: "Usage limit reached", spawnFailed: "Session didn't start", notReceived: "Not received",
        sessionClosed: "Session closed", cancelled: "Stopped", chooseReferent: "Choose an issue", addChipFormat: "Add %@",
        stoppedMayContinue: "Stopped · commands may still be running"
    )
    #endif

    public var isEmpty: Bool { self == Self.init() }

    /// "Add #139 Rewrite pricing page copy" (틀이 승인 전이면 nil)
    public func addChip(_ chipName: String) -> String? {
        addChipFormat.map { $0.replacingOccurrences(of: "%@", with: chipName) }
    }

    /// 이 이유의 말 (없으면 nil → 일반 줄)
    func reasonWords(_ reason: AgentDeliveryReason) -> String? {
        switch reason {
        case .versionUnsupported: versionUnsupported
        case .usageLimited: usageLimited
        case .spawnFailed: spawnFailed
        case .notReceived: notReceived
        case .sessionClosed: sessionClosed
        default: nil
        }
    }
}

/// 지금 화면이 쓰는 새 문구 (한 곳). Release에서는 늘 `approved`다
public enum AgentNewCopy {
    #if DEBUG
    /// 견본 앱(`-TFEdgeSnapshotAgentChat`)만 켠다: 승인 전 후보를 화면에 그린다. 시험은 이 값을 건드리지 않고 문구를 직접 넘긴다
    nonisolated(unsafe) public static var isPreviewing = false
    public static var active: AgentUnapprovedCopy { isPreviewing ? .candidates : .approved }
    #else
    public static var active: AgentUnapprovedCopy { .approved }
    #endif
}

/// DS에 있는 문구 (승인됨, 바꾸지 않는다): 전달 · Stop · 확인 카드
public enum AgentCopy {
    public static let received = "Received"
    public static let sent = "Sent"
    public static let unknown = "Unknown · Not confirmed by the agent"
    public static let queued = "Queued"
    public static let sessionInTerminal = "Session is in Terminal"
    public static let macOffline = "Mac is offline"
    public static let answerFirst = "Answer the question first"
    public static let notSent = "Not sent"
    public static let accessNotVerified = "Access not verified"
    public static let notConnected = "Not connected"
    public static let unsupported = "Unsupported"
    public static let expired = "Expired · Older than 24 hours"
    public static let sendAgain = "Send again"
    public static let stopNewSteps = "Stop new steps"
    public static let stopRequested = "Stop requested · not confirmed"
    public static let resumeTitle = "Is the Terminal session closed?"
    public static let resumeMeta = "Queued messages send after you resume"
    public static let resumeConfirm = "Resume here"
    public static let cancel = "Cancel"
    public static let closeTerminalFirst = "Close the terminal session first"
    public static let viewFull = "View full"

    public static func notSignedIn(to agent: String) -> String { "Not signed in to \(agent)" }
}
