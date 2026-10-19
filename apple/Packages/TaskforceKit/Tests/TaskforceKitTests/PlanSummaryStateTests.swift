import Foundation
import Testing
@testable import TaskforceKit

/// 상태 → 화면 (OA 결제 계약 9.2 표 + DS PlanSummary + 승인된 DZ 그림). 순수 규칙이라 두 창이 같은 값을 그린다
struct PlanSummaryStateTests {
    typealias F = PlanFixtures
    typealias C = PlanCopy

    // MARK: 읽는 중 · 못 읽음 · 모르는 상태

    @Test func nothingReadYetIsAPlanRowSayingChecking() {
        let state = F.make(nil)
        #expect(state.rows.map(\.id) == ["plan"] && state.row("plan")?.control == .value("Checking…", bold: false))
        #expect(state.notice == nil && state.sections.first?.footnote == nil && !state.isBusy)
        #expect(state.compact == .init(label: "Checking…", detail: nil, failed: false))
        #expect(state.sections.first?.title == "Plan & usage")
    }

    @Test func aFailedFirstReadIsOneQuietLineWithNoNewTextAndNoButton() {
        let state = F.make(nil) { $0.loadFailed = true }
        #expect(state.rows.isEmpty && state.sections.first?.empty == "Something went wrong. Try again in a moment.")
        #expect(state.compact.failed && state.notice == nil)
    }

    @Test func aFailedReadAfterAGoodOneKeepsTheGoodValue() {
        let state = F.make(F.pro) { $0.loadFailed = true }
        #expect(state.row("plan") != nil && state.sections.first?.empty == nil, "읽은 값이 있으면 그대로")
    }

    @Test func anUnknownStateAndTheTimeAfterCheckoutAreBothChecking() {
        for state in [F.make(F.status(.unknown)), F.make(F.none) { $0.settling = true }, F.make(F.pro) { $0.settling = true }] {
            #expect(state.rows.map(\.id) == ["plan"] && state.row("plan")?.control == .value("Checking…", bold: false))
            #expect(state.notice == nil && state.sections.count == 1)
        }
    }

    // MARK: none · lapsed (Lifetime 줄 · 동의 줄 · Claude Code 줄)

    @Test func noPlanFirstTimeOffersTheTrialAndLifetimeWithTheSplitLines() throws {
        let state = F.make(F.none)
        #expect(state.rows.map(\.id) == ["plan", "pro", "lifetime"] && state.notice == nil)
        #expect(state.row("plan")?.control == .value("No plan", bold: false))
        let pro = try #require(state.row("pro"))
        #expect(pro.label == "Pro")
        #expect(pro.detail == ["$12.99 a month, first month $6.99 · or $119.88 a year", "Renews until you cancel. Tax may apply."])
        #expect(pro.control == .button(.init("Start 3-day free trial", .checkout(.pro), prominent: true)))
        let lifetime = try #require(state.row("lifetime"))
        #expect(lifetime.detail == ["$229 once · model usage billed to your OpenRouter account", "One payment. Tax may apply."])
        #expect(lifetime.control == .button(.init("Buy Lifetime", .checkout(.lifetime))), "Lifetime 버튼은 잉크가 아니다")
        #expect(state.sections[0].footnote == .init(paragraphs: ["Manual lists, existing results and sources stay available without a plan. Pro adds AI and execution. Claude Code usage is billed to your own Claude plan."], legal: true))
    }

    @Test func afterTheTrialWasUsedTheButtonIsStartProAndTheFirstMonthPhraseIsGone() throws {
        let used = F.status(.none, canCheckout: true, canBuyLifetime: true, withTrial: false)
        let state = F.make(used)
        let pro = try #require(state.row("pro"))
        #expect(pro.control == .button(.init("Start Pro", .checkout(.pro), prominent: true)))
        #expect(pro.detail == ["$12.99 a month · or $119.88 a year", "Renews until you cancel. Tax may apply."])
        #expect(!state.allText.contains { $0.contains("first month") })
    }

