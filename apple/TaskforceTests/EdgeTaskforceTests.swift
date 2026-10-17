import AppKit
import Foundation
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// Taskforce 대화 시험의 틀 (OA U3): 진짜 `NowStore` · `ReviewDesk` · `ReturnSummaryStore` · `IssueRuntime`(가짜 서버 `IssueSampleGateway`)을 한 셸에 묶는다.
/// 서버 호출은 모두 가짜 네트워크 · 가짜 gateway 위다 (실제 서버 호출 0). 시계는 셸의 주입 시계(`EdgeSchedule`)를 손으로 돌린다
@MainActor
struct TaskforceRig {
    let harness: ReviewHarness
    let desk: ReviewDesk
    let summary: ReturnSummaryStore
    let gateway: IssueSampleGateway
    let issues: IssueRuntime
    let time: EdgeShellModelTests.ManualTime
    let shell: EdgeShellModel

    static let lease = UUID(uuidString: "c0000000-0000-4000-8000-000000000001")!
    static let run = UUID(uuidString: "d0000000-0000-4000-8000-000000000001")!
    static let holder = IssueSnapshotData.session(1)
    static let later = IssueSnapshotData.session(2)
    static let issue = IssueSnapshotData.issue(139)

    static func make(reviews: Int = 2, withReview: Bool = true, withSummary: Bool = true, gate: Bool = true) async throws -> TaskforceRig {
        let harness = try await ReviewHarness.make(reviews: reviews, open: 2)
        let summary = ReturnSummaryStore(gateway: LiveReturnSummaryGateway(services: harness.services), scope: harness.scope)
        let desk = ReviewDesk(now: harness.store, scope: harness.scope)
        let gateway = IssueSampleGateway()
        gateway.taskforceDetails = [lease: detail()]
        let issues = IssueRuntime(gateway: gateway, scope: harness.scope)
        let time = EdgeShellModelTests.ManualTime()
        let shell = EdgeShellModel(
            schedule: time.schedule, clock: time.clock, review: withReview ? desk : nil, summary: withSummary ? summary : nil, chatsEnabled: true,
            windowsEnabled: true, issues: issues, taskforceGate: gate
        )
        shell.accountChanged(ReviewHarness.userID)
        await harness.store.load()
        await issues.sessions.refresh()
        let rig = TaskforceRig(harness: harness, desk: desk, summary: summary, gateway: gateway, issues: issues, time: time, shell: shell)
        rig.sync()
        shell.sessionsChanged()
        await rig.settle()
        return rig
    }

    /// 겹친 읽기가 모두 끝나기를 기다린다 (셸이 띄운 읽기 포함: 마지막에 시작한 읽기만 반영된다)
    func settle() async {
        for _ in 0..<5 { await Task.yield() }
        var guardCount = 0
        while issues.taskforce.inflightReads > 0, guardCount < 10_000 {
            await Task.yield()
            guardCount += 1
        }
        for _ in 0..<5 { await Task.yield() }
    }

    /// 앱의 `followWork`처럼 목록을 셸에 옮긴다
    func sync() {
        let now = harness.store
        shell.update(EdgeWorkSnapshot(
            sections: now.sections, working: [], stopping: [], load: WorkLoad.from(refresh: now.refreshState, hasList: now.response != nil),
            doneSince: now.doneTodaySince, canConnect: false
        ))
    }

    func id(_ n: Int) -> UUID { ReviewHarness.id(n) }

    // MARK: 서버 응답 만들기

    static func detail(path: String = "src/content/pricing.mdx") -> TaskforceConflictDetail {
        TaskforceConflictDetail(leaseID: lease, relPath: path, holderRunID: run, laterRunID: run, holderSessionID: holder, laterSessionID: later)
    }

    static func confirm(_ action: UUID, version: String = "action:v:3") -> TaskforceDecisionGroup {
        let item = TaskforceDecisionItem(id: "confirm:\(action.uuidString.lowercased())", kind: .confirm, actionID: action, version: version)
        return TaskforceDecisionGroup(key: "\(action):confirm", actionID: action, kind: .confirm, items: [item])
    }

    static func result(session: UUID = holder, runID: UUID = run, version: String = "result:1") -> TaskforceDecisionGroup {
        let ref = TaskforceResultRef(sessionID: session, reviewedTurnSeq: 0, lastTurnSeq: 2, changedAt: "2026-10-15T01:00:00.000Z")
        let item = TaskforceDecisionItem(id: "result_ready:\(runID.uuidString.lowercased())", kind: .resultReady, actionID: issue, version: version, result: ref)
        return TaskforceDecisionGroup(key: "\(issue):result_ready", actionID: issue, kind: .resultReady, items: [item])
    }

    static func conflict(version: Int = 2) -> TaskforceDecisionGroup {
        let ref = TaskforceConflictRef(leaseID: lease, conflictVersion: version, holderActionID: issue, holderRunID: run, laterRunID: run, released: false, stopped: true)
        let item = TaskforceDecisionItem(id: "path_conflict:\(lease.uuidString.lowercased())", kind: .pathConflict, actionID: issue, version: "conflict:\(version)", conflict: ref)
        return TaskforceDecisionGroup(key: "\(issue):path_conflict", actionID: issue, kind: .pathConflict, items: [item])
    }

    static func response(_ groups: [TaskforceDecisionGroup], complete: Bool = true) -> TaskforceReviewResponse {
        TaskforceReviewResponse(complete: complete, decisions: groups)
    }

    /// 가짜 서버가 이 응답을 내리게 하고 한 번 읽어 셸에 반영한다
    func read(_ response: TaskforceReviewResponse?) async {
        await settle()
        gateway.taskforceResponse = response
        await issues.taskforce.refresh()
        await settle()
        shell.taskforceChanged()
    }

    var store: TaskforceRequestStore { issues.taskforce }

    /// 서버 순서의 요청 id들
    var ids: [String] { shell.taskforceQueue.ids }
}

/// OA U3 11.3: bell · 키 · 대화(confirm · 결과 · 충돌 · 빈 상태) · 링 · 계정 경계 (격리 Mac 호스트, 가짜 서버만)
@MainActor
struct EdgeTaskforceTests {
    typealias Rig = TaskforceRig

