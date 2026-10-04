import Foundation

/// 크레딧 기간: 기기 시간대의 이번 달 1일 0시 (`GET /credits?since=`, S3 This month)
public enum CreditsMonth {
    public static func start(of now: Date, timeZone: TimeZone = .current) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month], from: now)
        return calendar.date(from: DateComponents(year: c.year, month: c.month, day: 1)) ?? now
    }
}

/// 설정 S3 Usage & Credits (Figma 240:1907)의 행 값 · 부제. 합계는 서버가 정하고(`GET /credits`), 할 일 제목은 앱 목록에서 찾는다.
/// 문구는 Figma 그대로, Figma에 없는 경우(0 · 여럿 · 불러오기 실패)는 후보 (U2 Mac 계획 PR4 표).
public struct CreditsRows: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public let title: String
        public let value: String
        public let subtitle: String?
        /// Available 값만 굵게 (Figma)
        public let isEmphasized: Bool

        public init(title: String, value: String, subtitle: String?, isEmphasized: Bool = false) {
            self.title = title
            self.value = value
            self.subtitle = subtitle
            self.isEmphasized = isEmphasized
        }
    }

    /// 크레딧이 모자라 멈춘 run 카드 (제목 없는 구역, 누르면 런처 `Taskforce Working`)
    public struct PausedCard: Equatable, Sendable {
        public let title: String
        public let subtitle: String
    }

    public let available: Row
    public let reserved: Row
    /// 원가를 확인하는 중인 예약이 없으면 nil (행을 숨긴다, 후보)
    public let pending: Row?
    /// 멈춘 run이 없으면 nil (카드를 숨긴다)
    public let paused: PausedCard?
    public let used: Row
    public let included: Row
    /// 값을 한 번도 받지 못했는데 불러오기가 실패함 (빈 페이지 대신 "—"와 이 한 줄)
    public let notice: String?

    static let missing = "—"

    /// - `credits`: 마지막으로 받은 값 (전송 오류면 앞 값을 그대로 넘긴다), `checkedAt`: 그 값을 받은 시각
    /// - `pausedRuns`: 크레딧이 모자라 멈춘 끝나지 않은 run (`TaskforceReads.pausedRuns`)
    /// - `titles`: 할 일 제목 (앱 목록). 모르는 할 일은 제목 없이 센다
    public static func make(
        credits: CreditsSummary?, loadFailed: Bool, checkedAt: Date?, pausedRuns: [RunSummary], titles: [UUID: String],
        now: Date, timeZone: TimeZone = .current
    ) -> CreditsRows {
        let checked = checkedAt.map { "Checked \(clock($0, timeZone: timeZone))" }
        let available = Row(title: "Available", value: credits.map { "\($0.available)" } ?? missing, subtitle: checked, isEmphasized: true)
        let reserved = Row(
            title: "Reserved", value: credits.map { "\($0.heldForRunning)" } ?? missing,
            subtitle: credits.map { heldText(runs: $0.runningRuns) }
        )
        let pending = credits.flatMap { credits in
            credits.hasPending ? Row(title: "Pending", value: "Unknown", subtitle: checkingText(credits.settling.actionIDs, titles: titles)) : nil
        }
        let since = credits?.used?.since ?? CreditsMonth.start(of: now, timeZone: timeZone)
        let used = Row(title: "Used", value: credits?.used.map { "\($0.credits)" } ?? missing, subtitle: range(from: since, to: now, timeZone: timeZone))
        return CreditsRows(
            available: available,
            reserved: reserved,
            pending: pending,
            paused: pausedCard(pausedRuns, titles: titles),
            used: used,
            included: Row(title: "Included in your plan", value: "Not set yet", subtitle: "Pricing is not decided for the beta"),
            notice: credits == nil && loadFailed ? "Couldn't load credits." : nil
        )
    }

    /// "Held for 1 running task until it finishes" (Figma) · 여럿 · 0 (후보)
    static func heldText(runs: Int) -> String {
        switch runs {
        case ..<1: "Nothing held right now"
        case 1: "Held for 1 running task until it finishes"
        default: "Held for \(runs) running tasks until they finish"
        }
    }

    /// "<할 일 제목> is still being checked" (Figma) · 여럿 · 제목 모름 (후보)
    static func checkingText(_ actionIDs: [UUID], titles: [UUID: String]) -> String {
        let ids = unique(actionIDs)
        switch ids.count {
        case 0: return "Still being checked"
        case 1: return titles[ids[0]].map { "\($0) is still being checked" } ?? "1 task is still being checked"
        default: return "\(ids.count) tasks are still being checked"
        }
    }

    /// "2 paid steps are paused" / "QA 시나리오 업데이트, 데모 스크립트 초안. They continue when credits are added." (Figma)
    static func pausedCard(_ runs: [RunSummary], titles: [UUID: String]) -> PausedCard? {
        let paused = runs.filter { $0.isOpen && $0.holdReason == .credit }
        guard !paused.isEmpty else { return nil }
        let names = unique(paused.sorted { $0.isNewer(than: $1) }.map(\.actionID)).compactMap { titles[$0] }
        let title = paused.count == 1 ? "1 paid step is paused" : "\(paused.count) paid steps are paused"
        let tail = "They continue when credits are added."
        return PausedCard(title: title, subtitle: names.isEmpty ? tail : "\(names.joined(separator: ", ")). \(tail)")
    }

    /// "Oct 1 – Oct 4" (기기 시간대, 같은 날이면 "Oct 4")
    static func range(from start: Date, to end: Date, timeZone: TimeZone) -> String {
        let first = LocalDate(date: start, timeZone: timeZone)
        let last = LocalDate(date: end, timeZone: timeZone)
        let from = DueText.date(first, today: last)
        return first >= last ? from : "\(from) – \(DueText.date(last, today: last))"
    }

    /// 24시간제 "16:10" · "8:01" (`RefreshState.statusText`와 같은 모양)
    static func clock(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    private static func unique(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }
}
