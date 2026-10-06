import Foundation

// 목록 섹션 접기 (Figma "길고 많을 때": Review 2 · In Progress 5 · To Do 5까지 보이고 나머지는 "Show N More", Done Today는 접힌 한 줄).
// 기준값은 서버가 준다 (`/now` `section_limits`, 앱 배포 없이 조정). 개수는 받은 목록을 앱이 센다.

/// contract.ts `nowResponseSchema.section_limits`: 섹션마다 처음에 보일 행 수 (양의 정수)
public struct SectionLimits: Decodable, Sendable, Hashable {
    public let review: Int
    public let inProgress: Int
    public let toDo: Int

    /// 서버가 보내지 않을 때 (Figma 시안 값)
    public static let standard = SectionLimits(review: 2, inProgress: 5, toDo: 5)

    enum CodingKeys: String, CodingKey {
        case review
        case inProgress = "in_progress"
        case toDo = "to_do"
    }

    public init(review: Int, inProgress: Int, toDo: Int) {
        self.review = review
        self.inProgress = inProgress
        self.toDo = toDo
    }

    /// 빠졌거나 양의 정수가 아닌 값은 그 섹션만 기본값으로 둔다
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value(_ key: CodingKeys, _ fallback: Int) -> Int {
            guard let number = try? c.decodeIfPresent(Int.self, forKey: key), number > 0 else { return fallback }
            return number
        }
        self.init(
            review: value(.review, Self.standard.review),
            inProgress: value(.inProgress, Self.standard.inProgress),
            toDo: value(.toDo, Self.standard.toDo)
        )
    }

    /// 그 섹션의 기준값. Done Today는 행 수가 아니라 접힌 한 줄이라 nil
    public func limit(for group: TaskGroup) -> Int? {
        switch group {
        case .review: review
        case .inProgress: inProgress
        case .toDo: toDo
        case .doneToday: nil
        }
    }
}

/// User-selected visible row count for one launcher section. `all` is the default;
/// selecting a number is the only way to add a Show More row.
public enum SectionDisplayLimit: Int, CaseIterable, Identifiable, Sendable, Hashable {
    case all = 0
    case five = 5
    case ten = 10
    case twenty = 20
    case fifty = 50

    public var id: Int { rawValue }

    public var displayName: String { self == .all ? "All" : "\(rawValue)" }

    public var count: Int? { self == .all ? nil : rawValue }
}

/// Mac launcher presentation preferences, stored locally and independently from the
/// server's `section_limits` contract.
public struct SectionDisplayPreferences: Sendable, Hashable {
    public static let defaultsKey = "launcher.section-display.v1"
    public static let all = SectionDisplayPreferences()

    public var review: SectionDisplayLimit
    public var inProgress: SectionDisplayLimit
    public var toDo: SectionDisplayLimit
    public var doneToday: SectionDisplayLimit

    public init(
        review: SectionDisplayLimit = .all,
        inProgress: SectionDisplayLimit = .all,
        toDo: SectionDisplayLimit = .all,
        doneToday: SectionDisplayLimit = .all
    ) {
        self.review = review
        self.inProgress = inProgress
        self.toDo = toDo
        self.doneToday = doneToday
    }

    public static func load(from defaults: UserDefaults = .standard) -> SectionDisplayPreferences {
        func value(_ group: TaskGroup) -> SectionDisplayLimit {
            guard let rawValue = defaults.object(forKey: key(for: group)) as? Int,
                  let limit = SectionDisplayLimit(rawValue: rawValue) else { return .all }
            return limit
        }
        return SectionDisplayPreferences(
            review: value(.review), inProgress: value(.inProgress), toDo: value(.toDo), doneToday: value(.doneToday)
        )
    }

    public func save(to defaults: UserDefaults = .standard) {
        for group in TaskGroup.allCases {
            defaults.set(limit(for: group).rawValue, forKey: Self.key(for: group))
        }
    }

    public func limit(for group: TaskGroup) -> SectionDisplayLimit {
        switch group {
        case .review: review
        case .inProgress: inProgress
        case .toDo: toDo
        case .doneToday: doneToday
        }
    }

    private static func key(for group: TaskGroup) -> String {
        "\(defaultsKey).\(group.rawValue)"
    }
}

/// 섹션 하나를 어떻게 보이나
public enum SectionFold: Sendable, Hashable {
    /// 다 보인다
    case all
    /// 앞 `visible`개만 보이고 나머지 `hidden`개는 "Show N More" 한 줄
    case capped(visible: Int, hidden: Int)
    /// 섹션 머리 한 줄만 (Done Today: 이름 · 개수 · ›)
    case collapsed

    /// 보이는 행 수
    public func visibleCount(of count: Int) -> Int {
        switch self {
        case .all: count
        case .capped(let visible, _): visible
        case .collapsed: 0
        }
    }
}

/// 섹션 접기 상태. 펼침은 섹션마다 따로 기억한다 (Show N More · Done Today 머리).
/// 찾는 중이거나 범위를 고른 동안에는 접지 않는다: 찾기가 접힌 행도 찾고, 범위는 그 섹션 전체를 보인다.
public struct SectionCaps: Sendable, Hashable {
    public var limits: SectionLimits
    /// Non-nil preferences override server limits and cover Done Today as well.
    public var displayPreferences: SectionDisplayPreferences?
    public private(set) var expanded: Set<TaskGroup> = []

    /// User-facing launcher default: show every section in full.
    public init(displayPreferences: SectionDisplayPreferences = .all) {
        self.limits = .standard
        self.displayPreferences = displayPreferences
    }

    /// Compatibility path for callers that still want the `/now` server limits.
    public init(limits: SectionLimits) {
        self.limits = limits
        self.displayPreferences = nil
    }

    public init(limits: SectionLimits, displayPreferences: SectionDisplayPreferences) {
        self.limits = limits
        self.displayPreferences = displayPreferences
    }

    /// Apply a local settings change to an already-presented launcher.
    public mutating func apply(displayPreferences: SectionDisplayPreferences) {
        self.displayPreferences = displayPreferences
        expanded = []
    }

    /// 접지 않는 때: 찾는 중 · All Tasks가 아닌 범위
    public static func isUnfolded(query: String, scope: TaskScope) -> Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || scope != .allTasks
    }

    public func fold(_ group: TaskGroup, count: Int, query: String = "", scope: TaskScope = .allTasks) -> SectionFold {
        if Self.isUnfolded(query: query, scope: scope) || expanded.contains(group) { return .all }
        if let preference = displayPreferences?.limit(for: group) {
            guard let limit = preference.count else { return .all }
            return count > limit ? .capped(visible: limit, hidden: count - limit) : .all
        }
        guard let limit = limits.limit(for: group) else { return count == 0 ? .all : .collapsed }
        return count > limit ? .capped(visible: limit, hidden: count - limit) : .all
    }

    /// "Show N More" · Done Today 머리를 열었다
    public mutating func expand(_ group: TaskGroup) {
        expanded.insert(group)
    }

    /// Done Today 머리를 다시 눌렀다 (열고 닫기)
    public mutating func toggle(_ group: TaskGroup) {
        if expanded.remove(group) == nil { expanded.insert(group) }
    }

    /// 처음 모양으로 (계정 전환 등)
    public mutating func reset() {
        expanded = []
    }
}