    func confirmID(_ rig: Rig, _ n: Int) -> String { "confirm:\(rig.id(n).uuidString.lowercased())" }

    // MARK: 게이트

    @Test func theConversationExistsOnlyWhenIssuesReviewAndSummaryAreAllOn() async throws {
        let full = try await Rig.make()
        #expect(full.shell.taskforceEnabled && full.shell.taskforceStore != nil)
        let noReview = try await Rig.make(withReview: false)
        let noSummary = try await Rig.make(withSummary: false)
        #expect(!noReview.shell.taskforceEnabled && noReview.shell.taskforceStore == nil && noReview.shell.taskforceBell == nil)
        #expect(!noSummary.shell.taskforceEnabled && noSummary.shell.taskforceStore == nil)
        let plain = EdgeShellModel(schedule: { _, _ in EdgeTimer() })
        #expect(!plain.taskforceEnabled && plain.taskforceBell == nil && plain.taskforceQueue.isEmpty)
        // 꺼진 구성은 대화를 열지 않고 읽지도 않는다
        noReview.shell.openTaskforce()
        noReview.shell.refreshTaskforce()
        #expect(!noReview.shell.panelOpen && noReview.gateway.taskforceReads == 0)
    }

    // MARK: bell

    @Test func thereIsNoBellBeforeTheFirstReadOrWithoutRequests() async throws {
        let rig = try await Rig.make()
        #expect(rig.shell.taskforceBell == nil, "v2 첫 읽기 전에는 bell이 없다")
        await rig.read(Rig.response([]))
        #expect(rig.shell.taskforceBell == nil, "요청 0 · 닫힘: 없다")
        #expect(rig.shell.railMode == .rest || rig.shell.railMode == .compact)
    }

    @Test func theBellAppearsAndRingsWhileRequestsWaitAndChangesNeverRingIt() async throws {
        let rig = try await Rig.make()
        await rig.read(Rig.response([Rig.confirm(rig.id(1)), Rig.result()]))
        let bell = try #require(rig.shell.taskforceBell)
        #expect(bell.rings && bell.count == 2 && !bell.selected)
        #expect(bell.accessibilityName == "Taskforce · Needs your answer, 2 items")
        // 바뀐 것(복귀 요약)만 있으면 bell이 없다
        let quiet = try await Rig.make()
        await quiet.harness.server.scriptSummary(SummaryJSON.response([SummaryJSON.item(quiet.id(101), title: "Open 1", changes: [SummaryJSON.change()])]))
        await quiet.summary.refresh()
        await quiet.read(Rig.response([]))
        #expect(quiet.summary.summary?.hasChangesToClear == true && quiet.shell.taskforceBell == nil, "변화만으로는 울리지 않는다")
    }

    @Test func theBellStaysQuietlyWhileTheConversationIsOpenAfterTheLastAnswerThenGoesAway() async throws {
        let rig = try await Rig.make()
        await rig.read(Rig.response([Rig.result()]))
        rig.shell.openTaskforce()
        #expect(rig.shell.taskforceBell?.selected == true && rig.shell.taskforceBell?.rings == true, "요청이 남아 있으면 열려 있어도 계속 울린다")
        await rig.read(Rig.response([]))
        let quiet = try #require(rig.shell.taskforceBell)
        #expect(quiet.selected && !quiet.rings && quiet.tooltip == "Taskforce · Nothing waiting", "마지막 답 뒤 대화가 열린 동안은 조용히 보인다")
        rig.shell.dismiss()
        #expect(rig.shell.taskforceBell == nil, "접으면 없다")
    }

    @Test func theResultReadyRequestRingsTheBellToo() async throws {
        let rig = try await Rig.make()
        await rig.read(Rig.response([Rig.result()]))
        #expect(rig.shell.taskforceBell?.rings == true, "U3-13 = A: 결과 준비도 bell을 울린다")
    }

    @Test func agentQuestionsAndExecutionDecisionsNeverRingTheBell() async throws {
        let rig = try await Rig.make()
        let kinds: [TaskforceDecisionKind] = [.agentQuestion, .agentApproval, .agentSecretQuestion, .approval, .reviewFailed, .runInput]
        let groups = kinds.map { kind -> TaskforceDecisionGroup in
            let item = TaskforceDecisionItem(id: "\(kind):x", kind: kind, actionID: Rig.issue, version: "v")
            return TaskforceDecisionGroup(key: "k:\(kind)", actionID: Rig.issue, kind: kind, items: [item])
        }
        await rig.read(Rig.response(groups))
        #expect(rig.shell.taskforceBell == nil && rig.shell.taskforceQueue.isEmpty, "질문은 그 세션에서만 답한다")
    }

    // MARK: ⌘1 · ⌥Space · bell 클릭

    @Test func commandOneOpensTheFirstRequestInServerOrderAndAlsoWhenAlreadyOpen() async throws {
        let rig = try await Rig.make()
        await rig.read(Rig.response([Rig.result(), Rig.confirm(rig.id(1)), Rig.conflict()]))
        rig.shell.openNewestReview()
        #expect(rig.shell.panelOpen && rig.shell.view == .review && rig.shell.taskforceShownID == rig.ids.first)
        rig.shell.stepTaskforce(1)
        #expect(rig.shell.taskforceShownID == rig.ids[1])
        rig.shell.openNewestReview()
        #expect(rig.shell.panelOpen && rig.shell.taskforceShownID == rig.ids.first, "이미 열려 있어도 접지 않고 첫 요청으로 간다")
        // 서버가 순서를 바꾸면 목적지도 따른다 (앱은 다시 정렬하지 않는다)
        await rig.read(Rig.response([Rig.confirm(rig.id(1)), Rig.result()]))
        rig.shell.openNewestReview()
        #expect(rig.shell.shownTaskforceRequest?.kind == .confirm)
    }

