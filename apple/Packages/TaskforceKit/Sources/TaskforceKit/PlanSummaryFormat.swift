import Foundation

/// Plan & usage의 날짜 · 토큰 수 표기 (DZ 그림의 한 형식). 영어 월 이름을 직접 쓴다: 앱 화면 틀은 영어이고 기기 언어에 따라 달라지지 않는다 (시험이 고정한다).
public enum PlanSummaryFormat {
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// "Nov 8" · 다른 해는 "Oct 8, 2027". 날은 기기 시간대의 달력 날이다 (`calendar`)
    public static func date(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = calendar.component(.year, from: now)
        guard let y = parts.year, let m = parts.month, let d = parts.day, (1...12).contains(m) else { return "" }
        return y == year ? "\(months[m - 1]) \(d)" : "\(months[m - 1]) \(d), \(y)"
    }

    /// "850 tokens" · "12.3K tokens" · "2.4M tokens" · "1,284.6M tokens". 소수 한 자리, 정수 부분은 세 자리마다 쉼표
    public static func tokens(_ count: Int) -> String {
        let n = max(count, 0)
        if n < 1_000 { return n == 1 ? "1 token" : "\(n) tokens" }
        if n < 999_950 { return "\(tenths((n + 50) / 100))K tokens" }
        return "\(tenths((n + 50_000) / 100_000))M tokens"
    }

    /// 10분의 1 단위 정수 → "12.3" · "1,284.6"
    private static func tenths(_ value: Int) -> String {
        let whole = value / 10
        let digits = String(whole)
        var grouped = ""
        for (offset, character) in digits.reversed().enumerated() {
            if offset > 0, offset % 3 == 0 { grouped.append(",") }
            grouped.append(character)
        }
        return "\(String(grouped.reversed())).\(value % 10)"
    }
}
