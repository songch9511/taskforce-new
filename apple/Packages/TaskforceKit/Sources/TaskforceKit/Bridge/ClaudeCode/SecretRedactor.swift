#if os(macOS)
import Foundation

/// 건넨 비밀값을 밖으로 나가는 글에서 가린다 (OA D3a 8장 11, 코디네이터 결정).
/// 값은 그 세션 프로세스가 끝날 때까지 메모리에만 있다 (디스크 · 로그 0). 정확히 같은 부분 문자열(앞뒤 공백을 정리한 것 포함)만 `[redacted]`로 바꾼다.
/// 8자 미만 값과 변형(base64 · 일부)은 가리지 못한다 (notes 남는 위험)
public struct SecretRedactor: Sendable, Equatable {
    public static let placeholder = "[redacted]"
    public static let minimumLength = 8

    /// 긴 것부터 (앞뒤 공백이 있는 원래 값이 정리한 값보다 먼저)
    let values: [String]

    public init(_ secrets: [String] = []) {
        var found = Set<String>()
        for secret in secrets {
            let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= Self.minimumLength else { continue }
            found.insert(secret)
            found.insert(trimmed)
        }
        values = found.sorted { $0.utf16.count != $1.utf16.count ? $0.utf16.count > $1.utf16.count : $0 < $1 }
    }

    public var isEmpty: Bool { values.isEmpty }

    /// 글자 단위 정확 비교 (`.literal`: 정규 동등 · 대소문자를 보지 않는다)
    public func redact(_ text: String) -> String {
        values.reduce(text) { $0.replacingOccurrences(of: $1, with: Self.placeholder, options: .literal) }
    }

    /// 밖으로 나가는 사건 (메시지 · 질문 · 산출물 글)
    public func redact(_ event: AgentEvent) -> AgentEvent {
        guard !isEmpty else { return event }
        switch event {
        case .message(let text): return .message(text: redact(text))
        case .question(let question): return .question(redact(question))
        case .artifact(let path, let hash, let summary): return .artifact(path: redact(path), hash: hash, summary: redact(summary))
        default: return event
        }
    }

    public func redact(_ question: AgentQuestion) -> AgentQuestion {
        var copy = question
        copy.text = redact(question.text)
        copy.items = question.items.map { item in
            var item = item
            item.header = redact(item.header)
            item.text = redact(item.text)
            item.options = item.options.map { AgentQuestionOption(label: redact($0.label), description: redact($0.description)) }
            return item
        }
        return copy
    }
}
#endif