    @Test func commandOneAlwaysOpensTheConversationEvenWithNothingWaiting() async throws {
        let rig = try await Rig.make()
        rig.shell.openNewestReview()
        // 가짜 서버가 아직 이 기능이 없다(404)고 답했다: 비었다고 말하지 않고 읽지 못했다고 말한다
        #expect(rig.shell.panelOpen && rig.shell.view == .review && rig.shell.taskforceShownID == nil && rig.shell.taskforceScreen == .failed)
        await rig.read(Rig.response([]))
        #expect(rig.shell.taskforceScreen == .empty(problem: nil))
    }

    @Test func optionSpaceOpensTheFirstRequestOrTheLastViewAndClosesWhenOpen() async throws {
        let rig = try await Rig.make()
        rig.shell.openAllWork()
        rig.shell.dismiss()
        rig.shell.togglePanel()
        #expect(rig.shell.panelOpen && rig.shell.view == .allWork, "요청이 없으면 마지막 화면")
        rig.shell.togglePanel()
        #expect(!rig.shell.panelOpen, "열려 있으면 접는다")
        await rig.read(Rig.response([Rig.confirm(rig.id(1)), Rig.result()]))
        rig.shell.togglePanel()
        #expect(rig.shell.panelOpen && rig.shell.view == .review && rig.shell.shownTaskforceRequest?.kind == .confirm, "요청이 있으면 서버 순서 첫 요청")
        rig.shell.togglePanel()
        #expect(!rig.shell.panelOpen)
    }

    @Test func clickingTheBellIsCommandOneAndRereadsOnlyWhenAlreadyOpen() async throws {
        let rig = try await Rig.make()
        await rig.read(Rig.response([Rig.result(), Rig.conflict()]))
        let reads = rig.gateway.taskforceReads
        rig.shell.openTaskforce()
        #expect(rig.shell.panelOpen && rig.shell.taskforceShownID == rig.ids.first)
        #expect(rig.gateway.taskforceReads == reads, "패널을 막 여는 경우는 컨트롤러의 패널 열기 읽기가 읽는다")
        rig.shell.stepTaskforce(1)
        rig.shell.openTaskforce()
        #expect(rig.shell.taskforceShownID == rig.ids.first, "열려 있어도 접지 않고 첫 요청으로")
        while rig.gateway.taskforceReads == reads { await Task.yield() }
        #expect(rig.gateway.taskforceReads == reads + 1, "이미 열려 있으면 다시 읽는다")
    }

    // MARK: 단계 · 보던 요청

    @Test func stepsMoveByIdAndStopAtTheEnds() async throws {
        let rig = try await Rig.make()
        await rig.read(Rig.response([Rig.result(), Rig.confirm(rig.id(1)), Rig.conflict()]))
        rig.shell.openTaskforce()
        let ids = rig.ids
        rig.shell.stepTaskforce(-1)
        #expect(rig.shell.taskforceShownID == ids[0], "처음에서 멈춘다")
        rig.shell.stepTaskforce(1)
        rig.shell.stepTaskforce(1)
        rig.shell.stepTaskforce(1)
        #expect(rig.shell.taskforceShownID == ids[2], "끝에서 돌지 않는다")
        rig.shell.showTaskforceRequest(ids[1])
        #expect(rig.shell.taskforceShownID == ids[1])
        rig.shell.showTaskforceRequest("gone")
        #expect(rig.shell.taskforceShownID == ids[1], "목록에 없는 id는 무시")
    }

    @Test func aShownRequestThatLeavesIsReplacedByTheOneAfterIt() async throws {
        let rig = try await Rig.make()
        await rig.read(Rig.response([Rig.result(), Rig.confirm(rig.id(1)), Rig.conflict()]))
        rig.shell.openTaskforce()
        rig.shell.stepTaskforce(1)
        #expect(rig.shell.shownTaskforceRequest?.kind == .confirm)
        await rig.read(Rig.response([Rig.result(), Rig.conflict()]))
        #expect(rig.shell.shownTaskforceRequest?.kind == .pathConflict, "빠진 요청 뒤를 이은 요청")
        await rig.read(Rig.response([Rig.result()]))
        #expect(rig.shell.shownTaskforceRequest?.kind == .resultReady)
    }

    @Test func aNewRequestNeverTakesOverWhatIsBeingRead() async throws {
        let rig = try await Rig.make()
        await rig.read(Rig.response([Rig.confirm(rig.id(1))]))
        rig.shell.openTaskforce()
        let shown = rig.shell.taskforceShownID
        await rig.read(Rig.response([Rig.result(), Rig.confirm(rig.id(1))]))
        #expect(rig.shell.taskforceShownID == shown, "새 요청이 와도 보던 요청을 빼앗지 않는다")
    }

    // MARK: confirm 답

    @Test func theConfirmCardIsTheV1RequestAndAnswersThroughTheOldPathAndRereadsV2() async throws {
        let rig = try await Rig.make()
        await rig.read(Rig.response([Rig.confirm(rig.id(1)), Rig.confirm(rig.id(2))]))
        rig.shell.openTaskforce()
        #expect(rig.shell.shownReview?.id == rig.id(1) && rig.shell.taskforceScreen == .request(problem: nil))
        #expect(rig.shell.reviewQueue.isEmpty, "이 구성에는 v1 Review 큐가 없다")
        let reads = rig.gateway.taskforceReads
        let task = try #require(rig.shell.answer(.confirm, for: rig.id(1)))
        let result = await task.value
        #expect(result == .applied)
        #expect(await rig.harness.server.writeCount() == 1, "v1 확인 요청 하나")
        while rig.gateway.taskforceReads == reads { await Task.yield() }
        #expect(rig.gateway.taskforceReads == reads + 1, "내 답 뒤 v2를 다시 읽는다")
    }

    @Test func aConfirmWithoutItsV1PairIsNotCountedUntilTheListHasIt() async throws {
        let rig = try await Rig.make(reviews: 1)
        await rig.read(Rig.response([Rig.confirm(rig.id(1)), Rig.confirm(rig.id(99))]))
        #expect(rig.ids == [confirmID(rig, 1)], "짝이 없는 확인 요청은 세지 않는다 (지어내지 않는다)")
        #expect(rig.shell.taskforceVisible.skippedUnknown, "/now를 받았는데도 짝이 없으면 응답을 믿지 않는다 (대화가 영영 빈칸이 되지 않는다)")
        #expect(rig.shell.taskforceScreen == .request(problem: .failed), "요청 위 Notice")
    }

