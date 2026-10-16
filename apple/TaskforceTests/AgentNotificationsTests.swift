import Foundation
import Testing
@testable import Taskforce
@testable import TaskforceKit

/// 시험이 닫아 두었다가 여는 문: 알림 센터의 느린 응답(권한 조회 · 게시)을 흉내 낸다
final class NotificationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var _arrivals = 0

    /// 문 앞에 온 호출 수
    var arrivals: Int { lock.withLock { _arrivals } }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                _arrivals += 1
                if !isOpen { waiters.append(continuation) }
                return isOpen
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        for waiter in pending { waiter.resume() }
    }
}

/// 가짜 알림 센터 (시험): 실제 알림 센터에 아무것도 보내지 않는다
final class FakeNotificationCenter: AgentNotificationCenter, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: PushPermission.Status = .allowed
    private var _added: [AgentNotificationPlan] = []
    private var _removed: [String] = []
    private var _requests = 0
    /// 센터에 걸려 있는 알림 id → 그 알림을 건 `add` 호출의 번호(1부터). 같은 id를 나중에 거는 호출이 덮어쓴다
    private var _delivered: [String: Int] = [:]
    private var _permissionGate: NotificationGate?
    private var _addGate: NotificationGate?

    var status: PushPermission.Status {
        get { lock.withLock { _status } }
        set { lock.withLock { _status = newValue } }
    }
    var added: [AgentNotificationPlan] { lock.withLock { _added } }
    var removed: [String] { lock.withLock { _removed } }
    var requests: Int { lock.withLock { _requests } }

    /// 센터에 지금 걸려 있는 알림 (`add`가 닿으면 들어가고 `remove`가 지운다)
    var delivered: Set<String> { lock.withLock { Set(_delivered.keys) } }
    /// 그 id의 알림을 건 `add` 호출의 번호 (옛 게시와 새 게시를 가린다)
    func deliveredFrom(_ id: String) -> Int? { lock.withLock { _delivered[id] } }
    /// 권한 조회를 문이 열릴 때까지 붙잡는다
    func holdPermission(_ gate: NotificationGate?) { lock.withLock { _permissionGate = gate } }
    /// 게시(`add`)를 문이 열릴 때까지 붙잡는다: 호출은 기록되지만 센터에는 아직 닿지 않았다
    func holdAdd(_ gate: NotificationGate?) { lock.withLock { _addGate = gate } }

    func permission() async -> PushPermission.Status {
        if let gate = lock.withLock({ _permissionGate }) { await gate.wait() }
        return status
    }
    func requestPermissionIfNeeded() async { lock.withLock { _requests += 1 } }
    func add(_ plan: AgentNotificationPlan) async {
        let (number, gate) = lock.withLock { () -> (Int, NotificationGate?) in
            _added.append(plan)
            return (_added.count, _addGate)
        }
        if let gate { await gate.wait() }
        lock.withLock { _delivered[plan.id] = number }
    }
    func remove(ids: [String]) async {
        lock.withLock {
            _removed.append(contentsOf: ids)
            for id in ids { _delivered[id] = nil }
        }
    }
}

/// 에이전트 질문 알림 (OA D4b-m-1, D4bm-60 · 61 · 62 · 63): 이 Mac의 로컬 알림. 글은 상태 + 열 곳뿐이다 (카나리로 확인). 시스템 알림 센터는 가짜다
@MainActor
struct AgentNotificationsTests {
    typealias Data = AgentChatSampleData
    typealias Q = QuestionSampleData

    static let canary = "DO_NOT_STORE_SECRET_D4BM"
    private let key = AgentQuestionKey(taskID: Q.task, requestID: Q.request)

    private func opened() -> AgentQuestionOpened {
        AgentQuestionOpened(key: key, sessionID: Data.sessionID, agentName: "Claude Code")
    }

    private func make(_ center: FakeNotificationCenter, enabled: Bool = true) -> AgentNotifications {
        AgentNotifications(center: center, isEnabled: { enabled }, copy: { .approved })
    }

