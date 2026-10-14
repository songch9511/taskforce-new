import Foundation

// Assistant 창의 대상 고르기 규칙 (OA U1, DS TargetPicker). 서버가 판정한 대상 상태(`GET /api/v2/assistant/targets`)를 **단어로만** 옮긴다:
// 상태를 다시 계산하지 않는다 (CLAUDE.md "Swift는 서버 판정을 다시 구현하지 않는다"). 단어는 Settings › Your agents와 같다.
// 로고는 대상 메뉴의 `AgentMark`뿐이다 (알약 · 칩 · 창 머리에는 이름만).

/// 공급된 에이전트 마크 (DS AgentMark): Taskforce · Claude Code · Codex, 그 밖의 adapter는 점선 사각형
public enum AgentMarkKind: String, Sendable, Hashable, CaseIterable {
    case taskforce, claudeCode, codex, placeholder

    public static func of(adapter: String) -> AgentMarkKind {
        switch adapter {
        case "agent:claude-code": .claudeCode
        case "agent:codex": .codex
        default: .placeholder
        }
    }

    /// 접근성 이름: 에이전트의 이름
    public var accessibilityName: String {
        switch self {
        case .taskforce: "Taskforce"
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .placeholder: "Agent"
        }
    }
}

/// 대화가 가진(또는 새 대화가 고른) 대상. 연결 없이 고른 에이전트(`connectionID == nil`)는 보내기에서 이유를 말한다
public enum AssistantTargetPick: Hashable, Sendable {
    case taskforce
    case agent(adapter: String, connectionID: UUID?)

    public var isAgent: Bool {
        if case .agent = self { return true }
        return false
    }

    /// 같은 대상인가. 연결을 아는 쪽은 연결 id로, 모르면 adapter로 (서버 대화는 adapter를 모르고, 연결 없이 고른 draft는 연결을 모른다)
    public func isSame(as other: AssistantTargetPick) -> Bool {
        switch (self, other) {
        case (.taskforce, .taskforce): true
        case (.agent(let adapter, let connection), .agent(let otherAdapter, let otherConnection)):
            connection != nil || otherConnection != nil ? connection == otherConnection : adapter == otherAdapter
        default: false
        }
    }
}

/// 대상 메뉴의 한 행
public struct AssistantTargetOption: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case taskforce
        case agent(adapter: String, connectionID: UUID?)
    }

    public let id: String
    public let kind: Kind
    public let name: String
    public let mark: AgentMarkKind
    /// 행 오른쪽 상태 단어 (정상이면 nil). 상태가 있어도 고를 수 있다
    public let status: String?
    /// 같은 adapter의 연결이 둘 이상일 때만 (기기 이름은 서버가 아직 주지 않아 지금은 보통 nil)
    public let deviceName: String?

    public var isAgent: Bool { kind != .taskforce }

    public var connectionID: UUID? {
        if case .agent(_, let connectionID) = kind { return connectionID }
        return nil
    }

    public var pick: AssistantTargetPick {
        switch kind {
        case .taskforce: .taskforce
        case .agent(let adapter, let connectionID): .agent(adapter: adapter, connectionID: connectionID)
        }
    }

    /// 대화를 만들 때 서버에 보낼 대상. 에이전트인데 연결이 없으면 nil (대화를 만들 곳이 없다)
    public var chatTarget: ChatTarget? {
        switch kind {
        case .taskforce: .taskforce
        case .agent(_, let connectionID): connectionID.map { .agent(connectionID: $0) }
        }
    }

    /// 상태가 있어도 어두워지지 않는다 ("Read only"도 메시지를 받는다)
    public var isDisabled: Bool { false }

    /// 행 오른쪽 글: 기기 이름 · 상태 단어
    public var detail: String? {
        let parts = [deviceName, status].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public var accessibilityLabel: String {
        [name, detail].compactMap { $0 }.joined(separator: ", ")
    }
}

