import Foundation
import Observation

/// Plan & usage가 부르는 서버 (v2 결제 route, OA 결제 계약 8장). 실제 구현은 `APIClient`다. 시험 · 견본은 가짜를 쓴다: 실제 Lemon Squeezy · OpenRouter · 브라우저에 닿지 않는다.
/// 모든 쓰기는 서버가 이벤트를 남긴다. 자격은 결제 제공자 webhook으로만 바뀐다 (클라이언트 신고 없음): 이 호출들의 성공은 "요청했다"일 뿐이다.
public protocol PlanSummaryGateway: Sendable {
    func billingStatus() async throws -> BillingStatusV2
    /// checkout 주소 (https `*.lemonsqueezy.com`만). `termsVersion`은 상태가 내려 준 현재 판을 그대로 되돌려 보낸다
    func billingCheckout(plan: PlanCheckoutKind, termsVersion: String) async throws -> URL
    func billingPortal(target: PlanPortalTarget) async throws -> URL
    func billingResume() async throws
    func billingRefund() async throws
    /// Lifetime의 OpenRouter 키. 값은 이 호출의 본문으로만 서버에 간다 (서버가 OpenRouter에 확인하고 암호화해 둔다, 다시 내려 주지 않는다)
    func saveOpenRouterKey(_ key: SecretBox) async throws
    func removeOpenRouterKey() async throws
}

extension APIClient: PlanSummaryGateway {}

/// Plan & usage 한 화면의 상태와 동작. Release 옛 창 · 0.2.0 창이 같은 규칙을 쓴다 (화면마다 하나씩 가진다).
/// - 계정마다 따로다: `follow(userID:gateway:)`가 계정이 바뀌면 값을 모두 비우고 늦은 응답을 버린다.
/// - 동작은 한 번에 하나 (진행 중이면 다른 동작은 무시): 서버가 두 번 부르는 일이 없다.
/// - 키는 `SecretBox`로만 지나가고 이 객체 어디에도 남지 않는다 (글로 찍어도 값이 나오지 않는다).
@MainActor
@Observable
public final class PlanSummaryStore {
    public private(set) var status: BillingStatusV2?
    public private(set) var loadFailed = false
    /// checkout을 열고 돌아와 상태를 다시 읽는 첫 읽기가 도는 동안 ("Checking…")
    public private(set) var settling = false
    public private(set) var busy: PlanSummaryInput.Busy?
    public private(set) var failure: PlanSummaryInput.Failure?
    public private(set) var askingRefund = false
    public private(set) var confirmingRemoveKey = false
    public private(set) var refundRequested = false
    public private(set) var refundIssued: PlanSummaryInput.IssuedPlan?
    public private(set) var owner: UUID?

    /// checkout · 포털 주소를 브라우저로 여는 일 (화면이 넣는다: `openURL`). 시험은 기록하는 가짜를 넣는다
    @ObservationIgnored public var opener: (@MainActor (URL) -> Void)?
    @ObservationIgnored private var gateway: (any PlanSummaryGateway)?
    /// 계정이 바뀔 때마다 오른다: 전 계정의 늦은 응답을 버린다
    @ObservationIgnored private var generation = 0
    /// 읽기마다 오른다: 겹친 읽기에서 오래된 응답이 새 값을 덮지 않는다
    @ObservationIgnored private var readSerial = 0
    /// checkout 주소를 열었다: 앱이 다시 활성화되면 Checking…으로 다시 읽고 webhook이 닿을 때까지 조용히 몇 번 더 읽는다
    @ObservationIgnored private var checkoutOpened = false
    @ObservationIgnored private var refundPlan: PlanSummaryInput.IssuedPlan?
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let pause: @Sendable (Duration) async -> Void
    @ObservationIgnored private let settleReads: Int
    @ObservationIgnored private let settleInterval: Duration

    public init(
        clock: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .current,
        pause: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        settleReads: Int = 5, settleInterval: Duration = .seconds(3)
    ) {
        self.clock = clock
        self.calendar = calendar
        self.pause = pause
        self.settleReads = settleReads
        self.settleInterval = settleInterval
    }

