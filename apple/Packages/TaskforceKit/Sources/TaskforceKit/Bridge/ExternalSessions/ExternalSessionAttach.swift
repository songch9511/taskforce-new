#if os(macOS)
import Foundation
import Observation

/// 이어받기 흐름이 쓰는 이 Mac의 런타임 면 (`BridgeRuntime`이 따른다, 시험은 가짜를 낀다)
public protocol ExternalSessionAttaching: Sendable {
    func prepareAttach(sessionID: String, folder: String) async -> Result<AttachPlan, AttachRefusal>
    func commitAttach(_ plan: AttachPlan, agentSessionID: UUID, server: AttachServerFacts) async -> AttachRefusal?
    func cancelAttach(_ plan: AttachPlan) async
}

extension BridgeRuntime: ExternalSessionAttaching {}

/// 이 계정의 세션 폴더 상태가 묶은 Claude id들 (목록이 쓴다): Taskforce가 시작한 세션의 id는 목록에서 빼고, **이 Mac이 이어받은** 세션의 id는 "In Taskforce"로 남긴다 (Sessions 패널은 그 줄을 Taskforce 절에서만 보인다).
/// 세션 폴더(UUID 이름)의 `state.json`만 읽는다 (글 · 경로 0)
public enum ExternalSessionBoundIDs {
    public static func read(sessionsRoot: URL) -> (taskforce: Set<String>, attached: Set<String>) {
        var taskforce = Set<String>()
        var attached = Set<String>()
        // 폴더 이름을 거르지 않는다 (`lineage` · `probe-cwd` 같은 폴더는 `state.json`이 없어 빈 상태라 건너뛴다): 이전 동작 그대로
        for folder in (try? FileManager.default.contentsOfDirectory(at: sessionsRoot, includingPropertiesForKeys: nil)) ?? [] {
            let state = ClaudeSessionState.load(from: folder)
            guard let id = state.providerSessionID?.lowercased() else { continue }
            if state.origin == .attached, state.bound { attached.insert(id) } else { taskforce.insert(id) }
        }
        return (taskforce, attached)
    }
}

/// 계정마다 바뀌는 런타임을 부를 때마다 찾아 쓰는 면: 런타임이 없으면(로그아웃 · bridge가 꺼진 빌드) 준비 못 한 것이다 (`notReady`)
public struct ExternalSessionAttachingHost: ExternalSessionAttaching {
    private let runtime: @Sendable () async -> BridgeRuntime?

    public init(runtime: @escaping @Sendable () async -> BridgeRuntime?) { self.runtime = runtime }

    public func prepareAttach(sessionID: String, folder: String) async -> Result<AttachPlan, AttachRefusal> {
        guard let runtime = await runtime() else { return .failure(.notReady) }
        return await runtime.prepareAttach(sessionID: sessionID, folder: folder)
    }

    public func commitAttach(_ plan: AttachPlan, agentSessionID: UUID, server: AttachServerFacts) async -> AttachRefusal? {
        guard let runtime = await runtime() else { return .notReady }
        return await runtime.commitAttach(plan, agentSessionID: agentSessionID, server: server)
    }

    public func cancelAttach(_ plan: AttachPlan) async {
        await runtime()?.cancelAttach(plan)
    }
}

/// 이 Mac의 Claude Code 대상 (대상 목록의 `bridge_id`가 이 Mac인 연결). 대상 목록을 읽지 못했으면 값 자체가 없다(nil: 게이트는 닫힌 채 둔다)
public struct ExternalSessionAttachTarget: Sendable, Equatable {
    /// 이 Mac의 연결. 이 Mac에 Claude Code 연결이 없으면 nil
    public var connectionID: UUID?
    /// `ready`가 아니면 그 대상 단어 ("Not connected" · "Offline" · "Sign in needed" · "Unsupported"). ready면 nil
    public var word: String?

    public init(connectionID: UUID?, word: String?) {
        self.connectionID = connectionID
        self.word = word
    }
}

/// 이어받기 흐름이 서버 · 이 Mac 밖에서 읽는 것들 (시험은 가짜를 낀다)
public struct ExternalSessionAttachServer: Sendable {
    public var bridgeID: @Sendable () async -> UUID?
    public var availability: @Sendable () async -> AgentAttachAvailability
    public var target: @Sendable (_ bridgeID: UUID) async -> ExternalSessionAttachTarget?
    public var attach: @Sendable (_ bridgeID: UUID, _ adapter: String, _ sessionID: String, _ workspaceRef: String) async throws -> AttachAgentSessionResponse
    public var readSession: @Sendable (_ id: UUID) async -> (connectionID: UUID, externalSessionID: String)?

