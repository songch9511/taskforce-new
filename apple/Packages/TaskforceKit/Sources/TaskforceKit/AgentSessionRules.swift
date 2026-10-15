import Foundation

// OA U2 계약 2.5 "세션 → 링 · 말" 표와 이슈 링 · 탭 고르기 규칙 (화면 없는 순수 함수).
// 서버 값을 화면 말로 옮길 뿐이다: 실패 이유 · 턴 결과는 대화 본문 · D4a 몫이고, " · " 뒤 세부("Editing pricing.mdx" 같은 진행 글)는 서버에 원천이 없어 쓰지 않는다.

/// 한 세션의 링 · 말 (표의 한 줄)
struct AgentSessionStanding: Equatable {
    let ring: AgentSessionRing?
    let line: String
}

extension AgentSessionRing {
    /// 이슈 목록 행 · 프로젝트 행의 활동 말 (`WorkActivity`와 같은 말). done · waiting · idle은 말이 없다
    public var activityLine: String? {
        switch self {
        case .needsYou: WorkActivity.needsAnswer
        case .unreachable: AgentSessionRules.connectionLost
        case .stopping: WorkActivity.stopRequested
        case .running: WorkActivity.running
        case .done, .waiting, .idle: nil
        }
    }

    /// 지금 있는 `WorkActivity` 글(v1 run · 확인 요청에서 온 것)이 어느 링인가. 모르는 글은 nil
    public init?(v1Activity: String?) {
        switch v1Activity {
        case WorkActivity.needsAnswer?: self = .needsYou
        case WorkActivity.running?: self = .running
        case WorkActivity.stopRequested?: self = .stopping
        default: return nil
        }
    }
}

public enum AgentSessionRules {
    public static let closed = "Closed"
    public static let connectionLost = "Connection lost · progress unknown"
    public static let idle = "Idle"
    public static let doneJustNow = "Done just now"
    public static let external = "External · Open in Terminal"
    /// Done 링이 머무는 시간 (디자인 ActivityRing "Done just now")
    public static let doneHold: TimeInterval = 3
    /// 탭에 보이는 세션의 최대 수 (디자인 SessionTab `max`)
    public static let tabLimit = 6

    // MARK: 2.5 표

    /// 위에서부터 먼저 맞는 줄. 마지막 task는 `turn_seq` 최대다. `doneNow`: 그 task가 `completed`로 바뀌는 것을 본 지 3초가 안 됐다
    static func standing(status: AgentSessionStatus, task: AgentTaskRecord?, doneNow: Bool) -> AgentSessionStanding {
        if status == .closed { return AgentSessionStanding(ring: nil, line: closed) }
        if status == .unreachable || task?.state == .unreachable { return AgentSessionStanding(ring: .unreachable, line: connectionLost) }
        let openState = task.map { [.dispatched, .accepted, .running, .awaitingAnswer].contains($0.state) } ?? false
        if openState, task?.cancelRequestedAt != nil { return AgentSessionStanding(ring: .stopping, line: WorkActivity.stopRequested) }
        switch task?.state {
        case .awaitingAnswer?: return AgentSessionStanding(ring: .needsYou, line: WorkActivity.needsAnswer)
        case .dispatched?, .accepted?, .running?: return AgentSessionStanding(ring: .running, line: WorkActivity.running)
        default: break
        }
        if status == .external { return AgentSessionStanding(ring: .idle, line: external) }
        if task?.state == .completed, doneNow { return AgentSessionStanding(ring: .done, line: doneJustNow) }
        return AgentSessionStanding(ring: .idle, line: idle)
    }

    /// 마지막 task: 그 세션의 `turn_seq` 최대 (`turn_seq`가 없는 task는 턴이 아니다)
    static func lastTask(of session: UUID, in tasks: [AgentTaskRecord]) -> AgentTaskRecord? {
        tasks.filter { $0.agentSessionID == session && $0.turnSeq != nil }.max { ($0.turnSeq ?? 0) < ($1.turnSeq ?? 0) }
    }

    /// 머리의 알약: `bound`(첫 턴 뒤) · `external`일 때만. 연결이 끊겼거나(세션 · 마지막 턴) 닫혔거나 첫 턴 전이면 없다 (새 문구를 만들지 않는다)
    static func pill(for session: AgentSessionRecord, task: AgentTaskRecord?) -> AgentSessionPill? {
        switch session.status {
        case .external:
            return .resumeHere
        case .bound:
            guard !session.isPendingFirstTurn, task?.state != .unreachable else { return nil }
            switch task?.state {
            case .dispatched?, .accepted?, .running?: return .openInTerminal(disabledReason: AgentSessionPill.turnRunning)
            case .awaitingAnswer?: return .openInTerminal(disabledReason: AgentSessionPill.answerFirst)
            default: return .openInTerminal(disabledReason: nil)
            }
        case .unreachable, .closed, .unknown:
            return nil
        }
    }

    // MARK: 읽은 값 → 세션 항목

