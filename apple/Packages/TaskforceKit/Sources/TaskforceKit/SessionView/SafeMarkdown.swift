#if os(macOS)
import Foundation

/// 답의 글 표시의 안전한 부분 집합 (DZ oa-session-view-dz v2 E1 · E4, 사용자 승인 2026-10-22 "안전한 부분만 그림"):
/// 코드 블록 · 인라인 코드 · 목록 · 굵게 · 제목(굵기만). **링크 · 표 · 이미지 · HTML · 인용은 쓴 그대로 글자다.**
///
/// 이 값에는 링크 · 첨부를 담을 자리가 없다: 어떤 글을 줘도 열리는 것이 만들어질 수 없다 (`Inline`은 글 · 코드 · 굵게뿐). 그래서 렌더하는 쪽도 링크 속성을 만들 수 없다.
/// 시스템의 마크다운 해석기(`AttributedString(markdown:)`)는 링크 · 이미지 첨부를 만들 수 있으므로 쓰지 않는다. 복사는 이 파서를 거치지 않는 **원문**이다.
/// 한도: 한 문단(목록 항목)이 `maxInlineBytes`를 넘으면 인라인 해석 없이 글자 그대로 둔다 (파싱 시간이 입력 길이에 비례하게). 코드 블록은 해석하지 않으므로 한도 없이 담는다 (읽기 쪽 상한이 이미 있다)
public enum SafeMarkdown {
    /// 이보다 긴 문단은 인라인 해석을 하지 않는다 (UTF-8 바이트)
    public static let maxInlineBytes = 8192
    /// 목록 들여쓰기는 이 깊이까지만 (둘째 · 셋째 층)
    static let maxDepth = 2
    /// 코드 블록 언어 이름의 상한
    static let maxLanguageLength = 20

    public indirect enum Inline: Equatable, Sendable {
        case text(String)
        case code(String)
        /// 굵게: 안에는 글과 코드뿐이다
        case bold([Inline])
    }

    public struct ListItem: Equatable, Sendable {
        public var depth: Int
        public var number: Int?
        public var inlines: [Inline]

        public init(depth: Int, number: Int?, inlines: [Inline]) {
            self.depth = depth
            self.number = number
            self.inlines = inlines
        }
    }

    public enum Block: Equatable, Sendable {
        case paragraph([Inline])
        /// 굵기만 바뀐다 (크기 그대로)
        case heading([Inline])
        case code(language: String?, text: String)
        case list(ordered: Bool, items: [ListItem])
    }

    // MARK: 블록

    private struct RawItem {
        var depth: Int
        var number: Int?
        var text: String
    }

