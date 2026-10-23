#if os(macOS)
import Foundation

/// 백그라운드 일의 줄에서 **정해진 칸만** 꺼내는 규칙 (기록의 끝 알림 · 스트림의 `task_notification`이 같이 쓴다).
/// 아이디 · 상태 · 끝낸 코드 · 일의 종류뿐이다: 알림의 요약(`<summary>`)에는 모델이 쓴 설명이나 **명령 글**이 따옴표 안에 들어 있을 수 있어, 끝낸 코드만 읽고 글은 값으로 남기지 않는다.
/// 에이전트 알림의 `<result>` · `<note>`(모델의 글)도 읽지 않는다: 태그는 앞쪽(최대 `window`바이트)에서 처음 나온 것만 믿는다 (뒤쪽의 글이 태그 모양을 흉내 내도 앞의 진짜 태그가 이긴다)
enum BackgroundTaskText {
    /// 알림 글에서 태그를 찾는 앞쪽의 크기 (UTF-8 바이트)
    static let window = 8192

    /// 일의 아이디: 영숫자 · `_` · `-` 1–64자 (경로 · 공백 · 제어 글자가 들어갈 길을 막는다. 출력 파일 이름이 이 아이디로 만들어진다)
    static func isValidTaskID(_ id: String) -> Bool {
        guard (1...64).contains(id.utf8.count) else { return false }
        return id.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F }
    }

    /// 도구 호출 id: 1–128바이트 (읽기가 도구 줄에 붙이는 id와 같은 한도)
    static func isValidToolUseID(_ id: String) -> Bool { (1...128).contains(id.utf8.count) }

    /// `completed` → done, `failed` → failed, 그 밖(`stopped` · `killed` · 낯선 값)은 끝내지 못한 일(stopped): 모르는 값을 성공으로 말하지 않는다
    static func status(_ word: String) -> BackgroundTaskStatus {
        switch word {
        case "completed": .done
        case "failed": .failed
        default: .stopped
        }
    }

    /// 요약의 끝낸 코드: 가장 뒤의 "exit code N" (앞의 따옴표 안 글이 흉내 내도 뒤의 진짜가 이긴다). 숫자가 아홉 자리를 넘거나 없으면 nil
    static func exitCode(inSummary summary: String) -> Int? {
        guard let marker = summary.range(of: "exit code ", options: .backwards) else { return nil }
        let digits = summary[marker.upperBound...].prefix { $0.isASCII && $0.isNumber }
        guard (1...9).contains(digits.count) else { return nil }
        return Int(digits)
    }

    /// 요약의 앞말로 종류를 안다 ("Background command …" · "Agent …"). 모르면 nil
    static func kind(inSummary summary: String) -> BackgroundTaskKind? {
        if summary.hasPrefix("Background command") { return .command }
        if summary.hasPrefix("Agent") { return .agent }
        return nil
    }

    /// 앞쪽 `window`바이트에서 처음 나온 `<tag>…</tag>`의 안쪽 글 (없으면 nil)
    private static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"), let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
    }

    /// `<task-notification>` 글 → 끝 사건. 알림 모양이 아니거나 아이디 · 상태가 없거나 틀리면 nil
    static func notification(_ text: String, at date: Date?) -> BackgroundTaskEvent? {
        let head = String(decoding: text.utf8.prefix(window), as: UTF8.self)
        guard head.drop(while: { $0.isWhitespace }).hasPrefix("<task-notification>"),
              let taskID = tag("task-id", in: head)?.trimmingCharacters(in: .whitespacesAndNewlines), isValidTaskID(taskID),
              let statusWord = tag("status", in: head)?.trimmingCharacters(in: .whitespacesAndNewlines), !statusWord.isEmpty else { return nil }
        let status = status(statusWord)
        let summary = tag("summary", in: head) ?? ""
        let code = status == .stopped ? nil : exitCode(inSummary: summary)
        return .finished(taskID: taskID, kind: kind(inSummary: summary), status: status, exitCode: code, at: date)
    }
}
#endif
