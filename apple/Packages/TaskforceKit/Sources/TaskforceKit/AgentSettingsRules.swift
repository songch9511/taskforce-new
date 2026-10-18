#if os(macOS)
import Foundation

// Settings › Your agents의 줄 · 상세 규칙 (OA Settings › Your agents 5장, 순수 함수).
// **서버가 판정하는 말은 대상 목록(T)에서만 온다** (CLAUDE.md "Swift는 서버 판정을 다시 구현하지 않는다", `AssistantTargets.swift`): Not connected(연결 없음) · Not signed in · Offline(unreachable) · Unsupported · Read only.
// 앱이 다시 계산하지 않는다. P(이 Mac의 probe)와 R(이 Mac 런타임 상태)은 이 Mac의 사실이라 그대로 보인다. 둘이 다르면(막 Terminal에서 로그인함) 줄은 T를 따르고 Status › Sign-in은 P를 보인다.
// 모르는 서버 상태는 아무것도 주장하지 않는다 ("Checking…").

/// 줄 · 상세를 정하는 사실
public struct AgentSettingsFacts: Equatable, Sendable {
    /// 이 Mac의 연결 행 (T)
    public enum Target: Equatable, Sendable {
        /// 아직 못 받았다 (읽는 중 · 읽기 실패): 서버 상태를 주장하지 않는다
        case notLoaded
        /// 읽었고 이 Mac의 연결 행이 없다 (서버의 `not_connected` 행과 같은 말)
        case none
        case row(state: AgentTargetState, access: AgentAccessLevel?)
    }

    /// B: 이 빌드가 에이전트를 띄울 수 있다 (bridge가 켜졌고 활성 런타임에 Claude Code adapter가 있다)
    public var canRunAgents: Bool
    /// R: 이 Mac 런타임의 상태 (런타임이 없으면 nil)
    public var status: BridgeStatus?
    /// 이 Mac에 살아 있는 실행이 있다 (R)
    public var hasLiveProcess: Bool
    /// P: 이 Mac의 probe 보고 (아직 못 받았으면 nil)
    public var report: BridgeV1AdapterReport?
    public var target: Target
    /// 이 Mac의 표시 이름 (N, 서버 `bridges.device_name`): 모르면 nil
    public var deviceName: String?
    /// 살아 있는 실행 중 가장 이른 시작 시각 (R): 없으면 nil
    public var liveSince: Date?

    public init(
        canRunAgents: Bool, status: BridgeStatus? = nil, hasLiveProcess: Bool = false, report: BridgeV1AdapterReport? = nil, target: Target = .notLoaded,
        deviceName: String? = nil, liveSince: Date? = nil
    ) {
        self.canRunAgents = canRunAgents
        self.status = status
        self.hasLiveProcess = hasLiveProcess
        self.report = report
        self.target = target
        self.deviceName = deviceName
        self.liveSince = liveSince
    }
}

/// Your agents 줄 (DS `AgentRow`): 이름은 늘 Claude Code, 줄 말 하나, 오른쪽 컨트롤 하나
public struct AgentSettingsLine: Equatable, Sendable {
    /// 5.2 표의 어느 줄인가
    public enum Kind: Equatable, Sendable {
        case checking, unavailable, reconnect, tooManyMacs, notInstalled, connect, signInNeeded, offline, ready
    }

    /// 오른쪽: 없음(셰브런) · Connect · Reconnect · Level(고칠 수 없는 Value "Can write", SA-01 A)
    public enum Control: Equatable, Sendable {
        case none, connect, reconnect, level
    }

    public let kind: Kind
    /// 줄 말 (DS `detail`)
    public let detail: String
    /// 굵은 말: "Not signed in" · "Not connected"(폐기 · 자격 거절) · "Not installed" · "Too many Macs"뿐이다 (README :44, 빨강 0)
    public let bold: Bool
    public let control: Control

    public var accessibilityLabel: String {
        [AgentSettingsCopy.agentName, detail, controlName].compactMap { $0 }.joined(separator: ", ")
    }

    /// 접근성에 말할 동작 이름 (줄 + 상태 + 동작)
    public var controlName: String? {
        switch control {
        case .none: nil
        case .connect: AgentSettingsCopy.connect
        case .reconnect: AgentSettingsCopy.reconnect
        case .level: "\(AgentSettingsCopy.level) \(AgentSettingsCopy.canWrite)"
        }
    }
}

/// 상세의 값 하나 (읽기 전용 `Value`): 굵은 말은 DS가 정한 것만
public struct AgentSettingsValue: Equatable, Sendable {
    public let text: String
    public let bold: Bool

    public init(_ text: String, bold: Bool = false) {
        self.text = text
        self.bold = bold
    }
}

