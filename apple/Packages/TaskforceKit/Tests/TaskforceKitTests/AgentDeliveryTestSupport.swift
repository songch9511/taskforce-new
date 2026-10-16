import Foundation
@testable import TaskforceKit

/// 가짜 `AgentConversationGateway` (OA D4a-1): deliver · referent · 대화 Stop · 전달 읽기를 스크립트로 정하고 부른 것을 남긴다. 붙잡기는 `Latch`로 한다
final class FakeAgentConversationGateway: AgentConversationGateway, @unchecked Sendable {
    struct Failure: Error {}

    struct DeliverCall: Equatable { let conversation: UUID; let messageIDs: [UUID]? }
    struct ReferentCall: Equatable { let conversation: UUID; let message: UUID; let action: UUID }
    struct ReadCall: Equatable { let conversation: UUID; let sinceSeq: Int? }

    private let lock = NSLock()
    private var _delivers: [DeliverCall] = []
    private var _referents: [ReferentCall] = []
    private var _stops: [UUID] = []
    private var _reads: [ReadCall] = []

    var delivers: [DeliverCall] { lock.withLock { _delivers } }
    var referents: [ReferentCall] { lock.withLock { _referents } }
    var stops: [UUID] { lock.withLock { _stops } }
    var reads: [ReadCall] { lock.withLock { _reads } }

    nonisolated(unsafe) var deliverHandler: @Sendable (UUID, [UUID]?) async throws -> AgentDeliverResponse = { _, _ in throw Failure() }
    nonisolated(unsafe) var referentHandler: @Sendable (UUID, UUID, UUID) async throws -> AgentPostedMessage = { _, _, _ in throw Failure() }
    nonisolated(unsafe) var stopHandler: @Sendable (UUID) async throws -> AgentStopResponse = { _ in throw Failure() }
    /// 기본: 아무 전달도 없다 (읽기가 빈 목록을 돌려준다)
    nonisolated(unsafe) var deliveriesHandler: @Sendable (UUID, Int?) async throws -> ConversationDeliveryResponse = { _, _ in ConversationDeliveryResponse(messages: []) }

    func deliver(conversationID: UUID, messageIDs: [UUID]?) async throws -> AgentDeliverResponse {
        lock.withLock { _delivers.append(DeliverCall(conversation: conversationID, messageIDs: messageIDs)) }
        return try await deliverHandler(conversationID, messageIDs)
    }

    func setReferent(conversationID: UUID, messageID: UUID, actionID: UUID) async throws -> AgentPostedMessage {
        lock.withLock { _referents.append(ReferentCall(conversation: conversationID, message: messageID, action: actionID)) }
        return try await referentHandler(conversationID, messageID, actionID)
    }

    func stopConversation(id: UUID) async throws -> AgentStopResponse {
        lock.withLock { _stops.append(id) }
        return try await stopHandler(id)
    }

    func deliveries(conversationID: UUID, sinceSeq: Int?) async throws -> ConversationDeliveryResponse {
        lock.withLock { _reads.append(ReadCall(conversation: conversationID, sinceSeq: sinceSeq)) }
        return try await deliveriesHandler(conversationID, sinceSeq)
    }
}

/// 손으로 돌리는 잠들기: 스케줄한 지연을 `fire()`로 부른다 (취소된 잠들기는 대기열에서 빠진다)
final class ManualTicker: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [(id: UUID, delay: TimeInterval, continuation: CheckedContinuation<Void, Never>)] = []

    var pendingDelays: [TimeInterval] { lock.withLock { waiters.map(\.delay) } }

    func sleep(_ delay: TimeInterval) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.withLock { waiters.append((id, delay, continuation)) }
                if Task.isCancelled { cancel(id) }
            }
        } onCancel: {
            cancel(id)
        }
    }

    private func cancel(_ id: UUID) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
            return waiters.remove(at: index).continuation
        }
        continuation?.resume()
    }

    /// 가장 먼저 기다린 것을 깨운다
    func fire() {
        let next = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard !waiters.isEmpty else { return nil }
            return waiters.removeFirst().continuation
        }
        next?.resume()
    }
}

