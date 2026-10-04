#if os(macOS)
import SwiftUI
import TaskforceKit
import TaskforceUI

/// 설정 Usage & Credits (Figma S3 240:1907): 설명 · Balance(Available · Reserved · Pending) · 멈춘 단계 카드 · This month(Used · Included in your plan).
/// 숫자는 서버가 정하고(`GET /credits`), 행 값 · 부제는 `CreditsRows`가 만든다. 사이드바 항목은 실행을 쓸 수 있을 때만 보인다 (`MacSettingsTab`).
/// `Add Credits…`(Figma 머리)는 숨긴다: 크레딧은 운영자가 지급하고(C3) 구매 경로가 없다 (U2 Mac 계획 열린 질문 1).
struct UsageCreditsPane: View {
    @Environment(RunStore.self) private var runs

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Credits are used when Taskforce does work you hand it. Finding tasks, your list, and checking results are free.")
                    .font(TFFont.footnote)
                    .foregroundStyle(TFColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.top, TFSpace.lg)
                } else {
                    content(runs.creditsRows(titles: Self.taskTitles))
                }
            }
            .frame(width: MacSettingsView.column, alignment: .leading)
            .padding(.top, 20)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        // 이 페이지를 열 때마다 새로 읽는다 (지급 · 정산 뒤 다시 열면 숫자 · 멈춘 카드가 바뀐다)
        .task {
            await runs.loadCredits()
            await runs.refreshActive()
        }
    }

    /// 앱을 막 열어 아직 한 번도 읽지 못함 (읽기가 실패했으면 "—"와 안내 한 줄을 보인다)
    private var isLoading: Bool {
        runs.credits == .unknown && !runs.creditsFailed
    }

    @ViewBuilder
    private func content(_ rows: CreditsRows) -> some View {
        section("Balance") {
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

    /// "2 paid steps are paused" 카드 (Figma Settings row, 아이콘 20 · 굵은 제목 · ›): 누르면 런처 범위 `Taskforce Working`
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
