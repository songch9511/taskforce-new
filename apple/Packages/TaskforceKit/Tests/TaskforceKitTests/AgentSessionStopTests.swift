import Foundation
import Testing
@testable import TaskforceKit

/// Stop (OA D4a-13 · 14, 계약 v3 5장): 열린 task가 있으면 보내기 원이 Stop이 되고(Assistant 창 · 세션 패널), 눌러도 한 번만 요청한다.
/// "Stop requested · not confirmed"(서버가 확인하기 전) · "Stopped · commands may still be running"(`processes: may_continue`, 다음 턴이 시작될 때까지)
struct AgentSessionStopRulesTests {
    typealias Fx = SessionFx
    typealias Rules = AgentStopRules

    func item(_ state: AgentTaskState?, status: AgentSessionStatus = .bound, cancelRequested: Bool = false, turn: Int = 1) -> AgentSessionItem {
        var snapshot = Fx.snapshot(status: status, state: state, cancelRequested: cancelRequested)
        snapshot.sessions[0] = Fx.session(1, status: status, turn: turn)
        snapshot.tasks = state.map { [Fx.task(1, state: $0, turn: turn, cancelRequested: cancelRequested)] } ?? []
        return Fx.item(snapshot)
    }

    // MARK: Stop 원

    @Test func theCircleIsStopForTheFourOpenStatesAndSendOtherwise() {
        for state in [AgentTaskState.dispatched, .accepted, .running, .awaitingAnswer] {
            #expect(Rules.presentation(session: item(state), outcome: nil).showsStop, "\(state.raw)")
        }
        for state in [AgentTaskState.idle, .completed, .failed, .cancelled, .unreachable, .unknown("x")] {
            #expect(!Rules.presentation(session: item(state), outcome: nil).showsStop, "\(state.raw): 열린 작업이 아니다")
        }
        #expect(!Rules.presentation(session: item(nil), outcome: nil).showsStop, "task 없음")
        #expect(!Rules.presentation(session: nil, outcome: nil).showsStop, "세션을 아직 모른다")
        #expect(!Rules.presentation(session: item(.running, status: .closed), outcome: nil).showsStop, "닫힌 세션은 열린 작업이 없다")
    }

    // MARK: 말

    @Test func aServerStopRequestOnAnOpenTaskSaysStopRequested() {
        let result = Rules.presentation(session: item(.running, cancelRequested: true), outcome: nil)
        #expect(result == Rules.Presentation(showsStop: true, line: .requested), "다시 읽은 `cancel_requested_at`")
    }

    @Test func aRequestedOnlyAnswerSaysStopRequestedUntilTheTurnEnds() {
        let outcome = AgentStopOutcome(requestedOnly: true, mayContinue: false, turnSeq: 1)
        #expect(Rules.presentation(session: item(.running), outcome: outcome) == Rules.Presentation(showsStop: true, line: .requested))
        #expect(Rules.presentation(session: item(.cancelled), outcome: outcome) == Rules.Presentation(showsStop: false, line: nil), "끝나면 지운다")
        // 다른 턴의 결과는 이 턴에 붙지 않는다
        #expect(Rules.presentation(session: item(.running, turn: 2), outcome: outcome) == Rules.Presentation(showsStop: true, line: nil))
    }

    @Test func allConfirmedWithNoOpenTaskIsJustSend() {
        let outcome = AgentStopOutcome(requestedOnly: false, mayContinue: false, turnSeq: 1)
        #expect(Rules.presentation(session: item(.cancelled), outcome: outcome) == Rules.Presentation(showsStop: false, line: nil))
        #expect(Rules.presentation(session: item(.idle), outcome: nil) == Rules.Presentation(showsStop: false, line: nil), "idle · task 없음은 열린 작업이 아니다")
    }

