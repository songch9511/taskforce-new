#if DEBUG
import Foundation
import TaskforceKit

/// 디자인 비교용 견본 (Debug 빌드, 실행 인자 `-TFSampleData`). Figma 156:6 M1(Mac) · P1(iPhone)과 같은 목록으로 화면을 채우고 서버는 부르지 않는다.
/// Review 4 · In Progress 5 · To Do 14 · Done Today 6 (M13 All Tasks 23). To Do · In Progress · Done 옮기기도 서버 없이 반영된다.
/// 상태 견본 (Mac 런처 U1 PR4): `-TFSampleOffline` 오프라인(M15) · `-TFSampleRefreshFailed` 새로고침 실패(M19) — 저장본을 보인다.
/// `-TFSampleNoSaved`를 더하면 저장본 없음(M20 · 실패 빈 화면). `-TFSampleEmpty` 할 일 없음(M21) · `-TFSampleLoading` 처음 불러오는 중.
/// `-TFSampleOfflineLoaded`: 받은 목록을 그대로 둔 채 오프라인 (iPhone P10의 Review 카드 전체 + 꺼진 버튼).
enum SampleData {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("-TFSampleData") }
    /// 첫 동기화 화면 (`-TFSampleData -TFSampleSyncing`): 할 일 없이 Notion이 동기화 중
    static var isSyncing: Bool { ProcessInfo.processInfo.arguments.contains("-TFSampleSyncing") }
    static var isOffline: Bool { ProcessInfo.processInfo.arguments.contains("-TFSampleOffline") }
    /// 이번 실행에서 목록을 받은 뒤 끊김 (`-TFSampleOfflineLoaded`): 받은 목록(확인 이유 · 원문 포함) 그대로 오프라인 (iPhone P10)
    static var isOfflineLoaded: Bool { ProcessInfo.processInfo.arguments.contains("-TFSampleOfflineLoaded") }
    static var isRefreshFailed: Bool { ProcessInfo.processInfo.arguments.contains("-TFSampleRefreshFailed") }
    static var hasNoSaved: Bool { ProcessInfo.processInfo.arguments.contains("-TFSampleNoSaved") }
    static var isEmpty: Bool { ProcessInfo.processInfo.arguments.contains("-TFSampleEmpty") }
    static var isLoading: Bool { ProcessInfo.processInfo.arguments.contains("-TFSampleLoading") }
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
    /// M1에서 고른 행 (In Progress 첫 줄)
    static let demoID = id(10)
    /// 바뀜 점 견본 (마지막으로 본 뒤 다른 사람이 바꿈)
    static let changedID = id(12)

    static var now: NowResponse {
        let today = DueDateFormat.today()
        // 확인 이유는 Review마다 다르게 (상세의 한 줄, `ConfirmReasonText`)
        let reviews = [
            summary(reviewID, "제안서 v2 보내기", due: today, needsConfirmation: true, reasons: ["판정 확인: NOT_MY_ACTION", "기한 확인"]),
            summary(id(2), "가입 단계 축소", due: today.adding(days: 3), needsConfirmation: true, reasons: ["병합 확인 (55%)"]),
            summary(id(3), "견적서 회신", due: nil, needsConfirmation: true, reasons: ["판정 확인: ALREADY_DONE"]),
            summary(id(4), "월간 보고서 초안", due: today.adding(days: 6), needsConfirmation: true),
        ]
        let started = Date(timeIntervalSinceNow: -3_600)
        let inProgress = [
            ranked(10, "금요일 고객 데모 준비 (새 온보딩, 결제 화면 포함)", due: today.adding(days: 6), startedAt: started),
            ranked(11, "온보딩 디자인 시안", due: today, reasons: [.dueToday], startedAt: started),
            ranked(12, "지훈에게 디자인 인계", due: today.adding(days: 6), startedAt: started, changed: true),
            ranked(13, "해외 파트너 요구사항을 반영한 다음 주 경영진 리뷰 발표 자료 정리", due: today.adding(days: 3), startedAt: started),
            ranked(14, "데모 환경 배포", due: today.adding(days: 6), startedAt: started),
        ]
        let toDoTitles: [(String, Int?)] = [
            ("QA 시나리오 업데이트", 2), ("계약서 변경 사항 검토", 6), ("고객 인터뷰 12건 요약과 인사이트 정리", 4),
            ("투자사 월간 업데이트 메일 작성", 2), ("다음 스프린트 계획", 9), ("채용 공고 문구 확인", 10), ("투자사 IR 자료 업데이트", 11),
            ("법무팀에 계약서 초안 전달", 12), ("파트너사 API 키 교체", 13), ("분기 OKR 초안", 14), ("고객 지원 매크로 정리", nil),
            ("디자인 시스템 색 점검", nil), ("온보딩 메일 문구 다듬기", nil), ("팀 회고 일정 잡기", nil),
        ]
        let toDo = toDoTitles.enumerated().map { index, item in
            ranked(20 + index, item.0, due: item.1.map { today.adding(days: $0) })
        }
        return NowResponse(
            now: inProgress + toDo,
            confirmations: reviews,
            weeklyCheck: nil,
            tracksChanges: true
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
        ["주간 회의록 정리", "견적서 v1 보내기", "회의실 예약", "급여 이체 확인", "릴리스 노트 공유", "고객 피드백 분류"].enumerated().map { index, title in
            summary(id(50 + index), title, due: DueDateFormat.today(), needsConfirmation: false, status: .done)
        }
    }

    /// 저장본 견본: 견본 목록의 제목 · 기한 · 상태 (오늘 10:31에 저장)
    static var saved: SavedNow {
        SavedNow(sections: TaskBoard(now: now, doneToday: doneToday).sections(), savedAt: today(10, 31))
    }

    /// 오늘 그 시각 (기기 시간대)
    static func today(_ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }

    static var evidence: [UUID: EvidenceDigest] {
        let day: TimeInterval = 86_400
        return [
            reviewID: EvidenceDigest(lines: [
                EvidenceLine(
                    id: UUID(), quote: "제안서 v2는 오늘 안에 민서 님께 보내 주세요", sourceID: UUID(), sourceTitle: "#sales · 민서",
                    occurredAt: Date(timeIntervalSinceNow: -1 * day), externalURL: URL(string: "https://acme.slack.com/sample"), service: .slack
                ),
            ]),
            demoID: EvidenceDigest(lines: [
                EvidenceLine(
                    id: UUID(), quote: "금요일 데모는 제가 준비할게요.", sourceID: UUID(), sourceTitle: "제품 회의록",
                    occurredAt: Date(timeIntervalSinceNow: -5 * day), externalURL: URL(string: "https://www.notion.so/sample"), service: .notion
                ),
            ]),
            id(21): EvidenceDigest(lines: [
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
            id(26): EvidenceDigest(lines: [
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
        return NowResponse(
            now: base.now + [added], confirmations: base.confirmations, weeklyCheck: base.weeklyCheck, failedSources: base.failedSources,
            sectionLimits: base.sectionLimits, changedConfirmations: base.changedConfirmations, tracksChanges: base.tracksChanges
        )
    }

    private static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "5A000000-0000-4000-8000-%012d", n))!
    }

    private static func summary(
        _ id: UUID, _ title: String, due: LocalDate?, needsConfirmation: Bool, reasons: [String] = ["기한 확인"],
        counterpart: String? = nil, status: ActionStatus = .open, startedAt: Date? = nil
    ) -> ActionSummary {
        ActionSummary(
            id: id, title: title, owner: .me, status: status, dueDate: due, counterpart: counterpart,
            needsConfirmation: needsConfirmation, confirmReasons: needsConfirmation ? reasons : [], startedAt: startedAt,
            lastActivityAt: Date()
        )
    }

    private static func ranked(
        _ n: Int, _ title: String, due: LocalDate?, reasons: [RankReason] = [], counterpart: String? = nil, startedAt: Date? = nil,
        changed: Bool = false
    ) -> RankedAction {
        RankedAction(
            action: summary(id(n), title, due: due, needsConfirmation: false, counterpart: counterpart, startedAt: startedAt),
            score: Double(100 - n), reasons: reasons, daysUntilDue: nil, changed: changed
        )
    }
}

/// 실행(U2) 견본 (Debug 빌드, U2 Mac 계획 §2): 서버를 부르지 않고 갈래 · S3 상태를 채운다. `-TFSampleData`와 함께 쓴다.
/// 갈래 견본은 M1에서 고른 행(`SampleData.demoID`, 금요일 고객 데모 준비)의 run 하나:
/// `-TFSampleRunWorking` · `-TFSampleRunDraftReady` · `-TFSampleRunCredit` · `-TFSampleRunStopped` · `-TFSampleRunStoppedFinishing` ·
/// `-TFSampleRunFailed` · `-TFSampleRunNeedsInput` · `-TFSampleRunNeedsConnection` · `-TFSampleRunPurged`.
/// `-TFSampleCredits`: S3 Figma 값 (Available 0 · Reserved 12 · Pending Unknown · Used 188 · 멈춘 2건). `-TFSampleNoExecution`: credits 404 (실행 UI 없음).
/// 견본 인자가 없으면 실행을 쓸 수 없는 계정처럼 둔다 (실행 UI가 보이지 않는다).
enum SampleRuns {
    enum Lane: String, CaseIterable {
        case working = "-TFSampleRunWorking"
        case draftReady = "-TFSampleRunDraftReady"
        case credit = "-TFSampleRunCredit"
        case stopped = "-TFSampleRunStopped"
        case stoppedFinishing = "-TFSampleRunStoppedFinishing"
        case failed = "-TFSampleRunFailed"
        case needsInput = "-TFSampleRunNeedsInput"
        case needsConnection = "-TFSampleRunNeedsConnection"
        case purged = "-TFSampleRunPurged"
    }

    static var lane: Lane? {
        let arguments = ProcessInfo.processInfo.arguments
        return Lane.allCases.first { arguments.contains($0.rawValue) }
    }

    static var showsCredits: Bool { ProcessInfo.processInfo.arguments.contains("-TFSampleCredits") }
    static var noExecution: Bool { ProcessInfo.processInfo.arguments.contains("-TFSampleNoExecution") }

    static let runID = UUID(uuidString: "5A000000-0000-4000-8000-0000000000A1")!
    static let earlierRunID = UUID(uuidString: "5A000000-0000-4000-8000-0000000000A2")!
    /// S3 견본: 크레딧이 모자라 멈춘 run 둘 (QA 시나리오 업데이트 · 계약서 변경 사항 검토)
    static let pausedActionIDs = [sampleActionID(20), sampleActionID(21)]
    /// S3 견본: 원가를 확인하는 중인 할 일 (지훈에게 디자인 인계)
    static let settlingActionID = SampleData.changedID

    /// S3 Figma 값: Available 0 · Reserved 12 (32 − 정산 보류 20) · Pending Unknown · Used 188 · 진행 중 run 1
    static func creditsSummary(now: Date = Date()) -> CreditsSummary {
        CreditsSummary(
            available: 0, reserved: 32, rateVersion: "c3-v1", runningRuns: 1,
            settling: .init(steps: 1, reserved: 20, actionIDs: [settlingActionID]),
            used: .init(credits: 188, since: CreditsMonth.start(of: now)), acceptingRuns: true, draftEstimateCredits: 20
        )
    }

    /// 갈래 견본의 크레딧 (잔액이 넉넉함, 크레딧 견본이면 0)
    static func laneCredits(_ lane: Lane) -> CreditsSummary {
        if lane == .credit { return creditsSummary() }
        return CreditsSummary(available: 480, reserved: lane == .working ? 20 : 0, rateVersion: "c3-v1", runningRuns: lane == .working ? 1 : 0,
                              acceptingRuns: true, draftEstimateCredits: 20)
    }

    /// 갈래 견본 하나 (run · 단계 · 초안)
    static func fixture(_ lane: Lane, now: Date = Date()) -> (runs: [RunSummary], steps: [StepSummary], drafts: [Artifact]) {
        let action = SampleData.demoID
        let started = now.addingTimeInterval(-6 * 60)
        func run(_ state: RunState, hold: RunHoldReason? = nil, outcome: RunOutcome? = nil, stoppedAt: Date? = nil) -> RunSummary {
            RunSummary(id: runID, actionID: action, state: state, holdReason: hold, outcome: outcome, createdAt: started, stoppedAt: stoppedAt)
        }
        func step(_ seq: Int, _ kind: StepKind, _ state: StepState, _ receipt: StepReceipt? = nil, run: UUID = runID) -> StepSummary {
            StepSummary(id: sampleStepID(run == runID ? seq : 10 + seq), runID: run, seq: seq, kind: kind, state: state, receipt: receipt,
                        createdAt: started.addingTimeInterval(Double(seq) * 20))
        }
        let plan = step(1, .plan, .called, StepReceipt(decision: .draft))
        func draft(purged: Bool = false, run: UUID = runID, at: Date? = nil) -> Artifact {
            let created = at ?? started.addingTimeInterval(90)
            return Artifact(
                id: sampleArtifactID(run == runID ? 1 : 2), runID: run, stepID: sampleStepID(run == runID ? 2 : 12), actionID: action,
                title: "데모 예상 질문과 답변 초안", body: purged ? "" : draftBody, model: "sample", promptVersion: "sample",
                retainUntil: created.addingTimeInterval(86_400 * 90), bodyPurgedAt: purged ? now : nil, createdAt: created
            )
        }
        switch lane {
        case .working:
            return ([run(.running)], [plan, step(2, .draft, .calling)], [])
        case .draftReady:
            return ([run(.done, outcome: .draftReady)], [plan, step(2, .draft, .called), step(3, .plan, .called, StepReceipt(decision: .done))], [draft()])
        case .credit:
            return ([run(.running, hold: .credit)], [plan, step(2, .draft, .prepared)], [])
        case .stopped:
            return ([run(.stopped, stoppedAt: SampleData.today(14, 20))], [plan, step(2, .draft, .prepared)], [])
        case .stoppedFinishing:
            return ([run(.stopped, stoppedAt: SampleData.today(14, 20))], [plan, step(2, .draft, .calling)], [])
        case .failed:
            return ([run(.failed)], [plan, step(2, .draft, .failed, StepReceipt(error: "rejected"))], [])
        case .needsInput:
            let ask = step(1, .plan, .called, StepReceipt(decision: .askUser, question: "데모는 어느 고객사 대상인가요?"))
            return ([run(.done, outcome: .needsInput)], [ask], [])
        case .needsConnection:
            // 앞선 run이 만든 초안은 그대로 (A39): 어느 상태든 View Draft
            let earlier = RunSummary(id: earlierRunID, actionID: action, state: .done, outcome: .draftReady, createdAt: started.addingTimeInterval(-86_400))
            let connect = step(1, .plan, .called, StepReceipt(decision: .needsConnection, capability: "gmail.send"))
            return ([run(.done, outcome: .needsConnection), earlier], [connect], [draft(run: earlierRunID, at: earlier.createdAt.addingTimeInterval(90))])
        case .purged:
            let old = now.addingTimeInterval(-86_400 * 91)
            let oldRun = RunSummary(id: runID, actionID: action, state: .done, outcome: .draftReady, createdAt: old)
            return ([oldRun], [plan, step(2, .draft, .called)], [draft(purged: true, at: old.addingTimeInterval(90))])
        }
    }

    /// S3 견본의 멈춘 run 둘
    static func pausedRuns(now: Date = Date()) -> [RunSummary] {
        pausedActionIDs.enumerated().map { index, action in
            RunSummary(id: sampleRunID(10 + index), actionID: action, state: .running, holdReason: .credit,
                       createdAt: now.addingTimeInterval(Double(-3_600 * (index + 1))))
        }
    }

    private static let draftBody = """
    민서 님, 금요일 데모에서 나올 만한 질문과 답변을 정리했습니다.

    1. 결제 단계에서 이탈이 많은 이유는 무엇인가요?
    카드 등록 화면이 두 번 나와서였습니다. 새 온보딩에서 한 번으로 줄였습니다.

    2. 개인정보는 어디에 저장되나요?
    서울 리전에만 저장하고, 보관 기간이 지나면 지웁니다.
    """

    private static func sampleActionID(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "5A000000-0000-4000-8000-%012d", n))!
    }

    private static func sampleRunID(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "5A000000-0000-4000-8000-0000000A%04d", n))!
    }

    private static func sampleStepID(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "5A000000-0000-4000-8000-0000000B%04d", n))!
    }

    private static func sampleArtifactID(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "5A000000-0000-4000-8000-0000000C%04d", n))!
    }
}

