import Foundation

/// 복귀 요약의 글자. SSOT 고정 문구(`Since …` · `Clear` · `Needs your answer` · `Next: …`)와 앱에 이미 있는 문구를 쓰고,
/// 새 문구는 최소로 둔다 (`c3-mac-notes.md`에 모두 적고 승인을 받는다). 서버는 토큰만 주고 문구를 만들지 않는다.
/// 숫자(개수)는 어디에도 없다 (디자인 D-12).
public enum ReturnSummaryCopy {
    // MARK: SSOT 고정 문구
    public static let clear = "Clear"
    public static let needsYourAnswer = ReviewCopy.needsYourAnswer
    /// 줄의 보조 글을 잇는 구분 (SSOT `Needs your answer · change`)
    public static let separator = " · "

    // MARK: 기존 앱 문구 재사용
    public static let tryAgain = "Try again"
    /// 지운 원문 (Remembered와 같은 말)
    public static let sourceDeleted = MemoryCopy.purgedStatement
    /// 접근 상실 (Remembered와 같은 말)
    public static let sourceUnavailable = MemoryCopy.sourceMissing
    /// 보관 만료 (초안 본문 `DraftBody.purgedMessage`와 같은 말, TaskforceUI 시험이 같음을 확인한다)
    public static let sourceExpired = "Text deleted after 90 days."
    /// run 결과 (`RunLaneText`와 같은 말)
    public static let runDraftReady = "Draft ready"
    public static let runQuestion = "Taskforce has a question"
    public static let runNeedsConnection = "Needs a connection"
    public static let runFailed = "Couldn't finish the draft"

    // MARK: 새 문구 (승인 필요)
    /// 카드 캡션: 마지막 Clear 시각을 모를 때 (`since == nil`). 시각을 지어내지 않는다 (첫 기준 시각은 열린 제품 결정)
    public static let changesTitle = "Changes"
    /// 변화 원천을 읽지 못했다 (또는 읽은 뒤 다시 읽지 못했다): 비어 있다고 말하지 않는다
    public static let couldNotLoad = "Couldn't load changes"
    /// 결정 대기를 읽지 못했다: `Needs your answer`가 빠졌을 수 있다
    public static let couldNotLoadDecisions = "Couldn't load decisions"
    /// 잘렸거나 이 앱이 읽지 못하는 값이 있다: 보이지 않는 변화가 있을 수 있다 (개수를 말하지 않는다)
    public static let someNotShown = "Some changes aren't shown"
    /// 끝난 결과를 볼 차례. (SSOT 예시는 "Next: accept the result"이지만 accept는 S4b라 지금 할 수 있는 말은 review다)
    public static let nextReviewResult = "Next: review the result"
    public static let actionEventDueChanged = "Due date changed"
    public static let actionEventScopeChanged = "Details changed"
    public static let actionEventOwnerChanged = "Owner changed"
    public static let actionEventMerged = "Mentioned again"
    public static let actionEventCompleted = "Completed"
    public static let actionEventDropped = "Canceled"
    public static let actionEventReopened = "Reopened"
    public static let runReviewFailed = "Review failed"
    public static let runAgentDone = "Agent finished"
    public static let runFinished = "Run finished"
    public static let messageAssistant = "New reply"
    public static let messageEvent = "New update"

    /// 카드 캡션 `Since <since>`. 날짜는 앱의 기존 표기(`WhenText`: 오늘/어제 24시간제, 그 밖은 `Oct 9`)에서 오늘/어제의 첫 글자만 소문자로 (SSOT "yesterday, 6:40 PM"의 문장 속 모양).
    /// `since == nil`이면 시각을 지어내지 않고 `Changes`다
    public static func title(since: Date?, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        guard let since else { return changesTitle }
        let label = WhenText.label(since, now: now, timeZone: timeZone)
        let inSentence = (label.hasPrefix("Today ") || label.hasPrefix("Yesterday ")) ? label.prefix(1).lowercased() + label.dropFirst() : label
        return "Since " + inSentence
    }

    /// 변화 하나의 글 (모르는 토큰은 nil: 줄은 제목만 보인다)
    public static func change(_ change: ReturnSummaryChange) -> String? {
        var parts: [String] = []
        if let base = base(change) { parts.append(base) }
        if change.source == .actionEvent, let state = change.sourceState, let phrase = sourceState(state) { parts.append(phrase) }
        return parts.isEmpty ? nil : parts.joined(separator: separator)
    }

