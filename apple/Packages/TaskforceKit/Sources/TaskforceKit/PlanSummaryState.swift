import Foundation

/// Plan & usage 한 화면이 알아야 하는 것: 서버 상태 + 이 화면에서 진행 중인 동작. 순수 값이다 (화면 · 네트워크 0).
public struct PlanSummaryInput: Equatable, Sendable {
    /// 지금 하고 있는 동작 하나 (한 번에 하나). 그 버튼은 스피너를 달고 다른 버튼은 눌리지 않는다
    public enum Busy: Equatable, Sendable {
        case checkout(PlanCheckoutKind), portal(PlanPortalTarget), resume, refund, saveKey, removeKey
    }

    /// 방금 한 동작의 실패 (조용한 회색 한 줄, 빨강 아님). 그 동작의 줄 아래에 선다
    public enum Failure: Equatable, Sendable {
        case checkout(PlanCheckoutKind), portal(PlanPortalTarget), resume, refund
        case keySave(KeyFailure), keyRemove
    }

    public enum KeyFailure: Equatable, Sendable {
        /// 422 `ai_key_invalid`: OpenRouter가 거절했거나 모양이 아니다
        case invalid
        /// 422 `ai_key_management`: 관리 키를 붙여 넣었다
        case management
        /// 그 밖(통신 · 서버 · 속도 제한): 키를 저장하지 않았다
        case generic
    }

    /// 환불이 끝난 플랜 ("Refund issued" Notice의 문장이 이것을 따른다)
    public enum IssuedPlan: Equatable, Sendable {
        case pro, lifetime
    }

    /// nil = 아직 읽지 못함
    public var status: BillingStatusV2?
    /// 읽지 못한 채로 끝났다 (읽은 값이 있으면 그대로 두므로 `status`가 nil일 때만 뜻이 있다)
    public var loadFailed = false
    /// checkout을 열고 돌아와 상태를 다시 읽는 중 ("Checking…")
    public var settling = false
    public var busy: Busy?
    public var failure: Failure?
    /// 환불 확인 줄이 열려 있다 (제자리 확인, Cancel이 먼저)
    public var askingRefund = false
    /// 키 지우기 확인 줄이 열려 있다
    public var confirmingRemoveKey = false
    /// 이 화면에서 환불을 요청했다 (서버 응답이 아직 `requested`로 바뀌기 전에도 Notice가 선다)
    public var refundRequested = false
    public var refundIssued: IssuedPlan?
    public var now: Date
    public var calendar: Calendar

    public init(
        status: BillingStatusV2? = nil, loadFailed: Bool = false, settling: Bool = false, busy: Busy? = nil, failure: Failure? = nil,
        askingRefund: Bool = false, confirmingRemoveKey: Bool = false, refundRequested: Bool = false, refundIssued: IssuedPlan? = nil,
        now: Date = Date(), calendar: Calendar = .current
    ) {
        self.status = status
        self.loadFailed = loadFailed
        self.settling = settling
        self.busy = busy
        self.failure = failure
        self.askingRefund = askingRefund
        self.confirmingRemoveKey = confirmingRemoveKey
        self.refundRequested = refundRequested
        self.refundIssued = refundIssued
        self.now = now
        self.calendar = calendar
    }
}

/// Plan & usage의 줄 · 각주 · Notice · 동작 (OA 결제 계약 9.2, DS `PlanSummary` + 승인된 DZ 그림). 순수 규칙이다: Release 옛 창(`MacSettingsView`)과
/// 0.2.0 창이 같은 값을 그린다 — 문구가 두 벌로 갈리지 않는다. 가격 · 날짜 · 토큰은 서버 값이고 Mac에 숫자 상수는 없다.
/// Notice는 한 번에 하나만 선다. 순서: 환불 결과(방금 한 동작) > 결제 문제(Payment failed · Pro ended) > 키 문제(402 · 403) > 공정 사용 상한.
/// 401(Revoked)은 Notice 없이 Key 줄의 굵은 말이 알린다.
public struct PlanSummaryState: Equatable, Sendable {
    public enum Action: Hashable, Sendable {
        case checkout(PlanCheckoutKind)
        case portal(PlanPortalTarget)
        case resume
        case askRefund, confirmRefund, cancelRefund
        /// 키 칸의 Save (칸에서 값을 한 번 읽어 보낸다: 값은 이 enum을 지나가지 않는다)
        case saveKey
        case askRemoveKey, confirmRemoveKey, cancelRemoveKey
    }

