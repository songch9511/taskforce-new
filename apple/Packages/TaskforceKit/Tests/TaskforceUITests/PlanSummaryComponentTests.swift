#if os(macOS)
import AppKit
import SwiftUI
import Testing
import TaskforceKit
@testable import TaskforceUI

/// Plan & usage 부품 (OA 결제 계약 16.4): Notice 아이콘 · 법률 줄과 링크 · 폭 안에 그려짐 · 색을 더하지 않음
@MainActor
struct PlanSummaryComponentTests {
    private func status(_ state: BillingStatusV2.State, plan: BillingStatusV2.Plan? = nil, key: BillingStatusV2.KeyStatus? = nil, checkout: Bool = false, lifetime: Bool = false) -> BillingStatusV2 {
        BillingStatusV2(
            state: state, plan: plan, trialEndsAt: Date(timeIntervalSince1970: 1_792_000_000), currentPeriodEndsAt: Date(timeIntervalSince1970: 1_793_000_000),
            canUseAI: true, canCheckout: checkout, canBuyLifetime: lifetime, withTrial: true,
            prices: .init(proMonthly: "$12.99", proFirstMonth: "$6.99", proYearly: "$119.88", lifetime: "$229"), aiKey: key
        )
    }

    private func fitting(_ state: PlanSummaryState, width: CGFloat = 520) -> CGSize {
        let view = PlanSummaryView(state: state, keyHandle: SecureFieldSmHandle(), onAction: { _ in }, onSubmitKey: { _ in })
        let host = NSHostingView(rootView: view.frame(width: width))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 3000)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    @Test func noticeIconsFollowTheDesignSystemRoles() {
        #expect(PlanSummaryNoticeView.icon(.warning) == .paused && PlanSummaryNoticeView.icon(.clock) == .refundRequested && PlanSummaryNoticeView.icon(.check) == .check)
    }

    @Test func theLegalLineIsTheApprovedSentenceWithTwoLinksToTheTermsAndPrivacyPages() throws {
        let line = PlanSummaryFootnoteView.legalLine
        #expect(String(line.characters) == "By continuing you agree to the Terms and Privacy Policy. You must be 14 or older and not in the EEA or UK.")
        let links = line.runs.compactMap { run in run.link.map { (String(line[run.range].characters), $0) } }
        #expect(links.count == 2)
        #expect(links[0].0 == "Terms" && links[0].1 == LegalLinks.terms)
        #expect(links[1].0 == "Privacy Policy" && links[1].1 == LegalLinks.privacy)
    }

    @Test func everyStateFitsTheSettingsColumnWidth() {
        let make = { (status: BillingStatusV2?) in PlanSummaryState.make(PlanSummaryInput(status: status, now: Date(timeIntervalSince1970: 1_791_000_000))) }
        let states = [
            make(nil), make(status(.none, checkout: true, lifetime: true)), make(status(.lapsed, checkout: true, lifetime: true)), make(status(.trial, plan: .monthly)),
            make(status(.pro, plan: .annual)), make(status(.pastDue, plan: .monthly)), make(status(.cancelled, plan: .monthly)),
            make(status(.lifetime, key: .connected)), make(status(.lifetime, key: .missing)), make(status(.beta)),
        ]
        for state in states {
            let size = fitting(state)
            #expect(size.width <= 520.5 && size.height > 40, "\(state.allTextForTest)")
        }
    }

    @Test func thePlanSectionIsTitledAndTheOpenRouterSectionComesAfterIt() {
        let state = PlanSummaryState.make(PlanSummaryInput(status: status(.lifetime, key: .connected), now: Date(timeIntervalSince1970: 1_791_000_000)))
        #expect(state.sections.map(\.title) == ["Plan & usage", "OpenRouter"])
        #expect(fitting(state).height > fitting(PlanSummaryState.make(PlanSummaryInput(status: status(.lifetime), now: Date()))).height, "키 절만큼 더 길다")
    }

    @Test func spendingOutsideIsOneClaudeCodeLineAndItsFootnote() {
        let host = NSHostingView(rootView: SpendingOutsideSection().frame(width: 520))
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 600)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height > 60 && host.fittingSize.width <= 520.5)
    }
}

private extension PlanSummaryState {
    var allTextForTest: String { rows.map(\.label).joined(separator: " / ") }
}
#endif
