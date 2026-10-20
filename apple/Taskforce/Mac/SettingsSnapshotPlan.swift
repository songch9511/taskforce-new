#if os(macOS) && DEBUG
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

/// Plan & usage 견본 (Debug 빌드, Release 바이너리에 없다): `--show-settings -TFSampleData -TFSettingsSnapshotPlan -TFSnapshot <폴더>`.
/// 0.2.0 창은 `-TF_EDGE_SHELL YES`를 더하고, 옛 창은 더하지 않는다. 상태마다 `<폴더>/light|dark/<창>-<상태>.png`:
/// 진짜 `SettingsPlanBody` · `MacBillingSectionBody`(Form 줄)를 진짜 `PlanSummaryStore` 위에 올리고, 동작은 가짜 서버(`SamplePlanGateway`)로 실제 눌림 · 실패 · 확인 상태를 만든다.
/// 값은 모두 가짜다: 실제 서버 · Lemon Squeezy · OpenRouter · 브라우저 · Keychain에 닿지 않는다 (주소는 `.handled`로 삼킨다). 렌더된 견본일 뿐이다: 실제 포인터 · 키보드 · VoiceOver 확인이 아니다
enum PlanSnapshot {
    static let argument = "-TFSettingsSnapshotPlan"

    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains(argument) }
}

/// 견본이 창에 넣는 가짜 서버 (`PlanGateways.current`가 견본 모드에서 읽는다)
@MainActor
enum PlanSnapshotHook {
    static var gateway: (any PlanSummaryGateway)?
}

/// 한 호출을 붙잡아 두는 문 (눌림 · 저장 중 모습): `release()`까지 호출이 멈춘다
final class SnapshotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    private var arrivals = 0

    var arrived: Bool { lock.withLock { arrivals > 0 } }

    func wait() async {
        lock.withLock { arrivals += 1 }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if opened { return true }
                waiting.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            opened = true
            defer { waiting = [] }
            return waiting
        }
        pending.forEach { $0.resume() }
    }
}

/// 견본 · 견본 모드용 가짜 서버: 상태 읽기는 차례로(마지막은 되풀이, nil이면 실패), 쓰기는 늘 성공하고, 호출 이름으로 실패 · 붙잡기를 정할 수 있다
final class SamplePlanGateway: PlanSummaryGateway, @unchecked Sendable {
    struct Failure: Error {}

    private let lock = NSLock()
    private var statuses: [BillingStatusV2?]
    private var failing: [String: Error] = [:]
    private var gates: [String: SnapshotGate] = [:]

    /// `-TFSampleData`만 켠 평범한 실행의 설정 창이 보이는 계정 (Pro 월간)
    static let standard = SamplePlanGateway([PlanSnapshot.pro(now: Date())])

    init(_ statuses: [BillingStatusV2?]) {
        self.statuses = statuses
    }

    func fail(_ call: String, with error: Error = Failure()) { lock.withLock { failing[call] = error } }

    /// 같은 서버가 다음에 내릴 상태를 바꾼다 (진짜 창이 열린 채 상태만 갈아 끼울 때)
    func replaceStatuses(_ next: [BillingStatusV2?]) { lock.withLock { statuses = next } }

    @discardableResult
    func hold(_ call: String) -> SnapshotGate {
        let gate = SnapshotGate()
        lock.withLock { gates[call] = gate }
        return gate
    }

    func releaseAll() {
        let all = lock.withLock { Array(gates.values) }
        all.forEach { $0.release() }
    }

    private func pass(_ call: String) async throws {
        let (gate, error) = lock.withLock { (gates[call], failing[call]) }
        if let gate { await gate.wait() }
        if let error { throw error }
    }

    func billingStatus() async throws -> BillingStatusV2 {
        let gate = lock.withLock { gates["status"] }
        if let gate { await gate.wait() }
        let next: BillingStatusV2? = lock.withLock { statuses.count > 1 ? statuses.removeFirst() : statuses.first.flatMap { $0 } }
        guard let next else { throw Failure() }
        return next
    }

    func billingCheckout(plan: PlanCheckoutKind, termsVersion: String) async throws -> URL {
        try await pass("checkout")
        return URL(string: "https://sample.lemonsqueezy.com/checkout/buy/sample")!
    }

    func billingPortal(target: PlanPortalTarget) async throws -> URL {
        try await pass("portal")
        return URL(string: "https://sample.lemonsqueezy.com/billing")!
    }

