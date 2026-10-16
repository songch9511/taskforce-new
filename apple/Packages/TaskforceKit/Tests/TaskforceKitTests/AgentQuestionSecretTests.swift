import Foundation
import Testing
@testable import TaskforceKit

/// 비밀값 답 (OA D4b-m-1, 계약 4.5 · 7장 · D4bm-22 · 43 · 45): 이 Mac의 메모리에만 있고, 서버 요청에 실리지 않고, 접힌 줄 · 상태 덤프 · 로그에 나오지 않는다.
/// 실제 내보내기(heartbeat → put → answer-local)는 D4b-m-2다: 여기는 저장소 쪽 규칙과, F2 호출 순서 · 결과 표를 가짜 포트로 시험한다.
@MainActor
struct AgentQuestionSecretTests {
    typealias F = AgentQuestionFixtures

    static let canary = "DO_NOT_STORE_SECRET_D4BM"

    let gateway = FakeAgentQuestionGateway()
    let ticker = ManualTicker()
    let scope = ChatTestAccount.fixedScope()
    let submitter = FakeSecretSubmitter()

    func makeStore(secrets: FakeSecretSubmitter? = nil, scope custom: AccountScope? = nil) -> AgentQuestionStore {
        let ticker = ticker
        let store = AgentQuestionStore(gateway: gateway, scope: custom ?? scope, secrets: secrets ?? submitter, sleep: { await ticker.sleep($0) })
        store.thisMacBridgeID = F.bridgeID
        return store
    }

    func open(_ store: AgentQuestionStore, _ json: String, item: AgentSessionItem = QFx.item()) async {
        gateway.records = [QFx.record(json)]
        store.sessionsRead([item])
        await store.settle()
    }

    func fire() async {
        _ = await eventually { !ticker.pendingDelays.isEmpty }
        ticker.fire()
    }

    func dumped(_ store: AgentQuestionStore) -> String {
        var text = ""
        dump(store.entries, to: &text)
        return text + String(describing: store.entries) + String(reflecting: store.entries)
    }

    // MARK: 이 Mac의 비밀값 질문

    @Test func aSecretIsHeldTwoSecondsThenGoesToTheLocalPathAndNeverToTheServer() async throws {
        let store = makeStore()
        await open(store, F.secret)
        store.submitSecret(SecretBox(Self.canary), session: F.sessionID)
        let held = try #require(store.entry(session: F.sessionID))
        #expect(held.phase == .holding && held.summary == nil, "Answer sent에 값을 보이지 않는다: 둘째 줄이 없다")
        #expect(submitter.submitted.isEmpty)
        await fire()
        #expect(await eventually { store.entry(session: F.sessionID)?.phase == .sent })
        #expect(submitter.submitted.count == 1 && gateway.answers.isEmpty, "서버 답 route는 0")
        let sent = try #require(submitter.submitted.first)
        #expect(sent.key == F.key() && sent.revealed() == ["q1": .text(Self.canary)])
    }

    @Test func undoErasesTheValueSoNothingIsSent() async throws {
        let store = makeStore()
        await open(store, F.secret)
        store.submitSecret(SecretBox(Self.canary), session: F.sessionID)
        store.undo(session: F.sessionID)
        #expect(try #require(store.entry(session: F.sessionID)).phase == .open)
        #expect(!dumped(store).contains(Self.canary))
        await quiet()
        #expect(submitter.submitted.isEmpty && gateway.answers.isEmpty)
        // 다시 입력한 값이 간다
        store.submitSecret(SecretBox("second value"), session: F.sessionID)
        await fire()
        #expect(await eventually { submitter.submitted.count == 1 })
        #expect(submitter.submitted[0].revealed() == ["q1": .text("second value")])
    }

