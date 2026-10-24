#if os(macOS)
import Foundation

extension SavedChatRow {
    /// 줄 둘째 줄: "시각 · 기기 이름" (기기 이름이 없으면 시각만). 시각은 On this Mac의 줄과 같은 규칙이다 (`now` · `N min ago` · `Yesterday` · `Mon` · `Oct 3`)
    public func metaText(now: Date, timeZone: TimeZone = .current) -> String {
        [ExternalSessionLineText.timeLabel(lastMessageAt, now: now, timeZone: timeZone), deviceName].compactMap { $0 }.joined(separator: " · ")
    }

    /// 접근성 이름: "제목 — 둘째 줄" (DZ 접근성: 줄 이름 "제목 — 시각 · 기기")
    public func accessibilityName(now: Date, timeZone: TimeZone = .current) -> String {
        "\(displayTitle) — \(metaText(now: now, timeZone: timeZone))"
    }

    /// 읽기 패널 머리의 둘째 줄: "기기 이름 · Oct 22" (기기 이름이 없으면 날짜만). 날짜는 마지막 말의 날(기기 시간대)이다
    public func headerLine(now: Date, timeZone: TimeZone = .current) -> String {
        let today = LocalDate(date: now, timeZone: timeZone)
        return [deviceName, DueText.date(LocalDate(date: lastMessageAt, timeZone: timeZone), today: today)].compactMap { $0 }.joined(separator: " · ")
    }
}
#endif
