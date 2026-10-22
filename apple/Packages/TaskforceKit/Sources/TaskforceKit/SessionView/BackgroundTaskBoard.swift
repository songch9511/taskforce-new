#if os(macOS)
import Foundation

/// 어댑터가 읽은 `task_*` 줄로 만든 백그라운드 일 목록을 **이 Mac 안에서** Taskforce 세션 패널에 건네는 판 (세션 보기 V1, DZ v2: Taskforce 패널은 어댑터의 스트림에서).
/// 세션(Taskforce agent 세션 id)마다 목록 하나, 메모리뿐이다: 서버 · 디스크 · 로그 0. 이름은 모델이 쓴 description뿐이고 명령 글은 들어오지 않는다 (`ClaudeEventMapper`가 거른다).
/// 쓰는 쪽(어댑터 actor)과 읽는 쪽(화면)이 다른 스레드라 잠금으로 지킨다. 화면은 `version`이 바뀐 때만 다시 읽는다
public final class BackgroundTaskBoard: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// 이보다 많은 세션이 쌓이면 가장 오래 안 쓴 세션부터 버린다
    public static let maxSessions = 32
    static let maxKeyLength = 200
    /// 실제 앱의 어댑터와 세션 패널이 함께 쓰는 판 (시험은 자기 판을 만든다)
    public static let shared = BackgroundTaskBoard()

    private let lock = NSLock()
    private var lists: [String: BackgroundTaskList] = [:]
    /// 오래 안 쓴 순서 (맨 앞이 가장 오래)
    private var recency: [String] = []
    private var _version = 0

    public init() {}

    /// 목록이 바뀔 때마다 오른다
    public var version: Int { lock.withLock { _version } }
    public var sessionCount: Int { lock.withLock { lists.count } }

    /// 세션 id는 대소문자를 가리지 않는다. 너무 길거나 빈 키는 받지 않는다
    private static func key(_ session: String) -> String? {
        let key = session.lowercased()
        return (1...maxKeyLength).contains(key.utf8.count) ? key : nil
    }

    /// - now: 끝 시각을 모르는 끝의 끝 시각 (시험은 값을 준다)
    public func apply(_ event: BackgroundTaskEvent, session: String, now: Date = Date()) {
        guard let key = Self.key(session) else { return }
        lock.withLock {
            let existing = lists[key]
            var list = existing ?? BackgroundTaskList()
            list.apply(event, now: now)
            guard list != (existing ?? BackgroundTaskList()) else { return }
            lists[key] = list
            recency.removeAll { $0 == key }
            recency.append(key)
            while lists.count > Self.maxSessions, let oldest = recency.first {
                lists[oldest] = nil
                recency.removeFirst()
            }
            _version += 1
        }
    }

    public func tasks(session: String) -> BackgroundTaskList {
        guard let key = Self.key(session) else { return BackgroundTaskList() }
        return lock.withLock { lists[key] ?? BackgroundTaskList() }
    }

    /// 모든 세션의 목록을 비운다 (계정이 떠날 때: 로그아웃 · 다른 계정)
    public func clearAll() {
        lock.withLock {
            guard !lists.isEmpty else { return }
            lists = [:]
            recency = []
            _version += 1
        }
    }

    /// 그 세션의 목록을 비운다 (세션을 잊을 때)
    public func clear(session: String) {
        guard let key = Self.key(session) else { return }
        lock.withLock {
            guard lists.removeValue(forKey: key) != nil else { return }
            recency.removeAll { $0 == key }
            _version += 1
        }
    }

    /// 아이디 · 이름 · 세션 id를 찍지 않는다
    public var description: String { "BackgroundTaskBoard()" }
    public var debugDescription: String { description }
}
#endif
