import Foundation
import Testing
@testable import TaskforceKit

/// 열린 질문 읽기의 모양 (OA D4b-m-1, 계약 5장 · 11.1): 서버 검증 모양을 그대로 읽고, 모르는 모양은 카드 없이 조용히 버린다 (크래시 0 · 질문 글 로그 0).
struct AgentQuestionModelsTests {
    typealias F = AgentQuestionFixtures

    private func question(_ json: String) -> AgentPendingQuestion? {
        AgentPendingQuestion(json: Data(json.utf8), taskID: F.taskID)
    }

    // MARK: 서버 검증 모양

    @Test func aSingleQuestionIsReadWithItsKeyAndPrompts() throws {
        let q = try #require(question(F.single))
        #expect(q.key == F.key() && q.kind == .input && q.structured)
        #expect(q.prompts.count == 1 && q.prompts[0].id == "q1" && q.prompts[0].header == "outside the brief")
        #expect(q.prompts[0].options.map(\.label) == ["First-month price", "Monthly price", "Yearly total", "Price per month"])
        #expect(!q.prompts[0].multiSelect && !q.prompts[0].allowOther && !q.prompts[0].secret && !q.hasSecret)
    }

    @Test func everyShapeTheServerAllowsIsRead() throws {
        #expect(try #require(question(F.multi)).prompts[0].multiSelect)
        let other = try #require(question(F.otherThree))
        #expect(other.prompts[0].allowOther && other.prompts[0].options.count == 3)
        #expect(try #require(question(F.textOnly)).prompts[0].options.isEmpty)
        let several = try #require(question(F.several))
        #expect(several.prompts.map(\.id) == ["price", "plans", "banner"])
        #expect(try #require(question(F.secret)).hasSecret)
        let mixed = try #require(question(F.secretMixed))
        #expect(mixed.prompts.map(\.secret) == [false, true] && mixed.hasSecret, "하나라도 비밀값이면 요청 전체가 비밀값이다")
    }

    @Test func anApprovalIsOneQuestionWithAllowAndDenyAndTheAdapterTextAsReceived() throws {
        let edit = try #require(question(F.approvalEdit))
        #expect(edit.kind == .approval && edit.prompts.count == 1 && edit.prompts[0].id == "approval")
        #expect(edit.prompts[0].header == "Edit file" && edit.prompts[0].text == "Edit src/content/pricing.mdx")
        #expect(edit.prompts[0].options.map(\.label) == ["Allow", "Deny"])
        let run = try #require(question(F.approvalRunWithReason))
        #expect(run.prompts[0].text == "Run: npm run build\nContains a secret value", "앱은 받은 글을 고치지 않는다")
    }

    @Test func optionDescriptionsAreKeptForTooltipsAndAccessibility() throws {
        let q = try #require(question(F.singleWithDescriptions))
        #expect(q.prompts[0].options.map(\.description) == ["Drop the Lifetime section for Thursday", ""])
    }

    @Test func theAskedAtTimeIsReadWhenItParsesAndIsNotRequired() throws {
        let q = try #require(question(F.single))
        #expect(q.askedAt != nil)
        let bad = F.pending(prompts: [F.prompt()], asked: "yesterday")
        #expect(question(bad)?.askedAt == nil, "시각을 못 읽어도 질문은 읽는다")
    }

    // MARK: 모르는 · 깨진 모양 → 카드 없음

