import Foundation
import Observation

/// 대상 목록 저장소 (OA U1): `GET /api/v2/assistant/targets`를 읽어 대상 메뉴의 행으로 만든다.
/// - 읽기 실패는 마지막으로 읽은 목록을 지키고(`failed`), 기능이 꺼져 있으면(404 gate) Taskforce뿐이다(`unavailable`). 처음 읽기 전에도 Taskforce뿐이다
/// - 겹친 읽기는 한 번만 부른다. 계정이 떠나면 목록을 비우고, 그 사이 시작한 읽기의 늦은 답은 쓰지 않는다
/// - 상태는 서버가 판정한 대로 단어로만 옮긴다 (`AssistantTargetRules`). "Can't run agents in this build"는 클라이언트 조건(`canRunAgents`)이다
@MainActor
@Observable
public final class AssistantTargetsStore {
    public enum Load: Equatable, Sendable {
        case idle, loading, loaded
        /// 대화 API 또는 에이전트가 꺼져 있다 (또는 이 런타임에 게이트웨이가 없다): Taskforce뿐
        case unavailable
        /// 읽지 못했다 (마지막 목록은 그대로)
        case failed
    }

    public private(set) var targets: [AssistantTarget] = []
    public private(set) var load: Load = .idle
    /// 같은 adapter의 연결이 둘일 때 행을 가르는 기기 이름. 서버가 아직 주지 않아 지금은 보통 비어 있다
    @ObservationIgnored public var deviceName: (UUID) -> String? = { _ in nil }

    /// 대상 목록을 읽는 곳. 없으면 Taskforce뿐이다 (견본이 가짜를 끼운다)
    @ObservationIgnored public var gateway: (any AssistantGateway)?
    @ObservationIgnored private let scope: AccountScope
    /// 이 빌드가 에이전트를 띄울 수 있는가 (샌드박스가 아니다). 견본이 바꿔 본다
    @ObservationIgnored public var canRunAgents: () -> Bool
    @ObservationIgnored private let flight = SingleFlight()

    public init(gateway: (any AssistantGateway)?, scope: AccountScope, canRunAgents: @escaping () -> Bool) {
        self.gateway = gateway
        self.scope = scope
        self.canRunAgents = canRunAgents
        scope.onLeft { [weak self] in self?.reset() }
    }

    public func reset() {
        flight.reset()
        targets = []
        load = .idle
    }

    /// 대상 메뉴의 행들 (Taskforce가 늘 처음)
    public var options: [AssistantTargetOption] {
        AssistantTargetRules.options(from: targets, canRunAgents: canRunAgents(), deviceName: deviceName)
    }

    /// 대상 메뉴가 보일 읽기 상태. 실패는 마지막 목록이 남아 있어도 말한다. 기능이 꺼졌거나 이 런타임에 게이트웨이가 없으면 Taskforce뿐이고 기다릴 것이 없다
    public var menuStatus: AssistantTargetMenuStatus {
        guard gateway != nil else { return .ready }
        switch load {
        case .failed: return .failed
        case .idle, .loading: return targets.contains { if case .agent = $0 { true } else { false } } ? .ready : .loading
        case .loaded, .unavailable: return .ready
        }
    }

    public func option(for pick: AssistantTargetPick) -> AssistantTargetOption? {
        let rows = options
        return AssistantTargetRules.index(of: pick, in: rows).map { rows[$0] }
    }

    /// 연결 id가 가리키는 adapter (대상 목록에 없으면 nil)
    public func adapter(forConnection connectionID: UUID) -> String? {
        for case .agent(let agent) in targets where agent.connectionID == connectionID { return agent.adapter }
        return nil
    }

    /// 연결 id의 마크. 목록에 없는 연결(꺼진 adapter · 지운 연결)은 점선 사각형이다
    public func mark(forConnection connectionID: UUID) -> AgentMarkKind {
        adapter(forConnection: connectionID).map(AgentMarkKind.of(adapter:)) ?? .placeholder
    }

    public func refresh() async {
        guard let gateway else {
            load = .unavailable
            return
        }
        await flight.run { [self] in
            guard let token = scope.token else { return }
            if targets.isEmpty { load = .loading }
            do {
                let rows = try await gateway.targets()
                guard scope.isCurrent(token) else { return }
                targets = rows
                load = .loaded
            } catch {
                guard scope.isCurrent(token) else { return }
                if let api = error as? APIError, api.isFeatureOff {
                    targets = []
                    load = .unavailable
                } else if !(error is CancellationError) {
                    load = .failed
                }
            }
        }
    }
}
