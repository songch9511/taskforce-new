#if os(macOS)
import Darwin
import Foundation
import Security
import TaskforceAgentWire

/// 보내기 전 확인에 쓰는 사실 (PR-D3k, 계약 21.2 DR-S2c ①②): **보낼 때마다** 등록 파일 · 프로세스에서 다시 읽는다 (`ClaudeAppSendVerifier`). 이 Mac 안에서만 쓰고 서버 · 로그에 가지 않는다
public struct ClaudeAppSendFacts: Equatable, Sendable {
    /// ② 같은 id의 다른 writer를 찾았나
    public enum Writers: Equatable, Sendable {
        case none
        /// 다른 프로세스가 `--resume <id>`로 쥐었거나, 같은 폴더에 등록 없는 `claude`가 있다
        case found
        /// 프로세스 목록을 읽지 못했다: 모르면 막는다 (fail-closed)
        case unknown
    }

    /// ① 믿는 데스크톱 세션: 그 id의 살아 있는 등록이 **하나뿐**이고 `entrypoint claude-desktop`, pid · uid · procStart가 맞다. 없으면 nil
    public var session: ClaudeAppSession?
    /// 같은 id를 내세운 살아 있는 등록이 둘 이상이다 (DT1: 어느 쪽도 믿지 않는다)
    public var doubled: Bool
    /// ① 그 프로세스가 Anthropic이 서명한 실행 파일이고 조상에 Claude.app 본체가 있다 (`ClaudeAppProcessTrust`)
    public var processTrusted: Bool
    public var otherWriters: Writers
    /// 등록 폴더를 읽을 수 없었다: 있는지 없는지 모른다
    public var registryUnavailable: Bool

    public init(session: ClaudeAppSession?, doubled: Bool, processTrusted: Bool, otherWriters: Writers, registryUnavailable: Bool = false) {
        self.session = session
        self.doubled = doubled
        self.processTrusted = processTrusted
        self.otherWriters = otherWriters
        self.registryUnavailable = registryUnavailable
    }
}

/// 보내는 쪽의 사정 (패널 · 중계 · 확인 상태)
public struct ClaudeAppSendContext: Equatable, Sendable {
    /// C5 확인을 누른 그 프로세스 (pid + 시작 시각): 다른 프로세스면 다시 묻는다
    public struct Confirmation: Equatable, Sendable {
        public var pid: Int32
        public var procStart: Date?

        public init(pid: Int32, procStart: Date?) {
            self.pid = pid
            self.procStart = procStart
        }
    }

    /// ⑤ 중계: 살아 있고 띄운 pid · 시작 시각 그대로(`ready`) · 아직 안 떠 있다(보내기가 띄운다) · 띄운 뒤 정체가 바뀌었다 · 이 실행에서 꺼졌다
    public enum Relay: Equatable, Sendable {
        case ready, notRunning, mismatch, unavailable
    }

    /// ⑦ 보기의 상태: 열려 있다 · Claude에서 닫혔다 · 기록을 못 읽는다
    public enum View: Equatable, Sendable {
        case open, closed, unreadable
    }

    public var confirmed: Confirmation?
    /// ④ 이 세션에 확인 전 글이 있다
    public var hasPending: Bool
    public var relay: Relay
    public var view: View

    /// (옛 ⑥ "패널이 보던 세션 = 보낼 세션"은 없앴다: 입력창은 세션마다 하나라 글은 늘 그 입력창의 세션으로만 가고 두 값이 같은 값이었다 — OA PR-D3 검토 P3-14)
    public init(confirmed: Confirmation?, hasPending: Bool, relay: Relay, view: View) {
        self.confirmed = confirmed
        self.hasPending = hasPending
        self.relay = relay
        self.view = view
    }
}

/// 보내기를 막은 까닭
public enum ClaudeAppSendBlock: Equatable, Sendable {
    /// 이 실행에서 중계가 꺼졌다 (모델 턴 · mod 해시 · 게이트)
    case unavailable
    /// 닫힘: 등록이 없거나 보기가 Closed다
    case sessionClosed
    /// 기록을 못 읽는다 (입력창이 없다)
    case unreadable
    /// 서명이 다르거나 조상에 Claude.app이 없다
    case notTrusted
    /// 같은 id의 등록이 둘이거나 다른 writer가 있다
    case twoWriters
    /// writer가 있는지 확인할 수 없다
    case writersUnknown
    /// 확인 전 글이 있다 (한 번에 하나)
    case pending
    /// 중계의 정체가 띄운 뒤 바뀌었다
    case relayMismatch

