import CoreGraphics
import Foundation

// Assistant 창 관리의 순수 규칙 (OA U1, DS "Assistant window"): 창 하나 = 대화 하나, 여러 개 동시에, 최대 8개, 위치는 대화 id별 · 화면별로 앱 로컬에 기억.
// AppKit 창은 앱(`Mac/Assistant`)이 만들고, 어느 창이 어느 대화를 보이고 무엇을 앞으로 가져오는지는 이 값이 정한다 (시험으로 고정).

public struct AssistantWindowRegistry: Equatable, Sendable {
    /// 창 개수 상한 (U1-15): 넘으면 새 창 대신 가장 오래 쓰지 않은 창을 앞으로 가져온다
    public static let maxWindows = 8

    public enum OpenOutcome: Equatable, Sendable {
        /// 새 창
        case opened(UUID)
        /// 그 대화를 이미 보이는 창이 있다: 그 창을 앞으로 (숨었으면 다시 보인다)
        case reused(UUID)
        /// 상한: 새 창을 만들지 않고 이 창을 앞으로
        case atCapacity(raise: UUID)
    }

    public enum RebindOutcome: Equatable, Sendable {
        case rebound
        /// 바꾸려는 대화를 다른 창이 이미 보인다: 그 창을 앞으로 가져오고 이 창은 그대로
        case showsElsewhere(UUID)
    }

    struct Entry: Equatable, Sendable {
        let id: UUID
        var conversationID: UUID
        /// 쓴 차례 (클수록 최근)
        var used: Int
        var hidden: Bool
    }

    private var entries: [Entry] = []
    private var tick = 0

    public init() {}

    public var windowIDs: [UUID] { entries.map(\.id) }

    public func conversationID(of windowID: UUID) -> UUID? {
        entries.first { $0.id == windowID }?.conversationID
    }

    public func window(showing conversationID: UUID) -> UUID? {
        entries.first { $0.conversationID == conversationID }?.id
    }

    public func isHidden(_ windowID: UUID) -> Bool {
        entries.first { $0.id == windowID }?.hidden ?? false
    }

    /// 가장 최근에 쓴 보이는 창
    public var frontmost: UUID? {
        entries.filter { !$0.hidden }.max { $0.used < $1.used }?.id
    }

    /// 숨은 창까지 포함해 가장 최근에 쓴 창
    public var mostRecentlyUsed: UUID? {
        entries.max { $0.used < $1.used }?.id
    }

    /// 가장 오래 쓰지 않은 창 (숨은 창 포함)
    public var leastRecentlyUsed: UUID? {
        entries.min { $0.used < $1.used }?.id
    }

    /// ⌘3 · 레일 Chats: 앞 창을 앞으로, 앞 창이 없으면 가장 최근에 쓴 창을 다시 보인다. 창이 없으면 nil (새로 연다)
    public var windowToBringForward: UUID? {
        frontmost ?? mostRecentlyUsed
    }

    /// 대화를 보이는 창을 연다. 같은 대화는 그 창을 앞으로, 상한이면 가장 오래 쓰지 않은 창을 앞으로, 아니면 새 창
    public mutating func open(conversation conversationID: UUID, windowID: UUID = UUID()) -> OpenOutcome {
        if let existing = window(showing: conversationID) {
            raise(existing)
            return .reused(existing)
        }
        if entries.count >= Self.maxWindows, let oldest = leastRecentlyUsed {
            raise(oldest)
            return .atCapacity(raise: oldest)
        }
        tick += 1
        entries.append(Entry(id: windowID, conversationID: conversationID, used: tick, hidden: false))
        return .opened(windowID)
    }

    /// 창을 썼다 (클릭 · 키 창이 됨): 가장 최근으로
    public mutating func touch(_ windowID: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == windowID }) else { return }
        tick += 1
        entries[index].used = tick
    }

    public mutating func setHidden(_ hidden: Bool, _ windowID: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == windowID }) else { return }
        entries[index].hidden = hidden
    }

    public mutating func close(_ windowID: UUID) {
        entries.removeAll { $0.id == windowID }
    }

    /// 같은 창 안에서 대화를 바꾼다 (History에서 열기 · New chat · 글이 있는 대화에서 다른 대상 고르기)
    public mutating func rebind(_ windowID: UUID, to conversationID: UUID) -> RebindOutcome {
        if let other = window(showing: conversationID), other != windowID {
            raise(other)
            return .showsElsewhere(other)
        }
        guard let index = entries.firstIndex(where: { $0.id == windowID }) else { return .rebound }
        entries[index].conversationID = conversationID
        touch(windowID)
        return .rebound
    }

    private mutating func raise(_ windowID: UUID) {
        touch(windowID)
        setHidden(false, windowID)
    }
}