/// Claude Code 상세 (DS `AgentDetail` + DZ): 머리 · Status · Access · 각주. Folders · Disconnect는 `showsFolders` · `showsDisconnect`로만 가린다 ("What Taskforce can do"는 SA-04로 없다)
public struct AgentSettingsDetail: Equatable, Sendable {
    public let line: AgentSettingsLine
    /// Sign-in 줄: 없으면 줄이 없다 (설치 안 됨 · 이 빌드가 못 띄움: 로그인할 대상이 없다)
    public let signIn: AgentSettingsValue?
    public let session: AgentSettingsValue
    /// Version: 설치되지 않았거나 읽지 못했으면 줄이 없다
    public let version: String?
    /// This Mac: 이름을 모르면 줄이 없다 (짐작하지 않는다)
    public let thisMac: String?
    /// Status 각주: 조건마다 한 문장, 순서대로 하나만
    public let statusFootnote: String?
    /// Access › Level: 늘 "Can write"인 읽기 전용 Value (SA-01 A)
    public let level = AgentSettingsCopy.canWrite
    /// Access › Open now: 서버가 정한 열린 등급 (연결 없음 · 모르면 줄이 없다)
    public let openNow: AgentSettingsValue?
    /// Access 각주: Open now 줄이 있을 때만
    public var accessFootnote: String? { openNow == nil ? nil : AgentSettingsCopy.accessFootnote }
    /// Folders 절 (늘 보인다. 이 빌드가 못 띄우면 등록부가 없어 뺀다)
    public let showsFolders: Bool
    /// Disconnect this Mac 절: 연결이 있을 때만
    public let showsDisconnect: Bool
}

public enum AgentSettingsRules {
    // MARK: 줄 (5.2, 위에서부터 먼저 맞는 줄)

    public static func line(_ facts: AgentSettingsFacts) -> AgentSettingsLine {
        // 0. P · T를 아직 받지 못함 (이 빌드가 못 띄우면 기다릴 것이 없다 → 아래 1)
        if facts.canRunAgents, facts.report == nil || facts.target == .notLoaded { return line(.checking, AgentSettingsCopy.checking, control: .none) }
        // 1. 이 빌드가 못 띄움
        guard facts.canRunAgents else { return line(.unavailable, AgentSettingsCopy.cantRunInThisBuild, control: .level) }
        // 2. 폐기 · 자격 거절
        if facts.status == .revoked || facts.status == .credentialRejected {
            return line(.reconnect, AgentSettingsCopy.notConnected, bold: true, control: .reconnect)
        }
        // 3. 이 계정의 Mac이 10대
        if facts.status == .tooManyBridges { return line(.tooManyMacs, AgentSettingsCopy.tooManyMacs, bold: true, control: .none) }
        // 4. 설치 안 됨
        if facts.report?.installed == false { return line(.notInstalled, AgentSettingsCopy.notInstalled, bold: true, control: .none) }
        switch facts.target {
        case .notLoaded:
            return line(.checking, AgentSettingsCopy.checking, control: .none)
        case .none:
            // 5. 연결 없음
            return line(.connect, AgentSettingsCopy.notConnected, control: .connect)
        case .row(let state, let access):
            switch state {
            case .notConnected:
                return line(.connect, AgentSettingsCopy.notConnected, control: .connect)
            case .signInNeeded:
                // 6.
                return line(.signInNeeded, AgentSettingsCopy.notSignedIn, bold: true, control: .level)
            case .unreachable:
                // 7. (서버 판정)
                return line(.offline, AgentSettingsCopy.offline, control: .level)
            case .ready, .unsupported:
                // 7. (이 Mac 런타임이 서버에 닿지 못한다)
                if facts.status == .offline || facts.status == .sleeping { return line(.offline, AgentSettingsCopy.offline, control: .level) }
                // 8. 그 밖
                var text = facts.hasLiveProcess ? AgentSettingsCopy.signedInSessionActive : AgentSettingsCopy.signedInNoSession
                if state == .unsupported { text += " · \(AgentSettingsCopy.unsupported)" }
                if access == .readOnly { text += " · \(AgentSettingsCopy.readOnly)" }
                return line(.ready, text, control: .level)
            case .unknown:
                // 모르는 서버 상태: 아무것도 주장하지 않는다
                return line(.checking, AgentSettingsCopy.checking, control: .none)
            }
        }
    }

    private static func line(_ kind: AgentSettingsLine.Kind, _ detail: String, bold: Bool = false, control: AgentSettingsLine.Control) -> AgentSettingsLine {
        AgentSettingsLine(kind: kind, detail: detail, bold: bold, control: control)
    }

