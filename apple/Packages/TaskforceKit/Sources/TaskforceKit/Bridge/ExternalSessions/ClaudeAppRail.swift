#if os(macOS)
import Foundation

/// 레일에 오른 데스크톱 세션 하나 (PR-D1 Kit, 계약 21.2 DR-S1b)
public struct ClaudeAppRailEntry: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case running
        case needsYou(ClaudeAppWait)
        case done
    }

    /// Claude 세션 id
    public let id: String
    public var kind: Kind
    /// running · needsYou는 상태가 바뀐 시각(등록 파일), done은 Taskforce가 끝난 것을 본 시각
    public var since: Date?

    public init(id: String, kind: Kind, since: Date?) {
        self.id = id
        self.kind = kind
        self.since = since
    }
}

/// Taskforce가 본 것의 기억 (메모리에만): 일하던 세션과 막 끝난 세션. 판정 함수가 값으로 주고받는다
public struct ClaudeAppRailMemory: Equatable, Sendable {
    /// 마지막으로 본 상태가 busy · waiting인 세션
    var active: Set<String> = []
    /// done으로 본 시각
    var doneSince: [String: Date] = [:]

    public init() {}
}

/// 무엇이 레일에 오르나 (DR-S1b, 사용자 승인 2026-10-22): `busy` → running, `waiting` → needsYou(approval · answer),
/// 일하던(busy · waiting) 세션이 쉬게 된 것을 **Taskforce가 본 뒤** 아직 열어 보지 않았으면 done(`doneHold` 동안). 쉬는 세션(idle)은 레일에 없다 — 처음부터 쉬던 세션도 마찬가지다.
/// 순수 함수다: 기억을 값으로 받고 새 기억을 값으로 돌려준다 (파일 · 시계 · 프로세스를 만지지 않는다). 레일 칸의 수 · 순서 규칙(`RailOrdering`)은 Mac 앱의 일이다.
public enum ClaudeAppRail {
    /// Done 링이 머무는 시간: Taskforce 세션의 Done 링과 같다
    public static let doneHold: TimeInterval = AgentSessionRules.doneHold

    public struct Result: Equatable, Sendable {
        /// needs-you → running → done, 같은 종류 안에서는 새것 먼저 (같은 시각이면 id)
        public var entries: [ClaudeAppRailEntry]
        public var memory: ClaudeAppRailMemory
    }

    /// - sessions: 지금 살아 있고 믿는 데스크톱 세션들 (`ClaudeAppStatusPoller.Poll.sessions`). 여기 없는 세션(프로세스가 끝남)은 기억에서도 지운다
    /// - opened: 사용자가 Taskforce에서 열어 둔(또는 방금 연) 세션 id: 그 세션의 done은 오르지 않고 오른 것도 바로 내린다
    public static func evaluate(sessions: [ClaudeAppSession], memory: ClaudeAppRailMemory, now: Date, opened: Set<String> = []) -> Result {
        var next = ClaudeAppRailMemory()
        var entries: [ClaudeAppRailEntry] = []
        for session in sessions {
            let id = session.id
            switch session.state {
            case .busy:
                entries.append(ClaudeAppRailEntry(id: id, kind: .running, since: session.statusUpdatedAt))
                next.active.insert(id)
            case .waiting(let wait):
                entries.append(ClaudeAppRailEntry(id: id, kind: .needsYou(wait), since: session.statusUpdatedAt))
                next.active.insert(id)
            case .idle, .unknown:
                // unknown은 아무것도 알려 주지 않는다: 읽기가 잠깐 흔들려도 일하던 세션의 끝을 놓치지 않게 기억을 그대로 둔다
                var active = memory.active.contains(id)
                var done = memory.doneSince[id]
                if session.state == .idle, active {
                    active = false
                    done = now
                }
                // 열려 있는(방금 연) 세션: done이 오르지 않고 이미 오른 것도 내린다
                if opened.contains(id) { done = nil }
                // 시계가 뒤로 가도(음수) 채우기 전에는 내리지 않는다
                if let since = done, now.timeIntervalSince(since) < doneHold {
                    entries.append(ClaudeAppRailEntry(id: id, kind: .done, since: since))
                    next.doneSince[id] = since
                }
                if active { next.active.insert(id) }
            }
        }
        entries.sort { lhs, rhs in
            let (l, r) = (rank(lhs.kind), rank(rhs.kind))
            if l != r { return l < r }
            let (lt, rt) = (lhs.since ?? .distantPast, rhs.since ?? .distantPast)
            return lt != rt ? lt > rt : lhs.id < rhs.id
        }
        return Result(entries: entries, memory: next)
    }

    private static func rank(_ kind: ClaudeAppRailEntry.Kind) -> Int {
        switch kind {
        case .needsYou: 0
        case .running: 1
        case .done: 2
        }
    }
}
#endif
