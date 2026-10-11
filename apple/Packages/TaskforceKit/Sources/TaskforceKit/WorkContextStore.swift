import Foundation
import Observation

/// 범위 멤버십 쓰기 한 번의 결과. 성공은 서버가 200으로 답한 뒤에만 말한다 (낙관적 표시 없음, 409 · 응답 유실 뒤의 지금 상태는 성공의 증거가 아니다)
public enum ProjectWriteResult: Equatable, Sendable {
    /// 200: 서버가 처리했다. `canUndo`: 실제로 바뀐 멤버가 있어 되돌릴 수 있다 (`change`가 비면 Undo 없음)
    case applied(canUndo: Bool)
    /// 409: 요청이 본 범위가 그 사이 바뀌었다 (쓰기 0). 자동 재전송 없이 지금 상태를 다시 읽어 보였다
    case conflict
    /// 응답을 받지 못했거나(전송 오류) 서버 오류: 서버가 처리했는지 모른다. 자동 재전송 없이 지금 상태를 다시 읽어 보였다
    case unconfirmed
    /// 이 동작을 줄 수 없다: gate 꺼짐 · 범위가 보관됐거나 없음 · 할 일이 없음
    case unavailable
    /// 요청이 거절됐다 (그 밖의 4xx). 아무것도 바뀌지 않았다
    case failed
    /// 보내지 않음: 이미 이 할 일의 요청이 진행 중 · 로그인 없음 · 조건(version)을 모름 · 고를 수 없는 범위
    case ignored
}

/// All work의 실제 범위(프로젝트) 멤버십 저장소 (S3b).
/// - 읽기는 RLS(`work_contexts` · `context_members`의 지금 멤버). 범위(version)를 먼저, 멤버를 나중에 읽는다: 그 사이 바뀌었으면 version이 더 낡게 남아 쓰기가 409로 안전하게 막힌다
/// - 쓰기는 서버 `/api/v2/contexts/…` 조건부 쓰기뿐이다. 조건 = 앱이 RLS로 읽은(또는 앞 200이 준) 그 범위의 `context_version`.
///   **성공은 200뿐**이다. 409 · 오류 · 응답 유실 뒤에는 같은 본문을 **자동으로 다시 보내지 않고** RLS로 다시 읽어 충돌 · 재확인으로 둔다
///   (새 멱등성 저장소가 없어 응답을 잃은 성공 요청의 재전송도 409다). 할 일마다 한 번에 하나
/// - Undo는 직전 200의 `change`(실제로 바뀐 것)의 역연산만, 그 `change`의 version을 조건으로 보낸다: 처음 A만 / A+B 모두 원래 있던 멤버십을 지우지 않는다.
///   맹목적 역이동(B → A)은 쓰지 않는다. 다른 기기가 그 범위를 바꿨다면 Undo도 409다. Undo는 한 단계다
/// - 멤버십은 권한이 아니다 (D13): 이 저장소가 서버에서 부르는 것은 읽기 둘과 `ContextGateway`의 쓰기 둘뿐이다. 실행 · 정책 · 승인 · run을 부르지 않고 할 일 필드를 바꾸지 않는다
/// - 계정 경계: `AccountScope`에 붙어 계정이 떠나면 모두 비우고 늦은 응답을 버린다 (화면이 떠 있는지와 무관). 새 영구 캐시는 없다: 모두 이 객체의 메모리
@MainActor
@Observable
public final class WorkContextStore {
    /// 한 할 일의 쓰기 안내 (화면이 이것만 보고 말한다)
    public enum Feedback: Equatable, Sendable {
        /// 다른 곳에서 바뀌었다 (지금 상태로 다시 읽었다)
        case conflict
        /// 서버가 처리했는지 모른다 (지금 상태로 다시 읽었다)
        case unconfirmed
        /// 그 범위가 보관됐거나 없다
        case contextGone
        /// 그 할 일이 없다
        case workGone
        /// 보내지 못했다 (한 줄)
        case failed(String)

        public var text: String {
            switch self {
            case .conflict: APIError.server(status: 409, code: .conflict, message: "").userMessage
            case .unconfirmed: WorkProjectCopy.unconfirmed
            case .contextGone: WorkProjectCopy.contextGone
            case .workGone: WorkProjectCopy.workGone
            case .failed(let message): message
            }
        }
    }

