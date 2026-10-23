#if os(macOS)
import Foundation

/// 단계 줄 하나의 보이는 값: "{도구 이름} · {description | 파일 이름}", 실패(굵은 "Failed"), 펼쳐 Input · Result를 볼 수 있나
public struct SessionStepInfo: Equatable, Sendable {
    public var name: String
    /// 줄에 쓰는 대상: 모델이 쓴 description, 없으면 파일 **이름**(경로 아님). 둘 다 없으면 nil
    public var target: String?
    public var failed: Bool
    /// 이 Mac의 기록에서 그 줄을 다시 읽을 수 있다 (펼치면 Input · Result)
    public var canExpand: Bool

    public init(name: String, target: String?, failed: Bool, canExpand: Bool) {
        self.name = name
        self.target = target
        self.failed = failed
        self.canExpand = canExpand
    }

    public var line: String { SessionStepText.line(name: name, target: target) }
}

/// 한 패널이 그릴 줄들 + 단계 줄의 값 (줄 id → 값)
public struct SessionTimelineData: Equatable, Sendable {
    public var items: [SessionTimelineItem]
    public var steps: [String: SessionStepInfo]
}

/// 두 패널이 같은 규칙(`SessionTimeline`)에 먹일 줄을 만든다: Claude 패널은 기록의 줄, Taskforce 패널은 서버 대화의 글에 이 Mac 기록의 도구 단계를 시각 순으로 끼운다
public enum SessionTimelineSource {
    /// 이 Mac의 시계와 서버의 시계가 어긋나도 대화 첫 글의 이 시간(초) 앞의 단계까지는 이 대화의 것으로 본다
    public static let stepSlack: TimeInterval = 5

    // MARK: Claude 패널

    public static func claude(_ turns: [ClaudeAppTurn]) -> SessionTimelineData {
        var items: [SessionTimelineItem] = []
        var steps: [String: SessionStepInfo] = [:]
        for turn in turns {
            switch turn.kind {
            case .user, .peer:
                items.append(SessionTimelineItem(id: turn.id, role: .user, time: turn.timestamp))
            case .assistant(let text):
                items.append(SessionTimelineItem(id: turn.id, role: .assistant, time: turn.timestamp, text: turn.truncated ? text + "…" : text))
            case .tool(let name, let description):
                let info = step(turn, name: name, description: description)
                items.append(SessionTimelineItem(id: turn.id, role: .step, time: turn.timestamp, stepName: name))
                steps[turn.id] = info
            }
        }
        return SessionTimelineData(items: items, steps: steps)
    }

    private static func step(_ turn: ClaudeAppTurn, name: String, description: String?) -> SessionStepInfo {
        let described = description.flatMap { $0.isEmpty ? nil : $0 }
        return SessionStepInfo(
            name: name, target: described ?? turn.target.map(SessionStepText.shortFileName), failed: turn.failed, canExpand: turn.lineOffset >= 0 && turn.toolUseID != nil
        )
    }

    // MARK: Taskforce 패널

    /// - steps: 이 Mac의 기록에서 읽은 줄 (도구 줄만, 시각이 있는 것만 쓴다)
    public static func chat(_ turns: [ChatTurn], steps localSteps: [ClaudeAppTurn]) -> SessionTimelineData {
        let chatItems = turns.map { turn -> SessionTimelineItem in
            let id = turn.id.uuidString
            if turn.isUser { return SessionTimelineItem(id: id, role: .user, time: turn.createdAt) }
            if turn.isEvent { return SessionTimelineItem(id: id, role: .other, time: turn.createdAt) }
            return SessionTimelineItem(id: id, role: .assistant, time: turn.createdAt, text: turn.textDeleted ? nil : turn.visibleText)
        }
        guard let first = turns.first?.createdAt else { return SessionTimelineData(items: [], steps: [:]) }
        // 사용자의 말마다 덩어리 하나 (첫 말 앞의 글들은 시작을 모르는 덩어리). 단계는 **시각이 든 창의 덩어리**의 것이다:
        // 덩어리의 창은 그 첫 글의 시각 − `stepSlack`부터 다음 덩어리의 창 앞까지. 이 Mac의 시계가 서버보다 조금 늦어도 말 바로 뒤의 단계가 앞 턴으로 새지 않는다.
        // 첫 창보다 이른 단계는 이 대화의 것이 아니다 (입양한 세션의 지난 기록이 패널을 덮지 않게)
        var groups: [[SessionTimelineItem]] = []
        for item in chatItems {
            if item.role == .user || groups.isEmpty { groups.append([item]) } else { groups[groups.count - 1].append(item) }
        }
        let anchors = groups.map { $0.first?.time ?? first }
        let windowStarts = anchors.map { $0.addingTimeInterval(-stepSlack) }
        var perGroup = [[(order: Int, item: SessionTimelineItem)]](repeating: [], count: groups.count)
        var infos: [String: SessionStepInfo] = [:]
        for (order, turn) in localSteps.enumerated() {
            guard case .tool(let name, let description) = turn.kind, let time = turn.timestamp, let index = windowStarts.lastIndex(where: { $0 <= time }) else { continue }
            // 창 안이지만 말보다 이른 시각의 단계는 그 말과 같은 시각으로 본다 (그 사용자의 말 바로 뒤)
            perGroup[index].append((order, SessionTimelineItem(id: turn.id, role: .step, time: max(time, anchors[index]), stepName: name)))
            infos[turn.id] = step(turn, name: name, description: description)
        }
        var merged: [SessionTimelineItem] = []
        for (index, group) in groups.enumerated() {
            let steps = perGroup[index].sorted { a, b in
                let ta = a.item.time ?? .distantPast, tb = b.item.time ?? .distantPast
                return ta != tb ? ta < tb : a.order < b.order
            }.map(\.item)
            var next = 0
            for item in group {
                while next < steps.count, comesBefore(steps[next], item) {
                    merged.append(steps[next])
                    next += 1
                }
                merged.append(item)
            }
            merged += steps[next...]
        }
        return SessionTimelineData(items: merged, steps: infos)
    }

    /// 단계가 대화의 글 앞인가: 더 이르거나, 같은 시각이면 사용자의 말 뒤 · 답 앞
    private static func comesBefore(_ step: SessionTimelineItem, _ message: SessionTimelineItem) -> Bool {
        guard let stepTime = step.time, let messageTime = message.time else { return false }
        return stepTime < messageTime || (stepTime == messageTime && message.role != .user)
    }

    // MARK: 진행 상태

    public static func runState(_ status: ClaudeAppLiveStatus?, closed: Bool) -> SessionRunState {
        guard !closed, let status else { return .finished }
        switch status {
        case .running: return .running
        case .needsApproval, .needsAnswer: return .frozen
        case .done, .idle: return .finished
        }
    }

    public static func runState(task state: AgentTaskState?, closed: Bool) -> SessionRunState {
        guard !closed, let state else { return .finished }
        switch state {
        case .dispatched, .accepted, .running: return .running
        case .awaitingAnswer: return .frozen
        default: return .finished
        }
    }
}
#endif
