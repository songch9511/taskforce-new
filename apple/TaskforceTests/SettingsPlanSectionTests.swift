import AppKit
import Observation
import SwiftUI
import Testing
@testable import TaskforceKit
import TaskforceUI
@testable import Taskforce

/// Plan & usage · Spending outside Taskforce가 어디에 보이나 (OA 결제 PR-C 9.1 · 16.4): 탭 순서 · 숨김 목록 · Release 옛 창 · 문구 · 소스 모양
@MainActor
struct SettingsPlanStructureTests {
    @Test func accountShowsPlanAndUsageBetweenSignInAndRemembered() {
        #expect(SettingsWindowTab.account.sections(.signedIn) == [.profile, .signIn, .planAndUsage, .remembered, .deleteAccount, .about, .legal], "DS SettingsPage 순서")
        for access in [SettingsWindowAccess.signedOut, .loading] {
            #expect(SettingsWindowTab.account.sections(access) == [.signIn, .about, .legal], "로그인하지 않았으면 플랜 절은 없다")
        }
    }

    @Test func executionShowsSpendingOutsideTaskforceAfterRunWithAI() {
        #expect(SettingsWindowTab.execution.sections(.signedIn) == [.runWithAI, .externalCosts])
        #expect(SettingsWindowTab.execution.sections(.signedOut) == [.signInRequired])
    }

    @Test func theSectionsAreTitledLikeTheDesignSystem() {
        #expect(SettingsWindowSection.planAndUsage.title == "Plan & usage" && SettingsWindowSection.externalCosts.title == "Spending outside Taskforce")
    }

    @Test func planAndUsageAndSpendingOutsideLeftTheHiddenListButTheOldConceptsStay() {
        let hidden = Set(SettingsWindowHidden.allCases.map(\.rawValue))
        #expect(!hidden.contains("Plan & usage") && !hidden.contains("Spending outside Taskforce"))
        #expect(hidden.isSuperset(of: ["Usage & Credits", "Subscription", "Default for new work", "Delivery", "Task List"]))
        #expect(SettingsWindowHidden.usageAndCredits.tab == .account && SettingsWindowHidden.subscription.tab == .account)
        #expect(SettingsWindowHidden.allCases.allSatisfy { !$0.reason.isEmpty && !$0.reason.contains("$9.99") })
        for tab in SettingsWindowTab.allCases {
            for access in [SettingsWindowAccess.signedIn, .signedOut, .loading] {
                #expect(Set(tab.sections(access).compactMap(\.title)).isDisjoint(with: hidden), "\(tab) \(access)")
            }
        }
    }

    @Test func theOldUsageAndCreditsPageStillOpensTheAccountTabWherePlanAndUsageLives() {
        #expect(SettingsWindowTab.tab(stored: MacSettingsTab.usage.rawValue) == .account)
    }

    @Test func releaseKeepsTheLegacyWindowSoThePlanSectionThereIsTheOldFormOne() {
        #expect(MacSettingsRootKind(surfaces: .release) == .legacy)
        #expect(EdgeSurfaces.release.settingsWindow == false)
        // 옛 창이 쓰는 Plan & usage 절이 있다 (Release가 L5까지 옛 창이라 여기서 팔고 키를 받는다)
        #expect(String(describing: MacBillingSection.self) == "MacBillingSection")
    }

    @Test func aChangeOfTheShownAccountInvalidatesThePreviousAccountsPlanStore() async {
        let window = SettingsWindowModel()
        let me = UUID()
        window.plan.follow(userID: me, gateway: PlanHostGateway(status: PlanHostFixtures.status(.pro, plan: .monthly, refund: true)))
        await window.plan.refresh()
        window.accountChanged(to: me)
        #expect(window.plan.owner == me && window.plan.status != nil, "같은 계정이면 그대로")
        window.accountChanged(to: UUID())
        #expect(window.plan.owner == nil && window.plan.status == nil, "다른 계정이 되면 비운다")
        window.plan.follow(userID: me, gateway: PlanHostGateway(status: PlanHostFixtures.status(.pro, plan: .monthly)))
        window.accountChanged(to: nil)
        #expect(window.plan.owner == nil, "로그아웃도 비운다")
    }

