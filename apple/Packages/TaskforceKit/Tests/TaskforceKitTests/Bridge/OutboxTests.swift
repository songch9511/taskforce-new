#if os(macOS)
import Foundation
import Testing
@testable import TaskforceKit

/// outbox 정책 (OA D2b 계약 2.7 · 4.1 K4): 글 자르기 · 질문 상한 · 묶음 고르기 · 응답 분류 · 다시 보내기 간격
struct OutboxTests {
    private let t0 = BridgeTest.t0

    // MARK: 글 자르기 (32KB UTF-8, 유니코드 스칼라 경계)

    @Test func textWithinTheLimitIsSentAsIs() {
        let text = String(repeating: "a", count: 32_768)
        let fit = Outbox.fit(text: text)
        #expect(fit.sent == text && fit.full == nil)
    }

    @Test func koreanTextIsCutOnAScalarBoundaryAndKeepsTheFullTextForViewFull() {
        let text = String(repeating: "한", count: 11_000) // 33,000 bytes
        let fit = Outbox.fit(text: text)
        #expect(fit.sent.utf8.count <= 32_768)
        #expect(fit.sent.utf8.count == 32_766)
        #expect(text.hasPrefix(fit.sent))
        #expect(fit.full == text)
    }

    @Test func emojiAtTheBoundaryAreNeverSplit() {
        let exact = String(repeating: "🙂", count: 8192)
        #expect(Outbox.fit(text: exact).full == nil && Outbox.fit(text: exact).sent.utf8.count == 32_768)
        let over = String(repeating: "🙂", count: 8193)
        let fit = Outbox.fit(text: over)
        #expect(fit.sent.utf8.count == 32_768 && fit.sent.unicodeScalars.count == 8192)
        #expect(fit.full == over)
    }

    @Test func aMultiByteScalarThatWouldCrossTheLimitIsDroppedWholeNotHalved() {
        let text = String(repeating: "a", count: 32_767) + "한" // 32,770 bytes
        let fit = Outbox.fit(text: text)
        #expect(fit.sent == String(repeating: "a", count: 32_767))
        #expect(fit.full == text)
    }

    @Test func aNulCharacterIsReplacedBecauseTheServerJSONBColumnRejectsIt() {
        let fit = Outbox.fit(text: "a\u{0}b")
        #expect(fit.sent == "a\u{FFFD}b" && fit.full == nil)
        let long = Outbox.fit(text: "a\u{0}" + String(repeating: "b", count: 40_000))
        #expect(!long.sent.unicodeScalars.contains("\u{0}") && !(long.full ?? "").unicodeScalars.contains("\u{0}"))
    }

    // MARK: 질문 상한 (Q15)

    private func question(
        request: String = "req-1", items: [AgentQuestionItem] = [AgentQuestionItem(id: "q1", header: "H", text: "T", options: [AgentQuestionOption(label: "A", description: "a")])]
    ) -> AgentQuestion {
        AgentQuestion(providerRequestID: request, kind: .input, structured: true, text: "Which?", items: items)
    }

    private func fits(_ result: Outbox.QuestionFit) -> (BridgeV1Question, Outbox.QuestionMap)? {
        if case .fits(let question, let map) = result { return (question, map) }
        return nil
    }

    @Test func aQuestionWithinTheLimitsIsSentUnchangedWithAnEmptyMap() throws {
        let (sent, map) = try #require(fits(Outbox.fit(question: question(), taskID: "t", observedAt: t0)))
        #expect(sent.providerRequestID == "req-1" && sent.questions.count == 1 && sent.questions[0].options[0].label == "A")
        #expect(map.isEmpty)
    }

    @Test func overlongFieldsAreCutAndLabelsAndIDsAreRememberedForTheAnswer() throws {
        let longLabel = String(repeating: "L", count: 600)
        let longID = String(repeating: "i", count: 250)
        let item = AgentQuestionItem(
            id: longID, header: String(repeating: "h", count: 300), text: String(repeating: "t", count: 5000),
            options: [AgentQuestionOption(label: longLabel, description: String(repeating: "d", count: 2000))], multiSelect: true, allowOther: true, secret: false
        )
        let (sent, map) = try #require(fits(Outbox.fit(question: question(items: [item]), taskID: "t", observedAt: t0)))
        let cut = sent.questions[0]
        #expect(cut.id.unicodeScalars.count == 200 && cut.header.unicodeScalars.count == 200)
        #expect(cut.text.unicodeScalars.count == 4000 && cut.options[0].label.unicodeScalars.count == 500 && cut.options[0].description.unicodeScalars.count == 1000)
        #expect(cut.multiSelect && cut.allowOther && !cut.secret)
        #expect(map.ids[cut.id] == longID)
        #expect(map.labels[cut.options[0].label] == longLabel)
    }

