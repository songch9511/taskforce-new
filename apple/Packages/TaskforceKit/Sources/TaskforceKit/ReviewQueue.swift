import Foundation

// 0.2.0 S4 Review: 기존 `GET /api/v1/now`의 확인 요청(`confirmations`)을 Review 화면의 결정 큐로 읽는 화면 없는 규칙.
// 새 판정 · 새 문장 · 새 서버 의미를 만들지 않는다. 순서는 서버가 정한 그대로(앱은 다시 줄 세우지 않는다)이고, 항목은 늘 stable action id로 가리킨다:
// 몇 번째인지(index)를 들고 있다가 큐가 바뀐 뒤 다른 항목에 행동하는 일이 없게, 화면에 보이는 것도 · 키가 가는 곳도 id다.

/// 결정에 줄 수 있는 답: **기존 v1 쓰기 둘뿐이다.** Confirm = `POST /api/v1/actions/:id/confirm`, Dismiss = `DELETE /api/v1/actions/:id`(서버는 취소로 둔다).
/// 번호 키는 1 · 2뿐이다. 세 번째 행동은 v1에 없으므로 3은 아무 일도 하지 않는다 (되돌리기 · 다른 제안 같은 것은 S4b/C3).
public enum ReviewAnswer: Int, Sendable, Hashable, CaseIterable {
    case confirm = 1
    case dismiss = 2

    /// 번호 키 (디자인 AnswerOption의 `index`)
    public var key: Int { rawValue }

    /// 라벨: 기존 앱 문구 (iPhone Review card · 런처 Review 행과 같다)
    public var label: String {
        switch self {
        case .confirm: "Confirm"
        case .dismiss: "Dismiss"
        }
    }

    /// 번호 키로 고르는 답. 1 · 2만 있다
    public init?(key: Int) {
        self.init(rawValue: key)
    }
}

/// 서버 순서 그대로의 Review 큐. 항목은 id로 가리킨다
public struct ReviewQueue: Sendable, Equatable {
    public let items: [ActionSummary]

    public init(_ items: [ActionSummary]) {
        self.items = items
    }

    public var count: Int { items.count }
    public var isEmpty: Bool { items.isEmpty }
    public var ids: [UUID] { items.map(\.id) }

    public func contains(_ id: UUID) -> Bool { items.contains { $0.id == id } }

    public func item(_ id: UUID) -> ActionSummary? { items.first { $0.id == id } }

    public func index(of id: UUID) -> Int? { items.firstIndex { $0.id == id } }

    /// ⌘1 · 가장 새 항목: `last_activity_at`이 가장 늦은 확인 요청. 같으면 서버 순서에서 뒤쪽.
    /// (v1에는 "결정이 생긴 시각"이 없다. 서버가 확인 요청을 `last_activity_at` 오름차순으로 주므로 보통 마지막 항목이지만, 순서가 달라져도 이 규칙이 따른다)
    public var newest: ActionSummary? {
        items.enumerated().max { ($0.element.lastActivityAt, $0.offset) < ($1.element.lastActivityAt, $1.offset) }?.element
    }

    /// 이 항목에서 `offset`만큼 옮긴 항목의 id (← →). 끝에서 돌지 않고 멈춘다. 큐에 없는 id면 nil
    public func neighbor(of id: UUID, offset: Int) -> UUID? {
        guard let index = index(of: id) else { return nil }
        return items[min(max(index + offset, 0), items.count - 1)].id
    }

    /// 보던 항목이 큐에서 빠졌을 때 다음에 볼 항목: 그 항목의 뒤에 있던 것 중 아직 남은 첫 번째, 없으면 앞에 있던 것 중 가장 가까운 것.
    /// `previous`는 빠지기 전 큐의 id 순서, `current`는 지금 큐. 둘 다에 없으면 nil
    public static func successor(of id: UUID, previous: [UUID], current: [UUID]) -> UUID? {
        guard let index = previous.firstIndex(of: id) else { return nil }
        let alive = Set(current)
        if let next = previous[(index + 1)...].first(where: alive.contains) { return next }
        return previous[..<index].last(where: alive.contains)
    }

    /// 지금 화면에 보일 항목: 보던 항목이 아직 큐에 있으면 그것(순서가 바뀌어도 id로), 빠졌으면 그 뒤를 이은 항목, 보던 것이 없으면 가장 새 항목. 큐가 비면 nil
    public func resolving(_ shown: UUID?, previous: [UUID]) -> UUID? {
        if let shown {
            if contains(shown) { return shown }
            if let next = Self.successor(of: shown, previous: previous, current: ids) { return next }
        }
        return newest?.id
    }
}

/// Review 본문에 무엇을 보일지 (디자인 EmptyState: 읽는 중 · 오프라인 · 읽기 실패 · 결정 없음은 서로 다른 화면). 받은 목록이 없으면 "결정이 없다"고 말하지 않는다
public enum ReviewScreen: Sendable, Hashable {
    /// 아무 주장도 하지 않는다: 이번 실행의 목록이 아직 없음 (읽는 중 · 로그아웃)
    case blank
    /// 목록 없이 오프라인
    case offline
    /// 목록 없이 읽기 실패
    case failed
    /// 받은 목록에 기다리는 결정이 없다: "No decisions waiting" (받은 목록 뒤에 끊겼으면 `problem`)
    case empty(problem: WorkLoad.Problem?)
    /// 결정 하나를 보인다 (받은 목록 뒤에 끊겼으면 `problem`)
    case decision(problem: WorkLoad.Problem?)

