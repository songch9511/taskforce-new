#if os(macOS)
import Foundation

/// 사건 outbox의 정책 (OA D2b 계약 2.7): 글 자르기 · 질문 상한 · 묶음 고르기 · 응답 분류 · 다시 보내기 간격.
/// 모두 순수 함수다. 저장은 `BridgeLedger`, 보내기는 `BridgeRuntime`이 한다. 서버 판정을 흉내 내지 않는다: 길이 · 개수는 **전송 모양의 제약**이다.
public enum Outbox {
    public static let maxEventsPerBatch = 100
    /// 서버 상한은 1,000,000바이트. 여유를 둔다
    public static let maxBatchBytes = 900_000
    /// `{"bridge_id":"…","events":[` … `]}` 포장
    public static let batchOverheadBytes = 160
    public static let maxTextBytes = 32_768
    static let questionJSONLimit = 32_768

    // MARK: 글 자르기

    public struct TextFit: Equatable {
        /// 서버로 보낼 글 (`maxTextBytes` 이하)
        public var sent: String
        /// 잘렸으면 전체 글 (View full용으로 원장에만 둔다, 계약 3.8)
        public var full: String?
    }

    /// UTF-8 바이트 상한으로 유니코드 스칼라 경계에서 자른다. NUL은 서버 JSONB가 받지 못하므로 U+FFFD로 바꾼다
    public static func fit(text: String, limitBytes: Int = maxTextBytes) -> TextFit {
        let cleaned = text.unicodeScalars.contains("\u{0}") ? text.replacingOccurrences(of: "\u{0}", with: "\u{FFFD}") : text
        guard cleaned.utf8.count > limitBytes else { return TextFit(sent: cleaned, full: nil) }
        var bytes = 0
        var end = cleaned.unicodeScalars.startIndex
        var index = end
        while index < cleaned.unicodeScalars.endIndex {
            let width = UTF8.width(cleaned.unicodeScalars[index])
            if bytes + width > limitBytes { break }
            bytes += width
            index = cleaned.unicodeScalars.index(after: index)
            end = index
        }
        return TextFit(sent: String(cleaned.unicodeScalars[cleaned.unicodeScalars.startIndex..<end]), full: cleaned)
    }

    // MARK: 질문 상한 (Q15)

    /// 잘린 id · 선택지 label → 원래 값. 답은 원래 값으로 되돌려 adapter에 넘긴다
    public struct QuestionMap: Codable, Equatable {
        public var ids: [String: String] = [:]
        public var labels: [String: String] = [:]

        public init(ids: [String: String] = [:], labels: [String: String] = [:]) {
            self.ids = ids
            self.labels = labels
        }

        public var isEmpty: Bool { ids.isEmpty && labels.isEmpty }
    }

    public enum QuestionFit: Equatable {
        case fits(BridgeV1Question, QuestionMap)
        /// 질문 5개 이상 · 선택지 11개 이상 · 줄여도 안 들어감 · id를 쓸 수 없음: 보낼 수 없다. 그 요청은 adapter가 닫는다 (deny)
        case unrepresentable(String)
    }

    private static func count(_ text: String) -> Int { text.unicodeScalars.count }

    /// 글자 수는 유니코드 스칼라 기준이다 (서버는 JS `Array.from`으로 센다)
    private static func cut(_ text: String, _ limit: Int) -> String {
        count(text) <= limit ? text : String(String.UnicodeScalarView(text.unicodeScalars.prefix(limit)))
    }

    public static func fit(question: AgentQuestion, taskID: String, observedAt: Date) -> QuestionFit {
        guard (1...200).contains(count(question.providerRequestID)) else { return .unrepresentable("request_id") }
        guard (1...4).contains(question.items.count) else { return .unrepresentable("question_count") }
        guard question.items.allSatisfy({ $0.options.count <= 10 }) else { return .unrepresentable("option_count") }

        var map = QuestionMap()
        var textCap = 4000
        var descriptionCap = 1000
        while true {
            var items: [BridgeV1QuestionItem] = []
            for item in question.items {
                let id = cut(item.id, 200)
                if id != item.id { map.ids[id] = item.id }
                let options = item.options.map { option -> BridgeV1QuestionOption in
                    let label = cut(option.label, 500)
                    if label != option.label { map.labels[label] = option.label }
                    return BridgeV1QuestionOption(label: label, description: cut(option.description, descriptionCap))
                }
                items.append(BridgeV1QuestionItem(
                    id: id, header: cut(item.header, 200), text: cut(item.text, textCap), options: options,
                    multiSelect: item.multiSelect, allowOther: item.allowOther, secret: item.secret
                ))
            }
            guard Set(items.map(\.id)).count == items.count else { return .unrepresentable("id_collision") }
            let candidate = BridgeV1Question(providerRequestID: question.providerRequestID, kind: question.kind, structured: question.structured, questions: items)
            if jsonbByteCount(of: candidate, taskID: taskID, observedAt: observedAt) <= questionJSONLimit { return .fits(candidate, map) }
            if textCap <= 50 { return .unrepresentable("too_large") }
            textCap /= 2
            descriptionCap /= 2
        }
    }