    func billingResume() async throws { try await pass("resume") }
    func billingRefund() async throws { try await pass("refund") }
    func saveOpenRouterKey(_ key: SecretBox) async throws { try await pass("save") }
    func removeOpenRouterKey() async throws { try await pass("remove") }
}

/// 상태 하나: 가짜 서버가 내릴 상태들과 (있으면) 그 상태에 이르는 동작
struct PlanScenario {
    let name: String
    let gateway: SamplePlanGateway
    var script: (@MainActor (PlanSummaryStore, SamplePlanGateway) async -> Void)?
}

extension PlanSnapshot {
    private static let prices = BillingStatusV2.Prices(proMonthly: "$12.99", proFirstMonth: "$6.99", proYearly: "$119.88", lifetime: "$229")
    private static func day(_ now: Date, _ days: Double) -> Date { now.addingTimeInterval(days * 86_400) }

    static func status(
        _ state: BillingStatusV2.State, now: Date, plan: BillingStatusV2.Plan? = nil, trialEnds: Double? = nil, period: Double? = nil, cancel: Double? = nil,
        notice: Double? = nil, refund: Double? = nil, refundState: BillingStatusV2.RefundState = .idle, checkout: Bool = false, lifetime: Bool = false,
        withTrial: Bool = false, tokens: Int? = nil, fairUse: Double? = nil, key: BillingStatusV2.KeyStatus? = nil, spendError: Double? = nil
    ) -> BillingStatusV2 {
        BillingStatusV2(
            state: state, plan: plan, trialEndsAt: trialEnds.map { day(now, $0) }, currentPeriodEndsAt: period.map { day(now, $0) }, cancelAt: cancel.map { day(now, $0) },
            noticeEndsAt: notice.map { day(now, $0) }, refundUntil: refund.map { day(now, $0) }, refundState: refundState, canUseAI: true, canCheckout: checkout,
            canBuyLifetime: lifetime, withTrial: withTrial, termsVersion: "sample", prices: prices,
            aiUsage: tokens.map { BillingStatusV2.Usage(promptTokens: $0 / 2, completionTokens: $0 - $0 / 2, totalTokens: $0) },
            fairUsePausedUntil: fairUse.map { day(now, $0) }, aiKey: key, aiKeySpendErrorAt: spendError.map { day(now, $0) }
        )
    }

    /// 키 저장 422 (OpenRouter가 거절 · 관리 키)
    private static func keyError(_ code: APIErrorCode) -> APIError { .server(status: 422, code: code, message: "sample") }

    static func pro(now: Date) -> BillingStatusV2 {
        status(.pro, now: now, plan: .monthly, period: 19, refund: 2.5, tokens: 2_400_000)
    }

