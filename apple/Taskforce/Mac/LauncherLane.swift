#if os(macOS)
import SwiftUI
import TaskforceKit
import TaskforceUI

/// 상세의 Taskforce 갈래 (Figma M1 Lane · Taskforce 181:1642 · M12 · M17): 할 일의 최신 run이 있거나 초안이 있을 때만 보인다.
/// 초안이 있으면 상태와 상관없이 `View Draft` (멈춤 · 실패 · needs_*에도 앞서 만든 초안이 있을 수 있다, A39). Tab · →로 버튼에 옮겨 ↩로 연다.
struct LauncherLaneView: View {
    @Bindable var model: LauncherModel
    let target: LauncherModel.Target

    var body: some View {
        if let lane = model.lane(for: target.action.id) {
            let card = LauncherLaneText.card(lane)
            LaneCard(
                heading: "Taskforce", title: card.title, subtitle: card.subtitle,
                action: lane.drafts.first.map { draft in
                    LaneCard.Action("View Draft", isFocused: model.laneFocusTarget?.action.id == target.action.id) {
                        model.openDraft(draft, for: target)
                    }
                }
            )
            // 보고 있는 할 일의 상태가 바뀌면 VoiceOver가 알린다 (Draft ready · Stop requested). 다른 할 일로 옮긴 것은 알리지 않는다
            .onChange(of: Announcement(id: target.action.id, text: LauncherLaneText.announcement(lane.state))) { old, new in
                guard old.id == new.id, let text = new.text, old.text != text else { return }
                AccessibilityNotification.Announcement(text).post()
            }
        }
    }

    private struct Announcement: Equatable {
        let id: UUID
        let text: String?
    }
}

/// 갈래 문구 (Figma M1 · M12 · M17, Figma에 없는 상태 · 부제는 후보 — U2 Mac 계획 PR3 표).
/// 상태는 서버 값으로 `RunLane`이 정하고 여기서는 Mac 문장으로만 옮긴다. 시각은 오늘이면 "14:20", 아니면 "Oct 2".
enum LauncherLaneText {
    struct Card: Equatable {
        let title: String
        let subtitle: String?
    }

    static func card(_ lane: RunLane, now: Date = Date(), timeZone: TimeZone = .current) -> Card {
        switch lane.state {
        case .working:
            return Card(title: "Writing draft", subtitle: lane.run.map { "Started \(clock($0.createdAt, now: now, timeZone: timeZone))" })
        case .paused(.credit):
            // 부제는 Figma M12
            return Card(title: "Draft paused", subtitle: "Not enough credits. New paid steps are paused.")
        case .paused(let reason):
            return Card(title: "Paused", subtitle: paused(reason))
        case .needsInput(let question):
            return Card(title: "Taskforce has a question", subtitle: question ?? "Question deleted after 90 days.")
        case .needsConnection(let capability):
            return Card(title: "Needs a connection", subtitle: connection(capability))
        case .stopped(let finishing, _):
            // 제목은 Figma M17
            return Card(title: "Stopped. No new steps will start.", subtitle: finishing ? "Finishing the current step." : nil)
        case .failed(let kind):
            return Card(title: "Couldn't finish the draft", subtitle: failure(kind))
        case .finishedWithoutDraft:
            return Card(title: "No draft needed", subtitle: nil)
        case .draftReady, .none:
            // M1: 제목은 초안 제목
            guard let latest = lane.drafts.first else { return Card(title: "Draft ready", subtitle: nil) }
            let when = clock(latest.createdAt, now: now, timeZone: timeZone)
            let count = lane.drafts.count
            return Card(title: latest.title, subtitle: count == 1 ? "AI draft · \(when)" : "\(count) AI drafts · \(when)")
        }
    }

    /// 액션 바 왼쪽 (Figma M17 `Stop requested 14:20`, 정지 기호). 시각은 서버 `stopped_at`(어느 기기에서 멈췄든).
    /// 없으면(사용자가 멈추지 않음: 할 일을 끝내 서버가 멈춤 · 그 전 서버) 막대에 보이지 않는다 (갈래 문장만)
    static func stopRequested(_ lane: RunLane, now: Date = Date(), timeZone: TimeZone = .current) -> String? {
        guard case .stopped(_, let stoppedAt?) = lane.state else { return nil }
        return "Stop requested \(clock(stoppedAt, now: now, timeZone: timeZone))"
    }

    /// 상태가 바뀌면 VoiceOver가 읽는 한 마디
    static func announcement(_ state: RunLane.State) -> String? {
        switch state {
        case .draftReady: "Draft ready"
        case .stopped(_, let stoppedAt): stoppedAt == nil ? "Stopped" : "Stop requested"
        default: nil
        }
    }

    /// 오늘이면 24시간제 "14:20" · "8:01" (`RefreshState.statusText`와 같은 모양), 아니면 "Oct 2"
    static func clock(_ date: Date, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let day = LocalDate(date: date, timeZone: timeZone)
        let today = LocalDate(date: now, timeZone: timeZone)
        guard day == today else { return DueText.date(day, today: today) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    private static func paused(_ reason: RunHoldReason) -> String? {
        switch reason {
        case .blocked: "New steps are paused for now."
        case .actor: "Run with AI isn't available for this account."
        case .needsConnection: "Needs a connection to continue."
        case .credit, .unknown: nil
        }
    }

    /// "gmail.send" → "Connect Gmail to continue."
    private static func connection(_ capability: String?) -> String {
        let service = capability?.split(separator: ".").first.flatMap { serviceNames[$0.lowercased()] }
        return service.map { "Connect \($0) to continue." } ?? "Connect a service to continue."
    }

    private static let serviceNames = [
        "gmail": "Gmail", "slack": "Slack", "notion": "Notion", "calendar": "Google Calendar", "google": "Google",
    ]

    private static func failure(_ kind: RunLane.FailureKind) -> String? {
        switch kind {
        case .consent: "AI processing was turned off."
        case .rejected: "The AI provider declined this request."
        case .retriesExhausted: "Stopped after too many retries."
        case .actionMissing: "The task was deleted."
        case .other: nil
        }
    }
}
#endif