    @Test func aMixedRequestSendsEveryAnswerLocallyEvenTheOnesThatAreNotSecret() async throws {
        let store = makeStore()
        await open(store, F.secretMixed)
        #expect(try #require(store.entry(session: F.sessionID)).card.kind == .single)
        store.choose(row: 0, session: F.sessionID)
        let second = try #require(store.entry(session: F.sessionID))
        #expect(second.step == 1 && second.card.kind == .secret && second.phase == .open)
        store.submitSecret(SecretBox(Self.canary), session: F.sessionID)
        await fire()
        #expect(await eventually { submitter.submitted.count == 1 })
        #expect(submitter.submitted[0].revealed() == ["env": .text("Staging"), "token": .text(Self.canary)], "D4bm-43: 요청의 모든 답을 이 Mac에 둔다")
        await quiet()
        #expect(gateway.answers.isEmpty, "비밀값이 아닌 줄의 답도 서버로 가지 않는다")
    }

    @Test func theValueNeverAppearsInStateDumpsSummariesOrLogs() async throws {
        let lines = LogLines()
        let ticker = ticker
        let store = AgentQuestionStore(gateway: gateway, scope: scope, secrets: submitter, sleep: { await ticker.sleep($0) }, log: { lines.add($0) })
        store.thisMacBridgeID = F.bridgeID
        await open(store, F.secret)
        store.submitSecret(SecretBox(Self.canary), session: F.sessionID)
        #expect(!dumped(store).contains(Self.canary), "보류 중")
        await fire()
        #expect(await eventually { store.entry(session: F.sessionID)?.phase == .sent })
        #expect(!dumped(store).contains(Self.canary), "보낸 뒤")
        #expect(lines.all.joined().contains(Self.canary) == false)
        #expect(try #require(store.entry(session: F.sessionID)).otherText.isEmpty, "입력 글 기억에도 값이 없다")
    }

    // MARK: 결과 표

    @Test func anOutcomeThatCouldNotBeSentReturnsTheCardAndDropsTheValue() async throws {
        for (outcome, failure) in [(LocalSecretOutcome.unavailable, AgentQuestionFailure.generic), (.failed(.offline), .offline), (.failed(.generic), .generic)] {
            let fake = FakeSecretSubmitter()
            fake.outcome = outcome
            let store = makeStore(secrets: fake)
            await open(store, F.secret)
            store.submitSecret(SecretBox(Self.canary), session: F.sessionID)
            await fire()
            #expect(await eventually { store.entry(session: F.sessionID)?.failure == failure }, "\(outcome)")
            let back = try #require(store.entry(session: F.sessionID))
            #expect(back.phase == .open && back.summary == nil && !dumped(store).contains(Self.canary))
        }
    }

    @Test func aClosedQuestionClearsTheCardAndRereads() async throws {
        submitter.outcome = .questionClosed
        let store = makeStore()
        await open(store, F.secret)
        store.submitSecret(SecretBox(Self.canary), session: F.sessionID)
        gateway.records = []
        await fire()
        #expect(await eventually { store.entry(session: F.sessionID) == nil })
        #expect(await eventually { gateway.reads.count == 2 })
    }

    @Test func withoutALocalPathTheCardComesBackWithTheGeneralReason() async throws {
        let ticker = ticker
        let store = AgentQuestionStore(gateway: gateway, scope: scope, secrets: nil, sleep: { await ticker.sleep($0) })
        store.thisMacBridgeID = F.bridgeID
        await open(store, F.secret)
        store.submitSecret(SecretBox(Self.canary), session: F.sessionID)
        await fire()
        #expect(await eventually { store.entry(session: F.sessionID)?.failure == .generic }, "D4b-m-2 전 앱은 구현이 없다: Couldn't send")
        #expect(gateway.answers.isEmpty)
    }

    // MARK: 종료 · 계정

    @Test func aSecretHeldAtQuitIsDroppedNotSentAndTheQuestionStaysOpen() async throws {
        let store = makeStore()
        await open(store, F.secret)
        store.submitSecret(SecretBox(Self.canary), session: F.sessionID)
        #expect(store.hasHeldAnswers)
        await store.flushForQuit(timeout: 3)
        #expect(submitter.submitted.isEmpty && gateway.answers.isEmpty, "표시만 서버에 가면 다음 실행의 lease가 값 없이 거절로 닫는다")
        let back = try #require(store.entry(session: F.sessionID))
        #expect(back.phase == .open && back.summary == nil && !dumped(store).contains(Self.canary), "카드는 열린 채 남는다")
        #expect(ticker.pendingDelays.isEmpty && !store.hasHeldAnswers)
    }

