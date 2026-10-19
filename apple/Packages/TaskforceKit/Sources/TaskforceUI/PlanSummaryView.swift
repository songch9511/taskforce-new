#if os(macOS)
import SwiftUI
import TaskforceKit

/// Plan & usage (0.2.0 Organisms, DS `PlanSummary`): Notice 하나(있으면) + 절들. 무엇을 그릴지는 Kit의 `PlanSummaryState`가 정한다 — 이것은 그리기만 한다.
/// DS 부품만 쓴다 (`Notice` · `SettingsSection` · `SettingsTrayRow` · `ConfirmRow` · `AgentActionButton` · `SecureFieldSm`): 색은 더하지 않는다 (실패 줄도 조용한 회색, 굵은 말은 Missing · Revoked뿐).
/// 버튼은 한 번에 하나만 눌린다: 동작이 진행 중이면(`state.isBusy`) 진행 중인 것 말고는 눌리지 않는다.
public struct PlanSummaryView: View {
    let state: PlanSummaryState
    let keyHandle: SecureFieldSmHandle
    let onAction: (PlanSummaryState.Action) -> Void
    let onSubmitKey: (SecretBox) -> Void

    public init(
        state: PlanSummaryState, keyHandle: SecureFieldSmHandle, onAction: @escaping (PlanSummaryState.Action) -> Void,
        onSubmitKey: @escaping (SecretBox) -> Void
    ) {
        self.state = state
        self.keyHandle = keyHandle
        self.onAction = onAction
        self.onSubmitKey = onSubmitKey
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SettingsTray.topicGap) {
            if let notice = state.notice {
                PlanSummaryNoticeView(notice: notice, locked: state.isBusy, onAction: onAction)
            }
            ForEach(state.sections) { section in
                PlanSummarySectionView(section: section, locked: state.isBusy, keyHandle: keyHandle, onAction: onAction, onSubmitKey: onSubmitKey)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Notice 하나: 제목 · 글 · (동작 버튼 하나). 환불 요청은 시계, 환불 끝은 체크, 나머지는 삼각 경고
struct PlanSummaryNoticeView: View {
    let notice: PlanSummaryState.Notice
    let locked: Bool
    let onAction: (PlanSummaryState.Action) -> Void

    static func icon(_ icon: PlanSummaryState.Notice.Icon) -> TFIcon {
        switch icon {
        case .warning: .paused
        case .clock: .refundRequested
        case .check: .check
        }
    }

    var body: some View {
        if let button = notice.button {
            Notice(icon: Self.icon(notice.icon), title: notice.title, message: notice.message) {
                AgentActionButton(button.title, busy: button.busy, prominent: button.prominent) { onAction(button.action) }
                    .disabled(locked && !button.busy)
            }
        } else {
            // 동작이 없으면 버튼 자리(위 10)도 없다
            Notice(icon: Self.icon(notice.icon), title: notice.title, message: notice.message)
        }
    }
}

/// 절 하나: 제목 · 트레이(줄들) · 각주. 읽지 못했을 때는 트레이 안에 조용한 회색 한 줄
struct PlanSummarySectionView: View {
    let section: PlanSummaryState.Section
    let locked: Bool
    let keyHandle: SecureFieldSmHandle
    let onAction: (PlanSummaryState.Action) -> Void
    let onSubmitKey: (SecretBox) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsTray.titleGap) {
            SettingsSection(section.title) {
                if let empty = section.empty {
                    AgentHintLine(empty)
                        .padding(SettingsTray.rowPadding)
                        .frame(maxWidth: .infinity, minHeight: SettingsTray.rowMinHeight, alignment: .leading)
                } else {
                    ForEach(section.rows) { row in
                        PlanSummaryRowView(row: row, locked: locked, keyHandle: keyHandle, onAction: onAction, onSubmitKey: onSubmitKey)
                    }
                }
            }
            if let footnote = section.footnote {
                PlanSummaryFootnoteView(footnote: footnote)
            }
        }
    }
}

struct PlanSummaryRowView: View {
    let row: PlanSummaryState.Row
    let locked: Bool
    let keyHandle: SecureFieldSmHandle
    let onAction: (PlanSummaryState.Action) -> Void
    let onSubmitKey: (SecretBox) -> Void

