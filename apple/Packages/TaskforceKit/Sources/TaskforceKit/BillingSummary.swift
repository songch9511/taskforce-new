import Foundation

public enum BillingPlan: String, Encodable, Sendable {
    case monthly, annual
}

/// Display only. The server independently checks entitlement before every AI operation.
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
        case "trial_pending": "7-day trial starts with your first source sync"
        case "trialing": "7-day free trial"
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
