#if os(macOS)
import Foundation

/// 건넨 비밀값을 밖으로 나가는 글에서 가린다 (OA D3a 8장 11 · 9장 1 · 3 · 10장 8, 코디네이터 결정).
/// 값은 agent 세션의 가리개로 메모리에만 있다 (디스크 · 로그 0). 먼저 정확히 같은 부분 문자열과 그 변형 — 앞뒤 공백 정리, NFC/NFD, JSON 이스케이프
/// (`\"` · `\\` · `\/` · `\uXXXX`), 셸 작은따옴표 이스케이프(`'\''`), 퍼센트 인코딩(대문자 · 소문자) — 을 `[redacted]`로 바꾼다.
/// 그다음 열거로 못 찾는 형태(일부만 퍼센트 인코딩 · `+`로 쓴 빈칸 · `'"'"'` 등)는 **디코드해서 찾는다** (`detects`): 퍼센트(두 방식) · JSON · 셸 따옴표를
/// 겹쳐 풀고 NFC/NFD로 맞춘다. 결정 입력에서 찾으면 서버에 묻지 않고, 사건 글에서는 그 셸 단어를 가린다 (단어를 못 집으면 글 전체).
/// 8자 미만 값과 그 밖의 변형(base64 · 일부)은 가리지 못한다 (notes 남는 위험)
public struct SecretRedactor: Sendable, Equatable {
    public static let placeholder = "[redacted]"
    public static let minimumLength = 8

    /// 받은 원래 값 (쌓을 때 다시 만든다)
    let secrets: [String]
    /// 가릴 글: 원래 값과 변형, 긴 것부터
    let values: [String]
    /// 디코드한 글에서 찾을 값: 원래 값 · 앞뒤 공백 정리본 그대로(정규화 전), 그리고 그 NFC와 NFD
    let needlesRaw: [String]
    let needlesNFC: [String]
    let needlesNFD: [String]