    public struct Button: Equatable, Sendable {
        public let title: String
        public let action: Action
        /// 잉크 버튼 (한 화면에 하나 — Start / Restart / Resume / Update payment method). 나머지는 `bg/field` 면
        public let prominent: Bool
        public let busy: Bool

        init(_ title: String, _ action: Action, prominent: Bool = false, busy: Bool = false) {
            self.title = title
            self.action = action
            self.prominent = prominent
            self.busy = busy
        }
    }

    public struct Notice: Equatable, Sendable {
        public enum Icon: Equatable, Sendable {
            case warning, clock, check
        }

        public let icon: Icon
        public let title: String
        public let message: String?
        public let button: Button?
    }

    public struct Confirm: Equatable, Sendable {
        public let title: String
        public let detail: String
        public let confirmTitle: String
        public let confirm: Action
        public let cancel: Action
        public let busy: Bool
    }

    public enum Control: Equatable, Sendable {
        case none
        /// 읽기 전용 값. 굵은 말은 DS가 정한 "Missing" · "Revoked"뿐이다
        case value(String, bold: Bool)
        case button(Button)
        /// 행 전체가 브라우저를 연다 (↗, Manage subscription)
        case opens(Action)
        /// 이 행 자리를 바꾸는 제자리 확인 (ConfirmRow)
        case confirm(Confirm)
        /// 키 칸 + Save (칸은 `SecureFieldSm`, 값은 `SecretBox`)
        case keyField(save: Button)
    }

    public struct Row: Equatable, Identifiable, Sendable {
        public let id: String
        public let label: String
        /// 라벨 아래 보조 글 (조용한 회색). 한 줄씩이다
        public let detail: [String]
        public let control: Control
    }

    /// 각주: 문단 하나씩, `legal`이면 마지막에 법률 줄(링크 Terms · Privacy Policy)이 붙는다
    public struct Footnote: Equatable, Sendable {
        public let paragraphs: [String]
        public let legal: Bool
    }

    public struct Section: Equatable, Identifiable, Sendable {
        public let id: String
        public let title: String?
        public let rows: [Row]
        public let footnote: Footnote?
        /// 트레이 대신 회색 한 줄 (못 읽음)
        public let empty: String?
    }

    /// Usage & Credits › Your plan (옛 창): 같은 모델의 Plan 줄 하나
    public struct Compact: Equatable, Sendable {
        public let label: String
        public let detail: String?
        public let failed: Bool
    }

    public let notice: Notice?
    public let sections: [Section]
    public let compact: Compact
    /// 동작이 하나라도 진행 중이다: 모든 버튼이 눌리지 않는다
    public let isBusy: Bool

    /// 지금 보이는 행 전부 (시험 · 접근성 순서)
    public var rows: [Row] { sections.flatMap(\.rows) }
}

extension PlanSummaryState {
    public static func make(_ input: PlanSummaryInput) -> PlanSummaryState {
        Builder(input).build()
    }
}

private struct Builder {
    typealias S = PlanSummaryState
    let i: PlanSummaryInput

    init(_ input: PlanSummaryInput) { i = input }

    private func date(_ value: Date?) -> String? {
        value.map { PlanSummaryFormat.date($0, now: i.now, calendar: i.calendar) }
    }

    private func planRow(_ value: String, detail: [String] = []) -> S.Row {
        S.Row(id: "plan", label: PlanCopy.planLabel, detail: detail, control: .value(value, bold: false))
    }

    private func valueRow(_ id: String, _ label: String, _ value: String?) -> S.Row? {
        value.map { S.Row(id: id, label: label, detail: [], control: .value($0, bold: false)) }
    }