    @Test func aPlainAnswerAndASecretAtQuitAreTreatedApartPerSession() async throws {
        let store = makeStore()
        gateway.records = [QFx.record(F.secret), QFx.record(QFx.single(request: "plain", task: QFx.secondTask), task: QFx.secondTask, session: QFx.secondSession)]
        store.sessionsRead([QFx.item(), QFx.item(session: QFx.secondSession)])
        await store.settle()
        store.submitSecret(SecretBox(Self.canary), session: F.sessionID)
        store.choose(row: 0, session: QFx.secondSession)
        await store.flushForQuit(timeout: 3)
        #expect(submitter.submitted.isEmpty && gateway.answers.count == 1 && gateway.answers[0].taskID == QFx.secondTask)
    }

    @Test func leavingTheAccountWhileASecretIsHeldDropsItWithNoCall() async throws {
        let account = ChatTestAccount.fixedScope()
        let store = makeStore(scope: account)
        await open(store, F.secret)
        store.submitSecret(SecretBox(Self.canary), session: F.sessionID)
        account.accountLeft()
        #expect(store.entries.isEmpty && !dumped(store).contains(Self.canary))
        await quiet()
        #expect(submitter.submitted.isEmpty && gateway.answers.isEmpty)
    }

    @Test func aLateOutcomeAfterAnAccountChangeIsDropped() async throws {
        let account = ChatTestAccount.fixedScope()
        let store = makeStore(scope: account)
        var answered = 0
        store.onAnswered = { _, _ in answered += 1 }
        await open(store, F.secret)
        let latch = Latch()
        submitter.holdNext(latch)
        store.submitSecret(SecretBox(Self.canary), session: F.sessionID)
        await fire()
        #expect(await latch.waitForArrivals(1, timeout: .seconds(3)))
        account.accountLeft()
        await latch.open()
        await quiet(120)
        #expect(store.entries.isEmpty && answered == 0)
    }

    // MARK: 다른 기기 · composer

    @Test func aSecretOnAnotherDeviceCannotBeAnsweredHere() async throws {
        let store = makeStore()
        await open(store, F.secret, item: QFx.item(bridge: F.otherBridgeID))
        let remote = try #require(store.entry(session: F.sessionID))
        #expect(remote.card.kind == .secretRemote)
        store.submitSecret(SecretBox(Self.canary), session: F.sessionID)
        store.choose(row: 0, session: F.sessionID)
        store.submitText(Self.canary, session: F.sessionID)
        #expect(try #require(store.entry(session: F.sessionID)).phase == .open)
        await quiet()
        #expect(submitter.submitted.isEmpty && gateway.answers.isEmpty && ticker.pendingDelays.isEmpty)
    }

    @Test func typingInTheComposerCanNeverBecomeASecretAnswer() async throws {
        // composer는 막혀 있고, 저장소 쪽에도 자유 글을 비밀값의 답으로 받는 길이 없다 (글 입력은 비밀값 카드에 닿지 않는다)
        let store = makeStore()
        await open(store, F.secret)
        #expect(store.blocksComposer(session: F.sessionID))
        store.submitText(Self.canary, session: F.sessionID)
        store.choose(row: 0, session: F.sessionID)
        store.toggle(row: 0, session: F.sessionID)
        #expect(try #require(store.entry(session: F.sessionID)).phase == .open)
        await quiet()
        #expect(submitter.submitted.isEmpty && gateway.answers.isEmpty)
    }
}

final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var _all: [String] = []
    var all: [String] { lock.withLock { _all } }
    func add(_ line: String) { lock.withLock { _all.append(line) } }
}

// MARK: F2 호출 순서 · 결과 표 (가짜 포트)