    private static func base(_ change: ReturnSummaryChange) -> String? {
        switch change.source {
        case .actionEvent:
            switch change.kind {
            case "due_changed": return actionEventDueChanged
            case "scope_changed": return actionEventScopeChanged
            case "owner_changed": return actionEventOwnerChanged
            case "merged": return actionEventMerged
            case "completed": return actionEventCompleted
            case "dropped": return actionEventDropped
            case "reopened": return actionEventReopened
            case "artifact_created": return runDraftReady
            default: return nil
            }
        case .run:
            switch change.kind {
            case "failed": return runFailed
            case "done":
                switch change.detail {
                case "draft_ready": return runDraftReady
                case "needs_input": return runQuestion
                case "needs_connection", "needs_capability": return runNeedsConnection
                case "review_failed": return runReviewFailed
                case "agent_done": return runAgentDone
                default: return runFinished
                }
            default: return nil
            }
        case .message:
            switch change.kind {
            case "assistant": return messageAssistant
            case "event": return messageEvent
            default: return nil
            }
        case .unknown:
            return nil
        }
    }

    /// 원문 상태 토큰의 글: 지운 원문 · 접근 상실 · 보관 만료를 글이나 옛 제목으로 되살리지 않고 이 말로만. `available`은 말이 없다
    public static func sourceState(_ state: ReturnSummarySourceState) -> String? {
        switch state {
        case .deleted: sourceDeleted
        case .accessLost: sourceUnavailable
        case .textExpired: sourceExpired
        case .available, .unknown: nil
        }
    }

    /// Next 줄: 끝난 결과를 볼 차례일 때만. `answer`는 `Needs your answer` 강조가 이미 말하고, `open`은 줄 자체가 이미 그 작업을 연다
    public static func next(_ next: ReturnSummaryNext) -> String? {
        next.kind == .reviewResult ? nextReviewResult : nil
    }

    /// 줄 하나가 말하는 변화 말의 수: 서로 다른 말을 시간 순서대로 모아 가장 최근 셋. 개수는 말하지 않는다 (줄을 열면 그 작업이 있다)
    static let visibleChanges = 3

    /// 줄의 보조 글: [`Needs your answer`] · 변화들 · [`Next: …`]. 변화는 시간 순서 그대로, 같은 말은 한 번만, 가장 최근 셋
    static func detail(_ item: ReturnSummaryItem) -> String? {
        var changes: [String] = []
        for text in item.changes.compactMap(Self.change) where !changes.contains(text) {
            changes.append(text)
        }
        var parts: [String] = []
        if item.needsAnswer { parts.append(needsYourAnswer) }
        parts.append(contentsOf: changes.suffix(visibleChanges))
        if let next = next(item.next) { parts.append(next) }
        return parts.isEmpty ? nil : parts.joined(separator: separator)
    }
}

/// 복귀 요약 한 줄: StatusMark · 제목 · 보조 글 (강조 구절은 `Needs your answer`)
public struct ReturnSummaryRow: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let title: String
    /// nil = 표시 없음 (취소된 작업 · 모르는 상태)
    public let progress: ReturnSummaryProgress?
    public let needsAnswer: Bool
    public let detail: String?
    /// 줄을 누르면 그 작업으로 간다. 목록에 없는 작업(지난 완료 · 취소)은 열 곳이 없으므로 누를 수 없는 줄이다 (거짓 어포던스 없음)
    public let canOpen: Bool

    /// 강조할 구절 (`detail` 안의 `Needs your answer`). 없으면 강조 없음
    public var highlight: String? { needsAnswer ? ReturnSummaryCopy.needsYourAnswer : nil }

    public init(id: UUID, title: String, progress: ReturnSummaryProgress?, needsAnswer: Bool, detail: String?, canOpen: Bool = true) {
        self.id = id
        self.title = title
        self.progress = progress
        self.needsAnswer = needsAnswer
        self.detail = detail
        self.canOpen = canOpen
    }
}