    @Test func aNewQuestionPostsOneStatusOnlyNotificationWithTheAgentNameAsTitle() async {
        let center = FakeNotificationCenter()
        let notifications = make(center)
        notifications.opened(opened(), isVisible: false)
        await notifications.settle()
        #expect(center.added.count == 1)
        let plan = center.added[0]
        #expect(plan.title == "Claude Code" && plan.id == AgentQuestionNotifications.identifier(for: key))
        #expect(plan.userInfo["kind"] == "agent_question" && plan.userInfo["session_id"] == Data.sessionID.uuidString.lowercased())
        #expect(notifications.posted == [plan.id])
    }

    @Test func nothingFromTheQuestionTheSessionOrThePathIsInTheNotificationText() async throws {
        let account = try AppChatAccount.make()
        let center = FakeNotificationCenter()
        let gateway = AgentChatSampleGateway()
        let ticker = QuestionTicker()
        let hostile = Q.pending([Q.Prompt(text: "Edit \(Self.canary)/secret.txt", header: Self.canary, options: [Self.canary, "B"], descriptions: [Self.canary, Self.canary])], request: "req-\(Self.canary)")
        var state = Q.world(hostile)
        state.agentName = "Claude Code"
        gateway.state = state
        let runtime = ChatRuntime(
            gateway: gateway, contextGateway: IssueSampleContextGateway(), scope: account.scope, now: { Date() }, issueScreens: true, agentQuestions: true,
            notificationCenter: center, questionSleep: { await ticker.sleep($0) }, notificationsEnabled: { true }
        )
        runtime.questions?.thisMacBridgeID = Data.thisMacBridge
        runtime.questions?.sessionsRead([QFxItem.make()])
        await runtime.questions?.settle()
        await runtime.notifications?.settle()
        let plan = try #require(center.added.first)
        let everything = ([plan.id, plan.title, plan.body] + plan.userInfo.flatMap { [$0.key, $0.value] }).joined(separator: "|")
        #expect(!everything.contains(Self.canary), "질문 글 · 선택지 · 설명 · 요청 id가 알림에 실리지 않는다")
        #expect(!everything.contains("Pricing copy draft") && !everything.contains("pricing.mdx") && !everything.contains("Which price"), "세션 이름 · 이슈 제목 · 경로 0")
    }

    @Test func thePreviewCandidateBodyIsNeedsYourAnswerOnlyInTheDebugSampleCopy() async {
        let center = FakeNotificationCenter()
        let notifications = AgentNotifications(center: center, isEnabled: { true }, copy: { AgentQuestionUnapprovedCopy(questionNotificationBody: "Needs your answer") })
        notifications.opened(opened(), isVisible: false)
        await notifications.settle()
        #expect(center.added.first?.body == "Needs your answer")
        let approved = FakeNotificationCenter()
        let plain = make(approved)
        plain.opened(opened(), isVisible: false)
        await plain.settle()
        #expect(approved.added.first?.body == "", "승인 전에는 본문이 없다")
    }

    @Test func itPostsNothingWhenTheBridgeIsOffTheCardIsVisibleOrPermissionIsNotAllowed() async {
        let off = FakeNotificationCenter()
        let disabled = make(off, enabled: false)
        disabled.opened(opened(), isVisible: false)
        await disabled.settle()
        #expect(off.added.isEmpty && off.requests == 0, "bridge가 꺼져 있으면 아무것도 하지 않는다")
        let visibleCenter = FakeNotificationCenter()
        let visible = make(visibleCenter)
        visible.opened(opened(), isVisible: true)
        await visible.settle()
        #expect(visibleCenter.added.isEmpty, "그 카드가 지금 키 표면에 보이면 보내지 않는다")
        for status in [PushPermission.Status.denied, .notDetermined] {
            let center = FakeNotificationCenter()
            center.status = status
            let n = make(center)
            n.opened(opened(), isVisible: false)
            await n.settle()
            #expect(center.added.isEmpty && center.requests == 0, "\(status): 조용히 — 질문 순간에 시스템 창을 띄우지 않는다")
        }
    }

    @Test func answeringOrClosingRemovesTheDeliveredNotification() async {
        let center = FakeNotificationCenter()
        let notifications = make(center)
        notifications.opened(opened(), isVisible: false)
        await notifications.settle()
        notifications.closed([key])
        await notifications.settle()
        #expect(center.removed == [AgentQuestionNotifications.identifier(for: key)] && notifications.posted.isEmpty)
        notifications.closed([])
        await notifications.settle()
        #expect(center.removed.count == 1)
    }

