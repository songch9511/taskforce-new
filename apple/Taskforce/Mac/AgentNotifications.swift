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
///
/// **알림 센터를 만지는 모든 일(권한 조회 · 권한 요청 · 게시 · 삭제)은 한 줄(`enqueue`)로 차례대로 한다.** 앞 일이 끝나야 다음 일이 시작한다:
/// 이전 수명의 느린 게시가 새 수명의 알림과 같은 id를 두고 겹치지 못한다. 일마다 자기 수명(계정 epoch + 질문 열쇠에서 온 id + 이번 열림의 표)을 기억하고,
/// 끝난 뒤 그 수명이 아직 현재일 때만 결과를 반영한다. 삭제는 그 수명이 건 것에만 닿는다 (닫힘 · 계정 전환이 건 알림의 id를 모아 지우고, 이후 수명의 일은 그 뒤 줄에 선다)
@MainActor
final class AgentNotifications {
    /// 한 질문 알림의 수명: 계정 epoch + 이번 열림의 표 (id는 task + 요청 id에서 온다)
    private struct Lifetime: Equatable {
        let epoch: Int
        let token: UUID
    }

    private let center: any AgentNotificationCenter
    private let isEnabled: () -> Bool
    private let copy: () -> AgentQuestionUnapprovedCopy
    /// 시스템 권한을 실제로 물었거나 이미 정해져 있어 더 물을 일이 없다
    private var permissionResolved = false
    /// 지금 조회 · 요청 중인 시도 (계정이 떠나면 무효가 된다: 끝나도 반영하지 않고, 재로그인 뒤 다시 시도한다)
    private var permissionAttempt: UUID?
    /// 열려 있는 알림 수명 (id → 수명): 게시 전 · 중 · 후 모두. 닫히면(답 · 해소 · 계정 전환) 사라진다
    private var live: [String: Lifetime] = [:]
    /// 센터에 걸어 둔 알림 id → 그것을 건 수명
    private var postedBy: [String: Lifetime] = [:]
    /// 계정이 떠날 때마다 오른다
    private var accountEpoch = 0
    /// 알림 센터 일의 줄: 맨 뒤 일 (새 일은 이 일이 끝난 뒤 시작한다)
    private var tail: Task<Void, Never>?

    init(center: any AgentNotificationCenter, isEnabled: @escaping () -> Bool, copy: @escaping () -> AgentQuestionUnapprovedCopy = { AgentQuestionNewCopy.active }) {
        self.center = center
        self.isEnabled = isEnabled
        self.copy = copy
    }

    /// 걸어 둔 알림 id (답 · 닫힘 · 해소되면 지운다)
    var posted: Set<String> { Set(postedBy.keys) }

    /// 새 질문이 이 Mac의 세션에서 열렸다
    func opened(_ opened: AgentQuestionOpened, isVisible: Bool) {
        guard isEnabled() else { return }
        let plan = AgentQuestionNotifications.plan(for: opened, copy: copy())
        let life = Lifetime(epoch: accountEpoch, token: UUID())
        live[plan.id] = life
        enqueue { [center] in
            let permission = await center.permission()
            // 권한을 묻는 사이에 질문이 닫혔다(또는 계정이 떠났다): 걸지 않는다
            guard self.isCurrent(plan.id, life),
                  AgentQuestionNotifications.shouldPost(permission: permission, isVisibleOnKeySurface: isVisible) else { return }
            await center.add(plan)
            if self.isCurrent(plan.id, life) {
                self.postedBy[plan.id] = life
            } else {
                // 게시가 끝나기 전에 닫혔다. 줄이 한 줄이라 이 알림은 이 수명의 것뿐이다(뒤 수명의 일은 아직 시작하지 않았다): 늦게 닿은 알림을 지운다
                await center.remove(ids: [plan.id])
            }
        }
    }

    /// 질문이 바뀌었거나 답이 갔거나 닫혔다: 전달된 알림을 지운다
    func closed(_ keys: [AgentQuestionKey]) {
        let ids = keys.map(AgentQuestionNotifications.identifier(for:))
        guard !ids.isEmpty else { return }
        for id in ids {
            live[id] = nil
            postedBy[id] = nil
        }
        removeLater(ids)
    }

    /// 계정이 떠났다: 그 계정의 알림 수명을 모두 끝낸다. 걸려 있거나 걸리는 중인 알림을 지우고(줄에서 진행 중인 게시가 끝난 뒤),
    /// 느린 권한 조회 · 게시가 끝나도 아무것도 반영하지 않으며, 권한 시도는 무효가 되어 재로그인 뒤 다시 한다
    func accountLeft() {
        let ids = Set(live.keys).union(postedBy.keys)
        accountEpoch += 1
        live = [:]
        postedBy = [:]
        permissionAttempt = nil
        if !ids.isEmpty { removeLater(Array(ids)) }
    }

    /// 세션 저장소가 새로 읽었다: 이 Mac에 묶인 연결이 처음 보이면 시스템 권한을 한 번 묻는다 (`PushPermission.shouldRequest` 규칙 그대로, 연결 = 이 Mac의 에이전트 연결).
    /// 조회 중인 상태와 실제로 물은 상태를 나눈다: 계정이 떠나 무효가 된 시도 · 로그인 전의 조회는 그 한 번을 쓰지 않는다
    func sessionsSeen(_ items: [AgentSessionItem], thisMacBridgeID: UUID?, signedIn: Bool) {
        guard isEnabled(), !permissionResolved, permissionAttempt == nil, items.contains(where: { AgentSessionRules.isOnThisMac($0, thisMacBridgeID: thisMacBridgeID) }) else { return }
        let attempt = UUID()
        permissionAttempt = attempt
        enqueue { [center] in
            let status = await center.permission()
            guard self.permissionAttempt == attempt else { return }   // 계정이 떠나 무효가 됐다: 쓰지 않았고, 재로그인 뒤 다시 한다
            guard AgentQuestionNotifications.shouldRequestPermission(status: status, signedIn: signedIn, hasThisMacConnection: true, isPresentingOther: false) else {
                // 이미 허용 · 거절로 정해졌으면 끝, 로그인 전이면 다음에 다시 한다
                if status != .notDetermined { self.permissionResolved = true }
                self.permissionAttempt = nil
                return
            }
            await center.requestPermissionIfNeeded()
            // 시스템에 실제로 물었다 (그 사이 계정이 떠났어도 시스템 쪽은 이제 정해졌다)
            self.permissionResolved = true
            if self.permissionAttempt == attempt { self.permissionAttempt = nil }
        }
    }

    // MARK: 알림 센터 일의 줄

    /// 일을 줄 맨 뒤에 세운다: 앞 일이 끝나야 시작한다
    private func enqueue(_ body: @escaping @MainActor () async -> Void) {
        let previous = tail
        tail = Task {
            await previous?.value
            await body()
        }
    }

    private func removeLater(_ ids: [String]) {
        enqueue { [center] in await center.remove(ids: ids) }
    }

    private func isCurrent(_ id: String, _ life: Lifetime) -> Bool {
        life.epoch == accountEpoch && live[id] == life
    }

    /// 걸어 둔 일이 모두 끝날 때까지 (시험)
    func settle() async {
        var last: Task<Void, Never>?
        while let current = tail, current != last {
            last = current
            await current.value
        }
    }
}
#endif
