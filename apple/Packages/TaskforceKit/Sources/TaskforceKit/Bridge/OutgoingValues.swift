#if os(macOS)
import Foundation

/// 서버로 나가는 값의 정리기 하나 (OA D2b 계약 7장 B8). 서버 zod(`contract.ts` D2a 블록)가 final로 거절하는 값을 보내면 사건이 dead-letter가 되거나
/// 등록이 400이 되므로, 길이 · 비어 있음 · NUL은 **보내기 전에** 여기서 맞춘다. 한도는 서버 한도 그대로이고 `Fixtures/bridge-v1/sanitizer-limits.json` 한 파일로
/// Swift 시험과 서버 시험(`swift-fixtures.test.ts`)이 함께 고정한다. 판단이 아니라 전송 모양의 제약이다.
public enum OutgoingValues {
    /// `external_task_id` · `event_id` · `external_session_id` · 산출물 `hash` (서버 `bridgeV1Identity`: 1–200자)
    public static let identityMaxChars = 200
    public static let workspaceRefMaxChars = 500
    public static let adapterVersionMaxChars = 50
    public static let artifactPathMaxChars = 1000
    public static let artifactSummaryMaxChars = 2000
    /// 산출물 `payload`를 JSONB 글자 모양으로 센 바이트 (서버 `bridgeV1JsonbText`)
    public static let artifactPayloadMaxBytes = 4096

    /// 값을 보내도 되나: 없다 · 이 값 · 거절
    public enum Checked: Equatable, Sendable {
        case absent
        case value(String)
        /// 서버가 final로 거절할 값이라 사건을 보내지 않는다 (자르면 다른 값이 되는 경우)
        case refused
    }

    /// 서버 JSONB는 NUL(U+0000)을 담지 못한다
    public static func stripNUL(_ text: String) -> String {
        text.unicodeScalars.contains("\u{0}") ? String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 != "\u{0}" })) : text
    }

    /// 글자 수는 유니코드 스칼라 기준이다 (서버는 JS `Array.from`으로 센다)
    static func count(_ text: String) -> Int { text.unicodeScalars.count }

    static func cut(_ text: String, _ limit: Int) -> String {
        count(text) <= limit ? text : String(String.UnicodeScalarView(text.unicodeScalars.prefix(limit)))
    }

    /// 1–200자이고 NUL이 없는 값. 아니면 nil (자르지 않는다: 잘린 id는 다른 id다)
    public static func identity(_ raw: String?) -> String? {
        guard let raw, (1...identityMaxChars).contains(count(raw)), !raw.unicodeScalars.contains("\u{0}") else { return nil }
        return raw
    }

    /// 비어 있으면 키를 뺀다, 500자를 넘거나 NUL이 있으면 거절한다 (자르지 않는다)
    public static func workspaceRef(_ raw: String?) -> Checked {
        guard let raw, !raw.isEmpty else { return .absent }
        guard count(raw) <= workspaceRefMaxChars, !raw.unicodeScalars.contains("\u{0}") else { return .refused }
        return .value(raw)
    }

    /// adapter `version`은 50자까지 (등록 · heartbeat 보고)
    public static func adapterVersion(_ raw: String?) -> String? {
        raw.map { cut(stripNUL($0), adapterVersionMaxChars) }
    }

    /// 산출물: NUL을 빼고 path 1000 · hash 200 · summary 2000자로 자른 뒤, payload가 4096바이트에 들어올 때까지 요약 → path → hash 순으로 줄인다.
    /// path나 hash가 비면 보낼 수 없다 (nil)
    public static func artifact(path: String, hash: String, summary: String) -> (path: String, hash: String, summary: String)? {
        var path = cut(stripNUL(path), artifactPathMaxChars)
        var hash = cut(stripNUL(hash), identityMaxChars)
        var summary = cut(stripNUL(summary), artifactSummaryMaxChars)
        guard !path.isEmpty, !hash.isEmpty else { return nil }
        func over() -> Int { artifactPayloadBytes(path: path, hash: hash, summary: summary) - artifactPayloadMaxBytes }
        while over() > 0 {
            let step = max(1, over() / 6)
            if !summary.isEmpty {
                summary = String(String.UnicodeScalarView(summary.unicodeScalars.dropLast(step)))
            } else if count(path) > 1 {
                path = String(String.UnicodeScalarView(path.unicodeScalars.dropLast(min(step, count(path) - 1))))
            } else if count(hash) > 1 {
                hash = String(String.UnicodeScalarView(hash.unicodeScalars.dropLast(min(step, count(hash) - 1))))
            } else {
                return nil
            }
        }
        return (path, hash, summary)
    }

    /// 서버가 `payload`로 저장할 JSON의 크기 (JSONB 글자 모양: 구분자 뒤에 공백)
    public static func artifactPayloadBytes(path: String, hash: String, summary: String) -> Int {
        let text = "{\"path\": \(Outbox.jsonString(path)), \"hash\": \(Outbox.jsonString(hash)), \"summary\": \(Outbox.jsonString(summary))}"
        return text.utf8.count
    }
}
#endif