    /// 화면에 보이는 "Not sent" 이유. 줄 없이 막는 경우(입력창이 없다 · 한 번에 하나 · 부르는 쪽 실수)는 nil
    public var notSentReason: ClaudeAppNotSentReason? {
        switch self {
        case .twoWriters: .twoWriters
        case .sessionClosed: .sessionClosed
        case .notTrusted, .writersUnknown: .notReceived
        case .unavailable, .relayMismatch: .relayFailed
        case .pending, .unreadable: nil
        }
    }
}

public enum ClaudeAppSendVerdict: Equatable, Sendable {
    case allowed
    /// C5: 첫 보내기(이 세션 · 이 프로세스) 확인이 먼저다
    case needsConfirmation
    case blocked(ClaudeAppSendBlock)
}

/// 보내기 전 확인 ①–⑧ (PR-D3k, 계약 21.2 DR-S2c · 25.4.3): 순수 판정이다. 순서가 고정이라 가장 구체적인 이유가 이긴다.
/// 보기 닫힘 · 기록 못 읽음 → 중계 꺼짐 → ① 세션(둘이면 두 곳 · 없으면 닫힘 · 서명) → ② 다른 writer → ④ 한 번에 하나 → ⑤ 중계 정체 → C5 확인.
/// ⑧ 저장이 켜졌는지는 보내기를 막지 않는다 (입력에 없다)
public enum ClaudeAppSendCheck {
    public static func evaluate(facts: ClaudeAppSendFacts, context: ClaudeAppSendContext) -> ClaudeAppSendVerdict {
        switch context.view {
        case .closed: return .blocked(.sessionClosed)
        case .unreadable: return .blocked(.unreadable)
        case .open: break
        }
        if context.relay == .unavailable { return .blocked(.unavailable) }
        if facts.registryUnavailable { return .blocked(.writersUnknown) }
        if facts.doubled { return .blocked(.twoWriters) }
        guard let session = facts.session else { return .blocked(.sessionClosed) }
        guard facts.processTrusted else { return .blocked(.notTrusted) }
        switch facts.otherWriters {
        case .found: return .blocked(.twoWriters)
        case .unknown: return .blocked(.writersUnknown)
        case .none: break
        }
        if context.hasPending { return .blocked(.pending) }
        if context.relay == .mismatch { return .blocked(.relayMismatch) }
        guard let confirmed = context.confirmed, confirmed.pid == session.pid, confirmed.procStart == session.procStart else { return .needsConfirmation }
        return .allowed
    }
}

/// 그 프로세스가 진짜 Claude 데스크톱 앱이 띄운 `claude`인가 (계약 21.2 DR-S2c ①, DT1): 실행 파일이 Anthropic 팀(`Q6L2SF6YDW`)이 서명했고 조상(세 단계 안)에 서명이 맞는 `Claude.app` 본체가 있다.
/// 등록 파일의 `entrypoint`는 같은 사용자의 아무 프로세스나 쓸 수 있는 값이라 이것만으로 믿지 않는다. 시험은 가짜로 바꾼다
public struct ClaudeAppProcessTrust: Sendable {
    public var isTrusted: @Sendable (Int32) -> Bool

    public init(isTrusted: @escaping @Sendable (Int32) -> Bool) {
        self.isTrusted = isTrusted
    }

    /// Anthropic PBC의 Developer ID 팀 (공개 값: `codesign -dv /Applications/Claude.app`)
    static let teamIdentifier = "Q6L2SF6YDW"
    static let appExecutableSuffix = "/Claude.app/Contents/MacOS/Claude"
    static let maxAncestors = 3

    public static let live = ClaudeAppProcessTrust(isTrusted: { Live.isTrusted($0) })

    enum Live {
        static func isTrusted(_ pid: Int32) -> Bool {
            guard pid > 1, signedByAnthropic(pid) else { return false }
            var current = pid
            for _ in 0..<maxAncestors {
                guard case .present(let generation) = ClaudeProcessInspector.generation(pid: current), generation.parentPID > 1 else { return false }
                current = generation.parentPID
                if executablePath(current)?.hasSuffix(appExecutableSuffix) == true, signedByAnthropic(current) { return true }
            }
            return false
        }

