import Foundation

/// Slack 연결을 끊거나 앱을 지우면 서버가 근거 인용을 이 글로 바꾼다 (purge_slack_sources, docs/go-live/slack-integration.md D3).
/// 누가 한 말이 아니므로 인용 부호 없이 이 앱의 문구로 보여 준다.
public enum RemovedQuote {
    public static let slackDisconnected = "Slack 연결을 끊어 지웠어요"
    public static let label = "Removed when Slack was disconnected"

    public static func isRemoved(_ quote: String) -> Bool { quote == slackDisconnected }
}

/// 근거 한 줄에 필요한 것: 인용 + 원문 (+ 서비스 · 붙은 일정)
public struct EvidenceLine: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let quote: String
    public let sourceID: UUID
    public let sourceTitle: String?
    /// 원문 시점 (일정이 없으면 근거 줄의 When). 일정 시작은 근거 순서에 쓰지 않는다
    public let occurredAt: Date?
    public let externalURL: URL?
    public let service: SourceService
    /// 원문에 붙은 Calendar 일정 (Notion 회의록 · Meet 전사)
    public let meeting: SourceMeeting?

    public init(
        id: UUID, quote: String, sourceID: UUID, sourceTitle: String?, occurredAt: Date?, externalURL: URL?, service: SourceService,
        meeting: SourceMeeting? = nil
    ) {
        self.id = id
        self.quote = quote
        self.sourceID = sourceID
        self.sourceTitle = sourceTitle
        self.occurredAt = occurredAt
        self.externalURL = externalURL
        self.service = service
        self.meeting = meeting
    }

    /// 근거 줄 "When · Source"의 When: 일정이 붙었으면 일정 시작 ("Sep 30 · Proposal review — Acme")
    public var displayDate: Date? { meeting?.start ?? occurredAt }

    /// 근거 줄 "When · Source"의 Source: 일정이 붙었으면 일정 제목, 제목 없는 일정이면 원문 제목
    public var displayTitle: String? { meeting?.title ?? sourceTitle }

    public init(_ citation: AskCitation) {
        self.init(
            id: UUID(),
            quote: citation.quote,
            sourceID: citation.sourceID,
            sourceTitle: citation.sourceTitle,
            occurredAt: citation.occurredAt,
            externalURL: citation.externalURL,
            service: citation.service
        )
    }
}

/// 할 일의 근거를 화면 두 곳에 맞게 고른다.
/// - iPhone Evidence 한 줄: 가장 최근 근거가 맨 앞, 나머지 원문은 줄 끝 작은 겹침 (Figma 3:407)
/// - Mac Sources 묶음: 오래된 근거가 위 (Figma 10:737)
public struct EvidenceDigest: Sendable, Hashable {
    /// 오래된 것이 위
    public let lines: [EvidenceLine]

    public init(lines: [EvidenceLine]) {
        self.lines = lines.sorted { ($0.occurredAt ?? .distantPast, $0.id.uuidString) < ($1.occurredAt ?? .distantPast, $1.id.uuidString) }
    }

    public init(evidence: [EvidenceRecord], sources: [UUID: SourceSummary]) {
        // 같은 원문의 같은 구절은 한 번만
        var seen = Set<String>()
        let unique = evidence
            .sorted { $0.createdAt < $1.createdAt }
            .filter { seen.insert("\($0.sourceID)|\($0.quote)").inserted }
        lines = unique.map { record in
            let source = sources[record.sourceID]
            return EvidenceLine(
                id: record.id,
                quote: record.quote,
                sourceID: record.sourceID,
                sourceTitle: source?.title,
                occurredAt: source?.occurredAt ?? record.createdAt,
                externalURL: source?.externalURL,
                service: source.map { SourceService.infer(externalURL: $0.externalURL, kind: $0.kind) } ?? .manual(.note),
                meeting: source?.meeting
            )
        }
    }

    public var isEmpty: Bool { lines.isEmpty }

    /// 맨 앞에 보여 줄 근거: 가장 최근 것 (지금 상태를 만든 말). Slack 연결을 끊어 지운 인용보다 남아 있는 인용을 먼저
    public var lead: EvidenceLine? { lines.last { !RemovedQuote.isRemoved($0.quote) } ?? lines.last }

    /// 맨 앞 근거의 원문을 뺀 나머지 원문의 서비스 (처음 들어온 순서, 원문마다 하나)
    public var otherSources: [SourceService] {
        guard let lead else { return [] }
        var seen: Set<UUID> = [lead.sourceID]
        return lines.filter { seen.insert($0.sourceID).inserted }.map(\.service)
    }

    /// Sources 묶음 머리의 겹친 로고 (처음 들어온 순서)
    public var services: [SourceService] { lines.map(\.service) }
}

/// Sources 묶음의 한 덩어리: 같은 일정(`calendar_event_id`)에 붙은 원문의 근거(예: Notion 회의록 + Meet 전사)는 한 회의로,
/// 일정이 없는 근거는 줄마다 하나.
public struct EvidenceGroup: Sendable, Hashable, Identifiable {
    /// 한 줄 이상, 받은 순서 그대로
    public let lines: [EvidenceLine]

    public var id: UUID { lines[0].id }
    public var meeting: SourceMeeting? { lines[0].meeting }

    private init(lines: [EvidenceLine]) {
        precondition(!lines.isEmpty)
        self.lines = lines
    }

    /// 받은 순서를 지키고, 같은 회의의 줄은 그 회의가 처음 나온 자리에 모은다.
    public static func grouped(_ lines: [EvidenceLine]) -> [EvidenceGroup] {
        var groups: [[EvidenceLine]] = []
        var meetingIndex: [String: Int] = [:]
        for line in lines {
            if let key = line.meeting?.calendarEventID {
                if let index = meetingIndex[key] {
                    groups[index].append(line)
                    continue
                }
                meetingIndex[key] = groups.count
            }
            groups.append([line])
        }
        return groups.map(EvidenceGroup.init(lines:))
    }
}
