import Foundation
import Testing
@testable import TaskforceKit

enum RunFixture {
    static let action = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static let otherAction = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    static let start = Date(timeIntervalSince1970: 1_791_000_000)

    static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "99999999-0000-4000-8000-%012d", n))!
    }

    static func run(
        _ n: Int, _ state: RunState, hold: RunHoldReason? = nil, outcome: RunOutcome? = nil, action: UUID = action,
        minutes: Double = 0, stoppedAt: Date? = nil
    ) -> RunSummary {
        RunSummary(id: id(n), actionID: action, state: state, holdReason: hold, outcome: outcome, createdAt: start.addingTimeInterval(minutes * 60),
                   stoppedAt: stoppedAt)
    }

    /// run 1
    static func run(
        _ state: RunState, hold: RunHoldReason? = nil, outcome: RunOutcome? = nil, action: UUID = action, minutes: Double = 0, stoppedAt: Date? = nil
    ) -> RunSummary {
        run(1, state, hold: hold, outcome: outcome, action: action, minutes: minutes, stoppedAt: stoppedAt)
    }

    static func step(_ seq: Int, _ kind: StepKind, _ state: StepState, _ receipt: StepReceipt? = nil, run: Int = 1) -> StepSummary {
        StepSummary(id: id(100 + run * 10 + seq), runID: id(run), seq: seq, kind: kind, state: state, receipt: receipt,
                    createdAt: start.addingTimeInterval(Double(seq)))
    }

    static func draft(_ n: Int, run: Int = 1, minutes: Double = 1, purged: Bool = false, action: UUID = action) -> Artifact {
        let created = start.addingTimeInterval(minutes * 60)
        return Artifact(
            id: id(200 + n), runID: id(run), stepID: id(300 + n), actionID: action, title: "초안 \(n)", body: purged ? "" : "본문 \(n)",
            retainUntil: created.addingTimeInterval(86_400 * 90), bodyPurgedAt: purged ? created : nil, createdAt: created
        )
    }

    static let plan = step(1, .plan, .called, StepReceipt(decision: .draft))
}

/// Taskforce 갈래: 상태 × hold × outcome × 부르던 단계, 초안은 상태와 따로
struct RunLaneTests {
    typealias F = RunFixture

    @Test func noRunHidesTheLane() {
        let lane = RunLane.state(run: nil, steps: [], artifacts: [])
        #expect(lane.state == .none)
        #expect(!lane.isVisible)
        // 모르는 상태 · 초안 없음도 숨김
        #expect(!RunLane.state(run: F.run(.unknown), steps: [], artifacts: []).isVisible)
        #expect(RunLane.state(run: F.run(.unknown), steps: [], artifacts: [F.draft(1)]).isVisible)
    }

    @Test(arguments: [
        (RunState.queued, nil as RunHoldReason?, RunLane.State.working),
        (.running, nil, .working),
        (.waitingApproval, nil, .working),
        (.running, .credit, .paused(.credit)),
        (.queued, .blocked, .paused(.blocked)),
        (.running, .actor, .paused(.actor)),
        (.running, .needsConnection, .paused(.needsConnection)),
        (.running, .unknown, .paused(.unknown)),
    ])
    func openRuns(_ state: RunState, _ hold: RunHoldReason?, _ expected: RunLane.State) {
        let lane = RunLane.state(run: F.run(state, hold: hold), steps: [F.plan, F.step(2, .draft, .prepared)], artifacts: [])
        #expect(lane.state == expected)
        #expect(lane.isVisible)
    }

    @Test func draftReady() {
        let lane = RunLane.state(run: F.run(.done, outcome: .draftReady), steps: [F.plan, F.step(2, .draft, .called)], artifacts: [F.draft(1)])
        #expect(lane.state == .draftReady)
        #expect(lane.drafts.map(\.title) == ["초안 1"])
    }

