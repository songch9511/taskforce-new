import Foundation

/// 서버 API와 Supabase 행을 같은 규칙으로 읽고 쓰는 JSON 코더.
public enum TaskforceJSON {
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = PostgresTimestamp.parse(string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "시각 형식이 아닙니다: \(string)")
            }
            return date
        }
        return decoder
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

/// Postgres · 서버가 돌려주는 ISO 8601 시각. 마이크로초(`.123456`), `+00:00` · `Z` · 오프셋 없음,
/// 날짜와 시각 사이의 공백(`2026-09-27 01:02:03+00`)을 모두 받는다. 오프셋이 없으면 UTC로 본다.
public enum PostgresTimestamp {
    nonisolated(unsafe) private static let pattern =
        /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2})(?:[.,](\d+))?)?\s*(Z|z|[+-]\d{2}(?::?\d{2})?)?$/

    public static func parse(_ string: String) -> Date? {
        guard let m = string.trimmingCharacters(in: .whitespaces).wholeMatch(of: pattern) else { return nil }
        var components = DateComponents()
        components.calendar = utcCalendar
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = Int(m.1)
        components.month = Int(m.2)
        components.day = Int(m.3)
        components.hour = Int(m.4)
        components.minute = Int(m.5)
        components.second = m.6.flatMap { Int($0) } ?? 0
        guard components.isValidDate, let base = utcCalendar.date(from: components) else { return nil }

        var fraction = 0.0
        if let digits = m.7 {
            fraction = Double("0." + digits) ?? 0
        }
        var offset = 0
        if let zone = m.8, zone != "Z", zone != "z" {
            let sign = zone.hasPrefix("-") ? -1 : 1
            let digits = zone.dropFirst().filter(\.isNumber)
            let hours = Int(digits.prefix(2)) ?? 0
            let minutes = digits.count >= 4 ? Int(digits.dropFirst(2).prefix(2)) ?? 0 : 0
            offset = sign * (hours * 3600 + minutes * 60)
        }
        return base.addingTimeInterval(fraction - Double(offset))
    }

    static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
}

/// 시각 없는 날짜 (`YYYY-MM-DD`). 기한 · 주 시작일에 쓴다. 시간대와 무관하게 그 날짜 자체를 뜻한다.
public struct LocalDate: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(year: Int, month: Int, day: Int) {
        var components = DateComponents(year: year, month: month, day: day)
        components.calendar = PostgresTimestamp.utcCalendar
        guard components.isValidDate else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    public init?(_ string: String) {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2])
        else { return nil }
        self.init(year: y, month: m, day: d)
    }

    /// `date`가 `timeZone`에서 몇 월 며칠인지.
    public init(date: Date, timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.year = c.year!
        self.month = c.month!
        self.day = c.day!
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// 그날 0시(UTC). 날짜 계산용.
    var utcMidnight: Date {
        PostgresTimestamp.utcCalendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// 1 = 일요일 … 7 = 토요일
    public var weekday: Int {
        PostgresTimestamp.utcCalendar.component(.weekday, from: utcMidnight)
    }

    public func adding(days: Int) -> LocalDate {
        let date = PostgresTimestamp.utcCalendar.date(byAdding: .day, value: days, to: utcMidnight)!
        return LocalDate(date: date, timeZone: TimeZone(secondsFromGMT: 0)!)
    }

    /// `other`에서 이 날짜까지 며칠 (이 날짜가 뒤면 양수).
    public func days(since other: LocalDate) -> Int {
        PostgresTimestamp.utcCalendar.dateComponents([.day], from: other.utcMidnight, to: utcMidnight).day ?? 0
    }

    public static func < (lhs: LocalDate, rhs: LocalDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let value = LocalDate(string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "날짜 형식(YYYY-MM-DD)이 아닙니다: \(string)")
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// jsonb 열(`action_events.before` · `after`)처럼 모양이 정해지지 않은 값.
public enum JSONValue: Hashable, Sendable, Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .number(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    public var isNull: Bool { self == .null }
}