    @Test func theRowsFollowWhatTheServerSaysCanBeBought() {
        let lifetimeOnly = F.make(F.status(.none, canCheckout: false, canBuyLifetime: true))
        #expect(lifetimeOnly.rows.map(\.id) == ["plan", "lifetime"])
        let proOnly = F.make(F.status(.none, canCheckout: true, canBuyLifetime: false))
        #expect(proOnly.rows.map(\.id) == ["plan", "pro"], "BYOK가 꺼지면 Lifetime 줄이 없다")
        let nothing = F.make(F.status(.none))
        #expect(nothing.rows.map(\.id) == ["plan"] && nothing.sections[0].footnote?.legal == false, "팔 것이 없으면 법률 줄도 없다")
    }

    @Test func checkoutBusyShowsASpinnerOnThatButtonOnlyAndDisablesTheRest() throws {
        let state = F.make(F.none) { $0.busy = .checkout(.pro) }
        #expect(state.isBusy)
        #expect(state.row("pro")?.control == .button(.init("Start 3-day free trial", .checkout(.pro), prominent: true, busy: true)))
        #expect(state.row("lifetime")?.control == .button(.init("Buy Lifetime", .checkout(.lifetime), busy: false)))
        let lifetimeBusy = F.make(F.none) { $0.busy = .checkout(.lifetime) }
        #expect(lifetimeBusy.row("lifetime")?.control == .button(.init("Buy Lifetime", .checkout(.lifetime), busy: true)))
    }

    @Test func aCheckoutFailureLineSitsOnTheRowThatFailedBetweenTheOfferAndTheTaxLine() throws {
        let pro = F.make(F.none) { $0.failure = .checkout(.pro) }
        #expect(pro.row("pro")?.detail == ["$12.99 a month, first month $6.99 · or $119.88 a year", "Couldn't open checkout. Try again in a moment.", "Renews until you cancel. Tax may apply."])
        #expect(pro.row("lifetime")?.detail.contains("Couldn't open checkout. Try again in a moment.") == false)
        let lifetime = F.make(F.none) { $0.failure = .checkout(.lifetime) }
        #expect(lifetime.row("lifetime")?.detail == ["$229 once · model usage billed to your OpenRouter account", "Couldn't open checkout. Try again in a moment.", "One payment. Tax may apply."])
    }

    @Test func endedShowsOneNoticeWithRestartProAndTheLifetimeRow() throws {
        let state = F.make(F.status(.lapsed, canCheckout: true, canBuyLifetime: true))
        let notice = try #require(state.notice)
        #expect(notice.title == "Pro ended · AI and execution paused" && notice.message == "Your lists, results and sources stay available." && notice.icon == .warning)
        #expect(notice.button == .init("Restart Pro", .checkout(.pro), prominent: true))
        #expect(state.rows.map(\.id) == ["plan", "lifetime"], "서버가 끝난 날짜를 주지 않으면 Ended 줄도 없다")
        #expect(state.row("plan")?.control == .value("No active plan", bold: false))
        #expect(state.sections[0].footnote == .init(paragraphs: ["Lists, results and sources stay. AI and execution start again when you restart Pro. Renews until you cancel. Tax may apply."], legal: true))
        #expect(state.compact == .init(label: "No active plan", detail: nil, failed: false))
    }

    @Test func endedShowsTheEndedRowWhenTheServerGivesADate() {
        let state = F.make(F.status(.lapsed, periodEndsAt: "2026-10-08T00:00:00Z", canCheckout: true, canBuyLifetime: true))
        #expect(state.row("ended")?.control == .value("Oct 8", bold: false))
        #expect(state.compact.detail == "Ended Oct 8")
    }

    @Test func endedWithoutAnythingToBuyHasNoButtonAndNoLegalLine() {
        let state = F.make(F.status(.lapsed))
        #expect(state.notice?.button == nil && state.rows.map(\.id) == ["plan"])
        #expect(state.sections[0].footnote == .init(paragraphs: ["Lists, results and sources stay. AI and execution start again when you restart Pro."], legal: false))
    }