    /// 읽은 값에서 화면이 쓰는 세션들. 만든 시각 순(오래된 것이 먼저, 같으면 id).
    /// - doneObservedAt: 세션의 마지막 task가 `completed`로 바뀌는 것을 본 때 (저장소가 정한다)
    public static func items(snapshot: AgentSessionSnapshot, doneObservedAt: [UUID: Date], now: Date) -> [AgentSessionItem] {
        let adapters = Dictionary(snapshot.connections.map { ($0.id, $0.adapter) }, uniquingKeysWith: { first, _ in first })
        let sessions = snapshot.sessions.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        return sessions.map { session in
            let agent = adapters[session.connectionID].map(AgentMarkKind.of(adapter:)) ?? .placeholder
            let agentName = agent.accessibilityName
            let task = lastTask(of: session.id, in: snapshot.tasks)
            let seen = doneObservedAt[session.id]
            let doneNow = seen.map { now.timeIntervalSince($0) < doneHold && now >= $0 } ?? false
            let standing = standing(status: session.status, task: task, doneNow: doneNow)
            let runs = snapshot.runs.filter { $0.agentSessionID == session.id && $0.kind == AgentSessionRunRecord.conversationKind }
            var seenIssues = Set<UUID>()
            let issues = runs.map(\.actionID).filter { seenIssues.insert($0).inserted }
            let current = task.flatMap { task in runs.first { $0.id == task.runID }?.actionID } ?? (issues.count == 1 ? issues.first : nil)
            return AgentSessionItem(
                id: session.id, name: session.displayName.isEmpty ? agentName : session.displayName, agent: agent, agentName: agentName,
                connectionID: session.connectionID, status: session.status, ring: standing.ring, line: standing.line, createdAt: session.createdAt,
                updatedAt: session.updatedAt, issueIDs: issues, currentIssueID: current,
                conversationID: snapshot.conversations.first { $0.agentSessionID == session.id }?.id,
                hasOpenTask: session.status != .closed && (task?.isOpen ?? false), pill: pill(for: session, task: task)
            )
        }
    }

    // MARK: 이슈 · 탭

    /// 한 이슈의 링 하나: v1 run · 확인 요청의 링과 그 이슈 세션들의 링 중 먼저인 것 (needs-you → unreachable → stopping → running → done → waiting).
    /// idle · 닫힌 세션은 링이 되지 않는다
    public static func issueRing(v1: AgentSessionRing?, sessions: [AgentSessionItem]) -> AgentSessionRing? {
        ([v1] + sessions.map(\.ring)).compactMap { $0 }.filter { $0.issueRank != nil }.min { ($0.issueRank ?? 0) < ($1.issueRank ?? 0) }
    }

    /// 이 이슈들의 세션만 (프로젝트 · Ungrouped 이슈 목록은 그 이슈들의 세션 전체, 이슈 상세는 그 이슈 하나). 이슈가 없는 세션은 어디에도 없다
    public static func sessions(of issues: Set<UUID>, in items: [AgentSessionItem]) -> [AgentSessionItem] {
        items.filter { !issues.isDisjoint(with: $0.issueIDs) }
    }

    /// 이슈 상세 Sessions 목록의 차례: 만든 시각 순, 닫힌 세션은 맨 아래
    public static func listOrder(_ items: [AgentSessionItem]) -> [AgentSessionItem] {
        let ordered = items.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        return ordered.filter { !$0.isClosed } + ordered.filter(\.isClosed)
    }

    /// 탭: 닫힌 세션은 없다. 여섯 이하면 모두, 넘으면 여섯(현재 세션 → needs-you 먼저, 그다음 최근 갱신 순)과 More.
    /// 보이는 순서는 만든 시각 순이라 갱신해도 흔들리지 않는다 (오래된 것이 위)
    public static func tabPlan(sessions: [AgentSessionItem], currentID: UUID?, limit: Int = tabLimit) -> AgentSessionTabPlan {
        let candidates = sessions.filter(\.showsInTab)
        func byCreation(_ items: [AgentSessionItem]) -> [AgentSessionItem] {
            items.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        }
        func byRecency(_ items: [AgentSessionItem]) -> [AgentSessionItem] {
            items.sorted { ($0.updatedAt, $1.id.uuidString) > ($1.updatedAt, $0.id.uuidString) }
        }
        guard candidates.count > limit else { return AgentSessionTabPlan(shown: byCreation(candidates), hidden: []) }
        let current = candidates.filter { $0.id == currentID }
        let needsYou = byRecency(candidates.filter { $0.id != currentID && $0.ring == .needsYou })
        let rest = byRecency(candidates.filter { $0.id != currentID && $0.ring != .needsYou })
        let kept = Array((current + needsYou + rest).prefix(limit))
        let keptIDs = Set(kept.map(\.id))
        return AgentSessionTabPlan(shown: byCreation(kept), hidden: byCreation(candidates.filter { !keptIDs.contains($0.id) }))
    }
}

/// 탭이 그릴 것: 보이는 세션과 More 뒤의 세션
public struct AgentSessionTabPlan: Equatable, Sendable {
    public let shown: [AgentSessionItem]
    public let hidden: [AgentSessionItem]

    public init(shown: [AgentSessionItem], hidden: [AgentSessionItem]) {
        self.shown = shown
        self.hidden = hidden
    }

    /// More 항목의 접근성 이름 "{n} more sessions" (화면에는 개수가 없다)
    public var moreLabel: String? {
        hidden.isEmpty ? nil : "\(hidden.count) more session\(hidden.count == 1 ? "" : "s")"
    }
}
