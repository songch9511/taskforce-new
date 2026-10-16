import Foundation
import Observation

/// 미루어 부르기: 몇 초 뒤 `work`를 부르고, 돌려준 클로저로 취소한다. 앱은 셸의 `EdgeSchedule`을 넘기고 시험은 손으로 돌리는 것을 넣는다
public typealias TaskforceSchedule = @MainActor (_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void

/// 경로 충돌에 고른 답 하나의 단계. 보류 중에는 Undo할 수 있고, 보낸 뒤에는 할 수 없다
public enum TaskforceAnswerPhase: Sendable, Hashable {
    case holding
    case sending
}

public struct TaskforceAnswer: Sendable, Hashable {
    public let requestID: String
    public let keep: TaskforceConflictKeep
    public let phase: TaskforceAnswerPhase

    public init(requestID: String, keep: TaskforceConflictKeep, phase: TaskforceAnswerPhase) {
        self.requestID = requestID
        self.keep = keep
        self.phase = phase
    }
}

/// 보낸 해소 한 번의 결과. 성공은 서버 200 `resolved`뿐이다. 어느 결과든 **자동으로 다시 보내지 않고** 지금 상태를 다시 읽는다
public enum TaskforceResolveResult: Equatable, Sendable {
    /// 200 resolved
    case resolved
    /// 409 conflict (옛 version이거나 이미 해소됨: 쓰기 0) · 404 (없는 lease · 남의 lease · gate 꺼짐)
    case conflict
    /// 그 밖의 4xx: 서버가 거절했다 (아무것도 바뀌지 않았다)
    case rejected
    /// 응답을 받지 못했거나 서버 오류 · 읽지 못한 응답: 서버가 처리했는지 **모른다**. 성공을 말하지 않는다
    case unconfirmed
    /// 보내지 않음: 계정이 바뀌었거나 보류가 풀렸거나 그 요청이 바뀌었다
    case ignored
}

/// Taskforce 대화 저장소 (OA U3). 대화가 보일 요청의 원천 `GET /api/v2/review`를 읽고, 경로 충돌에 고른 답 하나를 2초 보류한 뒤 보낸다.
/// - **읽기**: 정해진 주기가 없다. 사용자가 화면을 열거나 바뀔 까닭이 있을 때만 부른다 (이 GET은 제안을 만들고 노출 표시를 한다: `TaskforceRequestEndpoints.swift`).
///   읽기 순번으로 **마지막에 시작한 읽기만** 반영한다 (늦게 끝난 옛 읽기가 새 상태를 되돌리지 못한다). 읽지 못하면 받은 응답은 두고 `readProblem`만 올린다.
/// - **경로 충돌**: 응답에는 글이 없다. 경로와 두 run의 세션은 RLS로 따로 읽는다. 상세를 못 읽은 충돌은 보이지 않는다 (지어내지 않는다).
/// - **답(해소)**: 되돌릴 수 없어서 고른 뒤 2초 보류(`holdSeconds`)한다: 그 안의 Undo는 쓰기 0이다. 보류 중 같은 요청에 다시 눌러도 하나뿐이다.
///   보낼 때 다시 본다: 같은 계정 · 보류가 살아 있음 · 응답에 그 요청이 같은 `version` · 같은 `conflict_version`으로 있음. 하나라도 어긋나면 쓰기 0이다 (보류 중 요청이 바뀌면 새 카드가 말한다).
///   409는 자동 재시도 없이 다시 읽는다. 이미 나간 요청은 취소하지 않는다 (서버가 받았는지 모르는 요청을 버리지 않는다).
/// - 계정 경계: `AccountScope`에 붙어 계정이 떠나면(로그아웃 · 다른 계정 · 같은 UUID 재로그인) 모두 비우고 보류를 거두며 늦은 응답을 버린다.
/// - 로그: 경로 · 세션 이름 · 질문 글을 남기지 않는다. 새 영구 캐시는 없다: 모두 이 객체의 메모리다.
@MainActor
@Observable
public final class TaskforceRequestStore {
    public static let holdSeconds: TimeInterval = 2
    /// 서버 `conflict_version`의 범위 (DB integer)
    public static let conflictVersionRange = 1...2_147_483_647

    /// 마지막으로 받은 응답 (이번 실행의 것). 없으면 아직 못 읽었다
    public private(set) var response: TaskforceReviewResponse?
    /// 마지막 읽기가 끊겼다 (응답이 있으면 응답은 그대로 둔다)
    public private(set) var readProblem: WorkLoad.Problem?
    /// 서버 gate가 꺼져 있다 (404): 이 서버는 아직 이 기능이 없다. 비어 있다고 말하지 않는다
    public private(set) var featureOff = false
    /// 읽은 경로 충돌 상세 (lease id)
    public private(set) var conflicts: [UUID: TaskforceConflictDetail] = [:]
    /// 충돌 상세를 일부 못 읽었다: 그 충돌은 보이지 않는다 (응답을 믿을 수 없다고 말한다)
    public private(set) var conflictDetailsMissing = false
    /// 새 응답의 충돌 상세를 아직 읽는 중이다 (읽는 중에는 그 충돌을 기다린다)
    public private(set) var conflictDetailsReading = false
    /// 요청마다 고른 답 (보류 중 · 보내는 중)
    public private(set) var answers: [String: TaskforceAnswer] = [:]
    /// 가장 최근 안내 한 줄 (409 · 확인 못 함). 어느 요청에 대한 것인지 들고 있어 그 요청이 사라졌어도 말할 수 있다
    public private(set) var notice: Notice?
    /// 응답이 반영될 때마다 오른다 (관찰하는 쪽이 "새로 읽었다"를 안다)
    public private(set) var readSerial = 0
    /// 지금 읽는 중인 읽기의 수 (마지막에 시작한 읽기만 반영되므로 겹친 읽기가 끝나기를 기다리는 시험이 쓴다)
    public private(set) var inflightReads = 0

    public struct Notice: Equatable, Sendable {
        public let id: String
        public let text: String
    }

    @ObservationIgnored private let gateway: any TaskforceRequestGateway
    @ObservationIgnored private let scope: AccountScope
    /// 보류에 쓰는 시계. 앱은 셸의 `EdgeSchedule`을 넘겨 시험이 손으로 돌린다
    @ObservationIgnored public var schedule: TaskforceSchedule
    @ObservationIgnored private var readSequence = 0
    @ObservationIgnored private var online = true
    @ObservationIgnored private var holds: [String: Hold] = [:]
    @ObservationIgnored private var holdCounter = 0
    /// 마지막으로 보낸 해소 (시험이 끝을 기다린다)
    @ObservationIgnored public private(set) var lastSend: Task<TaskforceResolveResult, Never>?

    private struct Hold {
        let owner: Int
        let token: AccountScope.Token
        let keep: TaskforceConflictKeep
        let leaseID: UUID
        let itemVersion: String
        let conflictVersion: Int
        let cancel: () -> Void
    }

    public init(gateway: any TaskforceRequestGateway, scope: AccountScope, schedule: @escaping TaskforceSchedule = TaskforceRequestStore.liveSchedule) {
        self.gateway = gateway
        self.scope = scope
        self.schedule = schedule
        scope.onLeft { [weak self] in self?.reset() }
    }

    /// 실제 시계
    public static let liveSchedule: TaskforceSchedule = { delay, work in
        let task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            if !Task.isCancelled { work() }
        }
        return { task.cancel() }
    }

    /// 계정이 떠남: 모두 비운다 (읽는 중 · 보내는 중인 요청의 늦은 결과는 `scope.isCurrent`가 버린다)
    public func reset() {
        readSequence += 1
        for hold in holds.values { hold.cancel() }
        holds = [:]
        answers = [:]
        notice = nil
        response = nil
        readProblem = nil
        featureOff = false
        conflicts = [:]
        conflictDetailsMissing = false
        conflictDetailsReading = false
        readSerial += 1
    }

    /// 연결 경로: 오프라인에서 돌아오면 이미 읽은 적이 있는 저장소는 다시 읽는다 (처음 읽기는 화면이 연다)
    public func pathChanged(online now: Bool) {
        let returned = now && !online
        online = now
        guard returned, response != nil || readProblem != nil else { return }
        Task { await refresh() }
    }

    // MARK: 읽기

    /// 지금 보이는 요청들 (순수 규칙 `TaskforceRequestRules.visible`). 응답이 없으면 비었다
    /// - confirmationsKnown · sessionsKnown: v1 `/now` 목록과 세션 저장소가 읽었나 (읽는 중이면 그 재료의 요청을 기다린다)
    public func visible(
        confirmable: Set<UUID>, knownSessions: Set<UUID>, confirmationsKnown: Bool = true, sessionsKnown: Bool = true
    ) -> TaskforceVisibleRequests {
        guard let response else { return .none }
        return TaskforceRequestRules.visible(
            response, confirmable: confirmable, conflicts: conflicts, knownSessions: knownSessions,
            readiness: TaskforceReadiness(confirmationsKnown: confirmationsKnown, sessionsKnown: sessionsKnown, conflictDetailsKnown: !conflictDetailsReading)
        )
    }

    /// 응답을 믿고 "No decisions waiting"이라고 말해도 되나 (결정 원천 ok · complete · 모르는 것을 건너뛰지 않음 · 충돌 상세를 모두 읽음)
    public func isTrustworthy(_ visible: TaskforceVisibleRequests) -> Bool {
        guard let response else { return false }
        return TaskforceRequestRules.isTrustworthy(response, skippedUnknown: visible.skippedUnknown) && !conflictDetailsMissing && !featureOff
    }

    /// 새로 읽는다 (로그인 · 패널 열기 · ⌘1 · ⌥Space · 벨 클릭 · 온라인 복귀 · 깸 · 확인 요청 id가 바뀔 때 · 세션 상태가 바뀔 때 · 내 답 · 해소 뒤)
    public func refresh() async {
        guard let token = scope.token else { return }
        readSequence += 1
        let sequence = readSequence
        inflightReads += 1
        defer { inflightReads -= 1 }
        let received: TaskforceReviewResponse
        do {
            received = try await gateway.taskforceReview()
        } catch {
            guard scope.isCurrent(token), sequence == readSequence, !(error is CancellationError) else { return }
            if let api = error as? APIError, api.isFeatureOff {
                featureOff = true
                readProblem = .failed
            } else {
                featureOff = false
                readProblem = Self.isOffline(error, online: online) ? .offline : .failed
            }
            readSerial += 1
            return
        }
        guard scope.isCurrent(token), sequence == readSequence else { return }
        response = received
        readProblem = nil
        featureOff = false
        reconcile()
        conflictDetailsReading = !TaskforceRequestRules.conflictRefs(received).isEmpty
        readSerial += 1
        await readConflictDetails(for: received, token: token, sequence: sequence)
    }

    /// 충돌의 경로 · 세션을 읽는다. 읽은 만큼 바꾸고, 못 읽었으면 전에 읽은 상세를 그대로 두되 응답을 믿을 수 없다고 표시한다
    private func readConflictDetails(for received: TaskforceReviewResponse, token: AccountScope.Token, sequence: Int) async {
        let refs = TaskforceRequestRules.conflictRefs(received)
        guard !refs.isEmpty else {
            conflicts = [:]
            conflictDetailsMissing = false
            conflictDetailsReading = false
            return
        }
        let details: [UUID: TaskforceConflictDetail]
        do {
            details = try await gateway.pathConflictDetails(refs)
        } catch {
            guard scope.isCurrent(token), sequence == readSequence, !(error is CancellationError) else { return }
            conflictDetailsMissing = true
            conflictDetailsReading = false
            readSerial += 1
            return
        }
        guard scope.isCurrent(token), sequence == readSequence else { return }
        conflicts = details
        conflictDetailsMissing = refs.contains { details[$0.leaseID] == nil }
        conflictDetailsReading = false
        readSerial += 1
    }

    nonisolated static func isOffline(_ error: Error, online: Bool) -> Bool {
        if case .transport? = error as? APIError { return !online }
        return error is URLError && !online
    }

    // MARK: 새 응답 맞추기

    /// 새 응답이 반영된 뒤: 사라졌거나 `version`이 바뀐 요청의 보류를 거두고 (쓰기 0, 새 카드가 말한다), 사라진 요청의 고른 답 기록을 지운다
    private func reconcile() {
        // 결정 원천을 읽지 못했으면 요청이 없는 것이 아니라 모르는 것이다: 보류를 거두지 않는다 (보낼 때 다시 본다)
        guard let response, response.decisionsOK else { return }
        let items = Dictionary(response.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, hold) in holds {
            guard let item = items[id], item.version == hold.itemVersion, item.conflict?.conflictVersion == hold.conflictVersion else {
                hold.cancel()
                holds[id] = nil
                answers[id] = nil
                continue
            }
        }
        // 이미 보낸 답은 응답이 그 요청을 빼면(해소됨) 기록도 지운다
        for (id, answer) in answers where answer.phase == .sending && items[id] == nil {
            answers[id] = nil
        }
    }

    // MARK: 답 (경로 충돌 해소)

    /// 고른 답 하나를 **받는다** (클릭 · 1/2 키, 동기 경계): 2초 보류를 시작한다. 이 요청이 응답에 경로 충돌로 있고, 보류 · 전송 중이 아니고, 로그인 세션이 있을 때만 true
    /// (두 번 눌러도 하나뿐이다: 반복 키 · 중복 클릭 · 다른 답으로 바꿔 누르기 모두 한 번만 통과한다)
    @discardableResult
    public func choose(_ keep: TaskforceConflictKeep, for requestID: String) -> Bool {
        guard let token = scope.token, answers[requestID] == nil,
              let item = response?.items.first(where: { $0.id == requestID && $0.kind == .pathConflict }), let conflict = item.conflict,
              Self.conflictVersionRange.contains(conflict.conflictVersion) else { return false }
        holdCounter += 1
        let owner = holdCounter
        let cancel = schedule(Self.holdSeconds) { [weak self] in self?.holdElapsed(requestID, owner: owner) }
        holds[requestID] = Hold(
            owner: owner, token: token, keep: keep, leaseID: conflict.leaseID, itemVersion: item.version, conflictVersion: conflict.conflictVersion, cancel: cancel
        )
        answers[requestID] = TaskforceAnswer(requestID: requestID, keep: keep, phase: .holding)
        notice = nil
        return true
    }

    /// Undo: 보류 안에서만 된다 (쓰기 0). 보낸 뒤에는 아무 일도 없다
    public func undo(_ requestID: String) {
        guard let answer = answers[requestID], answer.phase == .holding, let hold = holds[requestID] else { return }
        hold.cancel()
        holds[requestID] = nil
        answers[requestID] = nil
    }

    /// 2초가 지났다: 보낸다
    private func holdElapsed(_ requestID: String, owner: Int) {
        guard let hold = holds[requestID], hold.owner == owner else { return }
        lastSend = Task { await self.send(requestID, hold: hold) }
    }

    /// 보내기 직전에 다시 본다. 하나라도 어긋나면 쓰기 0 · `.ignored`다
    private func send(_ requestID: String, hold: Hold) async -> TaskforceResolveResult {
        defer { if holds[requestID]?.owner == hold.owner { holds[requestID] = nil } }
        guard scope.isCurrent(hold.token), holds[requestID]?.owner == hold.owner,
              let item = response?.items.first(where: { $0.id == requestID }), item.version == hold.itemVersion,
              item.conflict?.conflictVersion == hold.conflictVersion else {
            if holds[requestID]?.owner == hold.owner { answers[requestID] = nil }
            return .ignored
        }
        answers[requestID] = TaskforceAnswer(requestID: requestID, keep: hold.keep, phase: .sending)
        holds[requestID] = nil
        let result: TaskforceResolveResult
        do {
            let reply = try await gateway.resolvePathConflict(leaseID: hold.leaseID, keep: hold.keep, conflictVersion: hold.conflictVersion)
            guard scope.isCurrent(hold.token) else { return .ignored }
            result = reply.isResolved ? .resolved : .unconfirmed
        } catch {
            guard scope.isCurrent(hold.token) else { return .ignored }
            result = Self.failure(error)
            switch result {
            case .conflict: notice = Notice(id: requestID, text: ReviewCopy.conflict)
            case .rejected: notice = Notice(id: requestID, text: (error as? APIError)?.userMessage ?? ReviewCopy.unverified)
            default: notice = Notice(id: requestID, text: ReviewCopy.unverified)
            }
        }
        if result == .unconfirmed, notice == nil { notice = Notice(id: requestID, text: ReviewCopy.unverified) }
        if result != .resolved { answers[requestID] = nil }
        // 어느 결과든 자동으로 다시 보내지 않고 지금 상태를 다시 읽는다. 해소되었으면 그 요청이 빠진 응답이 기록도 지운다
        await refresh()
        guard scope.isCurrent(hold.token) else { return .ignored }
        answers[requestID] = nil
        return result
    }

    /// 해소가 던진 오류를 결과로
    nonisolated static func failure(_ error: Error) -> TaskforceResolveResult {
        guard let api = error as? APIError else { return .unconfirmed }
        if api.isConflict { return .conflict }
        if case .server(404, _, _) = api { return .conflict }
        if case .unexpectedStatus(404) = api { return .conflict }
        if let status = api.status, (400..<500).contains(status) { return .rejected }
        return .unconfirmed
    }

    /// 이 요청에 대한 안내 (요청이 사라졌어도 남는다: 사라졌다는 사실은 내 요청의 성공 증거가 아니다)
    public func notice(for requestID: String) -> String? {
        notice.flatMap { $0.id == requestID ? $0.text : nil }
    }

    public func clearNotice() { notice = nil }
}