    // MARK: 키

    @Test func keysOneAndTwoAnswerTheShownRequestAndNothingElse() async throws {
        let rig = try await Rig.make()
        await rig.read(Rig.response([Rig.confirm(rig.id(1)), Rig.result(), Rig.conflict()]))
        rig.shell.openTaskforce()
        // confirm: 1 = Confirm (v1 경로, 곧바로), 반복 키는 먹기만 한다
        #expect(rig.shell.taskforceAnswerKey(.confirm, repeated: true), "반복 키는 먹기만 한다")
        #expect(await rig.harness.server.writeCount() == 0)
        #expect(rig.shell.taskforceAnswerKey(.confirm, repeated: false))
        _ = await rig.harness.wait { await rig.harness.server.writeCount() == 1 }
        #expect(await rig.harness.server.writeCount() == 1)
        // 결과: 답이 없어 키가 지나간다
        rig.shell.showTaskforceRequest(rig.ids[1])
        #expect(rig.shell.shownTaskforceRequest?.kind == .resultReady)
        #expect(!rig.shell.taskforceAnswerKey(.confirm, repeated: false) && !rig.shell.taskforceAnswerKey(.dismiss, repeated: false))
        #expect(rig.gateway.resolves.isEmpty)
        // 충돌: 1 = 먼저 쓴 쪽, 2 = 늦게 쓴 쪽 (2초 보류)
        rig.shell.showTaskforceRequest(rig.ids[2])
        #expect(rig.shell.taskforceAnswerKey(.dismiss, repeated: false))
        #expect(rig.store.answers[rig.ids[2]]?.keep == .later)
        rig.time.advance(2)
        _ = await rig.store.lastSend?.value
        #expect(rig.gateway.resolves == [TaskforceResolveRecord(leaseID: Rig.lease, keep: .later, conflictVersion: 2)])
    }

    @Test func keysPassThroughWhenNothingIsShownOrOffline() async throws {
        let rig = try await Rig.make()
        #expect(!rig.shell.taskforceAnswerKey(.confirm, repeated: false), "닫혀 있다")
        await rig.read(Rig.response([Rig.confirm(rig.id(1))]))
        rig.shell.openTaskforce()
        rig.shell.dismiss()
        #expect(!rig.shell.taskforceAnswerKey(.confirm, repeated: false), "접힌 대화에는 키가 가지 않는다")
        rig.shell.openTaskforce()
        rig.store.pathChanged(online: false)
        rig.gateway.taskforceRead = .offline
        await rig.store.refresh()
        #expect(rig.shell.taskforceScreen == .request(problem: .offline) && !rig.shell.taskforceAnswerKey(.confirm, repeated: false), "오프라인에서는 나중에 보내려고 모아 두지 않는다")
        #expect(await rig.harness.server.writeCount() == 0)
    }

    // MARK: 충돌 해소의 2초 보류

    @Test func choosingAConflictAnswerHoldsTwoSecondsUndoSendsNothingAndTheClockSendsOne() async throws {
        let rig = try await Rig.make()
        await rig.read(Rig.response([Rig.conflict()]))
        rig.shell.openTaskforce()
        let id = rig.ids[0]
        #expect(rig.shell.answerConflict(.holder, for: id))
        #expect(rig.store.answers[id]?.phase == .holding)
        rig.time.advance(1)
        rig.shell.undoConflict(id)
        rig.time.advance(5)
        #expect(rig.gateway.resolves.isEmpty && rig.store.answers.isEmpty, "2초 안 Undo → 요청 0")
        // 다시 고르고 2초가 지나면 정확히 하나
        #expect(rig.shell.answerConflict(.holder, for: id))
        #expect(!rig.shell.answerConflict(.later, for: id), "보류 중 다른 답을 눌러도 하나")
        rig.time.advance(1.9)
        #expect(rig.gateway.resolves.isEmpty)
        rig.time.advance(0.2)
        _ = await rig.store.lastSend?.value
        #expect(rig.gateway.resolves == [TaskforceResolveRecord(leaseID: Rig.lease, keep: .holder, conflictVersion: 2)])
    }

    @Test func aConflictAnswerOnlyWorksOnTheShownConflictOnlyOnlineAndOnlyWhileOpen() async throws {
        let rig = try await Rig.make()
        await rig.read(Rig.response([Rig.result(), Rig.conflict()]))
        let conflictID = rig.ids[1]
        #expect(!rig.shell.answerConflict(.holder, for: conflictID), "대화가 닫혀 있다")
        rig.shell.openTaskforce()
        #expect(!rig.shell.answerConflict(.holder, for: conflictID), "지금 보이는 요청이 아니다 (결과 카드)")
        rig.shell.stepTaskforce(1)
        #expect(rig.shell.answerConflict(.holder, for: conflictID))
        rig.shell.undoConflict(conflictID)
        rig.shell.dismiss()
        #expect(!rig.shell.answerConflict(.later, for: conflictID), "접힌 대화에는 답이 가지 않는다")
    }

    @Test func aConflict409RereadsOnceAndNeverRetriesAndTheNoticeStays() async throws {
        let rig = try await Rig.make()
        rig.gateway.resolveFailure = APIError.server(status: 409, code: .conflict, message: "x")
        await rig.read(Rig.response([Rig.conflict()]))
        rig.shell.openTaskforce()
        let id = rig.ids[0]
        let reads = rig.gateway.taskforceReads
        #expect(rig.shell.answerConflict(.holder, for: id))
        rig.time.advance(2)
        let result = await rig.store.lastSend?.value
        #expect(result == .conflict)
        rig.time.advance(30)
        #expect(rig.gateway.resolves.count == 1, "자동 재시도 0")
        #expect(rig.gateway.taskforceReads == reads + 1, "다시 읽기 한 번")
        #expect(rig.store.notice(for: id) == ReviewCopy.conflict)
        #expect(rig.store.answers.isEmpty, "다시 고를 수 있다")
    }

