#if os(macOS)
import Foundation

// 세션 보기 V1의 순수 규칙 (DZ oa-session-view-dz v2 E2 · E3 · E5 · E6): 연속한 도구 단계를 묶고, 턴마다 일한 시간과 답 밑 줄(복사)을 정하고, 도는 턴의 시계를 둔다.
// 입력은 Claude 패널(기록의 줄)이든 Taskforce 패널(대화의 글 + 이 Mac 기록의 단계)이든 같은 모양의 줄이다. 화면은 이 순서를 그대로 그린다. 파일 · 서버 · 시계를 만지지 않는다.

/// 한 줄 (사용자의 말 · 어시스턴트의 말 · 도구 단계 · 그 밖의 줄(이벤트 등))
public struct SessionTimelineItem: Equatable, Sendable {
    public enum Role: Equatable, Sendable {
        case user
        case assistant
        case step
        case other
    }

    /// 화면이 이 줄을 찾는 열쇠: 입력 안에서 겹치지 않는다
    public var id: String
    public var role: Role
    public var time: Date?
    /// 어시스턴트의 말의 원문 (복사할 글)
    public var text: String?
    /// 도구 단계의 도구 이름 (묶음 줄에 쓴다)
    public var stepName: String?

    public init(id: String, role: Role, time: Date? = nil, text: String? = nil, stepName: String? = nil) {
        self.id = id
        self.role = role
        self.time = time
        self.text = text
        self.stepName = stepName
    }
}

/// 마지막 턴이 지금 어떤 상태인가 (앞 턴은 모두 끝난 것으로 본다)
public enum SessionRunState: Equatable, Sendable {
    /// 일하지 않는다
    case finished
    /// 일하는 중: 맨 아래에 시계가 있고 마지막 묶음이 열려 있다
    case running
    /// 승인 · 답을 기다린다: 시계는 멈춘 값으로 "Worked for …"를 보인다
    case frozen
}

/// 이어진 도구 단계 하나의 덩어리. 네 개부터 `isGroup`(접힌 한 줄), 세 개 이하는 줄 그대로
public struct SessionStepRun: Equatable, Identifiable, Sendable {
    /// 첫 단계의 id: 단계가 늘어도 묶음의 정체가 그대로다
    public var id: String
    public var stepIDs: [String]
    /// 접힌 줄: 도구 이름을 처음 쓴 순서로 " · "
    public var label: String
    public var isGroup: Bool
    /// 도는 턴의 마지막 덩어리 (묶음이면 열려 있는 것이 기본이다)
    public var isLive: Bool
}

/// 끝난 턴의 줄: 일한 시간(10초 미만 · 시각 없음이면 nil) 또는 복사할 글(마지막 답)이다.
/// 답이 있으면 시간 줄(`aboveAnswer`)은 그 답 **바로 위**에, 복사 줄은 답 **바로 밑**에 따로 선다. 답이 없는 턴의 시간 줄은 턴의 끝에 선다
public struct SessionFooter: Equatable, Identifiable, Sendable {
    public var id: String
    public var workedFor: TimeInterval?
    public var copyText: String?
    /// 시간 줄이 답 바로 위에 선다 (아니면 복사 줄이거나 답 없는 턴의 끝 줄이다)
    public var aboveAnswer: Bool

    public init(id: String, workedFor: TimeInterval?, copyText: String?, aboveAnswer: Bool = false) {
        self.id = id
        self.workedFor = workedFor
        self.copyText = copyText
        self.aboveAnswer = aboveAnswer
    }
}

/// 도는 턴의 시계 줄 "Working · m:ss": 시작 시각부터 센다 (화면이 초마다 그린다)
public struct SessionClock: Equatable, Identifiable, Sendable {
    public var id: String
    public var since: Date

    public init(id: String, since: Date) {
        self.id = id
        self.since = since
    }
}

