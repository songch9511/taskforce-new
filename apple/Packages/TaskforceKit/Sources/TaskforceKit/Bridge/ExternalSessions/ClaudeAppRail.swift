#if os(macOS)
import Foundation

/// 레일에 오른 데스크톱 세션 하나 (PR-D1 Kit, 계약 21.2 DR-S1b). 제목은 여기 없다: 부르는 쪽(D2)이 `ExternalSessionsStore`의 줄에서 같은 Claude 세션 id로 찾아 붙인다
public struct ClaudeAppRailEntry: Identifiable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public enum Kind: Equatable, Sendable {
        case running
        case needsYou(ClaudeAppWait)
        case done
    }

    /// Claude 세션 id
    public let id: String
    public var kind: Kind
    /// running · needsYou는 상태가 바뀐 시각(등록 파일의 `statusUpdatedAt`, B 원천이면 nil), done은 Taskforce가 끝난 것을 본 시각(벽시계)
    public var since: Date?

    public init(id: String, kind: Kind, since: Date?) {
        self.id = id
        self.kind = kind
        self.since = since
    }

    /// 종류만 말한다: 세션 id를 찍지 않는다
    public var description: String { "ClaudeAppRailEntry(kind: \(kind))" }
    public var debugDescription: String { description }
}

/// Taskforce가 본 것의 기억 (메모리에만): 세션마다 (프로세스 pid, 마지막으로 일하는 것을 본 단조 시각, 막 끝난 것을 본 시각). 판정 함수가 값으로 주고받는다.
/// **(id, pid)로 알아본다**: 같은 id로 다시 시작한 프로세스는 옛 프로세스가 일하던 기억을 물려받지 않는다
public struct ClaudeAppRailMemory: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    struct Track: Equatable, Sendable {
        struct Done: Equatable, Sendable {
            /// 본 단조 시각 (머무는 시간을 잰다)
            var uptime: TimeInterval
            /// 본 벽시계 시각 (표시한다)
            var wall: Date
        }

        var pid: Int32
        /// 마지막으로 busy · waiting을 본 단조 시각. nil이면 일하던 것이 아니다
        var activeSeen: TimeInterval?
        var done: Done?
        /// 연달아 안 보인 판정 수
        var missed = 0
    }

    var tracks: [String: Track] = [:]

    public init() {}

    /// 일하던 것으로 기억하는 세션 id (시험용)
    var activeIDs: Set<String> { Set(tracks.filter { $0.value.activeSeen != nil }.keys) }

    /// 개수만 말한다: 세션 id를 찍지 않는다
    public var description: String { "ClaudeAppRailMemory(tracked: \(tracks.count))" }
    public var debugDescription: String { description }
}

/// 무엇이 레일에 오르나 (DR-S1b, 사용자 승인 2026-10-22 · 코디네이터 결정): `busy` → running, `waiting` → needsYou(approval · answer),
/// 일하던(busy · waiting) 세션이 쉬게 된 것을 **Taskforce가 본 뒤** 아직 열어 보지 않았으면 done(`doneHold` 동안). 쉬는 세션(idle)은 레일에 없다 — 처음부터 쉬던 세션도 마찬가지다.
/// `waiting → idle`도 done이다 (사용자가 답한 뒤 Claude가 끝낸 것이라 busy → idle과 같은 신호).
/// 순수 함수다: 기억을 값으로 받고 새 기억을 값으로 돌려준다 (파일 · 시계 · 프로세스를 만지지 않는다). 레일 칸의 수 · 순서 규칙(`RailOrdering`)은 Mac 앱의 일이다.
public enum ClaudeAppRail {
    /// Done 링이 머무는 시간: Taskforce 세션의 Done 링과 같은 3초
    public static let doneHold: TimeInterval = 3
    /// 마지막으로 일하는 것을 본 뒤 이 시간(초)이 지나면 "끝났다"를 새 소식으로 치지 않는다 (오래 모르던 세션 · 폴을 오래 쉰 뒤에 "Done just now"가 뜨지 않게)
    public static let activeLimit: TimeInterval = 30
    /// 판정에 연달아 이만큼(두 번)까지 안 보인 세션은 기억을 지킨다 (등록 읽기가 잠깐 흔들린 것). 넘으면 프로세스가 끝난 것이다
    public static let missingGrace = 2