    @Test func unknownOrBrokenShapesAreNotReadAndNeverCrash() {
        let broken = [
            F.unknownKind, F.noQuestions, F.fiveQuestions, F.elevenOptions, F.keyMismatch, F.keyForAnotherTask, F.approvalWithWrongID,
            F.approvalWithOneOption, F.missingField, "{}", "[]", "null", "\"text\"", "not json",
        ]
        for json in broken { #expect(question(json) == nil, "\(json.prefix(60))") }
    }

    @Test func limitsMatchTheServerSoALongQuestionStillReads() throws {
        let longText = String(repeating: "가", count: 4_000)
        let longLabel = String(repeating: "L", count: 500)
        let q = try #require(question(F.pending(prompts: [F.prompt(text: longText, options: [(longLabel, "")])])))
        #expect(q.prompts[0].text.count == 4_000 && q.prompts[0].options[0].label.count == 500)
        let ten = try #require(question(F.pending(prompts: [F.prompt(options: (1...10).map { ("Option \($0)", "") })])))
        #expect(ten.prompts[0].options.count == 10)
        let four = try #require(question(F.pending(prompts: (1...4).map { F.prompt(id: "q\($0)") })))
        #expect(four.prompts.count == 4)
    }

    // MARK: agent_tasks 행

    @Test func aTaskRowCarriesTheQuestionAndItsTaskID() throws {
        let record = try TaskforceJSON.decoder().decode(AgentQuestionRecord.self, from: Data(F.row(pending: F.single).utf8))
        #expect(record.taskID == F.taskID && record.sessionID == F.sessionID && record.turnSeq == 1 && record.state == .awaitingAnswer)
        #expect(record.question?.key == F.key() && !record.isMalformed)
    }

    @Test func aRowWithoutAQuestionHasNoCardAndIsNotMalformed() throws {
        let record = try TaskforceJSON.decoder().decode(AgentQuestionRecord.self, from: Data(F.row(pending: nil).utf8))
        #expect(record.question == nil && !record.isMalformed)
    }

    @Test func aRowWithABrokenQuestionStillDecodesAndIsFlagged() throws {
        let record = try TaskforceJSON.decoder().decode(AgentQuestionRecord.self, from: Data(F.row(pending: F.unknownKind).utf8))
        #expect(record.question == nil && record.isMalformed, "한 행의 깨진 질문이 다른 세션의 질문 읽기를 막지 않는다")
        let second = UUID()
        let rows = try TaskforceJSON.decoder().decode([AgentQuestionRecord].self, from: Data("[\(F.row(pending: F.unknownKind)),\(F.row(pending: F.pending(prompts: [F.prompt()], task: second), task: second, session: UUID()))]".utf8))
        #expect(rows.count == 2 && rows[0].isMalformed && rows[1].question != nil)
    }

    @Test func theRowColumnsNameExactlyTheFiveFieldsAndUnknownStatesStayReadable() throws {
        #expect(AgentQuestionRecord.columns == "id, agent_session_id, turn_seq, state, pending_question")
        let unknown = try TaskforceJSON.decoder().decode(AgentQuestionRecord.self, from: Data(F.row(pending: nil, state: "from_the_future").utf8))
        #expect(unknown.state == .unknown("from_the_future"))
    }

    /// U2의 열 목록은 질문 글을 읽지 않는다 (계약 2.1-1: 새 파일로 따로 읽는다)
    @Test func theSessionTaskColumnsStillDoNotReadTheQuestionText() {
        #expect(!AgentTaskRecord.columns.contains("pending_question"))
        #expect(!AgentSessionRecord.columns.contains("pending_question"))
    }

    // MARK: 열쇠

    @Test func theKeyIsTheTaskAndTheProviderRequestAndNothingElse() {
        let a = AgentQuestionKey(taskID: F.taskID, requestID: "r1")
        #expect(a == AgentQuestionKey(taskID: F.taskID, requestID: "r1"))
        #expect(a != AgentQuestionKey(taskID: F.taskID, requestID: "r2"))
        #expect(a != AgentQuestionKey(taskID: UUID(), requestID: "r1"))
    }

    // MARK: 비밀값 상자

    @Test func aSecretIsNeverPrintedDumpedOrMirrored() {
        let canary = "DO_NOT_STORE_SECRET_D4BM"
        let box = SecretBox(canary)
        #expect(!"\(box)".contains(canary) && !String(reflecting: box).contains(canary) && !String(describing: Mirror(reflecting: box).children.map { "\($0.value)" }).contains(canary))
        var text = ""
        dump(box, to: &text)
        #expect(!text.contains(canary), "dump에도 값이 없다")
        #expect(box.reveal() == canary)
        let answer = LocalSecretAnswer(key: F.key(), answers: ["token": .secret(box), "env": .plain(.text("Staging"))])
        #expect(!"\(answer)".contains(canary) && !String(reflecting: answer).contains(canary))
    }
}
