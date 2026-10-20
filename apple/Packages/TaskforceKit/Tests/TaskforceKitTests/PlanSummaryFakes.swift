import Foundation
import Testing
@testable import TaskforceKit

/// 문이 열릴 때까지 기다리게 하는 장치: 응답이 늦게 오는 경우(계정 전환 · 겹친 읽기)를 고정된 순서로 만든다. 짧은 sleep에 기대지 않는다
final class AsyncGate: @unchecked Sendable {
    /// true면 첫 호출만 붙잡는다: 막아야 할 둘째 호출이 새어 나가도 시험이 멈추지 않고 호출 수로 빨개진다
    private let holdsOnlyFirst: Bool
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private var count = 0

    init(holdsOnlyFirst: Bool = false) {
        self.holdsOnlyFirst = holdsOnlyFirst
    }

    /// 문 앞에 도착한 호출 수
    var entered: Int { lock.withLock { count } }

    func wait() async {
        let mustWait: Bool = lock.withLock {
            count += 1
            return !isOpen && (!holdsOnlyFirst || count == 1)
        }
        guard mustWait else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = lock.withLock {
                if isOpen { return true }
                continuations.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            defer { continuations = [] }
            return continuations
        }
        waiting.forEach { $0.resume() }
    }
}

/// 실제 서버 · Lemon Squeezy · OpenRouter에 닿지 않는 가짜 길. 호출 순서와 받은 값을 기록한다
final class FakePlanGateway: PlanSummaryGateway, @unchecked Sendable {
    struct Failure: Error, Equatable {}

    private let lock = NSLock()
    private var recorded: [String] = []
    private var statuses: [Result<BillingStatusV2, Error>]
    private var statusGates: [AsyncGate?] = []
    private var keys: [String] = []

    var checkoutResult: Result<URL, Error> = .success(URL(string: "https://acme.lemonsqueezy.com/checkout/buy/test")!)
    var portalResult: Result<URL, Error> = .success(URL(string: "https://acme.lemonsqueezy.com/billing")!)
    var resumeError: Error?
    var refundError: Error?
    var saveError: Error?
    var removeError: Error?
    var checkoutGate: AsyncGate?
    var portalGate: AsyncGate?
    /// false면 받은 키의 글자를 기록하지 않는다 (저장소가 키를 쥐고 있는지 거울로 훑을 때: 저장소는 이 가짜 길을 쥐고 있어서 기록이 섞이지 않게)
    var recordsKeys = true

    init(_ statuses: [Result<BillingStatusV2, Error>] = []) {
        self.statuses = statuses
    }

    convenience init(status: BillingStatusV2) {
        self.init([.success(status)])
    }

    var calls: [String] { lock.withLock { recorded } }
    var statusCalls: Int { calls.filter { $0 == "status" }.count }
    /// 시험 전용: 저장하려고 보낸 키의 글자 (앱 소스는 이 값을 남기지 않는다)
    var savedKeys: [String] { lock.withLock { keys } }

    /// 다음 상태 읽기가 이 문 앞에서 기다린다 (읽기마다 하나씩 쌓인다)
    func gateNextStatus(_ gate: AsyncGate) { lock.withLock { statusGates.append(gate) } }
    func setStatuses(_ next: [Result<BillingStatusV2, Error>]) { lock.withLock { statuses = next } }

    private func record(_ line: String) { lock.withLock { recorded.append(line) } }

    func billingStatus() async throws -> BillingStatusV2 {
        record("status")
        let (gate, result): (AsyncGate?, Result<BillingStatusV2, Error>) = lock.withLock {
            let gate = statusGates.isEmpty ? nil : statusGates.removeFirst()
            let result = statuses.count > 1 ? statuses.removeFirst() : (statuses.first ?? .failure(Failure()))
            return (gate, result)
        }
        if let gate { await gate.wait() }
        return try result.get()
    }

    func billingCheckout(plan: PlanCheckoutKind, termsVersion: String) async throws -> URL {
        record("checkout:\(plan.rawValue):\(termsVersion)")
        if let checkoutGate { await checkoutGate.wait() }
        return try checkoutResult.get()
    }

    func billingPortal(target: PlanPortalTarget) async throws -> URL {
        record("portal:\(target.rawValue)")
        if let portalGate { await portalGate.wait() }
        return try portalResult.get()
    }

    func billingResume() async throws {
        record("resume")
        if let resumeError { throw resumeError }
    }

    func billingRefund() async throws {
        record("refund")
        if let refundError { throw refundError }
    }

    func saveOpenRouterKey(_ key: SecretBox) async throws {
        record("saveKey")
        if recordsKeys { lock.withLock { keys.append(key.reveal()) } }
        if let saveError { throw saveError }
    }

    func removeOpenRouterKey() async throws {
        record("removeKey")
        if let removeError { throw removeError }
    }
}

/// 열려고 한 주소 기록 (실제 브라우저 0)
@MainActor
final class OpenedURLs {
    private(set) var urls: [URL] = []
    func record(_ url: URL) { urls.append(url) }
}

/// 조건이 될 때까지 기다린다 (고정된 짧은 sleep 대신). 시간 안에 안 되면 시험이 실패한다
@MainActor
func waitUntil(_ what: String, timeout: Duration = .seconds(60), _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline {
            Issue.record("조건을 기다리다 시간이 지났다: \(what)")
            return
        }
        await Task.yield()
    }
}

/// 지금 로그인한 계정 (화면 밖의 진실): 시험이 마음대로 바꾼다. 저장소는 `follow`를 부르지 않아도 이것으로 계정이 떠난 것을 안다
@MainActor
final class AccountBox {
    var id: UUID?
    init(_ id: UUID?) { self.id = id }
}
