import Foundation
import Testing
@testable import TaskforceKit

/// Plan & usage의 문구는 승인된 글자 그대로다 (2026-10-19 사용자 승인: `handoffs/oa-billing-dz/README.md` "사용자 승인용 새 문구" 표 + 계약 9.6 끝 목록의 DS 문구).
/// 이 목록은 상수에서 뽑지 않고 손으로 적었다: 한 글자라도 다르면 깨진다
struct PlanSummaryCopyTests {
    typealias C = PlanCopy

    @Test func theDesignSystemStringsAreExactlyTheDesignSystemText() {
        #expect(C.sectionTitle == "Plan & usage" && C.planLabel == "Plan" && C.noPlan == "No plan" && C.pro == "Pro")
        #expect(C.startTrial == "Start 3-day free trial" && C.trialPlan == "Pro · Trial" && C.trialEnds == "Trial ends" && C.firstCharge == "First charge")
        #expect(C.manageSubscription == "Manage subscription" && C.renews == "Renews" && C.aiUsage == "AI usage this month")
        #expect(C.requestRefundRow == "Request refund" && C.requestRefundAction == "Request…" && C.askRefundTitle == "Request a refund?" && C.requestRefundConfirm == "Request refund")
        #expect(C.refundProBody == "Pro ends when the refund is issued.")
        #expect(C.refundRequestedTitle == "Refund requested" && C.refundRequestedBody == "Lemon Squeezy confirms it by email, usually within a day.")
        #expect(C.refundIssuedTitle == "Refund issued" && C.refundIssuedProBody == "Pro ends now. Your lists, results and sources stay available.")
        #expect(C.cancelledPlan == "Pro · Cancelled" && C.availableUntil == "Available until" && C.resumePro == "Resume Pro" && C.resume == "Resume")
        #expect(C.paymentFailedTitle == "Payment failed" && C.paymentFailedBody == "AI and execution keep running while you update it." && C.updatePayment == "Update payment method" && C.paymentDue == "Payment due")
        #expect(C.endedTitle == "Pro ended · AI and execution paused" && C.endedBody == "Your lists, results and sources stay available." && C.restartPro == "Restart Pro")
        #expect(C.noActivePlan == "No active plan" && C.ended == "Ended" && C.lifetime == "Lifetime" && C.beta == "Beta")
        #expect(C.openRouter == "OpenRouter" && C.key == "Key" && C.keyBilled == "Billed to your OpenRouter account")
        #expect(C.connected == "Connected" && C.missing == "Missing" && C.revoked == "Revoked" && C.addKey == "Add key" && C.replaceKey == "Replace key" && C.save == "Save" && C.cancel == "Cancel")
        #expect(C.trialFootnote == "Cancel before the trial ends and you are not charged.")
        #expect(C.proFootnote == "Claude Code usage is billed to your own Claude plan, not to Pro.")
        #expect(C.lapsedFootnote == "Lists, results and sources stay. AI and execution start again when you restart Pro.")
        #expect(C.openRouterFootnote == "Your key is sent to Taskforce's server and kept there, not on this Mac. Model usage is billed to your OpenRouter account.")
        #expect(C.legalLead == "By continuing you agree to the " && C.terms == "Terms" && C.legalAnd == " and " && C.privacyPolicy == "Privacy Policy")
        #expect(C.spendingTitle == "Spending outside Taskforce" && C.spendingClaudeCode == "Claude Code" && C.spendingBilledTo == "Billed to your Claude plan" && C.spendingNotShared == "Not shared")
        #expect(C.spendingFootnote == "Not shared means the service doesn't tell Taskforce the amount. It isn't zero. This spending stays with each service and is never added to your plan.")
    }

