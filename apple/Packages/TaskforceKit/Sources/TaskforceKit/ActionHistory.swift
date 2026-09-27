import Foundation

/// 변경 이력 한 줄: 무엇이 바뀌었나 + 근거 인용
public struct HistoryEntry: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let date: Date
    public let actor: EventActor
    /// "기한 변경 9월 26일(금) → 9월 29일(월)"
    public let sentence: String
    /// 이 변경을 만든 원문 구절 (있을 때)
    public let quote: String?
    public let sourceID: UUID?

    public init(id: UUID, date: Date, actor: EventActor, sentence: String, quote: String?, sourceID: UUID?) {
        self.id = id
        self.date = date
        self.actor = actor
        self.sentence = sentence
        self.quote = quote
        self.sourceID = sourceID
    }
}

/// `action_events` + `evidence` → 사람이 읽는 변경 이력 (최신이 위).
/// 이벤트와 근거는 서버가 한 트랜잭션에서 같은 원문으로 쓰므로, 같은 원문의 근거 중 시각이 가장 가까운 것을 붙인다.
public enum ActionHistory {
    public static func entries(events: [ActionEventRecord], evidence: [EvidenceRecord], today: LocalDate) -> [HistoryEntry] {
        events
            .sorted { $0.createdAt > $1.createdAt }
            .map { event in
                let sourceID = event.sourceID ?? event.after?["source_id"]?.stringValue.flatMap(UUID.init(uuidString:))
                let quote = sourceID.flatMap { id in
                    evidence
                        .filter { $0.sourceID == id }
                        .min { abs($0.createdAt.timeIntervalSince(event.createdAt)) < abs($1.createdAt.timeIntervalSince(event.createdAt)) }?
                        .quote
                }
                return HistoryEntry(
                    id: event.id,
                    date: event.createdAt,
                    actor: event.actor,
                    sentence: sentence(for: event, today: today),
                    quote: quote,
                    sourceID: sourceID
                )
            }
    }

    public static func sentence(for event: ActionEventRecord, today: LocalDate) -> String {
        let before = event.before
        let after = event.after
        switch event.type {
        case "created":
            return after?["needs_confirmation"]?.boolValue == true ? "할 일로 등록 (확인 요청)" : "할 일로 등록"
        case "due_changed":
            return "기한 변경 \(due(before?["due"], today)) → \(due(after?["due"], today))"
        case "scope_changed":
            return "내용 변경 → “\(after?["title"]?.stringValue ?? "")”"
        case "owner_changed":
            return "담당 변경 \(owner(before?["owner"])) → \(owner(after?["owner"]))"
        case "merged":
            return "같은 할 일이 다시 언급됨"
        case "completed":
            return "완료로 바뀜"
        case "dropped":
            return "취소됨"
        case "reopened":
            return "다시 열림"
        case "user_edited":
            return editedSentence(before: before, after: after, today: today)
        case "user_deleted":
            return "삭제함"
        case "user_confirmed":
            return "맞다고 확인함"
        case "user_started":
            return "시작함"
        case "user_reported_missing":
            return "빠진 할 일로 신고해 추가함"
        default:
            return "변경됨"
        }
    }

    /// 사용자가 고친 필드마다 한 조각씩: "기한 고침 금 → 월, 담당 고침 미정 → 나"
    private static func editedSentence(before: JSONValue?, after: JSONValue?, today: LocalDate) -> String {
        var parts: [String] = []
        if let title = after?["title"]?.stringValue {
            parts.append("제목 고침 → “\(title)”")
        }
        if let newDue = after?["due"] {
            parts.append("기한 고침 \(due(before?["due"], today)) → \(due(newDue, today))")
        }
        if let newOwner = after?["owner"] {
            parts.append("담당 고침 \(owner(before?["owner"])) → \(owner(newOwner))")
        }
        switch after?["status"]?.stringValue {
        case "done": parts.append("완료함")
        case "open": parts.append("다시 엶")
        default: break
        }
        return parts.isEmpty ? "직접 고침" : parts.joined(separator: ", ")
    }

    private static func due(_ value: JSONValue?, _ today: LocalDate) -> String {
        guard let string = value?.stringValue, let date = LocalDate(String(string.prefix(10))) else { return "없음" }
        return DueDateFormat.label(date, today: today)
    }

    private static func owner(_ value: JSONValue?) -> String {
        value?.stringValue.flatMap(ActionOwner.init(rawValue:))?.label ?? "미정"
    }
}
