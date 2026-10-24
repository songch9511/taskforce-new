#if os(macOS)
import Foundation

// 외부 세션 이어받기 — 이 Mac의 로컬 쪽 (OA 외부 세션 PR2m, 계약 6.1 · 9.2 · 20장).
//
// **쓰기는 로컬 Resume here 확인에서만 일어난다** (20장 1): 핀(`attachPin`)과 상태(`bindAttached`)는 `commitAttach` 하나만 쓰고, 그 함수는 `prepareAttach`가 방금 낸 계획만 받는다.
// 명령 · push · wake · 서버가 시작한 길은 이 파일의 함수를 부르지 않는다 (소스 검사 시험이 호출자 목록을 고정한다).
// 흐름: 준비(로컬 사실만 보고 계획을 낸다, 쓰기 0) → [서버 `POST /api/v2/agent-sessions/attach`] → 확정(서버 답이 이 Mac의 계획과 맞을 때만 핀 → 상태). 서버 호출은 앱이 사용자 토큰으로 한다 (bridge 자격이 아니다).
// Claude id는 로컬 스캔 값(정규 소문자 UUID)이고 서버가 돌려준 id는 **대조에만** 쓴다 (다르면 거절, 쓰지 않는다).

/// 이어받기 계획 (계약 6.1): 로컬 Resume here 확인이 `prepareAttach`로 만든 것만 `commitAttach`가 받는다 (런타임이 낸 계획을 기억하고, 같은 계획이 아니면 거절한다)
public struct AttachPlan: Sendable, Equatable {
    /// Claude 세션 id (로컬 스캔 값: 정규 소문자 UUID)
    public let sessionID: String
    /// 작업 폴더 (realpath, 이 Mac 안에서만)
    public let folder: String
    /// 서버에 보낼 불투명 id (`ws_<uuid>`)
    public let ref: String
    public let bridgeID: UUID
    public let adapter: String
    let nonce: UUID
    let issuedAt: Date

    /// 서버로 가는 가상 루트 `/taskforce/<ws_id>` (경로는 가지 않는다)
    public var workspaceRef: String { VirtualWorkspacePaths.virtualRoot(forRef: ref) }
}

/// 이어받지 못한 이유 (계약 8.2 · 10장 `session_attach_refused.detail`)
public enum AttachRefusal: Error, Equatable, Sendable {
    /// 지금 다른 곳(데스크톱 · 터미널 · 백그라운드 · 모름)이 쥐고 있다
    case held(ExternalSessionHolder)
    /// 쥔 곳이 있는지 판정하지 못했다 (막는다)
    case couldNotCheck
    /// 폴더가 규칙을 통과하지 못했다 · 프로젝트 폴더와 겹친다 · 이 세션의 핀이 다른 폴더다
    case folder
    /// 세션 id 모양이 틀렸다
    case unreadable
    /// Claude Code가 없거나 이어받기 최소 버전(2.1.304) · adapter 범위 밖이다
    case version
    /// 이 Mac의 런타임 · 연결 · 로그인이 준비되지 않았다 (또는 이미 같은 세션을 준비 중이다)
    case notReady
    /// 이 Claude 세션을 이미 다른 Taskforce 세션이 쥐었다 (다른 Mac의 연결 · 이 Mac의 다른 세션)
    case inUse
    /// 서버가 실패했거나 서버 답이 이 Mac의 계획과 맞지 않는다
    case server
}

/// 서버가 이어받기에 답한 사실 (응답 + 이 Mac이 RLS로 읽은 그 세션 행): `commitAttach`가 이 Mac의 계획과 맞추어 본다 (계약 20장 2)
public struct AttachServerFacts: Sendable, Equatable {
    /// 서버가 그 세션 행에 적은 외부 세션 id (이 Mac이 보낸 로컬 id와 같아야 한다)
    public var externalSessionID: String
    /// 서버가 저장한 가상 루트 (이 Mac이 보낸 값과 같아야 한다: `existing`은 다른 기기의 옛 값을 돌려줄 수 있다)
    public var workspaceRef: String
    /// 그 세션 행의 연결
    public var connectionID: UUID
    /// 이 Mac의 Claude Code 연결 (대상 목록의 `bridge_id`가 이 Mac인 연결). 모르면 nil → 거절
    public var thisMacConnectionID: UUID?
    /// 그 대상이 지금 `ready`다 (대상 단어가 없다, 계약 6.1-2). 서버가 답한 사이 Offline 같은 단어가 생겼으면 false → 거절
    public var thisMacReady: Bool

