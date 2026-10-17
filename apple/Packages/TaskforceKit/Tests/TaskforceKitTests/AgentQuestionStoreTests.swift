import Foundation
import Testing
@testable import TaskforceKit

/// 질문 저장소 (OA D4b-m-1, 계약 2.1-1 · 4.3 DEC-5 · 11.1): 읽기 규칙 · 2초 보류 · Undo · 실패 되돌림 · 두 화면이 보는 상태 하나 · 계정 경계 · 종료 때 보냄.
/// 시계는 `ManualTicker`로 손으로 돌린다 (실제 2초를 기다리지 않는다). 서버는 가짜(`FakeAgentQuestionGateway`)다
@MainActor
struct AgentQuestionStoreTests {
    typealias F = AgentQuestionFixtures

    let gateway = FakeAgentQuestionGateway()
    let ticker = ManualTicker()
    let scope = ChatTestAccount.fixedScope()
    /// 로그에 남은 줄 (코드 이름뿐이어야 한다)
    let logged = LogSink()

    final class LogSink: @unchecked Sendable {
        private let lock = NSLock()
        private var _lines: [String] = []
        var lines: [String] { lock.withLock { _lines } }
        func add(_ line: String) { lock.withLock { _lines.append(line) } }
    }

    func makeStore(secrets: FakeSecretSubmitter? = nil, scope customScope: AccountScope? = nil) -> AgentQuestionStore {
        let logged = logged
        let ticker = ticker
        let store = AgentQuestionStore(gateway: gateway, scope: customScope ?? scope, secrets: secrets, sleep: { await ticker.sleep($0) }, log: { logged.add($0) })
        store.thisMacBridgeID = F.bridgeID
        return store
    }

    /// 세션이 질문을 기다린다고 알리고 읽기가 끝날 때까지
    func open(_ store: AgentQuestionStore, _ json: String, item: AgentSessionItem = QFx.item()) async {
        gateway.records = [QFx.record(json)]
        store.sessionsRead([item])
        await store.settle()
    }

    /// 보류 시계가 걸릴 때까지 기다렸다가 돌린다 (Task가 시계를 거는 것은 비동기다)
    func fire(_ clock: ManualTicker? = nil) async {
        let target = clock ?? ticker
        _ = await eventually { !target.pendingDelays.isEmpty }
        target.fire()
    }

    func entry(_ store: AgentQuestionStore) throws -> AgentQuestionStore.Entry {
        try #require(store.entry(session: F.sessionID))
    }

    // MARK: 읽기

    @Test func aSessionWaitingForAnAnswerGetsItsCardFromOneRead() async throws {
        let store = makeStore()
        await open(store, F.single)
        let e = try entry(store)
        #expect(e.phase == .open && e.card.kind == .single && e.card.title == "Which price should lead the yearly card?" && e.question.key == F.key())
        #expect(gateway.reads == [[F.sessionID]])
    }

    @Test func onlySessionsWaitingForAnAnswerOrShowingACardAreRead() async throws {
        let store = makeStore()
        gateway.records = [QFx.record(F.single)]
        store.sessionsRead([QFx.item(state: .running), QFx.item(session: QFx.secondSession, state: .idle), QFx.item(session: UUID(), state: nil)])
        await store.settle()
        #expect(gateway.reads.isEmpty && store.entry(session: F.sessionID) == nil, "기다리지 않는 세션은 읽지 않는다")
    }

    @Test func aSessionThatStoppedWaitingIsReadOnceMoreSoTheServerDecidesWhenTheCardGoes() async throws {
        let store = makeStore()
        await open(store, F.single)
        gateway.records = []
        store.sessionsRead([QFx.item(state: .running)])
        await store.settle()
        #expect(gateway.reads.count == 2, "서버가 사실이다: 세션 읽기 하나가 카드를 치우지 않는다")
        #expect(store.entry(session: F.sessionID) == nil)
    }

    @Test func aFailedReadKeepsTheCardAlreadyShown() async throws {
        let store = makeStore()
        await open(store, F.single)
        gateway.readFailure = FakeAgentQuestionGateway.Failure()
        store.sessionsRead([QFx.item()])
        await store.settle()
        #expect(store.entry(session: F.sessionID)?.question.key == F.key())
    }

    @Test func aBrokenQuestionDrawsNoCardAndNeverCrashes() async throws {
        let store = makeStore()
        await open(store, F.unknownKind)
        #expect(store.entry(session: F.sessionID) == nil && !store.blocksComposer(session: F.sessionID))
    }

