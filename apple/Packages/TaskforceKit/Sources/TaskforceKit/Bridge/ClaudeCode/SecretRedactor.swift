#if os(macOS)
import Foundation

/// 건넨 비밀값을 밖으로 나가는 글에서 가린다 (OA D3a 8장 11 · 9장 1 · 3, 코디네이터 결정).
/// 값은 agent 세션의 가리개로 메모리에만 있다 (디스크 · 로그 0). 정확히 같은 부분 문자열과 그 변형 — 앞뒤 공백 정리, NFC/NFD, JSON 이스케이프
/// (`\"` · `\\` · `\/` · `\uXXXX`), 셸 작은따옴표 이스케이프(`'\''`), 퍼센트 인코딩(대문자 · 소문자) — 을 `[redacted]`로 바꾼다.
/// 8자 미만 값과 그 밖의 변형(base64 · 일부)은 가리지 못한다 (notes 남는 위험)
public struct SecretRedactor: Sendable, Equatable {
    public static let placeholder = "[redacted]"
    public static let minimumLength = 8

    /// 받은 원래 값 (쌓을 때 다시 만든다)
    let secrets: [String]
    /// 가릴 글: 원래 값과 변형, 긴 것부터
    let values: [String]

    public init(_ secrets: [String] = []) {
        var kept: [String] = []
        var found: [String] = []
        for secret in secrets where secret.trimmingCharacters(in: .whitespacesAndNewlines).count >= Self.minimumLength {
            kept.append(secret)
            found += Self.variants(of: secret)
        }
        self.secrets = kept
        values = Self.unique(found).sorted { $0.utf16.count != $1.utf16.count ? $0.utf16.count > $1.utf16.count : Array($0.utf8).lexicographicallyPrecedes($1.utf8) }
    }

    /// 바이트가 같은 것만 하나로 (Swift `String`의 `==` · `Set`은 정규 동등이라 NFC와 NFD를 하나로 합친다)
    static func unique(_ values: [String]) -> [String] {
        var seen = Set<[UInt8]>()
        return values.filter { seen.insert(Array($0.utf8)).inserted }
    }

    /// 값을 더한 가리개 (agent 세션에서 쌓는다, 9장 1)
    public func adding(_ more: [String]) -> SecretRedactor {
        SecretRedactor(secrets + more)
    }

    public var isEmpty: Bool { values.isEmpty }

    static func variants(of secret: String) -> [String] {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        let bases = unique([secret, trimmed].flatMap { [$0, $0.precomposedStringWithCanonicalMapping, $0.decomposedStringWithCanonicalMapping] })
        var out = bases
        for base in bases {
            // 셸 작은따옴표 안의 `'` (`'\''`). 바꾸는 `'`는 셸 문법의 일부다 (`.literal`)
            out.append(base.replacingOccurrences(of: "'", with: "'\\''", options: .literal))
            for slash in [false, true] {
                out.append(jsonEscaped(base, slash: slash, ascii: nil))
                out.append(jsonEscaped(base, slash: slash, ascii: "%04x"))
                out.append(jsonEscaped(base, slash: slash, ascii: "%04X"))
            }
            out.append(percentEncoded(base, format: "%%%02X"))
            out.append(percentEncoded(base, format: "%%%02x"))
        }
        return unique(out).filter { $0.count >= minimumLength }
    }

    /// JSON 문자열 안의 모양: `"` · `\` · (선택) `/` 이스케이프, 제어 글자는 `\n` · `\uXXXX`, `ascii`면 비ASCII도 `\uXXXX`(서로게이트 쌍)
    static func jsonEscaped(_ text: String, slash: Bool, ascii: String?) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "/": out += slash ? "\\/" : "/"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else if let format = ascii, scalar.value > 0x7E {
                    for unit in String(scalar).utf16 { out += "\\u" + String(format: format, unit) }
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    /// 퍼센트 인코딩: 예약되지 않은 글자(`A-Z a-z 0-9 - . _ ~`) 밖의 UTF-8 바이트를 `%XX`로
    static func percentEncoded(_ text: String, format: String) -> String {
        var out = ""
        for byte in text.utf8 {
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x2E, 0x5F, 0x7E: out.unicodeScalars.append(Unicode.Scalar(byte))
            default: out += String(format: format, byte)
            }
        }
        return out
    }

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