    public init(externalSessionID: String, workspaceRef: String, connectionID: UUID, thisMacConnectionID: UUID?, thisMacReady: Bool) {
        self.externalSessionID = externalSessionID
        self.workspaceRef = workspaceRef
        self.connectionID = connectionID
        self.thisMacConnectionID = thisMacConnectionID
        self.thisMacReady = thisMacReady
    }
}

extension BridgeRuntime {
    /// 계획이 확정을 기다리는 최대 시간 (서버 호출 + 여유). 넘으면 계획은 죽는다
    static let attachPlanLifetime: TimeInterval = 300

    /// 이어받기 준비: **로컬 사실만 보고 쓰지 않는다** (등록부 · 상태 · 서버 0). 조건 (계약 6.1-2): 정규 소문자 UUID ∧ 폴더 규칙 · 겹침 규칙 통과 ∧ 이 Mac의 런타임 준비
    /// ∧ Claude Code 설치 · 버전 ≥ 2.1.304 · adapter 범위 · 로그인 ∧ **쥔 곳 없음**(`free`, 모르면 막는다). 통과하면 서버에 보낼 불투명 id를 담은 계획을 낸다.
    /// 같은 Claude id를 이미 준비 중이면 막는다 (같은 id에 대한 Resume here 두 번은 하나만)
    public func prepareAttach(sessionID: String, folder: String) async -> Result<AttachPlan, AttachRefusal> {
        guard ExternalSessionRules.isCanonicalUUID(sessionID) else { return .failure(.unreadable) }
        guard !shuttingDown, networkEnabled, let adapter = adapters[ClaudeCodeSupport.adapterID] as? any AttachableSessionAdapter,
              let resolver = workspaces as? RegistryWorkspaceResolver, let bridge = await localBridgeID() else { return .failure(.notReady) }
        guard let proposal = resolver.registry.proposedRef(forPath: folder) else { return .failure(.folder) }
        let report = await adapter.probe()
        guard report.installed, adapter.supportsVersion(report.version),
              let version = report.version, ExternalSessionRules.version(version, atLeast: ExternalSessionRules.minimumResumeVersion) == true else { return .failure(.version) }
        guard report.signedIn != .no else { return .failure(.notReady) }
        switch await adapter.probeExternalWriter(providerSessionID: sessionID, workspace: proposal.path) {
        case .free: break
        case .held(let holder): return .failure(.held(holder))
        case .unknown: return .failure(.couldNotCheck)
        }
        // 위의 await가 끝났다: 아래는 await 없이 계획을 내고 기억한다 (겹친 두 준비 중 하나만)
        guard !shuttingDown else { return .failure(.notReady) }
        let now = clock.now()
        if let pending = pendingAttaches[sessionID], now.timeIntervalSince(pending.issuedAt) < Self.attachPlanLifetime { return .failure(.notReady) }
        let plan = AttachPlan(sessionID: sessionID, folder: proposal.path, ref: proposal.ref, bridgeID: bridge, adapter: ClaudeCodeSupport.adapterID, nonce: UUID(), issuedAt: now)
        pendingAttaches[sessionID] = plan
        return .success(plan)
    }