public enum SessionEntry: Equatable, Identifiable, Sendable {
    /// 입력의 한 줄 (사용자 · 어시스턴트 · 그 밖)
    case item(String)
    case steps(SessionStepRun)
    case footer(SessionFooter)
    case clock(SessionClock)

    public var id: String {
        switch self {
        case .item(let id): id
        case .steps(let run): run.id
        case .footer(let footer): footer.id
        case .clock(let clock): clock.id
        }
    }
}

public enum SessionTimeline {
    /// 연속한 단계가 이만큼 이상이면 접힌 한 줄 (세 개 이하는 줄 그대로)
    public static let groupThreshold = 4
    /// 열린 묶음 안에서 보이는 최근 줄 수 (앞은 Show all 뒤에 있다)
    public static let visibleRecent = 6
    /// 한꺼번에 그리는 줄(entry)의 수: 본문이 즉시 쌓기라 처음 배치가 줄 수에 비례한다. 처음엔 가장 새 이만큼만, "Show earlier"를 한 번 누를 때마다 이만큼씩 더 (#187 핫픽스)
    public static let renderWindow = 150

    /// 이 자리가 한 덩어리(말 · 단계 묶음 · 답과 그 위 "Worked for" · 답 밑 복사 줄)의 **첫 줄**인가. 창이 여기서 시작해도 덩어리가 둘로 쪼개지지 않는다.
    /// 첫 줄이 될 수 없는 것: 답 밑 복사 줄 · 턴 끝 시간 줄(앞 덩어리의 꼬리), 답 위 "Worked for" 줄 바로 뒤의 답(그 줄과 한 덩어리), 도는 시계(턴의 꼬리). 단계 묶음은 줄 하나라 어디서나 통째다
    public static func startsUnit(_ entries: [SessionEntry], at index: Int) -> Bool {
        guard entries.indices.contains(index) else { return false }
        switch entries[index] {
        case .steps: return true
        case .footer(let footer): return footer.aboveAnswer
        case .clock: return false
        case .item:
            if index > 0, case .footer(let footer) = entries[index - 1], footer.aboveAnswer { return false }
            return true
        }
    }

    /// 가장 새 `limit`개만 그릴 때의 첫 줄 자리: `entries.count - limit`에서 시작하되 덩어리 한가운데면 **뒤로**(더 새 쪽으로) 밀어 첫 줄이 되는 자리까지 간다 (그려지는 줄은 `limit`개를 넘지 않는다).
    /// 줄이 `limit` 이하면 0
    public static func windowStart(_ entries: [SessionEntry], limit: Int) -> Int {
        guard limit > 0, entries.count > limit else { return 0 }
        let cut = entries.count - limit
        for index in cut..<entries.count where startsUnit(entries, at: index) { return index }
        // 끝까지 첫 줄이 될 자리가 없다 (마지막 덩어리가 한 줄 남짓): 앞쪽으로 물러난다 (한도보다 조금 더 그린다)
        return unitStart(entries, atOrBefore: cut)
    }

    /// `index` 이하에서 가장 가까운 덩어리의 첫 줄 자리 ("Show earlier"가 창을 앞으로 넓힐 때: 덩어리를 쪼개지 않으려고 앞쪽으로 맞춘다). 범위 밖은 끝 · 처음으로 맞추고, 없으면 0
    public static func unitStart(_ entries: [SessionEntry], atOrBefore index: Int) -> Int {
        guard !entries.isEmpty else { return 0 }
        var current = min(max(index, 0), entries.count - 1)
        while current > 0 {
            if startsUnit(entries, at: current) { return current }
            current -= 1
        }
        return 0
    }