    @Test func switchingTheAccountDuringTheHoldSendsNothing() async throws {
        let rig = try await Rig.make()
        await rig.read(Rig.response([Rig.conflict()]))
        rig.shell.openTaskforce()
        #expect(rig.shell.answerConflict(.holder, for: rig.ids[0]))
        rig.harness.scope.accountLeft()
        rig.shell.accountChanged(nil)
        rig.time.advance(5)
        #expect(rig.gateway.resolves.isEmpty && rig.store.answers.isEmpty && rig.store.response == nil)
        #expect(rig.shell.taskforceShownID == nil && rig.shell.taskforceQueue.isEmpty && rig.shell.taskforceBell?.rings != true, "계정 경계: 목록 · 보던 id를 비운다 (열린 대화의 bell은 조용히 남는다)")
    }

    // MARK: 결과 카드 · 세션 열기

    @Test func theResultCardOpensTheIssueDetailWithTheSessionPanel() async throws {
        let rig = try await Rig.make()
        await rig.read(Rig.response([Rig.result()]))
        rig.shell.openTaskforce()
        rig.shell.openTaskforceSession(Rig.holder)
        #expect(rig.shell.view == .allWork && rig.shell.nav.detailID == Rig.issue && rig.shell.sessionPanelID == Rig.holder && rig.shell.sessionPanelShown)
    }

    @Test func aSessionWithoutAnIssueCannotBeOpenedFromTheConversation() async throws {
        let rig = try await Rig.make()
        rig.shell.openTaskforce()
        rig.shell.openTaskforceSession(UUID())
        #expect(rig.shell.view == .review && rig.shell.sessionPanelID == nil)
    }

    // MARK: 충돌 본문 재료

    @Test func theConflictCardNeedsThePathAndBothSessionsAndNeverInventsThem() async throws {
        let rig = try await Rig.make()
        rig.gateway.taskforceDetails = [:]
        await rig.read(Rig.response([Rig.conflict(), Rig.result()]))
        #expect(rig.shell.taskforceQueue.requests.map(\.kind) == [.resultReady], "경로를 못 읽은 충돌은 세지 않는다")
        #expect(rig.shell.taskforceScreen == .request(problem: .failed), "응답을 믿지 않는다고 말한다")
        rig.gateway.taskforceDetails = [Rig.lease: Rig.detail()]
        await rig.read(Rig.response([Rig.conflict(), Rig.result()]))
        let request = try #require(rig.shell.taskforceQueue.requests.first { $0.kind == .pathConflict })
        let sides = try #require(rig.shell.taskforceConflictSides(request))
        #expect(sides.path == "src/content/pricing.mdx" && sides.first.id == Rig.holder && sides.second.id == Rig.later)
    }

    // MARK: 링

    @Test func aV1ConfirmRequestIsNeverARingAndClickingARingNeverOpensTheConversation() async throws {
        let rig = try await Rig.make()
        #expect(!rig.shell.work.review.isEmpty)
        #expect(rig.shell.slots.allSatisfy { $0.kind != .needsYou || !rig.shell.work.review.map(\.id).contains($0.id) }, "v1 확인 요청은 링이 아니다")
        // v1 확인 요청이 있는 이슈의 링도 Taskforce 대화를 열지 않는다
        let entry = RailEntry(id: rig.id(1), title: "Review 1", kind: .needsYou, state: .inProgress)
        rig.shell.openRailEntry(entry)
        #expect(rig.shell.view == .allWork, "링 클릭은 Taskforce 대화를 열지 않는다")
    }

    @Test func theGatedOffRailKeepsTheV1NeedsYouRing() async throws {
        let rig = try await Rig.make(withReview: false, withSummary: false)
        #expect(!rig.shell.taskforceEnabled)
        let rings = rig.shell.slots.filter { $0.kind == .needsYou }.map(\.id)
        #expect(rings.contains(rig.id(1)), "Taskforce 대화가 꺼진 구성은 지금 규칙 그대로")
    }

    // MARK: 빈 상태

    @Test func theEmptyConversationOffersTheFirstOpenIssueAsNextAndProjectsWhenNowIsEmpty() async throws {
        let rig = try await Rig.make(reviews: 0)
        await rig.read(Rig.response([]))
        rig.shell.openTaskforce()
        #expect(rig.shell.taskforceScreen == .empty(problem: nil))
        let next = try #require(rig.shell.taskforceNext)
        #expect(next.title == "Open 1", "Now의 첫 항목")
        rig.shell.open(itemID: next.id)
        #expect(rig.shell.view == .allWork && rig.shell.nav.detailID == next.id, "누르면 그 이슈 상세")
        let nothing = try await Rig.make(reviews: 0)
        nothing.shell.update(EdgeWorkSnapshot(load: .loaded(problem: nil)))
        #expect(nothing.shell.taskforceNext == nil, "Now가 비면 Next가 없다 (대화는 Projects 버튼)")
    }

    // MARK: 읽기 상태

    @Test func theScreenSaysWhyWhenTheReadCouldNotBeDone() async throws {
        let rig = try await Rig.make()
        rig.shell.openTaskforce()
        rig.gateway.taskforceRead = .failed
        await rig.read(nil)
        #expect(rig.shell.taskforceScreen == .failed)
        rig.store.pathChanged(online: false)
        rig.gateway.taskforceRead = .offline
        await rig.store.refresh()
        #expect(rig.shell.taskforceScreen == .offline)
        // 연결이 돌아오면(검토 1: 연결은 화면의 근거다) 읽기 사정이 다시 화면의 말이 된다
        rig.gateway.taskforceRead = .full
        rig.store.pathChanged(online: true)
        await rig.settle()
        await rig.read(Rig.response([Rig.result()], complete: false))
        #expect(rig.shell.taskforceScreen == .request(problem: .failed), "complete가 아니면 요청 위 Notice")
        await rig.read(Rig.response([], complete: false))
        #expect(rig.shell.taskforceScreen == .incomplete(problem: .failed), "일부만 읽으면 비었다고 말하지 않는다")
    }