    public struct Result: Equatable, Sendable {
        /// needs-you → running → done, 같은 종류 안에서는 새것 먼저 (같은 시각이면 id)
        public var entries: [ClaudeAppRailEntry]
        public var memory: ClaudeAppRailMemory
    }

    /// - sessions: 지금 살아 있고 믿는 데스크톱 세션들 (`ClaudeAppStatusPoller.Poll.sessions`)
    /// - now: 벽시계 (done의 표시 시각에만 쓴다). uptime: **단조 시간** (`ClaudeAppMonotonic.now()`): 머무는 시간 · 기억의 나이를 잰다. 벽시계가 뒤로 가도 얼지 않는다
    /// - opened: 사용자가 Taskforce에서 열어 둔(또는 방금 연) 세션 id: 그 세션의 done은 오르지 않고 오른 것도 바로 내린다
    public static func evaluate(sessions: [ClaudeAppSession], memory: ClaudeAppRailMemory, now: Date, uptime: TimeInterval, opened: Set<String> = []) -> Result {
        var next = ClaudeAppRailMemory()
        var entries: [ClaudeAppRailEntry] = []
        var present = Set<String>()
        for session in sessions {
            let id = session.id
            present.insert(id)
            // 같은 id라도 다른 프로세스(다시 시작)면 옛 기억은 이 세션의 것이 아니다
            var track = memory.tracks[id]
            if let known = track, known.pid != session.pid { track = nil }
            switch session.state {
            case .busy:
                entries.append(ClaudeAppRailEntry(id: id, kind: .running, since: session.statusUpdatedAt))
                next.tracks[id] = ClaudeAppRailMemory.Track(pid: session.pid, activeSeen: uptime, done: nil)
            case .waiting(let wait):
                entries.append(ClaudeAppRailEntry(id: id, kind: .needsYou(wait), since: session.statusUpdatedAt))
                next.tracks[id] = ClaudeAppRailMemory.Track(pid: session.pid, activeSeen: uptime, done: nil)
            case .idle, .unknown:
                // unknown은 아무것도 알려 주지 않는다: 읽기가 잠깐 흔들려도 일하던 세션의 끝을 놓치지 않게 기억을 두되, 너무 오래된 기억은 버린다
                var activeSeen = track?.activeSeen
                if let seen = activeSeen, uptime - seen > activeLimit { activeSeen = nil }
                var done = track?.done
                if session.state == .idle, activeSeen != nil {
                    activeSeen = nil
                    done = ClaudeAppRailMemory.Track.Done(uptime: uptime, wall: now)
                }
                // 열려 있는(방금 연) 세션: done이 오르지 않고 이미 오른 것도 내린다
                if opened.contains(id) { done = nil }
                if let shown = done, uptime - shown.uptime < doneHold {
                    entries.append(ClaudeAppRailEntry(id: id, kind: .done, since: shown.wall))
                } else {
                    done = nil
                }
                if activeSeen != nil || done != nil { next.tracks[id] = ClaudeAppRailMemory.Track(pid: session.pid, activeSeen: activeSeen, done: done) }
            }
        }
        // 안 보이는 세션: 줄은 없다. 두 번까지는 기억을 지킨다
        for (id, track) in memory.tracks where !present.contains(id) {
            var kept = track
            kept.missed += 1
            if kept.missed <= missingGrace { next.tracks[id] = kept }
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

extension ClaudeAppRail.Result: CustomStringConvertible, CustomDebugStringConvertible {
    /// 개수만 말한다: 세션 id를 찍지 않는다
    public var description: String { "ClaudeAppRail.Result(entries: \(entries.count), memory: \(memory))" }
    public var debugDescription: String { description }
}
#endif
