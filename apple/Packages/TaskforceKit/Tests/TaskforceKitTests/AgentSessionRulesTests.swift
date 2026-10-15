import Foundation
import Testing
@testable import TaskforceKit

/// OA U2 계약 2.5 "세션 → 링 · 말" 표의 모든 줄, 이슈 링 고르기(U2-05), 현재 이슈(U2-36), 탭 고르기(U2-26), 알약 자리(U2-09)
struct AgentSessionRulesTests {
    typealias Fx = SessionFx

    // MARK: 2.5 표 (위에서부터 먼저 맞는 줄)

    @Test func aClosedSessionHasNoRingAndSaysClosed() {
        let item = Fx.item(Fx.snapshot(status: .closed, state: .running))
        #expect(item.ring == nil && item.line == "Closed" && item.isClosed && !item.showsInTab)
    }

    @Test func anUnreachableSessionIsConnectionLostEvenWithARunningTask() {
        let item = Fx.item(Fx.snapshot(status: .unreachable, state: .running))
        #expect(item.ring == .unreachable && item.line == "Connection lost · progress unknown" && item.showsInTab)
    }

    @Test func anUnreachableLastTaskIsConnectionLostEvenWhenTheSessionIsBound() {
        let item = Fx.item(Fx.snapshot(status: .bound, state: .unreachable))
        #expect(item.ring == .unreachable && item.line == "Connection lost · progress unknown")
    }

    @Test func anOpenTaskWithAStopRequestIsStoppingNotConfirmed() {
        for state in [AgentTaskState.dispatched, .accepted, .running, .awaitingAnswer] {
            let item = Fx.item(Fx.snapshot(state: state, cancelRequested: true))
            #expect(item.ring == .stopping && item.line == "Stop requested · not confirmed", "\(state.raw)")
        }
    }

    @Test func aStopRequestOnAFinishedTaskIsNotStopping() {
        // 취소가 확인된 task(cancelled)에도 `cancel_requested_at`이 남는다: 열린 task가 아니면 멈추는 중이 아니다
        let item = Fx.item(Fx.snapshot(state: .cancelled, cancelRequested: true))
        #expect(item.ring == .idle && item.line == "Idle")
    }

    @Test func awaitingAnswerNeedsYou() {
        let item = Fx.item(Fx.snapshot(state: .awaitingAnswer))
        #expect(item.ring == .needsYou && item.line == "Needs your answer")
    }

    @Test func dispatchedAcceptedRunningAreRunning() {
        for state in [AgentTaskState.dispatched, .accepted, .running] {
            let item = Fx.item(Fx.snapshot(state: state))
            #expect(item.ring == .running && item.line == "Running", "\(state.raw)")
        }
    }

    @Test func anExternalSessionSaysOpenInTerminal() {
        let item = Fx.item(Fx.snapshot(status: .external, state: .idle))
        #expect(item.ring == .idle && item.line == "External · Open in Terminal" && item.isExternal)
    }

    @Test func anExternalSessionStillShowsItsOpenTaskFirst() {
        // 표의 차례: external 줄은 열린 task 줄들 뒤다
        let item = Fx.item(Fx.snapshot(status: .external, state: .running))
        #expect(item.ring == .running && item.line == "Running")
    }

    @Test func completedIsDoneForThreeSecondsAfterItWasSeen() {
        let snapshot = Fx.snapshot(state: .completed)
        let seen = Fx.at(10)
        #expect(Fx.item(snapshot, doneObservedAt: seen, now: Fx.at(10)).ring == .done)
        #expect(Fx.item(snapshot, doneObservedAt: seen, now: Fx.at(10)).line == "Done just now")
        #expect(Fx.item(snapshot, doneObservedAt: seen, now: Fx.at(12.9)).ring == .done)
        #expect(Fx.item(snapshot, doneObservedAt: seen, now: Fx.at(13)).ring == .idle)
        #expect(Fx.item(snapshot, doneObservedAt: seen, now: Fx.at(13)).line == "Idle")
    }

