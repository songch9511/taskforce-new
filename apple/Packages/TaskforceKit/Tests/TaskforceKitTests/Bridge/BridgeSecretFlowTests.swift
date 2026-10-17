#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// OA D4b-m-2 (계약 16.4 · 16.8): 비밀값 답을 내보내는 실제 길. 순서(heartbeat → put → POST)와 결과 표를 실제 포트 + `FakeBridgeServer`로 본다.
/// 값은 `TF_CANARY_D4BM2_<uuid>`다. 서버가 받은 모든 요청에 값이 없는 것은 `BridgeSecretCanaryTests`가 본다
struct BridgeSecretFlowTests {
    typealias S = SecretFixture

    private func answerLocalRequests(_ h: BridgeHarness) -> [FakeBridgeServer.Recorded] { h.server.requests("answer-local") }

    // MARK: 순서

    @Test func theValueIsInMemoryBeforeThePostArrivesAndTheRequestCarriesOnlyTheDigest() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h)
        let key = S.key(created)
        let seenAtPost = Locked<[Bool]>([])
        let routes = Locked<[String]>([])
        h.server.onRequest = { [secrets = h.secrets] record in
            routes.set(routes.get() + [record.route])
            if record.route == "answer-local" { seenAtPost.set(seenAtPost.get() + [await secrets.contains(key: key)]) }
        }
        let canary = S.canary()
        #expect(await S.submit(h, S.answer(created, value: canary)) == .sent)
        #expect(seenAtPost.get() == [true], "POST가 도착한 순간 값은 이미 메모리에 있다 (put이 먼저)")
        let requests = answerLocalRequests(h)
        try #require(requests.count == 1)
        let body = requests[0].json
        #expect(Set(body.keys) == ["bridge_id", "agent_task_id", "request_digest"])
        #expect(body["request_digest"] as? String == AgentQuestionRules.requestDigest(S.requestID))
        #expect(body["agent_task_id"] as? String == created.taskID && body["bridge_id"] as? String == h.bridgeID)
        let deviceSecret = try h.credentials.secret(partition: h.partition.id)
        #expect(requests[0].secret == deviceSecret && requests[0].token == h.token)
        #expect(requests[0].query.isEmpty)
        #expect(!requests[0].bodyJSON.contains(canary) && !requests[0].bodyJSON.contains(S.requestID))
        #expect(await h.secrets.contains(key: key), "서버가 받았다: 값은 lease가 가져가도록 둔다")
    }

    @Test func theAnswerCommandThatTheServerMakesDeliversTheValueOnceAndTheBoxIsEmptyAfterwards() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h)
        let canary = S.canary()
        #expect(await S.submit(h, S.answer(created, value: canary)) == .sent)
        await S.deliver(h)
        #expect(await h.eventually { h.agent.deliveredAnswers.count == 1 })
        let delivered = try #require(h.agent.deliveredAnswers.first)
        #expect(delivered.requestID == S.requestID && delivered.taskID == created.taskID)
        #expect(delivered.value.answers == [S.itemID: .one(canary)], "입력한 값이 그대로 adapter에 닿는다")
        await h.settle { h.server.taskState(created.taskID) == "idle" }
        #expect(await h.secrets.hasPending == false, "한 번 주고 지운다")
        #expect(h.agent.deliveredAnswers.count == 1)
    }

    @Test func aFreshHeartbeatIsNotSentAgainButAStaleOneIsRenewedBeforeThePost() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h)
        let routes = Locked<[String]>([])
        h.server.onRequest = { record in routes.set(routes.get() + [record.route]) }
        #expect(await S.submit(h, S.answer(created, value: S.canary())) == .sent)
        #expect(routes.get() == ["answer-local"], "90초 안의 heartbeat는 그대로 쓴다")

        let h2 = try BridgeHarness()
        let created2 = try await S.open(h2)
        let routes2 = Locked<[String]>([])
        h2.server.onRequest = { record in routes2.set(routes2.get() + [record.route]) }
        h2.clock.jump(by: 100)
        #expect(await S.submit(h2, S.answer(created2, value: S.canary())) == .sent)
        let relevant = routes2.get().filter { $0 == "heartbeat" || $0 == "answer-local" }
        #expect(relevant == ["heartbeat", "answer-local"], "오래됐으면 heartbeat가 먼저다: \(routes2.get())")
    }

    @Test func aFailedHeartbeatPutsNothingAndSendsNothing() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h)
        let puts = Locked<Int>(0)
        await h.secrets.observe { busy in if busy { puts.set(puts.get() + 1) } }
        h.clock.jump(by: 100)
        h.server.failNext("heartbeat", .init(status: 503, count: 3))
        #expect(await S.submit(h, S.answer(created, value: S.canary())) == .failed(.generic))
        #expect(answerLocalRequests(h).isEmpty, "POST 0")
        let pending = await h.secrets.hasPending
        #expect(puts.get() == 0 && !pending, "put 0")
    }

    // MARK: 결과 표 (F2 notes 10장 2-4)

    private struct Case {
        var name: String
        var failures: [FakeBridgeServer.Failure]
        var outcome: LocalSecretOutcome
        var posts: Int
        var keepsValue: Bool
    }

    private static func stale(_ reason: String, count: Int = 1) -> FakeBridgeServer.Failure {
        .init(status: 200, count: count, bodyJSON: #"{"status":"stale","reason":"\#(reason)"}"#)
    }

    private static let cases: [Case] = [
        Case(name: "stale question_closed", failures: [stale("question_closed")], outcome: .questionClosed, posts: 1, keepsValue: false),
        Case(name: "stale not_secret", failures: [stale("not_secret")], outcome: .questionClosed, posts: 1, keepsValue: false),
        Case(name: "404", failures: [.init(status: 404)], outcome: .questionClosed, posts: 1, keepsValue: false),
        Case(name: "401 (회복 뒤에도)", failures: [.init(status: 401, count: 5)], outcome: .questionClosed, posts: 2, keepsValue: false),
        Case(name: "403", failures: [.init(status: 403)], outcome: .questionClosed, posts: 1, keepsValue: false),
        Case(name: "400", failures: [.init(status: 400)], outcome: .failed(.generic), posts: 1, keepsValue: false),
        Case(name: "409 한 번 뒤 성공", failures: [.init(status: 409)], outcome: .sent, posts: 2, keepsValue: true),
        Case(name: "500 한 번 뒤 성공", failures: [.init(status: 500)], outcome: .sent, posts: 2, keepsValue: true),
        Case(name: "전송 오류 한 번 뒤 성공", failures: [.init(status: 0, transport: true)], outcome: .sent, posts: 2, keepsValue: true),
        Case(name: "409 세 번", failures: [.init(status: 409, count: 3)], outcome: .failed(.generic), posts: 3, keepsValue: false),
        Case(name: "503 세 번", failures: [.init(status: 503, count: 3)], outcome: .failed(.generic), posts: 3, keepsValue: false),
        Case(name: "전송 오류 세 번", failures: [.init(status: 0, transport: true, count: 3)], outcome: .failed(.offline), posts: 3, keepsValue: false),
        Case(name: "429 (그 route가 멈춘다)", failures: [.init(status: 429, headers: ["Retry-After": "60"])], outcome: .failed(.offline), posts: 1, keepsValue: false),
        Case(name: "not_live 한 번 뒤 성공", failures: [stale("not_live")], outcome: .sent, posts: 2, keepsValue: true),
        Case(name: "not_live 두 번", failures: [stale("not_live", count: 2)], outcome: .failed(.generic), posts: 2, keepsValue: false),
        Case(name: "모르는 status", failures: [.init(status: 200, bodyJSON: #"{"status":"future_thing"}"#)], outcome: .failed(.generic), posts: 1, keepsValue: false),
        Case(name: "모르는 stale 이유", failures: [stale("future_reason")], outcome: .failed(.generic), posts: 1, keepsValue: false),
    ]

    @Test func theResultTableHoldsLineByLine() async throws {
        for item in Self.cases {
            let h = try BridgeHarness()
            let created = try await S.open(h)
            for failure in item.failures { h.server.failNext("answer-local", failure) }
            let canary = S.canary()
            let outcome = await S.submit(h, S.answer(created, value: canary))
            #expect(outcome == item.outcome, "\(item.name): \(outcome)")
            #expect(answerLocalRequests(h).count == item.posts, "\(item.name): POST \(answerLocalRequests(h).count)번")
            #expect(await h.secrets.contains(key: S.key(created)) == item.keepsValue, "\(item.name): 값")
            #expect(Set(answerLocalRequests(h).map(\.bodyJSON)).count == 1, "\(item.name): 같은 요청(멱등)")
            #expect(!h.log.events.contains("bridge_gone"), "\(item.name): 이 route의 오류가 bridge를 지우지 않는다")
            #expect(!answerLocalRequests(h).contains { $0.bodyJSON.contains(canary) }, "\(item.name): 본문에 값 0")
        }
    }

    @Test func aRevokedMacErasesTheValueAndStopsTheNetwork() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h)
        h.server.failNext("answer-local", .init(status: 403))
        #expect(await S.submit(h, S.answer(created, value: S.canary())) == .questionClosed)
        #expect(await h.runtime.status == .revoked)
        #expect(await h.secrets.hasPending == false)
    }

    // MARK: 서버 규칙을 흉내 낸 가짜 서버

    /// 가짜 서버의 규칙은 클라이언트로 직접 본다 (제출 길은 원장이 모르는 요청이면 POST 전에 멈춘다: `BridgeSecretReviewFixTests`)
    private func rawAnswerLocal(_ h: BridgeHarness, task: String, request: String) async throws -> BridgeV1AnswerLocalResponse {
        let secret = try #require(try h.credentials.secret(partition: h.partition.id))
        return try await h.runtime.client.answerLocal(
            BridgeV1AnswerLocalRequest(bridgeID: h.bridgeID, agentTaskID: task, requestDigest: AgentQuestionRules.requestDigest(request)), secret: secret
        )
    }

    @Test func theFakeServerSaysClosedForADigestOfAnotherRequestAndMakesNoAnswerCommand() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h)
        #expect(try await rawAnswerLocal(h, task: created.taskID, request: "some-other-request") == .stale(reason: .questionClosed))
        #expect(h.server.commandIDs(taskID: created.taskID, kind: "answer").isEmpty)
        h.clock.jump(by: 6)
        await h.runtime.tick()
        #expect(h.agent.deliveredAnswers.isEmpty)
    }

    @Test func theFakeServerSaysNotSecretForAQuestionWithoutASecretItem() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h, secret: false)
        #expect(try await rawAnswerLocal(h, task: created.taskID, request: S.requestID) == .stale(reason: .notSecret))
        #expect(h.server.commandIDs(taskID: created.taskID, kind: "answer").isEmpty)
    }

    @Test func theSameRequestAgainIsADuplicateAndMakesNoSecondCommand() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h)
        let canary = S.canary()
        #expect(await S.submit(h, S.answer(created, value: canary)) == .sent)
        #expect(await S.submit(h, S.answer(created, value: canary)) == .sent)
        #expect(answerLocalRequests(h).count == 2)
        await S.deliver(h)
        #expect(await h.eventually { h.agent.deliveredAnswers.count == 1 })
        await h.settle { h.server.taskState(created.taskID) == "idle" }
        #expect(h.agent.deliveredAnswers.count == 1, "답 명령은 하나뿐이다")
        #expect(await h.secrets.hasPending == false)
    }

    @Test func theFakeServerSaysNotFoundForATaskThisMacDoesNotOwn() async throws {
        let h = try BridgeHarness()
        _ = try await S.open(h)
        await #expect(throws: BridgeClientError.notFound) {
            _ = try await rawAnswerLocal(h, task: UUID().uuidString.lowercased(), request: S.requestID)
        }
    }

    // MARK: 계정 경계 (D4bm2-05)

    @Test func anAccountThatDoesNotMatchAtTheStartSendsNothing() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h)
        let checks = AccountChecks([false])
        #expect(await S.submit(h, S.answer(created, value: S.canary()), matches: checks.closure) == .failed(.generic))
        let pending = await h.secrets.hasPending
        #expect(answerLocalRequests(h).isEmpty && !pending)
    }

    @Test func anAccountThatChangesBeforeThePutPutsNothingAndSendsNothing() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h)
        let puts = Locked<Int>(0)
        await h.secrets.observe { busy in if busy { puts.set(puts.get() + 1) } }
        let checks = AccountChecks([true, false, false])
        #expect(await S.submit(h, S.answer(created, value: S.canary()), matches: checks.closure) == .failed(.generic))
        let pending = await h.secrets.hasPending
        #expect(answerLocalRequests(h).isEmpty && puts.get() == 0 && !pending)
    }

    @Test func anAccountThatChangesAfterThePutErasesTheValueAndSendsNothing() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h)
        let puts = Locked<Int>(0)
        await h.secrets.observe { busy in if busy { puts.set(puts.get() + 1) } }
        let checks = AccountChecks([true, true, false])
        #expect(await S.submit(h, S.answer(created, value: S.canary()), matches: checks.closure) == .failed(.generic))
        #expect(puts.get() == 1, "put은 했다")
        #expect(answerLocalRequests(h).isEmpty, "POST 0")
        #expect(await h.secrets.hasPending == false, "값 0")
    }

    @Test func aTokenForAnotherUserNeverReachesTheServerAndTheValueIsErased() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h)
        h.bearerUser.set(UUID())
        #expect(await S.submit(h, S.answer(created, value: S.canary())) == .failed(.generic))
        let pending = await h.secrets.hasPending
        #expect(answerLocalRequests(h).isEmpty && !pending)
    }

    // MARK: 받지 않는 런타임

    @Test func aRuntimeThatIsShuttingDownOrDrainingTakesNoValue() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h)
        await h.runtime.shutdown(interrupt: false)
        #expect(await S.submit(h, S.answer(created, value: S.canary())) == .unavailable)
        #expect(await h.secrets.hasPending == false)

        let drain = try BridgeHarness(mode: .drain)
        let created2 = FakeBridgeServer.Created(commandID: "x", taskID: UUID().uuidString.lowercased(), sessionID: "y", stepID: "z", marker: "m")
        #expect(await S.submit(drain, S.answer(created2, value: S.canary())) == .unavailable)
        #expect(await drain.secrets.hasPending == false)
    }

    @Test func aValueThatVanishesBetweenThePutAndThePostIsNotPostedFor() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h)
        let key = S.key(created)
        let calls = Locked(0)
        // 확인 셋(heartbeat · put · POST 앞) 가운데 셋째에서 값이 사라진다 (정산 · 보관 정리가 지운 경우)
        let matches: @Sendable () async -> Bool = { [secrets = h.secrets] in
            let number = calls.get() + 1
            calls.set(number)
            if number == 3 { await secrets.discard(key: key) }
            return true
        }
        #expect(await S.submit(h, S.answer(created, value: S.canary()), matches: matches) == .failed(.generic))
        #expect(calls.get() == 3)
        #expect(answerLocalRequests(h).isEmpty, "값이 메모리에 없으면 서버에 답했다고 표시하지 않는다 (받아 줄 값이 없는 답 명령을 만들지 않는다)")
        let pending = await h.secrets.hasPending
        #expect(!pending)
    }

    // MARK: 가짜 서버가 흉내 낸 규칙

    @Test func theFakeServerSaysNotLiveWhenTheMacHasBeenSilentForMoreThanNinetySeconds() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h)
        let secret = try #require(try h.credentials.secret(partition: h.partition.id))
        let request = BridgeV1AnswerLocalRequest(bridgeID: h.bridgeID, agentTaskID: created.taskID, requestDigest: AgentQuestionRules.requestDigest(S.requestID))
        h.clock.jump(by: 100)
        #expect(try await h.runtime.client.answerLocal(request, secret: secret) == .stale(reason: .notLive))
        #expect(h.server.commandIDs(taskID: created.taskID, kind: "answer").isEmpty, "답 명령은 만들지 않았다")
    }

    @Test func theFakeServerRefusesABodyWithAnExtraKeyOrABadDigest() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h)
        let secret = try #require(try h.credentials.secret(partition: h.partition.id))
        let session = h.server.makeSession()
        func post(_ object: [String: Any]) async throws -> Int {
            var request = URLRequest(url: h.server.baseURL.appending(path: "api/v1/bridge/answer-local"))
            request.httpMethod = "POST"
            request.setValue("Bearer \(h.token)", forHTTPHeaderField: "Authorization")
            request.setValue(secret, forHTTPHeaderField: "X-Taskforce-Bridge-Secret")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: object)
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? 0
        }
        let digest = AgentQuestionRules.requestDigest(S.requestID)
        let good: [String: Any] = ["bridge_id": h.bridgeID, "agent_task_id": created.taskID, "request_digest": digest]
        var extra = good
        extra["answers"] = "TF_CANARY_SHOULD_NEVER_BE_ACCEPTED"
        #expect(try await post(extra) == 400, "strict 3키: 값을 실을 키는 400")
        var shortDigest = good
        shortDigest["request_digest"] = String(digest.prefix(63))
        #expect(try await post(shortDigest) == 400)
        var upper = good
        upper["request_digest"] = digest.uppercased()
        #expect(try await post(upper) == 400)
        #expect(try await post(good) == 200)
    }
}
#endif