    /// 화면이 쓸 규칙 값 (관찰된다: 읽는 값이 바뀌면 화면이 다시 그려진다)
    public var state: PlanSummaryState { PlanSummaryState.make(input) }

    private var input: PlanSummaryInput {
        PlanSummaryInput(
            status: status, loadFailed: loadFailed, settling: settling, busy: busy, failure: failure, askingRefund: askingRefund,
            confirmingRemoveKey: confirmingRemoveKey, refundRequested: refundRequested, refundIssued: refundIssued, now: clock(), calendar: calendar
        )
    }

    // MARK: 계정

    /// 화면이 보이는 계정과 서버 길을 붙인다. 계정이 바뀌면(로그아웃 = nil 포함) 값 · 진행 중인 동작을 모두 비우고 늦은 응답을 버린다
    public func follow(userID: UUID?, gateway: (any PlanSummaryGateway)?) {
        if owner != userID {
            generation += 1
            owner = userID
            reset()
        }
        self.gateway = userID == nil ? nil : gateway
    }

    private func reset() {
        status = nil
        loadFailed = false
        settling = false
        busy = nil
        failure = nil
        askingRefund = false
        confirmingRemoveKey = false
        refundRequested = false
        refundIssued = nil
        checkoutOpened = false
        refundPlan = nil
    }

    // MARK: 읽기

    /// 상태를 읽는다 (창이 보일 때 · 다시 열 때). 읽지 못해도 이미 읽은 값은 그대로 둔다
    public func refresh() async {
        _ = await read()
    }

    @discardableResult
    private func read() async -> BillingStatusV2? {
        guard let gateway, owner != nil else { return nil }
        let generation = generation
        readSerial += 1
        let serial = readSerial
        do {
            let value = try await gateway.billingStatus()
            guard generation == self.generation, serial == readSerial else { return nil }
            apply(value)
            return value
        } catch {
            guard generation == self.generation, serial == readSerial, !(error is CancellationError) else { return nil }
            if status == nil { loadFailed = true }
            return nil
        }
    }

    private func apply(_ value: BillingStatusV2) {
        status = value
        loadFailed = false
        // 이 화면에서 환불을 요청했는데 플랜이 끝났다: 환불이 확인됐다 ("Refund issued")
        if let plan = refundPlan, value.state == .none || value.state == .lapsed {
            refundIssued = plan
            refundPlan = nil
            refundRequested = false
        }
    }

    /// 앱이 다시 활성화됐다 (브라우저에서 돌아옴 · 시스템 설정 등). checkout을 열고 온 것이면 Checking…으로 읽고 webhook이 닿을 때까지 조용히 몇 번 더 읽는다
    public func appDidBecomeActive() async {
        guard checkoutOpened else {
            await refresh()
            return
        }
        checkoutOpened = false
        let generation = generation
        let baseline = status?.state
        settling = true
        var current = await read()
        guard generation == self.generation else { return }
        settling = false
        var reads = 1
        // 결제가 반영되면 상태가 바뀐다. 안 바뀌면(결제 안 함 · 아직 webhook 전) 몇 번만 조용히 더 읽는다
        while let value = current, value.state == baseline, reads < settleReads {
            await pause(settleInterval)
            guard generation == self.generation else { return }
            current = await read()
            reads += 1
        }
    }

    // MARK: 동작

    /// 줄 · 버튼이 누른 동작. 진행 중인 동작이 있으면 무시한다
    public func perform(_ action: PlanSummaryState.Action) async {
        switch action {
        case .checkout(let kind): await openCheckout(kind)
        case .portal(let target): await openPortal(target)
        case .resume: await resume()
        case .askRefund:
            guard busy == nil else { return }
            failure = nil
            askingRefund = true
        case .cancelRefund:
            guard busy != .refund else { return }
            askingRefund = false
        case .confirmRefund: await requestRefund()
        case .askRemoveKey:
            guard busy == nil else { return }
            failure = nil
            confirmingRemoveKey = true
        case .cancelRemoveKey:
            guard busy != .removeKey else { return }
            confirmingRemoveKey = false
        case .confirmRemoveKey: await removeKey()
        case .saveKey:
            // 값은 칸에서 `SecretBox`로 한 번 읽어 `saveKey(_:)`로 온다
            break
        }
    }

