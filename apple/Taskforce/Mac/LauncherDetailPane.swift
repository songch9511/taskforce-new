#if os(macOS)
import SwiftUI
import TaskforceKit
import TaskforceUI

/// 상세 칸 (Figma M1 `Detail viewport`, bg/elevated, 안쪽 위 18 · 좌우 24): U1은 임시 상세다.
/// 제목(자르지 않음) · 기한 · Review 이유 · Taskforce 갈래(U2 Mac, `LauncherLaneView`) · 원문(`EvidenceDigest`의 근거 줄, 종이 위 인용).
/// 나머지 갈래(`You` · `Waiting on` · `Done when`)는 U5 · U6a가 갈래 자리에 끼운다.
/// 저장본 행(오프라인)은 저장된 제목 · 기한만 있다. Run with AI(M8) · 초안 화면이면 이 칸이 그 화면이 된다.
struct LauncherDetailPane: View {
    @Bindable var model: LauncherModel
    var onClose: (() -> Void)? = nil

    /// 아래에 더 있는지 (아래 흐림)
    @State private var hasMoreBelow = false

    var body: some View {
        switch model.screen {
        case .runWithAI(let target): LauncherRunPane(model: model, target: target)
        case .handoff(let target): LauncherHandoffPane(model: model, target: target)
        case .draft(_, let artifact): LauncherDraftPane(artifact: artifact)
        default:
            detail
        }
    }

    private var detail: some View {
        ScrollView {
            detailContent
                .padding(.horizontal, TFSpace.xl)
                .padding(.top, 18)
                .padding(.bottom, TFSpace.xl)
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.containerSize.height < geometry.contentSize.height - 1
        } action: { _, more in
            hasMoreBelow = more
        }
        .background(TFColor.bgElevated)
        .scrollEdgeFade(TFColor.bgElevated, isActive: hasMoreBelow)
    }