    /// 계획 단계의 질문. 90일 정리로 지워졌으면(키 없음) · 빈 글이면 nil
    @Test func needsInputCarriesTheQuestion() {
        let ask = F.step(3, .plan, .called, StepReceipt(decision: .askUser, question: " 어느 고객사인가요? "))
        let lane = RunLane.state(run: F.run(.done, outcome: .needsInput), steps: [F.plan, F.step(2, .draft, .called), ask], artifacts: [F.draft(1)])
        #expect(lane.state == .needsInput(question: "어느 고객사인가요?"))
        // 앞서 만든 초안은 그대로 (View Draft)
        #expect(lane.drafts.count == 1)
        let purged = F.step(1, .plan, .called, StepReceipt(decision: .askUser))
        #expect(RunLane.state(run: F.run(.done, outcome: .needsInput), steps: [purged], artifacts: []).state == .needsInput(question: nil))
        let blank = F.step(1, .plan, .called, StepReceipt(decision: .askUser, question: "  "))
        #expect(RunLane.state(run: F.run(.done, outcome: .needsInput), steps: [blank], artifacts: []).state == .needsInput(question: nil))
    }

    @Test func needsConnectionKeepsEarlierDrafts() {
        let connect = F.step(3, .plan, .called, StepReceipt(decision: .needsConnection, capability: "gmail.send"))
        let lane = RunLane.state(
            run: F.run(.done, outcome: .needsConnection), steps: [F.plan, F.step(2, .draft, .called), connect], artifacts: [F.draft(1)]
        )
        #expect(lane.state == .needsConnection(capability: "gmail.send"))
        #expect(lane.drafts.count == 1)
    }

    @Test func doneWithoutOutcome() {
        let done = F.step(1, .plan, .called, StepReceipt(decision: .done))
        #expect(RunLane.state(run: F.run(.done), steps: [done], artifacts: []).state == .finishedWithoutDraft)
        // 모르는 결과라도 초안이 있으면 초안 있음
        #expect(RunLane.state(run: F.run(.done, outcome: .unknown), steps: [done], artifacts: [F.draft(1)]).state == .draftReady)
    }

    @Test(arguments: [
        ("consent", RunLane.FailureKind.consent), ("rejected", .rejected), ("retries_exhausted", .retriesExhausted),
        ("action_missing", .actionMissing), ("brand_new", .other),
    ])
    func failureKinds(_ error: String, _ kind: RunLane.FailureKind) {
        let lane = RunLane.state(run: F.run(.failed), steps: [F.plan, F.step(2, .draft, .failed, StepReceipt(error: error))], artifacts: [])
        #expect(lane.state == .failed(kind))
    }

    @Test func failedWithoutFailedStep() {
        #expect(RunLane.state(run: F.run(.failed), steps: [F.plan], artifacts: []).state == .failed(.other))
    }

    /// 멈춤: 부르던 단계(calling)가 남았으면 결과를 받는 중. 시각은 서버 값 (그 전 서버면 nil)
    @Test func stoppedFinishingAndTime() {
        let at = F.start.addingTimeInterval(1_200)
        let finishing = RunLane.state(run: F.run(.stopped, stoppedAt: at), steps: [F.plan, F.step(2, .draft, .calling)], artifacts: [])
        #expect(finishing.state == .stopped(finishing: true, stoppedAt: at))
        let settled = RunLane.state(run: F.run(.stopped), steps: [F.plan, F.step(2, .draft, .prepared)], artifacts: [F.draft(1)])
        #expect(settled.state == .stopped(finishing: false, stoppedAt: nil))
        #expect(settled.drafts.count == 1)
    }

    @Test func unknownRunStateShowsDraftsOnly() {
        #expect(RunLane.state(run: F.run(.unknown), steps: [], artifacts: []).state == .none)
        #expect(RunLane.state(run: F.run(.unknown), steps: [], artifacts: [F.draft(1)]).state == .draftReady)
    }

    /// 다른 run의 단계는 보지 않는다 (같은 할 일의 앞선 run이 부르는 중이어도 이 run은 멈춘 그대로)
    @Test func stepsOfOtherRunsAreIgnored() {
        let other = F.step(2, .draft, .calling, run: 2)
        #expect(RunLane.state(run: F.run(.stopped), steps: [F.plan, other], artifacts: []).state == .stopped(finishing: false, stoppedAt: nil))
    }