    @Test func aRestartFailureSitsOnThePlanRowBecauseTheNoticeHasNoRoomForIt() {
        let state = F.make(F.status(.lapsed, canCheckout: true, canBuyLifetime: true)) { $0.failure = .checkout(.pro) }
        #expect(state.row("plan")?.detail == ["Couldn't open checkout. Try again in a moment."])
        let busy = F.make(F.status(.lapsed, canCheckout: true, canBuyLifetime: true)) { $0.busy = .checkout(.pro) }
        #expect(busy.notice?.button?.busy == true)
    }

    // MARK: trial · pro

    @Test func aMonthlyTrialShowsTheFirstMonthPriceAndTheYearlyTrialTheYearlyPrice() {
        let monthly = F.make(F.status(.trial, plan: .monthly, trialEndsAt: "2026-10-22T09:00:00Z"))
        #expect(monthly.rows.map(\.id) == ["plan", "trial-ends", "first-charge", "manage"])
        #expect(monthly.row("plan")?.control == .value("Pro · Trial", bold: false))
        #expect(monthly.row("trial-ends")?.control == .value("Oct 22", bold: false))
        #expect(monthly.row("first-charge")?.control == .value("Oct 22 · $6.99", bold: false))
        #expect(monthly.row("manage")?.control == .opens(.portal(.manage)) && monthly.row("manage")?.label == "Manage subscription")
        #expect(monthly.sections[0].footnote == .init(paragraphs: ["Cancel before the trial ends and you are not charged."], legal: false))
        let yearly = F.make(F.status(.trial, plan: .annual, trialEndsAt: "2026-10-22T09:00:00Z"))
        #expect(yearly.row("first-charge")?.control == .value("Oct 22 · $119.88", bold: false))
        #expect(monthly.compact == .init(label: "Pro · Trial", detail: "Trial ends Oct 22", failed: false))
    }

    @Test func proMonthlyAndYearlyShowThePriceFromTheServerAndTheUsageForReference() throws {
        let monthly = F.make(F.pro)
        #expect(monthly.rows.map(\.id) == ["plan", "renews", "usage", "manage", "refund"])
        #expect(monthly.row("plan")?.control == .value("Pro · Monthly · $12.99 a month", bold: false))
        #expect(monthly.row("renews")?.control == .value("Nov 8", bold: false))
        let usage = try #require(monthly.row("usage"))
        #expect(usage.label == "AI usage this month" && usage.detail == ["For reference."] && usage.control == .value("2.4M tokens", bold: false))
        #expect(monthly.sections[0].footnote == .init(paragraphs: ["Claude Code usage is billed to your own Claude plan, not to Pro."], legal: false))
        #expect(monthly.compact == .init(label: "Pro · Monthly", detail: "Renews Nov 8", failed: false))
        let yearly = F.make(F.status(.pro, plan: .annual, periodEndsAt: "2027-12-31T00:00:00Z", tokens: 1_284_600_000))
        #expect(yearly.row("plan")?.control == .value("Pro · Yearly · $119.88 a year", bold: false))
        #expect(yearly.row("renews")?.control == .value("Dec 31, 2027", bold: false), "다른 해는 연도가 붙는다")
        #expect(yearly.row("usage")?.control == .value("1,284.6M tokens", bold: false))
        #expect(yearly.row("refund") == nil, "환불 창 밖이면 줄이 없다")
    }

    @Test func theUsageRowIsOnlyThereWhenTheServerGaveUsage() {
        #expect(F.make(F.status(.pro, plan: .monthly, periodEndsAt: "2026-11-08T00:00:00Z")).row("usage") == nil)
    }

    // MARK: 환불

    @Test func theRefundRowShowsOnlyInsideTheThreeDayWindowAndOpensAnInPlaceConfirmation() throws {
        let row = try #require(F.make(F.pro).row("refund"))
        #expect(row.label == "Request refund" && row.detail == ["Available until Oct 23"])
        #expect(row.control == .button(.init("Request…", .askRefund)))
        let asking = try #require(F.make(F.pro) { $0.askingRefund = true }.row("refund"))
        guard case .confirm(let confirm) = asking.control else { Issue.record("확인 줄이어야 한다"); return }
        #expect(confirm == .init(title: "Request a refund?", detail: "Pro ends when the refund is issued.", confirmTitle: "Request refund", confirm: .confirmRefund, cancel: .cancelRefund, busy: false))
        let busy = try #require(F.make(F.pro) { $0.askingRefund = true; $0.busy = .refund }.row("refund"))
        guard case .confirm(let sending) = busy.control else { Issue.record("확인 줄이어야 한다"); return }
        #expect(sending.busy)
    }