    /// DZ 그림과 같은 상태 (이름 앞 숫자는 DZ 시트 번호). 날짜는 실행한 날에서 센다
    static func scenarios(now: Date) -> [PlanScenario] {
        func one(_ name: String, _ statuses: [BillingStatusV2?], script: (@MainActor (PlanSummaryStore, SamplePlanGateway) async -> Void)? = nil) -> PlanScenario {
            PlanScenario(name: name, gateway: SamplePlanGateway(statuses), script: script)
        }
        let noneFirst = status(.none, now: now, checkout: true, lifetime: true, withTrial: true)
        let noneUsed = status(.none, now: now, checkout: true, lifetime: true)
        let lapsed = status(.lapsed, now: now, checkout: true, lifetime: true)
        let proRefund = status(.pro, now: now, plan: .monthly, period: 19, refund: 2.5, tokens: 2_400_000)
        let lifetime = { (key: BillingStatusV2.KeyStatus, refund: Double?, spend: Double?) in
            status(.lifetime, now: now, refund: refund, key: key, spendError: spend)
        }
        let sampleKey = SecretBox("sk-or-v1-sample0123456789abcdef")
        return [
            // DZ-0 · DZ-1: 읽는 중 · 못 읽음 · No plan · checkout · 끝남
            one("00-checking", [noneFirst]) { _, gateway in _ = gateway.hold("status") },
            one("00-load-failed", [nil]),
            one("01-none-first", [noneFirst]),
            one("01-none-trial-used", [noneUsed]),
            one("01-checkout-opening", [noneFirst]) { store, gateway in
                gateway.hold("checkout")
                Task { await store.perform(.checkout(.pro)) }
                while store.busy == nil { try? await Task.sleep(for: .milliseconds(50)) }
            },
            one("01-checkout-failed", [noneFirst]) { store, gateway in
                gateway.fail("checkout")
                await store.perform(.checkout(.pro))
            },
            one("01-lapsed", [lapsed]),
            one("01-lapsed-restart-failed", [lapsed]) { store, gateway in
                gateway.fail("checkout")
                await store.perform(.checkout(.pro))
            },
            // DZ-0: 체험 · Pro · 환불
            one("02-trial-monthly", [status(.trial, now: now, plan: .monthly, trialEnds: 2)]),
            one("02-trial-yearly", [status(.trial, now: now, plan: .annual, trialEnds: 2)]),
            one("02-pro-monthly", [proRefund]),
            one("02-pro-yearly-long", [status(.pro, now: now, plan: .annual, period: 438, tokens: 1_284_600_000)]),
            one("02-refund-confirm", [proRefund]) { store, _ in await store.perform(.askRefund) },
            one("02-refund-requested", [status(.pro, now: now, plan: .monthly, period: 19, refundState: .requested, tokens: 2_400_000)]),
            one("02-refund-issued", [proRefund, lapsed]) { store, _ in
                await store.perform(.askRefund)
                await store.perform(.confirmRefund)
            },
            one("02-refund-failed", [proRefund]) { store, gateway in
                gateway.fail("refund")
                await store.perform(.askRefund)
                await store.perform(.confirmRefund)
            },
            one("03-cancelled", [status(.cancelled, now: now, plan: .monthly, period: 19, cancel: 19)]),
            one("03-past-due", [status(.pastDue, now: now, plan: .monthly, period: -12)]),
            // DZ-0 · DZ-5 · DZ-8: Lifetime · OpenRouter 키
            one("04-lifetime-connected", [lifetime(.connected, 2.5, nil)]),
            one("04-lifetime-key-missing", [lifetime(.missing, nil, nil)]),
            one("04-lifetime-key-saving", [lifetime(.missing, nil, nil)]) { store, gateway in
                gateway.hold("save")
                Task { await store.saveKey(sampleKey) }
                while store.busy == nil { try? await Task.sleep(for: .milliseconds(50)) }
            },
            one("04-lifetime-key-saved", [lifetime(.missing, nil, nil), lifetime(.connected, nil, nil)]) { store, _ in await store.saveKey(sampleKey) },
            one("04-lifetime-key-invalid", [lifetime(.missing, nil, nil)]) { store, gateway in
                gateway.fail("save", with: keyError(.aiKeyInvalid))
                await store.saveKey(sampleKey)
            },
            one("04-lifetime-key-management", [lifetime(.missing, nil, nil)]) { store, gateway in
                gateway.fail("save", with: keyError(.aiKeyManagement))
                await store.saveKey(sampleKey)
            },
            one("04-lifetime-key-network", [lifetime(.missing, nil, nil)]) { store, gateway in
                gateway.fail("save", with: APIError.transport("sample"))
                await store.saveKey(sampleKey)
            },
            one("04-lifetime-key-revoked", [lifetime(.revoked, nil, nil)]),
            one("05-remove-key-confirm", [lifetime(.connected, nil, nil)]) { store, _ in await store.perform(.askRemoveKey) },
            one("05-remove-key-removing", [lifetime(.connected, nil, nil)]) { store, gateway in
                gateway.hold("remove")
                await store.perform(.askRemoveKey)
                Task { await store.perform(.confirmRemoveKey) }
                while store.busy == nil { try? await Task.sleep(for: .milliseconds(50)) }
            },
            one("05-remove-key-removed", [lifetime(.connected, nil, nil), lifetime(.missing, nil, nil)]) { store, _ in
                await store.perform(.askRemoveKey)
                await store.perform(.confirmRemoveKey)
            },
            one("04-lifetime-refund-confirm", [lifetime(.connected, 2.5, nil)]) { store, _ in await store.perform(.askRefund) },
            one("04-lifetime-refund-requested", [status(.lifetime, now: now, refundState: .requested, key: .connected)]),
            one("04-lifetime-refund-issued", [lifetime(.connected, 2.5, nil), status(.none, now: now, checkout: true, lifetime: true, withTrial: true)]) { store, _ in
                await store.perform(.confirmRefund)
            },
            // DZ-6 · DZ-7: Notice (OpenRouter can't pay · 공정 사용 · 겹침)
            one("06-openrouter-cant-pay", [lifetime(.connected, nil, -0.1)]),
            one("07-fair-use-pro-monthly", [status(.pro, now: now, plan: .monthly, period: 19, refund: 2.5, tokens: 9_800_000, fairUse: 11)]),
            one("07-fair-use-pro-yearly", [status(.pro, now: now, plan: .annual, period: 438, tokens: 142_600_000, fairUse: 11)]),
            one("07-fair-use-trial", [status(.trial, now: now, plan: .monthly, trialEnds: 2, fairUse: 2)]),
            one("07-past-due-beats-fair-use", [status(.pastDue, now: now, plan: .monthly, period: -12, fairUse: 11)]),
            // DZ-3: 베타
            one("08-beta", [status(.beta, now: now)]),
            one("08-beta-notice", [status(.beta, now: now, notice: 31, checkout: true, lifetime: true, withTrial: true)]),
        ]
    }
}

