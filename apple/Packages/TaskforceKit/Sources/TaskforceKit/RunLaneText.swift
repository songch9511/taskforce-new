import Foundation

/// 상세의 Taskforce 갈래 글 (`RunLane` → 제목 · 부제 · `View Draft`): Mac 런처(Figma M1 · M12 · M17)와 iPhone 상세(P2 · P9)가 같이 쓴다.
/// 기기마다 다른 것은 둘뿐이다 (`platform`):
/// - 멈춤: iPhone은 P9대로 시각을 문장에 넣는다 (`Stop requested 14:20. No new steps will start.`). Mac은 M17대로 문장에 시각 없이,
///   시각은 액션 바에 (`stopRequested`)
/// - 실행 주체 밖으로 멈춤: Mac은 `Run with AI isn't available for this account.`, iPhone은 `Run with AI`라는 말을 쓰지 않는다 (run을 시작하지 않는다)
/// Figma에 있는 문구: M12 `Draft paused` · `Not enough credits. The draft will resume when credits are added.`, M17 `Stopped. No new steps will start.` · `Stop requested 14:20`, P9.
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

    /// 멈추기를 보낸 뒤 VoiceOver 알림 (Mac과 같은 말)
    public static let stopAnnouncement = "Stop requested"
    /// 지켜보던 run이 초안을 냈을 때 VoiceOver 알림
    public static let draftAnnouncement = "Draft ready"
    /// `View Draft` 버튼
    public static let viewDraft = "View Draft"

    /// 보일 갈래가 없으면 nil (`RunLane.isVisible`)
    public static func make(
        _ lane: RunLane, platform: RunPlatform = .current, now: Date = Date(), timeZone: TimeZone = .current
    ) -> RunLaneText? {
        guard lane.isVisible else { return nil }
        let draft = lane.drafts.first
        func clock(_ date: Date) -> String { Self.clock(date, now: now, timeZone: timeZone) }
        switch lane.state {
        case .none, .draftReady:
            // `.none`이면서 보이는 갈래는 초안만 있는 경우다. 제목은 초안 제목 (M1)
            guard let draft else { return RunLaneText(title: "Draft ready") }
            let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let count = lane.drafts.count
            let label = count == 1 ? "AI draft" : "\(count) AI drafts"
            return RunLaneText(
                title: title.isEmpty ? "Draft ready" : title, subtitle: "\(label) · \(clock(draft.createdAt))",
                spokenState: title.isEmpty ? nil : "Draft ready", draft: draft
            )
        case .working:
            return RunLaneText(title: "Writing draft", subtitle: lane.run.map { "Started \(clock($0.createdAt))" }, draft: draft)
        case .paused(.credit):
            return RunLaneText(title: "Draft paused", subtitle: "Not enough credits. The draft will resume when credits are added.", draft: draft)
        case .paused(let reason):
            return RunLaneText(title: "Paused", subtitle: pausedSubtitle(reason, platform: platform), draft: draft)
        case .needsInput(let question):
            return RunLaneText(title: "Taskforce has a question", subtitle: question ?? "Question deleted after 90 days.", draft: draft)
        case .needsConnection(let capability):
            return RunLaneText(title: "Needs a connection", subtitle: connectionSubtitle(capability), draft: draft)
        case .stopped(let finishing, let stoppedAt):
            let stopped = "Stopped. No new steps will start."
            let title = platform == .iOS ? stoppedAt.map { "Stop requested \(clock($0)). No new steps will start." } ?? stopped : stopped
            return RunLaneText(title: title, subtitle: finishing ? "Finishing the current step." : nil, draft: draft)
        case .failed(let kind):
            return RunLaneText(title: "Couldn't finish the draft", subtitle: failureSubtitle(kind), draft: draft)
        case .finishedWithoutDraft:
            return RunLaneText(title: "No draft needed", draft: draft)
        }
    }

    /// Mac 액션 바 왼쪽 (Figma M17 `Stop requested 14:20`, 정지 기호). 시각은 서버 `stopped_at`(어느 기기에서 멈췄든).
    /// 없으면(사용자가 멈추지 않음: 할 일을 끝내 서버가 멈춤 · 그 전 서버) 막대에 보이지 않는다 (갈래 문장만)
    public static func stopRequested(_ lane: RunLane, now: Date = Date(), timeZone: TimeZone = .current) -> String? {
        guard case .stopped(_, let stoppedAt?) = lane.state else { return nil }
        return "Stop requested \(clock(stoppedAt, now: now, timeZone: timeZone))"
    }

    /// 보고 있는 할 일의 상태가 바뀌면 VoiceOver가 읽는 한 마디 (Mac 런처)
    public static func announcement(_ state: RunLane.State) -> String? {
        switch state {
        case .draftReady: draftAnnouncement
        case .stopped(_, let stoppedAt): stoppedAt == nil ? "Stopped" : stopAnnouncement
        default: nil
        }
    }

    /// 갈래의 시각: 오늘이면 24시간제 "14:20" · "8:01" (`RefreshState.statusText`와 같은 모양), 아니면 "Oct 2" (Mac 갈래와 같다)
    public static func clock(_ date: Date, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let day = LocalDate(date: date, timeZone: timeZone)
        let today = LocalDate(date: now, timeZone: timeZone)
        guard day == today else { return DueText.date(day, today: today) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    private static func pausedSubtitle(_ reason: RunHoldReason, platform: RunPlatform) -> String? {
        switch reason {
        case .actor where platform == .macOS: "Run with AI isn't available for this account."
        case .blocked, .actor: "New steps are paused for now."
        case .needsConnection: "Needs a connection to continue."
        case .credit, .unknown: nil
        }
    }

    /// 보내기에 필요한 연결 (`gmail.send` → "Connect Gmail to continue.")
    private static func connectionSubtitle(_ capability: String?) -> String {
        let service = capability?.split(separator: ".").first.flatMap { serviceNames[$0.lowercased()] }
        return service.map { "Connect \($0) to continue." } ?? "Connect a service to continue."
    }

    private static let serviceNames = [
        "gmail": "Gmail", "slack": "Slack", "notion": "Notion", "calendar": "Google Calendar", "google": "Google",
    ]

    private static func failureSubtitle(_ kind: RunLane.FailureKind) -> String? {
        switch kind {
        case .consent: "AI processing was turned off."
        case .rejected: "The AI provider declined this request."
        case .aiPricingUnavailable: "AI is unavailable because its price limit cannot be verified."
        case .aiProviderBoundViolation: "AI is paused because a provider exceeded its reserved cost."
        case .aiBudgetExhausted: "Your beta AI allowance cannot cover this request. Check Usage & Credits."
        case .retriesExhausted: "Stopped after too many retries."
        case .actionMissing: "The task was deleted."
        case .other: nil
        }
    }
}