    @Test func aLifetimeRefundConfirmationSaysLifetimeEnds() throws {
        let asking = try #require(F.make(F.lifetime) { $0.askingRefund = true }.row("refund"))
        guard case .confirm(let confirm) = asking.control else { Issue.record("확인 줄이어야 한다"); return }
        #expect(confirm.detail == "Lifetime ends when the refund is issued." && confirm.title == "Request a refund?")
    }

    @Test func aRefundFailureLineSitsUnderTheRefundRow() throws {
        let row = try #require(F.make(F.pro) { $0.failure = .refund }.row("refund"))
        #expect(row.detail == ["Available until Oct 23", "Something went wrong. Try again in a moment."])
    }

    @Test func aRequestedRefundIsANoticeInsteadOfTheRowWhetherTheServerOrThisScreenKnows() throws {
        for state in [F.make(F.status(.pro, plan: .monthly, periodEndsAt: "2026-11-08T00:00:00Z", refundState: .requested)), F.make(F.pro) { $0.refundRequested = true }] {
            let notice = try #require(state.notice)
            #expect(notice.icon == .clock && notice.title == "Refund requested" && notice.message == "Lemon Squeezy confirms it by email, usually within a day." && notice.button == nil)
            #expect(state.row("refund") == nil && state.row("plan") != nil, "자격은 그대로: 플랜 줄이 남는다")
        }
    }

    @Test func anIssuedRefundLeavesTheNoticeAndANoPlanRowOnly() throws {
        let pro = F.make(F.status(.lapsed, canCheckout: true, canBuyLifetime: true)) { $0.refundIssued = .pro }
        let notice = try #require(pro.notice)
        #expect(notice.icon == .check && notice.title == "Refund issued" && notice.message == "Pro ends now. Your lists, results and sources stay available.")
        #expect(pro.rows.map(\.id) == ["plan"] && pro.row("plan")?.control == .value("No plan", bold: false) && pro.sections.count == 1 && pro.sections[0].footnote == nil)
        let lifetime = F.make(F.status(.none, canCheckout: true, canBuyLifetime: true)) { $0.refundIssued = .lifetime }
        #expect(lifetime.notice?.message == "Lifetime ends now. Your lists, results and sources stay available.")
        #expect(lifetime.rows.map(\.id) == ["plan"], "OpenRouter 절 · 각주도 사라진다")
    }

    @Test func anIssuedRefundNoticeOnlyShowsWhenThePlanIsReallyOver() {
        #expect(F.make(F.pro) { $0.refundIssued = .pro }.notice == nil, "플랜이 아직 살아 있으면 지난 환불 표시를 쓰지 않는다")
    }

    // MARK: cancelled · past due

    @Test func cancelledShowsResumeAndNeverALifetimeRowWhileProIsStillRunning() throws {
        let state = F.make(F.status(.cancelled, plan: .monthly, periodEndsAt: "2026-11-08T00:00:00Z", cancelAt: "2026-11-08T00:00:00Z", canCheckout: false, canBuyLifetime: true))
        #expect(state.rows.map(\.id) == ["plan", "available-until", "resume"] && state.notice == nil)
        #expect(state.row("plan")?.control == .value("Pro · Cancelled", bold: false))
        #expect(state.row("available-until")?.control == .value("Nov 8", bold: false))
        let resume = try #require(state.row("resume"))
        #expect(resume.label == "Resume Pro" && resume.control == .button(.init("Resume", .resume, prominent: true)))
        #expect(state.sections[0].footnote == nil)
        #expect(state.compact == .init(label: "Pro · Cancelled", detail: "Available until Nov 8", failed: false))
        let failed = F.make(F.status(.cancelled, plan: .monthly, cancelAt: "2026-11-08T00:00:00Z")) { $0.failure = .resume }
        #expect(failed.row("resume")?.detail == ["Something went wrong. Try again in a moment."])
    }

