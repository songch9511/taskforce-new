import Foundation
@testable import TaskforceKit
@testable import Taskforce

/// Plan & usage 호스트 시험의 가짜 서버: 실제 서버 · Lemon Squeezy · OpenRouter · 브라우저에 닿지 않는다. 호출 순서와 받은 값을 기록한다
final class PlanHostGateway: PlanSummaryGateway, @unchecked Sendable {
    struct Failure: Error {}

    private let lock = NSLock()
    private var recorded: [String] = []
    private var statuses: [Result<BillingStatusV2, Error>]
    private var gates: [String: AgentTestGate] = [:]

    init(_ statuses: [Result<BillingStatusV2, Error>]) {
        self.statuses = statuses
    }

    convenience init(status: BillingStatusV2) {
        self.init([.success(status)])
    }

    var calls: [String] { lock.withLock { recorded } }
    var statusCalls: Int { calls.filter { $0 == "status" }.count }

    func hold(_ call: String) -> AgentTestGate {
        let gate = AgentTestGate()
        lock.withLock { gates[call] = gate }
        return gate
    }

    private func enter(_ call: String) async {
        let gate: AgentTestGate? = lock.withLock {
            recorded.append(call)
            return gates[call]
        }
        if let gate { await gate.wait() }
    }

    func billingStatus() async throws -> BillingStatusV2 {
        let result: Result<BillingStatusV2, Error> = lock.withLock {
            recorded.append("status")
            return statuses.count > 1 ? statuses.removeFirst() : (statuses.first ?? .failure(Failure()))
        }
        let gate: AgentTestGate? = lock.withLock { gates["status"] }
        if let gate { await gate.wait() }
        return try result.get()
    }

    func billingCheckout(plan: PlanCheckoutKind, termsVersion: String) async throws -> URL {
        await enter("checkout:\(plan.rawValue):\(termsVersion)")
        return URL(string: "https://acme.lemonsqueezy.com/checkout/buy/test")!
    }

    func billingPortal(target: PlanPortalTarget) async throws -> URL {
        await enter("portal:\(target.rawValue)")
        return URL(string: "https://acme.lemonsqueezy.com/billing")!
    }

    func billingResume() async throws { await enter("resume") }
    func billingRefund() async throws { await enter("refund") }
    func saveOpenRouterKey(_ key: SecretBox) async throws { await enter("saveKey") }
    func removeOpenRouterKey() async throws { await enter("removeKey") }
}

/// 열려고 한 주소 기록 (실제 브라우저 0)
@MainActor
final class PlanOpenedURLs {
    private(set) var urls: [URL] = []
    func record(_ url: URL) { urls.append(url) }
}

enum PlanHostFixtures {
    static let prices = BillingStatusV2.Prices(proMonthly: "$12.99", proFirstMonth: "$6.99", proYearly: "$119.88", lifetime: "$229")

    static func status(
        _ state: BillingStatusV2.State, plan: BillingStatusV2.Plan? = nil, key: BillingStatusV2.KeyStatus? = nil, checkout: Bool = false,
        lifetime: Bool = false, refund: Bool = false, fairUse: Bool = false, noPay: Bool = false
    ) -> BillingStatusV2 {
        let day: TimeInterval = 86_400
        let now = Date()
        return BillingStatusV2(
            state: state, plan: plan, trialEndsAt: now.addingTimeInterval(2 * day), currentPeriodEndsAt: now.addingTimeInterval(19 * day),
            cancelAt: state == .cancelled ? now.addingTimeInterval(19 * day) : nil, refundUntil: refund ? now.addingTimeInterval(2 * day) : nil,
            canUseAI: true, canCheckout: checkout, canBuyLifetime: lifetime, withTrial: true, termsVersion: "terms-host-test", prices: prices,
            aiUsage: state == .pro ? BillingStatusV2.Usage(promptTokens: 1_000_000, completionTokens: 1_400_000, totalTokens: 2_400_000) : nil,
            fairUsePausedUntil: fairUse ? now.addingTimeInterval(11 * day) : nil, aiKey: key, aiKeySpendErrorAt: noPay ? now : nil
        )
    }

    /// 두 창이 그릴 수 있는 대표 상태 (계약 9.2)
    static var all: [BillingStatusV2] {
        [
            status(.none, checkout: true, lifetime: true), status(.lapsed, checkout: true, lifetime: true), status(.trial, plan: .monthly), status(.pro, plan: .annual, refund: true),
            status(.pro, plan: .monthly, fairUse: true), status(.cancelled, plan: .monthly), status(.pastDue, plan: .monthly), status(.lifetime, key: .connected, refund: true),
            status(.lifetime, key: .missing), status(.lifetime, key: .revoked), status(.lifetime, key: .connected, noPay: true), status(.beta),
            status(.beta, checkout: true, lifetime: true),
        ]
    }
}

extension PlanSummaryState {
    /// 그 id의 줄 (시험 도우미)
    func row(_ id: String) -> Row? { rows.first { $0.id == id } }
}
