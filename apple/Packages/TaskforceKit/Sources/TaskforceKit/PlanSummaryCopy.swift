import Foundation

/// Plan & usage(결제)의 모든 UI 문구 한 곳 (OA 결제 PR-C, 2026-10-19 사용자 승인: `handoffs/oa-billing-dz/README.md` "사용자 승인용 새 문구" 표 + 코디네이터 결정).
/// DS 문구는 DS 미리보기 그대로이고 새 문구는 DZ 그림의 승인된 글 그대로다. 한 글자도 바꾸지 않는다 — 시험이 글자 하나하나를 고정한다.
/// 가격 · 날짜 · 토큰 수는 서버 값이다: 여기에는 숫자 상수가 없고 문장 틀만 있다 (예: "\(price) a month").
/// "unlimited" · "no limit"은 어디에도 두지 않는다 (보이지 않는 월 공정 사용 상한이 있다, 계약 20장 Q2).
public enum PlanCopy {
    // MARK: DS (승인됨)

    public static let sectionTitle = "Plan & usage"
    public static let planLabel = "Plan"
    public static let noPlan = "No plan"
    public static let pro = "Pro"
    public static let startTrial = "Start 3-day free trial"
    public static let trialPlan = "Pro · Trial"
    public static let trialEnds = "Trial ends"
    public static let firstCharge = "First charge"
    public static let manageSubscription = "Manage subscription"
    public static let renews = "Renews"
    public static let aiUsage = "AI usage this month"
    public static let requestRefundRow = "Request refund"
    public static let requestRefundAction = "Request…"
    public static let askRefundTitle = "Request a refund?"
    public static let requestRefundConfirm = "Request refund"
    public static let refundProBody = "Pro ends when the refund is issued."
    public static let refundRequestedTitle = "Refund requested"
    public static let refundRequestedBody = "Lemon Squeezy confirms it by email, usually within a day."
    public static let refundIssuedTitle = "Refund issued"
    public static let refundIssuedProBody = "Pro ends now. Your lists, results and sources stay available."
    public static let cancelledPlan = "Pro · Cancelled"
    public static let availableUntil = "Available until"
    public static let resumePro = "Resume Pro"
    public static let resume = "Resume"
    public static let paymentFailedTitle = "Payment failed"
    public static let paymentFailedBody = "AI and execution keep running while you update it."
    public static let updatePayment = "Update payment method"
    public static let paymentDue = "Payment due"
    public static let endedTitle = "Pro ended · AI and execution paused"
    public static let endedBody = "Your lists, results and sources stay available."
    public static let restartPro = "Restart Pro"
    public static let noActivePlan = "No active plan"
    public static let ended = "Ended"
    public static let lifetime = "Lifetime"
    public static let beta = "Beta"
    public static let openRouter = "OpenRouter"
    public static let key = "Key"
    public static let keyBilled = "Billed to your OpenRouter account"
    public static let connected = "Connected"
    public static let missing = "Missing"
    public static let revoked = "Revoked"
    public static let addKey = "Add key"
    public static let replaceKey = "Replace key"
    public static let save = "Save"
    public static let cancel = "Cancel"
    public static let trialFootnote = "Cancel before the trial ends and you are not charged."
    public static let proFootnote = "Claude Code usage is billed to your own Claude plan, not to Pro."
    public static let lapsedFootnote = "Lists, results and sources stay. AI and execution start again when you restart Pro."
    public static let openRouterFootnote = "Your key is sent to Taskforce's server and kept there, not on this Mac. Model usage is billed to your OpenRouter account."
    /// DS SignIn의 법률 문장 (링크 "Terms" · "Privacy Policy")
    public static let legalLead = "By continuing you agree to the "
    public static let terms = "Terms"
    public static let legalAnd = " and "
    public static let privacyPolicy = "Privacy Policy"

    // MARK: DS 문구를 숨은 월 상한에 맞춰 줄인 것 (Q2)

    /// DS: "For reference. Pro has no limit."
    public static let usageDetail = "For reference."
    /// DS: "…Pro adds AI and execution, with no usage limit."
    public static let noPlanFootnote = "Manual lists, existing results and sources stay available without a plan. Pro adds AI and execution."

    // MARK: 새 문구 (승인됨)

