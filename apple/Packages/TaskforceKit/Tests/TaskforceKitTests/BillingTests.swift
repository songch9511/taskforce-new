import Foundation
import Testing
@testable import TaskforceKit

/// 결제 v2 길 (OA 결제 계약 8장 · 16.4): 경로 · 메서드 · Bearer · 본문 · URL 검사. 실제 서버 · Lemon Squeezy는 없다
struct BillingTests {
    @Test func statusIsAnAuthenticatedV2Read() async throws {
        let fixture = APIClientExecutionTests()
        let value = try await fixture.client(body: PlanFixtures.json(state: "pro", plan: "monthly", periodEndsAt: "2026-11-08T00:00:00Z", canUseAI: true)).billingStatus()
        #expect(value.state == .pro && value.plan == .monthly && value.prices.proMonthly == "$12.99")
        #expect(fixture.last?.url.path == "/api/v2/billing")
        #expect(fixture.last?.method == "GET")
        #expect(fixture.last?.headers["Authorization"] == "Bearer token-123")
    }

    @Test func aStatusThatCannotBeReadIsADecodingError() async throws {
        let fixture = APIClientExecutionTests()
        await #expect(throws: APIError.self) { try await fixture.client(body: #"{"state":"pro"}"#).billingStatus() }
    }