    func build() -> S {
        let isBusy = i.busy != nil
        guard let status = i.status else {
            if i.loadFailed {
                return S(
                    notice: nil, sections: [S.Section(id: "plan", title: PlanCopy.sectionTitle, rows: [], footnote: nil, empty: PlanCopy.somethingWentWrong)],
                    compact: S.Compact(label: PlanCopy.somethingWentWrong, detail: nil, failed: true), isBusy: isBusy
                )
            }
            return checking(isBusy: isBusy)
        }
        if i.settling || status.state == .unknown { return checking(isBusy: isBusy) }
        // 환불이 끝났다 (이 화면에서 요청하고 다시 읽었더니 플랜이 끝났다): DS처럼 Notice + "No plan"만 남는다
        if let issued = i.refundIssued, status.state == .none || status.state == .lapsed {
            let notice = S.Notice(
                icon: .check, title: PlanCopy.refundIssuedTitle,
                message: issued == .lifetime ? PlanCopy.refundIssuedLifetimeBody : PlanCopy.refundIssuedProBody, button: nil
            )
            return S(
                notice: notice, sections: [S.Section(id: "plan", title: PlanCopy.sectionTitle, rows: [planRow(PlanCopy.noPlan)], footnote: nil, empty: nil)],
                compact: S.Compact(label: PlanCopy.noPlan, detail: nil, failed: false), isBusy: isBusy
            )
        }
        let body = rows(for: status)
        var sections = [S.Section(id: "plan", title: PlanCopy.sectionTitle, rows: body.rows, footnote: body.footnote, empty: nil)]
        if status.state == .lifetime, status.aiKey != nil { sections.append(openRouterSection(status)) }
        return S(notice: notice(for: status), sections: sections, compact: body.compact, isBusy: isBusy)
    }

    private func checking(isBusy: Bool) -> S {
        S(
            notice: nil, sections: [S.Section(id: "plan", title: PlanCopy.sectionTitle, rows: [planRow(PlanCopy.checking)], footnote: nil, empty: nil)],
            compact: S.Compact(label: PlanCopy.checking, detail: nil, failed: false), isBusy: isBusy
        )
    }

    // MARK: 줄

    private struct Body {
        var rows: [S.Row]
        var footnote: S.Footnote?
        var compact: S.Compact
    }

    private func rows(for s: BillingStatusV2) -> Body {
        switch s.state {
        case .none: return noPlan(s)
        case .trial: return trial(s)
        case .pro: return pro(s)
        case .cancelled: return cancelled(s)
        case .pastDue: return pastDue(s)
        case .lapsed: return lapsed(s)
        case .lifetime: return lifetime(s)
        case .beta: return beta(s)
        case .unknown: return Body(rows: [planRow(PlanCopy.checking)], footnote: nil, compact: S.Compact(label: PlanCopy.checking, detail: nil, failed: false))
        }
    }

    private func compact(_ label: String, _ detail: String? = nil) -> S.Compact { S.Compact(label: label, detail: detail, failed: false) }

    private func legalIfSelling(_ s: BillingStatusV2) -> Bool { s.canCheckout || s.canBuyLifetime }

    /// "Pro · Monthly"의 주기. 모르는 플랜이면 없다
    private func cadence(_ s: BillingStatusV2) -> String? {
        switch s.plan {
        case .monthly: "Monthly"
        case .annual: "Yearly"
        case .lifetime, .none: nil
        }
    }

    private func noPlan(_ s: BillingStatusV2) -> Body {
        var rows = [planRow(PlanCopy.noPlan)]
        if s.canCheckout { rows.append(proStartRow(s)) }
        if s.canBuyLifetime { rows.append(lifetimeRow(s)) }
        let footnote = S.Footnote(paragraphs: ["\(PlanCopy.noPlanFootnote) \(PlanCopy.claudeCodeLine)"], legal: legalIfSelling(s))
        return Body(rows: rows, footnote: footnote, compact: compact(PlanCopy.noPlan))
    }

    private func trial(_ s: BillingStatusV2) -> Body {
        let end = date(s.trialEndsAt)
        let price = s.plan == .annual ? s.prices.proYearly : s.prices.proFirstMonth
        var rows = [planRow(PlanCopy.trialPlan)]
        rows.append(contentsOf: [
            valueRow("trial-ends", PlanCopy.trialEnds, end),
            valueRow("first-charge", PlanCopy.firstCharge, end.map { PlanCopy.firstChargeValue(date: $0, price: price) }),
        ].compactMap { $0 })
        rows.append(manageRow())
        return Body(
            rows: rows, footnote: S.Footnote(paragraphs: [PlanCopy.trialFootnote], legal: false),
            compact: compact(PlanCopy.trialPlan, end.map { PlanCopy.summary(PlanCopy.trialEnds, $0) })
        )
    }

