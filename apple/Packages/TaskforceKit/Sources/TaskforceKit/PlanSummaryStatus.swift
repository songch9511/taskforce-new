import Foundation

/// `GET /api/v2/billing` (contract.ts `billingStatusV2Schema`). 표시용이다: AI · 실행을 쓸 수 있는지는 서버가 호출마다 따로 정한다 (I15, 클라이언트 신고 없음).
/// 읽는 규칙(계약 16.4): 모르는 `state`는 `.unknown`("Checking…"으로 그린다) · 남는 키는 무시 · 빠진 필수 키는 실패. 모르는 `plan` · `ai_key` · `refund_state` 값은 안전한 쪽(없음 · 없음 · idle)으로 읽는다.
/// 가격 · 약관 판은 서버가 내린 글자 그대로다 (Mac에 가격 숫자 상수 0). 숨은 월 상한의 숫자는 오지 않는다: `fair_use_paused_until`만 있다.
public struct BillingStatusV2: Decodable, Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case none, trial, pro, cancelled
        case pastDue = "past_due"
        case lapsed, lifetime, beta
        /// 이 앱이 모르는 상태 (더 새 서버): 주장하지 않고 "Checking…"
        case unknown
    }

    public enum Plan: String, Equatable, Sendable {
        case monthly, annual, lifetime
    }

    public enum RefundState: String, Equatable, Sendable {
        case idle, requested
    }

    public enum KeyStatus: String, Equatable, Sendable {
        case connected, missing, revoked
    }

    public struct Prices: Decodable, Equatable, Sendable {
        public let proMonthly: String
        public let proFirstMonth: String
        public let proYearly: String
        public let lifetime: String

        enum CodingKeys: String, CodingKey {
            case proMonthly = "pro_monthly", proFirstMonth = "pro_first_month", proYearly = "pro_yearly", lifetime
        }

        public init(proMonthly: String, proFirstMonth: String, proYearly: String, lifetime: String) {
            self.proMonthly = proMonthly
            self.proFirstMonth = proFirstMonth
            self.proYearly = proYearly
            self.lifetime = lifetime
        }
    }

    /// 이번 달(UTC) Taskforce 자체 AI 호출의 토큰 수. 참고값이고 상한이 아니다
    public struct Usage: Decodable, Equatable, Sendable {
        public let promptTokens: Int
        public let completionTokens: Int
        public let totalTokens: Int

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens", completionTokens = "completion_tokens", totalTokens = "total_tokens"
        }

        public init(promptTokens: Int, completionTokens: Int, totalTokens: Int) {
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
            self.totalTokens = totalTokens
        }
    }

    public let state: State
    public let plan: Plan?
    public let trialEndsAt: Date?
    public let currentPeriodEndsAt: Date?
    /// 해지했지만 이 시각까지 쓸 수 있다 (state cancelled)
    public let cancelAt: Date?
    /// 기존 베타 계정의 유료 전환 고지 끝. 없으면 아직 고지 전이다 (결제 요소를 보이지 않는다)
    public let noticeEndsAt: Date?
    /// 환불 요청을 받는 마지막 시각 (결제 3일 안). 지났거나 해당 없으면 nil
    public let refundUntil: Date?
    /// requested = 환불을 요청했고 제공자 확정을 기다린다 (자격은 확정 뒤에만 바뀐다)
    public let refundState: RefundState
    public let canUseAI: Bool
    public let canCheckout: Bool
    public let canBuyLifetime: Bool
    /// 지금 Pro를 시작하면 3일 무료 체험과 첫 달 할인이 붙는가 (계정당 처음 한 번)
    public let withTrial: Bool
    /// checkout 요청에 그대로 되돌려 보낼 현재 약관 판
    public let termsVersion: String
    public let prices: Prices
    public let aiUsage: Usage?
    /// 공정 사용 안전장치에 닿아 AI가 쉬는 동안, 다시 시작하는 시각. 아니면 nil
    public let fairUsePausedUntil: Date?
    public let aiKey: KeyStatus?
    /// OpenRouter가 402 · 403을 준 마지막 시각 (키는 connected 그대로, 충전하면 바로 된다). 다음 성공 호출이 지운다
    public let aiKeySpendErrorAt: Date?

    enum CodingKeys: String, CodingKey {
        case state, plan, prices
        case trialEndsAt = "trial_ends_at", currentPeriodEndsAt = "current_period_ends_at", cancelAt = "cancel_at"
        case noticeEndsAt = "notice_ends_at", refundUntil = "refund_until", refundState = "refund_state"
        case canUseAI = "can_use_ai", canCheckout = "can_checkout", canBuyLifetime = "can_buy_lifetime", withTrial = "with_trial"
        case termsVersion = "terms_version", aiUsage = "ai_usage_this_month"
        case fairUsePausedUntil = "fair_use_paused_until", aiKey = "ai_key", aiKeySpendErrorAt = "ai_key_spend_error_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 필수: 이 키들이 빠진 응답은 이 화면이 믿을 수 없다 (실패)
        state = State(rawValue: try c.decode(String.self, forKey: .state)) ?? .unknown
        prices = try c.decode(Prices.self, forKey: .prices)
        termsVersion = try c.decode(String.self, forKey: .termsVersion)
        canUseAI = try c.decode(Bool.self, forKey: .canUseAI)
        canCheckout = try c.decode(Bool.self, forKey: .canCheckout)
        canBuyLifetime = try c.decode(Bool.self, forKey: .canBuyLifetime)
        withTrial = try c.decode(Bool.self, forKey: .withTrial)
        refundState = RefundState(rawValue: try c.decode(String.self, forKey: .refundState)) ?? .idle
        // 서버가 늘 보내는 nullable 키: 없으면 null로 읽는다
        plan = try c.decodeIfPresent(String.self, forKey: .plan).flatMap(Plan.init(rawValue:))
        trialEndsAt = try c.decodeIfPresent(Date.self, forKey: .trialEndsAt)
        currentPeriodEndsAt = try c.decodeIfPresent(Date.self, forKey: .currentPeriodEndsAt)
        cancelAt = try c.decodeIfPresent(Date.self, forKey: .cancelAt)
        noticeEndsAt = try c.decodeIfPresent(Date.self, forKey: .noticeEndsAt)
        refundUntil = try c.decodeIfPresent(Date.self, forKey: .refundUntil)
        aiUsage = try c.decodeIfPresent(Usage.self, forKey: .aiUsage)
        fairUsePausedUntil = try c.decodeIfPresent(Date.self, forKey: .fairUsePausedUntil)
        aiKey = try c.decodeIfPresent(String.self, forKey: .aiKey).flatMap(KeyStatus.init(rawValue:))
        aiKeySpendErrorAt = try c.decodeIfPresent(Date.self, forKey: .aiKeySpendErrorAt)
    }

    public init(
        state: State, plan: Plan? = nil, trialEndsAt: Date? = nil, currentPeriodEndsAt: Date? = nil, cancelAt: Date? = nil, noticeEndsAt: Date? = nil,
        refundUntil: Date? = nil, refundState: RefundState = .idle, canUseAI: Bool = false, canCheckout: Bool = false, canBuyLifetime: Bool = false,
        withTrial: Bool = false, termsVersion: String = "terms-sample", prices: Prices, aiUsage: Usage? = nil, fairUsePausedUntil: Date? = nil,
        aiKey: KeyStatus? = nil, aiKeySpendErrorAt: Date? = nil
    ) {
        self.state = state
        self.plan = plan
        self.trialEndsAt = trialEndsAt
        self.currentPeriodEndsAt = currentPeriodEndsAt
        self.cancelAt = cancelAt
        self.noticeEndsAt = noticeEndsAt
        self.refundUntil = refundUntil
        self.refundState = refundState
        self.canUseAI = canUseAI
        self.canCheckout = canCheckout
        self.canBuyLifetime = canBuyLifetime
        self.withTrial = withTrial
        self.termsVersion = termsVersion
        self.prices = prices
        self.aiUsage = aiUsage
        self.fairUsePausedUntil = fairUsePausedUntil
        self.aiKey = aiKey
        self.aiKeySpendErrorAt = aiKeySpendErrorAt
    }
}

