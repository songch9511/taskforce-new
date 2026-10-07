import Foundation
import Testing
@testable import TaskforceKit

struct BillingTests {
    @Test func statusUsesAuthenticatedAccount() async throws {
        let fixture = APIClientExecutionTests()
        let value = try await fixture.client(body: #"{"status":"trialing","plan":null,"trial_ends_at":"2026-10-15T00:00:00Z","current_period_ends_at":null,"can_use_ai":true,"can_checkout":true}"#).billing()
        #expect(value.label == "7-day free trial")
        #expect(value.aiAllowance == nil)
        #expect(fixture.last?.url.path == "/api/v1/billing")
        #expect(fixture.last?.headers["Authorization"] == "Bearer token-123")
    }

    @Test func annualCheckoutSendsOnlyPlan() async throws {
        let fixture = APIClientExecutionTests()
        let url = try await fixture.client(body: #"{"url":"https://taskforcelabs.lemonsqueezy.com/checkout/test"}"#).billingCheckout(plan: .annual)
        #expect(url.host == "taskforcelabs.lemonsqueezy.com")
        #expect(fixture.last?.url.path == "/api/v1/billing/checkout")
        #expect(fixture.last?.method == "POST")
        let body = try #require(fixture.last?.body)
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(sent == ["plan": "annual", "terms_version": "2026-10-08"])
    }

    @Test(arguments: ["http://taskforcelabs.lemonsqueezy.com/checkout", "https://lemonsqueezy.com.evil.test/checkout", "https://evil.test/", "https://user:secret@taskforcelabs.lemonsqueezy.com/checkout", "javascript:alert(1)"])
    func rejectsUnsafePaymentURL(_ raw: String) throws {
        let url = try #require(URL(string: raw))
        #expect(throws: URLError.self) { try BillingSummary.validatedURL(url) }
    }

    @Test func portalIsAuthenticatedPost() async throws {
        let fixture = APIClientExecutionTests()
        _ = try await fixture.client(body: #"{"url":"https://taskforcelabs.lemonsqueezy.com/billing"}"#).billingPortal()
        #expect(fixture.last?.url.path == "/api/v1/billing/portal")
        #expect(fixture.last?.method == "POST")
        #expect(fixture.last?.headers["Authorization"] == "Bearer token-123")
    }
}