    /// 서버가 `pending_question`으로 저장할 JSON의 크기 (JSONB 글자 모양: 구분자 뒤에 공백, `bridgeV1JsonbText`와 같다).
    /// 서버 검사는 질문 + `question_key` + `asked_at`을 합친 객체를 센다 (contract.ts)
    public static func jsonbByteCount(of question: BridgeV1Question, taskID: String, observedAt: Date) -> Int {
        func string(_ value: String) -> String { jsonString(value) }
        func bool(_ value: Bool) -> String { value ? "true" : "false" }
        let items = question.questions.map { item -> String in
            let options = item.options.map { "{\"label\": \(string($0.label)), \"description\": \(string($0.description))}" }.joined(separator: ", ")
            return "{\"id\": \(string(item.id)), \"header\": \(string(item.header)), \"text\": \(string(item.text)), \"options\": [\(options)], "
                + "\"multi_select\": \(bool(item.multiSelect)), \"allow_other\": \(bool(item.allowOther)), \"secret\": \(bool(item.secret))}"
        }.joined(separator: ", ")
        let text = "{\"provider_request_id\": \(string(question.providerRequestID)), \"kind\": \(string(question.kind.rawValue)), "
            + "\"structured\": \(bool(question.structured)), \"questions\": [\(items)], "
            + "\"question_key\": [\(string(taskID)), \(string(question.providerRequestID))], \"asked_at\": \(string(BridgeV1Time.string(observedAt)))}"
        return text.utf8.count
    }

    /// JS `JSON.stringify`와 같은 글자 이스케이프 (`"` `\` 제어 문자만)
    private static func jsonString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{8}": out += "\\b"
            case "\u{c}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    /// 잘린 id · label로 온 답을 원래 값으로 되돌린다
    public static func originalAnswers(_ answers: [String: BridgeV1AnswerValue], map: QuestionMap) -> [String: BridgeV1AnswerValue] {
        func value(_ item: BridgeV1AnswerValue) -> BridgeV1AnswerValue {
            switch item {
            case .one(let text): .one(map.labels[text] ?? text)
            case .many(let texts): .many(texts.map { map.labels[$0] ?? $0 })
            }
        }
        return Dictionary(uniqueKeysWithValues: answers.map { (map.ids[$0.key] ?? $0.key, value($0.value)) })
    }

    // MARK: 묶음 고르기

    /// 삽입 순서로 훑는다. 아직 보낼 때가 아닌 행을 만난 세션은 그 뒤 사건도 보내지 않는다 (같은 세션 순서 유지).
    /// 첫 사건은 크기와 상관없이 담는다 (큰 사건 하나가 큐를 막지 않게)
    public static func selectBatch(from rows: [OutboxRow], now: Date) -> [OutboxRow] {
        var blocked = Set<String>()
        var batch: [OutboxRow] = []
        var bytes = batchOverheadBytes
        for row in rows where row.deadReason == nil {
            if blocked.contains(row.agentSessionID) { continue }
            if row.nextAttemptAt > now {
                blocked.insert(row.agentSessionID)
                continue
            }
            if batch.count >= maxEventsPerBatch { break }
            if !batch.isEmpty, bytes + row.bytes + 1 > maxBatchBytes { break }
            batch.append(row)
            bytes += row.bytes + 1
        }
        return batch
    }

    /// 400(묶음 전체)이면 반으로 나눠 다시 보낸다
    public static func halves(_ batch: [OutboxRow]) -> ([OutboxRow], [OutboxRow]) {
        guard batch.count >= 2 else { return (batch, []) }
        let middle = batch.count / 2
        return (Array(batch[..<middle]), Array(batch[middle...]))
    }

    // MARK: 응답 분류

    public struct Disposition: Equatable {
        /// 지운다 (`accepted_event_ids`뿐이 지우는 신호다)
        public var delivered: [Int64] = []
        /// 남기고 뒤로 미룬다 (`retry_event_ids`, 그리고 어느 목록에도 없는 사건)
        public var retry: [Int64] = []
        /// 다시 보내지 않는다 (`rejected`)
        public var dead: [Int64] = []
    }

    /// 세 목록이 권위다. `results[].status`는 진단용이라 쓰지 않는다
    public static func disposition(of response: BridgeV1EventsResponse, batch: [OutboxRow]) -> Disposition {
        let accepted = Set(response.acceptedEventIDs)
        let rejected = Set(response.rejected.map(\.eventID))
        var result = Disposition()
        for row in batch {
            if accepted.contains(row.eventID) {
                result.delivered.append(row.key)
            } else if rejected.contains(row.eventID) {
                result.dead.append(row.key)
            } else {
                result.retry.append(row.key)
            }
        }
        return result
    }

    // MARK: 다시 보내기 간격

    /// 1초 → 2 → 4 … 최대 60초. `jitter`는 −0.2…0.2 (±20%)
    public static func backoff(attempts: Int, jitter: Double = 0) -> TimeInterval {
        let base = attempts >= 6 ? 60.0 : min(60.0, pow(2.0, Double(max(0, attempts))))
        return base * (1 + jitter)
    }
}
#endif
