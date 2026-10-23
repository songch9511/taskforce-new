#if os(macOS)
import Foundation

// 세션이 돌리는 백그라운드 일 (DZ oa-session-view-dz v2 E7–E10, 탐침 BG-1~BG-7): Bash의 `run_in_background` · 백그라운드 에이전트.
// 이 Mac 안에서만 만들어지고 메모리에만 둔다. **이름은 모델이 쓴 description뿐이다** (명령 글 · 경로 · 출력은 값에 없다). 서버로 가는 것은 이 PR 밖이다.

public enum BackgroundTaskKind: String, Equatable, Sendable {
    case command
    case agent
    case other

    /// 줄의 둘째 줄에 쓰는 말 (승인된 문구)
    public var word: String {
        switch self {
        case .command: SessionViewCopy.command
        case .agent: SessionViewCopy.agent
        case .other: SessionViewCopy.task
        }
    }

    /// 이름이 없을 때 쓰는 도구 이름 (명령 글은 비밀값이 섞일 수 있어 보이지 않는다)
    var toolName: String {
        switch self {
        case .command: "Bash"
        case .agent: "Agent"
        case .other: SessionViewCopy.task
        }
    }
}

public enum BackgroundTaskStatus: Equatable, Sendable {
    case running
    case done
    case failed
    /// 알림 없이 끝났거나 세션이 닫혔다 (끝내지 못한 일)
    case stopped

    public var word: String {
        switch self {
        case .running: SessionViewCopy.running
        case .done: SessionViewCopy.done
        case .failed: SessionViewCopy.failed
        case .stopped: SessionViewCopy.stopped
        }
    }
}

/// 일의 사건. 기록(시작 · 끝 줄)과 스트림(`task_*` 줄)이 같은 값으로 목록을 채운다. 같은 사건이 되풀이돼도 결과는 같다
public enum BackgroundTaskEvent: Equatable, Sendable {
    /// 시작. `name`은 모델이 쓴 description만 (모르면 nil: 기록은 도구 줄의 description을 `toolUseID`로 나중에 찾는다)
    case started(taskID: String, toolUseID: String?, kind: BackgroundTaskKind, name: String?, at: Date?)
    /// 끝 (`done` · `failed` · `stopped`). 종류를 모르면 nil
    case finished(taskID: String, kind: BackgroundTaskKind?, status: BackgroundTaskStatus, exitCode: Int?, at: Date?)
    /// 지금 도는 일의 목록 (`background_tasks_changed`): 도는 줄 알았는데 없으면 끝내지 못한 일이다
    case snapshot(runningTaskIDs: [String])
}

public struct BackgroundTask: Identifiable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: String
    public var kind: BackgroundTaskKind
    public var name: String?
    public var status: BackgroundTaskStatus
    public var exitCode: Int?
    public var startedAt: Date?
    public var endedAt: Date?
    public var toolUseID: String?

    public init(
        id: String, kind: BackgroundTaskKind, name: String?, status: BackgroundTaskStatus = .running, exitCode: Int? = nil, startedAt: Date? = nil, endedAt: Date? = nil, toolUseID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.status = status
        self.exitCode = exitCode
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.toolUseID = toolUseID
    }

    /// 줄의 제목: 모델이 쓴 이름, 없으면 도구 이름
    public var title: String {
        if let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty { return trimmed }
        return kind.toolName
    }

    /// 걸린 시간 (시작 · 끝을 둘 다 알 때만)
    public var duration: TimeInterval? { SessionTime.elapsed(from: startedAt, to: endedAt) }

    /// 줄의 둘째 줄: "종류 · 상태 · 시간" ("Command · Failed · Exit code 3 · 12s"). 시작을 모르면 시간은 없다
    public func meta(now: Date) -> String {
        var parts = [kind.word, status.word]
        if status == .failed, let exitCode { parts.append(SessionViewCopy.exitCode(exitCode)) }
        switch status {
        case .running:
            if let startedAt { parts.append(SessionTime.clock(now.timeIntervalSince(startedAt))) }
        case .done, .failed, .stopped:
            if let duration { parts.append(SessionTime.worked(duration)) }
        }
        return parts.joined(separator: " · ")
    }

    /// 접근성 이름: "{종류}, {이름}, {상태}" (시계는 초마다 읽히지 않는다)
    public func accessibleName(now: Date) -> String { "\(kind.word), \(title), \(status.word)" }

    /// 이름 · 아이디 · 명령을 찍지 않는다
    public var description: String { "BackgroundTask()" }
    public var debugDescription: String { description }
}

