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

/// 턴의 끝 줄: 일한 시간(왼쪽, 10초 미만 · 시각 없음이면 nil) + 복사할 글(마지막 답, 없으면 nil)
public struct SessionFooter: Equatable, Identifiable, Sendable {
    public var id: String
    public var workedFor: TimeInterval?
    public var copyText: String?

    public init(id: String, workedFor: TimeInterval?, copyText: String?) {
        self.id = id
        self.workedFor = workedFor
        self.copyText = copyText
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
        var entries: [SessionEntry] = []
        for (index, turn) in turns.enumerated() {
            let isLast = index == turns.count - 1
            let running = isLast && state == .running
            let first = entries.count
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
            // 복사할 글 = 턴의 **마지막 답** (비면 복사는 없다: 앞의 답을 대신 복사하지 않는다)
            let copyAnswer = turn.last(where: { $0.role == .assistant }).flatMap { answer in
                answer.text.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } == true ? answer : nil
            }
            let answerEndsTheTurn = copyAnswer != nil && copyAnswer?.id == turn.last?.id
            for item in turn {
                if item.role == .step {
                    pending.append(item)
                } else {
                    flush()
                    entries.append(.item(item.id))
                    // 답 뒤에 단계 · 이벤트 줄이 이어지면 복사 아이콘은 그 답 바로 밑에 선다 (복사만). 시간은 턴의 끝에 따로 선다. 도는 턴에는 줄이 없다
                    if !running, !answerEndsTheTurn, let answer = copyAnswer, answer.id == item.id, let text = answer.text {
                        entries.append(.footer(SessionFooter(id: "footer-\(answer.id)", workedFor: nil, copyText: text)))
                    }
                }
            }
            flush()
            if running, let lastRun = entries[first...].lastIndex(where: { if case .steps = $0 { true } else { false } }), case .steps(var run) = entries[lastRun] {
                run.isLive = true
                entries[lastRun] = .steps(run)
            }
            guard let head = turn.first, let last = turn.last else { continue }
            let start = head.role == .user ? head.time : nil
            if running {
                if let start { entries.append(.clock(SessionClock(id: "clock-\(head.id)", since: start))) }
                continue
            }
            let elapsed = SessionTime.elapsed(from: start, to: turn.compactMap(\.time).max())
            let workedFor = elapsed.flatMap { $0 >= SessionTime.hideBelow ? $0 : nil }
            if answerEndsTheTurn, let answer = copyAnswer {
                // 답이 턴의 끝: 한 줄에 시간과 복사 (v2 그림)
                entries.append(.footer(SessionFooter(id: "footer-\(answer.id)", workedFor: workedFor, copyText: answer.text)))
            } else if workedFor != nil {
                // 답 뒤에 단계 · 이벤트가 있거나 답이 없다: 시간만 턴의 끝에 (복사는 있으면 답 바로 밑에 이미 섰다)
                entries.append(.footer(SessionFooter(id: "footer-\(last.id)", workedFor: workedFor, copyText: nil)))
            }
        }
        return entries
    }
}
#endif