    private func pro(_ s: BillingStatusV2) -> Body {
        let price: String? = switch s.plan {
        case .monthly: s.prices.proMonthly
        case .annual: s.prices.proYearly
        case .lifetime, .none: nil
        }
        let unit: String? = s.plan == .annual ? "year" : (s.plan == .monthly ? "month" : nil)
        let plan = PlanCopy.proPlan(cadence(s), price: price, unit: unit)
        let renew = date(s.currentPeriodEndsAt)
        var rows = [planRow(plan)]
        if let valueRow = valueRow("renews", PlanCopy.renews, renew) { rows.append(valueRow) }
        if let usage = s.aiUsage {
            rows.append(S.Row(id: "usage", label: PlanCopy.aiUsage, detail: [PlanCopy.usageDetail], control: .value(PlanSummaryFormat.tokens(usage.totalTokens), bold: false)))
        }
        rows.append(manageRow())
        if let refund = refundRow(s) { rows.append(refund) }
        return Body(
            rows: rows, footnote: S.Footnote(paragraphs: [PlanCopy.proFootnote], legal: false),
            compact: compact(PlanCopy.proPlan(cadence(s), price: nil, unit: nil), renew.map { PlanCopy.summary(PlanCopy.renews, $0) })
        )
    }

    private func cancelled(_ s: BillingStatusV2) -> Body {
        let until = date(s.cancelAt ?? s.currentPeriodEndsAt)
        var rows = [planRow(PlanCopy.cancelledPlan)]
        if let valueRow = valueRow("available-until", PlanCopy.availableUntil, until) { rows.append(valueRow) }
        // Pro가 아직 돌고 있는 동안은 Lifetime 줄이 없다 (코디네이터 결정 2): Resume이 주 동작
        var detail: [String] = []
        if i.failure == .resume { detail.append(PlanCopy.somethingWentWrong) }
        rows.append(S.Row(
            id: "resume", label: PlanCopy.resumePro, detail: detail,
            control: .button(S.Button(PlanCopy.resume, .resume, prominent: true, busy: i.busy == .resume))
        ))
        return Body(rows: rows, footnote: nil, compact: compact(PlanCopy.cancelledPlan, until.map { PlanCopy.summary(PlanCopy.availableUntil, $0) }))
    }

    private func pastDue(_ s: BillingStatusV2) -> Body {
        let due = date(s.currentPeriodEndsAt)
        // Update payment method의 실패는 Notice 안에 자리가 없어 Plan 줄 아래에 선다
        var rows = [planRow(PlanCopy.proPlan(cadence(s), price: nil, unit: nil), detail: i.failure == .portal(.payment) ? [PlanCopy.somethingWentWrong] : [])]
        if let valueRow = valueRow("due", PlanCopy.paymentDue, due) { rows.append(valueRow) }
        return Body(
            rows: rows, footnote: nil,
            compact: compact(PlanCopy.proPlan(cadence(s), price: nil, unit: nil), due.map { PlanCopy.summary(PlanCopy.paymentDue, $0) })
        )
    }

    private func lapsed(_ s: BillingStatusV2) -> Body {
        // 끝난 날짜는 서버가 줄 때만 보인다 (지금 v2 상태는 끝난 계정에 날짜를 주지 않는다)
        let end = date(s.currentPeriodEndsAt ?? s.cancelAt ?? s.trialEndsAt)
        // Restart Pro의 실패는 Notice 안에 자리가 없어 Plan 줄 아래에 선다
        var detail: [String] = []
        if i.failure == .checkout(.pro) { detail.append(PlanCopy.checkoutFailed) }
        var rows = [planRow(PlanCopy.noActivePlan, detail: detail)]
        if let valueRow = valueRow("ended", PlanCopy.ended, end) { rows.append(valueRow) }
        if s.canBuyLifetime { rows.append(lifetimeRow(s)) }
        var paragraph = PlanCopy.lapsedFootnote
        if s.canCheckout { paragraph += " \(PlanCopy.proTaxLine)" }
        return Body(
            rows: rows, footnote: S.Footnote(paragraphs: [paragraph], legal: legalIfSelling(s)),
            compact: compact(PlanCopy.noActivePlan, end.map { PlanCopy.summary(PlanCopy.ended, $0) })
        )
    }

