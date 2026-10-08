#if os(macOS)
import SwiftUI
import TaskforceKit
import TaskforceUI

/// Beta supplier USD is available to every signed-in account; execution credits remain separately gated.
struct UsageCreditsPane: View {
    @Environment(RunStore.self) private var runs
    @Environment(\.services) private var services
    @State private var budget: AiSpendSummary?
    @State private var budgetFailed = false
    @State private var billing: BillingSummary?
    @State private var billingFailed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                section("Your plan") {
                    SettingsCard {
                        if let billing {
                            SettingsRow(billing.label, subtitle: accessEnd(billing)) {
                                QuietButton("Manage") { SettingsOpener.open(.account) }
                            }
                        } else if billingFailed {
                            SettingsRow("Plan unavailable", subtitle: "Refresh to try again.") {
                                QuietButton("Refresh") { Task { await loadBilling() } }
                            }
                        } else {
                            SettingsRow("Loading plan") { ProgressView().controlSize(.small) }
                        }
                    }
                }
                section("Plan limits") {
                    if let budget {
                        SettingsCard {
                            VStack(alignment: .leading, spacing: TFSpace.md) {
                                HStack {
                                    Text("AI allowance").font(TFFont.footnoteEmphasis)
                                    Spacer()
                                    Text("\(AiSpendSummary.dollars(budget.remainingUSD)) remaining")
                                        .font(TFFont.footnote)
                                }
                                ProgressView(value: Self.allowanceFraction(budget))
                                    .tint(TFColor.textPrimary)
                                    .accessibilityLabel("AI allowance spent or reserved")
                                Text("\(AiSpendSummary.dollars(budget.confirmedUSD + budget.reservedUSD)) of \(AiSpendSummary.dollars(budget.capUSD)) spent or reserved")
                                    .font(TFFont.meta)
                                    .foregroundStyle(TFColor.textSecondary)
                                if let billing {
                                    Text(Self.resetDescription(billing))
                                        .font(TFFont.meta)
                                        .foregroundStyle(TFColor.textSecondary)
                                }
                            }
                            .padding(TFSpace.lg)
                            SettingsDivider()
                            budgetRow("Confirmed spend", budget.confirmedUSD)
                            SettingsDivider()
                            budgetRow("Reserved · \(budget.pendingCount) pending", budget.reservedUSD)
                        }
                        Text("Reservations are worst-case estimates, not confirmed spend. AI pauses at the limit with no automatic overage charges.")
                            .font(TFFont.meta)
                            .foregroundStyle(TFColor.textSecondary)
                        if let notice = budget.notice { Text(notice).font(TFFont.footnote) }
                    } else if budgetFailed {
                        SettingsCard {
                            SettingsRow("Allowance unavailable") {
                                QuietButton("Refresh") { Task { await loadBudget() } }
                            }
                        }
                    } else {
                        ProgressView().accessibilityLabel("Loading AI allowance")
                    }
                }
                if case .available = runs.credits {
                    content(runs.creditsRows(titles: Self.taskTitles))
                }
            }
            .frame(width: MacSettingsView.column, alignment: .leading)
            .padding(.top, 20)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        // 이 페이지를 열 때마다 새로 읽는다 (지급 · 정산 뒤 다시 열면 숫자 · 멈춘 카드가 바뀐다)
        .task(id: SettingsRoute.shared.openCount) {
            await loadBilling()
            await loadBudget()
            await runs.loadCredits()
            await runs.refreshActive()
        }
    }

    private func loadBudget() async {
        budget = nil
        budgetFailed = false
        do {
            guard let services else { budgetFailed = true; return }
            let result = try await services.api.aiBudget()
            guard !Task.isCancelled else { return }
            budget = result
        } catch {
            guard !Task.isCancelled else { return }
            budgetFailed = true
        }
    }

    private func loadBilling() async {
        billing = nil
        billingFailed = false
        do {
            guard let services else { billingFailed = true; return }
            let result = try await services.api.billing()
            guard !Task.isCancelled else { return }
            billing = result
        } catch {
            guard !Task.isCancelled else { return }
            billingFailed = true
        }
    }

    private func accessEnd(_ billing: BillingSummary) -> String? {
        (billing.currentPeriodEndsAt ?? billing.trialEndsAt).map { "Access until \(String($0.prefix(10))) (UTC)" }
    }

    static func allowanceFraction(_ budget: AiSpendSummary) -> Double {
        guard budget.capUSD > 0 else { return 0 }
        let value = NSDecimalNumber(decimal: (budget.confirmedUSD + budget.reservedUSD) / budget.capUSD).doubleValue
        return min(max(value, 0), 1)
    }

    static func resetDescription(_ billing: BillingSummary) -> String {
        if let reset = billing.allowanceResetsAt { return "Resets \(String(reset.prefix(10))) (UTC)" }
        if billing.status == "legacy_beta" { return "Cumulative beta allowance · no scheduled reset" }
        if billing.status == "trialing" || billing.status == "trial_pending" { return "Total trial allowance · no recurring reset" }
        return "No scheduled reset available"
    }

    private func budgetRow(_ title: String, _ amount: Decimal) -> some View {
        SettingsRow(title) { SettingsValue(AiSpendSummary.dollars(amount)) }
    }

    @ViewBuilder
    private func content(_ rows: CreditsRows) -> some View {
        section("Credits") {
            Text("Execution credits fund AI drafts. They are separate from your plan’s USD allowance.")
                .font(TFFont.meta)
                .foregroundStyle(TFColor.textSecondary)
            SettingsCard {
                row(rows.available)
                SettingsDivider()
                row(rows.reserved)
                if let pending = rows.pending {
                    SettingsDivider()
                    row(pending)
                }
            }
        }
        if let notice = rows.notice {
            Text(notice)
                .font(TFFont.meta)
                .foregroundStyle(TFColor.statusOverdue)
        }
        if let limitNotice = rows.limitNotice {
            Text(limitNotice)
                .font(TFFont.meta)
                .foregroundStyle(TFColor.textSecondary)
        }
        if let paused = rows.paused {
            SettingsCard {
                pausedRow(paused)
            }
        }
        section("This month") {
            SettingsCard {
                row(rows.used)
                SettingsDivider()
                row(rows.included)
            }
        }
    }

    /// 구역 제목(13 semibold) + 카드, 사이 10 (Figma Section)
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(TFFont.footnoteEmphasis)
                .foregroundStyle(TFColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    /// 제목 + 부제 + 오른쪽 값 (Available 값만 굵게). VoiceOver는 한 요소로 "Pending, Unknown, …"
    private func row(_ row: CreditsRows.Row) -> some View {
        SettingsRow(row.title, subtitle: row.subtitle) {
            if row.isEmphasized {
                Text(row.value)
                    .font(TFFont.footnoteEmphasis)
                    .foregroundStyle(TFColor.textPrimary)
                    .lineLimit(1)
            } else {
                SettingsValue(row.value)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.title)
        .accessibilityValue([row.value == "—" ? "Not available" : row.value, row.subtitle].compactMap { $0 }.joined(separator: ", "))
    }

    /// "N AI drafts are paused" 카드 (Figma Settings row, 아이콘 20 · 굵은 제목 · ›): 누르면 런처 범위 `Taskforce Working`
    private func pausedRow(_ card: CreditsRows.PausedCard) -> some View {
        Button {
            LauncherRoute.showTaskforceWorking()
        } label: {
            HStack(spacing: TFSpace.md) {
                Image(systemName: "pause.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(TFColor.textSecondary)
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: TFSpace.xxs) {
                    Text(card.title)
                        .font(TFFont.footnoteEmphasis)
                        .foregroundStyle(TFColor.textPrimary)
                    Text(card.subtitle)
                        .font(TFFont.meta)
                        .foregroundStyle(TFColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                DisclosureChevron()
            }
            .padding(.vertical, TFSpace.md)
            .padding(.horizontal, TFSpace.lg)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.title)
        .accessibilityValue(card.subtitle)
        .accessibilityHint("Shows Taskforce Working in the launcher")
    }

    /// 할 일 제목 (멈춘 run · 원가를 확인하는 중인 할 일): 런처가 받은 목록에서 찾는다 (`CreditsRows`: 모르는 할 일은 제목 없이 센다).
    /// 제목은 사용자 글이라 화면에 그릴 때만 읽고 따로 두지 않는다
    private static var taskTitles: [UUID: String] {
        guard let now = MacAppDelegate.shared?.launcher?.model.now else { return [:] }
        var titles: [UUID: String] = [:]
        for item in now.response?.now ?? [] { titles[item.action.id] = item.action.title }
        for action in now.response?.confirmations ?? [] { titles[action.id] = action.title }
        for action in now.doneToday { titles[action.id] = action.title }
        return titles
    }
}

/// 설정에서 런처로 가는 길 (U2 Mac PR4 → PR3): 런처를 열고 범위 `Taskforce Working`을 고른다.
/// 범위의 행 · 개수 · 메뉴 자리는 런처(PR3, `TaskScope.taskforceWorking` + `RunStore.workingActionIDs`)가 채운다
@MainActor
enum LauncherRoute {
    static func showTaskforceWorking() {
        guard let launcher = MacAppDelegate.shared?.launcher else { return }
        launcher.show()
        launcher.model.chooseScope(.taskforceWorking)
    }
}
#endif
