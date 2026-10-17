#if os(macOS)
import Foundation

/// Taskforce MCP 도구 `ask_user`의 입력 모양과 검사 (OA D3a 계약 3.3).
/// 질문 모양 · 상한은 서버 D2a `bridgeV1QuestionSchema`(contract.ts) · Kit `Outbox.fit`과 같은 수다 — 서버에 담을 수 없는 질문은 훅에서 deny로 돌려보내 모델이 바로 고치게 한다
/// (defer 뒤에 닫히는 것보다 낫다). 글자 수는 유니코드 스칼라로 센다 (서버 `Array.from`)
public enum AskUserSchema {
    public static let serverName = "tf"
    public static let toolName = "ask_user"
    public static let qualifiedName = "mcp__tf__ask_user"

    public static let maxQuestions = 4
    public static let maxOptions = 10
    public static let maxIDChars = 200
    public static let maxHeaderChars = 200
    public static let maxTextChars = 4000
    public static let maxLabelChars = 500
    public static let maxDescriptionChars = 1000

    public struct Option: Equatable, Sendable {
        public var label: String
        public var description: String

        public init(label: String, description: String) {
            self.label = label
            self.description = description
        }
    }

    public struct Question: Equatable, Sendable {
        public var id: String
        public var header: String
        public var text: String
        public var options: [Option]
        public var multiSelect: Bool
        public var allowOther: Bool
        public var secret: Bool

        public init(id: String, header: String, text: String, options: [Option], multiSelect: Bool, allowOther: Bool, secret: Bool) {
            self.id = id
            self.header = header
            self.text = text
            self.options = options
            self.multiSelect = multiSelect
            self.allowOther = allowOther
            self.secret = secret
        }
    }

    /// 모델에게 돌려줄 고칠 점 (영어 상수 조합. 모델의 글을 되풀이하지 않는다)
    public struct Problem: Error, Equatable, Sendable {
        public let message: String

        init(_ message: String) {
            self.message = "ask_user was not sent: \(message) Fix the call and try again."
        }
    }

    static let topKeys: Set<String> = ["questions", "answers"]
    static let questionKeys: Set<String> = ["id", "header", "text", "options", "multi_select", "allow_other", "secret"]
    static let optionKeys: Set<String> = ["label", "description"]

    /// 입력을 검사해 질문으로 바꾼다. 모델이 넣은 `answers`는 보지 않는다 (bridge 답만 쓴다, 사례 7-05)
    public static func validate(_ input: WireJSON) -> Result<[Question], Problem> {
        guard case .object(let fields) = input else { return .failure(Problem("The input must be an object.")) }
        guard Set(fields.keys).isSubset(of: topKeys) else { return .failure(Problem("Only the field questions is allowed.")) }
        guard case .array(let items)? = fields["questions"] else { return .failure(Problem("questions must be a list.")) }
        guard (1...maxQuestions).contains(items.count) else { return .failure(Problem("Ask 1 to \(maxQuestions) questions.")) }
        var questions: [Question] = []
        for item in items {
            switch question(item) {
            case .success(let question): questions.append(question)
            case .failure(let problem): return .failure(problem)
            }
        }
        guard Set(questions.map(\.id)).count == questions.count else { return .failure(Problem("Each question id must be unique.")) }
        return .success(questions)
    }