    @Test func pastDueShowsPaymentFailedWithUpdatePaymentMethodAndKeepsTheRows() throws {
        let state = F.make(F.status(.pastDue, plan: .monthly, periodEndsAt: "2026-10-08T00:00:00Z"))
        let notice = try #require(state.notice)
        #expect(notice.icon == .warning && notice.title == "Payment failed" && notice.message == "AI and execution keep running while you update it.")
        #expect(notice.button == .init("Update payment method", .portal(.payment), prominent: true))
        #expect(state.row("plan")?.control == .value("Pro · Monthly", bold: false) && state.row("due")?.control == .value("Oct 8", bold: false))
        #expect(state.compact == .init(label: "Pro · Monthly", detail: "Payment due Oct 8", failed: false))
        let failed = F.make(F.status(.pastDue, plan: .monthly, periodEndsAt: "2026-10-08T00:00:00Z")) { $0.failure = .portal(.payment) }
        #expect(failed.row("plan")?.detail == ["Something went wrong. Try again in a moment."])
    }

    // MARK: Lifetime · OpenRouter 키

    @Test func lifetimeShowsThePlanAndRefundRowThenTheOpenRouterSection() throws {
        let state = F.make(F.lifetime)
        #expect(state.sections.map(\.id) == ["plan", "openrouter"] && state.sections[1].title == "OpenRouter")
        #expect(state.sections[0].rows.map(\.id) == ["plan", "refund"] && state.row("plan")?.control == .value("Lifetime", bold: false))
        #expect(state.sections[1].rows.map(\.id) == ["key", "key-entry", "key-remove"])
        let key = try #require(state.row("key"))
        #expect(key.label == "Key" && key.detail == ["Billed to your OpenRouter account"] && key.control == .value("Connected", bold: false))
        let entry = try #require(state.row("key-entry"))
        #expect(entry.label == "Replace key" && entry.detail.isEmpty)
        #expect(entry.control == .keyField(save: .init("Save", .saveKey, prominent: false)), "키가 이미 있으면 Save는 잉크가 아니다")
        #expect(state.row("key-remove")?.label == "Remove key" && state.row("key-remove")?.control == .button(.init("Remove…", .askRemoveKey)))
        #expect(state.sections[1].footnote == .init(paragraphs: ["Your key is sent to Taskforce's server and kept there, not on this Mac. Model usage is billed to your OpenRouter account. Taskforce still asks for zero data retention. Logging settings in your OpenRouter account are yours."], legal: false))
        #expect(state.compact == .init(label: "Lifetime", detail: nil, failed: false))
    }

    @Test func aMissingKeyIsBoldAddKeyWithAnInkSaveAndNoRemoveRow() throws {
        let state = F.make(F.status(.lifetime, aiKey: .missing))
        #expect(state.row("key")?.control == .value("Missing", bold: true))
        #expect(state.row("key-entry")?.label == "Add key" && state.row("key-entry")?.control == .keyField(save: .init("Save", .saveKey, prominent: true)))
        #expect(state.row("key-remove") == nil, "지울 키가 없다")
    }

    @Test func aRevokedKeyIsBoldAndStillOffersRemoveKey() {
        let state = F.make(F.status(.lifetime, aiKey: .revoked))
        #expect(state.row("key")?.control == .value("Revoked", bold: true))
        #expect(state.row("key-entry")?.label == "Add key" && state.row("key-remove") != nil)
        #expect(state.notice == nil, "401은 Notice 없이 Key 줄의 굵은 말이 알린다")
    }

    @Test func noKeyStateMeansNoOpenRouterSection() {
        #expect(F.make(F.status(.lifetime)).sections.map(\.id) == ["plan"])
    }

    @Test func keySaveFailuresAreQuietGrayLinesUnderTheEntryRow() {
        let cases: [(PlanSummaryInput.KeyFailure, String)] = [
            (.invalid, "This key doesn't work. Check it in OpenRouter."), (.management, "Use a regular API key."), (.generic, "Something went wrong. Try again in a moment."),
        ]
        for (failure, text) in cases {
            let state = F.make(F.status(.lifetime, aiKey: .missing)) { $0.failure = .keySave(failure) }
            #expect(state.row("key-entry")?.detail == [text])
            #expect(state.row("key")?.control == .value("Missing", bold: true), "저장하지 않았으니 Missing 그대로")
        }
    }