    /// 초안은 최근 것이 위, 모든 run (같은 할 일만)
    @Test func draftsNewestFirstAcrossRuns() {
        let lane = RunLane.state(
            run: F.run(2, .running, minutes: 10), steps: [],
            artifacts: [F.draft(1, run: 1, minutes: 1), F.draft(2, run: 1, minutes: 3), F.draft(3, action: F.otherAction)]
        )
        #expect(lane.state == .working)
        #expect(lane.drafts.map(\.title) == ["초안 2", "초안 1"])
    }

    @Test func latestRunPerAction() {
        let runs = [
            F.run(1, .done, minutes: 0), F.run(2, .running, minutes: 5), F.run(3, .failed, action: F.otherAction, minutes: 1),
        ]
        let latest = RunSummary.latestByAction(runs)
        #expect(latest[F.action]?.id == F.id(2))
        #expect(latest[F.otherAction]?.id == F.id(3))
        // 같은 시각이면 id로 정한다 (읽을 때마다 같게)
        let tie = RunSummary.latestByAction([F.run(4, .done), F.run(5, .done)])
        #expect(tie[F.action]?.id == F.id(5))
    }
}

/// `Run with AI…` 보이기 · 켜기
struct RunAvailabilityTests {
    let credits = CreditsSummary(available: 100, reserved: 0)
    let now = Date(timeIntervalSince1970: 1_791_000_000)

    @Test func iPhoneNeverStarts() {
        #expect(!RunAvailability.canStart(.iOS))
        #expect(RunAvailability.canStart(.macOS))
        #expect(RunAvailability.evaluate(platform: .iOS, credits: credits, signedIn: true, refresh: .live, hasOpenRun: false) == .hidden)
    }

    /// credits 404 · 아직 모름 → 숨김 (실행 UI 0)
    @Test func noCreditsHides() {
        let availability = RunAvailability.evaluate(platform: .macOS, credits: nil, signedIn: true, refresh: .live, hasOpenRun: false)
        #expect(availability == .hidden)
        #expect(!availability.isVisible)
    }

    @Test(arguments: [
        (true, RefreshState.live, true, false, RunAvailability.available),
        (true, .loading, true, false, .available),
        (false, .live, true, false, .disabled(.signedOut)),
        (true, .offlineSaved(since: Date(timeIntervalSince1970: 0), savedAt: Date(timeIntervalSince1970: 0)), true, false, .disabled(.offline)),
        (true, .offlineEmpty(since: Date(timeIntervalSince1970: 0)), true, false, .disabled(.offline)),
        (true, .refreshFailed(at: Date(timeIntervalSince1970: 0), savedAt: nil), true, false, .disabled(.refreshFailed)),
        (true, .live, false, false, .disabled(.notAccepting)),
        (true, .live, true, true, .disabled(.alreadyRunning)),
    ])
    func macStates(_ signedIn: Bool, _ refresh: RefreshState, _ accepting: Bool, _ open: Bool, _ expected: RunAvailability) {
        let credits = CreditsSummary(available: 0, reserved: 0, acceptingRuns: accepting)
        let availability = RunAvailability.evaluate(platform: .macOS, credits: credits, signedIn: signedIn, refresh: refresh, hasOpenRun: open)
        #expect(availability == expected)
        #expect(availability.isVisible)
        #expect(availability.isEnabled == (expected == .available))
    }
}

/// 다시 읽는 간격: 움직이는 run(끝나지 않음 · 멈췄는데 부르던 단계가 남음)이 있을 때만, 처음 30초 3초 → 10초, 막힌 run뿐이면 60초
struct RunPollingTests {
    typealias F = RunFixture
    let since = RunFixture.start

    @Test func busyRuns() {
        #expect(RunPolling.isBusy(F.run(.running), steps: []))
        #expect(RunPolling.isBusy(F.run(.queued, hold: .credit), steps: []))
        #expect(!RunPolling.isBusy(F.run(.done), steps: [F.plan]))
        // 멈췄는데 부르던 단계가 남음 (Finishing the current step.)
        #expect(RunPolling.isBusy(F.run(.stopped), steps: [F.plan, F.step(2, .draft, .calling)]))
        #expect(!RunPolling.isBusy(F.run(.stopped), steps: [F.plan, F.step(2, .draft, .called)]))
        // 다른 run의 단계는 보지 않는다
        #expect(!RunPolling.isBusy(F.run(.stopped), steps: [F.step(2, .draft, .calling, run: 2)]))
        #expect(!RunPolling.isBusy(F.run(.unknown), steps: [F.step(2, .draft, .calling)]))
    }