    /// 직전 200이 바꾼 것의 역연산 (Undo 한 단계)
    struct UndoPlan: Equatable {
        enum Step: Equatable {
            /// 방금 넣은 범위를 뺀다 (`added`만)
            case remove(context: UUID, version: Int)
            /// 방금 뺀 범위를 다시 넣는다 (`removed`만)
            case add(context: UUID, version: Int)
            /// `added`와 `removed` 둘 다: 넣은 범위(from)에서 빼고 뺀 범위(to)에 다시 넣는다
            case move(from: UUID, fromVersion: Int, to: UUID, toVersion: Int)
        }

        let step: Step
        let anchor: ProjectLinkRules.UndoAnchor
    }

    /// 읽은 범위 (보관된 것 포함)
    public private(set) var contexts: [UUID: WorkContext] = [:]
    /// 지금 멤버 중 할 일 멤버 (`removed_at` 없음): 확인된 멤버와 후보(inferred)
    public private(set) var members: [ContextMember] = []
    /// 읽기 상태: 읽는 중 · 받음(+그 뒤 문제) · 오프라인 · 실패. 받은 적이 있으면 실패해도 받은 것을 그대로 둔다
    public private(set) var load: WorkLoad = .loading
    /// 이번 세션에서 서버로부터 읽은 적이 있다 (읽은 적이 없으면 멤버십을 모른다: Ungrouped라고도 말하지 않는다)
    public private(set) var hasRead = false
    /// 서버 DB에 범위 테이블이 아직 없다 (마이그레이션 적용 전): 멤버십이 없는 것이지 실패가 아니다
    public private(set) var readsUnavailable = false
    /// 서버 gate가 꺼져 쓰기가 막혀 있다 (404 "없는 경로입니다."): 실패가 아니라 기능이 아직 없는 것이다
    public private(set) var writesUnavailable = false
    /// 요청이 진행 중인 할 일 (할 일마다 한 번에 하나)
    public private(set) var busy: Set<UUID> = []
    public private(set) var feedback: [UUID: Feedback] = [:]
    public private(set) var isOnline = true
    private var undo: [UUID: UndoPlan] = [:]
    /// busy를 잡은 쓰기의 번호 (할 일마다). 쓰기가 끝날 때 자기 것일 때만 풀어, 세션이 바뀐 뒤 새 요청의 busy를 옛 요청이 지우지 않게 한다
    private var writeOwner: [UUID: Int] = [:]
    private var writeCounter = 0

    @ObservationIgnored private let gateway: any ContextGateway
    @ObservationIgnored private let scope: AccountScope
    /// 읽기 순번: 읽기를 시작할 때 하나씩 올린다. **마지막에 시작한 읽기만** 반영한다 (늦게 끝난 옛 읽기가 새 상태를 되돌리지 않는다).
    /// 쓰기 200을 반영할 때도 올려 그 전에 시작한 읽기를 버린다
    @ObservationIgnored private var readSequence = 0

    public init(gateway: any ContextGateway, scope: AccountScope) {
        self.gateway = gateway
        self.scope = scope
        scope.onLeft { [weak self] in self?.reset() }
    }

    /// 계정이 떠남: 모두 비운다 (읽는 중 · 쓰는 중인 요청의 늦은 결과는 `scope.isCurrent`가 버린다)
    public func reset() {
        readSequence += 1
        contexts = [:]
        members = []
        load = .loading
        hasRead = false
        readsUnavailable = false
        writesUnavailable = false
        busy = []
        writeOwner = [:]
        feedback = [:]
        undo = [:]
    }

    public func pathChanged(online: Bool) {
        isOnline = online
    }

    // MARK: 보이는 것

    /// 할 일마다 멤버십을 찾는 색인. 아직 읽은 적이 없으면 `unknown` (묶음 주장 없음)
    public var index: WorkMembershipIndex {
        hasRead ? WorkMembershipIndex(contexts: Array(contexts.values), members: members) : .unknown
    }

    /// 받은 목록 위 Notice 하나가 될 문제 (읽는 중이면 nil). 읽은 적이 없어도 오프라인 · 실패면 그렇게 말한다
    public var problem: WorkLoad.Problem? {
        switch load {
        case .loading: nil
        case .offline: .offline
        case .failed: .failed
        case .loaded(let problem): problem
        }
    }

    /// 고를 수 있는 범위: active만 (보관된 범위는 서버가 404), 이름 순
    public var activeProjects: [WorkProject] {
        contexts.values.filter(\.isActive).sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
            .map { WorkProject(id: $0.id, name: $0.name) }
    }

    public func isBusy(_ actionID: UUID) -> Bool { busy.contains(actionID) }