    @Test func theSystemPermissionIsAskedOnceAfterTheFirstConnectionOnThisMacNotWhenAQuestionOpens() async {
        let center = FakeNotificationCenter()
        center.status = .notDetermined
        let notifications = make(center)
        let thisMac = QFxItem.make()
        notifications.sessionsSeen([thisMac], thisMacBridgeID: Data.thisMacBridge, signedIn: true)
        await notifications.settle()
        #expect(center.requests == 1)
        notifications.sessionsSeen([thisMac], thisMacBridgeID: Data.thisMacBridge, signedIn: true)
        await notifications.settle()
        #expect(center.requests == 1, "한 번만 묻는다")
        // 다른 Mac의 연결만 있으면 묻지 않는다
        let other = FakeNotificationCenter()
        other.status = .notDetermined
        let n = make(other)
        n.sessionsSeen([thisMac], thisMacBridgeID: Data.otherMacBridge, signedIn: true)
        n.sessionsSeen([thisMac], thisMacBridgeID: nil, signedIn: true)
        await n.settle()
        #expect(other.requests == 0)
        // 이미 허용 · 거절했거나 로그인 전이면 묻지 않는다
        for (status, signedIn) in [(PushPermission.Status.allowed, true), (.denied, true), (.notDetermined, false)] {
            let c = FakeNotificationCenter()
            c.status = status
            let m = make(c)
            m.sessionsSeen([thisMac], thisMacBridgeID: Data.thisMacBridge, signedIn: signedIn)
            await m.settle()
            #expect(c.requests == 0, "\(status) \(signedIn)")
        }
    }

    @Test func aQuestionOnAnotherMacIsNeverPostedFromThisOne() async throws {
        let account = try AppChatAccount.make()
        let center = FakeNotificationCenter()
        let gateway = AgentChatSampleGateway()
        gateway.state = Q.world(Q.single, bridge: Data.otherMacBridge)
        let runtime = ChatRuntime(
            gateway: gateway, contextGateway: IssueSampleContextGateway(), scope: account.scope, now: { Date() }, issueScreens: true, agentQuestions: true,
            notificationCenter: center, notificationsEnabled: { true }
        )
        runtime.questions?.thisMacBridgeID = Data.thisMacBridge
        runtime.questions?.sessionsRead([QFxItem.make(bridge: Data.otherMacBridge)])
        await runtime.questions?.settle()
        await runtime.notifications?.settle()
        #expect(runtime.questions?.entry(session: Data.sessionID) != nil && center.added.isEmpty, "같은 사용자의 Mac 여럿이 겹쳐 알리지 않는다")
    }

    @Test func eachNewQuestionVersionPostsOnceAndARereadOfTheSameOneDoesNot() async throws {
        let account = try AppChatAccount.make()
        let center = FakeNotificationCenter()
        let gateway = AgentChatSampleGateway()
        gateway.state = Q.world(Q.single)
        let runtime = ChatRuntime(
            gateway: gateway, contextGateway: IssueSampleContextGateway(), scope: account.scope, now: { Date() }, issueScreens: true, agentQuestions: true,
            notificationCenter: center, notificationsEnabled: { true }
        )
        runtime.questions?.thisMacBridgeID = Data.thisMacBridge
        for _ in 0..<3 {
            runtime.questions?.sessionsRead([QFxItem.make()])
            await runtime.questions?.settle()
            await runtime.notifications?.settle()
        }
        #expect(center.added.count == 1, "version마다 한 번")
        gateway.update { $0.questions = [Q.record(Q.pending([Q.Prompt()], request: "second"))] }
        runtime.questions?.sessionsRead([QFxItem.make()])
        await runtime.questions?.settle()
        await runtime.notifications?.settle()
        #expect(center.added.count == 2 && center.removed.contains(AgentQuestionNotifications.identifier(for: key)), "새 질문은 새 알림, 앞 알림은 지운다")
    }