    @Test func mayContinueStaysUntilTheNextTurnStarts() {
        let outcome = AgentStopOutcome(requestedOnly: false, mayContinue: true, turnSeq: 1)
        #expect(Rules.presentation(session: item(.cancelled, turn: 1), outcome: outcome) == Rules.Presentation(showsStop: false, line: .mayContinue))
        #expect(Rules.presentation(session: item(.idle, turn: 1), outcome: outcome).line == .mayContinue)
        // Codex: 요청만 된 동안은 Stop requested, 확인되면(task가 끝나면) 명령이 남을 수 있다는 말
        let codex = AgentStopOutcome(requestedOnly: true, mayContinue: true, turnSeq: 1)
        #expect(Rules.presentation(session: item(.running, turn: 1), outcome: codex).line == .requested)
        #expect(Rules.presentation(session: item(.cancelled, turn: 1), outcome: codex).line == .mayContinue)
        // 다음 턴이 시작되면 사라진다 (새 턴 번호 · 열린 작업)
        #expect(Rules.presentation(session: item(.running, turn: 2), outcome: outcome).line == nil)
        #expect(Rules.presentation(session: item(.idle, turn: 2), outcome: outcome).line == nil)
    }

    @Test func theLinesWordsAreTheDesignWordAndTheApprovedNewWord() {
        #expect(AgentStopRules.Line.requested.text == "Stop requested · not confirmed")
        #expect(AgentStopRules.Line.mayContinue.text == "Stopped · commands may still be running", "사용자 승인 2026-10-18")
        #expect(AgentCopy.stopNewSteps == "Stop new steps" && AgentCopy.stopRequested == "Stop requested · not confirmed")
    }

    @Test func theOutcomeIsReadFromTheStopAnswer() {
        func result(_ cancel: AgentStopResult.Cancel, _ processes: AgentStopResult.Processes? = nil) -> AgentStopResult {
            AgentStopResult(agentTaskID: UUID(), cancel: cancel, processes: processes)
        }
        #expect(AgentStopOutcome(response: AgentStopResponse(tasks: [result(.confirmed), result(.requestedOnly)]), turnSeq: 3) == AgentStopOutcome(requestedOnly: true, mayContinue: false, turnSeq: 3), "requested_only가 하나라도 있으면")
        #expect(AgentStopOutcome(response: AgentStopResponse(tasks: [result(.confirmed, .mayContinue)]), turnSeq: 3) == AgentStopOutcome(requestedOnly: false, mayContinue: true, turnSeq: 3))
        #expect(AgentStopOutcome(response: AgentStopResponse(tasks: [result(.confirmed)]), turnSeq: 3) == nil, "모두 confirmed: 남길 것이 없다")
        #expect(AgentStopOutcome(response: AgentStopResponse(tasks: []), turnSeq: 3) == nil)
        #expect(AgentStopOutcome(response: AgentStopResponse(tasks: [result(.unknown("later"))]), turnSeq: 3) == nil, "모르는 값은 아무것도 주장하지 않는다")
    }
}

/// Stop 저장소: 요청 하나 · 눌러도 한 번 · 계정이 바뀌면 버린다
@MainActor
struct AgentSessionStopStoreTests {
    typealias Fx = SessionFx

    let conversations = FakeAgentConversationGateway()
    let sessions = FakeAgentSessionRequests()
    let conversationID = ChatContractFixtures.id(1, prefix: "bcb50000")

    func store(scope: AccountScope = ChatTestAccount.fixedScope()) -> AgentStopStore {
        AgentStopStore(conversations: conversations, sessions: sessions, scope: scope)
    }

    func running(_ n: Int = 1, cancelRequested: Bool = false) -> AgentSessionItem {
        Fx.item(Fx.snapshot(state: .running, cancelRequested: cancelRequested))
    }

    nonisolated func requestedOnly() -> AgentStopResponse {
        AgentStopResponse(tasks: [AgentStopResult(agentTaskID: UUID(), cancel: .requestedOnly, processes: .mayContinue)])
    }