    @Test func aDoneObservationDoesNotOutliveTheTasksCompletedState() {
        // 3초 안이어도 task가 이미 completed가 아니면(다음 턴이 시작됐거나 idle로 돌아옴) done이 아니다
        let seen = Fx.at(10)
        #expect(Fx.item(Fx.snapshot(state: .idle), doneObservedAt: seen, now: Fx.at(11)).ring == .idle)
        #expect(Fx.item(Fx.snapshot(state: .running), doneObservedAt: seen, now: Fx.at(11)).ring == .running)
        #expect(Fx.item(Fx.snapshot(state: nil), doneObservedAt: seen, now: Fx.at(11)).ring == .idle)
    }

    @Test func completedThatWasNeverSeenChangingIsIdle() {
        // 앱이 처음 읽을 때 이미 끝나 있던 task는 "방금 끝남"이 아니다
        let item = Fx.item(Fx.snapshot(state: .completed))
        #expect(item.ring == .idle && item.line == "Idle")
    }

    @Test func everythingElseIsIdle() {
        for state in [AgentTaskState.idle, .failed, .cancelled, .unknown("teleporting")] {
            let item = Fx.item(Fx.snapshot(state: state))
            #expect(item.ring == .idle && item.line == "Idle", "\(state.raw)")
        }
        let none = Fx.item(Fx.snapshot(state: nil))
        #expect(none.ring == .idle && none.line == "Idle")
    }

    @Test func anUnknownSessionStatusReadsLikeABoundSession() {
        let item = Fx.item(Fx.snapshot(status: .unknown("hibernating"), state: .running))
        #expect(item.ring == .running && item.showsInTab && !item.isClosed)
        #expect(Fx.item(Fx.snapshot(status: .unknown("hibernating"), state: nil)).line == "Idle")
    }

    // MARK: 이름 · 에이전트 · 접근성 이름

    @Test func theNameIsTheDisplayNameOrTheAgentName() {
        #expect(Fx.item(Fx.snapshot(name: "Pricing copy draft")).name == "Pricing copy draft")
        #expect(Fx.item(Fx.snapshot(name: "")).name == "Claude Code")
        #expect(Fx.item(Fx.snapshot(connection: Fx.codexConnection, name: "")).name == "Codex")
        // 연결을 모르면 에이전트 이름이 "Agent"인 점선 마크다
        let orphan = AgentSessionSnapshot(sessions: [Fx.session(1, name: "")], tasks: [], runs: [], connections: [], conversations: [])
        let item = AgentSessionRules.items(snapshot: orphan, doneObservedAt: [:], now: Fx.t0)[0]
        #expect(item.agent == .placeholder && item.agentName == "Agent" && item.name == "Agent")
    }

    @Test func theAgentComesFromTheConnectionAdapter() {
        let claude = Fx.item(Fx.snapshot(connection: Fx.claudeConnection))
        let codex = Fx.item(Fx.snapshot(connection: Fx.codexConnection))
        #expect(claude.agent == .claudeCode && claude.agentName == "Claude Code")
        #expect(codex.agent == .codex && codex.agentName == "Codex")
    }

    @Test func accessibilityNamesJoinNameAgentAndLine() {
        let item = Fx.item(Fx.snapshot(state: .running, name: "Pricing copy draft"))
        #expect(item.rowAccessibilityName == "Pricing copy draft — Claude Code — Running")
        #expect(item.tabAccessibilityName == "Pricing copy draft · Running")
        let external = Fx.item(Fx.snapshot(status: .external, name: "Pricing copy draft"))
        #expect(external.tabAccessibilityName == "Pricing copy draft · External · Open in Terminal")
    }

    // MARK: 현재 이슈 · 이슈들

