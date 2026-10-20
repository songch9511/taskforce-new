#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

// Settings › Account › Plan & usage · Execution › Spending outside Taskforce (OA 결제 PR-C, 디자인 SSOT `PlanSummary` · `ExternalCosts` + 승인된 DZ 그림).
// 무엇을 그릴지는 Kit의 `PlanSummaryState`(순수 규칙)가 정하고, 상태 · 동작은 `PlanSummaryStore`가 맡는다. 두 창(0.2.0 창 · Release 옛 창 `MacSettingsView`)이 같은 규칙 · 같은 문구를 쓴다.
// 결제 화면은 그리지 않는다: checkout · 포털 · 결제 수단은 브라우저(Lemon Squeezy)로 연다. 가격 · 날짜 · 토큰은 서버 값이고 이 앱에 가격 숫자 상수는 없다.

/// Plan & usage 화면 둘이 같이 쓰는 생애: 계정이 정해지면 읽고 (계정이 바뀌면 값을 비우고 늦은 응답을 버린다), 앱이 다시 활성화되면(브라우저에서 돌아옴) 다시 읽고, 설정을 다시 열면 읽는다.
/// 주소는 환경의 `openURL`로 연다 (시험은 기록하는 가짜를 넣는다: 실제 브라우저 0).
/// - `currentAccount`: 지금 로그인한 계정을 세션에서 읽는 길. 저장소가 요청이 끝날 때마다(주소를 열기 직전 포함) 계정이 그대로인지 본다 — 화면이 `follow`를 부르지 못하고 사라져도(로그아웃 · 계정 전환) 이전 계정의 결제 주소를 열지 않는다.
/// - `invalidatesOnDisappear`: 화면이 사라지면 저장소를 무효화한다 (화면마다 저장소를 갖는 Release 옛 창 · Usage & Credits). 탭을 옮겨도 남아야 하는 0.2.0 창의 저장소는 끄고, 계정이 떠나는 것으로만 무효화한다.
/// - 들어올 때마다(`beginVisit`) 그 화면 흐름에만 속한 표시("Refund issued" · 요청함 표시 · 환불 확인 줄)를 지운다: 같은 계정이 돌아와도 서버가 허용한 구매 줄이 가려지지 않는다
struct PlanSummaryLifecycle: ViewModifier {
    let store: PlanSummaryStore
    let userID: UUID?
    let gateway: (any PlanSummaryGateway)?
    var currentAccount: (@MainActor () -> UUID?)?
    var invalidatesOnDisappear = false
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content
            .task(id: userID) {
                store.opener = { url in openURL(url) }
                store.follow(userID: userID, gateway: gateway, currentAccount: currentAccount)
                store.beginVisit()
                await store.refresh()
            }
            .onDisappear {
                if invalidatesOnDisappear { store.invalidate() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await store.appDidBecomeActive() }
            }
            // 창 밖에서 다시 열면(메뉴 · 런처 · 알림) 새로 들어온 것이다: 흐름 표시를 지우고 새로 읽는다. 설정 창은 닫아도 남아 `task`가 다시 돌지 않는다
            .onChange(of: SettingsRoute.shared.openCount) {
                store.beginVisit()
                Task { await store.refresh() }
            }
    }
}

/// 세션에서 지금 로그인한 계정을 읽는 길 (견본은 견본 계정). 세션이 사라졌으면 계정이 없다
@MainActor
enum PlanAccount {
    static func current(_ session: SessionStore?) -> @MainActor () -> UUID? {
        { [weak session] in session.flatMap { SettingsWindowSession.accountUserID($0) } }
    }
}

/// Plan & usage가 부르는 서버 길. 실제는 `AppServices.api`다. 견본(`-TFSampleData`)은 가짜 길을 쓴다 (서버 · Lemon Squeezy · OpenRouter에 닿지 않는다)
@MainActor
enum PlanGateways {
    static func current(_ services: AppServices?) -> (any PlanSummaryGateway)? {
        #if DEBUG
        if SettingsWindowSession.isSample { return PlanSnapshotHook.gateway ?? SamplePlanGateway.standard }
        #endif
        return services?.api
    }
}

/// 0.2.0 창의 Plan & usage 알맹이: 규칙이 정한 값을 DS 부품으로 그리고, 동작을 저장소로 보낸다.
/// 시험은 가짜 길 · 가짜 계정으로 이것을 바로 붙인다
struct SettingsPlanBody: View {
    let store: PlanSummaryStore
    let userID: UUID?
    let gateway: (any PlanSummaryGateway)?
    var currentAccount: (@MainActor () -> UUID?)?
    @State private var keyHandle = SecureFieldSmHandle()

    var body: some View {
        PlanSummaryView(
            state: store.state, keyHandle: keyHandle,
            onAction: { action in Task { await store.perform(action) } },
            onSubmitKey: { key in Task { await store.saveKey(key) } }
        )
        .modifier(PlanSummaryLifecycle(store: store, userID: userID, gateway: gateway, currentAccount: currentAccount))
    }
}

/// Account › Plan & usage (DS SettingsPage 순서: Profile · Sign-in · Plan & usage · Remembered · Delete)
struct SettingsPlanSection: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.services) private var services

    var body: some View {
        SettingsPlanBody(
            store: SettingsWindowModel.shared.plan, userID: SettingsWindowSession.accountUserID(session), gateway: PlanGateways.current(services),
            currentAccount: PlanAccount.current(session)
        )
    }
}
#endif