extension BillingStatusV2 {
    /// 키를 저장하거나 지운 직후, 다시 읽기 전까지 화면이 맞게 보이도록 키 상태만 바꾼 사본 (서버가 바로 뒤이어 확정한다)
    public func replacingKey(_ key: KeyStatus?, spendErrorAt: Date? = nil) -> BillingStatusV2 {
        BillingStatusV2(
            state: state, plan: plan, trialEndsAt: trialEndsAt, currentPeriodEndsAt: currentPeriodEndsAt, cancelAt: cancelAt, noticeEndsAt: noticeEndsAt,
            refundUntil: refundUntil, refundState: refundState, canUseAI: canUseAI, canCheckout: canCheckout, canBuyLifetime: canBuyLifetime,
            withTrial: withTrial, termsVersion: termsVersion, prices: prices, aiUsage: aiUsage, fairUsePausedUntil: fairUsePausedUntil,
            aiKey: key, aiKeySpendErrorAt: spendErrorAt
        )
    }
}

/// checkout을 여는 상품 (`POST /api/v2/billing/checkout`의 `plan`). 가격 · 변형 · 코드 · 돌아올 주소는 서버가 정한다
public enum PlanCheckoutKind: String, Encodable, Equatable, Sendable {
    case pro, lifetime
}

/// 포털 (`POST /api/v2/billing/portal`의 `target`): manage = 구독 관리, payment = 결제 수단 바꾸기. 둘 다 브라우저(Lemon Squeezy)로 연다
public enum PlanPortalTarget: String, Encodable, Equatable, Sendable {
    case manage, payment
}
