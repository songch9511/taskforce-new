import Foundation
import Testing
@testable import TaskforceKit

/// 대상 고르기 규칙 (OA U1): 행 이름 · 마크 · 상태 단어 · 기기 이름 · 대화를 만들 대상. 서버 판정(상태)은 다시 계산하지 않고 단어로만 옮긴다
struct AssistantTargetRulesTests {
    let claudeConnection = UUID(uuidString: "a3333333-3333-4333-8333-333333333333")!
    let codexConnection = UUID(uuidString: "a3333333-3333-4333-8333-333333333334")!
    let otherCodexConnection = UUID(uuidString: "a3333333-3333-4333-8333-333333333335")!

    func agent(_ adapter: String, _ name: String, _ connection: UUID?, _ state: AgentTargetState, _ access: AgentAccessLevel? = nil) -> AssistantTarget {
        .agent(.init(adapter: adapter, displayName: name, connectionID: connection, state: state, access: access))
    }

    func options(_ targets: [AssistantTarget], canRun: Bool = true, deviceNames: [UUID: String] = [:]) -> [AssistantTargetOption] {
        AssistantTargetRules.options(from: targets, canRunAgents: canRun, deviceName: { deviceNames[$0] })
    }

    @Test func taskforceComesFirstThenAgentsInServerOrder() {
        let rows = options([
            .taskforce,
            agent("agent:claude-code", "Claude Code", claudeConnection, .ready, .write),
            agent("agent:codex", "Codex", codexConnection, .ready, .write),
        ])
        #expect(rows.map(\.name) == ["Taskforce", "Claude Code", "Codex"])
        #expect(rows.map(\.mark) == [.taskforce, .claudeCode, .codex])
        #expect(rows[0].kind == .taskforce && !rows[0].isAgent)
        #expect(rows[1].isAgent && rows[1].connectionID == claudeConnection)
        // 서버가 Taskforce를 빼 먹어도 목록은 늘 Taskforce로 시작한다 (기본 대상)
        let withoutTaskforce = options([agent("agent:codex", "Codex", codexConnection, .ready, .write)])
        #expect(withoutTaskforce.map(\.name) == ["Taskforce", "Codex"])
        #expect(options([]).map(\.name) == ["Taskforce"])
    }

    @Test func statusWordsFollowStateAndAccessLikeSettings() {
        func word(_ state: AgentTargetState, _ access: AgentAccessLevel? = nil) -> String? {
            options([agent("agent:codex", "Codex", codexConnection, state, access)])[1].status
        }
        #expect(word(.ready, .write) == nil, "정상은 이름만")
        #expect(word(.ready, .readOnly) == "Read only")
        #expect(word(.ready) == nil)
        #expect(word(.unsupported) == "Unsupported")
        #expect(word(.notConnected) == "Not connected")
        #expect(word(.notConnected, .readOnly) == "Not connected", "연결이 없으면 접근 등급보다 연결이 먼저다")
        #expect(word(.signInNeeded) == "Sign in needed")
        #expect(word(.unreachable) == "Offline", "heartbeat가 끊긴 연결: 짧은 관례 단어")
        #expect(word(.unknown("hibernating")) == nil, "모르는 상태는 주장하지 않는다")
        #expect(word(.ready, .unknown("admin")) == nil)
    }

    @Test func aBuildThatCannotRunAgentsSaysSoOnEveryAgentRowAndNotOnTaskforce() {
        let rows = options([
            .taskforce,
            agent("agent:claude-code", "Claude Code", claudeConnection, .unsupported),
            agent("agent:codex", "Codex", codexConnection, .ready, .readOnly),
        ], canRun: false)
        #expect(rows[0].status == nil)
        #expect(rows[1].status == "Can't run agents in this build")
        #expect(rows[2].status == "Can't run agents in this build", "Claude Code와 Codex 모두 (DS TargetPicker)")
    }