/// 한 세션의 백그라운드 일 목록 (값). 사건을 먹이면 상태가 정해진다
public struct BackgroundTaskList: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// 이보다 많으면 가장 오래된 끝난 일부터 버린다
    public static let maxTasks = 256

    /// 시작한 차례
    public private(set) var tasks: [BackgroundTask] = []

    public init() {}

    private func index(of id: String) -> Int? { tasks.firstIndex { $0.id == id } }

    private static func cleaned(_ name: String?) -> String? { name.flatMap(ExternalSessionRules.sanitizedTitle) }

    /// - now: 끝 시각을 모르는 끝(시각 없는 끝 · 스냅샷에서 사라짐)의 끝 시각: 그 사건을 받은 때 끝난 것이다 (끝 시각이 없으면 "막 끝난 일은 열어 보기 전까지 남는다" 규칙이 거짓이 된다). 시험은 값을 준다
    public mutating func apply(_ event: BackgroundTaskEvent, now: Date = Date()) {
        switch event {
        case .started(let id, let toolUseID, let kind, let name, let at):
            if let index = index(of: id) {
                // 끝 줄을 먼저 읽고 시작 줄을 나중에 읽었다 (앞 쪽 읽기): 상태는 그대로, 아는 것만 채운다
                if kind != .other || tasks[index].kind == .other { tasks[index].kind = kind }
                if tasks[index].startedAt == nil { tasks[index].startedAt = at }
                if tasks[index].name == nil { tasks[index].name = Self.cleaned(name) }
                if tasks[index].toolUseID == nil { tasks[index].toolUseID = toolUseID }
            } else {
                tasks.append(BackgroundTask(id: id, kind: kind, name: Self.cleaned(name), startedAt: at, toolUseID: toolUseID))
                bound()
            }
        case .finished(let id, let kind, let status, let exitCode, let at):
            guard status != .running else { return }
            if let index = index(of: id) {
                if tasks[index].kind == .other, let kind { tasks[index].kind = kind }
                switch tasks[index].status {
                case .running:
                    tasks[index].status = status
                    tasks[index].exitCode = exitCode
                    tasks[index].endedAt = at ?? now
                case .stopped where status == .done || status == .failed:
                    // 알림이 늦게 왔다: 멈춤을 알림의 끝으로 고친다
                    tasks[index].status = status
                    tasks[index].exitCode = exitCode
                    tasks[index].endedAt = at ?? tasks[index].endedAt
                case let current where current == status && status != .stopped:
                    // `task_updated`(상태만)가 `task_notification`(끝낸 코드)보다 먼저 온다: 같은 끝의 늦은 줄은 비어 있던 끝낸 코드를 채운다 (다른 끝의 코드는 가져오지 않는다)
                    if tasks[index].exitCode == nil, let exitCode { tasks[index].exitCode = exitCode }
                default:
                    break
                }
            } else {
                tasks.append(BackgroundTask(id: id, kind: kind ?? .other, name: nil, status: status, exitCode: exitCode, endedAt: at ?? now))
                bound()
            }
        case .snapshot(let running):
            let alive = Set(running)
            for index in tasks.indices where tasks[index].status == .running && !alive.contains(tasks[index].id) {
                tasks[index].status = .stopped
                tasks[index].endedAt = now
            }
        }
    }

    /// 이름을 부른 일 가운데 아직 도는 일만 `now`에 멈춘 것으로 한다 (스냅샷과 달리 부르지 않은 일은 그대로)
    public mutating func stopRunning(_ ids: Set<String>, now: Date) {
        for index in tasks.indices where tasks[index].status == .running && ids.contains(tasks[index].id) {
            tasks[index].status = .stopped
            tasks[index].endedAt = now
        }
    }

    private mutating func bound() {
        while tasks.count > Self.maxTasks {
            if let finished = tasks.firstIndex(where: { $0.status != .running }) { tasks.remove(at: finished) } else { tasks.removeFirst() }
        }
    }

    /// 이름을 모르는 일에 도구 줄의 description을 `toolUseID`로 찾아 붙인다 (이미 있는 이름은 그대로)
    public mutating func resolveNames(_ lookup: (String) -> String?) {
        for index in tasks.indices where tasks[index].name == nil {
            guard let toolUseID = tasks[index].toolUseID, let name = Self.cleaned(lookup(toolUseID)) else { continue }
            tasks[index].name = name
        }
    }

    /// 다른 출처(기록 · 스트림)의 목록을 합친다: 그쪽의 일마다 시작 · 끝 사건을 먹인다. 아는 이름 · 종류는 지키고 끝난 상태가 이긴다. 두 번 합쳐도 같다. 원본은 그대로
    public func merged(with other: BackgroundTaskList) -> BackgroundTaskList {
        var copy = self
        for task in other.tasks {
            copy.apply(.started(taskID: task.id, toolUseID: task.toolUseID, kind: task.kind, name: task.name, at: task.startedAt))
            if task.status != .running { copy.apply(.finished(taskID: task.id, kind: task.kind, status: task.status, exitCode: task.exitCode, at: task.endedAt)) }
        }
        return copy
    }

    /// 세션이 닫혔다: 아직 도는 일은 끝내지 못한 일이다 (Stopped). 원본은 그대로
    public func closed(at date: Date) -> BackgroundTaskList {
        var copy = self
        for index in copy.tasks.indices where copy.tasks[index].status == .running {
            copy.tasks[index].status = .stopped
            copy.tasks[index].endedAt = date
        }
        return copy
    }

    /// 도는 중 → 실패 → 그 밖(끝남 · 멈춤). 도는 일은 시작이 가까운 것 먼저, 끝난 일은 끝이 가까운 것 먼저 (같으면 나중에 시작한 것 먼저)
    public var ordered: [BackgroundTask] {
        func rank(_ task: BackgroundTask) -> Int {
            switch task.status {
            case .running: 0
            case .failed: 1
            case .done, .stopped: 2
            }
        }
        func stamp(_ task: BackgroundTask) -> Date { (task.status == .running ? task.startedAt : task.endedAt) ?? .distantPast }
        return tasks.enumerated().sorted { a, b in
            if rank(a.element) != rank(b.element) { return rank(a.element) < rank(b.element) }
            if stamp(a.element) != stamp(b.element) { return stamp(a.element) > stamp(b.element) }
            return a.offset > b.offset
        }.map(\.element)
    }

    public var runningCount: Int { tasks.filter { $0.status == .running }.count }

    /// 띠 · 옆줄 머리의 상태 한 단어: 도는 일이 있으면 Running, 아니면 Failed → Stopped → Done. 일이 없으면 nil
    public var stripStatus: BackgroundTaskStatus? {
        guard !tasks.isEmpty else { return nil }
        if tasks.contains(where: { $0.status == .running }) { return .running }
        if tasks.contains(where: { $0.status == .failed }) { return .failed }
        if tasks.contains(where: { $0.status == .stopped }) { return .stopped }
        return .done
    }

    /// 띠의 접근성 이름. 개수는 화면에 없고 여기에만 있다
    public var accessibleName: String {
        guard let status = stripStatus else { return SessionViewCopy.backgroundTasks }
        let running = runningCount
        return running > 0 ? "\(SessionViewCopy.backgroundTasks), \(running) running" : "\(SessionViewCopy.backgroundTasks), \(status.word)"
    }

    public var description: String { "BackgroundTaskList()" }
    public var debugDescription: String { description }
}