    @Test func theNewApprovedStringsAreExactlyTheApprovedText() {
        // N1 · N2 · N3 (쪼갠 줄) · N4
        #expect(C.lifetimeOffer("$229") == "$229 once · model usage billed to your OpenRouter account" && C.buyLifetime == "Buy Lifetime")
        #expect(C.startPro == "Start Pro")
        #expect(C.proTaxLine == "Renews until you cancel. Tax may apply." && C.lifetimeTaxLine == "One payment. Tax may apply.")
        #expect(C.legalTrail == ". You must be 14 or older and not in the EEA or UK.")
        #expect(C.claudeCodeLine == "Claude Code usage is billed to your own Claude plan.")
        // Q2: DS 문장을 숨은 월 상한에 맞춰 줄임
        #expect(C.usageDetail == "For reference.")
        #expect(C.noPlanFootnote == "Manual lists, existing results and sources stay available without a plan. Pro adds AI and execution.")
        // N5 · N6 · N7
        #expect(C.betaUntil("Nov 20") == "Beta · until Nov 20")
        #expect(C.lifetimeRefundBody == "Lifetime ends when the refund is issued." && C.refundIssuedLifetimeBody == "Lifetime ends now. Your lists, results and sources stay available.")
        #expect(C.removeKeyRow == "Remove key" && C.removeKeyAction == "Remove…" && C.removeKeyTitle == "Remove your OpenRouter key?")
        #expect(C.removeKeyBody == "AI and execution stop until you add a key. Your lists, results and sources stay." && C.removeKeyConfirm == "Remove")
        // N8 · N9 · N10 · N11 · N14
        #expect(C.keyInvalid == "This key doesn't work. Check it in OpenRouter." && C.keyManagement == "Use a regular API key.")
        #expect(C.openRouterCantPayTitle == "OpenRouter can't pay for requests" && C.openRouterCantPayBody == "Add credits or raise this key's limit in OpenRouter.")
        #expect(C.openRouterZeroRetention == "Taskforce still asks for zero data retention. Logging settings in your OpenRouter account are yours.")
        #expect(C.fairUseTitle("Nov 1") == "AI paused until Nov 1")
        #expect(C.fairUseProBody == "This account reached Pro's monthly fair-use limit." && C.fairUseTrialBody == "This account reached the trial's fair-use limit.")
        #expect(C.checkoutFailed == "Couldn't open checkout. Try again in a moment.")
        #expect(C.checking == "Checking…")
        // N12 · N13 (앱 오류)
        #expect(C.planEnded == "Your plan has ended. Restart Pro in Settings → Account → Plan & usage.")
        #expect(C.keyRequired == "Add your OpenRouter key in Settings → Account → Plan & usage.")
    }

    @Test func sentencesWithValuesTakeThemFromTheServerNotFromConstants() {
        #expect(C.proOffer(monthly: "$1", firstMonth: "$2", yearly: "$3", withTrial: true) == "$1 a month, first month $2 · or $3 a year")
        #expect(C.proOffer(monthly: "$1", firstMonth: "$2", yearly: "$3", withTrial: false) == "$1 a month · or $3 a year", "체험을 쓴 계정에는 첫 달 구절이 없다")
        #expect(C.proPlan("Monthly", price: "$1", unit: "month") == "Pro · Monthly · $1 a month")
        #expect(C.proPlan("Yearly", price: "$3", unit: "year") == "Pro · Yearly · $3 a year")
        #expect(C.proPlan("Monthly", price: nil, unit: nil) == "Pro · Monthly" && C.proPlan(nil, price: nil, unit: nil) == "Pro")
        #expect(C.firstChargeValue(date: "Oct 22", price: "$4") == "Oct 22 · $4")
        #expect(C.available(until: "Oct 11") == "Available until Oct 11")
    }

    /// 계약 5.1 Q2: 보이지 않는 월 상한이 있으니 "unlimited" · "no limit"은 어디에도 없다
    @Test func noWordClaimsUnlimitedUse() {
        for text in Self.every {
            let lower = text.lowercased()
            #expect(!lower.contains("unlimited") && !lower.contains("no limit") && !lower.contains("no usage limit"), "\(text)")
        }
    }

