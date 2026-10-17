import Foundation

/// 복귀 요약의 글자. SSOT 고정 문구(`Since …` · `Clear` · `Needs your answer`)와 앱에 이미 있는 문구를 쓰고, 새 문구는 A–D 승인 후속(`handoffs/c3-product-decisions-2026-10-12.md`)의
/// 확정안 그대로다 (`c3-mac-notes.md`에 목록). 서버는 토큰만 주고 문구를 만들지 않는다. 숫자(개수)는 어디에도 없다 (디자인 D-12).
/// `Next: review the result`는 이 앱에서 만들지 않는다: 실제 결과에 도달할 길이 아직 없다 (All work 행 이동뿐) — 약속하지 않는다.
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

    // MARK: 승인된 새 문구 (A, 최종 17개 + 조건부 `Next: review the result`는 생략)
    /// 카드 캡션: 마지막 Clear 시각을 모를 때 (`since == nil`, 기준점만 있는 `initialized` 포함). 시각을 지어내지 않는다
    public static let changesTitle = "Changes"
    /// 질문만 남은 카드의 캡션 (B): 기존 `Needs your answer`를 다시 쓴다
    public static let questionsTitle = ReviewCopy.needsYourAnswer
    /// 변화 원천을 읽지 못했다 (또는 읽은 뒤 다시 읽지 못했다 · 응답이 앞뒤가 맞지 않는다): 비어 있다고 말하지 않는다
    public static let couldNotLoad = "Couldn't load changes"
    /// 결정(질문) 목록을 읽지 못했다: `Needs your answer` 줄이 빠졌을 수 있다
    public static let couldNotLoadQuestions = "Couldn't load items needing your answer"
    /// 정상 페이지 잘림: 보인 작업을 Clear한 뒤 다음 조회가 나머지를 보인다 (개수를 말하지 않는다)
    public static let moreAvailable = "More changes are available"
    /// 앱이 말로 옮기지 못하는 변화가 있다: 줄은 남기고 Clear는 막는다
    public static let couldNotShow = "Some changes couldn't be shown"
    public static let actionEventDueChanged = "Due date changed"
    /// `scope_changed`의 실제 생산자는 제목 변경이다
    public static let actionEventTitleChanged = "Title changed"
    public static let actionEventOwnerChanged = "Owner changed"
    /// `merged`는 다시 언급됨뿐 아니라 원문 때문에 확인 사유가 달라진 경우도 포함한다
    public static let actionEventUpdatedFromSource = "Updated from source"
    public static let actionEventCompleted = "Completed"
    public static let actionEventDropped = "Canceled"
    public static let actionEventReopened = "Reopened"
    /// 검토 기준 미충족 · 수정 왕복 소진(`review_failed`)에만. 검사기 장애 · 검증 불가에 쓰지 않는다
    public static let runNeedsRevision = "Needs revision"
    /// 검토를 통과한 결과(`agent_done`)에만. 업무 전체 완료 · 외부 발송을 뜻하지 않는다
    public static let runResultReady = "Result ready"
    /// 결과 이름 없이 끝난 처리(`done`에 outcome이 없다)뿐이다. 모르는 outcome을 정상 성공으로 올리지 않는다 (그것은 해석 못 한 변화다)
    public static let runProcessingFinished = "Processing finished"
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

    /// 변화 하나의 글. **nil = 앱이 말로 옮기지 못하는 변화** (해석 못 한 변화: Clear · 기준점 확정을 막고 `Some changes couldn't be shown`). 어떤 성공 문구로도 바꾸지 않는다.
    /// 필드마다 정한 규칙 (P2-M2 — 알 수 없거나 타입이 틀린 값을 지우거나 정상으로 바꾸지 않는다):
    /// - 모르는 source · kind: 해석 못 함. 문자열이어야 하는 `kind` · `detail`이 다른 타입으로 왔으면(`isMalformed`) 해석 못 함.
    /// - run `done`의 `detail`(outcome): 정말 없음(null · 키 없음)은 `Processing finished`, 아는 outcome은 그 말, 모르는 문자열은 해석 못 함 (정상 성공으로 올리지 않는다).
    /// - run `failed`의 `detail`: 서버가 run의 outcome을 done · failed 사건 모두에 싣는다(`run.outcome`). 없음(null · 키 없음)과 **아는 outcome**(`knownRunOutcomes`)이면 실패 문장은 outcome에 달라지지 않으므로 그대로다.
    ///   모르는 문자열은 앱이 모르는 정보라 `done`과 똑같이 해석 못 함 (D-7: 모르는 자유 문자열 detail도 막는다 — 지금 서버가 보내지 않는 미래 토큰이어도 실패 문장으로 덮지 않는다). 타입이 틀리면 위처럼 해석 못 함.
    /// - action_event의 `detail`: 계약상 null이다. 값이 있으면 이 앱이 모르는 정보라 해석 못 함. message의 `detail`도 같다.
    /// - action_event의 `source_state`: 없음 · `available`은 말이 없고, `deleted` · `access_lost` · `text_expired`는 그 말을 덧붙이고, 모르는 값은 해석 못 함.
    /// - run · message의 `source_state`: 계약상 null이다. 없음 · `available`(말이 없는 값)만 받고, 그 밖의 값(모르는 값 포함)은 해석 못 함.
    public static func change(_ change: ReturnSummaryChange) -> String? {
        guard !change.isMalformed else { return nil }
        switch change.source {
        case .actionEvent:
            guard change.detail == nil, let base = base(change) else { return nil }
            switch change.sourceState {
            case nil, .available?: return base
            case .deleted?: return base + separator + sourceDeleted
            case .accessLost?: return base + separator + sourceUnavailable
            case .textExpired?: return base + separator + sourceExpired
            case .unknown?: return nil
            }
        case .run, .message:
            switch change.sourceState {
            case nil, .available?: return base(change)
            default: return nil
            }
        case .unknown:
            return nil
        }
    }

    /// 서버가 run에 기록하는 outcome (`execution_runs_outcome_check`): `done`의 말을 정하고, `failed`에 실려도 아는 값이다
    private static let knownRunOutcomes: Set<String> = ["draft_ready", "needs_input", "needs_connection", "needs_capability", "review_failed", "agent_done"]

    private static func base(_ change: ReturnSummaryChange) -> String? {
        switch change.source {
        case .actionEvent:
            switch change.kind {
            case "due_changed": return actionEventDueChanged
            case "scope_changed": return actionEventTitleChanged
            case "owner_changed": return actionEventOwnerChanged
            case "merged": return actionEventUpdatedFromSource
            case "completed": return actionEventCompleted
            case "dropped": return actionEventDropped
            case "reopened": return actionEventReopened
            case "artifact_created": return runDraftReady
            default: return nil
            }
        case .run:
            switch change.kind {
            case "failed":
                // 아는 outcome(서버가 failed 사건에도 싣는다)이거나 없을 때만 실패 문장이다. 모르는 문자열 detail은 해석 못 한 변화 (D-7)
                guard change.detail.map({ knownRunOutcomes.contains($0) }) ?? true else { return nil }
                return runFailed
            case "done":
                switch change.detail {
                case nil: return runProcessingFinished
                case "draft_ready"?: return runDraftReady
                case "needs_input"?: return runQuestion
                case "needs_connection"?, "needs_capability"?: return runNeedsConnection
                case "review_failed"?: return runNeedsRevision
                case "agent_done"?: return runResultReady
                default: return nil
                }
            default: return nil
            }
        case .message:
            guard change.detail == nil else { return nil }
            switch change.kind {
            case "assistant": return messageAssistant
            case "event": return messageEvent
            default: return nil
            }
        case .unknown:
            return nil
        }
    }

    /// 줄 하나가 말하는 변화 말의 수: 서로 다른 말 셋. 개수는 말하지 않는다 (줄을 열면 그 작업이 있다).
    /// **이것은 보이는 문장의 수일 뿐이다: Clear는 이 셋이 아니라 표시된 작업의 서버 커서가 가리키는 변화 전체를 읽음 처리한다** (그래서 해석 못 한 변화가 있으면 Clear를 막는다)
    static let visibleChanges = 3

    /// 서로 다른 변화 말을 **실제 마지막 발생 순**(오름차순)으로 모아 가장 최근 셋 (D-6). 발생 순서는 `at`이고 같은 시각이면 배열 순서가 안정된 tie다 (배열의 뒤가 더 나중).
    /// 같은 말(두 토큰이 같은 문구로 합쳐지는 경우 포함)은 하나이고 그 말의 위치는 마지막 발생이다: A → B → C → D → A는 C · D · A. 해석 못 한 변화는 말이 없다
    static func recentPhrases(_ changes: [ReturnSummaryChange]) -> [String] {
        let ordered = changes.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }
        var last: [String: Int] = [:]
        for (position, entry) in ordered.enumerated() {
            if let phrase = change(entry.element) { last[phrase] = position }
        }
        return last.sorted { $0.value < $1.value }.suffix(visibleChanges).map(\.key)
    }

    /// 줄의 보조 글: [`Needs your answer`] · 최근 서로 다른 변화 말들. (`Next: …`는 만들지 않는다)
    static func detail(_ item: ReturnSummaryItem) -> String? {
        var parts: [String] = []
        if item.needsAnswer { parts.append(needsYourAnswer) }
        parts.append(contentsOf: recentPhrases(item.changes))
        return parts.isEmpty ? nil : parts.joined(separator: separator)
    }

    /// 변화만 보이는 줄의 보조 글 (OA U3, Taskforce 대화의 끝 메시지): 최근 서로 다른 변화 말들뿐이다. 결정은 요청 카드가 말하니 `Needs your answer` 태그가 없다 (DS ReturnSummary)
    static func changesOnlyDetail(_ item: ReturnSummaryItem) -> String? {
        let phrases = recentPhrases(item.changes)
        return phrases.isEmpty ? nil : phrases.joined(separator: separator)
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
    /// 줄 밑의 정직한 한 줄 (비어 있다는 말이 아니라 **모른다 · 일부만 보인다 · 더 있다**는 말). 원인이 다르면 말도 다르다
    public enum Note: Equatable, Sendable {
        /// 변화 원천을 읽지 못했다 (또는 오래된 줄 · 앞뒤가 맞지 않는 응답)
        case couldNotLoad
        /// 질문 목록을 읽지 못했다
        case couldNotLoadQuestions
        /// 앱이 말로 옮기지 못하는 변화가 있다 (Clear 차단)
        case couldNotShow
        /// 정상 페이지 잘림 (Clear 가능)
        case moreAvailable

        public var text: String {
            switch self {
            case .couldNotLoad: ReturnSummaryCopy.couldNotLoad
            case .couldNotLoadQuestions: ReturnSummaryCopy.couldNotLoadQuestions
            case .couldNotShow: ReturnSummaryCopy.couldNotShow
            case .moreAvailable: ReturnSummaryCopy.moreAvailable
            }
        }

        /// 다시 읽을 수 있는 노트 (Try again)
        public var offersRetry: Bool { self == .couldNotLoad || self == .couldNotLoadQuestions }
    }

    public let title: String
    public let rows: [ReturnSummaryRow]
    public let notes: [Note]
    /// Clear 버튼: 서버가 커서를 줬고 읽음 처리할 변화가 보이고 그 변화를 안전하게 읽음 처리할 수 있을 때만 (`ReturnSummaryPresentation.canClear`)
    public let canClear: Bool
    public let isClearing: Bool
    /// Clear 뒤 안내 한 줄 (충돌 · 실패)
    public let message: String?
    /// 변화만 보이는 메시지 (OA U3, Taskforce 대화의 끝): Needs 태그 · 형광펜 없음, 목록의 In Progress는 표시 없이 빈 자리 (`StatusMark` 규칙). 옛 All work 위 카드는 아니다
    public let changesOnly: Bool

    public var showsCard: Bool { !rows.isEmpty }

    public init(
        title: String, rows: [ReturnSummaryRow], notes: [Note] = [], canClear: Bool = false, isClearing: Bool = false, message: String? = nil,
        changesOnly: Bool = false
    ) {
        self.title = title
        self.rows = rows
        self.notes = notes
        self.canClear = canClear
        self.isClearing = isClearing
        self.message = message
        self.changesOnly = changesOnly
    }
}

