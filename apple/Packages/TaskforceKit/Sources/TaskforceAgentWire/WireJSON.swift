#if os(macOS)
import Foundation

/// helper · bridge 소켓이 주고받는 JSON 값 (OA D3a 계약 2.6). 정수 · 실수 · 참거짓을 섞지 않고, 정규 글자(키 정렬 · 공백 없음)를 만든다:
/// 같은 입력은 키 순서와 상관없이 같은 글자 → 같은 digest (보류 때와 답 resume 때 입력이 같은지 본다, L3 · G16)
public enum WireJSON: Equatable, Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([WireJSON])
    case object([String: WireJSON])

    /// 객체의 값 (객체가 아니면 nil)
    public subscript(key: String) -> WireJSON? {
        if case .object(let fields) = self { return fields[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var int64Value: Int64? {
        if case .int(let value) = self { return value }
        return nil
    }

    public var arrayValue: [WireJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: WireJSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    // MARK: 읽기

    /// UTF-8 JSON 하나를 읽는다. 깨진 JSON · UTF-8이 아닌 바이트 · 앞뒤 쓰레기는 `WireError.malformed`
    public static func parse(_ data: Data) throws -> WireJSON {
        do {
            return try JSONDecoder().decode(WireJSON.self, from: data)
        } catch {
            throw WireError.malformed
        }
    }

    // MARK: 정규 글자

    /// 키를 정렬하고 공백 없이 쓴 글자. 글자열 이스케이프는 JS `JSON.stringify`와 같다 (`"` `\` 제어 문자만)
    public var canonicalText: String {
        var out = ""
        Self.write(self, into: &out)
        return out
    }

    public var canonicalData: Data { Data(canonicalText.utf8) }

    private static func write(_ value: WireJSON, into out: inout String) {
        switch value {
        case .null: out += "null"
        case .bool(let flag): out += flag ? "true" : "false"
        case .int(let number): out += String(number)
        case .double(let number):
            if number.isFinite, number == number.rounded(), abs(number) < 1e15 {
                out += String(Int64(number))
            } else if number.isFinite {
                out += "\(number)"
            } else {
                out += "null"
            }
        case .string(let text): writeString(text, into: &out)
        case .array(let items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                write(item, into: &out)
            }
            out += "]"
        case .object(let fields):
            out += "{"
            for (index, key) in fields.keys.sorted().enumerated() {
                if index > 0 { out += "," }
                writeString(key, into: &out)
                out += ":"
                write(fields[key]!, into: &out)
            }
            out += "}"
        }
    }

    private static func writeString(_ text: String, into out: inout String) {
        out += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{8}": out += "\\b"
            case "\u{c}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}

extension WireJSON: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let flag = try? container.decode(Bool.self) {
            self = .bool(flag)
        } else if let number = try? container.decode(Int64.self) {
            self = .int(number)
        } else if let number = try? container.decode(Double.self) {
            self = .double(number)
        } else if let text = try? container.decode(String.self) {
            self = .string(text)
        } else if let items = try? container.decode([WireJSON].self) {
            self = .array(items)
        } else {
            self = .object(try container.decode([String: WireJSON].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let flag): try container.encode(flag)
        case .int(let number): try container.encode(number)
        case .double(let number): try container.encode(number)
        case .string(let text): try container.encode(text)
        case .array(let items): try container.encode(items)
        case .object(let fields): try container.encode(fields)
        }
    }
}

/// 선 규약 오류. 어느 것이든 훅은 deny, bridge는 그 연결을 deny로 닫는다
public enum WireError: Error, Equatable, Sendable {
    case malformed
    case tooLarge
    case unsupportedVersion
    case unknownField
    case missingField
    case pathTooLong
    case timedOut
    case connectFailed
    case closed
}

/// 유니코드 스칼라 개수 (서버 zod는 JS `Array.from`으로 센다)
func scalarCount(_ text: String) -> Int { text.unicodeScalars.count }
#endif