    @Test func theCurrentIssueIsTheOneOfTheLastTurnsRun() {
        let first = Fx.issue(1), second = Fx.issue(2)
        let snapshot = AgentSessionSnapshot(
            sessions: [Fx.session(1, turn: 3)],
            tasks: [Fx.task(1, state: .idle, turn: 2), Fx.task(1, state: .running, turn: 3), Fx.task(1, state: .idle, turn: 1)],
            runs: [Fx.run(session: 1, turn: 1, action: first), Fx.run(session: 1, turn: 2, action: first), Fx.run(session: 1, turn: 3, action: second)],
            connections: Fx.connections, conversations: []
        )
        let item = AgentSessionRules.items(snapshot: snapshot, doneObservedAt: [:], now: Fx.t0)[0]
        #expect(item.currentIssueID == second)
        // 한 세션이 이슈 여럿을 맡으면 그 이슈들에 모두 나온다
        #expect(item.issueIDs == [first, second])
    }

    @Test func withoutALastTaskASingleIssueIsStillUnambiguous() {
        let item = Fx.item(Fx.snapshot(state: nil))
        #expect(item.currentIssueID == Fx.issue(1) && item.issueIDs == [Fx.issue(1)])
    }

    @Test func withoutALastTaskSeveralIssuesGiveNoCurrentIssue() {
        let snapshot = AgentSessionSnapshot(
            sessions: [Fx.session(1)], tasks: [], runs: [Fx.run(session: 1, turn: 1, action: Fx.issue(1)), Fx.run(session: 1, turn: 2, action: Fx.issue(2))],
            connections: Fx.connections, conversations: []
        )
        let item = AgentSessionRules.items(snapshot: snapshot, doneObservedAt: [:], now: Fx.t0)[0]
        #expect(item.currentIssueID == nil && item.issueIDs.count == 2)
    }

    @Test func aSessionWithoutAnIssueHasNoIssues() {
        let snapshot = AgentSessionSnapshot(sessions: [Fx.session(1)], tasks: [], runs: [], connections: Fx.connections, conversations: [])
        let item = AgentSessionRules.items(snapshot: snapshot, doneObservedAt: [:], now: Fx.t0)[0]
        #expect(item.issueIDs.isEmpty && item.currentIssueID == nil)
    }

    @Test func onlyConversationRunsTieASessionToAnIssue() {
        let snapshot = AgentSessionSnapshot(
            sessions: [Fx.session(1)], tasks: [],
            runs: [Fx.run(session: 1, turn: 1, action: Fx.issue(1), kind: "task"), Fx.run(session: 1, turn: 2, action: Fx.issue(2))],
            connections: Fx.connections, conversations: []
        )
        let item = AgentSessionRules.items(snapshot: snapshot, doneObservedAt: [:], now: Fx.t0)[0]
        #expect(item.issueIDs == [Fx.issue(2)])
    }

    @Test func theNewestConversationOfTheSessionIsItsConversation() {
        // 읽은 순서(새 것이 먼저)에서 첫 것
        let snapshot = AgentSessionSnapshot(
            sessions: [Fx.session(1), Fx.session(2)], tasks: [], runs: [], connections: Fx.connections,
            conversations: [Fx.conversation(10, session: 1), Fx.conversation(11, session: 2), Fx.conversation(12, session: 1)]
        )
        let items = AgentSessionRules.items(snapshot: snapshot, doneObservedAt: [:], now: Fx.t0)
        #expect(items[0].conversationID == Fx.id(10, prefix: "d0d00000"))
        #expect(items[1].conversationID == Fx.id(11, prefix: "d0d00000"))
    }

    @Test func itemsFollowTheOrderTheyWereCreatedWithTiesBrokenByID() {
        let snapshot = AgentSessionSnapshot(
            sessions: [Fx.session(3, created: 30), Fx.session(1, created: 10), Fx.session(2, created: 10)], tasks: [], runs: [],
            connections: Fx.connections, conversations: []
        )
        #expect(AgentSessionRules.items(snapshot: snapshot, doneObservedAt: [:], now: Fx.t0).map(\.id) == [Fx.id(1), Fx.id(2), Fx.id(3)])
    }

    // MARK: 열린 task