public enum ReturnSummaryPresentation {
    /// Clear를 보일 조건. 서버 커서가 있어야 하고(`cursor == nil` ⇒ 보이지 않는다: 잘림에서 짐작하지 않고, 서버가 줄 때만), 이미 쓴 커서(Clear 뒤)가 아니고, 오래된 줄이 아니고(다시 읽지 못했다),
    /// 읽음 처리할 변화가 줄에 있고(결정만 있는 줄은 Clear가 할 일이 없다), 그 변화를 안전하게 읽음 처리할 수 있을 때 — 앱이 말로 옮기지 못한 변화가 표시된 작업에 있으면 막는다 (D-7).
    /// 정상 잘림 · 결정 읽기 실패 · 모르는 결정 종류는 막지 않는다.
    /// **Clear는 표시된 작업의 서버 커서가 가리키는 변화 전체를 읽음 처리한다** — 줄이 말하는 최근 셋이 아니라 (그 작업들의 더 오래된 변화도 포함). 읽음일 뿐 해결 · 승인 · 완료 · 거절이 아니다
    public static func canClear(_ summary: ReturnSummaryResponse, isStale: Bool, cursorSpent: Bool) -> Bool {
        summary.cursor != nil && !isStale && !cursorSpent && summary.hasChangesToClear && summary.canMarkChangesRead
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
        if isStale || summary.sources.changes == .unavailable || summary.hasUnreadableChangeStatus { notes.append(.couldNotLoad) }
        if summary.sources.decisions == .unavailable || summary.sources.decisions == .unknown { notes.append(.couldNotLoadQuestions) }
        if summary.hasUninterpretableChange { notes.append(.couldNotShow) }
        if summary.isTruncated { notes.append(.moreAvailable) }
        guard !rows.isEmpty || !notes.isEmpty else { return nil }
        // B: 읽음 처리할 변화가 없고 질문만 남았으면 같은 카드의 캡션이 `Needs your answer`다 (Clear는 없다). 보이는 변화(해석 못 한 변화 포함)가 하나라도 있으면 지금처럼 Since / Changes
        let questionsOnly = !rows.isEmpty && !summary.hasChangesToClear
        return ReturnSummaryContent(
            title: questionsOnly ? ReturnSummaryCopy.questionsTitle : ReturnSummaryCopy.title(since: summary.baseline == .cleared ? summary.since : nil, now: now, timeZone: timeZone),
            rows: rows, notes: notes, canClear: canClear(summary, isStale: isStale, cursorSpent: cursorSpent), isClearing: isClearing,
            message: rows.isEmpty ? nil : message
        )
    }

