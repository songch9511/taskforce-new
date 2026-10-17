import Foundation
import Testing
@testable import TaskforceKit

/// OA U3 11.1: 보일 종류 · 셈(U3-22) · 순서 · 목적지 · bell(U3-12) · steps 창(U3-24) · 화면 갈래 · 글자
struct TaskforceRequestRulesTests {
    typealias Fx = TaskforceRequestFixtures

    static let otherSession = UUID(uuidString: "5e000000-0000-4000-8000-000000000002")!
    static let confirmable: Set<UUID> = [Fx.action(7)]
    static let known: Set<UUID> = [Fx.session, otherSession]

    static var details: [UUID: TaskforceConflictDetail] {
        [Fx.lease: TaskforceConflictDetail(
            leaseID: Fx.lease, relPath: "src/content/pricing.mdx", holderRunID: Fx.run, laterRunID: Fx.run, holderSessionID: Fx.session, laterSessionID: otherSession
        )]
    }

    func visible(
        _ response: TaskforceReviewResponse? = nil, confirmable: Set<UUID> = Self.confirmable, conflicts: [UUID: TaskforceConflictDetail] = Self.details,
        known: Set<UUID> = Self.known
    ) throws -> TaskforceVisibleRequests {
        TaskforceRequestRules.visible(try response ?? Fx.decode(Fx.review), confirmable: confirmable, conflicts: conflicts, knownSessions: known)
    }

    // MARK: 보일 종류 · 셈