    public init(
        bridgeID: @escaping @Sendable () async -> UUID?, availability: @escaping @Sendable () async -> AgentAttachAvailability,
        target: @escaping @Sendable (UUID) async -> ExternalSessionAttachTarget?,
        attach: @escaping @Sendable (UUID, String, String, String) async throws -> AttachAgentSessionResponse,
        readSession: @escaping @Sendable (UUID) async -> (connectionID: UUID, externalSessionID: String)?
    ) {
        self.bridgeID = bridgeID
        self.availability = availability
        self.target = target
        self.attach = attach
        self.readSession = readSession
    }
}

/// 이어받기 문구 (사용자 승인 2026-10-21 · 계약 17장). 새 말은 확인 줄의 둘과 거절 한 줄 하나뿐이고, 나머지는 이미 승인된 말을 그대로 쓴다
public enum ExternalSessionAttachCopy {
    /// 이미 승인된 말 ("Resume here": 줄의 단추 · 확인 단추)
    public static let resumeHere = AgentCopy.resumeConfirm
    public static let confirmTitle = "Resume this session in Taskforce?"
    /// 계약 17장이 고친 S14: 앞 문장("It stays in Claude too.")은 행동에 필요 없어 뺐다
    public static let confirmDetail = "Don't open it in Claude while Taskforce is working."
    public static let closeInClaudeFirst = "Close it in Claude first"
    /// 이미 승인된 말
    public static let closeTerminalFirst = AgentCopy.closeTerminalFirst

    /// 확인 줄 안의 회색 한 줄 (계약 8.3 · 8.2): 새 말을 만들지 않고 줄의 상태 말 · 이미 승인된 말을 재사용한다
    public static func note(for refusal: AttachRefusal) -> String {
        switch refusal {
        case .held(.claudeApp): closeInClaudeFirst
        case .held(.terminal): closeTerminalFirst
        case .held(.background), .held(.unknown), .inUse: ExternalSessionCopy.runningElsewhere
        case .couldNotCheck: ExternalSessionCopy.couldNotCheck
        case .folder: ExternalSessionCopy.folderNotAllowed
        case .unreadable: ExternalSessionCopy.unreadable
        case .version: ExternalSessionCopy.updateClaudeCode
        case .notReady: AgentCopy.notConnected
        case .server: AgentCopy.spawnFailed
        }
    }

    /// 이어받은 세션의 턴이 "다른 곳에서 쥐고 있어" 막혔을 때 세션 패널 머리 아래 상태 줄 (계약 S16: 줄의 상태 말을 그대로 쓴다, 새 말 0)
    public static func holdLine(for verdict: ExternalWriterVerdict) -> String {
        switch verdict {
        case .held(.claudeApp): ExternalSessionCopy.runningInClaude
        case .held(.terminal): ExternalSessionCopy.runningInTerminal
        case .held(.background), .held(.unknown): ExternalSessionCopy.runningElsewhere
        case .unknown: ExternalSessionCopy.couldNotCheck
        case .free: ""
        }
    }

    /// 계약 10장 `session_attach_refused.detail`의 말 (지표 · 로그는 이 코드만)
    public static func detail(for refusal: AttachRefusal) -> String {
        switch refusal {
        case .held, .inUse: "running_elsewhere"
        case .couldNotCheck, .unreadable: "unreadable"
        case .folder: "folder"
        case .version: "version"
        case .notReady: "not_ready"
        case .server: "server"
        }
    }
}