public enum AssistantTargetRules {
    public static let taskforceName = "Taskforce"
    public static let unsupported = "Unsupported"
    public static let readOnly = "Read only"
    public static let signInNeeded = "Sign in needed"
    public static let notConnected = "Not connected"
    /// `unreachable`(heartbeat가 90초 넘게 없음): DS에 단어가 없어 짧은 관례 단어를 쓴다 (U1-18)
    public static let offline = "Offline"
    /// 이 빌드(샌드박스)가 에이전트를 띄울 수 없다: API에 없고 클라이언트가 안다 (`AgentRuntimeEnvironment`)
    public static let cannotRunInThisBuild = "Can't run agents in this build"

    /// 서버 상태 → 단어. 모르는 상태는 아무것도 주장하지 않는다 (nil)
    static func statusWord(state: AgentTargetState, access: AgentAccessLevel?) -> String? {
        switch state {
        case .unsupported: unsupported
        case .notConnected: notConnected
        case .signInNeeded: signInNeeded
        case .unreachable: offline
        case .ready: access == .readOnly ? readOnly : nil
        case .unknown: nil
        }
    }

    /// 대상 메뉴의 행들: Taskforce가 늘 처음이고 에이전트는 서버 순서 그대로 (연결마다 한 행, OD-20).
    /// - canRunAgents: 이 빌드가 에이전트를 띄울 수 있는가. 아니면 모든 에이전트 행의 상태가 "Can't run agents in this build"다
    /// - deviceName: 같은 adapter의 연결이 둘 이상일 때 행을 가르는 기기 이름 (모르면 nil)
    public static func options(
        from targets: [AssistantTarget], canRunAgents: Bool, deviceName: (UUID) -> String? = { _ in nil }
    ) -> [AssistantTargetOption] {
        var agents: [AssistantTarget.Agent] = []
        for target in targets {
            if case .agent(let agent) = target { agents.append(agent) }
        }
        let perAdapter = Dictionary(grouping: agents, by: \.adapter).mapValues(\.count)
        var rows = [AssistantTargetOption(id: "taskforce", kind: .taskforce, name: taskforceName, mark: .taskforce, status: nil, deviceName: nil)]
        var used: Set<String> = ["taskforce"]
        for agent in agents {
            var id = "agent:\(agent.adapter):\(agent.connectionID?.uuidString.lowercased() ?? "none")"
            var suffix = 2
            while !used.insert(id).inserted {
                id = "agent:\(agent.adapter):\(agent.connectionID?.uuidString.lowercased() ?? "none"):\(suffix)"
                suffix += 1
            }
            let device = (perAdapter[agent.adapter] ?? 0) > 1 ? agent.connectionID.flatMap(deviceName) : nil
            rows.append(AssistantTargetOption(
                id: id, kind: .agent(adapter: agent.adapter, connectionID: agent.connectionID), name: agent.displayName,
                mark: AgentMarkKind.of(adapter: agent.adapter),
                status: canRunAgents ? statusWord(state: agent.state, access: agent.access) : cannotRunInThisBuild, deviceName: device
            ))
        }
        return rows
    }

    /// 이 대상(대화가 이미 가진 것 · 새 대화가 고른 것)에 해당하는 행. 연결 없이 고른 에이전트는 그 adapter의 첫 행. 목록에 없으면 nil
    public static func index(of pick: AssistantTargetPick, in options: [AssistantTargetOption]) -> Int? {
        switch pick {
        case .taskforce:
            return options.firstIndex { $0.kind == .taskforce }
        case .agent(let adapter, let connectionID):
            if let connectionID {
                // 서버 대화는 연결 id만 안다 (adapter는 빈 글자): 연결로 행을 찾는다
                return options.firstIndex { $0.connectionID == connectionID && $0.isAgent }
            }
            return options.firstIndex {
                if case .agent(let rowAdapter, _) = $0.kind { return rowAdapter == adapter }
                return false
            }
        }
    }
}