    @Test func anUnknownKindIsSkippedWithoutTrustingTheResponse() async throws {
        let rig = try await Rig.make()
        let unknown = TaskforceDecisionGroup(key: "k", actionID: Rig.issue, kind: .unknown, items: [TaskforceDecisionItem(id: "future:1", kind: .unknown, actionID: Rig.issue, version: "v")])
        await rig.read(Rig.response([unknown, Rig.result()]))
        #expect(rig.shell.taskforceQueue.requests.map(\.kind) == [.resultReady])
        #expect(rig.shell.taskforceScreen == .request(problem: .failed))
    }

    // MARK: 알림 접점 (U3-80)

    @Test func theShellGivesTheNotificationLaneTheSignalsItNeeds() async throws {
        let rig = try await Rig.make()
        await rig.read(Rig.response([Rig.result(), Rig.confirm(rig.id(1))]))
        // ① 요청 목록의 변화 신호 ② 첫 요청으로 여는 길 ③ 지금 보이는 요청 id
        let serial = rig.store.readSerial
        await rig.read(Rig.response([Rig.confirm(rig.id(1))]))
        #expect(rig.store.readSerial > serial)
        rig.shell.openTaskforce(requestID: rig.ids[0])
        #expect(rig.shell.shownTaskforceRequest?.id == rig.ids[0] && rig.shell.taskforceConversationOpen)
        rig.shell.dismiss()
        #expect(!rig.shell.taskforceConversationOpen)
        rig.shell.openTaskforce(requestID: "gone")
        #expect(rig.shell.taskforceShownID == rig.ids.first, "없는 id면 첫 요청")
    }

    // MARK: 복귀 요약 (방문 · Clear · 기준점, U3-28 · 51)

    /// 변화가 있는 요약 응답 (Clear 가능). 첫 사용 응답은 `since: nil` + 토큰
    func changesReply(_ rig: Rig, firstUse token: String? = nil) -> FakeReply {
        let items = [SummaryJSON.item(rig.id(101), title: "Open 1", changes: [SummaryJSON.change("action_event", "due_changed", detail: nil, sourceState: "available")])]
        if let token { return SummaryJSON.response(items, since: nil, initToken: token) }
        return SummaryJSON.response(items)
    }