    @Test func savingShowsASpinnerOnSave() {
        let state = F.make(F.status(.lifetime, aiKey: .missing)) { $0.busy = .saveKey }
        #expect(state.row("key-entry")?.control == .keyField(save: .init("Save", .saveKey, prominent: true, busy: true)) && state.isBusy)
    }

    @Test func removingAKeyAsksInPlaceWithCancelFirstAndOnlyThenBusy() throws {
        let asking = try #require(F.make(F.lifetime) { $0.confirmingRemoveKey = true }.row("key-remove"))
        guard case .confirm(let confirm) = asking.control else { Issue.record("확인 줄이어야 한다"); return }
        #expect(confirm == .init(title: "Remove your OpenRouter key?", detail: "AI and execution stop until you add a key. Your lists, results and sources stay.", confirmTitle: "Remove", confirm: .confirmRemoveKey, cancel: .cancelRemoveKey, busy: false))
        let busy = try #require(F.make(F.lifetime) { $0.confirmingRemoveKey = true; $0.busy = .removeKey }.row("key-remove"))
        guard case .confirm(let removing) = busy.control else { Issue.record("확인 줄이어야 한다"); return }
        #expect(removing.busy)
        #expect(F.make(F.lifetime) { $0.failure = .keyRemove }.row("key-remove")?.detail == ["Something went wrong. Try again in a moment."])
    }

    // MARK: Notice는 하나, 순서는 결제 > 키 > 공정 사용

    @Test func aFairUsePauseIsOneNoticeNamingTheProMonthLimitWithoutAnyNumber() throws {
        let state = F.make(F.status(.pro, plan: .monthly, periodEndsAt: "2026-11-08T00:00:00Z", tokens: 9_800_000, fairUse: "2026-11-01T00:00:00Z"))
        let notice = try #require(state.notice)
        #expect(notice.icon == .warning && notice.title == "AI paused until Nov 1" && notice.message == "This account reached Pro's monthly fair-use limit." && notice.button == nil)
        #expect(state.row("usage")?.detail == ["For reference."], "아래 사용량 줄은 그대로")
        let annual = F.make(F.status(.pro, plan: .annual, periodEndsAt: "2027-10-08T00:00:00Z", fairUse: "2026-11-01T00:00:00Z"))
        #expect(annual.notice?.message == "This account reached Pro's monthly fair-use limit.")
    }

    @Test func aTrialFairUsePauseSaysTheTrialLimitAndTheDateIsWhenTheTrialEnds() throws {
        let state = F.make(F.status(.trial, plan: .monthly, trialEndsAt: "2026-10-22T09:00:00Z", fairUse: "2026-10-22T09:00:00Z"))
        let notice = try #require(state.notice)
        #expect(notice.title == "AI paused until Oct 22" && notice.message == "This account reached the trial's fair-use limit.")
    }

    @Test func openRouterCantPayIsATextOnlyNoticeThatLeavesTheKeyConnected() throws {
        let state = F.make(F.status(.lifetime, aiKey: .connected, spendError: "2026-10-20T08:00:00Z"))
        let notice = try #require(state.notice)
        #expect(notice.title == "OpenRouter can't pay for requests" && notice.message == "Add credits or raise this key's limit in OpenRouter." && notice.button == nil)
        #expect(state.row("key")?.control == .value("Connected", bold: false), "충전하면 바로 된다")
        #expect(F.make(F.status(.lifetime, aiKey: .missing, spendError: "2026-10-20T08:00:00Z")).notice == nil, "키가 없으면 그 문제가 아니다")
        #expect(F.make(F.status(.lifetime, aiKey: .revoked, spendError: "2026-10-20T08:00:00Z")).notice == nil)
    }

