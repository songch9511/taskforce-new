#if os(macOS)
import Foundation

/// 한 줄(`SessionEntry.item`)이 그리는 것
public enum SavedChatItem: Equatable, Sendable {
    /// 보낸 말: 쓴 그대로 (서식 없음), 밑에 "Received · via Taskforce"
    case sent(text: String)
    /// 답: 세션 보기와 같은 **안전한 서식**(`SafeMarkdown`: 코드 · 목록 · 굵게, 링크 · 표 · 이미지 · HTML은 글자 그대로)으로 그린다. 계약 27장 Q-D3v4가 DZ 그림의 "글자 그대로"를 바꿨다.
    /// `markdown`은 원문(복사할 글)이다. `time`은 그 답을 기록한 시각 (24시간 "09:41")
    case reply(markdown: String, time: String)

    /// 안전한 서식으로 그리나 (답만)
    public var rendersMarkdown: Bool {
        if case .reply = self { true } else { false }
    }

    /// 보낸 말 밑의 전달 줄 (저장은 "Received" 뒤에만 되므로 모두 이 줄이다)
    public static let deliveryLine = MessageDeliveryLine(strong: nil, text: ClaudeAppChatCopy.receivedViaTaskforce)
}

/// 저장된 대화를 세션 보기의 줄로 (`SessionEntriesView`가 그린다). 같은 순수 규칙(`SessionTimeline`)을 쓰되 **시각을 넣지 않는다**:
/// 저장된 것은 기록이지 일하는 세션이 아니라서 "Worked for" · 도는 시계 · 답 밑 복사 줄(`SessionFooter`)이 서지 않는다 (시각 · 복사는 답 줄이 스스로 그린다).
/// 도구는 **이름뿐인** 단계 줄이다 (입력 · 결과 · 파일 이름 · 펼침 없음): 네 개부터 이름 한 줄로 접힌다
public struct SavedChatTimeline: Equatable, Sendable {
    public let entries: [SessionEntry]
    public let steps: [String: SessionStepInfo]
    public let items: [String: SavedChatItem]
    private let dayLabels: [String: String]

    /// 이 말 위의 날짜 줄 ("Oct 21" · "Yesterday" · "Today"): 첫 말 위와 날이 바뀐 곳에만 있다 (없으면 nil)
    public func dayLabel(of itemID: String) -> String? { dayLabels[itemID] }

    public static func make(_ messages: [SavedChatMessage], now: Date, timeZone: TimeZone = .current) -> SavedChatTimeline {
        var timelineItems: [SessionTimelineItem] = []
        var steps: [String: SessionStepInfo] = [:]
        var items: [String: SavedChatItem] = [:]
        var dayLabels: [String: String] = [:]
        let today = LocalDate(date: now, timeZone: timeZone)
        var previousDay: LocalDate?
        for message in messages {
            let id = message.id.uuidString
            let day = LocalDate(date: message.saidAt, timeZone: timeZone)
            if day != previousDay { dayLabels[id] = DueText.short(day, today: today) }
            previousDay = day
            switch message.role {
            case .user:
                timelineItems.append(SessionTimelineItem(id: id, role: .user))
                items[id] = .sent(text: message.body)
            case .assistant:
                // 이 답 앞에서 쓴 도구 이름들이 먼저 선다 (이름뿐)
                for (index, name) in message.toolNames.enumerated() {
                    let stepID = "\(id)-tool-\(index)"
                    timelineItems.append(SessionTimelineItem(id: stepID, role: .step, stepName: name))
                    steps[stepID] = SessionStepInfo(name: name, target: nil, failed: false, canExpand: false)
                }
                timelineItems.append(SessionTimelineItem(id: id, role: .assistant))
                // 상한에서 잘린 글은 끝에 말줄임을 붙인다 (세션 보기의 `ClaudeAppTurnView.shown`과 같다)
                items[id] = .reply(markdown: message.truncated ? message.body + "…" : message.body, time: WhenText.time(message.saidAt, timeZone: timeZone))
            }
        }
        return SavedChatTimeline(entries: SessionTimeline.build(timelineItems, state: .finished), steps: steps, items: items, dayLabels: dayLabels)
    }
}
#endif