    @Test func onlyTheLastStartedReadIsApplied() async throws {
        let store = makeStore()
        let latch = Latch()
        gateway.records = [QFx.record(QFx.single(request: "old"))]
        gateway.holdNextRead(latch)
        store.sessionsRead([QFx.item()])
        #expect(await latch.waitForArrivals(1, timeout: .seconds(3)), "첫 읽기가 서버에 닿았다")
        gateway.records = [QFx.record(QFx.single(request: "new"))]
        store.sessionsRead([QFx.item()])
        #expect(await eventually { store.entry(session: F.sessionID)?.question.key.requestID == "new" })
        await latch.open()
        await store.settle()
        #expect(store.entry(session: F.sessionID)?.question.key.requestID == "new", "먼저 시작한 읽기가 늦게 끝나도 새 질문을 되돌리지 못한다")
    }

    // MARK: 2초 보류 (DEC-5)

    @Test func pickingARowFoldsTheCardAtOnceAndSendsNothingForTwoSeconds() async throws {
        let store = makeStore()
        await open(store, F.single)
        store.choose(row: 2, session: F.sessionID)
        let e = try entry(store)
        #expect(e.phase == .holding && e.summary == "Yearly total")
        #expect(await eventually { ticker.pendingDelays == [2.0] }, "보류는 정확히 2.0초")
        #expect(gateway.answers.isEmpty)
    }

    @Test func afterTwoSecondsExactlyOneRequestCarriesTheAnswer() async throws {
        let store = makeStore()
        await open(store, F.single)
        store.choose(row: 2, session: F.sessionID)
        await fire()
        #expect(await eventually { store.entry(session: F.sessionID)?.phase == .sent })
        #expect(gateway.answers.count == 1)
        let sent = try #require(gateway.answers.first)
        #expect(sent.taskID == F.taskID && sent.request.providerRequestID == F.requestID && sent.request.answers == ["q1": .text("Yearly total")])
        #expect(try entry(store).summary == "Yearly total", "보낸 뒤에도 고른 답이 접힌 줄에 남는다")
    }

    @Test func undoInsideTheWindowMakesNoServerCallAndBringsTheCardBack() async throws {
        let store = makeStore()
        await open(store, F.single)
        store.choose(row: 0, session: F.sessionID)
        store.undo(session: F.sessionID)
        let e = try entry(store)
        #expect(e.phase == .open && e.summary == nil && e.card.kind == .single)
        #expect(ticker.pendingDelays.isEmpty, "보류 시계도 걷힌다")
        await quiet()
        #expect(gateway.answers.isEmpty)
        store.choose(row: 1, session: F.sessionID)
        await fire()
        #expect(await eventually { gateway.answers.count == 1 })
        #expect(gateway.answers[0].request.answers == ["q1": .text("Monthly price")], "Undo 뒤 다시 고른 답이 간다")
    }

    @Test func pressingTwiceSendsOneRequestWithTheFirstChoice() async throws {
        let store = makeStore()
        await open(store, F.single)
        store.choose(row: 1, session: F.sessionID)
        store.choose(row: 3, session: F.sessionID)
        store.sendChecked(session: F.sessionID)
        await fire()
        #expect(await eventually { gateway.answers.count == 1 })
        await quiet()
        #expect(gateway.answers.count == 1 && gateway.answers[0].request.answers == ["q1": .text("Monthly price")])
    }

    @Test func undoAfterTheRequestHasStartedDoesNothing() async throws {
        let store = makeStore()
        await open(store, F.single)
        let latch = Latch()
        gateway.holdNextAnswer(latch)
        store.choose(row: 0, session: F.sessionID)
        await fire()
        #expect(await latch.waitForArrivals(1, timeout: .seconds(3)))
        #expect(try entry(store).phase == .sending)
        store.undo(session: F.sessionID)
        #expect(try entry(store).phase == .sending, "보내기 시작부터는 Undo가 없다")
        await latch.open()
        #expect(await eventually { store.entry(session: F.sessionID)?.phase == .sent })
        #expect(gateway.answers.count == 1)
    }

    @Test func theHoldBelongsToTheQuestionNotToAnyScreenSoSessionReadsDoNotDisturbIt() async throws {
        let store = makeStore()
        await open(store, F.single)
        store.choose(row: 0, session: F.sessionID)
        store.sessionsRead([QFx.item()])
        await store.settle()
        #expect(try entry(store).phase == .holding, "같은 질문이 다시 읽혀도 보류는 그대로다 (창 닫기 · 패널 접기도 마찬가지)")
        #expect(await eventually { ticker.pendingDelays == [2.0] })
        await fire()
        #expect(await eventually { gateway.answers.count == 1 })
    }