    public init(_ secrets: [String] = []) {
        var kept: [String] = []
        var found: [String] = []
        var bases: [String] = []
        for secret in secrets where secret.trimmingCharacters(in: .whitespacesAndNewlines).count >= Self.minimumLength {
            kept.append(secret)
            found += Self.variants(of: secret)
            bases += [secret, secret.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        self.secrets = kept
        values = Self.unique(found).sorted { $0.utf16.count != $1.utf16.count ? $0.utf16.count > $1.utf16.count : Array($0.utf8).lexicographicallyPrecedes($1.utf8) }
        needlesRaw = Self.unique(bases)
        needlesNFC = Self.unique(bases.map(\.precomposedStringWithCanonicalMapping))
        needlesNFD = Self.unique(bases.map(\.decomposedStringWithCanonicalMapping))
    }

    /// 디코드한 형태 어디엔가 비밀값이 있나 (10장 8 · 11장 7): 형태마다 먼저 정규화 전 글자 그대로 찾고(뒤에 붙은 결합 표시가 정규화로 섞여 사라지지 않게), 그다음 NFC · NFD로
    public func detects(_ text: String) -> Bool {
        guard !needlesRaw.isEmpty, !text.isEmpty else { return false }
        for form in Self.decodedForms(text) {
            if needlesRaw.contains(where: { form.range(of: $0, options: .literal) != nil }) { return true }
            let nfc = form.precomposedStringWithCanonicalMapping
            if needlesNFC.contains(where: { nfc.range(of: $0, options: .literal) != nil }) { return true }
            let nfd = form.decomposedStringWithCanonicalMapping
            if needlesNFD.contains(where: { nfd.range(of: $0, options: .literal) != nil }) { return true }
        }
        return false
    }

    /// 원래 글과, 퍼센트(`%XX` · `+`→빈칸 두 방식) · JSON unescape · 셸 따옴표 풀기 · ANSI-C 조각 풀기를 3단까지 겹쳐 푼 글 (바이트가 같은 것은 한 번).
    /// 퍼센트 · JSON은 조각마다 푼다(앞뒤 글과 무관). ANSI-C `$'…'`는 글 전체를 셸로 푼 것과 따로 조각마다도 푼다 (12장 11: 앞선 자연어의 작은따옴표에 흔들리지 않게).
    /// 해석들의 합이다 (14장 8): 원문 그대로 ∪ 조각 디코드 ∪ 셸 풀기(주석 처리함) ∪ 셸 풀기(주석 처리 안 함). 하나라도 찾으면 찾은 것이다 (거짓 양성은 로컬 카드라 안전하다)
    static func decodedForms(_ text: String, depth: Int = 3) -> [String] {
        var forms = [text]
        var seen: Set<[UInt8]> = [Array(text.utf8)]
        var frontier = [text]
        for _ in 0..<depth where !frontier.isEmpty {
            var next: [String] = []
            for form in frontier {
                for decoded in [
                    percentDecoded(form, plusIsSpace: false), percentDecoded(form, plusIsSpace: true), jsonUnescaped(form), shellUnquoted(form, comments: true),
                    shellUnquoted(form, comments: false), ansiCFragmentsDecoded(form),
                ] {
                    guard let decoded, seen.insert(Array(decoded.utf8)).inserted else { continue }
                    forms.append(decoded)
                    next.append(decoded)
                }
            }
            frontier = next
        }
        return forms
    }

    static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }

    /// `%XX`를 바이트로 (`plusIsSpace`면 `+`도 빈칸으로, form 인코딩). 바뀐 것이 없으면 nil
    static func percentDecoded(_ text: String, plusIsSpace: Bool) -> String? {
        let bytes = Array(text.utf8)
        guard bytes.contains(0x25) || (plusIsSpace && bytes.contains(0x2B)) else { return nil }
        var out: [UInt8] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x25, index + 2 < bytes.count, let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2]) {
                out.append(high << 4 | low)
                index += 3
            } else {
                out.append(plusIsSpace && byte == 0x2B ? 0x20 : byte)
                index += 1
            }
        }
        return out == bytes ? nil : String(decoding: out, as: UTF8.self)
    }

    /// JSON 문자열 안의 이스케이프를 푼다 (`\"` `\\` `\/` `\b` `\f` `\n` `\r` `\t`, 4자리 16진 `\u` + 서로게이트 쌍). 바뀐 것이 없으면 nil
    static func jsonUnescaped(_ text: String) -> String? {
        let units = Array(text.utf16)
        guard units.contains(0x5C) else { return nil }
        var out: [UInt16] = []
        var index = 0
        func hex4(_ at: Int) -> UInt16? {
            guard at + 4 <= units.count else { return nil }
            var value: UInt16 = 0
            for unit in units[at..<at + 4] {
                guard unit < 0x80, let digit = hexValue(UInt8(unit)) else { return nil }
                value = value << 4 | UInt16(digit)
            }
            return value
        }
        while index < units.count {
            let unit = units[index]
            guard unit == 0x5C, index + 1 < units.count else {
                out.append(unit)
                index += 1
                continue
            }
            let next = units[index + 1]
            switch next {
            case 0x22, 0x5C, 0x2F: out.append(next); index += 2
            case 0x62: out.append(0x08); index += 2
            case 0x66: out.append(0x0C); index += 2
            case 0x6E: out.append(0x0A); index += 2
            case 0x72: out.append(0x0D); index += 2
            case 0x74: out.append(0x09); index += 2
            case 0x75:
                if let value = hex4(index + 2) {
                    out.append(value)
                    index += 6
                } else {
                    out.append(unit)
                    index += 1
                }
            default:
                out.append(unit)
                index += 1
            }
        }
        return out == units ? nil : String(decoding: out, as: UTF16.self)
    }

    /// 글 안의 ANSI-C `$'…'` 조각만 하나씩 푼다 (12장 11): 조각 밖의 글은 그대로 둔다 (닫히지 않은 조각도). 바뀐 것이 없으면 nil
    static func ansiCFragmentsDecoded(_ text: String) -> String? {
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var changed = false
        var index = 0
        while index < scalars.count {
            if scalars[index] == "$", index + 1 < scalars.count, scalars[index + 1] == "'" {
                // 닫는 `'`까지 (`\` 뒤 한 글자는 건너뛴다: `\'`는 조각 안이다)
                var end = index + 2
                while end < scalars.count, scalars[end] != "'" { end += scalars[end] == "\\" ? 2 : 1 }
                if end < scalars.count {
                    var fragment = String.UnicodeScalarView()
                    fragment.append(contentsOf: scalars[index...end])
                    if let decoded = shellUnquoted(String(fragment)) {
                        out.append(contentsOf: decoded.unicodeScalars)
                        changed = true
                        index = end + 1
                        continue
                    }
                }
            }
            out.append(scalars[index])
            index += 1
        }
        return changed ? String(out) : nil
    }

    /// 셸 따옴표를 푼다: `'…'`는 그대로, `"…"` 안의 `\` 이스케이프(`$` `` ` `` `"` `\`), 따옴표 밖의 `\x` → `x`, 따옴표 밖 · 큰따옴표 안의 줄 이음(`\` + 줄바꿈)은 지운다,
    /// ANSI-C `$'…'`는 이스케이프(`\xHH` · `\NNN` · 4자리 `\u` · 8자리 `\U` · `\n` 등 · `\cX`)를 푼다 (11장 8). `'"'"'` · `'\''`도 풀린다.
    /// `comments`면 따옴표 밖 **단어 첫머리**의 `#`부터 줄 끝까지는 주석이다: 그대로 두고 그 안의 따옴표를 셸 문법으로 보지 않는다 (12장 11).
    /// 단어 첫머리는 실제 경계로 본다 (14장 8): 글 처음, 또는 이스케이프되지 않은 빈칸 · 탭 · 줄바꿈 · `; & | ( ) < >` 바로 뒤. 이스케이프된 글자(`\ ` · `\;` 등) ·
    /// 따옴표 · 다른 글자 뒤는 단어 중간이고, 줄 이음은 그 상태를 바꾸지 않는다 (단어 중간 줄 이음 뒤의 `#`는 글자다). 바뀐 것이 없으면 nil
    static func shellUnquoted(_ text: String, comments: Bool = true) -> String? {
        let scalars = Array(text.unicodeScalars)
        guard scalars.contains(where: { $0 == "'" || $0 == "\"" || $0 == "\\" }) else { return nil }
        enum Mode { case bare, single, double, ansiC }
        var mode = Mode.bare
        /// 따옴표 밖에서 다음 글자가 새 단어의 첫머리다
        var wordStart = true
        let boundaries: Set<Unicode.Scalar> = [" ", "\t", "\n", ";", "&", "|", "(", ")", "<", ">"]
        // `$'…'`의 `\xHH` · `\NNN`은 바이트다: 바이트로 모아 끝에 UTF-8로 읽는다
        var out: [UInt8] = []
        func put(_ scalar: Unicode.Scalar) { out += Array(String(scalar).utf8) }
        func digits(from start: Int, max: Int, radix: UInt32) -> (value: UInt32, count: Int) {
            var value: UInt32 = 0
            var count = 0
            while count < max, start + count < scalars.count, let digit = Character(scalars[start + count]).hexDigitValue, UInt32(digit) < radix {
                value = value * radix + UInt32(digit)
                count += 1
            }
            return (value, count)
        }
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            let next = index + 1 < scalars.count ? scalars[index + 1] : nil
            switch mode {
            case .single:
                if scalar == "'" { mode = .bare } else { put(scalar) }
            case .double:
                if scalar == "\"" {
                    mode = .bare
                } else if scalar == "\\", next == "\n" {
                    index += 1 // 줄 이음: `\`와 줄바꿈을 함께 지운다 (11장 8)
                } else if scalar == "\\", let next, ["$", "`", "\"", "\\"].contains(next) {
                    put(next)
                    index += 1
                } else {
                    put(scalar)
                }
            case .ansiC:
                if scalar == "'" {
                    mode = .bare
                } else if scalar == "\\", let next {
                    index += 1
                    switch next {
                    case "a": out.append(0x07)
                    case "b": out.append(0x08)
                    case "e", "E": out.append(0x1B)
                    case "f": out.append(0x0C)
                    case "n": out.append(0x0A)
                    case "r": out.append(0x0D)
                    case "t": out.append(0x09)
                    case "v": out.append(0x0B)
                    case "\\", "'", "\"", "?": put(next)
                    case "x":
                        let (value, count) = digits(from: index + 1, max: 2, radix: 16)
                        if count > 0 { out.append(UInt8(value)); index += count } else { put("\\"); put(next) }
                    case "u", "U":
                        let (value, count) = digits(from: index + 1, max: next == "u" ? 4 : 8, radix: 16)
                        if count > 0, let decoded = Unicode.Scalar(value) { put(decoded); index += count } else { put("\\"); put(next) }
                    case "c":
                        if index + 1 < scalars.count, scalars[index + 1].isASCII {
                            out.append(UInt8(scalars[index + 1].value & 0x1F))
                            index += 1
                        } else {
                            put("\\")
                            put(next)
                        }
                    default:
                        let (value, count) = digits(from: index, max: 3, radix: 8)
                        if count > 0 { out.append(UInt8(truncatingIfNeeded: value)); index += count - 1 } else { put("\\"); put(next) }
                    }
                } else {
                    put(scalar)
                }
            case .bare:
                if comments, scalar == "#", wordStart {
                    // 주석: 줄바꿈 앞까지 그대로 옮긴다 (줄바꿈은 다음 차례에 따옴표 밖 글로)
                    while index < scalars.count, scalars[index] != "\n" {
                        put(scalars[index])
                        index += 1
                    }
                    continue
                } else if scalar == "'" {
                    mode = .single
                    wordStart = false
                } else if scalar == "$", next == "'" {
                    mode = .ansiC // ANSI-C 따옴표 `$'…'` (11장 8)
                    index += 1
                    wordStart = false
                } else if scalar == "\"" {
                    mode = .double
                    wordStart = false
                } else if scalar == "\\", next == "\n" {
                    index += 1 // 줄 이음: 단어 경계 상태는 그대로
                } else if scalar == "\\", let next {
                    put(next)
                    index += 1
                    wordStart = false
                } else {
                    put(scalar)
                    wordStart = boundaries.contains(scalar)
                }
            }
            index += 1
        }
        let result = String(decoding: out, as: UTF8.self)
        return out == Array(text.utf8) ? nil : result
    }

    /// 셸 단어로 나눈다 (따옴표 밖의 빈칸 · 탭 · 줄바꿈이 경계). 경계 글도 조각으로 남겨 다시 이으면 원래 글이다
    static func shellSegments(_ text: String) -> [(text: String, isWord: Bool)] {
        var segments: [(text: String, isWord: Bool)] = []
        var current = String.UnicodeScalarView()
        var currentIsWord = true
        var quote: Unicode.Scalar?
        var escaped = false
        func flush() {
            if !current.isEmpty { segments.append((String(current), currentIsWord)) }
            current = String.UnicodeScalarView()
        }
        for scalar in text.unicodeScalars {
            let isWord = !(quote == nil && !escaped && (scalar == " " || scalar == "\t" || scalar == "\n"))
            if isWord != currentIsWord, !current.isEmpty { flush() }
            currentIsWord = isWord
            current.append(scalar)
            if escaped {
                escaped = false
            } else if let open = quote {
                if scalar == open { quote = nil } else if open == "\"", scalar == "\\" { escaped = true }
            } else if scalar == "'" || scalar == "\"" {
                quote = scalar
            } else if scalar == "\\" {
                escaped = true
            }
        }
        flush()
        return segments
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

    /// 먼저 변형을 글자 단위로 정확히 바꾸고(`.literal`: 정규 동등 · 대소문자를 보지 않는다), 디코드해서 남은 것을 찾는다
    public func redact(_ text: String) -> String {
        guard !isEmpty else { return text }
        let exact = values.reduce(text) { $0.replacingOccurrences(of: $1, with: Self.placeholder, options: .literal) }
        guard detects(exact) else { return exact }
        // 열거로 못 지운 형태 (10장 8): 디코드해서 비밀값이 나오는 셸 단어를 통째로 가린다. 그래도 남으면(단어를 넘나든다) 글 전체를 가린다
        let words = Self.shellSegments(exact).map { $0.isWord && detects($0.text) ? Self.placeholder : $0.text }.joined()
        return detects(words) ? Self.placeholder : words
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