    public static let startPro = "Start Pro"
    public static let buyLifetime = "Buy Lifetime"
    public static let proTaxLine = "Renews until you cancel. Tax may apply."
    public static let lifetimeTaxLine = "One payment. Tax may apply."
    public static let legalTrail = ". You must be 14 or older and not in the EEA or UK."
    public static let claudeCodeLine = "Claude Code usage is billed to your own Claude plan."
    public static let lifetimeRefundBody = "Lifetime ends when the refund is issued."
    public static let refundIssuedLifetimeBody = "Lifetime ends now. Your lists, results and sources stay available."
    public static let removeKeyRow = "Remove key"
    public static let removeKeyAction = "Remove…"
    public static let removeKeyTitle = "Remove your OpenRouter key?"
    public static let removeKeyBody = "AI and execution stop until you add a key. Your lists, results and sources stay."
    public static let removeKeyConfirm = "Remove"
    public static let keyInvalid = "This key doesn't work. Check it in OpenRouter."
    public static let keyManagement = "Use a regular API key."
    public static let openRouterCantPayTitle = "OpenRouter can't pay for requests"
    public static let openRouterCantPayBody = "Add credits or raise this key's limit in OpenRouter."
    public static let openRouterZeroRetention = "Taskforce still asks for zero data retention. Logging settings in your OpenRouter account are yours."
    public static let fairUseProBody = "This account reached Pro's monthly fair-use limit."
    public static let fairUseTrialBody = "This account reached the trial's fair-use limit."
    /// 실행 줄(`RunLaneText`)의 한 줄: N11 본문에서 "Pro's monthly"를 뺀 것 (플랜을 모르는 자리, 새 문구 확인 필요)
    public static let fairUseLimit = "This account reached the fair-use limit."
    public static let checkoutFailed = "Couldn't open checkout. Try again in a moment."
    public static let checking = "Checking…"
    /// 앱에 이미 있는 문장 (`APIError.userMessage`): Plan & usage를 못 읽었을 때 · 키 저장 통신 실패 · 환불 · 다시 시작 · 포털 실패
    public static let somethingWentWrong = "Something went wrong. Try again in a moment."
    /// N12 · N13: 앱 오류 문장 (알림 · 실행 줄, 그림 없음)
    public static let planEnded = "Your plan has ended. Restart Pro in Settings → Account → Plan & usage."
    public static let keyRequired = "Add your OpenRouter key in Settings → Account → Plan & usage."

    // MARK: 문장 틀 (값은 서버 · 시각)

    /// "AI paused until Nov 1"
    public static func fairUseTitle(_ date: String) -> String { "AI paused until \(date)" }
    /// 값 "Beta · until Nov 20"
    public static func betaUntil(_ date: String) -> String { "Beta · until \(date)" }
    public static func available(until date: String) -> String { "\(availableUntil) \(date)" }
    /// "Pro · Monthly · $12.99 a month"
    public static func proPlan(_ cadence: String?, price: String?, unit: String?) -> String {
        ["Pro", cadence, price.flatMap { price in unit.map { "\(price) a \($0)" } }].compactMap { $0 }.joined(separator: " · ")
    }
    /// 설명 "$12.99 a month, first month $6.99 · or $119.88 a year" (체험을 쓴 계정은 첫 달 구절 없음)
    public static func proOffer(monthly: String, firstMonth: String, yearly: String, withTrial: Bool) -> String {
        withTrial ? "\(monthly) a month, first month \(firstMonth) · or \(yearly) a year" : "\(monthly) a month · or \(yearly) a year"
    }
    /// 설명 "$229 once · model usage billed to your OpenRouter account"
    public static func lifetimeOffer(_ price: String) -> String { "\(price) once · model usage billed to your OpenRouter account" }
    /// "First charge" 값: "Oct 22 · $6.99"
    public static func firstChargeValue(date: String, price: String) -> String { "\(date) · \(price)" }
    /// 두 번째 줄 "Renews Nov 8" 같은 요약 (Usage & Credits › Your plan)
    public static func summary(_ label: String, _ date: String) -> String { "\(label) \(date)" }

    // MARK: Execution › Spending outside Taskforce (DS ExternalCosts, 새 문구 없음)

    public static let spendingTitle = "Spending outside Taskforce"
    public static let spendingClaudeCode = "Claude Code"
    public static let spendingBilledTo = "Billed to your Claude plan"
    public static let spendingNotShared = "Not shared"
    public static let spendingFootnote = "Not shared means the service doesn't tell Taskforce the amount. It isn't zero. This spending stays with each service and is never added to your plan."

    // MARK: 눈에 띄는 이름 (접근성 · 칸)

    /// 키 칸의 자리 글 (DS TextField placeholder)과 화면 읽기 이름 (칸 위에 보이지 않는다)
    public static let keyPlaceholder = "sk-or-…"
    public static let keyFieldName = "OpenRouter key"
}