    @Test func anAnswerToACutQuestionGoesBackWithTheOriginalValues() {
        let map = Outbox.QuestionMap(ids: ["idcut": "idcut-original"], labels: ["labelcut": "labelcut-original"])
        let answers: [String: BridgeV1AnswerValue] = ["idcut": .one("labelcut"), "plain": .many(["labelcut", "free text"])]
        let restored = Outbox.originalAnswers(answers, map: map)
        #expect(restored["idcut-original"] == .one("labelcut-original"))
        #expect(restored["plain"] == .many(["labelcut-original", "free text"]))
        #expect(restored["idcut"] == nil)
    }

    @Test func tooManyQuestionsOrOptionsOrAnUnusableRequestIDCannotBeRepresented() {
        func unrepresentable(_ result: Outbox.QuestionFit) -> Bool { if case .unrepresentable = result { true } else { false } }
        let item = { (id: String) in AgentQuestionItem(id: id, header: "", text: "", options: []) }
        #expect(unrepresentable(Outbox.fit(question: question(items: (1...5).map { item("q\($0)") }), taskID: "t", observedAt: t0)))
        #expect(!unrepresentable(Outbox.fit(question: question(items: (1...4).map { item("q\($0)") }), taskID: "t", observedAt: t0)))
        #expect(unrepresentable(Outbox.fit(question: question(items: []), taskID: "t", observedAt: t0)))
        let eleven = AgentQuestionItem(id: "q", header: "", text: "", options: (1...11).map { AgentQuestionOption(label: "o\($0)", description: "") })
        #expect(unrepresentable(Outbox.fit(question: question(items: [eleven]), taskID: "t", observedAt: t0)))
        let ten = AgentQuestionItem(id: "q", header: "", text: "", options: (1...10).map { AgentQuestionOption(label: "o\($0)", description: "") })
        #expect(!unrepresentable(Outbox.fit(question: question(items: [ten]), taskID: "t", observedAt: t0)))
        #expect(unrepresentable(Outbox.fit(question: question(request: ""), taskID: "t", observedAt: t0)))
        #expect(unrepresentable(Outbox.fit(question: question(request: String(repeating: "r", count: 201)), taskID: "t", observedAt: t0)))
    }

    @Test func idsThatCollideAfterCuttingCannotBeRepresented() {
        let base = String(repeating: "x", count: 200)
        let items = [AgentQuestionItem(id: base + "1", header: "", text: "", options: []), AgentQuestionItem(id: base + "2", header: "", text: "", options: [])]
        guard case .unrepresentable = Outbox.fit(question: question(items: items), taskID: "t", observedAt: t0) else {
            Issue.record("colliding ids must not be sent")
            return
        }
    }

    @Test func aQuestionOverThe32KBJSONLimitIsShrunkUntilItFits() throws {
        let items = (1...4).map { index in
            AgentQuestionItem(id: "q\(index)", header: "H", text: String(repeating: "한", count: 4000), options: [AgentQuestionOption(label: "A", description: String(repeating: "설", count: 1000))])
        }
        let big = question(items: items)
        let (sent, _) = try #require(fits(Outbox.fit(question: big, taskID: "7a5c0001-0000-4000-8000-000000000001", observedAt: t0)))
        #expect(Outbox.jsonbByteCount(of: sent, taskID: "7a5c0001-0000-4000-8000-000000000001", observedAt: t0) <= 32_768)
        #expect(sent.questions.map(\.id) == ["q1", "q2", "q3", "q4"])
        #expect(sent.questions[0].text.unicodeScalars.count < 4000)
    }

    @Test func aQuestionThatCannotShrinkEnoughIsUnrepresentable() {
        let heavyOption = { (id: String) in
            AgentQuestionItem(id: id, header: "", text: "", options: (1...10).map { AgentQuestionOption(label: String(repeating: "라", count: 500) + String($0), description: "") })
        }
        guard case .unrepresentable = Outbox.fit(question: question(items: (1...4).map { heavyOption("q\($0)") }), taskID: "t", observedAt: t0) else {
            Issue.record("labels cannot be shrunk below the answer-matching values")
            return
        }
    }

    // MARK: 묶음 고르기