    @Test func aPaymentProblemBeatsAKeyProblemWhichBeatsFairUse() throws {
        let pastDueAndFair = F.make(F.status(.pastDue, plan: .monthly, periodEndsAt: "2026-10-08T00:00:00Z", fairUse: "2026-11-01T00:00:00Z"))
        #expect(pastDueAndFair.notice?.title == "Payment failed")
        let lapsedAndFair = F.make(F.status(.lapsed, canCheckout: true, fairUse: "2026-11-01T00:00:00Z"))
        #expect(lapsedAndFair.notice?.title == "Pro ended · AI and execution paused")
        let keyAndFair = F.make(F.status(.lifetime, fairUse: "2026-11-01T00:00:00Z", aiKey: .connected, spendError: "2026-10-20T08:00:00Z"))
        #expect(keyAndFair.notice?.title == "OpenRouter can't pay for requests")
    }

    @Test func aRefundResultTakesTheNoticeSlotWhileItLasts() {
        let busyAccount = F.status(.pastDue, plan: .monthly, periodEndsAt: "2026-10-08T00:00:00Z", refundState: .requested, fairUse: "2026-11-01T00:00:00Z")
        #expect(F.make(busyAccount).notice?.title == "Refund requested")
    }

    // MARK: beta

    @Test func betaBeforeTheNoticeIsJustBetaWithNothingToBuy() {
        let state = F.make(F.status(.beta, canCheckout: false, canBuyLifetime: false))
        #expect(state.rows.map(\.id) == ["plan"] && state.row("plan")?.control == .value("Beta", bold: false))
        #expect(state.sections[0].footnote == nil && state.notice == nil)
        #expect(state.compact == .init(label: "Beta", detail: nil, failed: false))
        // 서버가 고지 전에는 살 수 없다고 하므로(can_checkout false) 날짜가 있어도 결제 요소를 만들지 않는다
        #expect(F.make(F.status(.beta)).rows.map(\.id) == ["plan"])
    }

    @Test func betaAfterTheNoticeShowsTheDateAndTheProAndLifetimeRows() {
        let state = F.make(F.status(.beta, noticeEndsAt: "2026-11-20T00:00:00Z", canCheckout: true, canBuyLifetime: true, withTrial: true))
        #expect(state.row("plan")?.control == .value("Beta · until Nov 20", bold: false))
        #expect(state.rows.map(\.id) == ["plan", "pro", "lifetime"])
        #expect(state.sections[0].footnote == .init(paragraphs: [], legal: true), "법률 줄만 (각주의 첫 문단 없음)")
        #expect(state.compact == .init(label: "Beta · until Nov 20", detail: nil, failed: false))
    }

    // MARK: 접근성 · 문구 전체

    @Test func everyRowHasAStableUniqueIdAndAName() {
        for state in Self.scenarios {
            let ids = state.rows.map(\.id)
            #expect(Set(ids).count == ids.count, "\(ids)")
            #expect(state.rows.allSatisfy { !$0.label.isEmpty })
        }
    }

    @Test func atMostOneInkButtonSitsOnTheScreen() {
        for state in Self.scenarios {
            var inks = 0
            for row in state.rows {
                switch row.control {
                case .button(let button) where button.prominent: inks += 1
                case .keyField(let save) where save.prominent: inks += 1
                default: break
                }
            }
            if state.notice?.button?.prominent == true { inks += 1 }
            #expect(inks <= 1, "\(state.allText)")
        }
    }