    @Test func onlyConfirmResultReadyAndPathConflictAreShownInServerOrder() throws {
        let shown = try visible()
        let kinds: [TaskforceRequest.Kind] = [.resultReady, .pathConflict, .confirm]
        #expect(shown.requests.map(\.kind) == kinds, "질문 셋은 그리지도 세지도 않는다 · 서버 순서 그대로")
        #expect(shown.requests.map(\.id) == [
            "result_ready:\(Fx.run.uuidString.lowercased())", "path_conflict:\(Fx.lease.uuidString.lowercased())", "confirm:\(Fx.action(7).uuidString.lowercased())",
        ])
        #expect(!shown.skippedUnknown, "아는 종류만 있으면 건너뛴 것이 없다")
    }

    @Test func theAgentQuestionKindsAndTheExecutionKindsAreNeverCounted() throws {
        let questionsOnly = TaskforceReviewResponse(decisions: [
            TaskforceDecisionGroup(key: "k1", actionID: Fx.action(1), kind: .agentQuestion, items: [TaskforceDecisionItem(id: "agent_question:1", kind: .agentQuestion, actionID: Fx.action(1), version: "v")]),
            TaskforceDecisionGroup(key: "k2", actionID: Fx.action(1), kind: .agentApproval, items: [TaskforceDecisionItem(id: "agent_approval:1", kind: .agentApproval, actionID: Fx.action(1), version: "v")]),
            TaskforceDecisionGroup(key: "k3", actionID: Fx.action(1), kind: .agentSecretQuestion, items: [TaskforceDecisionItem(id: "agent_secret_question:1", kind: .agentSecretQuestion, actionID: Fx.action(1), version: "v")]),
            TaskforceDecisionGroup(key: "k4", actionID: Fx.action(1), kind: .approval, items: [TaskforceDecisionItem(id: "approval:1", kind: .approval, actionID: Fx.action(1), version: "v")]),
            TaskforceDecisionGroup(key: "k5", actionID: Fx.action(1), kind: .reviewFailed, items: [TaskforceDecisionItem(id: "review_failed:1", kind: .reviewFailed, actionID: Fx.action(1), version: "v")]),
            TaskforceDecisionGroup(key: "k6", actionID: Fx.action(1), kind: .runInput, items: [TaskforceDecisionItem(id: "run_input:1", kind: .runInput, actionID: Fx.action(1), version: "v")]),
        ])
        let shown = try visible(questionsOnly)
        #expect(shown.requests.isEmpty && !shown.skippedUnknown, "알지만 그리지 않는 종류는 '모르는 종류'가 아니다")
        #expect(TaskforceRequestRules.isTrustworthy(questionsOnly, skippedUnknown: shown.skippedUnknown))
    }

    @Test func anUnknownKindIsSkippedAndTheResponseIsNotTrusted() throws {
        let response = TaskforceReviewResponse(decisions: [
            TaskforceDecisionGroup(key: "k", actionID: Fx.action(9), kind: .unknown, items: [TaskforceDecisionItem(id: "future:1", kind: .unknown, actionID: Fx.action(9), version: "v")]),
            TaskforceDecisionGroup(key: "c", actionID: Fx.action(7), kind: .confirm, items: [TaskforceDecisionItem(id: "confirm:7", kind: .confirm, actionID: Fx.action(7), version: "v")]),
        ])
        let shown = try visible(response)
        #expect(shown.requests.map(\.id) == ["confirm:7"] && shown.skippedUnknown, "모르는 종류만 건너뛰고 아는 요청은 그대로 보인다")
        #expect(!TaskforceRequestRules.isTrustworthy(response, skippedUnknown: shown.skippedUnknown), "complete가 true여도 믿지 않는다")
    }

    @Test func anUnreadableDrawnItemIsSkippedAndTheResponseIsNotTrusted() throws {
        let broken = TaskforceReviewResponse(decisions: [
            TaskforceDecisionGroup(key: "p", actionID: Fx.action(5), kind: .pathConflict, items: [TaskforceDecisionItem(id: "path_conflict:x", kind: .pathConflict, actionID: Fx.action(5), version: "v")]),
        ])
        let shown = try visible(broken)
        #expect(shown.requests.isEmpty && shown.skippedUnknown)
    }

    @Test func aConfirmWithoutItsV1PairWaitsWhileTheListIsBeingReadAndIsSkippedOnceItIsRead() throws {
        let response = try Fx.decode(Fx.review)
        let reading = TaskforceRequestRules.visible(
            response, confirmable: [], conflicts: Self.details, knownSessions: Self.known, readiness: .init(confirmationsKnown: false)
        )
        let kinds: [TaskforceRequest.Kind] = [.resultReady, .pathConflict]
        #expect(reading.requests.map(\.kind) == kinds)
        #expect(reading.deferred && !reading.skippedUnknown, "/now를 읽는 중: 기다린다 (비었다고도 못 읽었다고도 말하지 않는다)")
        let read = try visible(confirmable: [])
        #expect(read.requests.map(\.kind) == kinds)
        #expect(!read.deferred && read.skippedUnknown, "/now를 받았는데도 짝이 없다: 건너뛴 것이고 응답을 믿지 않는다 (대화가 영영 빈칸이 되지 않는다)")
    }

    @Test func sessionsAndConflictDetailsWaitWhileTheyAreBeingReadToo() throws {
        let response = try Fx.decode(Fx.review)
        let noSessions = TaskforceRequestRules.visible(
            response, confirmable: Self.confirmable, conflicts: Self.details, knownSessions: [], readiness: .init(sessionsKnown: false)
        )
        #expect(noSessions.requests.map(\.kind) == [.confirm] && noSessions.deferred && !noSessions.skippedUnknown)
        let noDetails = TaskforceRequestRules.visible(
            response, confirmable: Self.confirmable, conflicts: [:], knownSessions: Self.known, readiness: .init(conflictDetailsKnown: false)
        )
        #expect(noDetails.requests.map(\.kind) == [.resultReady, .confirm] && noDetails.deferred && !noDetails.skippedUnknown)
        let missingForGood = try visible(conflicts: [:])
        #expect(!missingForGood.deferred && missingForGood.skippedUnknown, "다 읽었는데 상세가 없다")
    }

    @Test func aResultNeedsItsSessionAndAConflictNeedsPathAndBothSessions() throws {
        // 세션 저장소가 아직 비었다: 결과 · 충돌 모두 세지 않는다 (지어내지 않는다)
        #expect(try visible(known: []).requests.map(\.kind) == [.confirm])
        // 충돌 상세가 아직 없다
        #expect(try visible(conflicts: [:]).requests.map(\.kind) == [.resultReady, .confirm])
        // 늦게 쓴 쪽 세션만 모른다
        #expect(try visible(known: [Fx.session]).requests.map(\.kind) == [.resultReady, .confirm])
        // 읽은 상세가 이 충돌의 run이 아니다 (옛 상세)
        var stale = Self.details
        stale[Fx.lease] = TaskforceConflictDetail(
            leaseID: Fx.lease, relPath: "p", holderRunID: UUID(), laterRunID: Fx.run, holderSessionID: Fx.session, laterSessionID: Self.otherSession
        )
        #expect(try visible(conflicts: stale).requests.map(\.kind) == [.resultReady, .confirm])
        // 세션이 지워진 결과(null)는 보이지 않는다
        var gone = try Fx.decode(Fx.review)
        gone = TaskforceReviewResponse(decisions: gone.decisions?.map { group in
            TaskforceDecisionGroup(key: group.key, actionID: group.actionID, kind: group.kind, items: group.items.map { item in
                guard item.kind == .resultReady, let ref = item.result else { return item }
                return TaskforceDecisionItem(
                    id: item.id, kind: item.kind, actionID: item.actionID, version: item.version,
                    result: TaskforceResultRef(sessionID: nil, reviewedTurnSeq: ref.reviewedTurnSeq, lastTurnSeq: ref.lastTurnSeq, changedAt: ref.changedAt)
                )
            })
        })
        #expect(try visible(gone).requests.map(\.kind) == [.pathConflict, .confirm])
    }

    @Test func theSameItemTwiceIsOneRequest() throws {
        let item = TaskforceDecisionItem(id: "confirm:7", kind: .confirm, actionID: Fx.action(7), version: "v")
        let response = TaskforceReviewResponse(decisions: [
            TaskforceDecisionGroup(key: "a", actionID: Fx.action(7), kind: .confirm, items: [item, item]),
            TaskforceDecisionGroup(key: "b", actionID: Fx.action(7), kind: .confirm, items: [item]),
        ])
        #expect(try visible(response).requests.count == 1)
    }

    @Test func anIncompleteOrUnavailableResponseIsNotTrusted() throws {
        let full = try Fx.decode(Fx.review)
        #expect(TaskforceRequestRules.isTrustworthy(full, skippedUnknown: false))
        let partial = TaskforceReviewResponse(complete: false, decisions: full.decisions)
        #expect(!TaskforceRequestRules.isTrustworthy(partial, skippedUnknown: false), "complete가 아니면 비었다고 말하지 않는다")
        let unavailable = TaskforceReviewResponse(complete: false, sources: .init(decisions: .unavailable), decisions: nil)
        #expect(!TaskforceRequestRules.isTrustworthy(unavailable, skippedUnknown: false))
    }

    @Test func conflictRefsAreTheRefsOfEveryConflictItem() throws {
        #expect(TaskforceRequestRules.conflictRefs(try Fx.decode(Fx.review)).map(\.leaseID) == [Fx.lease])
    }

    // MARK: 순서 · 목적지

    @Test func theFirstRequestIsTheServersFirstAndTheAppNeverReorders() throws {
        let queue = TaskforceRequestQueue(try visible().requests)
        #expect(queue.first?.kind == .resultReady, "⌘1 · ⌥Space · bell의 목적지 = 서버 순서의 첫 요청")
        let reversed = TaskforceRequestQueue(try visible().requests.reversed())
        #expect(reversed.first?.kind == .confirm, "서버가 뒤집어 주면 목적지도 따라간다 (앱은 다시 정렬하지 않는다)")
    }

    @Test func steppingStopsAtTheEndsAndWorksById() throws {
        let queue = TaskforceRequestQueue(try visible().requests)
        let ids = queue.ids
        #expect(queue.neighbor(of: ids[0], offset: -1) == ids[0], "처음에서 멈춘다")
        #expect(queue.neighbor(of: ids[0], offset: 1) == ids[1])
        #expect(queue.neighbor(of: ids[2], offset: 1) == ids[2], "끝에서 돌지 않는다")
        #expect(queue.neighbor(of: "gone", offset: 1) == nil)
        #expect(queue.index(of: ids[1]) == 1 && queue.contains(ids[2]) && queue.request(ids[0])?.kind == .resultReady)
    }

    @Test func aShownRequestThatLeavesIsReplacedByTheOneAfterItNotBySlot() {
        func request(_ id: String) -> TaskforceRequest { TaskforceRequest(id: id, kind: .confirm, actionID: UUID(), version: "v") }
        let before = ["a", "b", "c", "d"]
        let after = TaskforceRequestQueue(["a", "c", "d"].map(request))
        #expect(after.resolving("b", previous: before) == "c", "빠진 요청 뒤를 이은 요청")
        #expect(after.resolving("d", previous: before) == "d", "그대로 있으면 순서가 바뀌어도 id로")
        let tail = TaskforceRequestQueue(["a", "b"].map(request))
        #expect(tail.resolving("d", previous: before) == "b", "뒤가 없으면 앞의 가장 가까운 것")
        #expect(tail.resolving(nil, previous: []) == "a", "보던 것이 없으면 첫 요청")
        #expect(TaskforceRequestQueue([]).resolving("a", previous: ["a"]) == nil)
    }

    // MARK: bell

    @Test func theBellShowsWhenRequestsWaitOrTheConversationIsOpenAndRingsOnlyForRequests() {
        func bell(_ count: Int, open: Bool, enabled: Bool = true) -> TaskforceBell? { TaskforceBellRules.bell(requestCount: count, conversationOpen: open, enabled: enabled) }
        #expect(bell(0, open: false) == nil, "요청 0 · 닫힘: bell이 없다 (⌘1은 그래도 대화를 연다)")
        #expect(bell(2, open: false) == TaskforceBell(rings: true, selected: false, count: 2))
        #expect(bell(0, open: true) == TaskforceBell(rings: false, selected: true, count: 0), "마지막 답 뒤 대화가 열린 동안은 조용히 보인다")
        #expect(bell(1, open: true) == TaskforceBell(rings: true, selected: true, count: 1), "요청이 남아 있으면 열려 있어도 계속 울린다")
        #expect(bell(3, open: true, enabled: false) == nil, "게이트가 꺼지면 없다")
    }

    @Test func theBellNamesAreTheTwoDesignWordsAndTheCountIsOnlyInTheAccessibilityName() {
        let ringing = TaskforceBell(rings: true, selected: false, count: 2)
        #expect(ringing.tooltip == "Taskforce · Needs your answer")
        #expect(ringing.accessibilityName == "Taskforce · Needs your answer, 2 items")
        #expect(TaskforceBell(rings: true, selected: false, count: 1).accessibilityName == "Taskforce · Needs your answer, 1 item")
        let quiet = TaskforceBell(rings: false, selected: true, count: 0)
        #expect(quiet.tooltip == "Taskforce · Nothing waiting" && quiet.accessibilityName == "Taskforce · Nothing waiting")
        #expect(!ringing.tooltip.contains("2"), "화면 글에는 개수가 없다")
    }

    // MARK: steps

    @Test func tenOrFewerDotsAreAllDrawnAndMoreSlideWithTheCurrentOneCentered() {
        #expect(TaskforceStepsWindow.visible(count: 2, current: 1) == 0..<2)
        #expect(TaskforceStepsWindow.visible(count: 10, current: 9) == 0..<10)
        #expect(TaskforceStepsWindow.visible(count: 20, current: 0) == 0..<10, "처음에서 멈춘다")
        #expect(TaskforceStepsWindow.visible(count: 20, current: 10) == 5..<15, "지금 요청이 가운데")
        #expect(TaskforceStepsWindow.visible(count: 20, current: 19) == 10..<20, "끝에서 멈춘다")
        #expect(TaskforceStepsWindow.visible(count: 11, current: 5) == 0..<10)
        #expect(TaskforceStepsWindow.visible(count: 11, current: 6) == 1..<11)
        for current in 0..<20 {
            let window = TaskforceStepsWindow.visible(count: 20, current: current)
            #expect(window.count == 10 && window.contains(current), "점은 열을 넘지 않고 지금 요청은 늘 보인다 (\(current))")
        }
    }

    // MARK: 화면 갈래

    @Test func theScreenNeverClaimsNothingWaitsWithoutATrustworthyResponse() {
        typealias S = TaskforceScreen
        #expect(S.of(hasResponse: false, readProblem: nil, trustworthy: false, hasRequest: false) == .blank)
        #expect(S.of(hasResponse: false, readProblem: .offline, trustworthy: false, hasRequest: false) == .offline)
        #expect(S.of(hasResponse: false, readProblem: .failed, trustworthy: false, hasRequest: false) == .failed)
        #expect(S.of(hasResponse: true, readProblem: nil, trustworthy: true, hasRequest: false) == .empty(problem: nil))
        #expect(S.of(hasResponse: true, readProblem: .offline, trustworthy: true, hasRequest: false) == .empty(problem: .offline))
        #expect(S.of(hasResponse: true, readProblem: nil, trustworthy: false, hasRequest: false) == .incomplete(problem: .failed), "일부만 읽음: 비었다고 말하지 않는다")
        #expect(S.of(hasResponse: true, readProblem: nil, trustworthy: true, hasRequest: true) == .request(problem: nil))
        #expect(S.of(hasResponse: true, readProblem: nil, trustworthy: false, hasRequest: true) == .request(problem: .failed), "요청 위 Notice")
        #expect(S.of(hasResponse: true, readProblem: .offline, trustworthy: true, hasRequest: true) == .request(problem: .offline))
        #expect(S.of(hasResponse: true, readProblem: nil, trustworthy: true, hasRequest: false, deferred: true) == .blank, "재료를 읽는 중: 비었다고 말하지 않는다")
        #expect(S.of(hasResponse: true, readProblem: nil, trustworthy: true, hasRequest: true, deferred: true) == .request(problem: nil))
    }

    @Test func answersAreOnlyPossibleOnlineWhileARequestIsShown() {
        #expect(TaskforceScreen.request(problem: nil).canAnswer && TaskforceScreen.request(problem: .failed).canAnswer)
        #expect(!TaskforceScreen.request(problem: .offline).canAnswer, "오프라인에서는 나중에 보내려고 모아 두지 않는다")
        #expect(!TaskforceScreen.empty(problem: nil).canAnswer && !TaskforceScreen.blank.canAnswer)
    }

    @Test func theSummaryIsDrawnOnlyWhereTheConversationHasSomethingToSay() {
        #expect(TaskforceScreen.request(problem: nil).drawsSummary && TaskforceScreen.empty(problem: nil).drawsSummary && TaskforceScreen.incomplete(problem: .failed).drawsSummary)
        #expect(!TaskforceScreen.blank.drawsSummary && !TaskforceScreen.offline.drawsSummary && !TaskforceScreen.failed.drawsSummary)
    }

    // MARK: 글자

    @Test func theCopyIsTheApprovedWords() {
        #expect(TaskforceCopy.title == "Taskforce" && TaskforceCopy.resultReady == "Result ready" && TaskforceCopy.noDecisions == "No decisions waiting")
        #expect(TaskforceCopy.next == "Next" && TaskforceCopy.projects == "Projects" && TaskforceCopy.answerSent == "Answer sent" && TaskforceCopy.undo == "Undo")
        #expect(TaskforceCopy.whichSessionKeeps(path: "src/content/pricing.mdx") == "Which session keeps pricing.mdx?")
        #expect(TaskforceCopy.whichSessionKeeps(path: "pricing.mdx") == "Which session keeps pricing.mdx?")
        #expect(TaskforceCopy.fileConflict(path: "src/content/pricing.mdx") == "File conflict · src/content/pricing.mdx")
        #expect(TaskforceCopy.keep("Pricing copy draft") == "Keep Pricing copy draft")
        #expect(TaskforceCopy.touchedFirst(line: "Running") == "Touched first · Running" && TaskforceCopy.touchedFirst(line: "") == "Touched first")
        #expect(TaskforceCopy.requestPosition(2, of: 3) == "Request 2 of 3", "사용자 승인 2026-10-18")
    }

    @Test func aLongPathKeepsItsWholeTextInTheMetaAndItsLastPartInTheQuestion() {
        let path = "packages/very-long-workspace-name/src/content/localized/ko/pricing-page-final-v2.mdx"
        #expect(TaskforceCopy.fileConflict(path: path).hasSuffix(path), "가운데를 줄이지 않는다")
        #expect(TaskforceCopy.whichSessionKeeps(path: path) == "Which session keeps pricing-page-final-v2.mdx?")
        #expect(TaskforceCopy.whichSessionKeeps(path: "/") == "Which session keeps /?", "마지막 요소가 없으면 경로 그대로")
    }
}
