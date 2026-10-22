#if os(macOS)
import Foundation

// Claude 데스크톱 세션의 안 연 끝남 표시를 두는 곳 (OA PR-D2, 계약 23장): 끝난 링은 사용자가 열어 볼 때까지 레일에 남고, 표시는 이 Mac에 저장해 앱을 다시 켠 뒤에도 남는다.
// 값은 세션 id · pid · 본 시각뿐이다 (제목 · 폴더 · 글 0, 서버 · 로그 0). Taskforce 세션 · 이슈의 표시는 `RailDoneStore`가 따로 둔다.

/// 끝남 표시를 두는 곳. **메인 액터에서만 쓴다**
public protocol ClaudeAppDoneStore: AnyObject, Sendable {
    func load() -> [String: ClaudeAppDoneMark]
    func save(_ marks: [String: ClaudeAppDoneMark])
    /// 계정이 떠났다: 남기지 않는다
    func clear()
}

public final class InMemoryClaudeAppDoneStore: ClaudeAppDoneStore, @unchecked Sendable {
    private let lock = NSLock()
    private var marks: [String: ClaudeAppDoneMark] = [:]
    private var _saves = 0

    public init() {}

    /// 쓴 횟수 (시험이 "바뀔 때만 쓴다"를 본다)
    public var saves: Int { lock.withLock { _saves } }
    public func load() -> [String: ClaudeAppDoneMark] { lock.withLock { marks } }

    public func save(_ marks: [String: ClaudeAppDoneMark]) {
        lock.withLock {
            self.marks = marks
            _saves += 1
        }
    }

    public func clear() { lock.withLock { marks = [:] } }
}

/// 이 Mac의 설정(앱 도메인)에 JSON 하나로 둔다. 읽을 수 없으면 비어 있는 것으로 시작한다. id는 소문자 정규 UUID만 되살린다 (`ClaudeAppRailMemory(restoring:)`)
public final class UserDefaultsClaudeAppDoneStore: ClaudeAppDoneStore, @unchecked Sendable {
    public static let key = "taskforce.rail.claudeAppDoneMarks"
    private let defaults: any RailDoneDefaults

    public init(defaults: any RailDoneDefaults = UserDefaults.standard) { self.defaults = defaults }

    public func load() -> [String: ClaudeAppDoneMark] {
        guard let data = defaults.object(forKey: Self.key) as? Data, let marks = try? JSONDecoder().decode([String: ClaudeAppDoneMark].self, from: data) else { return [:] }
        return marks
    }

    public func save(_ marks: [String: ClaudeAppDoneMark]) {
        guard let data = try? JSONEncoder().encode(marks) else { return }
        defaults.set(data, forKey: Self.key)
    }

    public func clear() { defaults.set(nil, forKey: Self.key) }
}
#endif