    /// 화면에 보이는 모든 글이 승인된 문구이거나 승인된 문장 틀에 서버 값을 끼운 것이다 (새 글이 몰래 생기지 않는다)
    @Test func everyVisibleStringIsApprovedCopyOrAnApprovedTemplateWithServerValues() {
        let approved = Set(PlanSummaryCopyTests.every)
        let date = #"[A-Z][a-z]{2} \d{1,2}(, \d{4})?"#
        let templates = [
            "^(Available until|Renews|Trial ends|Payment due|Ended) \(date)$", "^\(date)$", "^\(date) · \\$[\\d.]+$", "^Pro( · (Monthly|Yearly))?( · \\$[\\d.]+ a (month|year))?$",
            "^[\\d.,]+[KM]? tokens?$", "^AI paused until \(date)$", "^Beta · until \(date)$",
            "^\\$[\\d.]+ a month · or \\$[\\d.]+ a year$", "^\\$[\\d.]+ a month, first month \\$[\\d.]+ · or \\$[\\d.]+ a year$",
            "^\\$\\d+ once · model usage billed to your OpenRouter account$",
            "^\(NSRegularExpression.escapedPattern(for: C.noPlanFootnote)) \(NSRegularExpression.escapedPattern(for: C.claudeCodeLine))$",
            "^\(NSRegularExpression.escapedPattern(for: C.lapsedFootnote))( \(NSRegularExpression.escapedPattern(for: C.proTaxLine)))?$",
            "^\(NSRegularExpression.escapedPattern(for: C.openRouterFootnote)) \(NSRegularExpression.escapedPattern(for: C.openRouterZeroRetention))$",
        ]
        for state in Self.scenarios {
            for text in state.allText where !approved.contains(text) {
                let matched = templates.contains { text.range(of: $0, options: .regularExpression) != nil }
                #expect(matched, "승인되지 않은 글: \(text)")
            }
        }
    }

    /// 두 창이 그릴 수 있는 모든 상태 (계약 9.2 표 전부 + 진행 중 · 실패 · 확인)
    static var scenarios: [PlanSummaryState] {
        let statuses: [BillingStatusV2] = [
            F.none, F.status(.none, canCheckout: true, canBuyLifetime: true), F.status(.none), F.status(.lapsed, canCheckout: true, canBuyLifetime: true), F.status(.lapsed),
            F.status(.lapsed, periodEndsAt: "2026-10-08T00:00:00Z", canCheckout: true, canBuyLifetime: true),
            F.status(.trial, plan: .monthly, trialEndsAt: "2026-10-22T09:00:00Z"), F.status(.trial, plan: .annual, trialEndsAt: "2026-10-22T09:00:00Z", fairUse: "2026-10-22T09:00:00Z"),
            F.pro, F.status(.pro, plan: .annual, periodEndsAt: "2027-12-31T00:00:00Z", tokens: 1_284_600_000, fairUse: "2026-11-01T00:00:00Z"),
            F.status(.cancelled, plan: .monthly, cancelAt: "2026-11-08T00:00:00Z", canBuyLifetime: true),
            F.status(.pastDue, plan: .monthly, periodEndsAt: "2026-10-08T00:00:00Z"), F.status(.pastDue, plan: .annual, periodEndsAt: "2026-10-08T00:00:00Z", fairUse: "2026-11-01T00:00:00Z"),
            F.lifetime, F.status(.lifetime, aiKey: .missing), F.status(.lifetime, aiKey: .revoked), F.status(.lifetime, aiKey: .connected, spendError: "2026-10-20T08:00:00Z"),
            F.status(.beta), F.status(.beta, noticeEndsAt: "2026-11-20T00:00:00Z", canCheckout: true, canBuyLifetime: true, withTrial: true),
            F.status(.pro, plan: .monthly, periodEndsAt: "2026-11-08T00:00:00Z", refundState: .requested),
        ]
        var out: [PlanSummaryState] = []
        for status in statuses {
            out.append(F.make(status))
            for busy in [PlanSummaryInput.Busy.checkout(.pro), .checkout(.lifetime), .portal(.payment), .resume, .refund, .saveKey, .removeKey] {
                out.append(F.make(status) { $0.busy = busy; $0.askingRefund = busy == .refund; $0.confirmingRemoveKey = busy == .removeKey })
            }
            for failure in [PlanSummaryInput.Failure.checkout(.pro), .checkout(.lifetime), .portal(.manage), .portal(.payment), .resume, .refund, .keySave(.invalid), .keySave(.management), .keySave(.generic), .keyRemove] {
                out.append(F.make(status) { $0.failure = failure })
            }
            out.append(F.make(status) { $0.askingRefund = true })
            out.append(F.make(status) { $0.confirmingRemoveKey = true })
            out.append(F.make(status) { $0.refundIssued = .pro })
            out.append(F.make(status) { $0.refundIssued = .lifetime })
        }
        out += [F.make(nil), F.make(nil) { $0.loadFailed = true }, F.make(F.pro) { $0.settling = true }]
        return out
    }
}
