#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// OA D4b-m-2 시험 도우미: 비밀값 질문이 열린 런타임을 세우고, 실제 `submitLocalSecret` 길로 값을 내보낸다 (가짜 서버 · 수동 시계).
enum SecretFixture {
    static let requestID = "req-secret"
    static let itemID = "q"

    static func canary() -> String { "TF_CANARY_D4BM2_\(UUID().uuidString)" }

    static func question(secret: Bool = true, request: String = requestID) -> AgentQuestion {
        AgentQuestion(
            providerRequestID: request, kind: .input, structured: true, text: "API token?",
            items: [AgentQuestionItem(id: itemID, header: "Token", text: "token", options: [], secret: secret)]
        )
    }

    /// 등록 → 질문을 내는 턴 → 서버가 `awaiting_answer`로 안다
    /// - endsAfterAsking: 질문을 내고 프로세스가 끝난다 (Claude Code처럼: 질문은 프로세스가 끝난 뒤에 나가고 task는 프로세스 없이 `awaiting_answer`로 기다린다)
    static func open(_ h: BridgeHarness, secret: Bool = true, endsAfterAsking: Bool = false) async throws -> FakeBridgeServer.Created {
        if endsAfterAsking {
            h.agent.setScript(.init([.sessionBound(external: "fake-session-1", workspace: "workspace-fake"), .accepted, .question(question(secret: secret)), .end(AgentExit(code: 0))]))
        } else {
            h.agent.setScript(.asking(question(secret: secret)))
        }
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        await h.settle(timeout: 30) { (try? await h.ledger.task(created.taskID))?.openRequestID == requestID && h.server.taskState(created.taskID) == "awaiting_answer" }
        if (try? await h.ledger.task(created.taskID))?.openRequestID != requestID || h.server.taskState(created.taskID) != "awaiting_answer" {
            Issue.record("질문이 열리지 않았다 (부하로 늦었을 수 있다): 원장 \(String(describing: (try? await h.ledger.task(created.taskID))?.openRequestID)) 서버 \(String(describing: h.server.taskState(created.taskID)))")
        }
        return created
    }

    static func key(_ created: FakeBridgeServer.Created, request: String = requestID) -> LocalSecretKey {
        LocalSecretKey(taskID: created.taskID, requestID: request)
    }

    static func answer(_ created: FakeBridgeServer.Created, request: String = requestID, value: String) -> LocalSecretAnswer {
        LocalSecretAnswer(
            key: AgentQuestionKey(taskID: UUID(uuidString: created.taskID)!, requestID: request), answers: [itemID: .secret(SecretBox(value))]
        )
    }

    /// 실제 길로 내보낸다. 재시도 사이의 `pause`는 수동 시계가 돌려 준다 (잠든 것이 있을 때만 1초씩)
    static func submit(
        _ h: BridgeHarness, _ answer: LocalSecretAnswer, matches: @escaping @Sendable () async -> Bool = { true }
    ) async -> LocalSecretOutcome {
        let done = Locked<LocalSecretOutcome?>(nil)
        let task = Task {
            let outcome = await h.runtime.submitLocalSecret(answer, accountStillMatches: matches)
            done.set(outcome)
        }
        let deadline = Date().addingTimeInterval(30)
        while done.get() == nil, Date() < deadline {
            if h.clock.sleeperCount > 0 {
                await h.clock.advance(by: 1)
            } else {
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        await task.value
        return done.get() ?? .unavailable
    }

    /// 첫 제출을 내보내고 그 답 명령의 lease 응답을 잃는다 (서버는 lease했지만 이 Mac은 모른다). 답 명령 id를 돌려준다
    static func submitAndLoseTheLease(_ h: BridgeHarness, created: FakeBridgeServer.Created) async throws -> String {
        #expect(await submit(h, answer(created, value: canary())) == .sent)
        let commandID = try #require(h.server.commandIDs(taskID: created.taskID, kind: "answer").first)
        h.server.dropResponseOnce(route: "ack")
        await deliver(h)
        return commandID
    }

    /// lease가 만료돼 결과 확인 목록에 나오고 `not_received`로 정산된다. 서버는 질문을 되살리고(`restoresQuestionOnNotReceived`) 로컬 task는 failed로 남는다
    static func settleAsNotReceived(_ h: BridgeHarness, commandID: String) async throws {
        h.server.markLeasedUnknown(commandID)
        h.clock.jump(by: 6)
        await h.runtime.tick()
        #expect(await h.eventually(timeout: 5) { (try? await h.ledger.command(commandID))?.ackFinalAt != nil }, "정산이 끝났다")
        let command = try #require(try await h.ledger.command(commandID))
        #expect(command.state == .settled && command.ackResult == "not_received")
    }

    /// 답 명령이 lease되어 전달되게 한다 (서버가 만든 `answered_locally` 명령)
    static func deliver(_ h: BridgeHarness) async {
        h.clock.jump(by: 6)
        await h.runtime.tick()
    }
}

/// 다음 계정 확인 몇 번의 결과를 정한다 (시작 · put 앞 · POST 앞 순서)
final class AccountChecks: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Bool]
    private(set) var calls = 0

    init(_ answers: [Bool]) {
        self.answers = answers
    }

    func next() -> Bool {
        lock.withLock {
            calls += 1
            return answers.isEmpty ? true : answers.removeFirst()
        }
    }

    var closure: @Sendable () async -> Bool { { self.next() } }
}
#endif