    @Test func openTasksAreTheOnesThatKeepTheReadGoing() {
        for state in [AgentTaskState.dispatched, .accepted, .running, .awaitingAnswer, .unreachable] {
            #expect(Fx.item(Fx.snapshot(state: state)).hasOpenTask, "\(state.raw)")
        }
        for state in [AgentTaskState.idle, .completed, .failed, .cancelled, .unknown("x")] {
            #expect(!Fx.item(Fx.snapshot(state: state)).hasOpenTask, "\(state.raw)")
        }
        #expect(!Fx.item(Fx.snapshot(state: nil)).hasOpenTask)
        #expect(!Fx.item(Fx.snapshot(status: .closed, state: .running)).hasOpenTask)
    }

    // MARK: 알약 자리 (U2-09)

    @Test func theTerminalPillIsOnlyForBoundAfterTheFirstTurnAndExternal() {
        #expect(Fx.item(Fx.snapshot(state: .idle)).pill == .openInTerminal(disabledReason: nil))
        #expect(Fx.item(Fx.snapshot(state: nil)).pill == .openInTerminal(disabledReason: nil))
        #expect(Fx.item(Fx.snapshot(state: nil, pending: true)).pill == nil, "첫 턴 전")
        #expect(Fx.item(Fx.snapshot(status: .unreachable, state: .idle)).pill == nil)
        #expect(Fx.item(Fx.snapshot(status: .closed, state: .idle)).pill == nil)
        #expect(Fx.item(Fx.snapshot(status: .external, state: .idle)).pill == .resumeHere)
        #expect(Fx.item(Fx.snapshot(status: .unknown("x"), state: .idle)).pill == nil)
        // 마지막 턴이 끊긴 세션: 서버가 거절하는데 새 문구를 만들지 않는다
        #expect(Fx.item(Fx.snapshot(status: .bound, state: .unreachable)).pill == nil)
    }

    @Test func openInTerminalIsOffWithTheTwoDesignReasons() {
        for state in [AgentTaskState.dispatched, .accepted, .running] {
            #expect(Fx.item(Fx.snapshot(state: state)).pill == .openInTerminal(disabledReason: "Turn is running"), "\(state.raw)")
        }
        #expect(Fx.item(Fx.snapshot(state: .awaitingAnswer)).pill == .openInTerminal(disabledReason: "Answer the question first"))
        #expect(AgentSessionPill.openInTerminal(disabledReason: "Turn is running").isEnabled == false)
        #expect(AgentSessionPill.openInTerminal(disabledReason: nil).isEnabled)
        #expect(AgentSessionPill.openInTerminal(disabledReason: nil).title == "Open in Terminal")
        #expect(AgentSessionPill.resumeHere.title == "Resume here" && AgentSessionPill.resumeHere.isEnabled)
    }

    // MARK: 이슈 링 고르기 (U2-05)

    @Test func theIssueRingIsTheFirstOfNeedsYouUnreachableStoppingRunningDoneWaiting() {
        let order: [AgentSessionRing] = [.needsYou, .unreachable, .stopping, .running, .done, .waiting]
        for (index, ring) in order.enumerated() {
            // 이 링보다 늦은 링들이 함께 있어도 이 링이 이긴다 (세션 링으로도, v1 링으로도)
            let later = Array(order[(index + 1)...])
            #expect(AgentSessionRules.issueRing(v1: nil, sessions: ([ring] + later).map { Self.session(ring: $0) }) == ring, "\(ring)")
            #expect(AgentSessionRules.issueRing(v1: ring, sessions: later.map { Self.session(ring: $0) }) == ring, "\(ring)")
            #expect(AgentSessionRules.issueRing(v1: later.first, sessions: [Self.session(ring: ring)]) == ring, "\(ring)")
        }
        #expect(AgentSessionRules.issueRing(v1: nil, sessions: []) == nil)
    }

    @Test func idleAndClosedSessionsNeverGiveARing() {
        #expect(AgentSessionRules.issueRing(v1: nil, sessions: [Self.session(ring: .idle), Self.session(ring: nil)]) == nil)
        #expect(AgentSessionRules.issueRing(v1: .running, sessions: [Self.session(ring: .idle)]) == .running)
    }