    @Test func aDifferentQuestionOnTheSameTaskReplacesTheHeldAnswerWithoutSendingIt() async throws {
        let store = makeStore()
        await open(store, F.single)
        store.choose(row: 0, session: F.sessionID)
        await open(store, QFx.single(request: "next-question"))
        let e = try entry(store)
        #expect(e.question.key.requestID == "next-question" && e.phase == .open && e.summary == nil, "새 카드를 보인다 (적용하지 않는다)")
        #expect(ticker.pendingDelays.isEmpty)
        await quiet()
        #expect(gateway.answers.isEmpty, "D4bm-27: 서버 호출 0")
    }

    @Test func aQuestionThatClosedWhileHeldIsNeverSent() async throws {
        let store = makeStore()
        await open(store, F.single)
        store.choose(row: 0, session: F.sessionID)
        gateway.records = []
        store.sessionsRead([QFx.item()])
        await store.settle()
        #expect(store.entry(session: F.sessionID) == nil && ticker.pendingDelays.isEmpty)
        await quiet()
        #expect(gateway.answers.isEmpty, "다른 기기에서 먼저 답했다")
    }

    // MARK: 종류별 답

    @Test func anApprovalAnswersAllowOrDenyUnderTheApprovalID() async throws {
        for (row, word) in [(0, "allow"), (1, "deny")] {
            let g = FakeAgentQuestionGateway()
            let t = ManualTicker()
            let store = AgentQuestionStore(gateway: g, scope: scope, sleep: { await t.sleep($0) })
            store.thisMacBridgeID = F.bridgeID
            g.records = [QFx.record(F.approvalEdit)]
            store.sessionsRead([QFx.item()])
            await store.settle()
            store.choose(row: row, session: F.sessionID)
            #expect(try #require(store.entry(session: F.sessionID)).summary == (row == 0 ? "Allow" : "Deny"))
            await fire(t)
            #expect(await eventually { g.answers.count == 1 })
            #expect(g.answers[0].request.answers == ["approval": .text(word)], "\(word)")
        }
    }

    @Test func multiSelectSendsTheCheckedLabelsAsAnArrayAndNeedsOne() async throws {
        let store = makeStore()
        await open(store, F.multi)
        store.sendChecked(session: F.sessionID)
        #expect(try entry(store).phase == .open, "하나라도 체크되기 전까지 보내지 않는다")
        store.toggle(row: 2, session: F.sessionID)
        store.toggle(row: 0, session: F.sessionID)
        store.toggle(row: 1, session: F.sessionID)
        store.toggle(row: 1, session: F.sessionID)
        #expect(try entry(store).checked == [0, 2])
        store.sendChecked(session: F.sessionID)
        #expect(try entry(store).summary == "Pro monthly, Lifetime")
        await fire()
        #expect(await eventually { gateway.answers.count == 1 })
        #expect(gateway.answers[0].request.answers == ["q1": .choices(["Pro monthly", "Lifetime"])])
    }

    @Test func theOtherRowOpensAFieldAndTheTypedTextIsTheAnswer() async throws {
        let store = makeStore()
        await open(store, F.otherThree)
        store.choose(row: 3, session: F.sessionID)
        let opened = try entry(store)
        #expect(opened.otherOpen && opened.phase == .open, "Other를 고르면 그 자리에서 입력 칸이 열린다")
        store.closeOther(session: F.sessionID)
        #expect(try !entry(store).otherOpen)
        store.choose(row: 3, session: F.sessionID)
        store.submitText("Lifetime, first", session: F.sessionID)
        #expect(try entry(store).phase == .holding)
        await fire()
        #expect(await eventually { gateway.answers.count == 1 })
        #expect(gateway.answers[0].request.answers == ["q1": .text("Lifetime, first")])
    }

    @Test func aTextOnlyQuestionTakesTheTextStraightAway() async throws {
        let store = makeStore()
        await open(store, F.textOnly)
        store.submitText("   ", session: F.sessionID)
        #expect(try entry(store).phase == .open, "빈 글은 답이 아니다")
        store.submitText(String(repeating: "가", count: 2_005), session: F.sessionID)
        await fire()
        #expect(await eventually { gateway.answers.count == 1 })
        guard case .text(let sent)? = gateway.answers.first?.request.answers["q1"] else { Issue.record("text expected"); return }
        #expect(sent.unicodeScalars.count == 2_000)
    }