    /// 이 Mac의 에이전트 연결이 서버에 있다 (끊을 것이 있다): T가 연결 행을 주고(`not_connected`가 아니다) 이 Mac 런타임이 폐기 · 거절 · 10대 상태가 아니다
    public static func hasConnection(_ facts: AgentSettingsFacts) -> Bool {
        guard facts.canRunAgents, case .row(let state, _) = facts.target, state != .notConnected else { return false }
        return ![.revoked, .credentialRejected, .tooManyBridges].contains(facts.status)
    }

    // MARK: 상세 (5.3)

    public static func detail(_ facts: AgentSettingsFacts, timeZone: TimeZone = .current) -> AgentSettingsDetail {
        let line = line(facts)
        let report = facts.report
        let installed = report?.installed != false
        // Status
        var signIn: AgentSettingsValue?
        if facts.canRunAgents, installed {
            switch report?.signedIn {
            case .yes?: signIn = AgentSettingsValue(AgentSettingsCopy.signedIn)
            case .no?: signIn = AgentSettingsValue(AgentSettingsCopy.notSignedIn, bold: true)
            case .unknown?, nil: signIn = AgentSettingsValue(AgentSettingsCopy.checking)
            }
        }
        let session = AgentSettingsValue(facts.liveSince.map { AgentSettingsCopy.activeSince(WhenText.time($0, timeZone: timeZone)) } ?? AgentSettingsCopy.none)
        let version = installed ? report?.version : nil
        let thisMac = facts.deviceName.flatMap { $0.isEmpty ? nil : $0 }
        return AgentSettingsDetail(
            line: line, signIn: signIn, session: session, version: version, thisMac: thisMac, statusFootnote: statusFootnote(facts, line: line),
            openNow: openNow(facts, line: line), showsFolders: facts.canRunAgents, showsDisconnect: hasConnection(facts)
        )
    }

    /// Status 각주: 조건마다 한 문장, 순서대로 하나만 (로그인 안 됨 → 설치 안 됨 → managed settings → 지원하지 않는 버전 → 연결 전 안내)
    static func statusFootnote(_ facts: AgentSettingsFacts, line: AgentSettingsLine) -> String? {
        guard facts.canRunAgents, let report = facts.report else { return nil }
        if report.installed, report.signedIn == .no { return AgentSettingsCopy.signInHelp }
        if !report.installed { return AgentSettingsCopy.installHelp }
        if report.managedSettings { return AgentSettingsCopy.managedSettings }
        // 이 Mac adapter 자신의 사실 (`ClaudeCodeSupport.supports`, 서버 registry와 같은 범위를 시험이 대조한다). "Unsupported"라고 말하는 것은 서버 판정(Open now)뿐이다
        if report.installed, let version = report.version, !ClaudeCodeSupport.supports(version) { return AgentSettingsCopy.unsupportedVersion }
        if line.kind == .connect { return AgentSettingsCopy.connectIntro }
        return nil
    }

    /// Access › Open now: 이 빌드가 못 띄우면 그 말, 아니면 서버가 정한 열린 등급 (`unsupported` → "Unsupported", `read_only` → "Read only", `write` → "Can write"). 연결 없음 · 모르면 줄이 없다
    static func openNow(_ facts: AgentSettingsFacts, line: AgentSettingsLine) -> AgentSettingsValue? {
        if line.kind == .unavailable { return AgentSettingsValue(AgentSettingsCopy.cantRunInThisBuild, bold: true) }
        guard [.signInNeeded, .offline, .ready].contains(line.kind), case .row(let state, let access) = facts.target else { return nil }
        if state == .unsupported { return AgentSettingsValue(AgentSettingsCopy.unsupported, bold: true) }
        switch access {
        case .write?: return AgentSettingsValue(AgentSettingsCopy.canWrite)
        case .readOnly?: return AgentSettingsValue(AgentSettingsCopy.readOnly)
        case .unknown?, nil: return nil
        }
    }

    // MARK: T 고르기

    /// 대상 목록에서 이 Mac의 Claude Code 연결 행: adapter가 같고 `bridge_id`가 이 Mac의 bridge id인 행. 이 Mac이 등록 전이거나 그런 행이 없으면 nil (다른 Mac의 연결은 이 Mac의 것이 아니다)
    public static func thisMacRow(in targets: [AssistantTarget], adapter: String, bridgeID: UUID?) -> AssistantTarget.Agent? {
        guard let bridgeID else { return nil }
        for case .agent(let agent) in targets where agent.adapter == adapter && agent.bridgeID == bridgeID { return agent }
        return nil
    }

    /// 읽은 대상 목록 → T
    public static func target(from row: AssistantTarget.Agent?) -> AgentSettingsFacts.Target {
        guard let row else { return .none }
        return .row(state: row.state, access: row.access)
    }
}
#endif