    static func question(_ item: WireJSON) -> Result<Question, Problem> {
        guard case .object(let fields) = item else { return .failure(Problem("Each question must be an object.")) }
        guard Set(fields.keys).isSubset(of: questionKeys) else {
            return .failure(Problem("A question may only have id, header, text, options, multi_select, allow_other and secret."))
        }
        guard let id = fields["id"]?.stringValue, (1...maxIDChars).contains(scalarCount(id)), clean(id) else {
            return .failure(Problem("Each question needs an id of 1 to \(maxIDChars) characters."))
        }
        guard let text = fields["text"]?.stringValue, (1...maxTextChars).contains(scalarCount(text)), clean(text) else {
            return .failure(Problem("Each question needs text of 1 to \(maxTextChars) characters."))
        }
        var header = ""
        if let value = fields["header"] {
            guard let string = value.stringValue, scalarCount(string) <= maxHeaderChars, clean(string) else {
                return .failure(Problem("header must be text of at most \(maxHeaderChars) characters."))
            }
            header = string
        }
        // 없으면 false, 참거짓이 아니면 nil (고칠 점)
        func flag(_ key: String) -> Bool? {
            guard let value = fields[key] else { return false }
            return value.boolValue
        }
        guard let multiSelect = flag("multi_select"), let allowOther = flag("allow_other"), let secret = flag("secret") else {
            return .failure(Problem("multi_select, allow_other and secret must be true or false."))
        }
        var options: [Option] = []
        if let value = fields["options"] {
            guard case .array(let list) = value, list.count <= maxOptions else { return .failure(Problem("options must be a list of at most \(maxOptions).")) }
            for entry in list {
                guard case .object(let option) = entry, Set(option.keys).isSubset(of: optionKeys) else {
                    return .failure(Problem("Each option may only have label and description."))
                }
                guard let label = option["label"]?.stringValue, (1...maxLabelChars).contains(scalarCount(label)), clean(label) else {
                    return .failure(Problem("Each option needs a label of 1 to \(maxLabelChars) characters."))
                }
                var description = ""
                if let raw = option["description"] {
                    guard let string = raw.stringValue, scalarCount(string) <= maxDescriptionChars, clean(string) else {
                        return .failure(Problem("An option description must be text of at most \(maxDescriptionChars) characters."))
                    }
                    description = string
                }
                options.append(Option(label: label, description: description))
            }
        }
        guard Set(options.map(\.label)).count == options.count else { return .failure(Problem("Option labels must be unique within a question.")) }
        if multiSelect, options.isEmpty { return .failure(Problem("multi_select needs options.")) }
        return .success(Question(id: id, header: header, text: text, options: options, multiSelect: multiSelect, allowOther: allowOther, secret: secret))
    }

    /// NUL은 서버 JSONB가 담지 못한다
    static func clean(_ text: String) -> Bool { !text.unicodeScalars.contains("\u{0}") }

    // MARK: MCP tools/list

    public static let toolDescription =
        "Ask the user one to four questions and wait for the answers. Give options for choices, set allow_other to accept a typed answer, "
        + "set multi_select to allow several options, and set secret for a password or key. Make one ask_user call at a time and wait for its result."

    public static var inputSchema: WireJSON {
        let option: WireJSON = .object([
            "type": .string("object"),
            "properties": .object([
                "label": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(Int64(maxLabelChars))]),
                "description": .object(["type": .string("string"), "maxLength": .int(Int64(maxDescriptionChars))]),
            ]),
            "required": .array([.string("label")]),
            "additionalProperties": .bool(false),
        ])
        let question: WireJSON = .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(Int64(maxIDChars)), "description": .string("Short id, unique in this call.")]),
                "header": .object(["type": .string("string"), "maxLength": .int(Int64(maxHeaderChars))]),
                "text": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(Int64(maxTextChars))]),
                "options": .object(["type": .string("array"), "maxItems": .int(Int64(maxOptions)), "items": option]),
                "multi_select": .object(["type": .string("boolean")]),
                "allow_other": .object(["type": .string("boolean")]),
                "secret": .object(["type": .string("boolean")]),
            ]),
            "required": .array([.string("id"), .string("text")]),
            "additionalProperties": .bool(false),
        ])
        return .object([
            "type": .string("object"),
            "properties": .object([
                "questions": .object(["type": .string("array"), "minItems": .int(1), "maxItems": .int(Int64(maxQuestions)), "items": question]),
                "answers": .object(["type": .string("object"), "description": .string("Filled in by Taskforce with the user's answers. Leave it out.")]),
            ]),
            "required": .array([.string("questions")]),
            "additionalProperties": .bool(false),
        ])
    }
}
#endif