    @Test func severalQuestionsGoOneAtATimeAndTheLastAnswerStartsTheHold() async throws {
        let store = makeStore()
        await open(store, F.several)
        let first = try entry(store)
        #expect(first.step == 0 && first.card.meta == "1 of 3 · outside the brief")
        store.choose(row: 2, session: F.sessionID)
        let second = try entry(store)
        #expect(second.step == 1 && second.phase == .open && ticker.pendingDelays.isEmpty, "앞 답은 앱에만 쌓는다: 보류도 요청도 없다")
        store.toggle(row: 0, session: F.sessionID)
        store.toggle(row: 2, session: F.sessionID)
        store.sendChecked(session: F.sessionID)
        let third = try entry(store)
        #expect(third.step == 2 && third.card.kind == .text)
        store.submitText("Start free", session: F.sessionID)
        let held = try entry(store)
        #expect(held.phase == .holding && held.summary == "Yearly total · Pro monthly, Lifetime · Start free")
        await fire()
        #expect(await eventually { gateway.answers.count == 1 })
        #expect(gateway.answers[0].request.answers == ["price": .text("Yearly total"), "plans": .choices(["Pro monthly", "Lifetime"]), "banner": .text("Start free")], "한 요청에 모든 답")
    }

    @Test func undoInSeveralQuestionsReturnsToTheLastQuestionAndKeepsTheEarlierAnswers() async throws {
        let store = makeStore()
        await open(store, F.several)
        store.choose(row: 0, session: F.sessionID)
        store.toggle(row: 1, session: F.sessionID)
        store.sendChecked(session: F.sessionID)
        store.submitText("First banner", session: F.sessionID)
        store.undo(session: F.sessionID)
        let e = try entry(store)
        #expect(e.phase == .open && e.step == 2 && e.card.kind == .text, "마지막 질문으로 돌아간다")
        store.submitText("Second banner", session: F.sessionID)
        await fire()
        #expect(await eventually { gateway.answers.count == 1 })
        #expect(gateway.answers[0].request.answers == ["price": .text("First-month price"), "plans": .choices(["Pro yearly"]), "banner": .text("Second banner")], "앞 답은 그대로, 마지막 답만 바뀐다")
    }

    // MARK: 실패 되돌림 (D4bm-21)

    private func failing(_ error: Error) async throws -> AgentQuestionStore {
        let store = makeStore()
        await open(store, F.single)
        gateway.onAnswer { _ in throw error }
        store.choose(row: 1, session: F.sessionID)
        await fire()
        return store
    }

    @Test func aDroppedConnectionBringsTheCardBackWithTheOfflineReason() async throws {
        let store = try await failing(APIError.transport("The Internet connection appears to be offline."))
        #expect(await eventually { store.entry(session: F.sessionID)?.phase == .open })
        let e = try entry(store)
        #expect(e.failure == .offline && e.failure?.reason == "You're offline. Try again." && e.summary == nil && e.card.kind == .single)
    }

    @Test func otherRefusalsBringTheCardBackWithTheGeneralReason() async throws {
        let refusals: [APIError] = [
            .server(status: 400, code: .invalidRequest, message: "답이 질문과 맞지 않습니다."), .server(status: 500, code: .internalError, message: ""),
            .server(status: 429, code: .rateLimited, message: ""), .server(status: 503, code: .internalError, message: ""), .unexpectedStatus(502), .decoding("x"),
        ]
        for error in refusals {
            let store = try await failing(error)
            #expect(await eventually { store.entry(session: F.sessionID)?.failure != nil }, "\(error)")
            let back = try entry(store)
            #expect(back.failure == .generic && back.failure?.reason == "Something went wrong. Try again in a moment.")
        }
    }

    @Test func aSecretRequiresLocalRefusalIsAnAppBugLoggedAsACodeOnly() async throws {
        let store = try await failing(APIError.server(status: 409, code: .secretRequiresLocal, message: "비밀값은 이 세션을 가진 Mac에서만 답할 수 있습니다."))
        #expect(await eventually { store.entry(session: F.sessionID)?.failure == .generic })
        #expect(logged.lines == ["question_answer_secret_requires_local"], "코드 이름뿐: 질문 글 · 답 · 서버 문구가 없다")
    }

    @Test func busyRetryRepeatsTheSameRequestExactlyOnce() async throws {
        let store = makeStore()
        await open(store, F.single)
        gateway.onAnswer { number in
            if number == 1 { throw APIError.server(status: 409, code: .busyRetry, message: "") }
            return AgentAnswerResponse(status: .answered, stepID: UUID())
        }
        store.choose(row: 0, session: F.sessionID)
        await fire()
        #expect(await eventually { store.entry(session: F.sessionID)?.phase == .sent })
        #expect(gateway.answers.count == 2 && gateway.answers[0] == gateway.answers[1], "같은 요청")
    }