    @ViewBuilder
    private var detailContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let target = model.detailTarget {
                header(title: target.action.title, due: target.group == .doneToday ? nil : target.action.dueDate,
                       reason: target.group == .review ? ConfirmReasonText.label(target.action.confirmReasons) : nil)
                // 갈래 자리 (Taskforce: U2 Mac, 나머지는 U5 · U6a)
                LauncherLaneView(model: model, target: target)
                sources(target.action.id)
            } else if let row = model.detailSavedRow {
                header(title: row.task.title, due: row.task.status == .doneToday ? nil : row.task.dueDate, reason: nil)
                Text("Saved · \(row.task.status.group.title)")
                    .font(TFFont.meta)
                    .foregroundStyle(TFColor.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var today: LocalDate { DueDateFormat.today() }

    /// 제목 20 semibold (자르지 않음) + 기한 · 확인 이유 12
    private func header(title: String, due: LocalDate?, reason: String?) -> some View {
        HStack(alignment: .top, spacing: TFSpace.sm) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(TFFont.title)
                    .foregroundStyle(TFColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if due != nil || reason != nil {
                    VStack(alignment: .leading, spacing: TFSpace.xs) {
                        if let due {
                            Text("Due \(DueText.short(due, today: today))")
                                .foregroundStyle(DueText.isUrgent(due: due, reasons: [], today: today) ? TFColor.statusOverdue : TFColor.textSecondary)
                        }
                        if let reason {
                            Text(reason).foregroundStyle(TFColor.textSecondary)
                        }
                    }
                    .font(TFFont.meta)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TFColor.textSecondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close task details")
                .accessibilityLabel("Close task details")
            }
        }
    }

    @ViewBuilder
    private func sources(_ id: UUID) -> some View {
        if let digest = model.now?.evidence[id], !digest.isEmpty {
            VStack(alignment: .leading, spacing: TFSpace.sm) {
                Text(digest.lines.count == 1 ? "Source" : "Sources")
                    .font(TFFont.footnoteEmphasis)
                    .foregroundStyle(TFColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                // 가장 최근 근거(지금 상태를 만든 말)가 위
                ForEach(digest.lines.reversed()) { line in
                    SourceSlip(line: line) { url in model.open(url) }
                }
            }
        } else if model.now?.evidenceLoading.contains(id) == true {
            HStack(spacing: TFSpace.xs) {
                ProgressView().controlSize(.small)
                Text("Loading source details…")
            }
            .font(TFFont.meta)
            .foregroundStyle(TFColor.textSecondary)
        } else if model.now?.evidenceFailed.contains(id) == true {
            HStack(spacing: TFSpace.sm) {
                Text("Couldn't load sources.")
                    .font(TFFont.meta)
                    .foregroundStyle(TFColor.textSecondary)
                Button("Retry") { Task { await model.now?.loadEvidence(id, force: true) } }
                    .buttonStyle(.plain)
            }
        } else {
            Text("No source details available.")
                .font(TFFont.meta)
                .foregroundStyle(TFColor.textSecondary)
        }
    }
}

private struct LauncherHandoffPane: View {
    @Bindable var model: LauncherModel
    let target: LauncherModel.Target

    @State private var hasMoreBelow = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Hand off to AI")
                        .font(TFFont.title)
                        .foregroundStyle(TFColor.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text(target.action.title)
                        .font(TFFont.meta)
                        .foregroundStyle(TFColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let state = model.handoffPaneState {
                    if state.isLoading {
                        HStack(spacing: TFSpace.xs) {
                            ProgressView().controlSize(.small)
                            Text("Preparing handoff…")
                        }
                        .font(TFFont.meta)
                        .foregroundStyle(TFColor.textSecondary)
                    }

                    if let error = state.error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(TFFont.meta)
                            .foregroundStyle(TFColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let response = state.response {
                        assessment(response.assessment)
                        Text("Prompt")
                            .font(TFFont.footnoteEmphasis)
                            .foregroundStyle(TFColor.textPrimary)
                        TextEditor(text: $model.handoffPrompt)
                            .font(TFFont.footnote)
                            .scrollContentBackground(.hidden)
                            .padding(TFSpace.xs)
                            .frame(minHeight: 230)
                            .background(TFColor.settingsFill, in: RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous)
                                    .strokeBorder(TFColor.settingsLine, lineWidth: 1)
                            }
                            .accessibilityLabel("Editable handoff prompt")
                            .disabled(state.isLoading)

                        if let copyError = state.copyError {
                            Text(copyError)
                                .font(TFFont.meta)
                                .foregroundStyle(TFColor.textSecondary)
                        }

                        HStack {
                            if state.error != nil {
                                Button("Retry") { model.retryHandoff() }
                                    .disabled(state.isLoading)
                                    .accessibilityLabel("Retry handoff preparation")
                            }
                            Spacer(minLength: TFSpace.sm)
                            Button(state.copied ? "Copied" : "Copy prompt") { model.copyHandoffPrompt() }
                                .disabled(state.isLoading || model.handoffPrompt.isEmpty || state.error != nil)
                                .accessibilityLabel(state.copied ? "Prompt copied" : "Copy handoff prompt")
                        }
                        .buttonStyle(.bordered)
                    } else if !state.isLoading {
                        Button("Retry") { model.retryHandoff() }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Retry handoff preparation")
                    }
                }
            }
            .padding(.horizontal, TFSpace.xl)
            .padding(.top, 18)
            .padding(.bottom, TFSpace.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.containerSize.height < geometry.contentSize.height - 1
        } action: { _, more in
            hasMoreBelow = more
        }
        .background(TFColor.bgElevated)
        .scrollEdgeFade(TFColor.bgElevated, isActive: hasMoreBelow)
    }

    @ViewBuilder
    private func assessment(_ result: HandoffAssessment?) -> some View {
        if let result {
            VStack(alignment: .leading, spacing: TFSpace.xs) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Effort")
                        .foregroundStyle(TFColor.textSecondary)
                    Text(result.effort.label)
                        .foregroundStyle(TFColor.textPrimary)
                    Spacer(minLength: TFSpace.sm)
                    Text("Difficulty")
                        .foregroundStyle(TFColor.textSecondary)
                    Text(result.difficulty.label)
                        .foregroundStyle(TFColor.textPrimary)
                }
                .font(TFFont.meta)

                if result.context == .needsClarification {
                    Label("Needs clarification", systemImage: "questionmark.circle")
                        .font(TFFont.meta)
                        .foregroundStyle(TFColor.textSecondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("AI assessment. Effort \(result.effort.label), difficulty \(result.difficulty.label), context \(result.context == .sufficient ? "sufficient" : "needs clarification").")
        } else {
            Label("Context only", systemImage: "text.alignleft")
                .font(TFFont.meta)
                .foregroundStyle(TFColor.textSecondary)
                .accessibilityHint("This server returned task context without an AI assessment.")
        }
    }
}

private extension HandoffAssessment.Level {
    var label: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .unknown: "Unknown"
        }
    }
}
#endif
