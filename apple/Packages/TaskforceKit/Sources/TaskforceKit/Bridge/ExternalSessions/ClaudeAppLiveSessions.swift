#if os(macOS)
import Foundation

/// Claude 데스크톱 앱에 열려 있고 믿을 수 있는 세션 하나 (PR-D1 Kit). **이 Mac 안에서만** 쓰고 서버 · 로그에 가지 않는다:
/// `description`은 글 · 경로 · id 없이 상태만 말한다
public struct ClaudeAppSession: Identifiable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// 소문자 정규 UUID (Claude 세션 id)
    public let id: String
    public var pid: Int32
    /// 등록 파일의 작업 폴더 (이 Mac 안에서만)
    public var cwd: String?
    public var procStart: Date?
    public var state: ClaudeAppSessionState
    public var statusUpdatedAt: Date?

    public init(id: String, pid: Int32, cwd: String?, procStart: Date?, state: ClaudeAppSessionState, statusUpdatedAt: Date?) {
        self.id = id
        self.pid = pid
        self.cwd = cwd
        self.procStart = procStart
        self.state = state
        self.statusUpdatedAt = statusUpdatedAt
    }

    public var description: String { "ClaudeAppSession(state: \(state))" }
    public var debugDescription: String { description }
}

/// 등록 파일에서 읽은, 지금 레일에 오를 수 있는 데스크톱 세션들 (5.4 · 21.5 DT1 · DT3의 Kit 몫)
public struct ClaudeAppLiveSessions: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// 믿는 세션: `entrypoint claude-desktop`(background 종류 아님), 우리 혈통 아님, 살아 있음(pid · uid · procStart), 그 id의 살아 있는 등록이 **하나뿐**. id 순
    public var sessions: [ClaudeAppSession]
    /// 살아 있는 등록이 둘 이상인 id: 어느 쪽도 믿지 않는다 ("Running in two places").
    /// **비어 있다고 다른 writer가 없다는 뜻은 아니다**: 등록 파일을 만들지 않는 writer(옛 버전 · 등록이 없는 프로세스)는 여기에 안 나온다. 보내기 전 확인(PR-D3)은 따로 한다
    public var doubled: Set<String>
    /// 등록 폴더를 읽을 수 없거나 형식이 바뀌어 하나도 해석하지 못했다
    public var registryUnavailable: Bool

    public init(sessions: [ClaudeAppSession], doubled: Set<String>, registryUnavailable: Bool) {
        self.sessions = sessions
        self.doubled = doubled
        self.registryUnavailable = registryUnavailable
    }

    /// 개수만 말한다: 세션 id · pid를 찍지 않는다
    public var description: String { "ClaudeAppLiveSessions(sessions: \(sessions.count), doubled: \(doubled.count), registryUnavailable: \(registryUnavailable))" }
    public var debugDescription: String { description }

    public static func read(
        fileSystem: ExternalSessionFileSystem = .live, sessionsDirectory: String, facts: ExternalSessionProcessFacts = .live, ownPIDs: Set<Int32> = [], now: Date = Date(),
        localZone: TimeZone = .current
    ) -> ClaudeAppLiveSessions {
        var reuse = ExternalSessionRegistry.Reuse()
        return read(fileSystem: fileSystem, sessionsDirectory: sessionsDirectory, facts: facts, ownPIDs: ownPIDs, now: now, localZone: localZone, reuse: &reuse, alwaysRead: [])
    }

    /// 폴러가 이어 쓰는 읽기: 지난번과 같은 파일은 다시 열지 않는다 (`alwaysRead` = 지금 레일에 있는 데스크톱 세션의 pid는 늘 다시 읽는다)
    static func read(
        fileSystem: ExternalSessionFileSystem, sessionsDirectory: String, facts: ExternalSessionProcessFacts, ownPIDs: Set<Int32>, now: Date, localZone: TimeZone = .current,
        reuse: inout ExternalSessionRegistry.Reuse, alwaysRead: Set<Int32>
    ) -> ClaudeAppLiveSessions {
        let entries: [ExternalSessionRegistry.Entry]
        switch ExternalSessionRegistry.read(fileSystem: fileSystem, sessionsDirectory: sessionsDirectory, now: now, localZone: localZone, reuse: &reuse, alwaysRead: alwaysRead) {
        case .unavailable: return ClaudeAppLiveSessions(sessions: [], doubled: [], registryUnavailable: true)
        case .entries(let found): entries = found
        }
        // 살아 있음은 쥠 판정과 같은 검사다 (pid · 같은 사용자 · 시작 시각 1초 안). 끝난 프로세스의 남은 파일은 어디에도 세지 않는다
        let live = entries.filter { !ownPIDs.contains($0.pid) && ExternalSessionHold.isAlive($0, facts: facts) }
        var counts: [String: Int] = [:]
        for entry in live { counts[entry.sessionID, default: 0] += 1 }
        let desktop = live.filter { ExternalSessionHold.holder($0) == .claudeApp }
        // 같은 id를 내세운 살아 있는 등록이 둘 이상이면(다른 출처 포함) 어느 쪽도 믿지 않는다 (DT1)
        let doubled = Set(desktop.map(\.sessionID).filter { counts[$0, default: 0] > 1 })
        let sessions = desktop.filter { !doubled.contains($0.sessionID) }.map {
            ClaudeAppSession(id: $0.sessionID, pid: $0.pid, cwd: $0.cwd, procStart: $0.procStart, state: $0.state, statusUpdatedAt: $0.statusUpdatedAt)
        }
        return ClaudeAppLiveSessions(sessions: sessions.sorted { $0.id < $1.id }, doubled: doubled, registryUnavailable: false)
    }
}
#endif