        static func executablePath(_ pid: Int32) -> String? {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
            return ExternalSessionFileSystem.Live.string(fromCString: buffer)
        }

        /// 실행 중인 그 프로세스의 서명이 유효하고 팀이 Anthropic이다 (`SecCodeCheckValidity`, 실행 중 코드의 확인이라 디스크를 깊게 읽지 않는다)
        static func signedByAnthropic(_ pid: Int32) -> Bool {
            var code: SecCode?
            let attributes = [kSecGuestAttributePid: pid] as CFDictionary
            guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code) == errSecSuccess, let code else { return false }
            var requirement: SecRequirement?
            let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
            guard SecRequirementCreateWithString(text as CFString, SecCSFlags(), &requirement) == errSecSuccess, let requirement else { return false }
            return SecCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess
        }
    }
}

/// 사실 모으기 (계약 DR-S2c ① ②): 등록 파일을 **다시 읽고**(캐시 없음) 프로세스 사실 · 서명을 본다. 실제 `claude`는 부르지 않는다
public struct ClaudeAppSendVerifier: Sendable {
    private let fileSystem: ExternalSessionFileSystem
    private let sessionsDirectory: String
    private let processFacts: ExternalSessionProcessFacts
    private let trust: ClaudeAppProcessTrust
    private let ownPIDs: @Sendable () -> Set<Int32>
    private let clock: @Sendable () -> Date

    /// - ownPIDs: Taskforce가 띄운 프로세스(중계 포함): 다른 writer로 세지 않는다
    public init(
        fileSystem: ExternalSessionFileSystem = .live, sessionsDirectory: String, processFacts: ExternalSessionProcessFacts = .live, trust: ClaudeAppProcessTrust = .live,
        ownPIDs: @escaping @Sendable () -> Set<Int32> = { [] }, clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileSystem = fileSystem
        self.sessionsDirectory = sessionsDirectory
        self.processFacts = processFacts
        self.trust = trust
        self.ownPIDs = ownPIDs
        self.clock = clock
    }

    /// 막히는 호출이다 (파일 · 프로세스 읽기): 메인 밖에서 부른다
    public func facts(for sessionID: String) -> ClaudeAppSendFacts {
        let own = ownPIDs()
        let now = clock()
        var reuse = ExternalSessionRegistry.Reuse()
        let live = ClaudeAppLiveSessions.read(
            fileSystem: fileSystem, sessionsDirectory: sessionsDirectory, facts: processFacts, ownPIDs: own, now: now, reuse: &reuse, alwaysRead: []
        )
        if live.registryUnavailable {
            return ClaudeAppSendFacts(session: nil, doubled: false, processTrusted: false, otherWriters: .none, registryUnavailable: true)
        }
        let doubled = live.doubled.contains(sessionID)
        guard !doubled, let session = live.sessions.first(where: { $0.id == sessionID }) else {
            return ClaudeAppSendFacts(session: nil, doubled: doubled, processTrusted: false, otherWriters: .none)
        }
        return ClaudeAppSendFacts(
            session: session, doubled: false, processTrusted: trust.isTrusted(session.pid), otherWriters: otherWriters(of: session, own: own, now: now)
        )
    }

    /// 계약 5.4의 ② ③: 다른 프로세스가 같은 세션 id를 `--resume`했거나, 같은 폴더에 등록 파일 없는 `claude`가 있다 (④ "기록이 방금 쓰였다"는 대상이 지금 쓰는 중이라 해당 없다)
    private func otherWriters(of session: ClaudeAppSession, own: Set<Int32>, now: Date) -> ClaudeAppSendFacts.Writers {
        guard case .entries(let registered) = ExternalSessionRegistry.read(fileSystem: fileSystem, sessionsDirectory: sessionsDirectory, now: now) else { return .unknown }
        let registeredPIDs = Set(registered.map(\.pid))
        guard let named = processFacts.argumentSessionIDs(own.union([session.pid])), let folders = processFacts.unregisteredClaudeFolders(registeredPIDs, own) else { return .unknown }
        if named.contains(session.id) { return .found }
        if let cwd = session.cwd, folders.contains(cwd) { return .found }
        return .none
    }
}
#endif
