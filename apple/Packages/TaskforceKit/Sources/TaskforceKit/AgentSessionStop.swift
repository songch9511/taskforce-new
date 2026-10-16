import Foundation
import Observation

// Stop (OA D4a-13 · 14, 계약 v3 5장). 서버 값 → 화면은 순수 규칙 한 곳(`AgentStopRules`)이다:
// | 열린 task(dispatched · accepted · running · awaiting_answer) | 보내기 원이 Stop("Stop new steps") |
// | Stop 응답에 `requested_only`가 있음 · 다시 읽은 `cancel_requested_at` | Stop 그대로 + "Stop requested · not confirmed" |
// | 모두 `confirmed` · 열린 task 0 | 보내기, 말 없음 |
// | `processes: may_continue` | 보내기 + "Stopped · commands may still be running"(승인 전 후보), 다음 턴이 시작될 때까지 |
// | `idle` · task 없음 | 보내기 (열린 작업이 아니다) |
// 앱은 서버가 확인했는지를 판정하지 않는다: 응답과 다시 읽은 값을 말로 옮길 뿐이다.

/// Stop 응답이 남긴 것 (세션 하나, 그 턴 번호). `requested_only`는 아직 확인 전이고 `may_continue`는 실행 중 명령이 남을 수 있다 (Codex)
public struct AgentStopOutcome: Equatable, Sendable {
    public let requestedOnly: Bool
    public let mayContinue: Bool
    public let turnSeq: Int

    public init(requestedOnly: Bool, mayContinue: Bool, turnSeq: Int) {
        self.requestedOnly = requestedOnly
        self.mayContinue = mayContinue
        self.turnSeq = turnSeq
    }

    /// 응답에서: `requested_only`가 하나라도 있거나 `may_continue`가 하나라도 있을 때만 남긴다 (모두 confirmed · 모르는 값뿐이면 nil)
    public init?(response: AgentStopResponse, turnSeq: Int) {
        let requested = response.tasks.contains { $0.cancel == .requestedOnly }
        let mayContinue = response.tasks.contains { $0.processes == .mayContinue }
        guard requested || mayContinue else { return nil }
        self.init(requestedOnly: requested, mayContinue: mayContinue, turnSeq: turnSeq)
    }
}

public enum AgentStopRules {
    public enum Line: Equatable, Sendable {
        case requested
        case mayContinue

        /// 보일 글. "Stop requested · not confirmed"는 DS의 말이고 "Stopped · commands may still be running"은 승인 전 후보다 (없으면 nil)
        public func text(copy: AgentUnapprovedCopy = AgentNewCopy.active) -> String? {
            switch self {
            case .requested: AgentCopy.stopRequested
            case .mayContinue: copy.stoppedMayContinue
            }
        }
    }

    public struct Presentation: Equatable, Sendable {
        public let showsStop: Bool
        public let line: Line?

        public init(showsStop: Bool, line: Line?) {
            self.showsStop = showsStop
            self.line = line
        }
    }

    /// 열린 task 상태 넷 (연결이 끊긴 task는 Stop을 보이지 않는다: 멈출 프로세스를 이 서버가 모른다)
    static func isStoppable(_ state: AgentTaskState?) -> Bool {
        switch state {
        case .dispatched?, .accepted?, .running?, .awaitingAnswer?: true
        default: false
        }
    }

    public static func presentation(session: AgentSessionItem?, outcome: AgentStopOutcome?) -> Presentation {
        guard let session, !session.isClosed else { return Presentation(showsStop: false, line: nil) }
        if isStoppable(session.lastTaskState) {
            let requested = session.cancelRequested || (outcome.map { $0.requestedOnly && $0.turnSeq == session.turnSeq } ?? false)
            return Presentation(showsStop: true, line: requested ? .requested : nil)
        }
        if let outcome, outcome.mayContinue, session.turnSeq <= outcome.turnSeq { return Presentation(showsStop: false, line: .mayContinue) }
        return Presentation(showsStop: false, line: nil)
    }
}

/// Stop 요청과 그 결과 (Assistant 창 · 세션 패널 둘 다 쓴다). 세션마다 요청은 하나: 진행 중이거나 이미 요청했으면 다시 눌러도 보내지 않는다.
/// 응답은 부른 계정이 지금도 그대로일 때만 반영한다. 결과는 메모리뿐이다
@MainActor
@Observable
public final class AgentStopStore {
    /// 세션 id → Stop 응답이 남긴 것
    public private(set) var outcomes: [UUID: AgentStopOutcome] = [:]
    /// 요청이 끝났다(성공 · 실패): 부르는 쪽이 세션을 다시 읽는다 (서버가 사실이다)
    @ObservationIgnored public var onChanged: () -> Void = {}

    @ObservationIgnored private let conversations: (any AgentConversationGateway)?
    @ObservationIgnored private let sessions: (any AgentSessionRequests)?
    @ObservationIgnored private let scope: AccountScope
    @ObservationIgnored private var inFlight: Set<UUID> = []

    public init(conversations: (any AgentConversationGateway)?, sessions: (any AgentSessionRequests)?, scope: AccountScope) {
        self.conversations = conversations
        self.sessions = sessions
        self.scope = scope
        scope.onLeft { [weak self] in self?.reset() }
    }

    public func reset() {
        outcomes = [:]
        inFlight = []
    }

    public func presentation(session: AgentSessionItem?) -> AgentStopRules.Presentation {
        AgentStopRules.presentation(session: session, outcome: session.flatMap { outcomes[$0.id] })
    }

    /// Assistant 창: `POST /api/v2/conversations/{id}/stop`
    public func stopConversation(_ conversationID: UUID, session: AgentSessionItem?) async {
        guard let conversations else { return }
        await stop(session: session) { try await conversations.stopConversation(id: conversationID) }
    }

    /// 세션 패널: `POST /api/v2/agent-sessions/{id}/stop`
    public func stopSession(_ session: AgentSessionItem) async {
        guard let sessions else { return }
        await stop(session: session) { try await sessions.stopSession(id: session.id) }
    }

    private func stop(session: AgentSessionItem?, request: () async throws -> AgentStopResponse) async {
        guard let session, let token = scope.token else { return }
        let shown = presentation(session: session)
        // 열린 작업이 있을 때만, 진행 중이 아닐 때만, 이미 요청하지 않았을 때만 (눌러도 한 번)
        guard shown.showsStop, shown.line != .requested, inFlight.insert(session.id).inserted else { return }
        defer { inFlight.remove(session.id) }
        do {
            let response = try await request()
            guard scope.isCurrent(token) else { return }
            outcomes[session.id] = AgentStopOutcome(response: response, turnSeq: session.turnSeq)
        } catch {
            guard scope.isCurrent(token) else { return }
        }
        onChanged()
    }
}
