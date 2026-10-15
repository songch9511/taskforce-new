import Foundation
@testable import TaskforceKit

/// 세션 읽기 시험용 행 만들기. 같은 번호는 같은 id다
enum SessionFx {
    static func id(_ n: Int, prefix: String = "5e550000") -> UUID {
        UUID(uuidString: String(format: "%@-0000-4000-8000-%012d", prefix, n))!
    }

    static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    static func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    static let claudeConnection = id(1, prefix: "c0c00000")
    static let codexConnection = id(2, prefix: "c0c00000")
    static let connections = [
        AgentConnectionRecord(id: claudeConnection, adapter: "agent:claude-code"),
        AgentConnectionRecord(id: codexConnection, adapter: "agent:codex"),
    ]

    static func session(
        _ n: Int, name: String = "Pricing", status: AgentSessionStatus = .bound, connection: UUID = claudeConnection, pending: Bool = false,
        turn: Int = 1, created: Double = 0, updated: Double = 0
    ) -> AgentSessionRecord {
        AgentSessionRecord(
            id: id(n), connectionID: connection, displayName: name, status: status, isPendingFirstTurn: pending, lastTurnSeq: turn,
            createdAt: at(created), updatedAt: at(updated)
        )
    }

    /// 세션 `n`의 마지막 턴. 같은 run id는 `n`에서 정한다
    static func task(
        _ session: Int, state: AgentTaskState, turn: Int = 1, cancelRequested: Bool = false, live: AgentTaskState? = nil
    ) -> AgentTaskRecord {
        AgentTaskRecord(
            agentSessionID: id(session), runID: id(session * 100 + turn, prefix: "7a7a0000"), turnSeq: turn, state: state, lastLiveState: live,
            cancelRequestedAt: cancelRequested ? at(1) : nil
        )
    }

    static func run(session: Int, turn: Int = 1, action: UUID, kind: String = "conversation") -> AgentSessionRunRecord {
        AgentSessionRunRecord(id: id(session * 100 + turn, prefix: "7a7a0000"), kind: kind, agentSessionID: id(session), actionID: action)
    }

    static func conversation(_ n: Int, session: Int) -> AgentSessionConversationRecord {
        AgentSessionConversationRecord(id: id(n, prefix: "d0d00000"), agentSessionID: id(session))
    }

    static func issue(_ n: Int) -> UUID { id(n, prefix: "a0000000") }

    /// 한 세션 · 한 task · 한 이슈의 읽기
    static func snapshot(
        status: AgentSessionStatus = .bound, state: AgentTaskState? = nil, cancelRequested: Bool = false, pending: Bool = false,
        connection: UUID = claudeConnection, name: String = "Pricing"
    ) -> AgentSessionSnapshot {
        AgentSessionSnapshot(
            sessions: [session(1, name: name, status: status, connection: connection, pending: pending)],
            tasks: state.map { [task(1, state: $0, cancelRequested: cancelRequested)] } ?? [],
            runs: [run(session: 1, action: issue(1))], connections: connections, conversations: []
        )
    }

    static func item(_ snapshot: AgentSessionSnapshot, doneObservedAt: Date? = nil, now: Date = t0) -> AgentSessionItem {
        let observed = doneObservedAt.map { [snapshot.sessions[0].id: $0] } ?? [:]
        return AgentSessionRules.items(snapshot: snapshot, doneObservedAt: observed, now: now)[0]
    }
}
