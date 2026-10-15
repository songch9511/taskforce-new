import Foundation
import Testing
@testable import TaskforceKit

/// 세션 다시 읽기 규칙 (U2-35 · 계약 3.1 ③): 열린 task(dispatched · accepted · running · awaiting_answer · unreachable · Stop 요청)가 하나라도 있으면 5초마다,
/// 없거나 앱이 잠자면 멈춘다. `agent_sessions` · `agent_tasks`는 Realtime 발행 대상이 아니라 이 규칙이 갱신을 대신한다
struct AgentSessionReadPolicyTests {
    typealias Fx = SessionFx

    private func items(_ states: [AgentTaskState?], status: AgentSessionStatus = .bound, cancelRequested: Bool = false) -> [AgentSessionItem] {
        let sessions = states.indices.map { Fx.session($0 + 1, status: status) }
        let tasks = states.enumerated().compactMap { index, state in state.map { Fx.task(index + 1, state: $0, cancelRequested: cancelRequested) } }
        return AgentSessionRules.items(
            snapshot: AgentSessionSnapshot(sessions: sessions, tasks: tasks, runs: [], connections: Fx.connections, conversations: []),
            doneObservedAt: [:], now: Fx.t0
        )
    }

    @Test func anOpenTaskAsksForFiveSeconds() {
        #expect(AgentSessionReadPolicy.interval == 5)
        for state in [AgentTaskState.dispatched, .accepted, .running, .awaitingAnswer, .unreachable] {
            #expect(AgentSessionReadPolicy.pollInterval(items: items([state]), asleep: false) == 5, "\(state.raw)")
        }
    }

    @Test func aStopRequestOnAnOpenTaskKeepsReading() {
        #expect(AgentSessionReadPolicy.pollInterval(items: items([.running], cancelRequested: true), asleep: false) == 5)
    }

    @Test func noOpenTaskStopsTheReading() {
        for state in [AgentTaskState.idle, .completed, .failed, .cancelled, .unknown("x")] {
            #expect(AgentSessionReadPolicy.pollInterval(items: items([state]), asleep: false) == nil, "\(state.raw)")
        }
        #expect(AgentSessionReadPolicy.pollInterval(items: items([nil]), asleep: false) == nil)
        #expect(AgentSessionReadPolicy.pollInterval(items: [], asleep: false) == nil)
    }

    @Test func oneOpenTaskAmongQuietOnesIsEnough() {
        #expect(AgentSessionReadPolicy.pollInterval(items: items([.idle, .failed, .running, .idle]), asleep: false) == 5)
    }

    @Test func aSleepingAppDoesNotRead() {
        #expect(AgentSessionReadPolicy.pollInterval(items: items([.running]), asleep: true) == nil)
    }

    @Test func aClosedSessionsOpenTaskDoesNotKeepTheReadingGoing() {
        #expect(AgentSessionReadPolicy.pollInterval(items: items([.running], status: .closed), asleep: false) == nil)
    }
}
