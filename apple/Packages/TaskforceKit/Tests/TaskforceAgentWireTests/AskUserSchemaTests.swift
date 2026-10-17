#if os(macOS)
import Foundation
import Testing
@testable import TaskforceAgentWire

/// `ask_user` 입력 검사 (OA D3a 계약 3.3): 서버 질문 모양(D2a `bridgeV1QuestionSchema`)에 담을 수 없는 것은 모델에게 고칠 점을 돌려준다
struct AskUserSchemaTests {
    static func validate(_ text: String) throws -> Result<[AskUserSchema.Question], AskUserSchema.Problem> {
        AskUserSchema.validate(try WireJSON.parse(Data(text.utf8)))
    }

    @Test func aValidCallBecomesQuestionsWithDefaults() throws {
        let result = try Self.validate(#"{"questions":[{"id":"color","header":"Color","text":"Which color?","options":[{"label":"red","description":"warm"},{"label":"blue"}],"multi_select":true},{"id":"key","text":"API key?","secret":true}]}"#)
        let questions = try result.get()
        #expect(questions.count == 2)
        #expect(questions[0] == AskUserSchema.Question(id: "color", header: "Color", text: "Which color?", options: [.init(label: "red", description: "warm"), .init(label: "blue", description: "")], multiSelect: true, allowOther: false, secret: false))
        #expect(questions[1] == AskUserSchema.Question(id: "key", header: "", text: "API key?", options: [], multiSelect: false, allowOther: false, secret: true))
    }

    @Test func modelAnswersAreIgnoredByTheCheck() throws {
        #expect(try Self.validate(#"{"questions":[{"id":"a","text":"?"}],"answers":{"a":"from the model"}}"#).get().count == 1)
    }

    @Test func shapesTheServerCannotHoldComeBackAsProblems() throws {
        let cases: [String] = [
            #"{}"#,
            #"{"questions":[]}"#,
            #"{"questions":[{"id":"a","text":"1"},{"id":"b","text":"2"},{"id":"c","text":"3"},{"id":"d","text":"4"},{"id":"e","text":"5"}]}"#,
            #"{"questions":[{"id":"a","text":"1"},{"id":"a","text":"2"}]}"#,
            #"{"questions":[{"id":"","text":"1"}]}"#,
            #"{"questions":[{"id":"a"}]}"#,
            #"{"questions":[{"id":"a","text":""}]}"#,
            #"{"questions":[{"id":"a","text":"x","options":[{"label":"1"},{"label":"2"},{"label":"3"},{"label":"4"},{"label":"5"},{"label":"6"},{"label":"7"},{"label":"8"},{"label":"9"},{"label":"10"},{"label":"11"}]}]}"#,
            #"{"questions":[{"id":"a","text":"x","options":[{"label":"same"},{"label":"same"}]}]}"#,
            #"{"questions":[{"id":"a","text":"x","multi_select":true}]}"#,
            #"{"questions":[{"id":"a","text":"x","multiSelect":true}]}"#,
            #"{"questions":[{"id":"a","text":"x"}],"question":"legacy"}"#,
            #"{"questions":"not a list"}"#,
            #"{"questions":[{"id":"a","text":"x","secret":"yes"}]}"#,
            #"{"questions":[{"id":"a\u0000b","text":"x"}]}"#,
            #"{"questions":[{"id":"a","text":"x","options":[{"label":""}]}]}"#,
        ]
        for text in cases {
            guard case .failure(let problem) = try Self.validate(text) else {
                Issue.record("accepted: \(text)")
                continue
            }
            #expect(!problem.message.isEmpty)
        }
    }

    @Test func lengthLimitsCountUnicodeScalarsLikeTheServer() throws {
        let atLimit = String(repeating: "가", count: AskUserSchema.maxTextChars)
        #expect(throws: Never.self) { try Self.validate(#"{"questions":[{"id":"a","text":"\#(atLimit)"}]}"#).get() }
        let over = atLimit + "가"
        #expect(throws: AskUserSchema.Problem.self) { try Self.validate(#"{"questions":[{"id":"a","text":"\#(over)"}]}"#).get() }
        let header = String(repeating: "h", count: AskUserSchema.maxHeaderChars + 1)
        #expect(throws: AskUserSchema.Problem.self) { try Self.validate(#"{"questions":[{"id":"a","header":"\#(header)","text":"x"}]}"#).get() }
        let id = String(repeating: "i", count: AskUserSchema.maxIDChars + 1)
        #expect(throws: AskUserSchema.Problem.self) { try Self.validate(#"{"questions":[{"id":"\#(id)","text":"x"}]}"#).get() }
        let label = String(repeating: "l", count: AskUserSchema.maxLabelChars + 1)
        #expect(throws: AskUserSchema.Problem.self) { try Self.validate(#"{"questions":[{"id":"a","text":"x","options":[{"label":"\#(label)"}]}]}"#).get() }
        let description = String(repeating: "d", count: AskUserSchema.maxDescriptionChars + 1)
        #expect(throws: AskUserSchema.Problem.self) { try Self.validate(#"{"questions":[{"id":"a","text":"x","options":[{"label":"l","description":"\#(description)"}]}]}"#).get() }
    }

    @Test func theLimitsAreTheServerQuestionLimits() {
        // contract.ts D2a `bridgeV1QuestionSchema`: 질문 1–4 · 선택지 ≤ 10 · id 200 · header 200 · text 4000 · label 500 · description 1000 (Kit `Outbox.fit`과 같은 수)
        #expect(AskUserSchema.maxQuestions == 4)
        #expect(AskUserSchema.maxOptions == 10)
        #expect(AskUserSchema.maxIDChars == 200)
        #expect(AskUserSchema.maxHeaderChars == 200)
        #expect(AskUserSchema.maxTextChars == 4000)
        #expect(AskUserSchema.maxLabelChars == 500)
        #expect(AskUserSchema.maxDescriptionChars == 1000)
    }
}
#endif