    private func lifetime(_ s: BillingStatusV2) -> Body {
        var rows = [planRow(PlanCopy.lifetime)]
        if let refund = refundRow(s) { rows.append(refund) }
        return Body(rows: rows, footnote: nil, compact: compact(PlanCopy.lifetime))
    }

    private func beta(_ s: BillingStatusV2) -> Body {
        // 고지 전에는 "Beta"만: 체험 · 카운트다운 · 결제 요소 0 (DS README). 고지가 잡힌 뒤에만 Pro · Lifetime 줄이 나온다
        guard let until = date(s.noticeEndsAt) else {
            return Body(rows: [planRow(PlanCopy.beta)], footnote: nil, compact: compact(PlanCopy.beta))
        }
        let value = PlanCopy.betaUntil(until)
        var rows = [planRow(value)]
        if s.canCheckout { rows.append(proStartRow(s)) }
        if s.canBuyLifetime { rows.append(lifetimeRow(s)) }
        let footnote = legalIfSelling(s) ? S.Footnote(paragraphs: [], legal: true) : nil
        return Body(rows: rows, footnote: footnote, compact: compact(value))
    }

    // MARK: 부품 줄

    private func proStartRow(_ s: BillingStatusV2) -> S.Row {
        var detail = [PlanCopy.proOffer(monthly: s.prices.proMonthly, firstMonth: s.prices.proFirstMonth, yearly: s.prices.proYearly, withTrial: s.withTrial)]
        if i.failure == .checkout(.pro) { detail.append(PlanCopy.checkoutFailed) }
        detail.append(PlanCopy.proTaxLine)
        let title = s.withTrial ? PlanCopy.startTrial : PlanCopy.startPro
        return S.Row(
            id: "pro", label: PlanCopy.pro, detail: detail,
            control: .button(S.Button(title, .checkout(.pro), prominent: true, busy: i.busy == .checkout(.pro)))
        )
    }

    private func lifetimeRow(_ s: BillingStatusV2) -> S.Row {
        var detail = [PlanCopy.lifetimeOffer(s.prices.lifetime)]
        if i.failure == .checkout(.lifetime) { detail.append(PlanCopy.checkoutFailed) }
        detail.append(PlanCopy.lifetimeTaxLine)
        return S.Row(
            id: "lifetime", label: PlanCopy.lifetime, detail: detail,
            control: .button(S.Button(PlanCopy.buyLifetime, .checkout(.lifetime), busy: i.busy == .checkout(.lifetime)))
        )
    }

    private func manageRow() -> S.Row {
        let failed = i.failure == .portal(.manage)
        return S.Row(id: "manage", label: PlanCopy.manageSubscription, detail: failed ? [PlanCopy.somethingWentWrong] : [], control: .opens(.portal(.manage)))
    }

    /// 환불은 결제 3일 안(`refund_until`)에서만 보이고, 요청했으면 Notice가 대신 선다
    private func refundRow(_ s: BillingStatusV2) -> S.Row? {
        guard let until = date(s.refundUntil), s.refundState == .idle, !i.refundRequested else { return nil }
        if i.askingRefund || i.busy == .refund {
            let lifetime = s.state == .lifetime
            return S.Row(
                id: "refund", label: PlanCopy.askRefundTitle, detail: [],
                control: .confirm(S.Confirm(
                    title: PlanCopy.askRefundTitle, detail: lifetime ? PlanCopy.lifetimeRefundBody : PlanCopy.refundProBody,
                    confirmTitle: PlanCopy.requestRefundConfirm, confirm: .confirmRefund, cancel: .cancelRefund, busy: i.busy == .refund
                ))
            )
        }
        var detail = [PlanCopy.available(until: until)]
        if i.failure == .refund { detail.append(PlanCopy.somethingWentWrong) }
        return S.Row(
            id: "refund", label: PlanCopy.requestRefundRow, detail: detail,
            control: .button(S.Button(PlanCopy.requestRefundAction, .askRefund))
        )
    }

    // MARK: OpenRouter 절 (Lifetime)

