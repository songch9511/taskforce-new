import Foundation
import Testing
@testable import TaskforceKit

/// 세션 알약을 어느 Mac에 보이나 (OA D4a-03) · 세션 항목이 Stop에 쓰는 값 (D4a-13)
/// 알약은 그 세션 연결의 `agent_connections.bridge_id`가 이 Mac의 bridge id와 같을 때만 보인다. 다른 Mac과 `bridge_id`가 null이면 알약이 없다 (터미널은 그 Mac에서만 열 수 있다)
struct AgentSessionPillRulesTests {
    typealias Fx = SessionFx
    let thisMac = UUID(uuidString: "b1d6e000-0000-4000-8000-000000000001")!
    let otherMac = UUID(uuidString: "b1d6e000-0000-4000-8000-000000000002")!

    func item(bridge: UUID?, status: AgentSessionStatus = .bound, state: AgentTaskState? = .idle) -> AgentSessionItem {
        var snapshot = Fx.snapshot(status: status, state: state)
        snapshot.connections = [AgentConnectionRecord(id: Fx.claudeConnection, adapter: "agent:claude-code", bridgeID: bridge)]
        return Fx.item(snapshot)
    }

    // MARK: 이 Mac

    @Test func theConnectionsBridgeIDComesFromTheReadRow() throws {
        let row = try TaskforceJSON.decoder().decode(
            AgentConnectionRecord.self, from: Data(#"{"id":"c0c0c0c0-0000-4000-8000-000000000001","adapter":"agent:codex","bridge_id":"b1d6e000-0000-4000-8000-000000000001"}"#.utf8)
        )
        #expect(row.bridgeID == thisMac)
        let none = try TaskforceJSON.decoder().decode(AgentConnectionRecord.self, from: Data(#"{"id":"c0c0c0c0-0000-4000-8000-000000000001","adapter":"agent:codex","bridge_id":null}"#.utf8))
        #expect(none.bridgeID == nil)
        let missing = try TaskforceJSON.decoder().decode(AgentConnectionRecord.self, from: Data(#"{"id":"c0c0c0c0-0000-4000-8000-000000000001","adapter":"agent:codex"}"#.utf8))
        #expect(missing.bridgeID == nil, "열이 없는 DB도 읽는다")
        #expect(item(bridge: thisMac).connectionBridgeID == thisMac)
    }

    @Test func thePillIsOnlyOnTheMacThatRunsTheSession() {
        #expect(AgentSessionRules.isOnThisMac(item(bridge: thisMac), thisMacBridgeID: thisMac))
        #expect(!AgentSessionRules.isOnThisMac(item(bridge: otherMac), thisMacBridgeID: thisMac), "다른 Mac")
        #expect(!AgentSessionRules.isOnThisMac(item(bridge: nil), thisMacBridgeID: thisMac), "bridge_id가 null: 그 Mac을 모른다")
        #expect(!AgentSessionRules.isOnThisMac(item(bridge: thisMac), thisMacBridgeID: nil), "이 Mac이 bridge를 켜지 않았다")
        #expect(!AgentSessionRules.isOnThisMac(item(bridge: nil), thisMacBridgeID: nil), "둘 다 모르면 같다고 하지 않는다")
    }

    @Test func theVisiblePillFollowsTheRuleAndThePillRulesStayAsU2MadeThem() {
        #expect(AgentSessionRules.visiblePill(item(bridge: thisMac), thisMacBridgeID: thisMac) == .openInTerminal(disabledReason: nil))
        #expect(AgentSessionRules.visiblePill(item(bridge: thisMac, status: .external), thisMacBridgeID: thisMac) == .resumeHere)
        #expect(AgentSessionRules.visiblePill(item(bridge: otherMac, status: .external), thisMacBridgeID: thisMac) == nil, "다른 Mac의 세션: 알약 없음")
        #expect(AgentSessionRules.visiblePill(item(bridge: nil), thisMacBridgeID: thisMac) == nil)
        #expect(AgentSessionRules.visiblePill(item(bridge: thisMac, status: .closed), thisMacBridgeID: thisMac) == nil, "닫힌 세션은 U2 그대로 알약이 없다")
        #expect(AgentSessionRules.visiblePill(item(bridge: thisMac, state: .running), thisMacBridgeID: thisMac) == .openInTerminal(disabledReason: "Turn is running"))
    }

    // MARK: Stop에 쓰는 값

    @Test func theItemCarriesTheLastTasksStateAndTheStopRequestAndTheTurn() {
        var snapshot = Fx.snapshot(state: .running, cancelRequested: true)
        snapshot.sessions[0] = Fx.session(1, turn: 4)
        snapshot.tasks = [Fx.task(1, state: .running, turn: 4, cancelRequested: true)]
        let item = Fx.item(snapshot)
        #expect(item.lastTaskState == .running && item.cancelRequested && item.turnSeq == 4)
        let idle = Fx.item(Fx.snapshot(state: nil))
        #expect(idle.lastTaskState == nil && !idle.cancelRequested)
    }
}