    @Test func busyRetryTwiceGivesUpAndReturnsTheCard() async throws {
        let store = try await failing(APIError.server(status: 409, code: .busyRetry, message: ""))
        #expect(await eventually { store.entry(session: F.sessionID)?.failure == .generic })
        #expect(gateway.answers.count == 2, "한 번만 다시 보낸다")
    }

    @Test func aStaleOrMissingQuestionClearsTheCardAndRereads() async throws {
        for error in [APIError.server(status: 409, code: .questionStale, message: ""), .server(status: 404, code: .notFound, message: "")] {
            let g = FakeAgentQuestionGateway()
            let t = ManualTicker()
            let store = AgentQuestionStore(gateway: g, scope: scope, sleep: { await t.sleep($0) })
            store.thisMacBridgeID = F.bridgeID
            g.records = [QFx.record(F.single)]
            store.sessionsRead([QFx.item()])
            await store.settle()
            g.onAnswer { _ in throw error }
            // 서버는 이미 다른 질문을 쥐고 있다
            g.records = [QFx.record(QFx.single(request: "newer"))]
            store.choose(row: 0, session: F.sessionID)
            await fire(t)
            #expect(await eventually { store.entry(session: F.sessionID)?.question.key.requestID == "newer" }, "\(error)")
            #expect(g.reads.count == 2 && store.entry(session: F.sessionID)?.phase == .open, "카드를 지우고 다시 읽어 새 카드를 보인다")
        }
    }

    @Test func afterAFailureThePickCanBeRepeatedAndTheServerFoldsItAsDuplicate() async throws {
        let store = makeStore()
        await open(store, F.single)
        gateway.onAnswer { number in
            if number == 1 { throw APIError.transport("offline") }
            return AgentAnswerResponse(status: .duplicate, stepID: UUID())
        }
        store.choose(row: 2, session: F.sessionID)
        await fire()
        #expect(await eventually { store.entry(session: F.sessionID)?.failure == .offline })
        store.choose(row: 2, session: F.sessionID)
        #expect(try entry(store).failure == nil, "새로 고르면 실패 줄이 사라진다")
        await fire()
        #expect(await eventually { store.entry(session: F.sessionID)?.phase == .sent })
        #expect(gateway.answers.count == 2 && gateway.answers[0] == gateway.answers[1])
    }

    @Test func aFailedSendKeepsTheMultiSelectCheckedRowsAndTheTypedText() async throws {
        let store = makeStore()
        await open(store, F.multi)
        gateway.onAnswer { _ in throw APIError.transport("offline") }
        store.toggle(row: 0, session: F.sessionID)
        store.toggle(row: 2, session: F.sessionID)
        store.sendChecked(session: F.sessionID)
        await fire()
        #expect(await eventually { store.entry(session: F.sessionID)?.failure == .offline })
        #expect(try entry(store).checked == [0, 2], "다시 고르기 쉽게 체크를 남긴다")
    }

    // MARK: 계정 경계 · 종료

    @Test func leavingTheAccountWhileHeldDropsTheAnswerWithNoServerCall() async throws {
        let account = ChatTestAccount.fixedScope()
        let store = makeStore(scope: account)
        await open(store, F.single)
        store.choose(row: 0, session: F.sessionID)
        account.accountLeft()
        #expect(store.entries.isEmpty && ticker.pendingDelays.isEmpty)
        await quiet()
        #expect(gateway.answers.isEmpty)
    }

    @Test func aLateAnswerResponseAfterAnAccountChangeIsDropped() async throws {
        let account = ChatTestAccount.fixedScope()
        let store = makeStore(scope: account)
        var answered = 0
        store.onAnswered = { _, _ in answered += 1 }
        await open(store, F.single)
        let latch = Latch()
        gateway.holdNextAnswer(latch)
        store.choose(row: 0, session: F.sessionID)
        await fire()
        #expect(await latch.waitForArrivals(1, timeout: .seconds(3)))
        account.accountLeft()
        await latch.open()
        await quiet(120)
        #expect(store.entries.isEmpty && answered == 0, "떠난 계정의 늦은 응답은 새 상태를 만들지 않는다")
    }

    @Test func aLateQuestionReadAfterAnAccountChangeIsDropped() async throws {
        let account = ChatTestAccount.fixedScope()
        let store = makeStore(scope: account)
        let latch = Latch()
        gateway.records = [QFx.record(F.single)]
        gateway.holdNextRead(latch)
        store.sessionsRead([QFx.item()])
        #expect(await latch.waitForArrivals(1, timeout: .seconds(3)))
        account.accountLeft()
        await latch.open()
        await store.settle()
        #expect(store.entries.isEmpty)
    }

