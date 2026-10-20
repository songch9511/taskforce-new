import Foundation
@testable import TaskforceKit

/// Plan & usage 시험이 같이 쓰는 값. 가격 · 날짜는 시험용 표본이다 (앱 소스에는 이런 숫자가 없다: 서버가 내린다)
enum PlanFixtures {
    static let now = PostgresTimestamp.parse("2026-10-20T12:00:00Z")!

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    static let prices = BillingStatusV2.Prices(proMonthly: "$12.99", proFirstMonth: "$6.99", proYearly: "$119.88", lifetime: "$229")

    static func at(_ iso: String) -> Date { PostgresTimestamp.parse(iso)! }

    /// 서버 `GET /api/v2/billing`이 내리는 JSON (모든 키가 있다). 값이 `nil`이면 null
    static func json(
        state: String = "none", plan: String? = nil, trialEndsAt: String? = nil, periodEndsAt: String? = nil, cancelAt: String? = nil,
        noticeEndsAt: String? = nil, refundUntil: String? = nil, refundState: String = "idle", canUseAI: Bool = false, canCheckout: Bool = false,
        canBuyLifetime: Bool = false, withTrial: Bool = false, usage: String? = nil, fairUse: String? = nil, aiKey: String? = nil, spendError: String? = nil
    ) -> String {
        func string(_ value: String?) -> String { value.map { "\"\($0)\"" } ?? "null" }
        return """
        {"state":"\(state)","plan":\(string(plan)),"trial_ends_at":\(string(trialEndsAt)),"current_period_ends_at":\(string(periodEndsAt)),
        "cancel_at":\(string(cancelAt)),"notice_ends_at":\(string(noticeEndsAt)),"refund_until":\(string(refundUntil)),"refund_state":"\(refundState)",
        "can_use_ai":\(canUseAI),"can_checkout":\(canCheckout),"can_buy_lifetime":\(canBuyLifetime),"with_trial":\(withTrial),"terms_version":"terms-2026-test",
        "prices":{"pro_monthly":"$12.99","pro_first_month":"$6.99","pro_yearly":"$119.88","lifetime":"$229"},
        "ai_usage_this_month":\(usage ?? "null"),"fair_use_paused_until":\(string(fairUse)),"ai_key":\(string(aiKey)),"ai_key_spend_error_at":\(string(spendError))}
        """
    }

    static func decode(_ json: String) throws -> BillingStatusV2 {
        try TaskforceJSON.decoder().decode(BillingStatusV2.self, from: Data(json.utf8))
    }

    static func status(
        _ state: BillingStatusV2.State, plan: BillingStatusV2.Plan? = nil, trialEndsAt: String? = nil, periodEndsAt: String? = nil, cancelAt: String? = nil,
        noticeEndsAt: String? = nil, refundUntil: String? = nil, refundState: BillingStatusV2.RefundState = .idle, canCheckout: Bool = false,
        canBuyLifetime: Bool = false, withTrial: Bool = false, tokens: Int? = nil, fairUse: String? = nil, aiKey: BillingStatusV2.KeyStatus? = nil, spendError: String? = nil
    ) -> BillingStatusV2 {
        BillingStatusV2(
            state: state, plan: plan, trialEndsAt: trialEndsAt.map(at), currentPeriodEndsAt: periodEndsAt.map(at), cancelAt: cancelAt.map(at),
            noticeEndsAt: noticeEndsAt.map(at), refundUntil: refundUntil.map(at), refundState: refundState, canUseAI: true, canCheckout: canCheckout,
            canBuyLifetime: canBuyLifetime, withTrial: withTrial, termsVersion: "terms-2026-test", prices: prices,
            aiUsage: tokens.map { BillingStatusV2.Usage(promptTokens: $0 / 2, completionTokens: $0 - $0 / 2, totalTokens: $0) },
            fairUsePausedUntil: fairUse.map(at), aiKey: aiKey, aiKeySpendErrorAt: spendError.map(at)
        )
    }

    static func make(_ status: BillingStatusV2?, _ edit: (inout PlanSummaryInput) -> Void = { _ in }) -> PlanSummaryState {
        var input = PlanSummaryInput(status: status, now: now, calendar: calendar)
        edit(&input)
        return .make(input)
    }

    /// 몇몇 시험이 쓰는 대표 상태
    static let none = status(.none, canCheckout: true, canBuyLifetime: true, withTrial: true)
    static let pro = status(.pro, plan: .monthly, periodEndsAt: "2026-11-08T00:00:00Z", refundUntil: "2026-10-23T12:00:00Z", tokens: 2_400_000)
    static let lifetime = status(.lifetime, refundUntil: "2026-10-22T12:00:00Z", aiKey: .connected)
}

extension PlanSummaryState {
    func row(_ id: String) -> Row? { rows.first { $0.id == id } }

    /// 화면에 보이는 모든 글 (줄 · 값 · 보조 글 · 버튼 · 확인 · Notice · 각주)
    var allText: [String] {
        var out: [String] = []
        if let notice {
            out += [notice.title] + [notice.message].compactMap { $0 } + [notice.button?.title].compactMap { $0 }
        }
        for section in sections {
            out += [section.title].compactMap { $0 } + [section.empty].compactMap { $0 }
            out += (section.footnote?.paragraphs ?? [])
            for row in section.rows {
                out += [row.label] + row.detail
                switch row.control {
                case .none, .opens: break
                case .value(let value, _): out.append(value)
                case .button(let button): out.append(button.title)
                case .keyField(let save): out.append(save.title)
                case .confirm(let confirm): out += [confirm.title, confirm.detail, confirm.confirmTitle]
                }
            }
        }
        out += [compact.label] + [compact.detail].compactMap { $0 }
        return out
    }
}