/// "On this Mac" 줄의 Resume here 상태와 흐름 (OA 외부 세션 PR2m, 계약 6.1 · 8.3 · 17장)
///
/// - **게이트**: 서버가 이어받기를 열었고(`agentAttachAvailability`: 플래그 · 베타 명단) 이 Mac의 Claude Code 대상 행이 ready일 때만 줄에 Resume here가 있다. 서버가 닫았거나 모르면 아무것도 보이지 않는다.
///   플래그는 한 시간에 한 번만 묻고(모르면 1분 뒤 다시), 대상 행은 부를 때마다 읽는다
/// - **흐름**: 줄의 Resume here → `request`(제자리 확인, 아무것도 하지 않는다) → 확인을 누름 `confirm`: ① 이 Mac의 런타임이 그 세션을 **그 순간 다시 판정**하고 계획을 낸다(`prepareAttach`)
///   ② 서버 `POST /api/v2/agent-sessions/attach` ③ 서버가 적은 행을 이 Mac이 RLS로 읽는다 ④ 서버 답이 계획과 맞을 때만 런타임이 핀 · 상태를 쓴다(`commitAttach`, 20장 2).
///   실패하면 확인 줄 안의 회색 한 줄과 함께 확인으로 돌아간다: 닫고 다시 누르면 서버가 같은 행을 돌려주어(멱등) 끝낸다 (6.1-4)
/// - 같은 줄에 대한 확인은 하나만 돈다. 계정이 떠나면 모두 지우고 늦은 답은 쓰지 않는다 (계획은 거둔다). 로그는 코드뿐이다 (id · 폴더 · 제목 0)
@MainActor
@Observable
public final class ExternalSessionAttachModel {
    public enum Phase: Equatable, Sendable {
        /// 줄 밑에 제자리 확인이 서 있다 (`note`는 직전 거절의 회색 한 줄)
        case confirming(note: String?)
        /// 서버 · 로컬 확정이 도는 중이다
        case working

        /// 직전 거절의 회색 한 줄 (확인 중이고 거절이 있었을 때만)
        public var note: String? {
            if case .confirming(let note) = self { note } else { nil }
        }
    }

    public enum Gate: Equatable, Sendable {
        /// 서버가 이어받기를 닫았거나 알 수 없다: Resume here도 확인도 없다
        case unavailable
        /// 서버는 열렸는데 이 Mac의 대상 행이 ready가 아니다: 줄은 그 대상 단어를 보인다 (8.2-8)
        case notReady(word: String)
        case ready
    }

    public enum Outcome: Equatable, Sendable {
        case attached(UUID)
        case refused(AttachRefusal)
        /// 아무것도 하지 않았다 (확인이 없었다 · 게이트가 닫혔다 · 계정이 떠났다 · 취소됐다)
        case ignored
    }

    public private(set) var phases: [String: Phase] = [:]
    public private(set) var gate: Gate = .unavailable

    /// 서버 플래그를 다시 묻는 간격 (열림 · 닫힘) · 모를 때
    public static let probeInterval: TimeInterval = 3600
    public static let unknownRetryInterval: TimeInterval = 60

    @ObservationIgnored private let scope: AccountScope
    @ObservationIgnored private let runtime: any ExternalSessionAttaching
    @ObservationIgnored private let server: ExternalSessionAttachServer
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let log: any BridgeLogSink
    /// 이어받기가 끝났다 (새 Taskforce 세션의 id): 셸이 목록을 다시 읽고 세션 패널을 연다
    @ObservationIgnored public var onAttached: @MainActor (UUID) async -> Void
    @ObservationIgnored private var lastProbe: (availability: AgentAttachAvailability, at: Date)?

    public init(
        scope: AccountScope, runtime: any ExternalSessionAttaching, server: ExternalSessionAttachServer, now: @escaping @Sendable () -> Date = { Date() },
        log: any BridgeLogSink = NoBridgeLog(), onAttached: @escaping @MainActor (UUID) async -> Void = { _ in }
    ) {
        self.scope = scope
        self.runtime = runtime
        self.server = server
        self.now = now
        self.log = log
        self.onAttached = onAttached
        scope.onLeft { [weak self] in self?.reset() }
    }

    public func reset() {
        phases = [:]
        gate = .unavailable
        lastProbe = nil
    }

    // MARK: 게이트

    /// 서버가 열렸나 · 이 Mac의 대상이 ready인가를 다시 읽는다 (Sessions 패널이 열릴 때)
    public func refreshGate(force: Bool = false) async {
        guard let token = scope.token else {
            gate = .unavailable
            return
        }
        let current = now()
        let availability: AgentAttachAvailability
        if !force, let last = lastProbe, current.timeIntervalSince(last.at) < (last.availability == .unknown ? Self.unknownRetryInterval : Self.probeInterval) {
            availability = last.availability
        } else {
            availability = await server.availability()
            guard scope.isCurrent(token) else { return }
            lastProbe = (availability, current)
        }
        guard availability == .enabled, let bridge = await server.bridgeID() else {
            if scope.isCurrent(token) { gate = .unavailable }
            return
        }
        let target = await server.target(bridge)
        guard scope.isCurrent(token) else { return }
        // 대상 목록을 읽지 못했다: 모른다 → 닫힌 채. 이 Mac의 연결이 없거나 ready가 아니면 그 대상 단어를 말한다
        guard let target else {
            gate = .unavailable
            return
        }
        if target.connectionID != nil, target.word == nil {
            gate = .ready
        } else {
            gate = .notReady(word: target.word ?? AgentCopy.notConnected)
        }
    }