    @Test func quittingSendsTheHeldAnswerAtOnceWithoutWaitingTheTwoSeconds() async throws {
        let store = makeStore()
        await open(store, F.single)
        store.choose(row: 3, session: F.sessionID)
        #expect(store.hasHeldAnswers)
        await store.flushForQuit(timeout: 3)
        #expect(gateway.answers.count == 1 && gateway.answers[0].request.answers == ["q1": .text("Price per month")])
        #expect(!store.hasHeldAnswers && ticker.pendingDelays.isEmpty, "보류 시계는 걷혔다")
    }

    @Test func quittingStopsWaitingForASlowServerAfterTheTimeout() async throws {
        let store = makeStore()
        await open(store, F.single)
        let latch = Latch()
        gateway.holdNextAnswer(latch)
        store.choose(row: 0, session: F.sessionID)
        let done = ResultBox()
        let flush = Task { @MainActor in
            await store.flushForQuit(timeout: 3)
            done.set(true)
        }
        #expect(await latch.waitForArrivals(1, timeout: .seconds(3)), "곧바로 보냈다")
        #expect(await eventually { ticker.pendingDelays == [3.0] }, "기다림의 한도는 3초")
        #expect(!done.value)
        await fire()
        await flush.value
        #expect(done.value, "3초가 지나면 종료 응답으로 넘어간다")
        await latch.open()
    }

    @Test func quittingWithNothingHeldReturnsAtOnce() async throws {
        let store = makeStore()
        await open(store, F.single)
        #expect(!store.hasHeldAnswers)
        await store.flushForQuit(timeout: 3)
        #expect(gateway.answers.isEmpty && ticker.pendingDelays.isEmpty)
    }

    // MARK: 두 화면 · 키 · 포커스 · 알림

    @Test func twoSurfacesShareOneStateSoOneRequestGoesOut() async throws {
        let store = makeStore()
        await open(store, F.single)
        // 같은 세션의 Assistant 창 둘과 세션 패널은 같은 항목을 본다
        let surfaces = (0..<3).map { _ in store.entry(session: F.sessionID) }
        #expect(surfaces.allSatisfy { $0?.question.key == F.key() })
        store.choose(row: 0, session: F.sessionID)
        store.choose(row: 0, session: F.sessionID)
        #expect((0..<3).allSatisfy { _ in store.entry(session: F.sessionID)?.phase == .holding })
        await fire()
        #expect(await eventually { gateway.answers.count == 1 })
        await quiet()
        #expect(gateway.answers.count == 1)
    }

    @Test func escapeFirstClosesTheOtherFieldThenUndoesAHeldAnswerOnlyWhileTheCardHasFocus() async throws {
        let store = makeStore()
        await open(store, F.otherThree)
        #expect(!store.escape(session: F.sessionID), "열린 것이 없으면 Esc는 지나간다")
        store.choose(row: 3, session: F.sessionID)
        #expect(store.escape(session: F.sessionID), "① Other 입력 칸이면 줄로 되돌린다")
        #expect(try !entry(store).otherOpen)
        store.choose(row: 0, session: F.sessionID)
        #expect(!store.escape(session: F.sessionID), "② 카드에 포커스가 없으면 Undo가 아니다")
        #expect(try entry(store).phase == .holding)
        store.setCardFocus(true, session: F.sessionID)
        #expect(store.escape(session: F.sessionID), "카드에 포커스가 있으면 Undo")
        #expect(try entry(store).phase == .open)
        await quiet()
        #expect(gateway.answers.isEmpty)
    }

    @Test func aFocusRequestRaisesAPerSessionCounter() async throws {
        let store = makeStore()
        #expect(store.focusRequest(session: F.sessionID) == 0)
        store.requestFocus(session: F.sessionID)
        store.requestFocus(session: F.sessionID)
        #expect(store.focusRequest(session: F.sessionID) == 2 && store.focusRequest(session: QFx.secondSession) == 0)
    }