    @Test func aSessionRingOutranksAQuieterV1Ring() {
        #expect(AgentSessionRules.issueRing(v1: .running, sessions: [Self.session(ring: .needsYou)]) == .needsYou)
        #expect(AgentSessionRules.issueRing(v1: .running, sessions: [Self.session(ring: .unreachable)]) == .unreachable)
        #expect(AgentSessionRules.issueRing(v1: .done, sessions: [Self.session(ring: .running)]) == .running)
    }

    @Test func theActivityLineFollowsTheWinningRing() {
        #expect(AgentSessionRing.needsYou.activityLine == "Needs your answer")
        #expect(AgentSessionRing.unreachable.activityLine == "Connection lost · progress unknown")
        #expect(AgentSessionRing.stopping.activityLine == "Stop requested · not confirmed")
        #expect(AgentSessionRing.running.activityLine == "Running")
        #expect(AgentSessionRing.done.activityLine == nil)
        #expect(AgentSessionRing.waiting.activityLine == nil)
        #expect(AgentSessionRing.idle.activityLine == nil)
    }

    @Test func v1ActivityTextsMapToTheirRings() {
        #expect(AgentSessionRing(v1Activity: WorkActivity.needsAnswer) == .needsYou)
        #expect(AgentSessionRing(v1Activity: WorkActivity.running) == .running)
        #expect(AgentSessionRing(v1Activity: WorkActivity.stopRequested) == .stopping)
        #expect(AgentSessionRing(v1Activity: nil) == nil)
        #expect(AgentSessionRing(v1Activity: "Something else") == nil)
    }

    // MARK: 탭 고르기 (U2-26)

    @Test func scopeKeepsOnlyTheSessionsOfTheOpenIssues() {
        let a = Self.session(id: 1, issues: [Fx.issue(1)]), b = Self.session(id: 2, issues: [Fx.issue(2)]), both = Self.session(id: 3, issues: [Fx.issue(1), Fx.issue(2)])
        let none = Self.session(id: 4, issues: [])
        let all = [a, b, both, none]
        #expect(AgentSessionRules.sessions(of: [Fx.issue(1)], in: all).map(\.id) == [a.id, both.id])
        #expect(AgentSessionRules.sessions(of: [Fx.issue(1), Fx.issue(2)], in: all).map(\.id) == [a.id, b.id, both.id])
        #expect(AgentSessionRules.sessions(of: [], in: all).isEmpty)
        // 이슈가 없는 세션은 어느 이슈의 목록에도 없다
        #expect(!AgentSessionRules.sessions(of: [Fx.issue(1)], in: all).contains { $0.id == none.id })
    }

    @Test func theTabNeverShowsClosedSessionsButTheIssueListDoes() {
        let open = Self.session(id: 1, issues: [Fx.issue(1)], created: 5), closed = Self.session(id: 2, issues: [Fx.issue(1)], ring: nil, status: .closed, created: 1)
        #expect(AgentSessionRules.tabPlan(sessions: [open, closed], currentID: nil).shown.map(\.id) == [open.id])
        // Sessions 목록은 닫힌 세션을 맨 아래에 둔다
        #expect(AgentSessionRules.listOrder([closed, open]).map(\.id) == [open.id, closed.id])
    }

    @Test func upToSixSessionsAllShowInCreationOrder() {
        let sessions = (1...6).map { Self.session(id: $0, issues: [Fx.issue(1)], created: Double(7 - $0)) }
        let plan = AgentSessionRules.tabPlan(sessions: sessions, currentID: nil)
        #expect(plan.shown.map(\.id) == sessions.reversed().map(\.id), "오래된 것이 위")
        #expect(plan.hidden.isEmpty)
    }