    @Test func theAccountLeavingClearsThePlanStateFromMemory() async {
        let window = SettingsWindowModel()
        let gateway = PlanHostGateway(status: PlanHostFixtures.status(.pro, plan: .monthly, refund: true))
        window.plan.follow(userID: UUID(), gateway: gateway)
        await window.plan.refresh()
        #expect(window.plan.status != nil)
        window.plan.follow(userID: nil, gateway: nil)
        #expect(window.plan.status == nil && window.plan.owner == nil)
    }
}

/// 소스 모양: 두 창의 소스에 옛 $9.99 문구 · 가격 숫자 상수 · 저장 길이 없다 (Mac 소스에 가격 숫자 상수 0, 계약 16.4)
struct SettingsPlanSourceTests {
    private static var macDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../Taskforce/Mac").standardized
    }

    /// Debug 전용 견본 파일을 뺀 화면 소스 (견본에는 가짜 값이 있다: Release 바이너리에 없다)
    private static let files = ["MacSettingsView.swift", "UsageCreditsPane.swift", "SettingsWindow/SettingsPlanSections.swift", "SettingsWindow/SettingsWindowModel.swift", "SettingsWindow/SettingsWindowView.swift"]

    private func code(_ name: String) throws -> String {
        let source = try String(contentsOf: Self.macDirectory.appending(path: name), encoding: .utf8)
        return source.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
    }

    @Test func theRemovedDollarNineCopyIsNotInTheScreens() throws {
        let removed = [
            "Subscribe monthly", "Subscribe yearly", "$9.99", "$101.90", "Payment starts immediately", "Plans include $3", "7-day trial starts with your first source sync",
            "7-day free trial", "AI allowance remaining", "Total trial allowance", "Cumulative beta allowance", "Plan limits", "Subscription terms", "Billing privacy",
            "Refresh subscription", "I agree to the subscription terms",
        ]
        for name in Self.files {
            let text = try code(name)
            for old in removed { #expect(!text.contains(old), "\(name)에 \(old)") }
        }
    }

    @Test func noScreenHasAPriceOrDateConstant() throws {
        for name in Self.files {
            let text = try code(name)
            let literals = text.matches(of: /"(?:[^"\\]|\\.)*"/).map { String($0.0) }
                .map { $0.replacingOccurrences(of: #"\\\([^)]*\)"#, with: "", options: .regularExpression) }.joined(separator: "\n")
            #expect(literals.range(of: #"\$\d"#, options: .regularExpression) == nil, "\(name)에 달러 숫자 상수")
            for price in ["12.99", "6.99", "119.88", "229"] { #expect(!literals.contains(price), "\(name)에 \(price)") }
        }
    }

    @Test func theUsagePaneNoLongerAsksForTheUsdAllowance() throws {
        let text = try code("UsageCreditsPane.swift")
        #expect(!text.contains("aiBudget") && !text.contains("AiSpendSummary") && !text.contains("allowanceFraction") && !text.contains("resetDescription"))
        #expect(text.contains("Your plan") && text.contains("PlanSummaryStore"))
    }

    @Test func theKeyFlowHasNoPersistenceOrLoggingPath() throws {
        for name in ["SettingsWindow/SettingsPlanSections.swift"] {
            let text = try code(name)
            for forbidden in ["UserDefaults", "AppStorage", "Keychain", "SecItem", "print(", "NSLog", "os_log", "Logger(", "debugPrint", "dump("] {
                #expect(!text.contains(forbidden), "\(name)에 \(forbidden)")
            }
        }
        // 옛 창의 키 줄은 같은 부품 · 같은 길 (MacSettingsView 안 Plan 줄 구역)
        let legacy = try code("MacSettingsView.swift")
        let planPart = String(legacy[legacy.range(of: "struct MacBillingSection: View")!.lowerBound...])
        for forbidden in ["UserDefaults", "Keychain", "SecItem", "print(", "NSLog", "os_log", "Logger(", "dump("] {
            #expect(!planPart.contains(forbidden), "MacBillingSection에 \(forbidden)")
        }
    }

    /// 승인 규칙: 확인 행은 Cancel이 먼저다 (옛 창도 같다): 자리 · 처음 포커스. ↩로는 아무것도 확인되지 않는다 (기본 동작 버튼 없음)
    @Test func theLegacyConfirmRowPutsCancelFirstAndGivesItTheFirstFocus() throws {
        let text = try code("MacSettingsView.swift")
        let start = try #require(text.range(of: "struct LegacyPlanConfirm: View"))
        let block = String(text[start.lowerBound...].prefix(2_400))
        let cancel = try #require(block.range(of: "PlanCopy.cancel"))
        let confirm = try #require(block.range(of: "confirm.confirmTitle"))
        #expect(cancel.lowerBound < confirm.lowerBound, "Cancel 버튼이 확인 버튼보다 앞에 있다")
        #expect(block.contains("defaultFocus") && block.contains("cancelFocused"), "Cancel이 처음 포커스를 받는다")
        #expect(!block.contains("defaultAction"), "↩ 기본 동작 버튼 없음")
    }

    @Test func theSampleGatewayIsOnlyReachableFromDebugCode() throws {
        let text = try String(contentsOf: Self.macDirectory.appending(path: "SettingsWindow/SettingsPlanSections.swift"), encoding: .utf8)
        // 견본 길은 `#if DEBUG` 안에서만 쓰인다 (Release 바이너리에 SamplePlanGateway · PlanSnapshotHook가 없다)
        let range = try #require(text.range(of: "#if DEBUG"))
        let beforeDebug = text[..<range.lowerBound]
        #expect(!beforeDebug.contains("SamplePlanGateway") && !beforeDebug.contains("PlanSnapshotHook"))
        let snapshot = try String(contentsOf: Self.macDirectory.appending(path: "SettingsSnapshotPlan.swift"), encoding: .utf8)
        #expect(snapshot.hasPrefix("#if os(macOS) && DEBUG"))
    }
}

/// 실제로 그려진 모습: 오프스크린 창에 붙여 본다 (실제 포인터 · 키보드 · VoiceOver 확인이 아니다). 읽기 · 다시 활성화 · 계정 전환 · 주소 열기를 가짜 서버로 본다
@MainActor
@Suite(.serialized)
struct SettingsPlanRenderedTests {
    @Observable
    final class AccountBox {
        var userID: UUID?
        init(_ userID: UUID?) { self.userID = userID }
    }

    private func mount<V: View>(_ view: V, width: CGFloat, opened: PlanOpenedURLs) async -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width + 40, height: 1600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view
            .frame(width: width)
            .environment(\.openURL, OpenURLAction { url in
                opened.record(url)
                return .handled
            }))
        window.contentView = host
        window.alphaValue = 0
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    private func waitUntil(_ what: String, timeout: Duration = .seconds(30), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { Issue.record("조건을 기다리다 시간이 지났다: \(what)"); return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private let user = UUID(uuidString: "a1111111-1111-4111-8111-111111111111")!
    private let other = UUID(uuidString: "b2222222-2222-4222-8222-222222222222")!

    // MARK: 0.2.0 창

    @Test func theWindowSectionReadsOnceWhenItAppearsAndDrawsTheRulesOutput() async {
        let gateway = PlanHostGateway(status: PlanHostFixtures.status(.pro, plan: .monthly, refund: true))
        let store = PlanSummaryStore()
        let opened = PlanOpenedURLs()
        let (window, host) = await mount(SettingsPlanBody(store: store, userID: user, gateway: gateway), width: 520, opened: opened)
        defer { window.orderOut(nil) }
        await waitUntil("첫 읽기") { store.status != nil }
        #expect(gateway.statusCalls == 1 && store.owner == user)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width <= 520.5 && host.fittingSize.height > 150)
        #expect(store.state.row("plan")?.control == .value("Pro · Monthly · $12.99 a month", bold: false))
    }

    @Test func becomingActiveReadsAgain() async {
        let gateway = PlanHostGateway(status: PlanHostFixtures.status(.none, checkout: true, lifetime: true))
        let store = PlanSummaryStore()
        let (window, _) = await mount(SettingsPlanBody(store: store, userID: user, gateway: gateway), width: 520, opened: PlanOpenedURLs())
        defer { window.orderOut(nil) }
        await waitUntil("첫 읽기") { gateway.statusCalls == 1 }
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await waitUntil("다시 활성화돼 한 번 더 읽음") { gateway.statusCalls == 2 }
        #expect(gateway.statusCalls == 2)
    }

    @Test func aPressOnTheDrawnStateReachesTheServerOnceAndTheAddressOpensThroughOpenURL() async {
        let gateway = PlanHostGateway(status: PlanHostFixtures.status(.none, checkout: true, lifetime: true))
        let store = PlanSummaryStore()
        let opened = PlanOpenedURLs()
        let (window, _) = await mount(SettingsPlanBody(store: store, userID: user, gateway: gateway), width: 520, opened: opened)
        defer { window.orderOut(nil) }
        await waitUntil("첫 읽기") { store.status != nil }
        // 그려진 줄의 버튼이 가진 동작: Start 3-day free trial
        guard case .button(let button)? = store.state.row("pro")?.control else { Issue.record("Pro 줄 버튼이 있어야 한다"); return }
        #expect(button.title == "Start 3-day free trial")
        await store.perform(button.action)
        #expect(gateway.calls.filter { $0.hasPrefix("checkout") } == ["checkout:pro:terms-host-test"], "버튼 → API 호출 1")
        #expect(opened.urls == [URL(string: "https://acme.lemonsqueezy.com/checkout/buy/test")!], "↗ 열기는 openURL로 한 번")
    }

    @Test func theManageRowAndTheNoticeButtonOpenThePortalTheSameWay() async {
        let gateway = PlanHostGateway(status: PlanHostFixtures.status(.pastDue, plan: .monthly))
        let store = PlanSummaryStore()
        let opened = PlanOpenedURLs()
        let (window, _) = await mount(SettingsPlanBody(store: store, userID: user, gateway: gateway), width: 520, opened: opened)
        defer { window.orderOut(nil) }
        await waitUntil("첫 읽기") { store.status != nil }
        guard let action = store.state.notice?.button?.action else { Issue.record("Payment failed Notice의 버튼이 있어야 한다"); return }
        #expect(action == .portal(.payment))
        await store.perform(action)
        #expect(gateway.calls.contains("portal:payment") && opened.urls.count == 1)
    }

    @Test func aLateAnswerForTheAccountThatLeftIsDiscardedAndTheNewAccountReadsItsOwn() async {
        let box = AccountBox(user)
        let gateway = PlanHostGateway([.success(PlanHostFixtures.status(.pro, plan: .monthly)), .success(PlanHostFixtures.status(.lifetime, key: .connected))])
        let gate = gateway.hold("status")
        let store = PlanSummaryStore()
        struct Host: View {
            let box: AccountBox
            let store: PlanSummaryStore
            let gateway: PlanHostGateway
            var body: some View { SettingsPlanBody(store: store, userID: box.userID, gateway: gateway) }
        }
        let (window, _) = await mount(Host(box: box, store: store, gateway: gateway), width: 520, opened: PlanOpenedURLs())
        defer { window.orderOut(nil) }
        await waitUntil("첫 읽기가 서버 앞에 도착") { gate.arrived }
        box.userID = other
        await waitUntil("새 계정으로 다시 읽기 시작") { store.owner == other }
        #expect(store.status?.state != .pro, "전 계정의 값이 새 계정 화면에 없다")
        gate.open()
        await waitUntil("새 계정의 읽기") { store.status != nil }
        // 붙잡혔던 전 계정의 응답이 늦게 풀려도 새 계정의 값을 덮지 않는다 (잠시 지켜본다)
        for _ in 0..<20 {
            #expect(store.status?.state == .lifetime)
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(gateway.statusCalls == 2)
        box.userID = nil
        await waitUntil("로그아웃은 비운다") { store.owner == nil }
        #expect(store.status == nil)
    }

    // MARK: 계정이 떠난 뒤의 늦은 응답 (PR-C 검토 1 P1)

    /// 화면 제거 · 교체 때 늦은 checkout 응답이 전 계정의 결제 주소를 열지 못한다.
    /// 진짜 Release 구역(`MacBillingSection`)을 `.id(userID)` 아래에 두고 (실제 계정 화면과 같다) 로그아웃 · 다른 계정 · 같은 계정 화면만 사라짐을 본다
    @MainActor
    @Observable
    final class StoreRegistry {
        @ObservationIgnored private var stores: [UUID: PlanSummaryStore] = [:]
        func store(for id: UUID) -> PlanSummaryStore {
            if let store = stores[id] { return store }
            let store = PlanSummaryStore()
            stores[id] = store
            return store
        }
    }

    private struct ReleaseHost: View {
        let box: AccountBox
        let stores: StoreRegistry
        let gateway: PlanHostGateway
        let accountFollowsBox: Bool

        var body: some View {
            if let id = box.userID {
                Form {
                    MacBillingSection(
                        userID: id, store: stores.store(for: id), gatewayOverride: gateway,
                        currentAccountOverride: accountFollowsBox ? { box.userID } : { id }
                    )
                    .id(id)
                }
                .formStyle(.grouped)
            } else {
                Text("Sign in")
            }
        }
    }

    @Test func aLateCheckoutAnswerOpensNothingWhenTheRealReleaseSectionIsRemovedOrReplaced() async {
        let cases: [(next: UUID?, accountFollowsBox: Bool, why: String)] = [
            (nil, true, "로그아웃"), (other, true, "다른 계정으로 바뀜"), (nil, false, "화면만 사라짐(계정은 그대로: 창을 닫음 · 페이지를 옮김)"),
        ]
        for item in cases {
            let box = AccountBox(user)
            let stores = StoreRegistry()
            let gateway = PlanHostGateway(status: PlanHostFixtures.status(.none, checkout: true, lifetime: true))
            let held = gateway.hold("checkout:pro:terms-host-test")
            let opened = PlanOpenedURLs()
            let (window, _) = await mount(ReleaseHost(box: box, stores: stores, gateway: gateway, accountFollowsBox: item.accountFollowsBox), width: 520, opened: opened)
            defer { window.orderOut(nil) }
            let previous = stores.store(for: user)
            await waitUntil("옛 구역이 처음 읽음 (\(item.why))") { previous.status != nil }
            let late = Task { await previous.perform(.checkout(.pro)) }
            await waitUntil("checkout 요청이 서버 앞에 도착 (\(item.why))") { held.arrived }
            box.userID = item.next
            await waitUntil("옛 구역이 제거돼 저장소가 무효화됨 (\(item.why))") { previous.owner == nil }
            held.open()
            await late.value
            #expect(opened.urls.isEmpty, "\(item.why): 이전 계정의 결제 주소를 열지 않는다")
            #expect(previous.busy == nil && previous.status == nil)
        }
    }

    @Test func aLatePortalAnswerOpensNothingWhenTheShownAccountLeftTheWindowBody() async {
        let box = AccountBox(user)
        let gateway = PlanHostGateway(status: PlanHostFixtures.status(.pastDue, plan: .monthly))
        let held = gateway.hold("portal:payment")
        let store = PlanSummaryStore()
        let opened = PlanOpenedURLs()
        struct Host: View {
            let box: AccountBox
            let store: PlanSummaryStore
            let gateway: PlanHostGateway
            var body: some View { SettingsPlanBody(store: store, userID: box.userID, gateway: gateway, currentAccount: { box.userID }) }
        }
        let (window, _) = await mount(Host(box: box, store: store, gateway: gateway), width: 520, opened: opened)
        defer { window.orderOut(nil) }
        await waitUntil("첫 읽기") { store.status != nil }
        let late = Task { await store.perform(.portal(.payment)) }
        await waitUntil("포털 요청이 서버 앞에 도착") { held.arrived }
        box.userID = nil
        held.open()
        await late.value
        #expect(opened.urls.isEmpty && store.owner == nil, "로그아웃 뒤 늦게 온 포털 주소를 열지 않는다")
    }

    // MARK: 환불 안내는 그 화면 흐름 안에서만 (PR-C 검토 1 P2)

    @Test func comingBackToTheAccountScreenWithTheSameAccountDropsTheRefundIssuedNoticeAndShowsThePurchaseRows() async {
        let gateway = PlanHostGateway([
            .success(PlanHostFixtures.status(.pro, plan: .monthly, refund: true)),
            .success(PlanHostFixtures.status(.none, checkout: true, lifetime: true)),
        ])
        let store = PlanSummaryStore()
        let opened = PlanOpenedURLs()
        let (first, _) = await mount(SettingsPlanBody(store: store, userID: user, gateway: gateway), width: 520, opened: opened)
        await waitUntil("첫 읽기") { store.status?.state == .pro }
        await store.perform(.confirmRefund)
        #expect(store.state.notice?.title == "Refund issued" && store.state.rows.map(\.id) == ["plan"], "그 확인 흐름 안에서는 보인다")
        // 탭을 옮겼다 돌아옴: 같은 저장소 · 같은 계정의 새 화면
        first.orderOut(nil)
        let (second, _) = await mount(SettingsPlanBody(store: store, userID: user, gateway: gateway), width: 520, opened: opened)
        defer { second.orderOut(nil) }
        await waitUntil("다시 들어와 환불 표시를 지움") { store.refundIssued == nil }
        let state = store.state
        #expect(state.notice == nil && state.rows.map(\.id) == ["plan", "pro", "lifetime"], "서버가 허용한 구매 줄이 보인다")
    }

    @Test func spendingOutsideTaskforceFitsTheWidth() async {
        let (window, host) = await mount(SpendingOutsideSection(), width: 520, opened: PlanOpenedURLs())
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width <= 520.5 && host.fittingSize.height > 60)
    }

    // MARK: Release 옛 창 (Form 줄)

    private func legacy(_ store: PlanSummaryStore, gateway: PlanHostGateway, userID: UUID?) -> some View {
        Form { MacBillingSectionBody(store: store, userID: userID, gateway: gateway) }.formStyle(.grouped)
    }

    @Test func theLegacyFormReadsOnceDrawsAndOpensTheAddressThroughOpenURL() async {
        let gateway = PlanHostGateway(status: PlanHostFixtures.status(.none, checkout: true, lifetime: true))
        let store = PlanSummaryStore()
        let opened = PlanOpenedURLs()
        let (window, host) = await mount(legacy(store, gateway: gateway, userID: user), width: 520, opened: opened)
        defer { window.orderOut(nil) }
        await waitUntil("첫 읽기") { store.status != nil }
        #expect(gateway.statusCalls == 1)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width <= 520.5)
        guard case .button(let button)? = store.state.row("lifetime")?.control else { Issue.record("Lifetime 줄 버튼이 있어야 한다"); return }
        #expect(button.title == "Buy Lifetime")
        await store.perform(button.action)
        #expect(gateway.calls.last == "checkout:lifetime:terms-host-test" && opened.urls.count == 1)
    }

    @Test func theLegacyFormBecomesActiveReadsAgainAndDropsALateAnswerAfterAnAccountSwitch() async {
        let box = AccountBox(user)
        let gateway = PlanHostGateway([.success(PlanHostFixtures.status(.pro, plan: .annual)), .success(PlanHostFixtures.status(.beta))])
        let gate = gateway.hold("status")
        let store = PlanSummaryStore()
        struct Host: View {
            let box: AccountBox
            let store: PlanSummaryStore
            let gateway: PlanHostGateway
            var body: some View { Form { MacBillingSectionBody(store: store, userID: box.userID, gateway: gateway) }.formStyle(.grouped) }
        }
        let (window, _) = await mount(Host(box: box, store: store, gateway: gateway), width: 520, opened: PlanOpenedURLs())
        defer { window.orderOut(nil) }
        await waitUntil("첫 읽기가 서버 앞에 도착") { gate.arrived }
        box.userID = other
        await waitUntil("새 계정") { store.owner == other }
        #expect(store.status?.state != .pro)
        gate.open()
        await waitUntil("새 계정의 읽기") { store.status != nil }
        for _ in 0..<20 {
            #expect(store.status?.state == .beta, "늦게 풀린 전 계정의 응답은 버려진다")
            try? await Task.sleep(for: .milliseconds(10))
        }
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await waitUntil("다시 활성화돼 읽음") { gateway.statusCalls >= 3 }
        #expect(gateway.statusCalls == 3)
    }

    @Test func everyStateFitsBothWindowsAtTheirColumnWidth() async {
        for status in PlanHostFixtures.all {
            let gateway = PlanHostGateway(status: status)
            let wide = PlanSummaryStore()
            let (windowA, hostA) = await mount(SettingsPlanBody(store: wide, userID: user, gateway: gateway), width: 520, opened: PlanOpenedURLs())
            let narrow = PlanSummaryStore()
            let (windowB, hostB) = await mount(legacy(narrow, gateway: gateway, userID: user), width: 520, opened: PlanOpenedURLs())
            await waitUntil("두 창이 읽음") { wide.status != nil && narrow.status != nil }
            hostA.layoutSubtreeIfNeeded()
            hostB.layoutSubtreeIfNeeded()
            #expect(hostA.fittingSize.width <= 520.5 && hostA.fittingSize.height > 40, "\(status.state)")
            #expect(hostB.fittingSize.width <= 520.5, "\(status.state)")
            windowA.orderOut(nil)
            windowB.orderOut(nil)
        }
    }
}