    @Test func aNewQuestionOnThisMacIsAnnouncedOncePerQuestionAndClearedWhenItCloses() async throws {
        let store = makeStore()
        var opened: [AgentQuestionOpened] = []
        var closed: [[AgentQuestionKey]] = []
        store.onOpened = { opened.append($0) }
        store.onClosed = { closed.append($0) }
        await open(store, F.single)
        store.sessionsRead([QFx.item()])
        await store.settle()
        #expect(opened.map(\.key) == [F.key()] && opened[0].sessionID == F.sessionID && opened[0].agentName == "Claude Code", "version마다 한 번")
        await open(store, QFx.single(request: "second"))
        #expect(opened.map(\.key.requestID) == [F.requestID, "second"] && closed == [[F.key()]], "바뀌면 앞 알림을 지운다")
        gateway.records = []
        store.sessionsRead([QFx.item()])
        await store.settle()
        #expect(closed.last == [AgentQuestionKey(taskID: F.taskID, requestID: "second")])
    }

    @Test func aQuestionOnAnotherMacIsNeverAnnouncedFromThisOne() async throws {
        let store = makeStore()
        var opened = 0
        store.onOpened = { _ in opened += 1 }
        await open(store, F.single, item: QFx.item(bridge: F.otherBridgeID))
        #expect(store.entry(session: F.sessionID) != nil && opened == 0, "같은 사용자의 Mac 여럿이 겹쳐 알리지 않는다")
        store.thisMacBridgeID = nil
        await open(store, QFx.single(request: "r2"), item: QFx.item(bridge: nil))
        #expect(opened == 0, "이 Mac을 모르면 다른 기기로 본다")
    }

    @Test func theSentRowGoesWhenTheServerRecordsAnEventLineWithTheAnswerKey() async throws {
        let key = F.key()
        #expect(AgentQuestionStore.sentEventKey(key) == "answer:\(F.taskID.uuidString.lowercased()):\(AgentQuestionRules.requestDigest(F.requestID))")
        #expect(AgentQuestionRules.requestDigest("toolu_01F2SecretLocalAnswer") == "0e558779236c0c8b12aad0b75364ec4a080b58bba3e5fb8795316522a2d08c4e", "F2의 알려진 digest와 같다")
        let store = makeStore()
        await open(store, F.single)
        store.choose(row: 0, session: F.sessionID)
        await fire()
        #expect(await eventually { store.entry(session: F.sessionID)?.phase == .sent })
        let e = try entry(store)
        #expect(!store.isRecorded(e, eventKeys: []) && !store.isRecorded(e, eventKeys: ["answer:other:key"]))
        #expect(store.isRecorded(e, eventKeys: [AgentQuestionStore.sentEventKey(key)]))
        var open = try entry(store)
        open.phase = .open
        #expect(!store.isRecorded(open, eventKeys: [AgentQuestionStore.sentEventKey(key)]), "접힌 줄이 아닌 카드는 사건 줄과 상관없다")
    }

    @Test func theSentRowGoesWhenTheQuestionLeavesTheReads() async throws {
        let store = makeStore()
        await open(store, F.single)
        store.choose(row: 0, session: F.sessionID)
        await fire()
        #expect(await eventually { store.entry(session: F.sessionID)?.phase == .sent })
        gateway.records = []
        store.sessionsRead([QFx.item(state: .running)])
        await store.settle()
        #expect(store.entry(session: F.sessionID) == nil)
    }

    @Test func aRememberedMacNameIsReadOnceAndCardsAreRebuiltWhenThisMacIsLearnedLater() async throws {
        let store = makeStore()
        store.thisMacBridgeID = nil
        gateway.names = [F.otherBridgeID: "Mina's MacBook Pro"]
        await open(store, F.secret, item: QFx.item(bridge: F.otherBridgeID))
        #expect(await eventually { store.entry(session: F.sessionID)?.card.macName == "Mina's MacBook Pro" })
        #expect(try entry(store).card.kind == .secretRemote && gateway.nameReads == [F.otherBridgeID])
        store.sessionsRead([QFx.item(bridge: F.otherBridgeID)])
        await store.settle()
        #expect(gateway.nameReads == [F.otherBridgeID], "이름은 한 번만 읽는다")
        // 이 Mac의 bridge id를 뒤늦게 알았다: 그 세션은 이 Mac의 것이다
        store.thisMacBridgeID = F.otherBridgeID
        #expect(try entry(store).card.kind == .secret)
    }

    @Test func aMacWithoutAnameLeavesTheNameEmptyForTheScreenToFill() async throws {
        let store = makeStore()
        store.thisMacBridgeID = nil
        await open(store, F.secret, item: QFx.item(bridge: F.otherBridgeID))
        await store.settle()
        let remote = try entry(store)
        #expect(remote.card.macName == nil && remote.card.kind == .secretRemote)
    }