/// 띠가 있나 (DZ v2 E7 · 열린 질문 7): 도는 일이 있거나, 막 끝난 일을 사용자가 아직 열어 보지 않았다. 열어 본 시각은 세션마다 이 Mac에 둔다
public enum BackgroundTaskVisibility {
    public static func isVisible(tasks: [BackgroundTask], openedAt: Date?) -> Bool {
        guard !tasks.isEmpty else { return false }
        if tasks.contains(where: { $0.status == .running }) { return true }
        guard let openedAt else { return true }
        return tasks.contains { task in task.endedAt.map { $0 > openedAt } ?? false }
    }
}

/// 열어 본 시각을 두는 곳 (세션 id → 시각). 이 Mac에만 있다: 제목 · 폴더 · 글 0, 서버 · 로그 0. **메인 액터에서만 쓴다**
public protocol BackgroundTaskOpenStore: AnyObject, Sendable {
    func openedAt(session: String) -> Date?
    func markOpened(session: String, at: Date)
    /// 열어 본 시각을 모두 지운다 (주인은 그대로: 주인은 부르는 쪽이 정한다)
    func clear()
    /// 이 저장본의 주인 계정 (끝남 표시의 `RailDoneStore`와 같다). 모르면 nil
    var owner: UUID? { get }
    func setOwner(_ owner: UUID?)
}