extension RunStore {
    /// 견본으로 채운다 (이후 읽기 · 쓰기는 서버를 부르지 않는다). 견본 인자가 없으면 실행을 쓸 수 없는 계정처럼 둔다
    func useSampleData(now: Date = Date()) {
        if SampleRuns.noExecution {
            applySample(credits: .unavailable, runs: [], steps: [], drafts: [])
        } else if SampleRuns.showsCredits {
            applySample(
                credits: .available(SampleRuns.creditsSummary(now: now), checkedAt: SampleData.today(16, 10)),
                runs: SampleRuns.pausedRuns(now: now), steps: [], drafts: [], paused: SampleRuns.pausedRuns(now: now)
            )
        } else if let lane = SampleRuns.lane {
            let fixture = SampleRuns.fixture(lane, now: now)
            applySample(
                credits: .available(SampleRuns.laneCredits(lane), checkedAt: now), runs: fixture.runs, steps: fixture.steps,
                drafts: fixture.drafts, paused: lane == .credit ? fixture.runs : []
            )
        } else {
            applySample(credits: .unavailable, runs: [], steps: [], drafts: [])
        }
    }
}

extension NowStore {
    /// 견본으로 채운다 (이후 `load()`는 서버를 부르지 않는다)
    func useSampleData() {
        sampleMode = true
        if SampleData.isSyncing || SampleData.isEmpty {
            applySample(NowResponse(now: [], confirmations: [], weeklyCheck: nil), doneToday: [], evidence: [:])
        } else {
            applySample(SampleData.now, doneToday: SampleData.doneToday, evidence: SampleData.evidence)
        }
        let saved = SampleData.hasNoSaved ? nil : SampleData.saved
        if SampleData.isOffline {
            // M15 "Offline since 10:41." (저장본 없으면 M20 "Offline since 8:01.")
            applySampleState(saved: saved, offlineSince: saved == nil ? SampleData.today(8, 1) : SampleData.today(10, 41), failedAt: nil)
        } else if SampleData.isRefreshFailed {
            // M19 "Couldn’t refresh at 10:46. Showing 10:31."
            applySampleState(saved: saved, offlineSince: nil, failedAt: SampleData.today(10, 46))
        } else if SampleData.isLoading {
            applySampleState(saved: nil, offlineSince: nil, failedAt: nil)
        } else if SampleData.isOfflineLoaded {
            // P10 "Offline since 10:41. Showing saved tasks." (10:31에 받은 목록)
            applySampleOffline(loadedAt: SampleData.today(10, 31), since: SampleData.today(10, 41))
        }
    }

    /// 견본에서 직접 추가 (`add(title:due:)`, 서버를 부르지 않는다)
    func addSample(title: String, due: LocalDate?) {
        applySample(SampleData.adding(title, due: due, to: response), doneToday: doneToday, evidence: evidence)
    }
}
#endif