    public func feedback(for actionID: UUID) -> Feedback? { feedback[actionID] }

    public func clearFeedback(for actionID: UUID) {
        feedback[actionID] = nil
    }

    public func canUndo(_ actionID: UUID) -> Bool { undo[actionID] != nil }

    /// 이 할 일의 ProjectLink 줄들 (`ProjectLinkRules.links`). 멤버십을 아직 읽지 못했으면 nil
    public func projectLinks(for actionID: UUID) -> [ProjectLinkContent]? {
        ProjectLinkRules.links(
            memberships: index.memberships(of: actionID), active: activeProjects, writesUnavailable: writesUnavailable,
            isBusy: busy.contains(actionID), undo: undo[actionID]?.anchor, message: feedback[actionID]?.text
        )
    }

    // MARK: 읽기

    /// 범위 · 멤버를 읽는다 (패널을 열 때 · 로그인 · Try again · 온라인으로 돌아왔을 때 · 쓰기 뒤 · 409/응답 유실 뒤).
    /// 받은 것이 있으면 실패해도 그대로 둔다. 마지막에 시작한 읽기만 반영한다
    public func refresh() async {
        guard let token = scope.token else { return }
        readSequence += 1
        let sequence = readSequence
        if !hasRead { load = .loading }
        do {
            // 범위(version)를 먼저, 멤버를 나중에: 그 사이 바뀌었으면 version이 더 낡아 쓰기가 409로 안전하게 막힌다
            let named = try await gateway.workContexts()
            let rows = try await gateway.contextMembers()
            guard scope.isCurrent(token), sequence == readSequence else { return }
            contexts = Dictionary(named.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            members = rows.filter { !$0.isRemoved && $0.actionID != nil }
            hasRead = true
            readsUnavailable = false
            load = .loaded(problem: nil)
        } catch {
            guard scope.isCurrent(token), sequence == readSequence, let failure = ReadFailure.from(error, online: isOnline) else { return }
            if failure == .unavailable {
                // 서버에 범위 테이블이 아직 없다: 실패가 아니라 멤버십이 없는 것이다
                contexts = [:]
                members = []
                hasRead = true
                readsUnavailable = true
                load = .loaded(problem: nil)
            } else if hasRead {
                load = .loaded(problem: failure == .offline ? .offline : .failed)
            } else {
                load = failure == .offline ? .offline : .failed
            }
        }
    }

    // MARK: 쓰기

    /// ProjectLink에서 고른 동작 하나를 보낸다 (`ProjectChange`)
    @discardableResult
    public func perform(_ change: ProjectChange, for actionID: UUID) async -> ProjectWriteResult {
        switch change {
        case .add(let context): await add(actionID, to: context)
        case .remove(let context): await remove(actionID, from: context)
        case .move(let from, let to): await move(actionID, from: from, to: to)
        }
    }

    /// 그 범위에 넣는다 (origin user). 후보(inferred)를 확인하는 것도 같은 요청이다
    @discardableResult
    public func add(_ actionID: UUID, to contextID: UUID) async -> ProjectWriteResult {
        await change(actionID, op: .add, context: contextID)
    }

    /// 그 범위에서 뺀다. 후보를 거절하는 것도 같은 요청이다 (뺀 표시가 남아 자동 규칙이 다시 넣지 못한다)
    @discardableResult
    public func remove(_ actionID: UUID, from contextID: UUID) async -> ProjectWriteResult {
        await change(actionID, op: .remove, context: contextID)
    }

    /// A에서 B로 바꾼다 (한 요청, 서버가 원자적으로). 전체 교체가 아니다: 그 할 일의 다른 범위 멤버십은 그대로
    @discardableResult
    public func move(_ actionID: UUID, from fromContextID: UUID, to toContextID: UUID) async -> ProjectWriteResult {
        guard fromContextID != toContextID,
              let from = contexts[fromContextID], from.isActive, let fromVersion = from.contextVersion,
              let to = contexts[toContextID], to.isActive, let toVersion = to.contextVersion else { return .ignored }
        return await write(actionID, clearsUndo: true) { gateway in
            .moved(try await gateway.moveContextMember(
                actionID: actionID, from: fromContextID, to: toContextID, expectedToVersion: toVersion, expectedFromVersion: fromVersion
            ))
        }
    }

    private func change(_ actionID: UUID, op: ContextMemberOp, context contextID: UUID) async -> ProjectWriteResult {
        guard let context = contexts[contextID], context.isActive, let version = context.contextVersion else { return .ignored }
        return await write(actionID, clearsUndo: true) { gateway in
            .changed(try await gateway.changeContextMember(contextID: contextID, op: op, actionID: actionID, expectedVersion: version))
        }
    }

    /// 직전 200이 실제로 바꾼 것만 되돌린다 (그 `change`의 version을 조건으로). 한 단계: 누르면 계획은 사라진다 (409여도 다시 보내지 않는다)
    @discardableResult
    public func undoLast(_ actionID: UUID) async -> ProjectWriteResult {
        guard let plan = undo[actionID], !busy.contains(actionID) else { return .ignored }
        return await write(actionID, clearsUndo: true, recordsUndo: false) { gateway in
            switch plan.step {
            case .remove(let context, let version):
                .changed(try await gateway.changeContextMember(contextID: context, op: .remove, actionID: actionID, expectedVersion: version))
            case .add(let context, let version):
                .changed(try await gateway.changeContextMember(contextID: context, op: .add, actionID: actionID, expectedVersion: version))
            case .move(let from, let fromVersion, let to, let toVersion):
                .moved(try await gateway.moveContextMember(
                    actionID: actionID, from: from, to: to, expectedToVersion: toVersion, expectedFromVersion: fromVersion
                ))
            }
        }
    }

    private enum Response {
        case changed(ContextMemberWriteResponse)
        case moved(ContextMemberMoveResponse)
    }

    private func write(
        _ actionID: UUID, clearsUndo: Bool, recordsUndo: Bool = true, _ send: (any ContextGateway) async throws -> Response
    ) async -> ProjectWriteResult {
        guard let token = scope.token, !busy.contains(actionID), !writesUnavailable else { return .ignored }
        busy.insert(actionID)
        writeCounter += 1
        let owner = writeCounter
        writeOwner[actionID] = owner
        feedback[actionID] = nil
        if clearsUndo { undo[actionID] = nil }
        // 세션이 바뀌면 `reset()`이 busy를 비우고 새 세션이 같은 할 일에 새 요청을 잡을 수 있다: 이 요청이 잡은 busy일 때만 푼다
        defer {
            if writeOwner[actionID] == owner {
                writeOwner[actionID] = nil
                busy.remove(actionID)
            }
        }
        do {
            let response = try await send(gateway)
            // 응답이 오는 사이 계정이 떠났다면 어떤 결과든 반영하지 않는다 (새 세션의 상태를 건드리지 않는다)
            guard scope.isCurrent(token) else { return .ignored }
            let canUndo = applied(response, actionID: actionID, recordsUndo: recordsUndo)
            // 서버 상태와 맞춘다 (방금 받은 행은 이 읽기가 이어받는다)
            await refresh()
            return scope.isCurrent(token) ? .applied(canUndo: canUndo) : .ignored
        } catch {
            guard scope.isCurrent(token) else { return .ignored }
            let result = await failed(error, actionID: actionID)
            return scope.isCurrent(token) ? result : .ignored
        }
    }

    /// 200: 서버가 돌려준 행과 version을 반영하고, 실제로 바뀐 것으로 Undo를 만든다. 그 전에 시작한 읽기는 버린다
    private func applied(_ response: Response, actionID: UUID, recordsUndo: Bool) -> Bool {
        readSequence += 1
        let change: ContextChange
        switch response {
        case .changed(let r):
            absorb(r.member, version: r.contextVersion)
            change = r.change
        case .moved(let r):
            absorb(r.member, version: r.contextVersion)
            absorb(r.fromMember, version: r.fromContextVersion)
            change = r.change
        }
        // Undo의 응답에는 다시 Undo를 걸지 않는다 (한 단계)
        guard recordsUndo, let plan = Self.undoPlan(for: change) else { return false }
        undo[actionID] = plan
        return true
    }

    /// 쓴 뒤의 행을 지금 멤버 목록에 반영하고 (뺀 행이면 목록에서 뺀다), 그 범위 version은 더 높은 쪽으로만 올린다
    private func absorb(_ member: ContextMember, version: Int) {
        members.removeAll { $0.id == member.id || ($0.contextID == member.contextID && $0.actionID == member.actionID) }
        if !member.isRemoved, member.actionID != nil { members.append(member) }
        if let context = contexts[member.contextID], (context.contextVersion ?? 0) < version {
            contexts[member.contextID] = WorkContext(id: context.id, name: context.name, status: context.status, contextVersion: version)
        }
    }

    /// 직전 `change`의 역연산: added만 → 그 범위 빼기, removed만 → 그 범위 넣기, 둘 다 → 옮기기(added → removed 범위로). 둘 다 비면 없음.
    /// Undo 버튼은 방금 확인된 범위(added)의 줄에 놓이고, 빼기만 했으면(그 줄이 사라졌다) 남은 첫 줄에 놓인다.
    /// 맹목적 역이동이 아니다: 이미 멤버였던 도착 범위는 `added`에 없으므로 Undo가 지우지 않는다
    static func undoPlan(for change: ContextChange) -> UndoPlan? {
        switch (change.added.first, change.removed.first) {
        case (let added?, let removed?):
            UndoPlan(
                step: .move(from: added.contextID, fromVersion: added.contextVersion, to: removed.contextID, toVersion: removed.contextVersion),
                anchor: .project(added.contextID)
            )
        case (let added?, nil):
            UndoPlan(step: .remove(context: added.contextID, version: added.contextVersion), anchor: .project(added.contextID))
        case (nil, let removed?):
            UndoPlan(step: .add(context: removed.contextID, version: removed.contextVersion), anchor: .unlinked)
        case (nil, nil):
            nil
        }
    }

    private func failed(_ error: Error, actionID: UUID) async -> ProjectWriteResult {
        if let api = error as? APIError {
            if api == .notSignedIn {
                // 요청을 보내지 못했다 (로그인 세션이 없음)
                feedback[actionID] = .failed(api.userMessage)
                return .failed
            }
            if api.isFeatureOff {
                writesUnavailable = true
                return .unavailable
            }
            if api.isConflict {
                // 성공으로 올리지 않는다: 내 요청이 이미 적용된 것인지 다른 기기가 먼저 바꾼 것인지 구별할 근거가 없다. 지금 상태를 읽어 보인다
                feedback[actionID] = .conflict
                await refresh()
                return .conflict
            }
            if api.isMissingContext {
                feedback[actionID] = .contextGone
                await refresh()
                return .unavailable
            }
            if api.isMissingAction {
                feedback[actionID] = .workGone
                await refresh()
                return .unavailable
            }
            if let status = api.status, (400..<500).contains(status) {
                // 서버가 요청을 거절했다 (아무것도 쓰지 않았다)
                feedback[actionID] = .failed(api.userMessage)
                return .failed
            }
        }
        if error is CancellationError {
            feedback[actionID] = .unconfirmed
            await refresh()
            return .unconfirmed
        }
        // 응답을 받지 못했다(전송 오류) · 서버 오류 · 읽지 못한 응답: 서버가 처리했을 수 있다. 자동으로 다시 보내지 않고 지금 상태를 읽어 보인다
        feedback[actionID] = .unconfirmed
        await refresh()
        return .unconfirmed
    }
}

/// ProjectLink 한 줄에서 사용자가 고른 동작 (서버 쓰기 하나에 대응한다)
public enum ProjectChange: Equatable, Sendable {
    case add(UUID)
    case remove(UUID)
    case move(from: UUID, to: UUID)

