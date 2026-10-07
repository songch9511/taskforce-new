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
        VStack(spacing: 0) {
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
            .scrollEdgeFade(TFColor.bgElevated, isActive: hasMoreBelow)

            if let id = model.detailTarget?.action.id {
                LauncherNotesComposer(model: model, actionID: id).id(id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TFColor.bgElevated)
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
                .padding(.trailing, -TFSpace.sm)
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
        VStack(spacing: 0) {
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
            .scrollEdgeFade(TFColor.bgElevated, isActive: hasMoreBelow)

            LauncherNotesComposer(model: model, actionID: target.action.id).id(target.action.id)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TFColor.bgElevated)
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

private struct LauncherNotesComposer: View {
    private enum Format {
        case bold, italic, heading, bullet, checklist
    }

    @Bindable var model: LauncherModel
    let actionID: UUID

    @FocusState private var editorFocused: Bool
    @State private var selection: TextSelection?
    @State private var preview = false

    private var entry: ActionNotesStore.Entry { model.actionNotesEntry(actionID) }
    private var text: Binding<String> {
        Binding(
            get: { model.actionNotesEntry(actionID).markdown },
            set: { model.editActionNotes(actionID, markdown: $0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TFSpace.xs) {
            HStack(spacing: TFSpace.sm) {
                Text("Notes")
                    .font(TFFont.footnoteEmphasis)
                    .foregroundStyle(TFColor.textPrimary)
                Spacer(minLength: 0)
                Text(status)
                    .font(TFFont.meta)
                    .foregroundStyle(entry.error == nil ? TFColor.textSecondary : TFColor.statusOverdue)
                    .lineLimit(1)
                Button(preview ? "Write" : "Preview") { preview.toggle() }
                    .font(TFFont.meta)
                    .buttonStyle(.plain)
                    .accessibilityLabel(preview ? "Edit notes" : "Preview notes")
            }

            if !preview {
                HStack(spacing: TFSpace.xs) {
                    formatButton("B", label: "Bold", format: .bold).fontWeight(.bold)
                    formatButton("I", label: "Italic", format: .italic).italic()
                    formatButton("H₂", label: "Heading", format: .heading)
                    formatButton("list.bullet", label: "Bullet list", format: .bullet, symbol: true)
                    formatButton("checklist", label: "Checklist", format: .checklist, symbol: true)
                    Spacer(minLength: 0)
                    Text("\(entry.markdown.utf16.count)/10,000")
                        .font(TFFont.meta)
                        .foregroundStyle(TFColor.textSecondary)
                        .monospacedDigit()
                }

                TextEditor(text: text, selection: $selection)
                    .font(TFFont.meta)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, TFSpace.xs)
                    .padding(.vertical, 2)
                    .frame(height: 66)
                    .background(TFColor.settingsFill, in: RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous)
                            .strokeBorder(TFColor.settingsLine, lineWidth: 1)
                    }
                    .focused($editorFocused)
                    .simultaneousGesture(TapGesture().onEnded { editorFocused = true })
                    .accessibilityLabel("Task notes in Markdown")
                    .disabled(entry.isLoading && !entry.isDirty)
                    .overlay(alignment: .topLeading) {
                        if entry.markdown.isEmpty && !editorFocused {
                            Text("Write notes…")
                                .font(TFFont.meta)
                                .foregroundStyle(TFColor.textSecondary)
                                .padding(.leading, TFSpace.sm)
                                .padding(.top, TFSpace.sm)
                                .allowsHitTesting(false)
                        }
                    }
            } else {
                markdownPreview
            }

            if let server = entry.serverVersion {
                VStack(alignment: .leading, spacing: TFSpace.xs) {
                    Text("Server version: \(server.markdown.isEmpty ? "(empty)" : server.markdown)")
                        .font(TFFont.meta)
                        .foregroundStyle(TFColor.textSecondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    HStack(spacing: TFSpace.xs) {
                        Text("Notes changed elsewhere.")
                            .font(TFFont.meta)
                            .foregroundStyle(TFColor.textSecondary)
                        Spacer(minLength: TFSpace.xs)
                        Button("Use server") { model.useServerActionNotes(actionID) }
                        Button("Keep mine") { model.keepMyActionNotes(actionID) }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Resolve notes conflict; server revision \(server.revision)")
            } else if entry.error != nil {
                HStack(spacing: TFSpace.xs) {
                    Text(entry.error ?? "")
                        .font(TFFont.meta)
                        .foregroundStyle(TFColor.statusOverdue)
                        .lineLimit(2)
                    Spacer(minLength: TFSpace.xs)
                    Button(entry.isLoaded ? "Retry" : "Reload") { model.retryActionNotes(actionID) }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
            }
        }
        .padding(.horizontal, TFSpace.xl)
        .padding(.top, TFSpace.sm)
        .padding(.bottom, TFSpace.sm)
        .background(TFColor.bgElevated)
        .overlay(alignment: .top) { Rectangle().fill(TFColor.settingsLine).frame(height: 1) }
        .task(id: actionID) { await model.loadActionNotes(actionID) }
        .onChange(of: editorFocused) { _, focused in model.setNotesEditorFocused(focused) }
        .onDisappear { model.setNotesEditorFocused(false) }
    }

    private var status: String {
        if entry.serverVersion != nil { return "Conflict" }
        if entry.error != nil { return "Not saved" }
        if entry.isLoading { return "Loading…" }
        if entry.isSaving || entry.isDirty { return "Saving…" }
        return "Saved"
    }

    @ViewBuilder
    private var markdownPreview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                if entry.markdown.isEmpty {
                    Text("No notes yet.").foregroundStyle(TFColor.textSecondary)
                } else {
                    ForEach(Array(entry.markdown.components(separatedBy: .newlines).enumerated()), id: \.offset) { _, line in
                        previewLine(line)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, TFSpace.sm)
            .padding(.vertical, TFSpace.xs)
        }
        .font(TFFont.meta)
        .frame(height: 66)
        .background(TFColor.settingsFill, in: RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous))
        .accessibilityLabel("Notes preview")
    }

    @ViewBuilder
    private func previewLine(_ line: String) -> some View {
        if line.hasPrefix("## ") {
            Text(markdown(line.dropFirst(3))).font(TFFont.footnoteEmphasis).foregroundStyle(TFColor.textPrimary)
        } else if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
            let checked = line.hasPrefix("- [x]") || line.hasPrefix("- [X]")
            HStack(alignment: .firstTextBaseline, spacing: TFSpace.xs) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(TFColor.textSecondary)
                Text(markdown(line.dropFirst(6))).foregroundStyle(TFColor.textPrimary)
            }
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: TFSpace.xs) {
                Text("•").foregroundStyle(TFColor.textSecondary)
                Text(markdown(line.dropFirst(2))).foregroundStyle(TFColor.textPrimary)
            }
        } else {
            Text(markdown(line)).foregroundStyle(TFColor.textPrimary)
        }
    }

    private func markdown<S: StringProtocol>(_ source: S) -> AttributedString {
        (try? AttributedString(markdown: String(source))) ?? AttributedString(source)
    }

    private func formatButton(_ title: String, label: String, format: Format, symbol: Bool = false) -> some View {
        Button {
            apply(format)
            editorFocused = true
        } label: {
            Group {
                if symbol { Image(systemName: title) }
                else { Text(title) }
            }
            .font(TFFont.meta)
            .foregroundStyle(TFColor.textSecondary)
            .frame(minWidth: 22, minHeight: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private func apply(_ format: Format) {
        let source = entry.markdown
        let range: Range<String.Index>
        if let selection, case .selection(let selected) = selection.indices {
            range = selected
        } else {
            range = source.endIndex..<source.endIndex
        }

        switch format {
        case .bold: wrap("**", placeholder: "bold", range: range, in: source)
        case .italic: wrap("*", placeholder: "text", range: range, in: source)
        case .heading: prefix("## ", range: range, in: source)
        case .bullet: prefix("- ", range: range, in: source)
        case .checklist: prefix("- [ ] ", range: range, in: source)
        }
    }

    private func wrap(_ marker: String, placeholder: String, range: Range<String.Index>, in source: String) {
        let selected = String(source[range])
        let replacement = marker + (selected.isEmpty ? placeholder : selected) + marker
        guard (source.utf16.count - source[range].utf16.count + replacement.utf16.count) <= 10_000 else { return }
        var updated = source
        updated.replaceSubrange(range, with: replacement)
        guard model.editActionNotes(actionID, markdown: updated) else { return }
        let innerStart = updated.index(updated.startIndex, offsetBy: source.distance(from: source.startIndex, to: range.lowerBound) + marker.count)
        let innerEnd = updated.index(innerStart, offsetBy: (selected.isEmpty ? placeholder : selected).count)
        selection = TextSelection(range: innerStart..<innerEnd)
    }

    private func prefix(_ marker: String, range: Range<String.Index>, in source: String) {
        let lowerOffset = source.distance(from: source.startIndex, to: range.lowerBound)
        let upperOffset = source.distance(from: source.startIndex, to: range.upperBound)
        let lineStart = source[..<range.lowerBound].lastIndex(of: "\n").map { source.index(after: $0) } ?? source.startIndex
        let lines = source.components(separatedBy: "\n")
        let startLine = source[..<lineStart].filter { $0 == "\n" }.count
        guard lines.indices.contains(startLine) else { return }
        let remove = lines[startLine].hasPrefix(marker)
        var transformed = lines
        if remove { transformed[startLine].removeFirst(marker.count) }
        else { transformed[startLine].insert(contentsOf: marker, at: transformed[startLine].startIndex) }
        let updated = transformed.joined(separator: "\n")
        guard model.editActionNotes(actionID, markdown: updated) else { return }
        let delta = remove ? -marker.count : marker.count
        let newLower = updated.index(updated.startIndex, offsetBy: max(0, lowerOffset + delta))
        let newUpper = updated.index(updated.startIndex, offsetBy: max(0, upperOffset + delta))
        selection = TextSelection(range: min(newLower, newUpper)..<max(newLower, newUpper))
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
