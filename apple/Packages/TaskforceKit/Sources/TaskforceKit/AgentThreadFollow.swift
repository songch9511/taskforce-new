import Foundation

/// 에이전트 대화의 글 따라 읽기 (Claude Code 첫 실사용: 승인 세 번 뒤 마지막 답이 Mac 대화에 나오지 않았다).
///
/// 에이전트의 글(답 · 질문 · 사건 줄)은 bridge가 서버에 쓰고, 앱은 `conversation_messages`를 RLS로 읽는다. 이 표는 Realtime 발행 대상이 아니고(`actions` · `bridge_commands`만이다),
/// 대화 글은 대화를 열 때 · 질문에 답했을 때 · 목록을 읽을 때만 다시 읽었다. 그래서 답이 서버에 있어도 화면은 모르는 채였다.
/// 세션 읽기(`AgentSessionReadPolicy`: 열린 task가 있으면 5초마다)가 이미 돌고 있으므로, 그 읽기에서 **새 일**이 보였을 때만 같이 읽는다 (비용을 지키는 규칙, 검토 P2 · P3):
/// - 새 일 = 세션 표식(`Mark`)이 앞섰다: 턴 번호, 같은 턴이면 마지막 반영 사건 순서(`agent_tasks.last_event_seq`), 순서가 같으면 task 상태 · 세션 상태 · 갱신 시각이 달라졌다.
///   열린 task여도 새 일이 없으면 읽지 않는다. 낡은 읽기(다른 저장소의 늦은 응답)는 새 일이 아니다.
/// - 처음 보는 세션: 열린 task가 있거나 그 세션의 `updatedAt`이 대화 글을 마지막으로 읽은 때보다 나중이면 한 번 읽는다 (앱이 안 보던 사이에 턴이 끝났다). 아니면 기준만 적는다.
/// - 같은 대화는 ~4초 안에 한 번으로 합친다. 읽는 중에 온 새 일은 그 읽기가 끝난 뒤 한 번 더 (지금 읽는 글에는 없을 수 있다). 전달 표시는 다시 읽지 않는다.
/// - 표식은 읽기가 **성공한 뒤에만** 적는다. 실패하면 4초 뒤 한 번 다시 읽고, 그것도 실패하면 표식을 적지 않는다 (다음 세션 읽기가 같은 새 일을 다시 본다).
/// - 표식은 세션 저장소가 둘이어도 하나를 함께 쓴다 (한 읽기에 없는 세션의 표식도 지우지 않는다): 같은 새 일을 두 번 읽지 않는다.
///
/// 순서 보장: 서버는 글(`message`)을 먼저 쓰고 그 뒤에 `turn_completed`가 task를 idle로 바꾼다(두 사건, 따로 반영). bridge가 사건을 순서대로 보내므로
/// 앱이 task의 끝(idle)을 본 읽기에서는 마지막 글이 이미 있다
public enum AgentThreadFollow {
    /// 세션을 마지막으로 본 값
    public struct Mark: Equatable, Sendable {
        public var turnSeq: Int
        public var state: AgentTaskState?
        public var status: AgentSessionStatus
        public var updatedAt: Date
        public var lastEventSeq: Int?

        init(_ item: AgentSessionItem) {
            turnSeq = item.turnSeq
            state = item.lastTaskState
            status = item.status
            updatedAt = item.updatedAt
            lastEventSeq = item.lastEventSeq
        }

        /// `old`보다 새 일이 담겼나 (낡은 읽기는 false)
        func advances(past old: Mark) -> Bool {
            if turnSeq != old.turnSeq { return turnSeq > old.turnSeq }
            if let new = lastEventSeq, let before = old.lastEventSeq, new != before { return new > before }
            return self != old && updatedAt >= old.updatedAt
        }
    }

    public struct Plan: Equatable, Sendable {
        /// 글을 다시 읽을 세션 → 읽기가 성공하면 적을 표식
        public var reread: [UUID: Mark]
        /// 읽지 않고 기준만 적는 세션 (처음 보는 쉬는 세션)
        public var baseline: [UUID: Mark]
    }

    /// - marks: 지금까지 적었거나 이미 읽기를 요청한 표식
    /// - loadedAt: 그 세션의 보이는 대화 글을 마지막으로 읽은 때 (보이지 않으면 nil)
    public static func plan(items: [AgentSessionItem], marks: [UUID: Mark], loadedAt: (UUID) -> Date?) -> Plan {
        var plan = Plan(reread: [:], baseline: [:])
        for item in items {
            let mark = Mark(item)
            if let old = marks[item.id] {
                if mark.advances(past: old) { plan.reread[item.id] = mark }
            } else if item.hasOpenTask || loadedAt(item.id).map({ item.updatedAt > $0 }) == true {
                plan.reread[item.id] = mark
            } else {
                plan.baseline[item.id] = mark
            }
        }
        return plan
    }

    /// 읽기 요청 하나: 어느 세션의 어떤 표식을 읽기가 성공하면 적을지 · 몇 번째 시도인지
    struct Request: Equatable {
        var session: UUID
        var mark: Mark
        var attempts: Int
    }

