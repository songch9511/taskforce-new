import Foundation

// Remembered의 순수 규칙: 문구 · 한 줄 메타 · 범위 이름 · 출처 표시. 화면 없이 테스트로 고정한다 (`MemoryRulesTests`).
// 무엇이 지금 쓰이는 기억인지(범위 사이 우선)는 서버 판정이라 여기서 흉내 내지 않는다: 항목마다 행의 값을 그대로 보인다.

/// Remembered의 글. 디자인 SettingsPage · RememberedNote/Row/Detail의 문구는 글자 그대로, 디자인에 없는 말은 `New copy`
public enum MemoryCopy {
    // 디자인
    public static let rowTitle = "Remembered"
    public static let rowDetail = "What Taskforce keeps about you and your work"
    public static let noteTitle = "Remembered"
    /// 목록 각주 (Settings에서만 말한다)
    public static let listFootnote = "Remembered things are context, not permission. They never give an agent access to anything."
    /// 추정 항목 상세 각주
    public static let inferredFootnote = "Inferred items are not used in any work until you confirm them."
    public static let forgetTitle = "Forget this?"
    public static let forgetDetail = "Work already done with it stays as it is."
    public static let forgetConfirm = "Forget"
    public static let forgetOpen = "Forget…"
    public static let confirm = "Confirm"
    public static let edit = "Edit"
    public static let save = "Save"
    public static let cancel = "Cancel"
    public static let statementLabel = "Statement"
    public static let kindLabel = "Kind"
    public static let scopeLabel = "Applies to"
    public static let whenLabel = "Remembered"
    public static let sourceTitle = "Source"
    public static let allWork = "All work"
    public static let unconfirmed = "Unconfirmed"

    // New copy
    /// 출처 원문 글이 지워진 observed (statement가 비었다)
    public static let purgedStatement = "Original text deleted"
    /// 지금 기억이 아니다 (잊었거나 정정되어 대체되었다 · 읽을 수 없다): 이유를 지어내지 않는다
    public static let noLongerRemembered = "No longer remembered"
    /// 목록이 비었다
    public static let emptyList = "Nothing remembered yet."
    public static let couldNotLoad = "Couldn't load what's remembered"
    public static let offline = "You're offline"
    public static let tryAgain = "Try again"
    /// 서버 gate가 꺼져 쓰기가 막혀 있다 (읽기는 된다)
    public static let writesUnavailable = "Changes aren't available yet."
    /// 서버가 글을 그대로 저장하지 못하게 했다 (Slack 원문 후보를 글자 그대로 저장하려 함): 글을 고쳐 써야 한다
    public static let rewriteToSave = "Change the wording to save it."
    /// 범위 이름 (디자인은 프로젝트와 All work만 안다): 읽기만 하는 나머지 범위
    public static let scopeTask = "A task"
    public static let scopePerson = "A person"
    public static let scopeAgent = "An agent"
    public static let scopeProject = "A project"
    public static let scopeOther = "Another scope"
    public static let unnamedProject = "Project"
    // 출처
    public static let sourceMissing = "The source is no longer available"
    public static let sourceNoQuote = "No quote to show"
    public static let chatPlace = "Chat"
    public static let you = "You"
    public static let taskforce = "Taskforce"
}

public enum MemoryText {
    /// 디자인 kind: Explicit · Observed · Inferred (모르는 값은 그대로 보이고 확인은 주지 않는다)
    public static func kind(_ origin: MemoryOrigin) -> String {
        switch origin {
        case .explicit: "Explicit"
        case .observed: "Observed"
        case .inferred: "Inferred"
        case .other(let raw): raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }

    /// "Inferred · Unconfirmed": 지금 기억인 추정은 늘 확인 전이다 (확인하면 새 explicit 행이 생기고 이 행은 정정된다)
    public static func kindLine(_ item: MemoryItem) -> String {
        item.isUnconfirmedInference ? "\(kind(item.origin)) · \(MemoryCopy.unconfirmed)" : kind(item.origin)
    }

    /// 범위 이름. 프로젝트 이름을 아직 모르면(읽는 중 · 지워짐) "Project"
    public static func scope(_ item: MemoryItem, contexts: [UUID: WorkContext]) -> String {
        switch item.scopeKind {
        case .global: MemoryCopy.allWork
        case .context: item.contextID.flatMap { contexts[$0]?.name } ?? MemoryCopy.unnamedProject
        case .action: MemoryCopy.scopeTask
        case .counterpart: MemoryCopy.scopePerson
        case .agent: MemoryCopy.scopeAgent
        case .other: MemoryCopy.scopeOther
        }
    }

    /// 글: 지워진 observed는 글이 없다고 사실대로 말한다
    public static func statement(_ item: MemoryItem) -> String {
        item.sourcePurged || item.statement.isEmpty ? MemoryCopy.purgedStatement : item.statement
    }

    /// 노트의 둘째 줄 "Explicit · Shape launch" · 목록 행의 둘째 줄 "Explicit · Shape launch · Today 10:24" (시각은 `withTime`)
    public static func meta(_ item: MemoryItem, contexts: [UUID: WorkContext], withTime: Bool, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        var parts = [kindLine(item), scope(item, contexts: contexts)]
        if withTime { parts.append(WhenText.label(item.observedAt, now: now, timeZone: timeZone)) }
        return parts.joined(separator: " · ")
    }

    /// 지금은 흐리게 읽는 문장인가 (확인 전 추정, 글이 지워진 항목)
    public static func isTentative(_ item: MemoryItem) -> Bool {
        item.isUnconfirmedInference || item.sourcePurged || item.statement.isEmpty
    }

    /// 범위 popup을 줄 수 있는 항목: explicit이고 범위가 전체 · 프로젝트일 때만 (서버 정책 보류: 나머지는 409 `scope_unavailable`)
    public static func canChangeScope(_ item: MemoryItem) -> Bool {
        guard item.origin == .explicit, item.isCurrent else { return false }
        return item.scopeKind == .global || item.scopeKind == .context
    }

    /// 확인을 줄 수 있는 항목: 지금 기억인 추정이고 글이 있다 (서버 정책 보류는 409 `confirm_unavailable`로 알려 와 그때 감춘다)
    public static func canConfirm(_ item: MemoryItem) -> Bool {
        item.isUnconfirmedInference && !item.sourcePurged && !item.statement.isEmpty
    }

    /// 정정 글의 검사: 앞뒤 공백을 걷고 1–1000자 (서버 `memoryEditRequestSchema`, UTF-16)
    public static func editedStatement(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf16.count <= 1000 else { return nil }
        return trimmed
    }

    /// 범위 popup의 선택지: All work + 내 active 프로젝트. 지금 범위가 보관된 프로젝트면 그것도 (선택값으로) 넣는다
    public static func scopeChoices(for item: MemoryItem, contexts: [UUID: WorkContext]) -> [MemoryScopeChoice] {
        var choices = [MemoryScopeChoice(target: .global, name: MemoryCopy.allWork)]
        let active = contexts.values.filter(\.isActive).sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
        choices += active.map { MemoryScopeChoice(target: .context($0.id), name: $0.name) }
        if item.scopeKind == .context, let id = item.contextID, !choices.contains(where: { $0.target == .context(id) }) {
            choices.append(MemoryScopeChoice(target: .context(id), name: scope(item, contexts: contexts)))
        }
        return choices
    }

    /// 항목의 지금 범위 (popup 선택값)
    public static func currentTarget(_ item: MemoryItem) -> MemoryTarget? {
        switch item.scopeKind {
        case .global: .global
        case .context: item.contextID.map(MemoryTarget.context)
        default: nil
        }
    }
}

public struct MemoryScopeChoice: Sendable, Hashable, Identifiable {
    public let target: MemoryTarget
    public let name: String