    @Test(arguments: [(PlanCheckoutKind.pro, "pro"), (.lifetime, "lifetime")])
    func checkoutSendsOnlyTheProductAndTheTermsVersionItWasToldAndReturnsAVerifiedAddress(_ kind: PlanCheckoutKind, _ raw: String) async throws {
        let fixture = APIClientExecutionTests()
        let url = try await fixture.client(body: #"{"url":"https://taskforcelabs.lemonsqueezy.com/checkout/buy/x"}"#).billingCheckout(plan: kind, termsVersion: "terms-2026-test")
        #expect(url.host == "taskforcelabs.lemonsqueezy.com")
        #expect(fixture.last?.url.path == "/api/v2/billing/checkout" && fixture.last?.method == "POST")
        #expect(fixture.last?.headers["Authorization"] == "Bearer token-123")
        let body = try #require(fixture.last?.body)
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(sent == ["plan": raw, "terms_version": "terms-2026-test"], "가격 · 변형 · 코드 · 주소는 보내지 않는다")
    }

    @Test(arguments: ["http://taskforcelabs.lemonsqueezy.com/checkout", "https://lemonsqueezy.com.evil.test/checkout", "https://evil.test/", "https://user:secret@taskforcelabs.lemonsqueezy.com/checkout", "javascript:alert(1)"])
    func rejectsUnsafePaymentURL(_ raw: String) async throws {
        let url = try #require(URL(string: raw))
        #expect(throws: URLError.self) { try BillingSummary.validatedURL(url) }
        // 서버가 그런 주소를 내려도 열지 않는다 (checkout · 포털 둘 다)
        let fixture = APIClientExecutionTests()
        let json = #"{"url":"\#(raw)"}"#
        await #expect(throws: URLError.self) { try await fixture.client(body: json).billingCheckout(plan: .pro, termsVersion: "t") }
        await #expect(throws: URLError.self) { try await fixture.client(body: json).billingPortal(target: .manage) }
    }

    @Test(arguments: [(PlanPortalTarget.manage, "manage"), (.payment, "payment")])
    func portalSendsTheTargetOnly(_ target: PlanPortalTarget, _ raw: String) async throws {
        let fixture = APIClientExecutionTests()
        let url = try await fixture.client(body: #"{"url":"https://taskforcelabs.lemonsqueezy.com/billing"}"#).billingPortal(target: target)
        #expect(url.host == "taskforcelabs.lemonsqueezy.com")
        #expect(fixture.last?.url.path == "/api/v2/billing/portal" && fixture.last?.method == "POST")
        #expect(fixture.last?.headers["Authorization"] == "Bearer token-123")
        let body = try #require(fixture.last?.body)
        #expect(try JSONSerialization.jsonObject(with: body) as? [String: String] == ["target": raw])
    }

    @Test func resumeAndRefundArePostsWithoutABodyAndNeedTheRequestedAnswer() async throws {
        let fixture = APIClientExecutionTests()
        try await fixture.client(body: #"{"requested":true}"#).billingResume()
        #expect(fixture.last?.url.path == "/api/v2/billing/resume" && fixture.last?.method == "POST" && (fixture.last?.body == nil || fixture.last?.body?.isEmpty == true))
        try await fixture.client(body: #"{"requested":true}"#).billingRefund()
        #expect(fixture.last?.url.path == "/api/v2/billing/refund" && fixture.last?.method == "POST" && (fixture.last?.body == nil || fixture.last?.body?.isEmpty == true))
        #expect(fixture.last?.headers["Authorization"] == "Bearer token-123")
        await #expect(throws: APIError.self) { try await fixture.client(body: #"{"requested":false}"#).billingRefund() }
    }

    @Test(arguments: [
        (409, "billing_refund_window_closed", APIErrorCode.billingRefundWindowClosed), (409, "billing_refund_used", .billingRefundUsed),
        (409, "billing_refund_pending", .billingRefundPending), (409, "billing_unavailable", .billingUnavailable), (409, "billing_terms_required", .billingTermsRequired),
        (422, "ai_key_invalid", .aiKeyInvalid), (422, "ai_key_management", .aiKeyManagement),
    ])
    func theNewServerErrorCodesKeepTheirOwnNames(_ status: Int, _ raw: String, _ expected: APIErrorCode) async throws {
        let fixture = APIClientExecutionTests()
        do {
            try await fixture.client(status: status, body: #"{"error":{"code":"\#(raw)","message":"설명"}}"#).billingRefund()
            Issue.record("성공하면 안 된다")
        } catch let error as APIError {
            #expect(error == .server(status: status, code: expected, message: "설명"))
        }
    }

    // MARK: OpenRouter 키 (BYOK, PR-B route)

    @Test func savingTheKeyPutsItInTheBodyOnlyAndReadsTheStateBack() async throws {
        let fixture = APIClientExecutionTests()
        try await fixture.client(body: #"{"ai_key":"connected"}"#).saveOpenRouterKey(SecretBox("sk-or-v1-0123456789abcdef0123"))
        #expect(fixture.last?.url.path == "/api/v2/billing/openrouter-key" && fixture.last?.method == "PUT")
        #expect(fixture.last?.headers["Authorization"] == "Bearer token-123")
        let body = try #require(fixture.last?.body)
        #expect(try JSONSerialization.jsonObject(with: body) as? [String: String] == ["key": "sk-or-v1-0123456789abcdef0123"])
        // 주소 · 쿼리에는 키가 없다
        #expect(fixture.last?.url.absoluteString.contains("sk-or") == false)
        await #expect(throws: APIError.self) { try await fixture.client(body: #"{"ai_key":"missing"}"#).saveOpenRouterKey(SecretBox("sk-or-v1-0123456789abcdef0123")) }
    }

    @Test func aKeyThatTheServerRefusedFailsWithTheServersOwnCodeAndNoKeyInTheError() async throws {
        let fixture = APIClientExecutionTests()
        let secret = "sk-or-v1-SECRET-0123456789abcdef"
        do {
            try await fixture.client(status: 422, body: #"{"error":{"code":"ai_key_invalid","message":"This key doesn't work."}}"#).saveOpenRouterKey(SecretBox(secret))
            Issue.record("성공하면 안 된다")
        } catch let error as APIError {
            #expect(error == .server(status: 422, code: .aiKeyInvalid, message: "This key doesn't work."))
            #expect(!error.description.contains(secret) && !error.userMessage.contains(secret))
        }
    }

    @Test func removingTheKeyIsADeleteWithNoBodyAnd204IsEnough() async throws {
        let fixture = APIClientExecutionTests()
        try await fixture.client(status: 204, body: "").removeOpenRouterKey()
        #expect(fixture.last?.url.path == "/api/v2/billing/openrouter-key" && fixture.last?.method == "DELETE")
        #expect(fixture.last?.headers["Authorization"] == "Bearer token-123" && (fixture.last?.body == nil || fixture.last?.body?.isEmpty == true))
    }

    // MARK: 앱 오류 문장 (N12 · N13) · 옛 7일 문구

    @Test func billingRequiredIsTheEndedPlanSentenceOrTheMissingKeySentenceTheServerNamed() {
        let ended = APIError.server(status: 403, code: .billingRequired, message: "Your plan has ended. Restart Pro in Settings → Account → Plan & usage.")
        #expect(ended.userMessage == "Your plan has ended. Restart Pro in Settings → Account → Plan & usage.")
        let key = APIError.server(status: 403, code: .billingRequired, message: "Add your OpenRouter key in Settings → Account → Plan & usage.")
        #expect(key.userMessage == "Add your OpenRouter key in Settings → Account → Plan & usage.")
        // 서버가 모르는 다른 글을 보내도 화면에는 승인된 문장만
        let other = APIError.server(status: 403, code: .billingRequired, message: "anything else")
        #expect(other.userMessage == "Your plan has ended. Restart Pro in Settings → Account → Plan & usage.")
        #expect(!ended.userMessage.contains("Subscription"))
    }

    @Test func theOldV1ReadStillWorksButNoLongerSpeaksOfASevenDayTrial() async throws {
        let fixture = APIClientExecutionTests()
        let trial = try await fixture.client(body: #"{"status":"trialing","plan":null,"trial_ends_at":"2026-10-15T00:00:00Z","current_period_ends_at":null,"can_use_ai":true,"can_checkout":false,"monthly_price_usd":9.99,"annual_price_usd":101.90}"#).billing()
        #expect(!trial.label.contains("7-day") && !trial.label.contains("trial starts"))
        #expect(fixture.last?.url.path == "/api/v1/billing")
        let active = try await fixture.client(body: #"{"status":"active","plan":"monthly","can_use_ai":true,"can_checkout":false}"#).billing()
        #expect(active.label == "Monthly subscription")
    }
}