/// 창 위치의 기억 (대화 id별 · 화면별). 점은 창의 **왼쪽 위**(화면 좌표, 아래가 0)다 — 높이가 변해도 위가 움직이지 않는다.
/// 오래된 대화부터 잊는다 (`capacity`개까지). 사용자가 정한 창 **크기**는 대화가 아니라 화면별로 하나 기억한다 (그 화면에서 새로 여는 창이 그 크기로 열린다)
public struct AssistantWindowPositions: Codable, Equatable, Sendable {
    public static let capacity = 100

    struct Entry: Codable, Equatable, Sendable {
        var conversation: String
        var displays: [String: [Double]]
    }

    private(set) var entries: [Entry] = []
    private(set) var sizes: [String: AssistantWindowSize] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case entries, sizes
    }

    /// 크기 기억이 생기기 전에 저장한 것도 읽는다 (`sizes`가 없으면 비어 있다): 업데이트로 창 위치를 잃지 않는다
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decode([Entry].self, forKey: .entries)
        sizes = try container.decodeIfPresent([String: AssistantWindowSize].self, forKey: .sizes) ?? [:]
    }

    public var conversationCount: Int { entries.count }

    public func position(conversation: UUID, display: String) -> CGPoint? {
        guard let point = entries.first(where: { $0.conversation == Self.key(conversation) })?.displays[display], point.count == 2 else { return nil }
        return CGPoint(x: point[0], y: point[1])
    }

    public mutating func remember(_ topLeft: CGPoint, conversation: UUID, display: String) {
        let key = Self.key(conversation)
        var entry = entries.first { $0.conversation == key } ?? Entry(conversation: key, displays: [:])
        entries.removeAll { $0.conversation == key }
        entry.displays[display] = [Double(topLeft.x), Double(topLeft.y)]
        entries.append(entry)
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }

    /// 그 화면에서 사용자가 정한 창 크기 (없으면 기본)
    public func size(display: String) -> AssistantWindowSize? {
        sizes[display]
    }

    /// 기본 크기로 되돌렸으면 기억을 지운다 (기본은 기억할 값이 아니다)
    public mutating func rememberSize(_ size: AssistantWindowSize, display: String) {
        if size == .standard { sizes[display] = nil } else { sizes[display] = size }
    }

    private static func key(_ id: UUID) -> String { id.uuidString.lowercased() }
}

/// 위치 저장소: 앱의 설정 도메인에 한 키로 둔다. 시험은 격리 suite를 넘긴다 (실사용 설정을 건드리지 않는다).
/// `defaults`가 nil이면 메모리뿐이다 (디자인 비교 견본은 설정 도메인을 만들지 않는다)
public struct AssistantWindowPositionStore: @unchecked Sendable {
    public static let key = "tf.assistant.windowPositions"

    /// 메모리 저장소의 본체 (값 타입 복사본이 같은 곳을 본다)
    private final class Memory {
        var data: Data?
    }

    private let defaults: UserDefaults?
    private let memory = Memory()

    public init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    private var stored: Data? {
        defaults.map { $0.data(forKey: Self.key) } ?? memory.data
    }

    public func load() -> AssistantWindowPositions {
        guard let data = stored, let positions = try? JSONDecoder().decode(AssistantWindowPositions.self, from: data) else {
            return AssistantWindowPositions()
        }
        return positions
    }

    public func save(_ positions: AssistantWindowPositions) {
        guard let data = try? JSONEncoder().encode(positions) else { return }
        if let defaults { defaults.set(data, forKey: Self.key) } else { memory.data = data }
    }

    public func clear() {
        if let defaults { defaults.removeObject(forKey: Self.key) } else { memory.data = nil }
    }
}
