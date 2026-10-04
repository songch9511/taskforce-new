import Foundation

/// Taskforce 갈래 카드의 글 (`RunLane` → 제목 · 부제 · `View Draft`). Mac 런처 상세 · iPhone 상세(P2 · P9)가 같이 쓴다.
/// Figma에 있는 문구: M12 `Not enough credits. New paid steps are paused.`, M17 · P9 `Stop requested 14:20. No new steps will start.`.
/// 나머지는 후보 (U2 Mac 계획 PR3 표 · 열린 질문 9). 시각은 서버 값만 쓴다 (멈춘 시각 = `stopped_at`, 어느 기기에서 멈췄든).
public struct RunLaneText: Equatable, Sendable {
    public let title: String
    public let subtitle: String?
    /// VoiceOver가 갈래 이름 바로 뒤에 읽는 상태: 제목이 상태를 말하지 않을 때만 (초안 제목 → "Draft ready")
    public let spokenState: String?
    /// `View Draft`가 여는 초안 (가장 최근 것). 상태와 상관없이 초안이 있으면 있다 (A39)
    public let draft: Artifact?

    public init(title: String, subtitle: String? = nil, spokenState: String? = nil, draft: Artifact? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.spokenState = spokenState
        self.draft = draft
    }

    /// 멈추기를 보낸 뒤 VoiceOver 알림
    public static let stopAnnouncement = "Stop requested"
    /// 지켜보던 run이 초안을 냈을 때 VoiceOver 알림
    public static let draftAnnouncement = "Draft ready"
    /// `View Draft` 버튼
    public static let viewDraft = "View Draft"

    /// 보일 갈래가 없으면 nil (`RunLane.isVisible`)
    public static func make(_ lane: RunLane, now: Date = Date(), timeZone: TimeZone = .current) -> RunLaneText? {
        guard lane.isVisible else { return nil }
        let draft = lane.drafts.first
        func clock(_ date: Date) -> String { Self.clock(date, now: now, timeZone: timeZone) }
        switch lane.state {
        case .none, .draftReady:
            // `.none`이면서 보이는 갈래는 초안만 있는 경우다
            guard let draft else { return RunLaneText(title: "Draft ready", spokenState: nil) }
            let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let count = lane.drafts.count
            let label = count == 1 ? "AI draft" : "\(count) AI drafts"
            return RunLaneText(
                title: title.isEmpty ? "Draft ready" : title, subtitle: "\(label) · \(clock(draft.createdAt))",
                spokenState: title.isEmpty ? nil : "Draft ready", draft: draft
            )
        case .working:
            return RunLaneText(title: "Writing draft", subtitle: lane.run.map { "Started \(clock($0.createdAt))" }, draft: draft)
        case .paused(let reason):
            return RunLaneText(title: "Paused", subtitle: pausedSubtitle(reason), draft: draft)
        case .needsInput(let question):
            return RunLaneText(title: "Taskforce has a question", subtitle: question ?? "Question deleted after 90 days.", draft: draft)
        case .needsConnection(let capability):
            return RunLaneText(title: "Connection needed", subtitle: connectionSubtitle(capability), draft: draft)
        case .stopped(let finishing, let stoppedAt):
            let title = stoppedAt.map { "Stop requested \(clock($0)). No new steps will start." } ?? "Stopped. No new steps will start."
            return RunLaneText(title: title, subtitle: finishing ? "Finishing the current step." : nil, draft: draft)
        case .failed(let kind):
            return RunLaneText(title: "Couldn’t finish the draft", subtitle: failureSubtitle(kind), draft: draft)
        case .finishedWithoutDraft:
            return RunLaneText(title: "Finished without a draft", draft: draft)
        }
    }

    /// 갈래의 시각: 오늘이면 "14:20"(P9), 어제면 "Yesterday 14:20", 그 전이면 "Sep 30" (`WhenText`)
    public static func clock(_ date: Date, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let day = LocalDate(date: date, timeZone: timeZone)
        let today = LocalDate(date: now, timeZone: timeZone)
        return day == today ? WhenText.time(date, timeZone: timeZone) : WhenText.label(date, now: now, timeZone: timeZone)
    }

    private static func pausedSubtitle(_ reason: RunHoldReason) -> String {
        switch reason {
        case .credit: "Not enough credits. New paid steps are paused."
        case .needsConnection: "Waiting for a connection."
        case .blocked, .actor, .unknown: "New steps are on hold."
        }
    }

    /// 보내기에 필요한 연결 (`gmail.send` → Gmail). 모르는 서비스면 부제 없이
    private static func connectionSubtitle(_ capability: String?) -> String? {
        guard let service = capability?.split(separator: ".").first?.lowercased() else { return nil }
        let names = ["gmail": "Gmail", "slack": "Slack", "notion": "Notion"]
        return names[service].map { "Connect \($0) to continue." }
    }

    private static func failureSubtitle(_ kind: RunLane.FailureKind) -> String? {
        switch kind {
        case .consent: "AI processing was turned off."
        case .rejected: "The AI provider declined the request."
        case .retriesExhausted: "Stopped after several tries."
        case .actionMissing: "The task was deleted."
        case .other: nil
        }
    }
}