    private func openRouterSection(_ s: BillingStatusV2) -> S.Section {
        let key = s.aiKey ?? .missing
        var rows: [S.Row] = []
        let (word, bold) = switch key {
        case .connected: (PlanCopy.connected, false)
        case .missing: (PlanCopy.missing, true)
        case .revoked: (PlanCopy.revoked, true)
        }
        rows.append(S.Row(id: "key", label: PlanCopy.key, detail: [PlanCopy.keyBilled], control: .value(word, bold: bold)))
        var entryDetail: [String] = []
        if case .keySave(let failure) = i.failure {
            let line: String = switch failure {
            case .invalid: PlanCopy.keyInvalid
            case .management: PlanCopy.keyManagement
            case .generic: PlanCopy.somethingWentWrong
            }
            entryDetail.append(line)
        }
        rows.append(S.Row(
            id: "key-entry", label: key == .connected ? PlanCopy.replaceKey : PlanCopy.addKey, detail: entryDetail,
            // 키가 이미 있으면 Save는 잉크가 아니다 (바꾸는 일은 주 동작이 아니다)
            control: .keyField(save: S.Button(PlanCopy.save, .saveKey, prominent: key != .connected, busy: i.busy == .saveKey))
        ))
        // 지울 키가 없으면(Missing) Remove key 줄도 없다. Connected · Revoked에서 보인다
        if key != .missing {
            if i.confirmingRemoveKey || i.busy == .removeKey {
                rows.append(S.Row(
                    id: "key-remove", label: PlanCopy.removeKeyRow, detail: [],
                    control: .confirm(S.Confirm(
                        title: PlanCopy.removeKeyTitle, detail: PlanCopy.removeKeyBody, confirmTitle: PlanCopy.removeKeyConfirm,
                        confirm: .confirmRemoveKey, cancel: .cancelRemoveKey, busy: i.busy == .removeKey
                    ))
                ))
            } else {
                rows.append(S.Row(
                    id: "key-remove", label: PlanCopy.removeKeyRow, detail: i.failure == .keyRemove ? [PlanCopy.somethingWentWrong] : [],
                    control: .button(S.Button(PlanCopy.removeKeyAction, .askRemoveKey))
                ))
            }
        }
        return S.Section(
            id: "openrouter", title: PlanCopy.openRouter, rows: rows,
            footnote: S.Footnote(paragraphs: ["\(PlanCopy.openRouterFootnote) \(PlanCopy.openRouterZeroRetention)"], legal: false), empty: nil
        )
    }

    // MARK: Notice (한 번에 하나)

    private func notice(for s: BillingStatusV2) -> S.Notice? {
        // 방금 한 동작의 결과: 순서 밖이고 떠 있는 동안 자리를 쓴다
        if s.refundState == .requested || i.refundRequested {
            return S.Notice(icon: .clock, title: PlanCopy.refundRequestedTitle, message: PlanCopy.refundRequestedBody, button: nil)
        }
        // 결제 문제
        if s.state == .pastDue {
            let button = S.Button(PlanCopy.updatePayment, .portal(.payment), prominent: true, busy: i.busy == .portal(.payment))
            return S.Notice(icon: .warning, title: PlanCopy.paymentFailedTitle, message: PlanCopy.paymentFailedBody, button: button)
        }
        if s.state == .lapsed {
            let button = s.canCheckout ? S.Button(PlanCopy.restartPro, .checkout(.pro), prominent: true, busy: i.busy == .checkout(.pro)) : nil
            return S.Notice(icon: .warning, title: PlanCopy.endedTitle, message: PlanCopy.endedBody, button: button)
        }
        // 키 문제: 402 · 403 (글만, 동작 없음). 401은 Notice 없이 Key 줄의 "Revoked"가 알린다
        if s.state == .lifetime, s.aiKey == .connected, s.aiKeySpendErrorAt != nil {
            return S.Notice(icon: .warning, title: PlanCopy.openRouterCantPayTitle, message: PlanCopy.openRouterCantPayBody, button: nil)
        }
        // 공정 사용 상한: 숫자는 보이지 않는다. 체험이면 체험의 상한이라고 말한다
        if let until = date(s.fairUsePausedUntil) {
            let body = s.state == .trial ? PlanCopy.fairUseTrialBody : PlanCopy.fairUseProBody
            return S.Notice(icon: .warning, title: PlanCopy.fairUseTitle(until), message: body, button: nil)
        }
        return nil
    }
}