    /// 턴 = 사용자의 말 하나부터 다음 사용자의 말 직전까지 (첫 사용자의 말 앞의 줄은 시작을 모르는 한 턴)
    public static func build(_ items: [SessionTimelineItem], state: SessionRunState) -> [SessionEntry] {
        var turns: [[SessionTimelineItem]] = []
        for item in items {
            if item.role == .user || turns.isEmpty {
                turns.append([item])
            } else {
                turns[turns.count - 1].append(item)
            }
        }
        /// 턴 안에서 놓을 것: 항목 아니면 줄
        enum Piece {
            case item(SessionTimelineItem)
            case footer(SessionFooter)
        }
        var entries: [SessionEntry] = []
        for (index, turn) in turns.enumerated() {
            guard let head = turn.first, let last = turn.last else { continue }
            let isLast = index == turns.count - 1
            let running = isLast && state == .running
            let first = entries.count
            let start = head.role == .user ? head.time : nil
            // 일한 시간: 끝난 턴만 (도는 턴은 시계가 센다). 10초 미만 · 시각을 모르면 없다
            let elapsed = SessionTime.elapsed(from: start, to: turn.compactMap(\.time).max())
            let workedFor = running ? nil : elapsed.flatMap { $0 >= SessionTime.hideBelow ? $0 : nil }
            // 복사할 글 = 턴의 **마지막 답** (비면 복사는 없다: 앞의 답을 대신 복사하지 않는다)
            let answerIndex = turn.lastIndex(where: { $0.role == .assistant })
            let copyAnswer = answerIndex.flatMap { index in
                turn[index].text.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } == true ? turn[index] : nil
            }
            var pieces: [Piece] = []
            if !running, let answer = copyAnswer, let answerIndex {
                // 끝난 턴 (사용자 결정 2026-10-23): 단계 · 이벤트 줄 → "Worked for …"(시간만) → 마지막 답 → 복사 아이콘(답 바로 밑).
                // 마지막 답 뒤에 이어진 단계는 시간 줄 앞으로 올라온다 (단계끼리의 순서는 그대로). 답 뒤의 이벤트 줄은 시간순 그대로 복사 뒤에 선다
                let after = turn[(answerIndex + 1)...]
                pieces += turn[..<answerIndex].map(Piece.item)
                pieces += after.filter { $0.role == .step }.map(Piece.item)
                if let workedFor { pieces.append(.footer(SessionFooter(id: "worked-\(answer.id)", workedFor: workedFor, copyText: nil, aboveAnswer: true))) }
                pieces.append(.item(answer))
                pieces.append(.footer(SessionFooter(id: "footer-\(answer.id)", workedFor: nil, copyText: answer.text)))
                pieces += after.filter { $0.role != .step }.map(Piece.item)
            } else {
                // 도는 턴(시계가 끝에 선다) 또는 답이 없는 턴(시간은 턴의 끝에)
                pieces = turn.map(Piece.item)
                if let workedFor { pieces.append(.footer(SessionFooter(id: "footer-\(last.id)", workedFor: workedFor, copyText: nil))) }
            }
            var pending: [SessionTimelineItem] = []
            func flush() {
                guard let head = pending.first else { return }
                let run = SessionStepRun(
                    id: head.id, stepIDs: pending.map(\.id), label: SessionStepText.groupLabel(names: pending.compactMap(\.stepName)),
                    isGroup: pending.count >= groupThreshold, isLive: false
                )
                entries.append(.steps(run))
                pending = []
            }
            for piece in pieces {
                switch piece {
                case .item(let item):
                    if item.role == .step {
                        pending.append(item)
                    } else {
                        flush()
                        entries.append(.item(item.id))
                    }
                case .footer(let footer):
                    flush()
                    entries.append(.footer(footer))
                }
            }
            flush()
            if running {
                if let lastRun = entries[first...].lastIndex(where: { if case .steps = $0 { true } else { false } }), case .steps(var run) = entries[lastRun] {
                    run.isLive = true
                    entries[lastRun] = .steps(run)
                }
                if let start { entries.append(.clock(SessionClock(id: "clock-\(head.id)", since: start))) }
            }
        }
        return entries
    }
}
#endif