    /// 팝업에서 `choice`를 골랐다 (nil = 이 범위에서 빼기). 이미 그 값이거나 할 수 없는 선택이면 nil.
    /// - "No clear link" 줄(범위 없음)에서 범위를 고르면 넣기, 범위가 있는 줄에서 다른 범위를 고르면 바꾸기(한 요청), 빼기를 고르면 빼기
    public static func choosing(_ choice: UUID?, in link: ProjectLinkContent) -> ProjectChange? {
        guard link.basis != .candidate, !link.isArchived, choice != link.contextID else { return nil }
        switch (link.contextID, choice) {
        case (nil, let target?): return .add(target)
        case (let current?, nil): return .remove(current)
        case (let current?, let target?): return .move(from: current, to: target)
        case (nil, nil): return nil
        }
    }

    /// 후보 Confirm: 그 범위에 넣는다 (서버가 후보 행을 user로 승격한다)
    public static func confirming(_ link: ProjectLinkContent) -> ProjectChange? {
        link.basis == .candidate ? link.contextID.map(ProjectChange.add) : nil
    }

    /// 후보 Dismiss: 그 범위에서 뺀다 (뺀 표시가 남아 후보가 다시 보이지 않는다, 바뀐 멤버가 아니라 Undo는 없다)
    public static func dismissing(_ link: ProjectLinkContent) -> ProjectChange? {
        link.basis == .candidate ? link.contextID.map(ProjectChange.remove) : nil
    }
}