public final class InMemoryBackgroundTaskOpenStore: BackgroundTaskOpenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var opened: [String: Date] = [:]
    private var _owner: UUID?

    public init() {}

    public func openedAt(session: String) -> Date? { lock.withLock { opened[session] } }
    public func markOpened(session: String, at date: Date) { lock.withLock { opened[session] = date } }
    public func clear() { lock.withLock { opened = [:] } }
    public var owner: UUID? { lock.withLock { _owner } }
    public func setOwner(_ owner: UUID?) { lock.withLock { _owner = owner } }
}

/// 이 Mac의 설정(앱 도메인)에 JSON 하나로 둔다. 읽을 수 없으면 비어 있는 것으로 시작한다. 가장 새 `maxSessions`개만 남긴다
public final class UserDefaultsBackgroundTaskOpenStore: BackgroundTaskOpenStore, @unchecked Sendable {
    public static let key = "taskforce.sessionView.backgroundOpened"
    public static let ownerKey = "taskforce.sessionView.backgroundOpenedOwner"
    public static let maxSessions = 64
    private let defaults: any RailDoneDefaults
    private let lock = NSLock()

    public init(defaults: any RailDoneDefaults = UserDefaults.standard) { self.defaults = defaults }

    private func load() -> [String: Double] {
        guard let data = defaults.object(forKey: Self.key) as? Data, let values = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        return values
    }

    public func openedAt(session: String) -> Date? {
        lock.withLock { load()[session].map { Date(timeIntervalSince1970: $0) } }
    }

    public func markOpened(session: String, at date: Date) {
        lock.withLock {
            var values = load()
            values[session] = date.timeIntervalSince1970
            if values.count > Self.maxSessions {
                for key in values.sorted(by: { $0.value < $1.value }).prefix(values.count - Self.maxSessions).map(\.key) { values[key] = nil }
            }
            guard let data = try? JSONEncoder().encode(values) else { return }
            defaults.set(data, forKey: Self.key)
        }
    }

    public func clear() {
        lock.withLock { defaults.set(nil, forKey: Self.key) }
    }

    public var owner: UUID? {
        lock.withLock { (defaults.object(forKey: Self.ownerKey) as? String).flatMap(UUID.init(uuidString:)) }
    }

    public func setOwner(_ owner: UUID?) {
        lock.withLock { defaults.set(owner?.uuidString, forKey: Self.ownerKey) }
    }
}

/// 보안 P3-1: 열어 본 시각(이 Mac의 저장본)과 이 Mac의 일 목록 판은 계정과 함께 간다 (끝남 표시의 `RailDoneStore` · `ClaudeAppSessionsModel.adopt`와 같은 규칙).
/// 로그인한 계정이 주인이 아니면(다른 계정이거나 모르면) 저장본을 비우고, 알던 계정이 떠나면 판을 비운다
public struct BackgroundTaskAccount: Sendable {
    public let openStore: any BackgroundTaskOpenStore
    public let board: BackgroundTaskBoard

    public init(openStore: any BackgroundTaskOpenStore, board: BackgroundTaskBoard) {
        self.openStore = openStore
        self.board = board
    }

    /// 이 계정을 저장본의 주인으로 확정한다: 주인이 이 계정이 아니면(다른 계정이거나 모르면) 이 계정의 것이 아니라서 비운다. 같은 계정을 다시 알려도 아무 일도 없다
    public func adopt(account: UUID) {
        if openStore.owner != account { openStore.clear() }
        openStore.setOwner(account)
    }

    /// 알던 계정이 떠났다 (로그아웃 · 다른 계정): 이 Mac의 일 목록 판을 비운다
    public func leave() {
        board.clearAll()
    }
}
#endif