    @Test func noBusyRunNoPolling() {
        #expect(RunPolling.interval(busyRuns: [], watchingSince: since, now: since) == nil)
    }

    @Test(arguments: [(0.0, Duration.seconds(3)), (29.9, .seconds(3)), (30, .seconds(10)), (600, .seconds(10))])
    func fastThenSlow(_ elapsed: TimeInterval, _ expected: Duration) {
        #expect(RunPolling.interval(busyRuns: [F.run(.running)], watchingSince: since, now: since.addingTimeInterval(elapsed)) == expected)
        // 결과를 받는 중인 멈춘 run도 같은 간격
        #expect(RunPolling.interval(busyRuns: [F.run(.stopped)], watchingSince: since, now: since.addingTimeInterval(elapsed)) == expected)
    }

    @Test func heldRunsPollEveryMinute() {
        let held = [F.run(.running, hold: .credit), F.run(2, .queued, hold: .blocked)]
        #expect(RunPolling.interval(busyRuns: held, watchingSince: since, now: since) == .seconds(60))
        // 하나라도 막히지 않았으면 그 run의 간격
        #expect(RunPolling.interval(busyRuns: held + [F.run(3, .running)], watchingSince: since, now: since) == .seconds(3))
    }

    @Test func finishedDetection() {
        let a = F.id(1)
        let b = F.id(2)
        #expect(RunPolling.finished(before: [a, b], after: [b]) == [a])
        #expect(RunPolling.finished(before: [a], after: [a]).isEmpty)
        // 처음 본 run이 이미 끝나 있으면 끝남 신호가 아니다
        #expect(RunPolling.finished(before: [], after: []).isEmpty)
    }
}

/// Stop Taskforce · Delete · Done 전에 멈출 run: 그 할 일의 끝나지 않은 run 전부
struct RunStopTests {
    typealias F = RunFixture

    @Test func allOpenRunsOfTheTask() {
        let runs = [
            F.run(1, .running, minutes: 0), F.run(2, .queued, hold: .credit, minutes: 5), F.run(3, .done, minutes: 9),
            F.run(4, .running, action: F.otherAction), F.run(5, .waitingApproval, minutes: 2), F.run(6, .unknown),
        ]
        #expect(RunStop.targets(actionID: F.action, runs: runs) == [F.id(2), F.id(5), F.id(1)])
        #expect(RunStop.targets(actionID: F.otherAction, runs: runs) == [F.id(4)])
        #expect(RunStop.targets(actionID: F.action, runs: [F.run(.stopped)]).isEmpty)
    }
}

struct ArtifactLinkTests {
    @Test func parsesReceiptLinks() {
        let id = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
        #expect(ArtifactLink.parse(URL(string: "taskforce://artifacts/77777777-7777-4777-8777-777777777777")!) == id)
        #expect(ArtifactLink.parse(URL(string: "TASKFORCE://Artifacts/77777777-7777-4777-8777-777777777777")!) == id)
        #expect(ArtifactLink.url(for: id).absoluteString == "taskforce://artifacts/77777777-7777-4777-8777-777777777777")
        #expect(ArtifactLink.parse(ArtifactLink.url(for: id)) == id)
    }

    @Test(arguments: [
        "taskforce://artifacts/", "taskforce://artifacts/not-a-uuid", "taskforce://connections/notion?status=connected",
        "taskforce://artifacts/77777777-7777-4777-8777-777777777777/extra", "https://artifacts/77777777-7777-4777-8777-777777777777",
    ])
    func rejectsOtherLinks(_ string: String) {
        #expect(ArtifactLink.parse(URL(string: string)!) == nil)
    }

    @Test func notFoundCopy() {
        #expect(ArtifactLink.notFoundMessage == "Draft not found.")
    }
}
