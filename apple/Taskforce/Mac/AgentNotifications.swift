#if os(macOS)
import Foundation
import TaskforceKit
import UserNotifications

/// 로컬 알림 센터와 닿는 면 (OA D4b-m-1). 시험은 가짜로 바꾼다 — 실제 알림 센터에 보낸 알림 0
protocol AgentNotificationCenter: AnyObject, Sendable {
    func permission() async -> PushPermission.Status
    /// 아직 안 물었으면 시스템이 한 번 묻는다 (이미 있는 한 번 묻기 `PushCenter.requestIfNeeded`)
    func requestPermissionIfNeeded() async
    func add(_ plan: AgentNotificationPlan) async
    func remove(ids: [String]) async
}

/// 실제 시스템 알림 센터. 글은 `AgentNotificationPlan`이 정한다 (상태 + 열 곳뿐)
final class SystemAgentNotificationCenter: AgentNotificationCenter {
    func permission() async -> PushPermission.Status { await PushCenter.status() }

    func requestPermissionIfNeeded() async {
        await PushCenter.shared.requestIfNeeded(hasConnections: true)
    }

    func add(_ plan: AgentNotificationPlan) async {
        let content = UNMutableNotificationContent()
        content.title = plan.title
        content.body = plan.body
        content.userInfo = plan.userInfo
        // 같은 id는 센터가 덮어쓴다: 질문 version마다 한 번 (D4bm-60)
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: plan.id, content: content, trigger: nil))
    }

    func remove(ids: [String]) async {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}

/// 에이전트 질문 알림 (OA D4b-m-1, D4bm-60 · 61 · 62): 질문이 이 Mac의 세션에서 열리면 로컬 알림을 건다. 서버 알림(APNs)은 없다 — 같은 사용자의 Mac 여럿이 겹쳐 알리지 않는다.
/// - 글은 상태 + 열 곳뿐: 제목 = 에이전트 이름, 본문은 새 문구라 승인 전에는 비어 있다. 질문 글 · 이슈 제목 · 세션 이름 · 경로 0
/// - 그 카드가 지금 키 표면에 보이면 보내지 않는다. 권한이 허용돼 있지 않으면 조용히 보내지 않는다 (거절했거나 아직 안 물었다)
/// - 이 Mac에 묶인 에이전트 연결이 처음 보이면 시스템 권한을 한 번 묻는다 (질문 순간이 아니다: 질문 위에 시스템 창을 띄우지 않는다)
/// - bridge가 꺼져 있으면(`isEnabled`) 아무것도 하지 않는다. 방해 금지 · 조용한 시간은 시스템 Focus뿐이다 (D4bm-64)
@MainActor
final class AgentNotifications {
    private let center: any AgentNotificationCenter
    private let isEnabled: () -> Bool
    private let copy: () -> AgentQuestionUnapprovedCopy
    private var askedForPermission = false
    /// 건 알림 id (답 · 닫힘 · 해소되면 지운다)
    private(set) var posted: Set<String> = []
    /// 마지막으로 시험이 기다릴 수 있는 일
    private var work: [Task<Void, Never>] = []

    init(center: any AgentNotificationCenter, isEnabled: @escaping () -> Bool, copy: @escaping () -> AgentQuestionUnapprovedCopy = { AgentQuestionNewCopy.active }) {
        self.center = center
        self.isEnabled = isEnabled
        self.copy = copy
    }

    /// 새 질문이 이 Mac의 세션에서 열렸다
    func opened(_ opened: AgentQuestionOpened, isVisible: Bool) {
        guard isEnabled() else { return }
        let plan = AgentQuestionNotifications.plan(for: opened, copy: copy())
        track { [center] in
            let permission = await center.permission()
            guard AgentQuestionNotifications.shouldPost(permission: permission, isVisibleOnKeySurface: isVisible) else { return }
            await center.add(plan)
            self.posted.insert(plan.id)
        }
    }

    /// 질문이 바뀌었거나 답이 갔거나 닫혔다: 전달된 알림을 지운다
    func closed(_ keys: [AgentQuestionKey]) {
        let ids = keys.map(AgentQuestionNotifications.identifier(for:))
        guard !ids.isEmpty else { return }
        posted.subtract(ids)
        track { [center] in await center.remove(ids: ids) }
    }

    /// 세션 저장소가 새로 읽었다: 이 Mac에 묶인 연결이 처음 보이면 시스템 권한을 한 번 묻는다 (`PushPermission.shouldRequest` 규칙 그대로, 연결 = 이 Mac의 에이전트 연결)
    func sessionsSeen(_ items: [AgentSessionItem], thisMacBridgeID: UUID?, signedIn: Bool) {
        guard isEnabled(), !askedForPermission, items.contains(where: { AgentSessionRules.isOnThisMac($0, thisMacBridgeID: thisMacBridgeID) }) else { return }
        askedForPermission = true
        track { [center] in
            let status = await center.permission()
            guard AgentQuestionNotifications.shouldRequestPermission(status: status, signedIn: signedIn, hasThisMacConnection: true, isPresentingOther: false) else { return }
            await center.requestPermissionIfNeeded()
        }
    }

    private func track(_ body: @escaping @MainActor () async -> Void) {
        // 오래된 것은 이미 끝났다 (시험이 기다릴 최근 일만 쥔다)
        if work.count > 32 { work.removeFirst(16) }
        work.append(Task { await body() })
    }

    /// 걸어 둔 일이 모두 끝날 때까지 (시험)
    func settle() async {
        while let task = work.popLast() { await task.value }
    }
}
#endif
