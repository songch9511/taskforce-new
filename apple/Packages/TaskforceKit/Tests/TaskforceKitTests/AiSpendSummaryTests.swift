import Foundation
import Testing
@testable import TaskforceKit

struct AiSpendSummaryTests {
    @Test func summaryKeepsUSDAndReservationsSeparate() throws {
        let data = Data(#"{"cap_usd":10,"confirmed_usd":1.25,"reserved_usd":3,"pending_count":2,"remaining_usd":5.75,"status":"available"}"#.utf8)
        let summary = try JSONDecoder().decode(AiSpendSummary.self, from: data)
        #expect(summary.confirmedUSD == Decimal(string: "1.25"))
        #expect(summary.reservedUSD == 3)
        #expect(summary.pendingCount == 2)
        #expect(summary.remainingUSD == Decimal(string: "5.75"))
        #expect(summary.notice == nil)
        #expect(AiSpendSummary.explanation.contains("No automatic overage charges"))
        #expect(AiSpendSummary.explanation.contains("stays reserved until the provider confirms the cost"))
        #expect(AiSpendSummary.explanation.contains("an upper bound, not confirmed spend"))
    }
    @Test func budgetErrorsAreDistinctAndNotConsent() throws {
        let codes: [APIErrorCode] = [.aiBudgetExhausted, .aiPricingUnavailable, .aiProviderBoundViolation, .aiBudgetUnavailable]
        let errors = codes.map { APIError.server(status: 503, code: $0, message: "private") }
        #expect(Set(errors.map(\.userMessage)).count == 4)
        #expect(errors.allSatisfy { !$0.isConsentRequired && !$0.userMessage.contains("private") })
    }
    @Test func summaryIsAuthenticatedReadWithoutCreditGate() async throws {
        let fixture = APIClientExecutionTests()
        let api = fixture.client(body: #"{"cap_usd":10,"confirmed_usd":0,"reserved_usd":10,"pending_count":1,"remaining_usd":0,"status":"exhausted"}"#)
        let summary = try await api.aiBudget()
        #expect(summary.notice?.contains("fully spent or reserved") == true)
        #expect(fixture.last?.url.path == "/api/v1/ai-budget")
        #expect(fixture.last?.method == "GET")
        #expect(fixture.last?.headers["Authorization"] == "Bearer token-123")
        #expect(RunLane.FailureKind("ai_budget_exhausted") == .aiBudgetExhausted)
    }
}