    public var id: MemoryTarget { target }
}

/// 출처 표시 (RememberedDetail의 SourceQuote). 사실대로: 없는 것은 없다고, 지워진 것은 지워졌다고 쓰고 옛 인용을 다시 보이지 않는다
public struct MemoryQuote: Sendable, Hashable {
    public let service: SourceService?
    public let from: String?
    public let place: String?
    public let time: Date?
    public let text: String
    public let url: URL?
}

public enum MemorySourceDisplay: Sendable, Hashable {
    /// 보일 출처가 없다 (사용자가 직접 쓴 값: 출처가 사용자 Claim이다)
    case hidden
    case loading
    /// 읽지 못했다 (오프라인 · 실패): 인용을 지어내지 않는다
    case failed
    /// 인용을 보일 수 없다: 이유를 한 줄로
    case unavailable(String)
    case quote(MemoryQuote)
}

public enum MemorySourceRules {
    /// - message: `source_ref.message_id`의 대화 메시지 (읽은 것), source: `source_ref.source_id`의 원문 요약 (읽은 것)
    /// - 읽은 결과가 없으면(`nil`) 지워졌거나 닿을 수 없는 것이다 (읽기 자체의 실패는 `lookup`이 `.failed`)
    public enum Lookup: Sendable, Hashable {
        case loading, failed
        case loaded(message: ChatMessage?, source: SourceSummary?)
    }

    public static func display(item: MemoryItem, lookup: Lookup) -> MemorySourceDisplay {
        guard let ref = item.sourceRef else {
            // 출처가 없다: explicit은 사용자가 직접 쓴 값이다. 그 밖은 출처가 없다고 말한다
            return item.origin == .explicit ? .hidden : .unavailable(MemoryCopy.sourceMissing)
        }
        if item.sourcePurged { return .unavailable(MemoryCopy.purgedStatement) }
        let hasLookup = ref.messageID != nil || ref.sourceID != nil
        let (message, source): (ChatMessage?, SourceSummary?)
        switch lookup {
        case .loading where hasLookup: return .loading
        case .failed where hasLookup: return .failed
        case .loaded(let m, let s): (message, source) = (m, s)
        default: (message, source) = (nil, nil)
        }

        if let messageID = ref.messageID {
            guard let message, message.id == messageID, !message.text.isEmpty else { return .unavailable(MemoryCopy.purgedStatement) }
            let isUser = message.role.isUser
            return .quote(MemoryQuote(
                service: nil, from: isUser ? MemoryCopy.you : MemoryCopy.taskforce, place: MemoryCopy.chatPlace, time: message.createdAt,
                text: ref.quote.flatMap { $0.isEmpty ? nil : $0 } ?? message.text, url: nil
            ))
        }
        if ref.sourceID != nil {
            let service = source.map { SourceService.infer(externalURL: $0.externalURL, kind: $0.kind) }
            let quote = ref.quote.flatMap { $0.isEmpty ? nil : $0 }
            // Slack 연결을 끊으면 인용이 사라진다 (D3): 그렇게 지웠다고 말한다
            if quote == nil || quote.map(RemovedQuote.isRemoved) == true {
                if service == .slack || quote != nil { return .unavailable(RemovedQuote.label) }
                return source == nil ? .unavailable(MemoryCopy.sourceMissing) : .unavailable(MemoryCopy.sourceNoQuote)
            }
            return .quote(MemoryQuote(
                service: service, from: nil, place: source?.title, time: source?.occurredAt,
                text: quote ?? "", url: source?.externalURL
            ))
        }
        return .unavailable(MemoryCopy.sourceNoQuote)
    }
}
