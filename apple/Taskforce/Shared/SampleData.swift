#if DEBUG
import Foundation
import TaskforceKit

/// 디자인 비교용 견본 (Debug 빌드, 실행 인자 `-TFSampleData`). Figma 9:529 · 5:57과 같은 문구로 화면을 채우고 서버는 부르지 않는다.
/// 구역마다 하나 이상: Review 3 · In Progress 1 · To Do 2 · Done Today 1. To Do · In Progress · Done 옮기기도 서버 없이 반영된다.
enum SampleData {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("-TFSampleData") }
    /// 첫 동기화 화면 (`-TFSampleData -TFSampleSyncing`): 할 일 없이 Notion이 동기화 중
    static var isSyncing: Bool { ProcessInfo.processInfo.arguments.contains("-TFSampleSyncing") }
    /// 처리방침 변경 안내 (`-TFSampleData -TFSamplePolicy`: 시행된 판, `-TFSamplePolicyUpcoming`: 시행 예정 판)
    static var policyNotice: PolicyNotice? {
        let arguments = ProcessInfo.processInfo.arguments
        let links = PolicyLinks(
            ko: URL(string: "https://www.taskforcelabs.dev/ko/privacy")!,
            en: URL(string: "https://www.taskforcelabs.dev/en/privacy")!
        )
        if arguments.contains("-TFSamplePolicyUpcoming") {
            return PolicyNotice(kind: .upcoming, version: "sample-upcoming", effectiveDate: DueDateFormat.today().adding(days: 7), url: links)
        }
        guard arguments.contains("-TFSamplePolicy") else { return nil }
        return PolicyNotice(kind: .updated, version: "sample", effectiveDate: DueDateFormat.today(), url: links)
    }

    static let reviewID = UUID(uuidString: "5A000000-0000-4000-8000-000000000001")!
    /// 로그인 없이 견본 화면을 띄울 때 쓰는 사용자 id (iPhone)
    static let userID = UUID(uuidString: "5A000000-0000-4000-8000-0000000000FF")!

    static var now: NowResponse {
        let today = DueDateFormat.today()
        let review = summary(reviewID, "법무팀에 계약서 초안 전달", due: today.adding(days: 4), needsConfirmation: true)
        return NowResponse(
            now: [
                ranked(2, "계약서 검토 의견 전달", due: today.adding(days: -1), reasons: [.overdue], counterpart: "김대표"),
                ranked(3, "투자사 IR 자료 업데이트", due: today.adding(days: 3), reasons: [.dueSoon, .started], startedAt: Date(timeIntervalSinceNow: -3_600)),
                ranked(4, "채용 공고 문구 확인", due: today.adding(days: 10), reasons: []),
            ],
            confirmations: [
                review,
                summary(UUID(), "견적서 회신", due: nil, needsConfirmation: true),
                summary(UUID(), "월간 보고서 초안", due: today.adding(days: 6), needsConfirmation: true),
            ],
            weeklyCheck: nil
        )
    }

    /// 연결: Notion 하나 (첫 동기화 화면이면 동기화 중)
    static var connections: [ConnectionRecord] {
        let now = Date()
        return [
            ConnectionRecord(
                id: id(90), provider: ConnectionProvider.notion.rawValue, displayName: "Acme", status: .active,
                lastSyncedAt: isSyncing ? now : now.addingTimeInterval(-600), lastError: nil, syncStartedAt: isSyncing ? now : nil
            ),
        ]
    }

    /// 오늘 끝낸 할 일
    static var doneToday: [ActionSummary] {
        [summary(id(5), "주간 회의록 정리", due: DueDateFormat.today(), needsConfirmation: false, status: .done)]
    }

    static var evidence: [UUID: EvidenceDigest] {
        let day: TimeInterval = 86_400
        return [
            reviewID: EvidenceDigest(lines: [
                EvidenceLine(
                    id: UUID(), quote: "초안은 그쪽에서 법무팀에 넘겨 주시면 될 것 같아요", sourceID: UUID(), sourceTitle: "박이사 미팅 회의록",
                    occurredAt: Date(timeIntervalSinceNow: -4 * day), externalURL: URL(string: "https://www.notion.so/sample"), service: .notion
                ),
            ]),
            id(2): EvidenceDigest(lines: [
                EvidenceLine(
                    id: UUID(), quote: "금요일까지 검토 의견 보내드릴게요", sourceID: UUID(), sourceTitle: "김대표 미팅 회의록",
                    occurredAt: Date(timeIntervalSinceNow: -6 * day), externalURL: URL(string: "https://www.notion.so/sample"), service: .notion
                ),
                EvidenceLine(
                    id: UUID(), quote: "의견은 토요일까지 주셔도 괜찮아요", sourceID: UUID(), sourceTitle: "#sales · 김대표",
                    occurredAt: Date(timeIntervalSinceNow: -3 * day), externalURL: URL(string: "https://acme.slack.com/sample"), service: .slack
                ),
            ]),
            // 같은 Calendar 일정에 붙은 Notion 회의록 · Meet 전사: 근거 줄은 일정 제목 · 날짜, Sources는 한 회의로
            id(3): EvidenceDigest(lines: [
                EvidenceLine(
                    id: UUID(), quote: "IR 자료 숫자는 이번 주 안에 업데이트해서 공유", sourceID: UUID(), sourceTitle: "투자사 미팅 회의록",
                    occurredAt: Date(timeIntervalSinceNow: -2 * day), externalURL: URL(string: "https://www.notion.so/sample"), service: .notion,
                    meeting: irMeeting
                ),
                EvidenceLine(
                    id: UUID(), quote: "이준호: 네, 숫자 바꿔서 금요일까지 다시 보내드릴게요", sourceID: UUID(), sourceTitle: "투자사 미팅 — 한빛벤처스",
                    occurredAt: Date(timeIntervalSinceNow: -2 * day + 60),
                    externalURL: URL(string: "https://docs.google.com/document/d/sample/view"), service: .googleMeet, meeting: irMeeting
                ),
            ]),
        ]
    }

    private static let irMeeting = SourceMeeting(
        calendarEventID: "sample-event", title: "투자사 미팅 — 한빛벤처스",
        start: Date(timeIntervalSinceNow: -2 * 86_400), end: Date(timeIntervalSinceNow: -2 * 86_400 + 3_600)
    )

    /// 직접 추가: 서버 없이 Now 끝에 붙인다
    static func adding(_ title: String, due: LocalDate?, to response: NowResponse?) -> NowResponse {
        let base = response ?? now
        let added = RankedAction(action: summary(UUID(), title, due: due, needsConfirmation: false), score: 0, reasons: [], daysUntilDue: nil)
        return NowResponse(now: base.now + [added], confirmations: base.confirmations, weeklyCheck: base.weeklyCheck)
    }

    private static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "5A000000-0000-4000-8000-%012d", n))!
    }

    private static func summary(
        _ id: UUID, _ title: String, due: LocalDate?, needsConfirmation: Bool, counterpart: String? = nil,
        status: ActionStatus = .open, startedAt: Date? = nil
    ) -> ActionSummary {
        ActionSummary(
            id: id, title: title, owner: .me, status: status, dueDate: due, counterpart: counterpart,
            needsConfirmation: needsConfirmation, confirmReasons: needsConfirmation ? ["기한 확인"] : [], startedAt: startedAt,
            lastActivityAt: Date()
        )
    }

    private static func ranked(
        _ n: Int, _ title: String, due: LocalDate?, reasons: [RankReason], counterpart: String? = nil, startedAt: Date? = nil
    ) -> RankedAction {
        RankedAction(
            action: summary(id(n), title, due: due, needsConfirmation: false, counterpart: counterpart, startedAt: startedAt),
            score: Double(100 - n), reasons: reasons, daysUntilDue: nil
        )
    }
}

extension NowStore {
    /// 견본으로 채운다 (이후 `load()`는 서버를 부르지 않는다)
    func useSampleData() {
        sampleMode = true
        if SampleData.isSyncing {
            applySample(NowResponse(now: [], confirmations: [], weeklyCheck: nil), doneToday: [], evidence: [:])
        } else {
            applySample(SampleData.now, doneToday: SampleData.doneToday, evidence: SampleData.evidence)
        }
    }

    /// 견본에서 직접 추가 (`add(title:due:)`, 서버를 부르지 않는다)
    func addSample(title: String, due: LocalDate?) {
        applySample(SampleData.adding(title, due: due, to: response), doneToday: doneToday, evidence: evidence)
    }
}
#endif