extension SettingsSnapshot {
    /// Plan & usage의 모든 상태를 Light · Dark로. 진짜 알맹이 뷰를 진짜 저장소 위에 올린 독립 창(폭 556: 옛 창 본문 칸 · 0.2.0 창 본문 폭)을 그린다.
    /// 0.2.0 창은 맥락 장면(Account 탭 · Execution 탭)도 진짜 설정 창에서 담는다
    static func capturePlan(to directory: URL, legacy: Bool) async {
        let now = Date()
        func settle(_ seconds: Double = 0.8) async { try? await Task.sleep(for: .seconds(seconds)) }
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            NSApplication.shared.appearance = NSAppearance(named: appearance)
            let folder = directory.appending(path: name, directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let prefix = legacy ? "legacy" : "window"
            for scenario in PlanSnapshot.scenarios(now: now) {
                let store = PlanSummaryStore()
                let userID = SampleData.userID
                let gateway = scenario.gateway
                let content: AnyView = legacy
                    ? AnyView(Form { MacBillingSectionBody(store: store, userID: userID, gateway: gateway) }.formStyle(.grouped).frame(width: 556).fixedSize(horizontal: false, vertical: true))
                    : AnyView(SettingsPlanBody(store: store, userID: userID, gateway: gateway).padding(20).frame(width: 560, alignment: .leading).fixedSize(horizontal: false, vertical: true))
                let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: legacy ? 556 : 560, height: 1400), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSApplication.shared.appearance
                let host = NSHostingView(rootView: content
                    .background(legacy ? TFColor.settingsContent : TFColor.bgSurface)
                    // 주소는 열지 않는다 (checkout · 포털)
                    .environment(\.openURL, OpenURLAction { _ in .handled })
                    .environment(\.colorScheme, name == "dark" ? .dark : .light))
                window.contentView = host
                window.orderFront(nil)
                // 알맹이의 생애가 이 가짜 서버로 계정을 정하고 한 번 읽는다
                await settle()
                if let script = scenario.script { await script(store, gateway) }
                await settle(0.6)
                // 내용의 자연 높이에 창을 맞춘다
                host.layoutSubtreeIfNeeded()
                window.setContentSize(NSSize(width: legacy ? 556 : 560, height: max(host.fittingSize.height, 80)))
                await settle(0.4)
                capture(window, to: folder.appending(path: "\(prefix)-\(scenario.name).png"))
                gateway.releaseAll()
                await settle(0.2)
                window.orderOut(nil)
            }
        }
        if legacy { await capturePlanLegacyContext(to: directory, now: now) } else { await capturePlanContext(to: directory, now: now) }
        NSApplication.shared.appearance = nil
    }

    /// 진짜 옛 설정 창(Account 페이지 안의 Plan & usage 구역): 위 · 가운데 · 끝. 같은 가짜 서버의 상태만 갈아 끼우고 창을 다시 연다 (열면 다시 읽는다)
    private static func capturePlanLegacyContext(to directory: URL, now: Date) async {
        func settle(_ seconds: Double = 1.2) async { try? await Task.sleep(for: .seconds(seconds)) }
        let gateway = SamplePlanGateway([PlanSnapshot.pro(now: now)])
        PlanSnapshotHook.gateway = gateway
        let contexts: [(String, BillingStatusV2)] = [
            ("account-pro", PlanSnapshot.pro(now: now)),
            ("account-lifetime-missing", PlanSnapshot.status(.lifetime, now: now, key: .missing)),
        ]
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            NSApplication.shared.appearance = NSAppearance(named: appearance)
            let folder = directory.appending(path: name, directoryHint: .isDirectory)
            for (shot, status) in contexts {
                gateway.replaceStatuses([status])
                SettingsOpener.open(.account)
                await settle(2.0)
                guard let window = settingsWindow else { continue }
                scrollToStart(window)
                await settle(0.5)
                capture(window, to: folder.appending(path: "legacy-context-\(shot)-top.png"))
                if scrollTo(window, fraction: 0.4) {
                    await settle(0.5)
                    capture(window, to: folder.appending(path: "legacy-context-\(shot)-mid.png"))
                }
                if scrollToEnd(window) {
                    await settle(0.5)
                    capture(window, to: folder.appending(path: "legacy-context-\(shot)-end.png"))
                }
            }
        }
        PlanSnapshotHook.gateway = nil
    }

    /// 창 안에서 가장 긴 스크롤 칸을 `fraction`(0 맨 위 · 1 맨 끝)만큼 내린다. 스크롤할 것이 없으면 false
    private static func scrollTo(_ window: NSWindow, fraction: CGFloat) -> Bool {
        guard let root = window.contentView else { return false }
        var stack: [NSView] = [root]
        var best: (view: NSScrollView, overflow: CGFloat)?
        while let view = stack.popLast() {
            if let scroll = view as? NSScrollView, let document = scroll.documentView {
                let overflow = document.frame.height - scroll.contentView.bounds.height
                if overflow > (best?.overflow ?? 1) { best = (scroll, overflow) }
            }
            stack.append(contentsOf: view.subviews)
        }
        guard let best, let document = best.view.documentView else { return false }
        let offset = best.overflow * fraction
        best.view.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? offset : best.overflow - offset))
        best.view.reflectScrolledClipView(best.view.contentView)
        return true
    }

    /// 진짜 설정 창의 맥락: Account 탭(Plan & usage가 탭 안에 서는 자리)과 Execution 탭(Spending outside Taskforce)
    private static func capturePlanContext(to directory: URL, now: Date) async {
        func settle(_ seconds: Double = 1.0) async { try? await Task.sleep(for: .seconds(seconds)) }
        let model = SettingsWindowModel.shared
        let contexts: [(String, BillingStatusV2, SettingsWindowTab)] = [
            ("account-pro", PlanSnapshot.pro(now: now), .account),
            ("account-fair-use", PlanSnapshot.status(.pro, now: now, plan: .monthly, period: 19, tokens: 9_800_000, fairUse: 11), .account),
            ("account-lifetime-missing", PlanSnapshot.status(.lifetime, now: now, key: .missing), .account),
            ("execution", PlanSnapshot.pro(now: now), .execution),
        ]
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            NSApplication.shared.appearance = NSAppearance(named: appearance)
            let folder = directory.appending(path: name, directoryHint: .isDirectory)
            for (shot, status, tab) in contexts {
                let gateway = SamplePlanGateway([status])
                PlanSnapshotHook.gateway = gateway
                model.plan.follow(userID: nil, gateway: nil)
                await show(tab)
                // 같은 탭이 이미 열려 있으면 절의 생애가 다시 돌지 않는다: 이 가짜 서버로 직접 붙이고 읽는다
                model.plan.follow(userID: SampleData.userID, gateway: gateway)
                await model.plan.refresh()
                await settle()
                guard let window = settingsWindow else { continue }
                // 시작 · 가운데(Plan & usage) · 끝
                scrollToStart(window)
                await settle(0.5)
                capture(window, to: folder.appending(path: "window-context-\(shot)-top.png"))
                if scrollTo(window, fraction: 0.4) {
                    await settle(0.5)
                    capture(window, to: folder.appending(path: "window-context-\(shot)-mid.png"))
                }
                if scrollToEnd(window) {
                    await settle(0.5)
                    capture(window, to: folder.appending(path: "window-context-\(shot)-end.png"))
                }
                gateway.releaseAll()
            }
        }
        PlanSnapshotHook.gateway = nil
        model.close()
    }
}
#endif