    @Test func aStatusNeverMakesATargetUnselectableButNoConnectionCannotCreateAChat() {
        let rows = options([
            agent("agent:claude-code", "Claude Code", claudeConnection, .unsupported),
            agent("agent:codex", "Codex", nil, .notConnected, .readOnly),
        ])
        #expect(rows[0].chatTarget == .taskforce)
        #expect(rows[1].chatTarget == .agent(connectionID: claudeConnection), "상태가 있어도 고를 수 있다 — 서버가 전달 상태로 답한다")
        #expect(rows[2].chatTarget == nil && rows[2].connectionID == nil, "연결이 없으면 보낼 곳이 없다: 보내기에서 이유를 말한다")
        #expect(rows.allSatisfy { !$0.isDisabled }, "어두워지지 않는다 (Read only도 메시지를 받는다)")
    }

    @Test func twoConnectionsOfOneAdapterAreTwoRowsToldApartByTheDeviceName() {
        let targets: [AssistantTarget] = [
            agent("agent:codex", "Codex", codexConnection, .ready, .readOnly),
            agent("agent:codex", "Codex", otherCodexConnection, .unreachable),
            agent("agent:claude-code", "Claude Code", claudeConnection, .ready, .write),
        ]
        let rows = options(targets, deviceNames: [codexConnection: "Mac mini", otherCodexConnection: "MacBook Pro", claudeConnection: "Mac mini"])
        #expect(rows.map(\.name) == ["Taskforce", "Codex", "Codex", "Claude Code"])
        #expect(rows[1].deviceName == "Mac mini" && rows[2].deviceName == "MacBook Pro")
        #expect(rows[3].deviceName == nil, "연결이 하나인 adapter는 기기 이름을 붙이지 않는다")
        #expect(rows[1].detail == "Mac mini · Read only" && rows[2].detail == "MacBook Pro · Offline")
        #expect(rows[3].detail == nil)
        #expect(Set(rows.map(\.id)).count == rows.count, "행 id는 겹치지 않는다")
        // 기기 이름을 모르면(서버가 아직 주지 않는다) 이름 없이 두 행을 그대로 보인다
        let unnamed = options(targets)
        #expect(unnamed[1].deviceName == nil && unnamed[2].deviceName == nil && unnamed.count == 4)
        #expect(unnamed[1].detail == "Read only" && unnamed[2].detail == "Offline")
    }

    @Test func unknownKindsAndAdaptersAreHandledWithoutBreakingTheList() {
        let rows = options([.taskforce, .other("workspace"), agent("agent:future", "Future", nil, .notConnected)])
        #expect(rows.map(\.name) == ["Taskforce", "Future"], "모르는 kind 행은 보이지 않는다")
        #expect(rows[1].mark == .placeholder, "공급된 마크가 없는 adapter는 점선 사각형")
        #expect(AgentMarkKind.of(adapter: "agent:claude-code") == .claudeCode)
        #expect(AgentMarkKind.of(adapter: "agent:codex") == .codex)
        #expect(AgentMarkKind.of(adapter: "") == .placeholder)
    }

    @Test func theChosenOptionIsFoundByWhatTheConversationAlreadyHas() {
        let rows = options([
            agent("agent:codex", "Codex", codexConnection, .ready, .write),
            agent("agent:codex", "Codex", otherCodexConnection, .ready, .write),
        ])
        #expect(AssistantTargetRules.index(of: .taskforce, in: rows) == 0)
        #expect(AssistantTargetRules.index(of: .agent(adapter: "agent:codex", connectionID: otherCodexConnection), in: rows) == 2)
        // 서버에 있는 에이전트 대화는 연결 id만 안다 (adapter 빈 글자)
        #expect(AssistantTargetRules.index(of: .agent(adapter: "", connectionID: codexConnection), in: rows) == 1)
        // 연결 없이 고른 draft는 adapter의 첫 행
        #expect(AssistantTargetRules.index(of: .agent(adapter: "agent:codex", connectionID: nil), in: rows) == 1)
        // 목록에 없는 대상(꺼진 adapter · 지운 연결)은 못 찾는다
        #expect(AssistantTargetRules.index(of: .agent(adapter: "agent:codex", connectionID: UUID()), in: rows) == nil)
    }
}
