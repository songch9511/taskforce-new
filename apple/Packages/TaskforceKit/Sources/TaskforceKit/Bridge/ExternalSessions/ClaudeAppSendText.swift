#if os(macOS)
import Foundation

/// 보내는 글의 정리 (PR-D3k, 계약 25.4.1): 대상 기록에서 **같은 글**로 읽혀야 "Received"가 된다 (`ClaudeAppExchangeCollector`가 바이트까지 맞춰 본다).
/// 기록 읽기(`ClaudeAppTranscriptReader`)는 제어 글자 · 눈에 보이지 않는 서식 글자(ZWJ · ZWNJ는 둔다) · 줄 구분(U+2028 · U+2029)을 지우고 앞뒤 공백을 자르며, CLI는 인자 끝의 공백 · 줄바꿈을 자른다 (탐침).
/// 그래서 보내기 전에 같은 정리를 먼저 한다: 정리한 글은 어디를 지나도 한 글자도 다르지 않다. CRLF · CR은 줄바꿈 하나로 합친다 (`\r`을 그냥 지우면 줄이 붙는다)
public enum ClaudeAppSendText {
    /// 보낼 글의 상한 (UTF-16 칸): mod · 서버와 같다
    public static let maxLength = ClaudeAppRelay.maxTextLength

    /// 정리한 글. 남는 것이 없으면 nil
    public static func normalize(_ raw: String) -> String? {
        let unified = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let kept = unified.unicodeScalars.filter { !ClaudeAppTranscriptReader.isStripped($0) }
        let text = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// 1–16,000 UTF-16 칸인가 (정리한 글에 쓴다)
    public static func isSendable(_ text: String) -> Bool {
        (1...maxLength).contains(text.utf16.count)
    }
}
#endif