    public static func of(load: WorkLoad, hasDecision: Bool) -> ReviewScreen {
        switch load {
        case .loading: .blank
        case .offline: .offline
        case .failed: .failed
        case .loaded(let problem): hasDecision ? .decision(problem: problem) : .empty(problem: problem)
        }
    }

    /// 답을 보낼 수 있나: 결정이 보이고 오프라인이 아닐 때만. 오프라인에서는 나중에 보내려고 모아 두지 않는다
    public var canAnswer: Bool {
        if case .decision(let problem) = self { problem != .offline } else { false }
    }
}

/// Review 화면의 글자. 새 문구는 최소로 하고 기존 앱 문구를 재사용한다 (`s4-mac-notes.md`에 새 문구를 모두 적는다)
public enum ReviewCopy {
    /// 디자인 DecisionBlock meta: "Waiting"은 쓰지 않는다 (Taskforce에서 Waiting은 늘 다른 사람을 기다리는 뜻)
    public static let needsYourAnswer = "Needs your answer"
    /// 출처 인용이 없다 (읽었는데 근거 줄이 없음): 기존 Remembered 문구
    public static let noQuote = "No quote to show"
    /// 근거를 읽지 못했다: 기존 Remembered 문구
    public static let couldNotLoadSource = "Couldn't load the source"
    public static let tryAgain = "Try again"
    /// 응답을 받지 못했거나 서버가 5xx · 해석할 수 없는 응답을 줬다: 서버가 처리했을 수도 있다. 자동으로 다시 보내지 않고 지금 상태를 읽어 보인다.
    /// ("Confirm" 버튼과 헷갈리지 않게 "confirm" 대신 "verify")
    public static let unverified = "Couldn't verify that answer. Showing what's saved."
    /// 409: 기존 문구 그대로 ("This changed somewhere else. It's been refreshed.")
    public static let conflict = APIError.server(status: 409, code: .conflict, message: "").userMessage

    /// "Needs your answer" + S3b에서 **확인된** 멤버십이 있을 때만 그 범위 이름들 (이름 일치 · 추정 없음, 후보(inferred)는 이름을 붙이지 않는다)
    public static func meta(memberships: WorkMemberships) -> String {
        let names = memberships.links.map(\.project.title)
        return names.isEmpty ? needsYourAnswer : needsYourAnswer + " · " + names.joined(separator: ", ")
    }

    /// 질문 자리: 서버가 남긴 확인 이유를 앱의 기존 분류 · 문구로 (`ConfirmReasonText`). 새 판정 · 새 문장이 아니다
    public static func question(_ action: ActionSummary) -> String {
        ConfirmReasonText.label(action.confirmReasons)
    }
}

/// 결정 아래 원문: 기존 `/now` 근거(`EvidenceDigest`)를 사실대로. 지어내지 않고 새 영구 캐시도 없다
public enum ReviewSource: Equatable, Sendable {
    public struct Line: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let service: SourceService
        /// 원문 이름 (제목이 없으면 nil)
        public let place: String?
        public let time: Date?
        /// 원문 그대로의 구절. `removed`면 비어 있다
        public let text: String
        /// Slack 연결을 끊어 지운 인용 (인용 부호 없이 이 앱의 문구로)
        public let removed: Bool
        public let url: URL?

        public init(id: UUID, service: SourceService, place: String?, time: Date?, text: String, removed: Bool, url: URL?) {
            self.id = id
            self.service = service
            self.place = place
            self.time = time
            self.text = text
            self.removed = removed
            self.url = url
        }
    }

    /// 읽는 중 (아직 아무것도 받지 않았다)
    case loading
    /// 읽지 못했다
    case failed
    /// 읽었는데 보일 근거가 없다
    case noQuote
    /// 근거 줄들 (가장 최근 것이 위: 지금 상태를 만든 말)
    case lines([Line])

    /// `digest`가 nil이고 `failed`가 아니면 읽는 중. 실행 receipt(초안 저장 기록)는 원문이 아니라 뺀다.
    /// 읽지 못했으면(`failed`) 전에 읽은 근거가 있어도 그것을 지금 근거처럼 보이지 않는다 (그 뒤 항목이 달라졌을 수 있다)
    public static func of(digest: EvidenceDigest?, failed: Bool) -> ReviewSource {
        if failed { return .failed }
        guard let digest else { return .loading }
        let lines = digest.withoutReceipts.lines.reversed().map { line in
            let removed = RemovedQuote.isRemoved(line.quote)
            return Line(
                id: line.id, service: line.service, place: line.displayTitle, time: line.displayDate,
                text: removed ? "" : line.quote, removed: removed, url: line.externalURL
            )
        }
        return lines.isEmpty ? .noQuote : .lines(lines)
    }
}