    // MARK: 검토 1: 늦게 끝난 권한 조회 · 게시가 닫힌 질문의 알림을 남기지 않는다

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test func aQuestionClosedWhileThePermissionIsLookedUpIsNeverPosted() async {
        let center = FakeNotificationCenter()
        let gate = NotificationGate()
        center.holdPermission(gate)
        let notifications = make(center)
        notifications.opened(opened(), isVisible: false)
        #expect(await eventually { gate.arrivals == 1 }, "권한 조회가 느리다")
        notifications.closed([key])
        gate.open()
        await notifications.settle()
        #expect(center.added.isEmpty && center.delivered.isEmpty && notifications.posted.isEmpty, "조회가 끝나기 전에 질문이 닫혔다: 알림을 걸지 않는다")
    }

    @Test func aPostThatLandsAfterTheQuestionClosedIsRemoved() async {
        let center = FakeNotificationCenter()
        let gate = NotificationGate()
        center.holdAdd(gate)
        let notifications = make(center)
        notifications.opened(opened(), isVisible: false)
        #expect(await eventually { gate.arrivals == 1 }, "게시가 시작됐지만 센터에 아직 닿지 않았다")
        notifications.closed([key])
        // 알림 센터 일은 한 줄이다: 닫힘의 삭제는 진행 중인 게시가 끝난 뒤에 선다 (센터에 아직 없는 알림을 지우려 하지 않는다)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(center.removed.isEmpty, "진행 중인 게시 뒤에 선다")
        gate.open()
        await notifications.settle()
        #expect(center.delivered.isEmpty && notifications.posted.isEmpty, "늦게 닿은 알림도 지운다")
    }

    @Test func leavingTheAccountWhileTheFirstConnectionPermissionIsLookedUpAsksNothing() async {
        let center = FakeNotificationCenter()
        center.status = .notDetermined
        let gate = NotificationGate()
        center.holdPermission(gate)
        let notifications = make(center)
        notifications.sessionsSeen([QFxItem.make()], thisMacBridgeID: Data.thisMacBridge, signedIn: true)
        #expect(await eventually { gate.arrivals == 1 }, "시스템 권한 조회가 느리다")
        notifications.accountLeft()
        gate.open()
        await notifications.settle()
        #expect(center.requests == 0, "계정이 떠난 뒤 늦게 끝난 조회가 시스템 권한 창을 띄우지 않는다")
    }

    @Test func leavingTheAccountRemovesTheDeliveredNotificationsAndEndsTheirLifetimes() async {
        let center = FakeNotificationCenter()
        let notifications = make(center)
        notifications.opened(opened(), isVisible: false)
        await notifications.settle()
        #expect(center.delivered.count == 1)
        notifications.accountLeft()
        await notifications.settle()
        #expect(center.delivered.isEmpty && notifications.posted.isEmpty)
    }

    @Test func leavingTheAccountWhileThePermissionIsLookedUpPostsNothing() async throws {
        let account = try AppChatAccount.make()
        let center = FakeNotificationCenter()
        let gate = NotificationGate()
        center.holdPermission(gate)
        let gateway = AgentChatSampleGateway()
        gateway.state = Q.world(Q.single)
        let runtime = ChatRuntime(
            gateway: gateway, contextGateway: IssueSampleContextGateway(), scope: account.scope, now: { Date() }, issueScreens: true, agentQuestions: true,
            notificationCenter: center, notificationsEnabled: { true }
        )
        let store = try #require(runtime.questions)
        store.thisMacBridgeID = Data.thisMacBridge
        store.sessionsRead([QFxItem.make()])
        await store.settle()
        #expect(await eventually { gate.arrivals == 1 }, "새 질문의 알림이 권한 조회에서 기다린다")
        account.scope.accountLeft()
        gate.open()
        await runtime.notifications?.settle()
        #expect(center.added.isEmpty && center.delivered.isEmpty, "계정이 떠난 뒤 늦게 끝난 조회가 알림을 걸지 않는다")
    }

    // MARK: 재검토 1: 알림 센터 일은 한 줄로, 수명마다 따로 (이전 수명의 끝이 새 수명의 알림 · 권한 요청을 건드리지 않는다)