    @Test func theComposerIsBlockedOnlyWhileASecretQuestionIsOpenAndNotYetSent() async throws {
        let store = makeStore(secrets: FakeSecretSubmitter())
        await open(store, F.single)
        #expect(!store.blocksComposer(session: F.sessionID), "일반 질문은 composer를 막지 않는다")
        await open(store, QFx.single(request: "s1").replacingOccurrences(of: "\"secret\":false", with: "\"secret\":true"))
        #expect(store.blocksComposer(session: F.sessionID) && !store.blocksComposer(session: QFx.secondSession), "다른 대화는 막지 않는다")
        await open(store, F.secret, item: QFx.item(bridge: F.otherBridgeID))
        #expect(store.blocksComposer(session: F.sessionID), "다른 기기에서도 막는다")
        store.thisMacBridgeID = F.bridgeID
        gateway.records = []
        store.sessionsRead([QFx.item(state: .running)])
        await store.settle()
        #expect(!store.blocksComposer(session: F.sessionID))
    }

    // MARK: 검토 1: 이전 전송의 늦은 응답 · 포커스 요청의 수명

    @Test func aLateResponseOfAnOlderSendNeverRemovesTheNewerSendsQuitWait() async throws {
        let store = makeStore()
        var answered = 0
        store.onAnswered = { _, _ in answered += 1 }
        await open(store, F.single)
        let first = Latch()
        gateway.holdNextAnswer(first)
        store.choose(row: 0, session: F.sessionID)
        await fire()
        #expect(await first.waitForArrivals(1, timeout: .seconds(3)), "Q1의 응답이 느리다")
        // 그 사이 서버가 다른 질문(Q2)을 보인다. 사용자가 Q2에 답해 그 전송도 가는 중이다
        await open(store, QFx.single(request: "second"))
        #expect(try entry(store).key.requestID == "second" && (try entry(store).phase) == .open)
        let second = Latch()
        gateway.holdNextAnswer(second)
        store.choose(row: 1, session: F.sessionID)
        await fire()
        #expect(await second.waitForArrivals(1, timeout: .seconds(3)), "Q2도 가는 중이다")
        // Q1의 응답이 이제 온다
        await first.open()
        #expect(await eventually { answered == 1 }, "Q1의 늦은 응답이 처리됐다")
        // 종료: Q2가 아직 가는 중이니 기다려야 한다 (Q1의 끝이 Q2의 기다림을 지우면 곧바로 돌아와 답을 잃는다)
        let done = ResultBox()
        let flush = Task { @MainActor in
            await store.flushForQuit(timeout: 3)
            done.set(true)
        }
        #expect(await eventually { ticker.pendingDelays == [3.0] }, "Q2의 끝이나 한도(3초)까지 기다린다")
        #expect(!done.value)
        await second.open()
        await flush.value
        #expect(done.value && gateway.answers.count == 2)
    }

    @Test func aFocusRequestOnlyCountsForTheQuestionThatWasOpenWhenItWasMade() async throws {
        let store = makeStore()
        await open(store, F.single)
        #expect(store.pendingFocusRequests(session: F.sessionID) == 0, "요청이 없으면 카드는 포커스를 가져가지 않는다")
        store.requestFocus(session: F.sessionID)
        #expect(store.pendingFocusRequests(session: F.sessionID) == 1)
        await open(store, QFx.single(request: "second"))
        #expect(store.focusRequest(session: F.sessionID) == 1 && store.pendingFocusRequests(session: F.sessionID) == 0, "앞 질문 때 누른 링이 새 질문 카드의 포커스가 되지 않는다")
        store.requestFocus(session: F.sessionID)
        #expect(store.pendingFocusRequests(session: F.sessionID) == 1)
    }

    @Test func aRequestMadeBeforeTheCardExistedStillGoesToTheCardThatOpensForIt() async throws {
        let store = makeStore()
        store.requestFocus(session: F.sessionID)
        await open(store, F.single)
        #expect(store.pendingFocusRequests(session: F.sessionID) == 1, "링을 누른 뒤 질문 읽기가 끝났다: 그 카드가 받는다")
        // 질문이 없는 읽기는 아직 안 쓴 요청을 버린다 (한참 뒤의 질문이 훔치지 않게)
        let other = makeStore()
        other.requestFocus(session: F.sessionID)
        gateway.records = []
        other.sessionsRead([QFx.item()])
        await other.settle()
        await open(other, F.single)
        #expect(other.pendingFocusRequests(session: F.sessionID) == 0)
    }

}

/// 값을 시험 밖으로 꺼내는 작은 상자
final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.withLock { _value } }
    func set(_ value: Bool) { lock.withLock { _value = value } }
}