    /// 이어받기 확정: 서버가 답한 뒤 사용자 행동의 길에서만 부른다. **계획을 한 번만 받는다** (쓰든 거절하든 거둔다).
    /// 서버 답(`server`)이 계획과 맞아야 한다 (20장 2): 외부 id = 로컬 id · 가상 루트 = 보낸 값 · 세션 행의 연결 = 이 Mac의 연결. 하나라도 다르면 거절하고 **핀도 상태도 쓰지 않는다**.
    /// 서버 답을 기다린 사이 다른 곳이 쥐었는지 한 번 더 본다. 그다음 핀(`attachPin`: 이미 다른 폴더에 핀이 있으면 거절) → 상태(`bindAttached`: 이미 다른 id로 묶였으면 거절).
    /// 핀만 꽂히고 멈춰도 다시 누르면 서버가 같은 행을 돌려주어 나머지를 마친다 (둘 다 멱등)
    public func commitAttach(_ plan: AttachPlan, agentSessionID: UUID, server: AttachServerFacts) async -> AttachRefusal? {
        guard pendingAttaches[plan.sessionID] == plan else { return .notReady }
        pendingAttaches[plan.sessionID] = nil
        guard !shuttingDown, clock.now().timeIntervalSince(plan.issuedAt) < Self.attachPlanLifetime,
              let adapter = adapters[plan.adapter] as? any AttachableSessionAdapter, let resolver = workspaces as? RegistryWorkspaceResolver else { return .notReady }
        guard server.externalSessionID == plan.sessionID, server.workspaceRef == plan.workspaceRef, let mac = server.thisMacConnectionID, server.connectionID == mac else { return .server }
        // 이 Mac의 대상이 확정 순간에도 ready여야 한다 (계약 6.1-2): 서버가 답하는 사이 Offline 같은 단어가 생겼으면 쓰지 않는다
        guard server.thisMacReady else { return .notReady }
        switch await adapter.probeExternalWriter(providerSessionID: plan.sessionID, workspace: plan.folder) {
        case .free: break
        case .held(let holder): return .held(holder)
        case .unknown: return .couldNotCheck
        }
        guard !shuttingDown else { return .notReady }
        let sessionKey = agentSessionID.uuidString.lowercased()
        // 이 호출이 새로 꽂은 핀만 뒤 단계가 실패하면 되돌린다 (보안 P3-2): 이미 있던 핀(반쯤 끝난 이어받기)은 건드리지 않는다
        var created: String?
        switch resolver.registry.attachPin(session: sessionKey, to: plan.folder, ref: plan.ref) {
        case .pinned(let ref):
            created = ref
            guard ref == plan.ref else {
                resolver.registry.unpinIfEqual(session: sessionKey, ref: ref)
                return .server
            }
        case .samePin(let ref): guard ref == plan.ref else { return .server }
        case .pinnedElsewhere, .rejected: return .folder
        case .refTaken: return .server
        }
        switch await adapter.bindAttached(agentSessionID: sessionKey, providerSessionID: plan.sessionID, at: clock.now()) {
        case .written, .alreadyAttached: return nil
        case .refused:
            if let created { resolver.registry.unpinIfEqual(session: sessionKey, ref: created) }
            return .inUse
        }
    }

    /// 서버 호출이 실패했다 · 사용자가 취소했다: 계획을 거둔다 (같은 세션을 다시 준비할 수 있다)
    public func cancelAttach(_ plan: AttachPlan) {
        if pendingAttaches[plan.sessionID] == plan { pendingAttaches[plan.sessionID] = nil }
    }

    /// 마지막으로 "다른 곳에서 쥐고 있어" 이 세션의 턴을 막은 이유 (세션 패널이 "Running in Claude" 같은 상태 줄로 보인다, 계약 S16). 다음 턴이 통과하면 nil
    public func attachedHold(forAgentSession sessionID: UUID) async -> ExternalWriterVerdict? {
        guard let adapter = adapters[ClaudeCodeSupport.adapterID] as? any AttachableSessionAdapter else { return nil }
        return await adapter.externalHold(forAgentSession: sessionID.uuidString.lowercased())
    }

    // MARK: 명령 길 (읽기만: 이 Mac의 상태를 바꾸지 않는다)

    /// 이어받은 세션의 명령이 **로컬 이어받기 시각 이후에** 서버가 만든 것인가 (계약 20장 6). 사용자가 확인하기 전에 서버가 미리 쌓아 둔 명령이 확인 직후 실행되지 않게 한다.
    /// 서버 시각을 이 Mac의 시계로 옮겨 본다 (`clockOffsetMS` = 서버 − 로컬). 시계 추정 오차 안(2초)은 받는다. 서버가 만든 시각을 모르면 막는다.
    /// 이어받은 세션이 아니면(Taskforce가 시작한 세션 · 다른 adapter) 늘 true다
    func commandPostdatesAttach(_ record: BridgeCommandRecord, adapter: any AgentProcess, session: String) async -> Bool {
        guard let attachable = adapter as? any AttachableSessionAdapter, let since = await attachable.attachedSince(agentSession: session) else { return true }
        guard let created = record.serverCreatedAt else { return false }
        let offset = TimeInterval(((try? await ledger.meta())?.clockOffsetMS) ?? 0) / 1000
        return created.addingTimeInterval(-offset) >= since.addingTimeInterval(-Self.attachClockTolerance)
    }

    /// 서버 시각 → 이 Mac 시각 변환의 오차 허용 (왕복 중간점 추정의 한계)
    static let attachClockTolerance: TimeInterval = 2
}
#endif
