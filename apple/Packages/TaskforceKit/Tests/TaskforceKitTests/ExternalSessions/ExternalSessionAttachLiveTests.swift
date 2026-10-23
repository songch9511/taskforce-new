#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 이어받기의 실제 면 (OA 외부 세션 PR2m): 대상 목록에서 **이 Mac의** Claude Code 연결을 가려낸다 (계약 20장 2: 응답한 세션 행의 연결이 이 Mac의 것인지 대조하는 값)
@MainActor
struct ExternalSessionAttachLiveTests {
    nonisolated static let mac = UUID(uuidString: "b1b1b1b1-0000-4000-8000-0000000000a1")!
    nonisolated static let otherMac = UUID(uuidString: "b1b1b1b1-0000-4000-8000-0000000000a2")!
    nonisolated static let thisConnection = UUID(uuidString: "c0c0c0c0-0000-4000-8000-0000000000a1")!
    nonisolated static let otherConnection = UUID(uuidString: "c0c0c0c0-0000-4000-8000-0000000000a2")!

    private func store(_ targets: [AssistantTarget]) -> AssistantTargetsStore {
        let gateway = FakeAssistantGateway()
        gateway.targetsHandler = { targets }
        return AssistantTargetsStore(gateway: gateway, scope: ChatTestAccount.fixedScope(), canRunAgents: { true })
    }

    private func claude(_ connection: UUID?, bridge: UUID?, state: AgentTargetState = .ready, access: AgentAccessLevel? = .write, adapter: String = "agent:claude-code") -> AssistantTarget {
        .agent(.init(adapter: adapter, displayName: "Claude Code", connectionID: connection, state: state, access: access, bridgeID: bridge))
    }

    @Test func theConnectionOfThisMacIsTheOneWhoseBridgeIsThisMac() async {
        let targets = store([.taskforce, claude(Self.otherConnection, bridge: Self.otherMac), claude(Self.thisConnection, bridge: Self.mac)])
        #expect(await targets.attachTarget(bridgeID: Self.mac) == ExternalSessionAttachTarget(connectionID: Self.thisConnection, word: nil))
        #expect(await targets.attachTarget(bridgeID: Self.otherMac) == ExternalSessionAttachTarget(connectionID: Self.otherConnection, word: nil))
    }

    @Test func aReadOnlyConnectionIsStillReady() async {
        let targets = store([claude(Self.thisConnection, bridge: Self.mac, access: .readOnly)])
        #expect(await targets.attachTarget(bridgeID: Self.mac)?.word == nil)
    }

    @Test func aConnectionThatIsNotReadySaysItsApprovedWord() async {
        for (state, word) in [(AgentTargetState.unreachable, "Offline"), (.signInNeeded, "Sign in needed"), (.unsupported, "Unsupported"), (.notConnected, "Not connected"), (.unknown("x"), "Not connected")] {
            let targets = store([claude(Self.thisConnection, bridge: Self.mac, state: state)])
            #expect(await targets.attachTarget(bridgeID: Self.mac) == ExternalSessionAttachTarget(connectionID: Self.thisConnection, word: word), "\(state)")
        }
    }

    @Test func noConnectionForThisMacIsNotConnected() async {
        let targets = store([
            .taskforce, claude(Self.otherConnection, bridge: Self.otherMac), claude(Self.thisConnection, bridge: Self.mac, adapter: "agent:codex"), claude(nil, bridge: Self.mac),
            claude(Self.otherConnection, bridge: nil),
        ])
        #expect(await targets.attachTarget(bridgeID: Self.mac) == ExternalSessionAttachTarget(connectionID: nil, word: "Not connected"), "다른 Mac · 다른 adapter · 연결 없음 · bridge를 모르는 행은 이 Mac의 것이 아니다")
    }

    @Test func aTargetListThatCouldNotBeReadIsUnknownNotNotConnected() async {
        let gateway = FakeAssistantGateway()
        gateway.targetsHandler = { throw URLError(.notConnectedToInternet) }
        let targets = AssistantTargetsStore(gateway: gateway, scope: ChatTestAccount.fixedScope(), canRunAgents: { true })
        #expect(await targets.attachTarget(bridgeID: Self.mac) == nil)
    }
}
#endif