    @Test func anOldPostFinishingAfterAReLoginNeverDeletesTheNewNotificationOfTheSameQuestion() async {
        let center = FakeNotificationCenter()
        let gate = NotificationGate()
        center.holdAdd(gate)
        let notifications = make(center)
        let id = AgentQuestionNotifications.identifier(for: key)
        notifications.opened(opened(), isVisible: false)
        #expect(await eventually { gate.arrivals == 1 }, "이전 게시가 느리다")
        notifications.accountLeft()                      // 로그아웃
        center.holdAdd(nil)
        notifications.opened(opened(), isVisible: false) // 같은 계정으로 다시 로그인 → 같은 질문이 다시 열린다
        // 이전 게시가 아직 멈춰 있는 동안 새 게시가 끝날 틈을 준다 (알림 센터 일이 한 줄이면 새 게시는 이전 게시 뒤에 서서 기다린다)
        try? await Task.sleep(for: .milliseconds(150))
        gate.open()
        await notifications.settle()
        #expect(center.deliveredFrom(id) == 2, "남은 알림은 새 수명이 건 것이다 (이전 게시의 정리가 공용 id의 새 알림을 지우지 않는다)")
        #expect(notifications.posted == [id])
    }

    @Test func leavingDuringTheFirstPermissionLookupThenSigningInAgainAsksThePermission() async {
        let center = FakeNotificationCenter()
        center.status = .notDetermined
        let gate = NotificationGate()
        center.holdPermission(gate)
        let notifications = make(center)
        let item = QFxItem.make()
        notifications.sessionsSeen([item], thisMacBridgeID: Data.thisMacBridge, signedIn: true)
        #expect(await eventually { gate.arrivals == 1 }, "첫 권한 조회가 느리다")
        notifications.accountLeft()
        notifications.sessionsSeen([item], thisMacBridgeID: Data.thisMacBridge, signedIn: true)   // 재로그인 뒤 연결을 다시 읽었다
        gate.open()
        await notifications.settle()
        #expect(center.requests == 1, "무효가 된 조회는 묻지 않고, 재로그인 뒤의 조회가 한 번 묻는다")
        notifications.sessionsSeen([item], thisMacBridgeID: Data.thisMacBridge, signedIn: true)
        await notifications.settle()
        #expect(center.requests == 1, "물은 뒤에는 다시 묻지 않는다")
    }

    @Test func aPermissionLookupBeforeSigningInDoesNotUseUpTheOneAsk() async {
        let center = FakeNotificationCenter()
        center.status = .notDetermined
        let notifications = make(center)
        let item = QFxItem.make()
        notifications.sessionsSeen([item], thisMacBridgeID: Data.thisMacBridge, signedIn: false)
        await notifications.settle()
        #expect(center.requests == 0, "로그인 전에는 묻지 않는다")
        notifications.sessionsSeen([item], thisMacBridgeID: Data.thisMacBridge, signedIn: true)
        await notifications.settle()
        #expect(center.requests == 1, "로그인한 뒤에 한 번 묻는다 (조회만 한 시도가 그 한 번을 쓰지 않는다)")
    }

    @Test func aSlowLookupDoesNotStartASecondLookupForTheSameAttempt() async {
        let center = FakeNotificationCenter()
        center.status = .notDetermined
        let gate = NotificationGate()
        center.holdPermission(gate)
        let notifications = make(center)
        let item = QFxItem.make()
        for _ in 0..<3 { notifications.sessionsSeen([item], thisMacBridgeID: Data.thisMacBridge, signedIn: true) }
        #expect(await eventually { gate.arrivals == 1 })
        gate.open()
        await notifications.settle()
        #expect(gate.arrivals == 1 && center.requests == 1, "조회 중인 동안 다시 읽어도 조회 · 요청은 하나다")
    }
}

extension QFxItem {
    static func make(bridge: UUID?) -> AgentSessionItem {
        let base = make()
        return AgentSessionItem(
            id: base.id, name: base.name, agent: base.agent, agentName: base.agentName, connectionID: base.connectionID, status: base.status, ring: base.ring, line: base.line,
            createdAt: base.createdAt, updatedAt: base.updatedAt, issueIDs: base.issueIDs, currentIssueID: base.currentIssueID, conversationID: base.conversationID,
            hasOpenTask: base.hasOpenTask, pill: base.pill, connectionBridgeID: bridge, lastTaskState: base.lastTaskState, cancelRequested: base.cancelRequested, turnSeq: base.turnSeq
        )
    }
}
