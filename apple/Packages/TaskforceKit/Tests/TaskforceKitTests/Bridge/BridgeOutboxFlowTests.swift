#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// outbox 흐름 · 글 최소 사본 (OA D2b 계약 4.1 K3 · K4): 적고 보냄 · retry · 400 나누기 · 401/403/404 유지 · 자르기 · 비밀값 디스크 0
struct BridgeOutboxFlowTests {
    // MARK: 응답 분류

    @Test func retryEventsStayAndBlockLaterEventsOfTheSameSessionUntilTheNextAttempt() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        try await h.seedEvents(count: 4)
        let rows = try await h.ledger.outboxRows()
        h.server.retryEventOnce(rows[1].eventID)
        await h.runtime.flushOutbox()
        // 첫 사건은 지워지고, 둘째와 그 뒤 같은 세션 사건은 남는다
        let left = try await h.ledger.outboxRows()
        #expect(left.map(\.eventID) == rows.dropFirst().map(\.eventID))
        #expect(left.allSatisfy { $0.attempts >= 1 || $0.eventID == rows[3].eventID })
        let afterFirst = h.server.requests("events").count
        await h.runtime.flushOutbox()
        #expect(h.server.requests("events").count == afterFirst, "다음 시도 시각 전에는 같은 세션의 뒤 사건도 보내지 않는다")
        h.clock.jump(by: 5)
        await h.runtime.flushOutbox()
        #expect(try await h.ledger.outboxRows().isEmpty)
        #expect(h.server.eventResults.map(\.eventID) == rows.map(\.eventID), "순서가 유지됐다")
    }

    @Test func aRejectedEventBecomesADeadLetterAndIsNeverSentAgain() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        // 서버가 모양을 거절할 사건 (필수 키가 없다)
        let task = BridgeTest.task("7a5c0001-0000-4000-8000-0000000000d1")
        try await h.ledger.saveTask(task)
        let row = try await h.ledger.appendEvent(taskID: task.agentTaskID, numbering: .taskSequence, build: { _, id in
            BuiltEvent(type: "progress", json: "{\"event_id\":\"\(id)\"}", observedAt: BridgeTest.t0)
        }, update: { _ in })
        await h.runtime.flushOutbox()
        #expect(try await h.ledger.outboxRows().isEmpty)
        let dead = try await h.ledger.outboxRows(includeDead: true)
        #expect(dead.map(\.eventID) == [row.eventID] && dead.first?.deadReason == "rejected")
        let sends = h.server.requests("events").count
        await h.runtime.flushOutbox()
        #expect(h.server.requests("events").count == sends)
    }

    @Test func aWholeBatch400IsSplitInHalvesAndASingleBadEventIsDroppedAsADeadLetter() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        try await h.seedEvents(count: 4)
        h.server.failNext("events", .init(status: 400))
        await h.runtime.flushOutbox()
        let events = h.server.requests("events")
        #expect(events.count == 3, "전체 400 → 앞 반 · 뒤 반")
        #expect(events.map { ($0.json["events"] as? [Any])?.count } == [4, 2, 2])
        #expect(try await h.ledger.outboxRows().isEmpty)
        // 한 사건만 남아도 400이면 그 사건은 dead-letter
        try await h.seedEvents(count: 1)
        h.server.failNext("events", .init(status: 400))
        await h.runtime.flushOutbox()
        #expect(try await h.ledger.outboxRows().isEmpty)
        #expect(try await h.ledger.outboxRows(includeDead: true).map(\.deadReason) == ["bad_request"])
    }

    @Test func serverErrorsBackOffAndDoNotDelete() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        try await h.seedEvents(count: 2)
        h.server.failNext("events", .init(status: 503))
        await h.runtime.flushOutbox()
        let first = try await h.ledger.outboxRows()
        #expect(first.count == 2 && first.allSatisfy { $0.attempts == 1 && $0.nextAttemptAt > h.clock.now })
        let sends = h.server.requests("events").count
        await h.runtime.flushOutbox()
        #expect(h.server.requests("events").count == sends, "backoff 안에는 다시 보내지 않는다")
        h.clock.jump(by: 5)
        await h.runtime.flushOutbox()
        #expect(try await h.ledger.outboxRows().isEmpty)
    }

    @Test func authFailuresNeverDeleteTheOutbox() async throws {
        // 401(회복 뒤에도) · 403 · 404: 지우지 않는다 (D2a 6.4)
        let cases: [(String, Int, Int)] = [("401", 401, 5), ("403", 403, 1), ("404", 404, 1)]
        for (name, status, count) in cases {
            let h = try BridgeHarness()
            await h.registerFirst()
            try await h.seedEvents(count: 3)
            h.server.failNext("events", .init(status: status, count: count))
            await h.runtime.flushOutbox()
            #expect(try await h.ledger.outboxRows().count == 3, "\(name)")
        }
    }

    // MARK: 글 자르기 (런타임 몫)

    @Test func aFortyKilobyteAgentMessageIsCutAtTheLimitOnTheWireAndTheFullTextStaysForViewFull() async throws {
        let h = try BridgeHarness()
        let long = String(repeating: "한", count: 14_000) // 42,000 bytes
        h.agent.setScript(FakeAgentProcess.Script([.accepted, .message(long), .turnCompleted, .end(AgentExit(code: 0))]))
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        await h.settle { h.server.taskState(created.taskID) == "idle" }
        let sent = h.server.requests("events").flatMap { ($0.json["events"] as? [[String: Any]]) ?? [] }
        let message = try #require(sent.first { $0["type"] as? String == "message" })
        let text = try #require(message["text"] as? String)
        #expect(text.utf8.count <= 32_768 && text.utf8.count > 32_000 && long.hasPrefix(text))
        let full = try await h.ledger.fullText(eventID: try #require(message["event_id"] as? String))
        #expect(full == long, "잘린 사건의 전체 글은 원장에")
    }

    @Test func aQuestionWithAnOverlongLabelIsCutAndTheAnswerGoesBackWithTheOriginalLabel() async throws {
        let h = try BridgeHarness()
        let longLabel = String(repeating: "L", count: 600)
        let question = AgentQuestion(
            providerRequestID: "req-1", kind: .input, structured: true, text: "Pick one",
            items: [AgentQuestionItem(id: "q1", header: "h", text: "t", options: [AgentQuestionOption(label: longLabel, description: "d")])]
        )
        h.agent.setScript(.asking(question))
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        await h.settle { (try? await h.ledger.task(created.taskID))?.openRequestID == "req-1" }
        await h.settle { h.server.taskState(created.taskID) == "awaiting_answer" }
        let sentLabel = String(longLabel.prefix(500))
        let sent = h.server.requests("events").flatMap { ($0.json["events"] as? [[String: Any]]) ?? [] }.first { $0["type"] as? String == "question" }
        let items = ((sent?["question"] as? [String: Any])?["questions"] as? [[String: Any]]) ?? []
        let options = (items.first?["options"] as? [[String: Any]]) ?? []
        #expect(options.first?["label"] as? String == sentLabel)
        // 사용자가 (잘린) 선택지를 골랐다
        h.server.enqueueAnswer(bridgeID: h.bridgeID, taskID: created.taskID, requestID: "req-1", answers: ["q1": sentLabel])
        h.clock.jump(by: 6)
        await h.runtime.tick()
        #expect(await h.eventually { h.agent.deliveredAnswers.count == 1 })
        #expect(h.agent.deliveredAnswers.first?.value.answers == ["q1": .one(longLabel)])
    }

    @Test func aQuestionThatCannotBeRepresentedIsClosedAtTheAgentAndNeverSent() async throws {
        let h = try BridgeHarness()
        let items = (1...5).map { AgentQuestionItem(id: "q\($0)", header: "", text: "t", options: []) }
        h.agent.setScript(.asking(AgentQuestion(providerRequestID: "req-big", kind: .input, structured: true, text: "five", items: items)))
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        #expect(await h.eventually { h.agent.closedRequests.map(\.requestID) == ["req-big"] })
        await h.settle { h.server.taskState(created.taskID) != "dispatched" }
        let sent = h.server.requests("events").flatMap { ($0.json["events"] as? [[String: Any]]) ?? [] }
        #expect(!sent.contains { $0["type"] as? String == "question" })
        #expect(try await h.ledger.task(created.taskID)?.closedRequestIDs.contains("req-big") == true)
    }

    // MARK: 비밀값 · 글 최소 사본

    @Test func aSecretAnswerComesOnlyFromMemoryIsNeverSentToTheServerAndNeverTouchesTheDisk() async throws {
        let h = try BridgeHarness()
        let question = AgentQuestion(
            providerRequestID: "req-secret", kind: .input, structured: false, text: "API token?",
            items: [AgentQuestionItem(id: "q", header: "Token", text: "token", options: [], secret: true)]
        )
        h.agent.setScript(.asking(question))
        await h.registerFirst()
        let created = h.message("SENTINEL-USER-MESSAGE-31c7")
        await h.runtime.tick()
        await h.settle { (try? await h.ledger.task(created.taskID))?.openRequestID == "req-secret" }
        #expect(try await h.ledger.task(created.taskID)?.openRequestSecret == true)
        await h.secrets.put(key: LocalSecretKey(taskID: created.taskID, requestID: "req-secret"), value: AgentAnswerValue(text: "SENTINEL-SECRET-VALUE-9b2e"))
        #expect(await h.runtime.isBusy(), "아직 전달하지 않은 비밀값 답이 있으면 바쁨")
        h.server.enqueueAnswer(bridgeID: h.bridgeID, taskID: created.taskID, requestID: "req-secret", locally: true, structured: false)
        h.clock.jump(by: 6)
        await h.runtime.tick()
        #expect(await h.eventually { h.agent.deliveredAnswers.count == 1 })
        #expect(h.agent.deliveredAnswers.first?.value.text == "SENTINEL-SECRET-VALUE-9b2e")
        await h.settle { h.server.taskState(created.taskID) == "idle" }
        await h.ledger.checkpoint()
        for sentinel in ["SENTINEL-SECRET-VALUE-9b2e", "SENTINEL-USER-MESSAGE-31c7"] {
            #expect(!h.diskContains(sentinel), "디스크(DB · WAL)에 \(sentinel) 0")
            #expect(!h.server.requests.contains { $0.bodyJSON.contains("SENTINEL-SECRET-VALUE-9b2e") }, "서버 요청에 비밀값 0")
        }
        #expect(await h.secrets.hasPending == false)
    }

    @Test func aSecretAnswerThatIsMissingFromMemoryClosesTheRequestAndAcksRequestClosed() async throws {
        let h = try BridgeHarness()
        let question = AgentQuestion(
            providerRequestID: "req-secret", kind: .input, structured: false, text: "Token?",
            items: [AgentQuestionItem(id: "q", header: "", text: "t", options: [], secret: true)]
        )
        h.agent.setScript(.asking(question))
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        await h.settle { (try? await h.ledger.task(created.taskID))?.openRequestID == "req-secret" }
        let answer = try #require(h.server.enqueueAnswer(bridgeID: h.bridgeID, taskID: created.taskID, requestID: "req-secret", locally: true, structured: false))
        h.clock.jump(by: 6)
        await h.runtime.tick()
        let acks = h.server.requests("ack").map(\.json).filter { $0["command_id"] as? String == answer.commandID }
        #expect(acks.map { $0["op"] as? String } == ["lease", "request_closed"])
        #expect(h.agent.deliveredAnswers.isEmpty)
        #expect(h.agent.closedRequests.map(\.requestID) == ["req-secret"])
    }

    @Test func theUserMessageTextIsNeverWrittenToTheLedgerButUnsentAgentTextIs() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(FakeAgentProcess.Script([.accepted, .message("SENTINEL-AGENT-TEXT-55aa"), .turnCompleted, .end(AgentExit(code: 0))]))
        await h.registerFirst()
        h.server.failNext("events", .init(status: 0, transport: true, count: 100))
        let created = h.message("SENTINEL-USER-TEXT-77bb")
        await h.runtime.tick()
        #expect(await h.eventually {
            let state = await h.command(created.commandID)?.state
            return state == .ended || state == .settled
        })
        await h.runtime.flushOutbox()
        await h.ledger.checkpoint()
        #expect(h.diskContains("SENTINEL-AGENT-TEXT-55aa"), "보낼 사건은 outbox에 있다 (감시가 글을 찾을 수 있다는 대조군)")
        #expect(!h.diskContains("SENTINEL-USER-TEXT-77bb"), "사용자 메시지 글은 디스크에 쓰지 않는다")
        #expect(h.agent.startedTurns.first?.text == "SENTINEL-USER-TEXT-77bb")
    }

    @Test func nothingSecretOrPersonalEntersTheLogs() async throws {
        let h = try BridgeHarness(workspace: "/Users/someone/private/workspace-SENTINEL")
        let question = AgentQuestion(
            providerRequestID: "req-secret", kind: .input, structured: false, text: "SENTINEL-QUESTION-TEXT",
            items: [AgentQuestionItem(id: "q", header: "SENTINEL-HEADER", text: "t", options: [], secret: true)]
        )
        h.agent.setScript(.asking(question))
        await h.registerFirst()
        let created = h.message("SENTINEL-USER-MESSAGE-LOG")
        await h.runtime.tick()
        await h.settle { (try? await h.ledger.task(created.taskID))?.openRequestID == "req-secret" }
        await h.secrets.put(key: LocalSecretKey(taskID: created.taskID, requestID: "req-secret"), value: AgentAnswerValue(text: "SENTINEL-SECRET-LOG"))
        h.server.enqueueAnswer(bridgeID: h.bridgeID, taskID: created.taskID, requestID: "req-secret", locally: true, structured: false)
        h.clock.jump(by: 6)
        await h.runtime.tick()
        await h.settle { h.server.taskState(created.taskID) == "idle" }
        let deviceID = try #require(try h.credentials.deviceID(partition: h.partition.id))
        let secret = try #require(try h.credentials.secret(partition: h.partition.id))
        let joined = h.log.lines.joined(separator: "\n")
        for forbidden in ["SENTINEL", deviceID, secret, "token-", "/Users/someone", "workspace-fake"] {
            #expect(!joined.contains(forbidden), "로그에 \(forbidden) 0")
        }
        #expect(!h.log.lines.isEmpty, "로그 자체는 남는다 (개수 · id · 상태)")
    }
}
#endif