    @Test func nineSessionsShowSixAndMoreKeepingCurrentAndNeedsYou() {
        var sessions = (1...9).map { Self.session(id: $0, issues: [Fx.issue(1)], ring: .running, created: Double($0), updated: Double($0)) }
        // 현재 세션은 오래 전에 갱신됐고, needs-you 하나도 오래됐다: 둘 다 남는다
        sessions[0] = Self.session(id: 1, issues: [Fx.issue(1)], ring: .running, created: 1, updated: 0)
        sessions[1] = Self.session(id: 2, issues: [Fx.issue(1)], ring: .needsYou, created: 2, updated: 0.5)
        let plan = AgentSessionRules.tabPlan(sessions: sessions, currentID: sessions[0].id)
        #expect(plan.shown.count == 6 && plan.hidden.count == 3)
        #expect(plan.shown.contains { $0.id == sessions[0].id } && plan.shown.contains { $0.id == sessions[1].id })
        // 나머지 넷은 최근 갱신 순: 9 · 8 · 7 · 6
        #expect(Set(plan.shown.map(\.id)) == Set([1, 2, 9, 8, 7, 6].map { Fx.id($0) }))
        // 보이는 순서는 만든 시각 순이라 갱신해도 흔들리지 않는다
        #expect(plan.shown.map(\.id) == [1, 2, 6, 7, 8, 9].map { Fx.id($0) })
        #expect(plan.hidden.map(\.id) == [3, 4, 5].map { Fx.id($0) })
    }

    @Test func theVisibleOrderDoesNotChangeWhenASessionIsUpdated() {
        var sessions = (1...9).map { Self.session(id: $0, issues: [Fx.issue(1)], created: Double($0), updated: Double($0)) }
        let before = AgentSessionRules.tabPlan(sessions: sessions, currentID: nil).shown.map(\.id)
        // 이미 보이던 세션 하나가 더 최근에 갱신돼도 같은 자리다
        sessions[5] = Self.session(id: 6, issues: [Fx.issue(1)], created: 6, updated: 100)
        let after = AgentSessionRules.tabPlan(sessions: sessions, currentID: nil).shown.map(\.id)
        #expect(before == [4, 5, 6, 7, 8, 9].map { Fx.id($0) })
        #expect(after == before)
    }

    @Test func moreThanSixNeedYouStillNeverShowMoreThanSix() {
        let sessions = (1...8).map { Self.session(id: $0, issues: [Fx.issue(1)], ring: .needsYou, created: Double($0), updated: Double($0)) }
        let plan = AgentSessionRules.tabPlan(sessions: sessions, currentID: Fx.id(1))
        #expect(plan.shown.count == 6 && plan.hidden.count == 2)
        // 현재 세션이 먼저 남고, needs-you는 최근 갱신 순으로 남는다
        #expect(Set(plan.shown.map(\.id)) == Set([1, 8, 7, 6, 5, 4].map { Fx.id($0) }))
        #expect(plan.hidden.map(\.id) == [2, 3].map { Fx.id($0) })
    }

    @Test func aNeedsYouSessionOutranksARecentOne() {
        // 여섯 칸 가운데 하나만 남는 경우: needs-you가 최근 갱신보다 먼저다
        let quiet = (1...6).map { Self.session(id: $0, issues: [Fx.issue(1)], ring: .running, created: Double($0), updated: Double($0) + 100) }
        let needs = Self.session(id: 7, issues: [Fx.issue(1)], ring: .needsYou, created: 7, updated: 0)
        let plan = AgentSessionRules.tabPlan(sessions: quiet + [needs], currentID: nil)
        #expect(plan.shown.contains { $0.id == needs.id })
        #expect(plan.hidden.map(\.id) == [Fx.id(1)], "가장 덜 최근에 갱신된 것이 More로 간다")
    }

    // MARK: 도우미

    /// 규칙 시험용 항목 (링 · 이슈 · 시각만 정한다)
    static func session(
        id: Int, issues: [UUID] = [], ring: AgentSessionRing? = .idle, status: AgentSessionStatus = .bound, created: Double = 0, updated: Double = 0
    ) -> AgentSessionItem {
        AgentSessionItem(
            id: Fx.id(id), name: "S\(id)", agent: .claudeCode, agentName: "Claude Code", connectionID: Fx.claudeConnection, status: status,
            ring: ring, line: ring?.label ?? "Closed", createdAt: Fx.at(created), updatedAt: Fx.at(updated), issueIDs: issues,
            currentIssueID: issues.first, conversationID: nil, hasOpenTask: false, pill: nil
        )
    }

    static func session(ring: AgentSessionRing?) -> AgentSessionItem { session(id: 1, ring: ring) }
}
