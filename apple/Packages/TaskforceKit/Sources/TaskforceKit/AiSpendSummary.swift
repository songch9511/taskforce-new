import Foundation

/// Cumulative supplier USD for this beta period, separate from execution credits.
public struct AiSpendSummary: Decodable, Equatable, Sendable {
    public let capUSD: Decimal
    public let confirmedUSD: Decimal
    public let reservedUSD: Decimal
    public let pendingCount: Int
    public let remainingUSD: Decimal
    public let status: String

    enum CodingKeys: String, CodingKey {
        case capUSD = "cap_usd", confirmedUSD = "confirmed_usd", reservedUSD = "reserved_usd"
        case pendingCount = "pending_count", remainingUSD = "remaining_usd", status
    }

    public static let explanation = "AI processing is included in your plan, separately from execution credits. See Account for your trial or subscription. Paid plans reset their allowance each UTC calendar month; free legacy beta access retains its original cumulative allowance. The verified worst-case amount stays reserved until the provider confirms the cost. A reservation is an upper bound, not confirmed spend. No automatic overage charges."
    public var notice: String? {
        switch status {
        case "exhausted": "Your AI allowance is fully spent or reserved. You can still manage saved tasks and connections."
        case "provider_bound_violation": "AI is paused because a provider exceeded its reserved cost."
        default: nil
        }
    }
    public static func dollars(_ value: Decimal) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(2...6)))
    }
}
