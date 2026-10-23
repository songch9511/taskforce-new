#if os(macOS)
import Foundation

/// 일한 시간의 모양 (DZ v2 E5 · E6). 시간은 **시계 시간**이다 (승인을 기다린 시간도 들어간다). 10초 미만 · 시각을 모르는 턴은 줄이 없다 (지어내지 않는다)
public enum SessionTime {
    /// 이보다 짧게 끝난 턴에는 시간 줄이 없다
    public static let hideBelow: TimeInterval = 10

    /// 음수 · 무한대 · 숫자가 아닌 값은 0초다
    private static func whole(_ seconds: TimeInterval) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int(min(seconds, 1_000_000_000))
    }

    /// 끝난 턴: `42s` · `4m 12s` · `1h 8m` (시간이 넘으면 초는 쓰지 않는다)
    public static func worked(_ seconds: TimeInterval) -> String {
        let total = whole(seconds)
        if total >= 3600 { return "\(total / 3600)h \((total % 3600) / 60)m" }
        if total >= 60 { return "\(total / 60)m \(total % 60)s" }
        return "\(total)s"
    }

    /// 도는 중: `0:07` · `1:48` · `1:02:30` (한 시간이 넘으면 시:분:초)
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = whole(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let rest = total % 60
        if hours > 0 { return "\(hours):" + twoDigits(minutes) + ":" + twoDigits(rest) }
        return "\(minutes):" + twoDigits(rest)
    }

    private static func twoDigits(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }

    /// 끝난 턴의 줄 "Worked for 4m 12s". 모르거나 10초 미만이면 nil
    public static func workedLine(_ seconds: TimeInterval?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= hideBelow else { return nil }
        return "\(SessionViewCopy.workedFor) \(worked(seconds))"
    }

    /// 도는 턴의 줄 "Working · 1:48"
    public static func workingLine(_ seconds: TimeInterval) -> String {
        "\(SessionViewCopy.working) · \(clock(seconds))"
    }

    /// 두 시각의 차이. 하나라도 모르거나 끝이 시작보다 앞서면(시계가 어긋남) nil
    public static func elapsed(from start: Date?, to end: Date?) -> TimeInterval? {
        guard let start, let end else { return nil }
        let value = end.timeIntervalSince(start)
        return value >= 0 ? value : nil
    }
}
#endif