    /// `ChatStore`가 쥐는 상태 (메모리뿐, 계정이 떠나면 비운다)
    struct State {
        /// 같은 대화는 이 시간 안에 한 번 (초). 시험이 바꾼다
        var window: TimeInterval = 4
        /// 읽기가 실패한 뒤 다시 읽기까지 (초)
        var retryDelay: TimeInterval = 4
        /// 읽기가 성공한 뒤에 적은 표식 (세션별)
        var marks: [UUID: Mark] = [:]
        /// 읽기를 요청했지만 아직 적지 않은 표식 (같은 새 일을 두 번 요청하지 않게 비교에 쓴다)
        var pending: [UUID: Mark] = [:]
        /// 대화별 글을 마지막으로 읽은 때
        var threadLoadedAt: [UUID: Date] = [:]
        /// 따라 읽기가 도는 대화
        var inFlight: Set<UUID> = []
        /// 대화별 마지막 따라 읽기를 시작한 때 (4초 안에 한 번)
        var startedAt: [UUID: Date] = [:]
        /// 다음 읽기에 실려 갈 요청
        var waiting: [UUID: [Request]] = [:]
        /// 4초 창이 끝나기를 / 재시도를 기다리는 예약 (대화별 하나)
        var timers: [UUID: Task<Void, Never>] = [:]

        mutating func cancelAll() {
            for timer in timers.values { timer.cancel() }
            timers = [:]
        }

        /// 이미 적었거나 요청한 표식 중 앞선 것
        func effectiveMarks() -> [UUID: Mark] {
            var merged = marks
            for (session, mark) in pending where merged[session].map({ mark.advances(past: $0) }) ?? true { merged[session] = mark }
            return merged
        }
    }
}

extension ChatStore {
    /// 세션 읽기가 반영됐다 (`AgentSessionStore.onApplied`): 새 일이 보인 세션의 **보이는** 에이전트 대화 글을 읽는다.
    /// 보이지 않는 대화는 읽지 않고 표식도 적지 않는다 (보일 때 열면서 읽는다)
    public func agentSessionsRead(_ items: [AgentSessionItem]) {
        let shown = shownAgentConversations()
        func conversations(of session: UUID) -> [UUID] { shown.filter { agentSessionID(for: $0) == session } }
        let plan = AgentThreadFollow.plan(
            items: items, marks: follow.effectiveMarks(), loadedAt: { session in conversations(of: session).compactMap { self.follow.threadLoadedAt[$0] }.min() }
        )
        for (session, mark) in plan.baseline { follow.marks[session] = mark }
        for (session, mark) in plan.reread {
            let targets = conversations(of: session)
            guard !targets.isEmpty else { continue }
            follow.pending[session] = mark
            for id in targets { requestFollow(AgentThreadFollow.Request(session: session, mark: mark, attempts: 0), in: id) }
        }
    }

    private func requestFollow(_ request: AgentThreadFollow.Request, in id: UUID) {
        follow.waiting[id, default: []].append(request)
        scheduleOrStartFollow(id, retry: false)
    }

    /// 읽는 중이거나 예약이 있으면 기다리고, 4초 창이 지났으면 지금 읽고, 아니면 남은 시간 뒤로 예약한다
    private func scheduleOrStartFollow(_ id: UUID, retry: Bool) {
        guard !follow.inFlight.contains(id), follow.timers[id] == nil, !(follow.waiting[id] ?? []).isEmpty else { return }
        let remaining = follow.window - now().timeIntervalSince(follow.startedAt[id] ?? .distantPast)
        let delay = retry ? max(follow.retryDelay, remaining) : remaining
        if delay <= 0 {
            startFollow(id)
            return
        }
        let sleep = sleep
        follow.timers[id] = Task { [weak self] in
            await sleep(delay)
            guard !Task.isCancelled, let self else { return }
            self.follow.timers[id] = nil
            self.startFollow(id)
        }
    }

    private func startFollow(_ id: UUID) {
        let batch = follow.waiting[id] ?? []
        follow.waiting[id] = nil
        guard !batch.isEmpty else { return }
        follow.inFlight.insert(id)
        follow.startedAt[id] = now()
        spawn { [self] in
            let result = await readThread(id, refreshesDeliveries: false)
            follow.inFlight.remove(id)
            finishFollow(id, batch: batch, result: result)
        }
    }

    private func finishFollow(_ id: UUID, batch: [AgentThreadFollow.Request], result: ThreadRead) {
        var retry = false
        switch result {
        case .applied:
            for request in batch { commit(request) }
        case .dropped:
            for request in batch { release(request) }
        case .failed, .superseded:
            // 한 번 늦춰 다시 읽는다. 그것도 못 읽었으면 표식을 적지 않고 놓는다 (다음 세션 읽기가 같은 새 일을 다시 본다)
            for request in batch {
                if request.attempts == 0 {
                    follow.waiting[id, default: []].append(AgentThreadFollow.Request(session: request.session, mark: request.mark, attempts: 1))
                    retry = true
                } else {
                    release(request)
                }
            }
        }
        // 읽는 중에 들어온 요청은 4초 창을 지켜 이어 읽는다
        scheduleOrStartFollow(id, retry: retry)
    }

    /// 읽기가 성공했다: 표식을 적는다 (뒤로 가지 않게 앞선 것만)
    private func commit(_ request: AgentThreadFollow.Request) {
        if follow.marks[request.session].map({ request.mark.advances(past: $0) }) ?? true { follow.marks[request.session] = request.mark }
        release(request)
    }

    /// 요청한 표식을 비교에서 뺀다 (적지 않았다면 다음 세션 읽기가 같은 새 일을 다시 본다)
    private func release(_ request: AgentThreadFollow.Request) {
        if follow.pending[request.session] == request.mark { follow.pending[request.session] = nil }
    }
}