    @Test func stoppingAConversationPostsOnceEvenWhenPressedTwice() async {
        let stop = store()
        let latch = Latch()
        conversations.stopHandler = { _ in
            await latch.wait()
            return self.requestedOnly()
        }
        let item = running()
        async let first: Void = stop.stopConversation(conversationID, session: item)
        #expect(await latch.waitForArrivals(1, timeout: .seconds(3)))
        async let second: Void = stop.stopConversation(conversationID, session: item)
        #expect(await noSecondRequest(latch), "진행 중인 세션의 두 번째 누름은 서버에 가지 않는다")
        await latch.open()
        _ = await (first, second)
        #expect(conversations.stops == [conversationID], "두 번 눌러도 한 번")
        #expect(stop.presentation(session: item).line == .requested && stop.presentation(session: item).showsStop)
        // 이미 요청했다: 다시 눌러도 요청하지 않는다 (Stop은 그대로 보인다)
        await stop.stopConversation(conversationID, session: item)
        #expect(conversations.stops.count == 1)
    }

    @Test func aSessionPanelStopUsesTheSessionRouteAndRecordsTheOutcome() async {
        let stop = store()
        sessions.stopHandler = { _ in AgentStopResponse(tasks: [AgentStopResult(agentTaskID: UUID(), cancel: .confirmed, processes: .mayContinue)]) }
        let item = running()
        await stop.stopSession(item)
        #expect(sessions.calls == ["stop:\(item.id.uuidString)"] && conversations.stops.isEmpty)
        let ended = Fx.item(Fx.snapshot(state: .cancelled))
        #expect(stop.presentation(session: ended) == AgentStopRules.Presentation(showsStop: false, line: .mayContinue))
    }

    @Test func nothingIsSentWhenThereIsNoOpenTask() async {
        let stop = store()
        await stop.stopConversation(conversationID, session: Fx.item(Fx.snapshot(state: .idle)))
        await stop.stopConversation(conversationID, session: nil)
        await stop.stopSession(Fx.item(Fx.snapshot(state: .completed)))
        #expect(conversations.stops.isEmpty && sessions.calls.isEmpty)
    }

    @Test func aFailedStopLeavesNoOutcomeAndAsksTheCallerToReadAgain() async {
        let stop = store()
        let changes = Mutex2(0)
        stop.onChanged = { changes.value += 1 }
        conversations.stopHandler = { _ in throw APIError.server(status: 409, code: .busyRetry, message: "x") }
        let item = running()
        await stop.stopConversation(conversationID, session: item)
        #expect(stop.presentation(session: item).line == nil && stop.presentation(session: item).showsStop)
        #expect(changes.value == 1, "다시 읽는다")
        // 실패 뒤에는 다시 누를 수 있다
        conversations.stopHandler = { _ in self.requestedOnly() }
        await stop.stopConversation(conversationID, session: item)
        #expect(conversations.stops.count == 2 && stop.presentation(session: item).line == .requested)
    }

    @Test func aLateAnswerAfterAnAccountChangeIsDropped() async throws {
        let account = try ChatTestAccount.make()
        let stop = store(scope: account.scope)
        let latch = Latch()
        conversations.stopHandler = { _ in
            await latch.wait()
            return self.requestedOnly()
        }
        let item = running()
        async let pending: Void = stop.stopConversation(conversationID, session: item)
        #expect(await latch.waitForArrivals(1, timeout: .seconds(3)))
        account.session.apply(event: .signedOut, session: nil)
        await latch.open()
        await pending
        #expect(stop.presentation(session: item).line == nil, "떠난 계정의 늦은 응답은 반영하지 않는다")
    }

    @Test func aStoreWithoutAGatewayDoesNothing() async {
        let stop = AgentStopStore(conversations: nil, sessions: nil, scope: ChatTestAccount.fixedScope())
        await stop.stopConversation(conversationID, session: running())
        await stop.stopSession(running())
        #expect(stop.presentation(session: running()).line == nil)
    }
}