    public static func parse(_ source: String) -> [Block] {
        let lines = splitLines(source)
        var blocks: [Block] = []
        var paragraph: [String] = []
        var items: [RawItem] = []
        var ordered = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            paragraph = []
            if !text.isEmpty { blocks.append(.paragraph(inlines(text))) }
        }
        func flushList() {
            guard !items.isEmpty else { return }
            blocks.append(.list(ordered: ordered, items: items.map { ListItem(depth: $0.depth, number: $0.number, inlines: inlines($0.text.trimmingCharacters(in: .whitespacesAndNewlines))) }))
            items = []
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            if let fence = openingFence(line) {
                flushParagraph()
                flushList()
                var body: [String] = []
                index += 1
                while index < lines.count, !closesFence(lines[index], fence) {
                    body.append(stripIndent(lines[index], fence.indent))
                    index += 1
                }
                index += 1
                blocks.append(.code(language: fence.language, text: body.joined(separator: "\n")))
                continue
            }
            if isBlank(line) {
                flushParagraph()
                flushList()
                index += 1
                continue
            }
            if let heading = headingText(line) {
                flushParagraph()
                flushList()
                blocks.append(.heading(inlines(heading)))
                index += 1
                continue
            }
            let indent = leadingSpaces(line)
            if let marker = listMarker(line), !items.isEmpty || indent < 4 {
                flushParagraph()
                if !items.isEmpty, ordered != marker.ordered { flushList() }
                ordered = marker.ordered
                items.append(RawItem(depth: min(maxDepth, indent / 2), number: marker.number, text: marker.text))
                index += 1
                continue
            }
            if !items.isEmpty {
                if indent >= 2 {
                    // 앞 항목에서 이어지는 줄
                    items[items.count - 1].text += "\n" + line.trimmingCharacters(in: .whitespaces)
                    index += 1
                    continue
                }
                flushList()
            }
            paragraph.append(line)
            index += 1
        }
        flushParagraph()
        flushList()
        return blocks
    }

    /// 개행 · CRLF · 낱개 CR을 모두 줄 끝으로
    private static func splitLines(_ source: String) -> [String] {
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        var previousWasCR = false
        for scalar in source.unicodeScalars {
            if scalar == "\n" {
                if !previousWasCR { lines.append(String(current)); current = String.UnicodeScalarView() }
                previousWasCR = false
            } else if scalar == "\r" {
                lines.append(String(current))
                current = String.UnicodeScalarView()
                previousWasCR = true
            } else {
                current.append(scalar)
                previousWasCR = false
            }
        }
        lines.append(String(current))
        return lines
    }

    private static func isBlank(_ line: String) -> Bool {
        line.unicodeScalars.allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func leadingSpaces(_ line: String) -> Int {
        var count = 0
        for scalar in line.unicodeScalars {
            if scalar == " " { count += 1 } else if scalar == "\t" { count += 4 } else { break }
        }
        return count
    }

    // MARK: 코드 울타리

    private struct Fence {
        var character: Unicode.Scalar
        var length: Int
        var indent: Int
        var language: String?
    }

    private static func openingFence(_ line: String) -> Fence? {
        let scalars = Array(line.unicodeScalars)
        var index = 0
        while index < scalars.count, scalars[index] == " ", index < 4 { index += 1 }
        guard index <= 3, index < scalars.count, scalars[index] == "`" || scalars[index] == "~" else { return nil }
        let character = scalars[index]
        var end = index
        while end < scalars.count, scalars[end] == character { end += 1 }
        let length = end - index
        guard length >= 3 else { return nil }
        let info = String(String.UnicodeScalarView(scalars[end...])).trimmingCharacters(in: .whitespaces)
        // 백틱 울타리의 안내 글에는 백틱이 없다 (있으면 인라인 코드가 있는 문단이다)
        if character == "`", info.unicodeScalars.contains("`") { return nil }
        let word = info.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
        return Fence(character: character, length: length, indent: index, language: word.flatMap(languageName))
    }

    private static func languageName(_ word: String) -> String? {
        guard !word.isEmpty, word.unicodeScalars.count <= maxLanguageLength else { return nil }
        let allowed = word.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 0x30 && scalar.value <= 0x39) || (scalar.value >= 0x41 && scalar.value <= 0x5A) || (scalar.value >= 0x61 && scalar.value <= 0x7A) || "_+#.-".unicodeScalars.contains(scalar)
        }
        return allowed ? word : nil
    }

    private static func closesFence(_ line: String, _ fence: Fence) -> Bool {
        let scalars = Array(line.unicodeScalars)
        var index = 0
        while index < scalars.count, scalars[index] == " ", index < 4 { index += 1 }
        guard index <= 3, index < scalars.count, scalars[index] == fence.character else { return false }
        var end = index
        while end < scalars.count, scalars[end] == fence.character { end += 1 }
        guard end - index >= fence.length else { return false }
        return scalars[end...].allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// 여는 울타리의 들여쓰기만큼 안의 줄 앞 공백을 덜어낸다 (그보다 더 들여쓴 것은 그대로)
    private static func stripIndent(_ line: String, _ indent: Int) -> String {
        guard indent > 0 else { return line }
        let scalars = Array(line.unicodeScalars)
        var removed = 0
        while removed < indent, removed < scalars.count, scalars[removed] == " " { removed += 1 }
        return String(String.UnicodeScalarView(scalars[removed...]))
    }

    // MARK: 제목 · 목록

    private static func headingText(_ line: String) -> String? {
        let scalars = Array(line.unicodeScalars)
        var index = 0
        while index < scalars.count, scalars[index] == " ", index < 4 { index += 1 }
        guard index <= 3 else { return nil }
        var hashes = 0
        while index + hashes < scalars.count, scalars[index + hashes] == "#" { hashes += 1 }
        guard (1...6).contains(hashes) else { return nil }
        let rest = scalars[(index + hashes)...]
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        let text = String(String.UnicodeScalarView(rest)).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    private static func listMarker(_ line: String) -> (ordered: Bool, number: Int?, text: String)? {
        let scalars = Array(line.unicodeScalars)
        var index = 0
        while index < scalars.count, scalars[index] == " " || scalars[index] == "\t" { index += 1 }
        guard index < scalars.count else { return nil }
        let first = scalars[index]
        if first == "-" || first == "*" || first == "+" {
            guard index + 1 < scalars.count, scalars[index + 1] == " " || scalars[index + 1] == "\t" else { return nil }
            return (false, nil, String(String.UnicodeScalarView(scalars[(index + 2)...])))
        }
        var digits = 0
        while index + digits < scalars.count, scalars[index + digits].value >= 0x30, scalars[index + digits].value <= 0x39 { digits += 1 }
        guard (1...9).contains(digits), index + digits + 1 < scalars.count else { return nil }
        let delimiter = scalars[index + digits]
        guard delimiter == "." || delimiter == ")", scalars[index + digits + 1] == " " || scalars[index + digits + 1] == "\t" else { return nil }
        let number = Int(String(String.UnicodeScalarView(scalars[index..<(index + digits)])))
        return (true, number, String(String.UnicodeScalarView(scalars[(index + digits + 2)...])))
    }

    // MARK: 인라인

    private enum Token {
        case text(String)
        case code(String)
        case delimiter(canOpen: Bool, canClose: Bool)
    }

    /// 인라인 해석: 코드 범위(같은 길이의 백틱끼리) → `**` 짝. 한 번에 한 겹, 한 번 훑는다
    private static func inlines(_ text: String) -> [Inline] {
        if text.utf8.count > maxInlineBytes { return [.text(text)] }
        let scalars = Array(text.unicodeScalars)
        var runs = BacktickRuns(scalars)
        var tokens: [Token] = []
        var buffer = String.UnicodeScalarView()
        func flush() {
            if !buffer.isEmpty {
                tokens.append(.text(String(buffer)))
                buffer = String.UnicodeScalarView()
            }
        }
        func isSpace(_ scalar: Unicode.Scalar) -> Bool { scalar.properties.isWhitespace }
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "`" {
                var end = index
                while end < scalars.count, scalars[end] == "`" { end += 1 }
                let run = end - index
                if let close = runs.closing(from: end, length: run) {
                    flush()
                    var content = String(String.UnicodeScalarView(scalars[end..<close]))
                    if content.hasPrefix(" "), content.hasSuffix(" "), content.contains(where: { $0 != " " }) { content = String(content.dropFirst().dropLast()) }
                    tokens.append(.code(content))
                    index = close + run
                } else {
                    buffer.append(contentsOf: scalars[index..<end])
                    index = end
                }
                continue
            }
            if scalar == "*", index + 1 < scalars.count, scalars[index + 1] == "*" {
                let previous = index > 0 ? scalars[index - 1] : nil
                let next = index + 2 < scalars.count ? scalars[index + 2] : nil
                flush()
                tokens.append(.delimiter(canOpen: next.map { !isSpace($0) } ?? false, canClose: previous.map { !isSpace($0) } ?? false))
                index += 2
                continue
            }
            buffer.append(scalar)
            index += 1
        }
        flush()
        return pair(tokens)
    }

    /// 한 번 훑어 길이별로 모아 둔 백틱 묶음의 시작들. "여는 묶음과 같은 길이의 다음 묶음"을 찾을 때 매번 끝까지 훑지 않는다 (여는 묶음마다 처음부터 끝까지 읽으면 짝 없는 묶음이 많을수록 느려진다).
    /// 여는 묶음은 왼쪽에서 오른쪽으로 오므로 길이마다 읽던 자리를 이어 간다 (전체 선형)
    private struct BacktickRuns {
        private var starts: [Int: [Int]] = [:]
        private var cursor: [Int: Int] = [:]

        init(_ scalars: [Unicode.Scalar]) {
            var index = 0
            while index < scalars.count {
                guard scalars[index] == "`" else {
                    index += 1
                    continue
                }
                var end = index
                while end < scalars.count, scalars[end] == "`" { end += 1 }
                starts[end - index, default: []].append(index)
                index = end
            }
        }

        /// `from`부터 정확히 `length`개인 백틱 묶음의 시작 (더 길거나 짧은 묶음은 건너뛴다). 없으면 nil
        mutating func closing(from start: Int, length: Int) -> Int? {
            guard let list = starts[length] else { return nil }
            var position = cursor[length, default: 0]
            while position < list.count, list[position] < start { position += 1 }
            cursor[length] = position
            return position < list.count ? list[position] : nil
        }
    }

    /// `**` 짝 맞추기 (겹치지 않는다: 먼저 닫을 수 있는 것이 닫는다). 짝이 없거나 안이 빈 `**`는 글자 그대로
    private static func pair(_ tokens: [Token]) -> [Inline] {
        var out: [Inline] = []
        /// 열려 있는 `**` 뒤에 쌓인 것 (닫히면 굵게가 된다)
        var inner: [Inline]?

        func appendText(_ text: String, to list: inout [Inline]) {
            if case .text(let last)? = list.last {
                list[list.count - 1] = .text(last + text)
            } else {
                list.append(.text(text))
            }
        }

        for token in tokens {
            switch token {
            case .text(let text):
                if inner != nil { appendText(text, to: &inner!) } else { appendText(text, to: &out) }
            case .code(let text):
                if inner != nil { inner!.append(.code(text)) } else { out.append(.code(text)) }
            case .delimiter(let canOpen, let canClose):
                if let current = inner {
                    if canClose, !current.isEmpty {
                        out.append(.bold(current))
                        inner = nil
                    } else if canClose {
                        // 안이 빈 `****`: 둘 다 글자 그대로
                        appendText("****", to: &out)
                        inner = nil
                    } else {
                        appendText("**", to: &inner!)
                    }
                } else if canOpen {
                    inner = []
                } else {
                    appendText("**", to: &out)
                }
            }
        }
        if let current = inner {
            // 닫히지 않은 `**`: 글자 그대로 돌려놓고 안의 것을 이어 붙인다
            appendText("**", to: &out)
            for inline in current {
                if case .text(let text) = inline { appendText(text, to: &out) } else { out.append(inline) }
            }
        }
        return out
    }

    // MARK: 도우미

    /// 시험 · 접근성: 보이는 글자만 이은 것 (문단 사이 빈 줄)
    public static func plainText(of blocks: [Block]) -> String {
        func text(_ inlines: [Inline]) -> String {
            inlines.map { inline in
                switch inline {
                case .text(let value), .code(let value): value
                case .bold(let inner): text(inner)
                }
            }.joined()
        }
        return blocks.map { block in
            switch block {
            case .paragraph(let inlines), .heading(let inlines): text(inlines)
            case .code(_, let code): code
            case .list(_, let items): items.map { text($0.inlines) }.joined(separator: "\n")
            }
        }.joined(separator: "\n\n")
    }

    /// 코드 블록의 글자 (복사는 울타리 줄 없는 글자만)
    public static func codeTexts(in blocks: [Block]) -> [String] {
        blocks.compactMap { if case .code(_, let text) = $0 { text } else { nil } }
    }
}
#endif