    /// 변화만 보이는 요약 (OA U3, 계약 v3 5.4): Taskforce 대화의 끝 메시지. 같은 응답 · 같은 Clear 규칙에서 **결정을 뺀 것**이다.
    /// - 줄은 변화가 있는 작업뿐이다 (결정만 있는 줄은 요청 카드가 말한다). Needs 태그 · 질문 제목 변형 · 질문 목록 노트가 없다.
    /// - Clear는 읽음 처리일 뿐이다 (요청을 해결하지 않는다). 변화만으로는 bell이 울리지 않는다.
    /// 옛 `make`는 Release용으로 그대로다. 아무것도 보일 것이 없으면 nil (비어 있다는 말은 만들지 않는다)
    public static func makeChangesOnly(
        summary: ReturnSummaryResponse?, isStale: Bool, readFailed: Bool, cursorSpent: Bool, isClearing: Bool, message: String?,
        now: Date = Date(), timeZone: TimeZone = .current, canOpen: (UUID) -> Bool = { _ in true }
    ) -> ReturnSummaryContent? {
        guard let summary else {
            return readFailed
                ? ReturnSummaryContent(title: ReturnSummaryCopy.changesTitle, rows: [], notes: [.couldNotLoad], canClear: false, isClearing: false, message: nil, changesOnly: true)
                : nil
        }
        let rows = summary.items.filter { !$0.changes.isEmpty }.map { item in
            ReturnSummaryRow(
                id: item.actionID, title: item.title, progress: item.state.flatMap { $0 == .unknown ? nil : $0 },
                needsAnswer: false, detail: ReturnSummaryCopy.changesOnlyDetail(item), canOpen: canOpen(item.actionID)
            )
        }
        var notes: [ReturnSummaryContent.Note] = []
        if isStale || summary.sources.changes == .unavailable || summary.hasUnreadableChangeStatus { notes.append(.couldNotLoad) }
        if summary.hasUninterpretableChange { notes.append(.couldNotShow) }
        if summary.isTruncated { notes.append(.moreAvailable) }
        guard !rows.isEmpty || !notes.isEmpty else { return nil }
        return ReturnSummaryContent(
            title: ReturnSummaryCopy.title(since: summary.baseline == .cleared ? summary.since : nil, now: now, timeZone: timeZone),
            rows: rows, notes: notes, canClear: canClear(summary, isStale: isStale, cursorSpent: cursorSpent), isClearing: isClearing,
            message: rows.isEmpty ? nil : message, changesOnly: true
        )
    }
}
