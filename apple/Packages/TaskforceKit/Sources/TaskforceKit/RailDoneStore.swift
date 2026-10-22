import Foundation

// 레일의 "열 때까지 남는 끝남" 저장 (OA PR-D2, 계약 23장): 끝난 링(초록)은 사용자가 열어 볼 때까지 레일에 남는다 (타이머 없음).
// 아직 안 연 끝남의 표시는 이 Mac에 저장해 앱을 다시 켠 뒤에도 남고, 열어 보면 지운다. 새 턴이 오면 그 표시는 새 상태가 대신한다 (세션 저장소 · 셸이 정한다).
// 저장하는 것은 id · 본 시각뿐이다 — 제목 · 글 · 경로 · 서버로 가는 것 0. Claude 데스크톱 세션의 표시(pid 포함)는 `ClaudeAppDoneStore`가 따로 둔다.

/// 아직 열어 보지 않은 끝남의 표시 (id → 끝난 것을 본 시각). Taskforce 세션과 v1 run(이슈)을 따로 센다
public struct RailDoneMarks: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// 칸마다 이만큼(새것 먼저)까지만 저장한다: 저장소가 커지지 않게
    public static let limit = 256

    /// Taskforce 세션 id → 마지막 task가 끝난 것을 본 시각
    public var sessions: [UUID: Date]
    /// 이슈(v1 run) id → 일이 끝난 것을 본 시각
    public var issues: [UUID: Date]
    /// 이 표시의 주인 계정 (보안 P3-1): 로그인한 계정이 이것과 다르면(또는 모르면) 이 표시는 그 계정의 것이 아니라 지운다 (고정을 계정별로 가지치기하는 것과 같다). 모르면 nil
    public var owner: UUID?

    public init(sessions: [UUID: Date] = [:], issues: [UUID: Date] = [:], owner: UUID? = nil) {
        self.sessions = sessions
        self.issues = issues
        self.owner = owner
    }

    private enum CodingKeys: String, CodingKey { case sessions, issues, owner }

    /// 읽을 수 있는 것만 읽는다: 모르는 모양의 칸 · UUID가 아닌 키는 건너뛴다 (죽지 않는다). 읽을 수 없는 주인은 모른다(nil)
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessions = Self.read(container, .sessions)
        issues = Self.read(container, .issues)
        owner = (try? container.decode(String.self, forKey: .owner)).flatMap(UUID.init(uuidString:))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.write(sessions), forKey: .sessions)
        try container.encode(Self.write(issues), forKey: .issues)
        try container.encodeIfPresent(owner?.uuidString.lowercased(), forKey: .owner)
    }

    private static func read(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [UUID: Date] {
        guard let raw = try? container.decode([String: Double].self, forKey: key) else { return [:] }
        var out: [UUID: Date] = [:]
        for (text, seconds) in raw {
            guard let id = UUID(uuidString: text), seconds.isFinite else { continue }
            out[id] = Date(timeIntervalSince1970: seconds)
        }
        return out
    }

    /// 새것 먼저 `limit`개까지, 키는 소문자 UUID 글자
    private static func write(_ marks: [UUID: Date]) -> [String: Double] {
        let newest = marks.sorted { ($0.value, $0.key.uuidString) > ($1.value, $1.key.uuidString) }.prefix(limit)
        return Dictionary(uniqueKeysWithValues: newest.map { ($0.key.uuidString.lowercased(), $0.value.timeIntervalSince1970) })
    }

    /// 개수만 말한다: id를 찍지 않는다
    public var description: String { "RailDoneMarks(sessions: \(sessions.count), issues: \(issues.count))" }
    public var debugDescription: String { description }
}

/// `UserDefaults`가 하는 일의 좁은 면 (시험은 실제 설정 도메인을 만들지 않으려고 사전으로 바꾼다)
public protocol RailDoneDefaults: AnyObject, Sendable {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: RailDoneDefaults {}

/// 끝남 표시를 두는 곳. **메인 액터에서만 쓴다** (읽고 고쳐 쓰는 `update`가 원자적이지 않다)
public protocol RailDoneStore: AnyObject, Sendable {
    func load() -> RailDoneMarks
    func save(_ marks: RailDoneMarks)
    /// 계정이 떠났다: 남기지 않는다
    func clear()
}

extension RailDoneStore {
    /// 읽고 → 고치고 → 쓴다
    public func update(_ body: (inout RailDoneMarks) -> Void) {
        var marks = load()
        body(&marks)
        save(marks)
    }

    /// 표시의 주인 계정을 적는다 (다른 칸은 그대로). nil이면 모른다
    public func setOwner(_ owner: UUID?) {
        update { $0.owner = owner }
    }
}

public final class InMemoryRailDoneStore: RailDoneStore, @unchecked Sendable {
    private let lock = NSLock()
    private var marks = RailDoneMarks()

    public init() {}

    public func load() -> RailDoneMarks { lock.withLock { marks } }
    public func save(_ marks: RailDoneMarks) { lock.withLock { self.marks = marks } }
    public func clear() { lock.withLock { marks = RailDoneMarks() } }
}

/// 이 Mac의 설정(앱 도메인)에 JSON 하나로 둔다. 읽을 수 없으면 빈 표시로 시작한다
public final class UserDefaultsRailDoneStore: RailDoneStore, @unchecked Sendable {
    public static let key = "taskforce.rail.doneMarks"
    private let defaults: any RailDoneDefaults

    public init(defaults: any RailDoneDefaults = UserDefaults.standard) { self.defaults = defaults }

    public func load() -> RailDoneMarks {
        guard let data = defaults.object(forKey: Self.key) as? Data, let marks = try? JSONDecoder().decode(RailDoneMarks.self, from: data) else { return RailDoneMarks() }
        return marks
    }

    public func save(_ marks: RailDoneMarks) {
        guard let data = try? JSONEncoder().encode(marks) else { return }
        defaults.set(data, forKey: Self.key)
    }

    public func clear() { defaults.set(nil, forKey: Self.key) }
}
