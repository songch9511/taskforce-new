#if os(macOS)
import SwiftUI
import TaskforceKit
import TaskforceUI

/// Usage & Credits (옛 창): "Your plan" 한 줄(Plan & usage와 같은 모델의 Plan 줄)과 실행 크레딧. 옛 USD 한도("Plan limits")는 10-09 가격에서 사라졌다:
/// 사용자에게 보이는 월 한도는 없고, 공정 사용 안전장치에 닿으면 Plan & usage의 Notice가 이유를 말한다. 실행 크레딧은 별개라 그대로 둔다
struct UsageCreditsPane: View {
    @Environment(RunStore.self) private var runs
    @Environment(SessionStore.self) private var session
    @Environment(\.services) private var services
    @State private var plan = PlanSummaryStore()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                section("Your plan") {
                    SettingsCard {
                        planRow(plan.state.compact)
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
        // 플랜은 Plan & usage와 같은 생애로 읽는다 (계정 · 다시 활성화 · 다시 열기)
        .modifier(PlanSummaryLifecycle(
            store: plan, userID: SettingsWindowSession.accountUserID(session), gateway: PlanGateways.current(services),
            currentAccount: PlanAccount.current(session), invalidatesOnDisappear: true
        ))
        // 이 페이지를 열 때마다 새로 읽는다 (지급 · 정산 뒤 다시 열면 숫자 · 멈춘 카드가 바뀐다)
        .task(id: SettingsRoute.shared.openCount) {
            await runs.loadCredits()
            await runs.refreshActive()
        }
    }

    /// 같은 모델의 Plan 줄 하나 (라벨 + 날짜 한 줄). 못 읽었으면 한 줄 + Refresh
    @ViewBuilder
    private func planRow(_ compact: PlanSummaryState.Compact) -> some View {
        if compact.failed {
            SettingsRow(compact.label) {
                QuietButton("Refresh") { Task { await plan.refresh() } }
            }
        } else {
            SettingsRow(compact.label, subtitle: compact.detail) {
                QuietButton("Manage") { SettingsOpener.open(.account) }
            }
        }
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
            TaskWorkRoute.show()
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
        .accessibilityHint("Opens tasks in Taskforce")
    }

    /// 할 일 제목 (멈춘 run · 원가를 확인하는 중인 할 일): 런처가 받은 목록에서 찾는다 (`CreditsRows`: 모르는 할 일은 제목 없이 센다).
    /// 제목은 사용자 글이라 화면에 그릴 때만 읽고 따로 두지 않는다
    private static var taskTitles: [UUID: String] {
        guard let now = MacAppDelegate.shared?.launcherModel?.now else { return [:] }
        var titles: [UUID: String] = [:]
        for item in now.response?.now ?? [] { titles[item.action.id] = item.action.title }
        for action in now.response?.confirmations ?? [] { titles[action.id] = action.title }
        for action in now.doneToday { titles[action.id] = action.title }
        return titles
    }
}

/// Settings opens the current task shell; the retired launcher is never constructed.
@MainActor
enum TaskWorkRoute {
    static func show() {
        MacAppDelegate.shared?.openTaskforce()
    }
}
#endif