/// `AgentQuestionSecretFlow` (계약 4.5, F2 notes 10장): heartbeat가 성공한 **뒤에만** → `LocalSecretAnswers.put`을 **먼저** → `POST /api/v1/bridge/answer-local {bridge_id, agent_task_id, request_digest}` → 결과에 따라 값을 두거나 지운다.
/// 포트에는 digest(64자 16진)만 건넨다: 값 · `provider_request_id`는 요청 쪽으로 가지 않는다. 실제 포트는 D4b-m-2가 `BridgeClient` · `BridgeRuntime`으로 채운다
struct AgentQuestionSecretFlowTests {
    typealias F = AgentQuestionFixtures
    typealias Reply = AgentQuestionSecretFlow.Reply

    static let canary = "DO_NOT_STORE_SECRET_D4BM"

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [String] = []
        private var _replies: [Reply]
        var heartbeats: [Bool]
        init(replies: [Reply], heartbeats: [Bool] = [true, true]) {
            _replies = replies
            self.heartbeats = heartbeats
        }
        var events: [String] { lock.withLock { _events } }
        func add(_ event: String) { lock.withLock { _events.append(event) } }
        func nextReply() -> Reply {
            lock.withLock {
                _events.append("post")
                return _replies.isEmpty ? .network : _replies.removeFirst()
            }
        }
        func nextHeartbeat() -> Bool {
            lock.withLock {
                _events.append("heartbeat")
                return heartbeats.isEmpty ? true : heartbeats.removeFirst()
            }
        }
        var digests: [String] { lock.withLock { _digests } }
        private var _digests: [String] = []
        func addDigest(_ digest: String) { lock.withLock { _digests.append(digest) } }
    }

    func ports(_ recorder: Recorder) -> AgentQuestionSecretFlow.Ports {
        AgentQuestionSecretFlow.Ports(
            heartbeat: { recorder.nextHeartbeat() },
            put: { _ in recorder.add("put") },
            erase: { _ in recorder.add("erase") },
            reconcile: { recorder.add("reconcile") },
            post: { digest in
                recorder.addDigest(digest)
                return recorder.nextReply()
            },
            pause: { _ in recorder.add("pause") }
        )
    }

    var answer: LocalSecretAnswer {
        LocalSecretAnswer(key: F.key(), answers: ["token": .secret(SecretBox(Self.canary))])
    }

    func run(_ replies: [Reply], heartbeats: [Bool] = [true, true]) async -> (LocalSecretOutcome, Recorder) {
        let recorder = Recorder(replies: replies, heartbeats: heartbeats)
        let outcome = await AgentQuestionSecretFlow.run(answer, ports: ports(recorder))
        return (outcome, recorder)
    }

    @Test func theOrderIsHeartbeatThenPutThenThePostAndTheValueStaysOnAnswered() async {
        for reply in [Reply.answered, .duplicate] {
            let (outcome, recorder) = await run([reply])
            #expect(outcome == .sent && recorder.events == ["heartbeat", "put", "post"], "\(reply): 값은 lease가 가져가도록 둔다 (지우지 않는다)")
        }
    }

    @Test func theRequestCarriesOnlyTheSha256DigestOfTheProviderRequestID() async {
        let (_, recorder) = await run([.answered])
        #expect(recorder.digests == ["0e558779236c0c8b12aad0b75364ec4a080b58bba3e5fb8795316522a2d08c4e"], "F2의 알려진 digest (ANSWER_LOCAL_REQUEST_JSON)")
        #expect(AgentQuestionRules.requestDigest("가나 ✓ 日本") == "f724923ecc39a80fbdc26c6afd41817f598f99a9d94cb7177b29c178cbdc7740", "멀티바이트 id도 UTF-8 바이트 그대로")
        #expect(recorder.digests.allSatisfy { !$0.contains(Self.canary) && !$0.contains(F.requestID) && $0.count == 64 })
    }

    @Test func aFailedHeartbeatPutsNothingAndSendsNothing() async {
        let (outcome, recorder) = await run([.answered], heartbeats: [false])
        #expect(outcome == .failed(.generic) && recorder.events == ["heartbeat"], "깨어난 직후의 not_live를 막는다: 값을 두기 전에 멈춘다")
    }

    @Test func aClosedOrUnknownQuestionErasesTheValueAndRereads() async {
        let replies: [Reply] = [.stale(.questionClosed), .stale(.notSecret), .http(404), .http(401), .http(403)]
        for reply in replies {
            let (outcome, recorder) = await run([reply])
            #expect(outcome == .questionClosed && recorder.events == ["heartbeat", "put", "post", "erase"], "\(reply)")
        }
    }

    @Test func notLiveKeepsTheValueRevivesTheTaskAndTriesOnceMore() async {
        let (outcome, recorder) = await run([.stale(.notLive), .answered])
        #expect(outcome == .sent && recorder.events == ["heartbeat", "put", "post", "reconcile", "heartbeat", "post"])
        let (failed, again) = await run([.stale(.notLive), .stale(.notLive)])
        #expect(failed == .failed(.generic) && again.events.filter { $0 == "post" }.count == 2 && again.events.last == "erase", "또 실패면 지운다")
    }

    @Test func conflictServerErrorRateLimitAndNetworkKeepTheValueAndRepeatTheSameRequest() async {
        for reply in [Reply.http(409), .http(429), .http(500), .http(503), .network] {
            let (outcome, recorder) = await run([reply, .answered])
            #expect(outcome == .sent, "\(reply)")
            #expect(recorder.events.filter { $0 == "post" }.count == 2 && !recorder.events.contains("erase"))
            #expect(Set(recorder.digests).count == 1, "같은 요청(멱등)")
        }
    }

    @Test func ifItIsNeverKnownTheValueIsErasedAndTheCardComesBack() async {
        let (offline, offlineRecorder) = await run([.network, .network, .network, .network])
        #expect(offline == .failed(.offline) && offlineRecorder.events.last == "erase" && offlineRecorder.events.filter { $0 == "post" }.count == AgentQuestionSecretFlow.maxAttempts)
        let (busy, busyRecorder) = await run([.http(503), .http(503), .http(503), .http(503)])
        #expect(busy == .failed(.generic) && busyRecorder.events.last == "erase")
    }

    @Test func aBadRequestIsAnAppBugTheValueIsErasedAndThereIsNoRetry() async {
        let (outcome, recorder) = await run([.http(400), .answered])
        #expect(outcome == .failed(.generic) && recorder.events == ["heartbeat", "put", "post", "erase"])
    }

    @Test func theDecisionTableIsPureAndCoversEveryReply() {
        typealias D = AgentQuestionSecretFlow.Decision
        #expect(AgentQuestionSecretFlow.decision(for: .answered, attempt: 1, revived: false) == .done(.sent))
        #expect(AgentQuestionSecretFlow.decision(for: .stale(.questionClosed), attempt: 1, revived: false) == .erase(.questionClosed))
        #expect(AgentQuestionSecretFlow.decision(for: .stale(.notLive), attempt: 1, revived: false) == .reviveAndRetry)
        #expect(AgentQuestionSecretFlow.decision(for: .stale(.notLive), attempt: 2, revived: true) == .erase(.failed(.generic)))
        #expect(AgentQuestionSecretFlow.decision(for: .http(409), attempt: 1, revived: false) == .retry)
        #expect(AgentQuestionSecretFlow.decision(for: .http(409), attempt: AgentQuestionSecretFlow.maxAttempts, revived: false) == .erase(.failed(.generic)))
        #expect(AgentQuestionSecretFlow.decision(for: .network, attempt: AgentQuestionSecretFlow.maxAttempts, revived: false) == .erase(.failed(.offline)))
        #expect(AgentQuestionSecretFlow.decision(for: .http(400), attempt: 1, revived: false) == .erase(.failed(.generic)))
        #expect(AgentQuestionSecretFlow.decision(for: .http(418), attempt: 1, revived: false) == .retry, "모르는 상태는 모르는 대로 다시 시도하다 지운다")
    }
}