/// 화면이 그릴 복귀 요약. 줄이 있으면 Card, 줄이 없고 노트만 있으면 노트만 (읽지 못했다고 말한다)
public struct ReturnSummaryContent: Equatable, Sendable {
    /// 줄 밑의 정직한 한 줄 (비어 있다는 말이 아니라 **모른다 · 일부만 보인다**는 말)
    public enum Note: Equatable, Sendable {
        case couldNotLoad
        case couldNotLoadDecisions
        case someNotShown

        public var text: String {
            switch self {
            case .couldNotLoad: ReturnSummaryCopy.couldNotLoad
            case .couldNotLoadDecisions: ReturnSummaryCopy.couldNotLoadDecisions
            case .someNotShown: ReturnSummaryCopy.someNotShown
            }
        }

        /// 다시 읽을 수 있는 노트 (Try again)
        public var offersRetry: Bool { self != .someNotShown }
    }

    public let title: String
    public let rows: [ReturnSummaryRow]
    public let notes: [Note]
    /// Clear 버튼: 서버가 커서를 줬고 읽음 처리할 변화가 보일 때만 (`ReturnSummaryPresentation.canClear`)
    public let canClear: Bool
    public let isClearing: Bool
    /// Clear 뒤 안내 한 줄 (충돌 · 실패)
    public let message: String?

    public var showsCard: Bool { !rows.isEmpty }

    public init(title: String, rows: [ReturnSummaryRow], notes: [Note] = [], canClear: Bool = false, isClearing: Bool = false, message: String? = nil) {
        self.title = title
        self.rows = rows
        self.notes = notes
        self.canClear = canClear
        self.isClearing = isClearing
        self.message = message
    }
}

public enum ReturnSummaryPresentation {
    /// Clear를 보일 조건. 서버 커서가 있어야 한다 (`cursor == nil` ⇒ 보이지 않는다: 잘림에서 짐작하지 않고, 서버가 줄 때만).
    /// 그리고 이미 쓴 커서(Clear 뒤)가 아니고, 오래된 줄이 아니고(다시 읽지 못했다), 읽음 처리할 변화가 줄에 있을 때 — 결정만 있는 줄은 Clear가 할 일이 없다
    public static func canClear(_ summary: ReturnSummaryResponse, isStale: Bool, cursorSpent: Bool) -> Bool {
        summary.cursor != nil && !isStale && !cursorSpent && summary.hasChangesToClear
    }

    /// 아무것도 보일 것이 없으면 nil (읽기 전 · 기능 꺼짐 · 완전히 비어 있음). 비어 있다는 말은 만들지 않는다
    public static func make(
        summary: ReturnSummaryResponse?, isStale: Bool, readFailed: Bool, cursorSpent: Bool, isClearing: Bool, message: String?,
        now: Date = Date(), timeZone: TimeZone = .current, canOpen: (UUID) -> Bool = { _ in true }
    ) -> ReturnSummaryContent? {
        guard let summary else {
            // 한 번도 읽지 못했다: 읽는 중 · 기능 꺼짐은 아무것도 말하지 않는다. 읽기가 실패했으면 그렇게 말한다
            return readFailed ? ReturnSummaryContent(title: ReturnSummaryCopy.changesTitle, rows: [], notes: [.couldNotLoad], canClear: false, isClearing: false, message: nil) : nil
        }
        let rows = summary.items.map { item in
            ReturnSummaryRow(
                id: item.actionID, title: item.title, progress: item.state.flatMap { $0 == .unknown ? nil : $0 },
                needsAnswer: item.needsAnswer, detail: ReturnSummaryCopy.detail(item), canOpen: canOpen(item.actionID)
            )
        }
        var notes: [ReturnSummaryContent.Note] = []
        if isStale || summary.sources.changes == .unavailable { notes.append(.couldNotLoad) }
        if summary.sources.decisions == .unavailable { notes.append(.couldNotLoadDecisions) }
        if summary.isTruncated || (!summary.isComplete && notes.isEmpty) { notes.append(.someNotShown) }
        guard !rows.isEmpty || !notes.isEmpty else { return nil }
        return ReturnSummaryContent(
            title: ReturnSummaryCopy.title(since: summary.baseline == .cleared ? summary.since : nil, now: now, timeZone: timeZone),
            rows: rows, notes: notes, canClear: canClear(summary, isStale: isStale, cursorSpent: cursorSpent), isClearing: isClearing,
            message: rows.isEmpty ? nil : message
        )
    }
}