    /// 이 줄에 Resume here를 보이나: 게이트가 ready · 아무 곳에서도 열려 있지 않다(`available`) · 폴더를 안다 · 소문자 정규 UUID · 도는 중이 아니다
    public func canResume(_ row: ExternalSessionRow) -> Bool {
        gate == .ready && row.status == .available && row.folderPath != nil && ExternalSessionRules.isCanonicalUUID(row.id) && phases[row.id] != .working
    }

    // MARK: 제자리 확인

    /// 줄의 Resume here를 눌렀다: 확인을 세운다 (아무것도 하지 않는다). 한 번에 하나만 선다 (도는 중인 줄은 그대로)
    public func request(_ row: ExternalSessionRow) {
        guard canResume(row) else { return }
        phases = phases.filter { $0.value == .working }
        phases[row.id] = .confirming(note: nil)
    }

    /// 확인의 Cancel (도는 중에는 지우지 않는다)
    public func cancel(_ id: String) {
        if case .confirming = phases[id] { phases[id] = nil }
    }

    /// 확인을 눌렀다 (계약 6.1-2): 이 순간 다시 판정하고 이어받는다. 보이는 확인이 없는 줄 · 게이트가 닫힌 줄은 아무것도 하지 않는다
    @discardableResult
    public func confirm(_ row: ExternalSessionRow) async -> Outcome {
        guard case .confirming = phases[row.id], canResume(row), let folder = row.folderPath, let token = scope.token else { return .ignored }
        phases[row.id] = .working
        let outcome = await run(row: row, folder: folder, token: token)
        guard scope.isCurrent(token) else { return .ignored }
        switch outcome {
        case .attached(let id):
            phases[row.id] = nil
            log.log("attach_done", [:])
            await onAttached(id)
        case .refused(let refusal):
            phases[row.id] = .confirming(note: ExternalSessionAttachCopy.note(for: refusal))
            log.log("attach_refused", ["reason": .code(ExternalSessionAttachCopy.detail(for: refusal))])
        case .ignored:
            phases[row.id] = .confirming(note: nil)
        }
        return outcome
    }

    private func run(row: ExternalSessionRow, folder: String, token: AccountScope.Token) async -> Outcome {
        let plan: AttachPlan
        switch await runtime.prepareAttach(sessionID: row.id, folder: folder) {
        case .failure(let refusal): return .refused(refusal)
        case .success(let made): plan = made
        }
        guard scope.isCurrent(token) else {
            await runtime.cancelAttach(plan)
            return .ignored
        }
        let response: AttachAgentSessionResponse
        do {
            response = try await server.attach(plan.bridgeID, plan.adapter, plan.sessionID, plan.workspaceRef)
        } catch is CancellationError {
            await runtime.cancelAttach(plan)
            return .ignored
        } catch {
            await runtime.cancelAttach(plan)
            return .refused(Self.refusal(for: error))
        }
        // 서버가 그 세션 행에 적은 값을 이 Mac이 RLS로 읽는다: 응답의 `session`에는 외부 id가 없다 (20장 2)
        let written = await server.readSession(response.session.id)
        let target = await server.target(plan.bridgeID)
        guard scope.isCurrent(token) else {
            await runtime.cancelAttach(plan)
            return .ignored
        }
        guard let written, written.connectionID == response.session.connectionID else {
            await runtime.cancelAttach(plan)
            return .refused(.server)
        }
        let facts = AttachServerFacts(externalSessionID: written.externalSessionID, workspaceRef: response.workspaceRef, connectionID: written.connectionID, thisMacConnectionID: target?.connectionID)
        if let refusal = await runtime.commitAttach(plan, agentSessionID: response.session.id, server: facts) { return .refused(refusal) }
        return .attached(response.session.id)
    }

    /// 서버 오류 → 거절: 409(다른 곳이 이미 이어받았다 · 가상 루트가 다른 폴더에 묶여 있다)는 "이미 쓰이는 중"이고 나머지(꺼짐 404 · 403 · 429 · 5xx · 전송 오류 · 모양 오류)는 서버 실패다
    static func refusal(for error: Error) -> AttachRefusal {
        if let api = error as? APIError, case .server(409, .conflict, _) = api { return .inUse }
        return .server
    }
}
#endif
