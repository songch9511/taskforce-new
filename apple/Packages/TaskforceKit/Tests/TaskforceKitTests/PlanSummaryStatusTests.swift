import Foundation
import Testing
@testable import TaskforceKit

/// `GET /api/v2/billing` 읽기 (OA 결제 계약 16.4): 모르는 state는 안전하게 · 남는 키는 무시 · 빠진 필수 키는 실패
struct PlanSummaryStatusTests {
    @Test func aFullProResponseDecodesEveryField() throws {
        let value = try PlanFixtures.decode(PlanFixtures.json(
            state: "pro", plan: "monthly", periodEndsAt: "2026-11-08T00:00:00Z", refundUntil: "2026-10-23T12:00:00.123Z", canUseAI: true,
            usage: #"{"since":"2026-10-01T00:00:00Z","prompt_tokens":1000000,"completion_tokens":1400000,"total_tokens":2400000}"#
        ))
        #expect(value.state == .pro && value.plan == .monthly && value.canUseAI)
        #expect(value.currentPeriodEndsAt == PlanFixtures.at("2026-11-08T00:00:00Z"))
        #expect(value.refundUntil != nil && value.refundState == .idle)
        #expect(value.aiUsage == BillingStatusV2.Usage(promptTokens: 1_000_000, completionTokens: 1_400_000, totalTokens: 2_400_000))
        #expect(value.prices == PlanFixtures.prices && value.termsVersion == "terms-2026-test")
        #expect(value.aiKey == nil && value.fairUsePausedUntil == nil && value.noticeEndsAt == nil)
    }

    @Test(arguments: [
        ("none", BillingStatusV2.State.none), ("trial", .trial), ("pro", .pro), ("cancelled", .cancelled), ("past_due", .pastDue),
        ("lapsed", .lapsed), ("lifetime", .lifetime), ("beta", .beta),
    ])
    func everyServerStateIsKnown(_ raw: String, _ expected: BillingStatusV2.State) throws {
        #expect(try PlanFixtures.decode(PlanFixtures.json(state: raw)).state == expected)
    }

    @Test func anUnknownStateDecodesAsUnknownInsteadOfFailing() throws {
        #expect(try PlanFixtures.decode(PlanFixtures.json(state: "paused_forever")).state == .unknown)
        // legacy_beta는 v1의 말이다: v2에는 없다
        #expect(try PlanFixtures.decode(PlanFixtures.json(state: "legacy_beta")).state == .unknown)
    }

    @Test func unknownPlanKeyAndRefundValuesReadAsTheSafeSide() throws {
        let value = try PlanFixtures.decode(PlanFixtures.json(state: "lifetime", plan: "weekly", refundState: "someday", aiKey: "expired"))
        #expect(value.plan == nil && value.refundState == .idle && value.aiKey == nil)
    }

    @Test(arguments: ["connected", "missing", "revoked"])
    func theThreeKeyStates(_ raw: String) throws {
        #expect(try PlanFixtures.decode(PlanFixtures.json(state: "lifetime", aiKey: raw)).aiKey?.rawValue == raw)
    }

    @Test func extraKeysAreIgnored() throws {
        var json = PlanFixtures.json(state: "none")
        json.removeLast()
        json += #","future_field":{"a":1},"another":[1,2]}"#
        #expect(try PlanFixtures.decode(json).state == .none)
    }

    @Test(arguments: ["state", "prices", "terms_version", "can_use_ai", "can_checkout", "can_buy_lifetime", "with_trial", "refund_state"])
    func aMissingRequiredKeyFails(_ key: String) throws {
        let object = try #require(try JSONSerialization.jsonObject(with: Data(PlanFixtures.json().utf8)) as? [String: Any])
        var broken = object
        broken[key] = nil
        let data = try JSONSerialization.data(withJSONObject: broken)
        #expect(throws: DecodingError.self) { try TaskforceJSON.decoder().decode(BillingStatusV2.self, from: data) }
    }

    @Test func aMissingPriceKeyFails() throws {
        var object = try #require(try JSONSerialization.jsonObject(with: Data(PlanFixtures.json().utf8)) as? [String: Any])
        object["prices"] = ["pro_monthly": "$12.99", "pro_yearly": "$119.88", "lifetime": "$229"]
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) { try TaskforceJSON.decoder().decode(BillingStatusV2.self, from: data) }
    }

    @Test func nullableKeysThatAreAbsentReadAsNull() throws {
        var object = try #require(try JSONSerialization.jsonObject(with: Data(PlanFixtures.json(state: "beta").utf8)) as? [String: Any])
        for key in ["plan", "trial_ends_at", "current_period_ends_at", "cancel_at", "notice_ends_at", "refund_until", "ai_usage_this_month", "fair_use_paused_until", "ai_key", "ai_key_spend_error_at"] {
            object[key] = nil
        }
        let value = try TaskforceJSON.decoder().decode(BillingStatusV2.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(value.state == .beta && value.plan == nil && value.noticeEndsAt == nil && value.aiUsage == nil)
    }

    @Test func replacingTheKeyChangesOnlyTheKey() throws {
        let original = PlanFixtures.status(.lifetime, refundUntil: "2026-10-22T12:00:00Z", aiKey: .missing, spendError: "2026-10-19T00:00:00Z")
        let saved = original.replacingKey(.connected)
        #expect(saved.aiKey == .connected && saved.aiKeySpendErrorAt == nil)
        #expect(saved.refundUntil == original.refundUntil && saved.state == original.state && saved.prices == original.prices && saved.termsVersion == original.termsVersion)
    }
}
