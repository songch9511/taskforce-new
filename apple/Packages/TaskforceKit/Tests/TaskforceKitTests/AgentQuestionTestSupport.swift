import Foundation
@testable import TaskforceKit

/// 질문 저장소 시험의 도우미 (OA D4b-m-1): 세션 항목 · 질문 행 만들기와 가짜 서버 · 가짜 비밀값 내보내기.
enum QFx {
    typealias F = AgentQuestionFixtures

    static let conversationID = UUID(uuidString: "a1111111-1111-4111-8111-111111111111")!
    static let secondSession = UUID(uuidString: "a4444444-4444-4444-8444-444444444445")!
    static let secondTask = UUID(uuidString: "a5555555-5555-4555-8555-555555555556")!

    /// 세션 패널 · 창이 아는 세션 하나 (질문을 기다리는 마지막 턴). `bridge`는 그 세션 연결의 Mac
    static func item(
        session: UUID = F.sessionID, conversation: UUID? = conversationID, bridge: UUID? = F.bridgeID, state: AgentTaskState? = .awaitingAnswer,
        status: AgentSessionStatus = .bound, agentName: String = "Claude Code"
    ) -> AgentSessionItem {
        AgentSessionItem(
            id: session, name: "Pricing copy", agent: .claudeCode, agentName: agentName, connectionID: UUID(), status: status,
            ring: state == .awaitingAnswer ? .needsYou : .idle, line: "", createdAt: .test(0), updatedAt: .test(1), issueIDs: [], currentIssueID: nil,
            conversationID: conversation, hasOpenTask: state?.isOpenForTests ?? false, pill: nil, connectionBridgeID: bridge, lastTaskState: state, cancelRequested: false, turnSeq: 1
        )
    }

    /// 읽은 `agent_tasks` 행
    static func record(_ pending: String, task: UUID = F.taskID, session: UUID = F.sessionID) -> AgentQuestionRecord {
        try! TaskforceJSON.decoder().decode(AgentQuestionRecord.self, from: Data(F.row(pending: pending, task: task, session: session).utf8))
    }

    /// 한 세션의 단일 선택 질문 (요청 id로 다른 질문을 만든다)
    static func single(request: String = F.requestID, task: UUID = F.taskID) -> String {
        F.pending(prompts: [F.prompt()], request: request, task: task)
    }
}

extension AgentTaskState {
    fileprivate var isOpenForTests: Bool { self == .awaitingAnswer || self == .running || self == .dispatched || self == .accepted }
}

/// 가짜 `AgentQuestionGateway`: 읽기 응답과 답 응답을 스크립트로 정하고 부른 것을 남긴다
final class FakeAgentQuestionGateway: AgentQuestionGateway, @unchecked Sendable {
    struct Failure: Error {}

    struct Answer: Equatable {
        let taskID: UUID
        let request: AgentAnswerRequest
    }

    private let lock = NSLock()
    private var _records: [AgentQuestionRecord] = []
    private var _reads: [Set<UUID>] = []
    private var _answers: [Answer] = []
    private var _nameReads: [UUID] = []
    private var _readFailure: Error?
    private var _names: [UUID: String] = [:]
    private var _readHold: Latch?
    private var _answerHold: Latch?
    private var _answerHandler: @Sendable (Int) async throws -> AgentAnswerResponse = { _ in
        AgentAnswerResponse(status: .answered, stepID: UUID(uuidString: "f0000000-0000-f000-f000-000000000001")!)
    }

    /// 서버가 지금 쥔 열린 질문들 (읽기가 요청한 세션만 걸러 돌려준다)
    var records: [AgentQuestionRecord] {
        get { lock.withLock { _records } }
        set { lock.withLock { _records = newValue } }
    }
    var reads: [Set<UUID>] { lock.withLock { _reads } }
    var answers: [Answer] { lock.withLock { _answers } }
    var nameReads: [UUID] { lock.withLock { _nameReads } }
    var readFailure: Error? {
        get { lock.withLock { _readFailure } }
        set { lock.withLock { _readFailure = newValue } }
    }
    var names: [UUID: String] {
        get { lock.withLock { _names } }
        set { lock.withLock { _names = newValue } }
    }
    /// 붙잡으면 읽기가 열릴 때까지 멈춘다 (한 번만 쓰인다)
    func holdNextRead(_ latch: Latch?) { lock.withLock { _readHold = latch } }
    func holdNextAnswer(_ latch: Latch?) { lock.withLock { _answerHold = latch } }
    /// n번째(1부터) 답 요청의 응답을 정한다
    func onAnswer(_ handler: @escaping @Sendable (Int) async throws -> AgentAnswerResponse) { lock.withLock { _answerHandler = handler } }

    func openQuestions(sessionIDs: Set<UUID>) async throws -> [AgentQuestionRecord] {
        let (served, failure, hold) = lock.withLock { () -> ([AgentQuestionRecord], Error?, Latch?) in
            _reads.append(sessionIDs)
            let hold = _readHold
            _readHold = nil
            return (_records.filter { sessionIDs.contains($0.sessionID) }, _readFailure, hold)
        }
        if let hold { await hold.wait() }
        if let failure { throw failure }
        return served
    }

    func answerQuestion(taskID: UUID, request: AgentAnswerRequest) async throws -> AgentAnswerResponse {
        let (number, handler, hold) = lock.withLock { () -> (Int, @Sendable (Int) async throws -> AgentAnswerResponse, Latch?) in
            _answers.append(Answer(taskID: taskID, request: request))
            let hold = _answerHold
            _answerHold = nil
            return (_answers.count, _answerHandler, hold)
        }
        if let hold { await hold.wait() }
        return try await handler(number)
    }

    func deviceName(bridgeID: UUID) async throws -> String? {
        lock.withLock {
            _nameReads.append(bridgeID)
            return _names[bridgeID]
        }
    }
}

/// 가짜 비밀값 내보내기 (D4b-m-1은 실제 경로가 없다): 받은 것을 남기고 정한 결과를 돌려준다
final class FakeSecretSubmitter: LocalSecretAnswerSubmitting, @unchecked Sendable {
    private let lock = NSLock()
    private var _submitted: [LocalSecretAnswer] = []
    private var _outcome: LocalSecretOutcome = .sent
    private var _hold: Latch?

    var submitted: [LocalSecretAnswer] { lock.withLock { _submitted } }
    var outcome: LocalSecretOutcome {
        get { lock.withLock { _outcome } }
        set { lock.withLock { _outcome = newValue } }
    }
    func holdNext(_ latch: Latch?) { lock.withLock { _hold = latch } }

    func submit(_ answer: LocalSecretAnswer) async -> LocalSecretOutcome {
        let (outcome, hold) = lock.withLock { () -> (LocalSecretOutcome, Latch?) in
            _submitted.append(answer)
            let hold = _hold
            _hold = nil
            return (_outcome, hold)
        }
        if let hold { await hold.wait() }
        return outcome
    }
}