    private func openCheckout(_ kind: PlanCheckoutKind) async {
        guard busy == nil, let gateway, owner != nil, let terms = status?.termsVersion else { return }
        let generation = generation
        busy = .checkout(kind)
        failure = nil
        do {
            let url = try await gateway.billingCheckout(plan: kind, termsVersion: terms)
            guard generation == self.generation else { return }
            busy = nil
            checkoutOpened = true
            opener?(url)
        } catch {
            guard generation == self.generation else { return }
            busy = nil
            if !(error is CancellationError) { failure = .checkout(kind) }
        }
    }

    private func openPortal(_ target: PlanPortalTarget) async {
        guard busy == nil, let gateway, owner != nil else { return }
        let generation = generation
        busy = .portal(target)
        failure = nil
        do {
            let url = try await gateway.billingPortal(target: target)
            guard generation == self.generation else { return }
            busy = nil
            opener?(url)
        } catch {
            guard generation == self.generation else { return }
            busy = nil
            if !(error is CancellationError) { failure = .portal(target) }
        }
    }

    private func resume() async {
        guard busy == nil, let gateway, owner != nil else { return }
        let generation = generation
        busy = .resume
        failure = nil
        do {
            try await gateway.billingResume()
            guard generation == self.generation else { return }
            busy = nil
            // 자격은 webhook이 바꾼다: 요청만으로 화면을 바꾸지 않고 다시 읽는다
            await refresh()
        } catch {
            guard generation == self.generation else { return }
            busy = nil
            if !(error is CancellationError) { failure = .resume }
        }
    }

    private func requestRefund() async {
        guard busy == nil, let gateway, owner != nil else { return }
        let generation = generation
        let plan: PlanSummaryInput.IssuedPlan = status?.state == .lifetime ? .lifetime : .pro
        busy = .refund
        failure = nil
        do {
            try await gateway.billingRefund()
            guard generation == self.generation else { return }
            busy = nil
            askingRefund = false
            // 요청했다: 서버가 다시 읽는 값이 `requested`로 바뀌기 전에도 Notice가 선다. 자격은 확정(webhook) 뒤에만 바뀐다
            refundRequested = true
            refundPlan = plan
            await refresh()
        } catch {
            guard generation == self.generation else { return }
            busy = nil
            askingRefund = false
            if !(error is CancellationError) { failure = .refund }
            // 창이 닫혔거나(409) 이미 요청했을 수 있다: 서버의 지금 상태를 다시 읽는다
            await refresh()
        }
    }

    // MARK: 키 (Lifetime)

    /// 키 칸의 Save · Return. 값은 `SecretBox`로 오고 서버로 한 번 가면 끝이다 (이 객체에 남기지 않는다)
    public func saveKey(_ key: SecretBox) async {
        guard busy == nil, let gateway, owner != nil, status?.state == .lifetime, !key.isEmpty else { return }
        let generation = generation
        busy = .saveKey
        failure = nil
        do {
            try await gateway.saveOpenRouterKey(key)
            guard generation == self.generation else { return }
            busy = nil
            // 서버가 OpenRouter에 확인하고 저장했다: 다시 읽기 전까지도 줄이 맞게 보인다
            status = status?.replacingKey(.connected)
            await refresh()
        } catch {
            guard generation == self.generation else { return }
            busy = nil
            if error is CancellationError { return }
            switch (error as? APIError) {
            case .server(_, .aiKeyInvalid, _)?: failure = .keySave(.invalid)
            case .server(_, .aiKeyManagement, _)?: failure = .keySave(.management)
            default: failure = .keySave(.generic)
            }
        }
    }

    private func removeKey() async {
        guard busy == nil, let gateway, owner != nil else { return }
        let generation = generation
        busy = .removeKey
        failure = nil
        do {
            try await gateway.removeOpenRouterKey()
            guard generation == self.generation else { return }
            busy = nil
            confirmingRemoveKey = false
            status = status?.replacingKey(.missing)
            await refresh()
        } catch {
            guard generation == self.generation else { return }
            busy = nil
            confirmingRemoveKey = false
            if !(error is CancellationError) { failure = .keyRemove }
        }
    }
}
