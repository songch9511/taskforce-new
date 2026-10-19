import Foundation

/// 옛 v1 상태 읽기 (`GET /api/v1/billing`, 동결). 새 Plan & usage 화면은 이것을 쓰지 않는다: v2 `BillingStatusV2`가 그린다.
/// 남아 있는 쓰임은 `validatedURL`(checkout · 포털 주소 검사)과 옛 견본 시험의 v1 읽기뿐이다. 서버는 새 상태를 옛 말로 옮겨 내린다.
public struct BillingSummary: Decodable, Sendable {
    public let status: String
    public let plan: String?
    public let trialEndsAt: String?
    public let currentPeriodEndsAt: String?
    public let canUseAI: Bool
    public let canCheckout: Bool
    public let aiAllowance: AiSpendSummary?
    public let allowanceResetsAt: String?

    enum CodingKeys: String, CodingKey {
        case status, plan
        case trialEndsAt = "trial_ends_at", currentPeriodEndsAt = "current_period_ends_at"
        case canUseAI = "can_use_ai", canCheckout = "can_checkout"
        case aiAllowance = "ai_allowance", allowanceResetsAt = "allowance_resets_at"
    }

    public var label: String {
        switch status {
        case "legacy_beta": "Free beta access"
        case "active": plan == "annual" ? "Yearly subscription" : "Monthly subscription"
        case "cancelled": "Cancelled — access until period ends"
        case "past_due", "unpaid": "Payment required"
        case "paused": "Subscription paused"
        case "refunded": "Payment refunded"
        case "deleting": "Account deletion in progress"
        default: "Subscription required for AI processing"
        }
    }

    public static func validatedURL(_ url: URL) throws -> URL {
        guard url.scheme == "https", let host = url.host,
              host.hasSuffix(".lemonsqueezy.com"), url.user == nil, url.password == nil else {
            throw URLError(.badURL)
        }
        return url
    }
}