/// 조건이 설 때까지 기다린다 (양보 횟수로 짐작하지 않는다). 안전망 3초
@MainActor
func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// 붙잡힌 요청에 **둘째가 들어오지 않는 것**을 본다 (같은 요청을 겹쳐 보내는 실수는 `Latch`에 둘째가 도착한다).
/// 둘째가 오면 false라 시험이 멈추지 않고 실패한다 (막이 없을 때 둘째가 영영 풀리지 않는 래치를 기다리다 멈추지 않는다)
func noSecondRequest(_ latch: Latch, window: Duration = .milliseconds(150)) async -> Bool {
    !(await latch.waitForArrivals(2, timeout: window))
}

/// 잠시 아무 일도 일어나지 않는 것을 본다 (일이 일어나지 않았음을 말할 때만: 일어나야 하는 일은 `eventually`로 기다린다)
func quiet(_ milliseconds: Int = 60) async {
    try? await Task.sleep(for: .milliseconds(milliseconds))
}

enum AgentFx {
    static let connection = UUID(uuidString: "a3333333-3333-4333-8333-333333333333")!
    static let session = UUID(uuidString: "a4444444-4444-4444-8444-444444444444")!

    /// 서버에 있는 에이전트 대화 행
    static func conversation(_ n: Int = 1, session: UUID? = nil, last: TimeInterval? = 10) -> ChatConversation {
        ChatConversation(
            id: ChatContractFixtures.id(n, prefix: "bcb50000"), createdAt: .test(), lastMessageAt: last.map { .test($0) },
            target: ChatConversationTarget(kind: .agent, agentConnectionID: connection, agentSessionID: session)
        )
    }

    /// 사용자 메시지 (서버가 저장한 것). `n`은 메시지 id를 정한다
    static func user(_ n: Int, in conversation: UUID, seq: Int, cmid: UUID? = UUID(), text: String = "Fix the pricing table") -> ChatMessage {
        Chats.message(n, in: conversation, seq: seq, role: .user, text: text, cmid: cmid, at: Double(seq))
    }

    static func entry(_ message: ChatMessage, _ delivery: AgentDelivery) -> ConversationDeliveryResponse.Entry {
        ConversationDeliveryResponse.Entry(messageID: message.id, seq: message.seq, delivery: delivery)
    }
}

/// 가짜 `AgentSessionRequests`: 알약 · 세션 Stop 요청을 스크립트로 정하고 부른 것을 남긴다
final class FakeAgentSessionRequests: AgentSessionRequests, @unchecked Sendable {
    struct Failure: Error {}

    private let lock = NSLock()
    private var _calls: [String] = []

    var calls: [String] { lock.withLock { _calls } }

    nonisolated(unsafe) var openHandler: @Sendable (UUID) async throws -> AgentSessionResponse = { _ in throw Failure() }
    nonisolated(unsafe) var resumeHandler: @Sendable (UUID) async throws -> AgentResumeResponse = { _ in throw Failure() }
    nonisolated(unsafe) var stopHandler: @Sendable (UUID) async throws -> AgentStopResponse = { _ in throw Failure() }

    func openExternal(sessionID: UUID) async throws -> AgentSessionResponse {
        lock.withLock { _calls.append("open:\(sessionID.uuidString)") }
        return try await openHandler(sessionID)
    }

    func resumeHere(sessionID: UUID) async throws -> AgentResumeResponse {
        lock.withLock { _calls.append("resume:\(sessionID.uuidString)") }
        return try await resumeHandler(sessionID)
    }

    func stopSession(id: UUID) async throws -> AgentStopResponse {
        lock.withLock { _calls.append("stop:\(id.uuidString)") }
        return try await stopHandler(id)
    }

    /// 서버 세션 한 줄 (응답 만들기)
    static func row(_ status: AgentSessionStatus, id: UUID = SessionFx.id(1)) -> AgentSessionRow {
        AgentSessionRow(id: id, connectionID: SessionFx.claudeConnection, displayName: "Pricing", status: status, lastTurnSeq: 1, updatedAt: SessionFx.t0)
    }
}