    private func row(_ key: Int64, session: String = "s1", bytes: Int = 100, next: Date? = nil, dead: String? = nil) -> OutboxRow {
        OutboxRow(
            key: key, eventID: "e\(key)", agentSessionID: session, agentTaskID: "t", seq: Int(key), type: "progress", bodyJSON: "{}", bytes: bytes,
            observedAt: t0, attempts: 0, nextAttemptAt: next ?? t0, lastStatus: nil, deadReason: dead
        )
    }

    @Test func aBatchHoldsAtMostOneHundredEventsInInsertionOrder() {
        let rows = (1...250).map { row(Int64($0)) }
        let batch = Outbox.selectBatch(from: rows, now: t0)
        #expect(batch.count == 100)
        #expect(batch.map(\.key) == (1...100).map(Int64.init))
    }

    @Test func aBatchStaysUnder900KBIncludingTheEnvelope() {
        let rows = (1...10).map { row(Int64($0), bytes: 100_000) }
        let batch = Outbox.selectBatch(from: rows, now: t0)
        #expect(batch.count == 8)
        let total = batch.reduce(Outbox.batchOverheadBytes) { $0 + $1.bytes + 1 }
        #expect(total <= Outbox.maxBatchBytes)
    }

    @Test func theFirstEventIsAlwaysSentSoALargeEventCannotJamTheQueue() {
        let batch = Outbox.selectBatch(from: [row(1, bytes: 950_000), row(2, bytes: 100)], now: t0)
        #expect(batch.map(\.key) == [1])
    }

    @Test func aSessionWithARowNotYetDueSendsNothingBehindIt() {
        let later = t0.addingTimeInterval(30)
        let rows = [row(1, session: "a", next: later), row(2, session: "a"), row(3, session: "b"), row(4, session: "a")]
        let batch = Outbox.selectBatch(from: rows, now: t0)
        #expect(batch.map(\.key) == [3])
        #expect(Outbox.selectBatch(from: rows, now: later).map(\.key) == [1, 2, 3, 4])
    }

    @Test func deadLettersAreNeverSentAndDoNotBlockTheSessionBehindThem() {
        let rows = [row(1, dead: "invalid"), row(2)]
        #expect(Outbox.selectBatch(from: rows, now: t0).map(\.key) == [2])
    }

    @Test func halvingKeepsOrderAndNeverReturnsAnEmptyHalfForTwoOrMore() {
        let (first, second) = Outbox.halves((1...5).map { row(Int64($0)) })
        #expect(first.map(\.key) == [1, 2] && second.map(\.key) == [3, 4, 5])
    }

    // MARK: 응답 분류

    @Test func theThreeAuthoritativeListsDecideWhatIsDeletedKeptOrDropped() throws {
        let batch = [row(1), row(2), row(3), row(4)]
        let response = try JSONDecoder().decode(
            BridgeV1EventsResponse.self,
            from: Data(#"{"results":[],"accepted_event_ids":["e1"],"retry_event_ids":["e2"],"rejected":[{"event_id":"e3","code":"invalid"}]}"#.utf8)
        )
        let outcome = Outbox.disposition(of: response, batch: batch)
        #expect(outcome.delivered == [1])
        #expect(outcome.retry == [2, 4], "e4는 어느 목록에도 없다: 지우지 않고 남긴다")
        #expect(outcome.dead == [3])
    }

    @Test func resultStatusesAreDiagnosticOnlyAndNeverDeleteAnything() throws {
        let batch = [row(1)]
        let response = try JSONDecoder().decode(
            BridgeV1EventsResponse.self,
            from: Data(#"{"results":[{"event_id":"e1","status":"applied"}],"accepted_event_ids":[],"retry_event_ids":[],"rejected":[]}"#.utf8)
        )
        let outcome = Outbox.disposition(of: response, batch: batch)
        #expect(outcome.delivered.isEmpty && outcome.retry == [1])
    }

    // MARK: 다시 보내기 간격

    @Test func backoffDoublesFromOneSecondToACapOfSixtyWithTwentyPercentJitter() {
        #expect((0...8).map { Outbox.backoff(attempts: $0) } == [1, 2, 4, 8, 16, 32, 60, 60, 60])
        #expect(Outbox.backoff(attempts: 3, jitter: 0.2) == 9.6)
        #expect(Outbox.backoff(attempts: 3, jitter: -0.2) == 6.4)
        #expect(Outbox.backoff(attempts: 100) == 60)
    }
}
#endif