    /// 보조 글은 줄마다 한 줄 (조용한 회색, DS FieldMessage 힌트 톤)
    private var detail: String? { row.detail.isEmpty ? nil : row.detail.joined(separator: "\n") }

    /// 접근성 이름: 줄 라벨. 버튼은 자기 이름으로 말한다
    var body: some View {
        switch row.control {
        case .none:
            SettingsTrayRow(row.label, detail: detail)
        case .value(let value, let bold):
            SettingsTrayRow(row.label, detail: detail) {
                Text(value)
                    .font(bold ? TFFont.footnoteEmphasis : TFFont.footnote)
                    .foregroundStyle(bold ? TFColor.textPrimary : TFColor.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        case .button(let button):
            SettingsTrayRow(row.label, detail: detail) {
                AgentActionButton(button.title, busy: button.busy, prominent: button.prominent, accessibilityName: "\(button.title) \(row.label)") {
                    onAction(button.action)
                }
                .disabled(locked && !button.busy)
            }
        case .opens(let action):
            SettingsTrayRow(row.label, detail: detail, external: true, onOpen: { if !locked { onAction(action) } })
        case .confirm(let confirm):
            ConfirmRow(
                confirm.title, detail: confirm.detail, confirmLabel: confirm.confirmTitle, busy: confirm.busy,
                onConfirm: { onAction(confirm.confirm) }, onCancel: { onAction(confirm.cancel) }
            )
        case .keyField(let save):
            SettingsTrayRow(row.label, detail: detail) {
                HStack(spacing: TFSpace.xs) {
                    SecureFieldSm(label: PlanCopy.keyFieldName, placeholder: PlanCopy.keyPlaceholder, handle: keyHandle, onSubmit: onSubmitKey)
                    AgentActionButton(save.title, busy: save.busy, prominent: save.prominent, accessibilityName: "\(save.title) \(row.label)") {
                        keyHandle.submit()
                    }
                    .disabled(locked && !save.busy)
                }
            }
        }
    }
}

/// 각주: 문단마다 한 줄 이상, 법률 줄은 마지막 (DS SignIn 문장 + 나이 · 지역 문장, 링크 "Terms" · "Privacy Policy")
struct PlanSummaryFootnoteView: View {
    let footnote: PlanSummaryState.Footnote

    /// 법률 줄: 링크가 약관 · 처리방침 페이지로 간다
    static var legalLine: AttributedString {
        var line = AttributedString(PlanCopy.legalLead)
        var terms = AttributedString(PlanCopy.terms)
        terms.link = LegalLinks.terms
        var privacy = AttributedString(PlanCopy.privacyPolicy)
        privacy.link = LegalLinks.privacy
        line += terms
        line += AttributedString(PlanCopy.legalAnd)
        line += privacy
        line += AttributedString(PlanCopy.legalTrail)
        return line
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(footnote.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
            }
            if footnote.legal {
                Text(Self.legalLine)
                    .tint(TFColor.textLink)
            }
        }
        .font(TFFont.meta)
        .foregroundStyle(TFColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, SettingsTray.separatorInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Execution › Spending outside Taskforce (DS `ExternalCosts`): 다른 곳에서 내는 비용. 지금은 Claude Code 한 줄 — 사용자 자신의 Claude 플랜에 청구되고 Taskforce는 금액을 모른다
public struct SpendingOutsideSection: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: SettingsTray.titleGap) {
            SettingsSection(PlanCopy.spendingTitle) {
                SettingsTrayRow(PlanCopy.spendingClaudeCode, detail: PlanCopy.spendingBilledTo) {
                    SettingsValue(PlanCopy.spendingNotShared)
                }
            }
            Text(PlanCopy.spendingFootnote)
                .font(TFFont.meta)
                .foregroundStyle(TFColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, SettingsTray.separatorInset)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
#endif
