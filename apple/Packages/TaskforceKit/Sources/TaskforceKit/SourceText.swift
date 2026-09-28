import Foundation

/// 원문을 줄 단위로 보여주고, 사용자가 고른 줄 범위를 원문 그대로의 인용으로 만든다.
/// 서버는 신고 구절이 원문에 실제로 있는지 확인하므로 (`quoteInText`) 인용은 반드시 `raw_text`의 부분 문자열이어야 한다.
public struct SourceText: Sendable {
    public struct Line: Sendable, Hashable, Identifiable {
        /// 0부터
        public let index: Int
        /// 줄바꿈 문자를 뺀 그 줄 (`\r` 포함하지 않음)
        public let text: String
        /// `raw`에서 이 줄의 위치 (줄바꿈 제외)
        let range: Range<String.Index>

        public var id: Int { index }
        public var isBlank: Bool { text.allSatisfy(\.isWhitespace) }
    }

    /// 서버가 받는 신고 구절 최대 길이 (contract.ts `missingReportRequestSchema`)
    public static let maxQuoteLength = 2000

    public let raw: String
    public let lines: [Line]

    public init(_ raw: String) {
        self.raw = raw
        var lines: [Line] = []
        var start = raw.startIndex
        var index = 0
        // "\r\n"은 Swift에서 한 Character라 "\n"과 따로 본다
        while true {
            let end = raw[start...].firstIndex(where: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) ?? raw.endIndex
            lines.append(Line(index: index, text: String(raw[start..<end]), range: start..<end))
            index += 1
            guard end < raw.endIndex else { break }
            start = raw.index(after: end)
        }
        self.lines = lines
    }

    /// 고른 줄들을 원문 그대로 이어 붙인 구절 (앞뒤 공백 · 빈 줄 제외). 전부 빈 줄이면 nil.
    public func quote(lines selected: ClosedRange<Int>) -> String? {
        guard !lines.isEmpty else { return nil }
        let lower = max(selected.lowerBound, 0)
        let upper = min(selected.upperBound, lines.count - 1)
        guard lower <= upper else { return nil }
        let text = raw[lines[lower].range.lowerBound..<lines[upper].range.upperBound]
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 근거 인용이 걸쳐 있는 줄 번호들. 서버처럼 공백 · 문장부호 차이는 무시하고,
    /// "…"로 이은 인용은 조각마다 찾는다. 한 인용은 최대 `maxSpan`줄에 걸친다고 본다.
    public func lineIndexes(matching quotes: [String], maxSpan: Int = 10) -> Set<Int> {
        let normalizedLines = lines.map { Self.normalize($0.text) }
        var result = Set<Int>()
        for quote in quotes {
            for fragment in Self.fragments(quote) {
                if let span = Self.span(of: fragment, in: normalizedLines, maxSpan: maxSpan) {
                    result.formUnion(span)
                }
            }
        }
        return result
    }

    /// 조각이 끝나는 줄을 먼저 찾고, 거꾸로 가장 가까운 시작 줄을 찾는다 (서버 `quoteContext`와 같은 방식).
    static func span(of fragment: String, in normalizedLines: [String], maxSpan: Int) -> ClosedRange<Int>? {
        for end in normalizedLines.indices {
            var joined = ""
            for start in stride(from: end, through: max(0, end - maxSpan), by: -1) {
                joined = normalizedLines[start] + joined
                if joined.contains(fragment) { return start...end }
            }
        }
        return nil
    }

    static func fragments(_ quote: String) -> [String] {
        quote
            .replacingOccurrences(of: "…", with: "...")
            .components(separatedBy: "..")
            .map(normalize)
            .filter { !$0.isEmpty }
    }

    /// 서버 `normalizeForMatch`: 소문자, 공백 · 문장부호 · 기호 제거
    static func normalize(_ text: String) -> String {
        String(String.UnicodeScalarView(text.lowercased().unicodeScalars.filter { scalar in
            let p = scalar.properties
            if p.isWhitespace { return false }
            switch p.generalCategory {
            case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
                 .finalPunctuation, .otherPunctuation, .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
                return false
            default:
                return true
            }
        }))
    }
}

/// 원문 줄 범위 고르기. 첫 탭은 한 줄, 두 번째 탭은 거기까지 범위, 범위가 있을 때 누르면 새로 시작한다.
/// 한 줄만 고른 상태에서 같은 줄을 다시 누르면 선택을 푼다.
public struct LineSelection: Sendable, Equatable {
    public private(set) var range: ClosedRange<Int>?

    public init(range: ClosedRange<Int>? = nil) {
        self.range = range
    }

    public mutating func tap(_ line: Int) {
        guard let current = range else {
            range = line...line
            return
        }
        if current.count == 1 {
            let anchor = current.lowerBound
            range = anchor == line ? nil : min(anchor, line)...max(anchor, line)
        } else {
            range = line...line
        }
    }

    public mutating func clear() {
        range = nil
    }

    public func contains(_ line: Int) -> Bool {
        range?.contains(line) ?? false
    }
}