    /// 두 창이 같은 문구를 쓴다: 그 문구에 가격 숫자 · 날짜 상수가 없다 (문장 틀은 값을 서버에서 받는다)
    @Test func theCopyFileHasNoPriceOrDateConstants() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../Sources/TaskforceKit/PlanSummaryCopy.swift").standardized, encoding: .utf8)
        let code = source.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        // 문자열 글자 속만 본다 (`$0`은 클로저 인자, 보간 `\(...)`은 값이 들어오는 자리)
        let stringLiterals = code.matches(of: /"(?:[^"\\]|\\.)*"/).map { String($0.0) }
        let literals = stringLiterals.map { $0.replacingOccurrences(of: #"\\\([^)]*\)"#, with: "", options: .regularExpression) }.joined(separator: "\n")
        #expect(literals.range(of: #"\$\d"#, options: .regularExpression) == nil, "달러 숫자 상수 0")
        #expect(code.range(of: #"\b(2026|2027)\b"#, options: .regularExpression) == nil)
        #expect(!code.contains("9.99") && !code.contains("101.90") && !code.contains("12.99") && !code.contains("119.88") && !code.contains("6.99"))
    }

    @Test func theOldDollarNineCopyIsGone() {
        let removed = [
            "Subscribe monthly — $9.99 / month", "Subscribe yearly — $101.90 / year · Save 15%", "Payment starts immediately at checkout, including during your trial",
            "Plans include $3 of AI processing", "7-day trial starts with your first source sync", "7-day free trial", "AI allowance remaining",
            "Total trial allowance · no recurring reset", "Cumulative beta allowance · no scheduled reset",
        ]
        for text in Self.every + BillingSummary.sampleLabels {
            for old in removed { #expect(!text.contains(old), "\(old) in \(text)") }
        }
    }

    /// 쓰이는 모든 문구 (상수 + 값을 끼운 문장 틀)
    static var every: [String] {
        let c = PlanCopy.self
        return [
            c.sectionTitle, c.planLabel, c.noPlan, c.pro, c.startTrial, c.trialPlan, c.trialEnds, c.firstCharge, c.manageSubscription, c.renews, c.aiUsage,
            c.requestRefundRow, c.requestRefundAction, c.askRefundTitle, c.requestRefundConfirm, c.refundProBody, c.refundRequestedTitle, c.refundRequestedBody,
            c.refundIssuedTitle, c.refundIssuedProBody, c.cancelledPlan, c.availableUntil, c.resumePro, c.resume, c.paymentFailedTitle, c.paymentFailedBody,
            c.updatePayment, c.paymentDue, c.endedTitle, c.endedBody, c.restartPro, c.noActivePlan, c.ended, c.lifetime, c.beta, c.openRouter, c.key, c.keyBilled,
            c.connected, c.missing, c.revoked, c.addKey, c.replaceKey, c.save, c.cancel, c.trialFootnote, c.proFootnote, c.lapsedFootnote, c.openRouterFootnote,
            c.usageDetail, c.noPlanFootnote, c.startPro, c.buyLifetime, c.proTaxLine, c.lifetimeTaxLine, c.legalTrail, c.claudeCodeLine, c.lifetimeRefundBody,
            c.refundIssuedLifetimeBody, c.removeKeyRow, c.removeKeyAction, c.removeKeyTitle, c.removeKeyBody, c.removeKeyConfirm, c.keyInvalid, c.keyManagement,
            c.openRouterCantPayTitle, c.openRouterCantPayBody, c.openRouterZeroRetention, c.fairUseProBody, c.fairUseTrialBody, c.fairUseLimit, c.checkoutFailed,
            c.checking, c.somethingWentWrong, c.planEnded, c.keyRequired, c.spendingTitle, c.spendingClaudeCode, c.spendingBilledTo, c.spendingNotShared,
            c.spendingFootnote, c.keyPlaceholder, c.keyFieldName,
            c.proOffer(monthly: "$m", firstMonth: "$f", yearly: "$y", withTrial: true), c.lifetimeOffer("$l"), c.fairUseTitle("d"), c.betaUntil("d"),
        ]
    }
}

extension BillingSummary {
    /// 옛 v1 읽기의 모든 라벨 (옛 7일 체험 문구가 남지 않았는지 본다)
    static var sampleLabels: [String] {
        ["legacy_beta", "trial_pending", "trialing", "active", "cancelled", "past_due", "paused", "refunded", "deleting", "weird"].compactMap { status in
            let json = #"{"status":"\#(status)","plan":null,"can_use_ai":true,"can_checkout":false}"#
            return (try? JSONDecoder().decode(BillingSummary.self, from: Data(json.utf8)))?.label
        }
    }
}