    /// 몇 번 양보해도 아무것도 나가지 않는다 (쓰기 0)
    func quiet(_ rig: Rig) async -> Int {
        for _ in 0..<60 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(60))
        let baselines = await rig.harness.server.baselineTokens().count
        let clears = await rig.harness.server.clearCursors().count
        return baselines + clears
    }

    @Test func clearInTheConversationSendsTheCursorOnceAndResolvesNothing() async throws {
        let rig = try await Rig.make()
        await rig.harness.server.scriptSummary(changesReply(rig))
        await rig.summary.refresh()
        await rig.read(Rig.response([Rig.confirm(rig.id(1))]))
        rig.shell.openTaskforce()
        await rig.settle()
        #expect(rig.shell.taskforceSummaryContent?.canClear == true, "변화만 보이는 요약이 대화 끝에 있다")
        let writes = await rig.harness.server.writeCount()
        let task = try #require(rig.shell.clearSummary())
        #expect(await task.value == .cleared(applied: true))
        #expect(await rig.harness.server.clearCursors() == [SummaryJSON.cursor])
        #expect(await rig.harness.server.writeCount() == writes, "Clear는 읽음 처리일 뿐 요청 · 결정을 바꾸지 않는다")
        #expect(rig.shell.taskforceQueue.ids == [confirmID(rig, 1)], "Clear가 요청을 없애지 않는다")
    }

    /// Clear를 받은 방문에서만 보낸다: 닫았다가 곧바로 다시 연 새 방문에서는 옛 선택이 나가지 않는다
    @Test func aClearQueuedInOneVisitIsNotSentInTheNextVisitOfTheConversation() async throws {
        let rig = try await Rig.make()
        await rig.harness.server.scriptSummary(changesReply(rig))
        await rig.summary.refresh()
        await rig.read(Rig.response([Rig.confirm(rig.id(1))]))
        rig.shell.openTaskforce()
        await rig.settle()
        let task = try #require(rig.shell.clearSummary())
        // await 없이: 닫았다가 곧바로 다시 연다 (새 방문)
        rig.shell.dismiss()
        rig.shell.openTaskforce()
        #expect(await task.value == .ignored)
        #expect(await rig.harness.server.clearCursors().isEmpty && !rig.summary.isClearing)
        // 같은 방문 안의 움직임은 방문을 바꾸지 않는다: 정확히 한 번 나간다
        let again = try #require(rig.shell.clearSummary())
        rig.shell.openTaskforce()
        #expect(await again.value == .cleared(applied: true))
        #expect(await rig.harness.server.clearCursors() == [SummaryJSON.cursor])
    }

    @Test func clearIsOnlyHeardWhileTheConversationActuallyDrawsTheSummary() async throws {
        let rig = try await Rig.make()
        await rig.harness.server.scriptSummary(changesReply(rig))
        await rig.summary.refresh()
        #expect(rig.shell.clearSummary() == nil, "대화가 닫혀 있다")
        rig.gateway.taskforceRead = .failed
        await rig.read(nil)
        rig.shell.openTaskforce()
        await rig.settle()
        #expect(rig.shell.taskforceScreen == .failed && rig.shell.clearSummary() == nil, "요약을 그리지 않는 화면에서는 받지 않는다")
        #expect(await quiet(rig) == 0)
    }

    /// 첫 정상 표시 기준점: 대화가 그 요약을 실제로 그릴 때만, 이 방문에서 한 번 (서버가 준 토큰 그대로)
    @Test func theBaselineIsConfirmedOnlyWhenTheConversationDrawsTheSummaryAndOnlyOnce() async throws {
        let token = "i1.U3-TEST-TOKEN"
        let initialized = SummaryJSON.response([SummaryJSON.item(ReviewHarness.id(101), title: "Open 1")], since: nil, baseline: "initialized")
        // ① 대화가 닫혀 있으면 요약이 읽혀도 나가지 않는다
        let closed = try await Rig.make()
        await closed.harness.server.scriptSummary(changesReply(closed, firstUse: token), initialized)
        await closed.summary.refresh()
        #expect(await quiet(closed) == 0, "대화가 닫혀 있다")
        // ② 열려 있어도 읽기 실패(또는 읽는 중 · 오프라인) 화면은 요약을 그리지 않는다
        let failed = try await Rig.make()
        failed.gateway.taskforceRead = .failed
        await failed.read(nil)
        failed.shell.openTaskforce()
        await failed.settle()
        await failed.harness.server.scriptSummary(changesReply(failed, firstUse: token), initialized)
        await failed.summary.refresh()
        #expect(failed.shell.taskforceScreen == .failed)
        #expect(await quiet(failed) == 0, "요약을 그리지 않는 화면이다")
        // ③ 그리는 화면이면 정상 표시 때 한 번, 같은 토큰으로 다시 보내지 않는다
        let drawn = try await Rig.make()
        await drawn.read(Rig.response([Rig.confirm(drawn.id(1))]))
        drawn.shell.openTaskforce()
        await drawn.settle()
        await drawn.harness.server.scriptSummary(changesReply(drawn, firstUse: token), initialized)
        await drawn.summary.refresh()
        let sent = await drawn.harness.wait { await drawn.harness.server.baselineTokens().count == 1 && !drawn.summary.isConfirmingBaseline }
        #expect(sent)
        #expect(await drawn.harness.server.baselineTokens() == [token])
        drawn.shell.openTaskforce()
        await drawn.summary.refresh()
        #expect(await quiet(drawn) == 1, "이미 확정했다: 같은 방문에서 또 보내지 않는다")
        #expect(await drawn.harness.server.writeCount() == 0, "읽음 표시일 뿐 요청 · 결정을 바꾸지 않는다")
    }

    // MARK: 레일 툴팁 (U3-60, DS 미리보기: "Taskforce · Needs your answer · ⌘1")

    @Test func theRailTooltipsAreTheDesignWordsAndTheirShortcutsAndNeverOverAnOpenPanel() async throws {
        let rig = try await Rig.make()
        await rig.read(Rig.response([Rig.confirm(rig.id(1))]))
        #expect(rig.shell.tooltip == nil, "접힌 레일에는 툴팁이 없다")
        rig.shell.pointer(inside: true)
        rig.time.advance(0.2)
        #expect(rig.shell.isExpanded)
        rig.shell.hover(bell: true)
        let bell = try #require(rig.shell.tooltip)
        #expect(bell.title == "Taskforce" && bell.detail == "· Needs your answer · ⌘1", "bell은 두 말 중 하나와 ⌘1")
        #expect(rig.shell.taskforceBell?.accessibilityName == "Taskforce · Needs your answer, 1 item", "접근성 이름에는 단축키가 없고 개수가 있다")
        rig.shell.hover(bell: false)
        rig.shell.hover(plus: true)
        #expect(rig.shell.tooltip?.title == "New session" && rig.shell.tooltip?.detail == "")
        rig.shell.hover(plus: false)
        for (control, shortcut) in [(EdgeShellModel.Control.allWork, "⌘2"), (.chats, "⌘3")] {
            rig.shell.hover(control: control)
            #expect(rig.shell.tooltip?.title == rig.shell.label(for: control) && rig.shell.tooltip?.detail == shortcut)
        }
        rig.shell.hover(control: nil)
        // 요청이 없으면 두 번째 말
        await rig.read(Rig.response([]))
        rig.shell.hover(bell: true)
        #expect(rig.shell.tooltip == nil, "요청이 없고 대화도 닫혀 있으면 bell이 없어 툴팁도 없다")
        await rig.read(Rig.response([Rig.confirm(rig.id(1))]))
        rig.shell.hover(bell: true)
        // 패널이 열려 있으면 툴팁을 끈다 (패널이 레일 바로 옆이다)
        rig.shell.openTaskforce()
        #expect(rig.shell.tooltip == nil)
    }

    // MARK: 검토 1 (Astra): 낡은 카드 · 읽기 소유 · Try again · 연결 · Release 길

    /// P2-2: 카드가 그려진 뒤 충돌의 version이 바뀌었는데 옛 카드의 선택이 도착하면 해소를 보내지 않는다 (선택이 **도착하기 전에** 바뀐 경우)
    @Test func aStaleCardsPickDeliveredAfterTheConflictChangedResolvesNothing() async throws {
        let rig = try await Rig.make()
        await rig.read(Rig.response([Rig.conflict()]))
        rig.shell.openTaskforce()
        await rig.settle()
        let id = try #require(rig.shell.taskforceShownID)
        let seen = try #require(rig.store.renderedConflict(for: id))
        #expect(seen.conflictVersion == 2)
        // 선택이 도착하기 전에 충돌이 바뀐다 (같은 lease의 새 version)
        await rig.read(Rig.response([Rig.conflict(version: 3)]))
        #expect(!rig.shell.answerConflict(.holder, for: id, rendered: seen), "옛 카드의 선택은 새 충돌에 적용되지 않는다")
        rig.time.advance(10)
        await rig.settle()
        #expect(rig.gateway.resolves.isEmpty && rig.store.answers.isEmpty)
        // 새 카드의 선택은 새 version으로 간다
        let current = try #require(rig.store.renderedConflict(for: id))
        #expect(current.conflictVersion == 3 && rig.shell.answerConflict(.holder, for: id, rendered: current))
        rig.time.advance(2)
        _ = await rig.store.lastSend?.value
        #expect(rig.gateway.resolves.map(\.conflictVersion) == [3])
    }

    /// P3-3: Projects 패널이 열린 채 bell · ⌘1로 들어오면 컨트롤러의 "패널 열기" 읽기가 없으니 셸이 읽는다. 닫힌 패널에서는 컨트롤러가 읽으니 셸은 겹쳐 읽지 않는다
    @Test func enteringFromAnOpenProjectsPanelReadsAgainAndAClosedPanelLeavesItToTheControllersOpenRead() async throws {
        let rig = try await Rig.make()
        await rig.read(Rig.response([Rig.confirm(rig.id(1))]))
        rig.shell.openAllWork()
        #expect(rig.shell.panelOpen && rig.shell.view == .allWork)
        await rig.settle()
        let reads = rig.gateway.taskforceReads
        rig.shell.openTaskforce()
        await rig.settle()
        #expect(rig.shell.view == .review && rig.gateway.taskforceReads == reads + 1, "열린 Projects에서 들어와도 한 번 읽는다")
        rig.shell.dismiss()
        let closed = rig.gateway.taskforceReads
        rig.shell.openTaskforce()
        await rig.settle()
        #expect(rig.gateway.taskforceReads == closed, "닫힌 패널은 컨트롤러의 패널 열기 읽기 몫이다")
    }

    /// P3-4: Try again은 v2를 한 번만 읽는다 (컨트롤러의 `load(.retry)`가 이미 읽는다). 이 GET은 제안 노출 표시를 한다
    @Test func tryAgainReadsTheV2ReviewExactlyOnce() async throws {
        let rig = try await Rig.make()
        rig.gateway.taskforceRead = .failed
        await rig.read(nil)
        rig.shell.openTaskforce()
        await rig.settle()
        #expect(rig.shell.taskforceScreen == .failed)
        rig.gateway.taskforceRead = .full
        // 컨트롤러의 `load(.retry)`는 v2를 한 번 읽는다 (`EdgeShell.load`): 그 읽기를 그대로 흉내 낸다
        rig.shell.onRetry = { [shell = rig.shell] in shell.refreshTaskforce() }
        let reads = rig.gateway.taskforceReads
        rig.shell.taskforceTryAgain()
        await rig.settle()
        #expect(rig.gateway.taskforceReads == reads + 1, "제안 노출 표시가 있는 GET은 한 번만")
    }

    /// P3-5: 연결이 끊기면 다음 읽기가 실패하기 전에도 화면이 오프라인을 말하고 답이 잠긴다 (끊김과 다음 읽기 사이)
    @Test func goingOfflineLocksTheCardsBeforeTheNextReadFails() async throws {
        let rig = try await Rig.make()
        await rig.read(Rig.response([Rig.conflict(), Rig.confirm(rig.id(1))]))
        rig.shell.openTaskforce()
        await rig.settle()
        let conflictID = try #require(rig.shell.taskforceQueue.requests.first { $0.kind == .pathConflict }?.id)
        rig.shell.showTaskforceRequest(conflictID)
        #expect(rig.shell.taskforceScreen == .request(problem: nil) && rig.shell.taskforceScreen.canAnswer)
        let reads = rig.gateway.taskforceReads
        rig.store.pathChanged(online: false)
        #expect(rig.store.readProblem == nil, "아직 실패한 읽기는 없다")
        #expect(rig.shell.taskforceScreen == .request(problem: .offline) && !rig.shell.taskforceScreen.canAnswer)
        #expect(!rig.shell.answerConflict(.holder, for: conflictID), "오프라인에서는 충돌 답을 받지 않는다")
        #expect(!rig.shell.taskforceAnswerKey(ReviewAnswer.allCases[0], repeated: false), "키도 지나간다")
        rig.time.advance(10)
        await rig.settle()
        #expect(rig.gateway.resolves.isEmpty && rig.gateway.taskforceReads == reads, "끊김은 읽기도 쓰기도 만들지 않는다")
        // 다시 연결되면 한 번 읽고 답이 다시 열린다
        rig.store.pathChanged(online: true)
        await rig.settle()
        #expect(rig.gateway.taskforceReads == reads + 1)
        #expect(rig.shell.taskforceScreen == .request(problem: nil) && rig.shell.taskforceScreen.canAnswer)
        // 응답이 없는 채 끊기면 읽는 중이 아니라 오프라인이다
        let fresh = try await Rig.make()
        fresh.store.pathChanged(online: false)
        #expect(fresh.shell.taskforceScreen == .offline)
    }

    /// 검토 1 시험 강도: **진짜 셸이 만들어지는 길**에서 Release가 새지 않는다. 다섯 인자가 모두 켜져도 Release 빌드의 게이트는 false이고, 그 값으로 만든 셸은
    /// issues · review · summary가 모두 있어도 Taskforce 대화 · 저장소 · bell이 없고 어느 입구로도 v2를 읽지 않는다
    @Test func aReleaseBuildNeverBuildsTheTaskforceShellEvenWithEveryFlagOn() async throws {
        let store = try TestDefaults()
        defer { store.cleanup() }
        for key in [EdgeShellFlag.key, S3bFlag.key, EdgeSurfaces.issueScreensKey, S4Flag.key, C3Flag.key] { store.defaults.set(true, forKey: key) }
        #expect(EdgeSurfaces.taskforceConversation(store.defaults, debugBuild: true), "Debug는 다섯 인자로 켜진다")
        let releaseGate = EdgeSurfaces.taskforceConversation(store.defaults, debugBuild: false)
        #expect(!releaseGate)
        let rig = try await Rig.make(gate: releaseGate)
        #expect(rig.shell.issueScreensEnabled && rig.shell.review != nil && rig.shell.summary != nil)
        #expect(!rig.shell.taskforceEnabled && rig.shell.taskforceStore == nil && rig.shell.taskforceBell == nil)
        rig.shell.accountChanged(ReviewHarness.userID)
        rig.shell.refreshTaskforce()
        rig.shell.openTaskforce()
        rig.shell.taskforceWoke()
        rig.shell.sessionsChanged()
        rig.sync()
        await rig.settle()
        #expect(rig.gateway.taskforceReads == 0 && !rig.shell.panelOpen && rig.shell.taskforceScreen == .blank)
    }

    /// v2 읽기의 입구: 게이트의 한 조각이라도 빠진 셸(U2만 · S4 없음 · C3 없음)은 어느 입구로도 v2를 읽지 않는다
    @Test func aShellWithoutTheFullGateNeverReadsV2FromAnyEntry() async throws {
        for rig in [try await Rig.make(withReview: false), try await Rig.make(withSummary: false), try await Rig.make(gate: false)] {
            rig.shell.accountChanged(ReviewHarness.userID)
            rig.shell.refreshTaskforce()
            rig.shell.taskforceWoke()
            rig.shell.openTaskforce()
            rig.shell.sessionsChanged()
            rig.sync()
            await rig.settle()
            #expect(rig.gateway.taskforceReads == 0 && rig.shell.taskforceStore == nil)
        }
    }
}
