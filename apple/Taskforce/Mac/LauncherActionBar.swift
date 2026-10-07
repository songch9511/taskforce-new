#if os(macOS)
import SwiftUI
import TaskforceKit
import TaskforceUI

/// 액션 바 (Figma M1 · M8 · M17 · M19 · M20 Footer, 높이 44): 왼쪽 앱 기호 + 화면 이름(`Tasks` · `Run with AI` · `Draft`) 또는 상태(`Offline since 8:01.` ·
/// `Couldn’t refresh at 10:46. Showing 10:31.` · `Stop requested 14:20`), 오른쪽 설명(`Manual, uses credits`) · 보조 동작(`Try Again ⌘R` · `Undo ⌘Z` ·
/// `Dismiss ⌘⌫`) → Return 동작(`Open in Notion ↩` · `Show details ↩` · `Confirm ⌘↩` · `Start ⌘↩` · `View Draft ↩` · `Copy ⌘C`) → `Actions ⌘K`.
/// 그 밖의 화면은 `Back esc`.
struct LauncherActionBar: View {
    @Bindable var model: LauncherModel
    @State private var clearHovered = false

    var body: some View {
        if model.isMultiSelecting || model.bulkBusy {
            bulkFooter
        } else {
            ActionBar(
                leading: leading,
                note: note,
                secondary: model.secondaryAction.map { action in ActionBarItem(action.title, keys: action.keys) { model.performSecondary() } },
                primary: model.primaryAction.map { action in
                    ActionBarItem(action.title, keys: action.keys, isEnabled: isPrimaryEnabled) { model.performPrimary() }
                },
                actions: trailing
            )
        }
    }

    private var bulkFooter: some View {
        HStack(spacing: TFSpace.sm) {
            HStack(spacing: TFSpace.xs) {
                Image(systemName: "checklist")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TFColor.textSecondary)
                    .accessibilityHidden(true)
                Text("\(model.selectedActionCount) selected")
                    .font(TFFont.footnote)
                    .foregroundStyle(TFColor.textPrimary)
                    .lineLimit(1)
                    .accessibilityLabel("\(model.selectedActionCount) selected")
                Button { model.clearMultiSelection() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(TFColor.textSecondary)
                        .frame(width: 20, height: 20)
                        .background(clearHovered ? TFColor.settingsFill : .clear, in: RoundedRectangle(cornerRadius: TFRadius.sm, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: TFRadius.sm, style: .continuous))
                }
                .buttonStyle(.plain)
                .onHover { clearHovered = $0 }
                .disabled(model.bulkBusy)
                .accessibilityLabel("Clear selection")
                .accessibilityHint("Unselects all selected tasks")
            }

            if model.bulkBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Applying bulk action")
            }

            if let message = model.bulkStatus ?? model.bulkFailureMessage {
                Text(message)
                    .font(TFFont.footnote)
                    .foregroundStyle(model.bulkFailureMessage == nil ? TFColor.textSecondary : TFColor.textPrimary)
                    .lineLimit(1)
                    .accessibilityLabel(message)
                    .help(model.bulkFailureMessage ?? message)
            }

            if model.canRetryBulkAction {
                Button("Retry") { model.retryBulkAction() }
                    .font(TFFont.footnote)
                    .buttonStyle(.plain)
                    .disabled(model.bulkBusy)
                    .help(model.bulkFailureMessage ?? "Retry the failed bulk action")
            }

            Spacer(minLength: TFSpace.sm)

            if model.canUndo {
                Button { model.undo() } label: {
                    HStack(spacing: 6) {
                        Text("Undo")
                            .font(TFFont.footnote)
                            .foregroundStyle(TFColor.textPrimary)
                        KeyHint("⌘Z")
                    }
                }
                .buttonStyle(.plain)
                .disabled(model.bulkBusy)
                .accessibilityLabel("Undo")
                .accessibilityHint("Command Z")
            }

            bulkActionsButton
        }
        .padding(.horizontal, 18)
        .frame(height: 44)
    }

    private var bulkActionsButton: some View {
        Button {
            guard !model.bulkBusy, !model.bulkActionEntries.isEmpty else { return }
            model.bulkMenuRequested = true
        } label: {
            HStack(spacing: 6) {
                Text("Actions")
                    .font(TFFont.footnote)
                    .foregroundStyle(TFColor.textPrimary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(TFColor.textSecondary)
                    .accessibilityHidden(true)
                KeyHint("⌘K")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.bulkBusy || model.bulkActionEntries.isEmpty)
        .accessibilityLabel("Actions")
        .accessibilityHint("Shows available actions for \(model.selectedActionCount) selected tasks. Command K")
        .background {
            BulkActionMenuPresenter(isRequested: $model.bulkMenuRequested, model: model)
        }
    }

    private var leading: ActionBar.Leading {
        if let text = model.statusText {
            if model.refreshState.isOffline {
                return .status(systemImage: "wifi.slash", text: text)
            }
            return .status(systemImage: "exclamationmark.triangle", text: text, alert: true)
        }
        if let stop = stopRequested {
            return .status(systemImage: "stop.circle", text: stop)
        }
        return .app(model.crumb?.screen ?? "Tasks")
    }

    /// M17: 상세에 보이는 할 일의 run을 멈췄으면 `Stop requested 14:20` (시각은 서버 값)
    private var stopRequested: String? {
        guard model.screen == .list || model.screen.isDetail, let id = model.detailTarget?.action.id, let lane = model.lane(for: id) else { return nil }
        return RunLaneText.stopRequested(lane)
    }

    /// M8: 모드 · 비용 한 줄 (Mode `Change`는 U6b라 늘 Manual)
    private var note: String? {
        if let message = model.bulkFailureMessage ?? model.bulkStatus { return message }
        if let feedback = model.feedbackMessage { return feedback }
        if case .runWithAI = model.screen { return "Manual, uses credits" }
        return nil
    }

    /// M8 Start는 Goal이 있고 보내는 중이 아닐 때만
    private var isPrimaryEnabled: Bool {
        if case .runWithAI = model.screen { model.canStartRun } else { true }
    }

    private var trailing: ActionBarItem? {
        switch model.screen {
        case .list, .detail, .runWithAI, .handoff, .draft(.some, _):
            // 할 일 행이 아니면 명령 패널 (로그아웃이면 할 일이 없어 숨긴다)
            guard model.canOpenActions else { return nil }
            return ActionBarItem("Actions", keys: "⌘K") { model.openActions() }
        case .draft(nil, _):
            // 목록에 없는 할 일의 초안: 동작이 없다 (`Back esc`는 머리에)
            return nil
        default:
            // 직접 추가 · 신고를 보내는 중에는 esc가 할 일이 없다
            guard !model.isSubmitting else { return nil }
            return ActionBarItem("Back", keys: "esc") { model.back() }
        }
    }
}

/// Uses AppKit's native menu so Command-K and the visible footer button open the same actions.
private struct BulkActionMenuPresenter: NSViewRepresentable {
    @Binding var isRequested: Bool
    let model: LauncherModel

    func makeCoordinator() -> Coordinator {
        Coordinator(isRequested: $isRequested, model: model)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.anchorView = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.isRequested = $isRequested
        context.coordinator.model = model
        context.coordinator.anchorView = view
        if isRequested { context.coordinator.schedulePresentation() }
    }

    @MainActor
    final class Coordinator: NSObject, NSMenuDelegate {
        var isRequested: Binding<Bool>
        var model: LauncherModel
        weak var anchorView: NSView?
        private var presentationScheduled = false
        private var isPresenting = false
        private var menuEntries: [LauncherModel.BulkActionEntry] = []
        private var performEntry: ((LauncherModel.BulkActionEntry) -> Void)?
        private var menu: NSMenu?

        init(isRequested: Binding<Bool>, model: LauncherModel) {
            self.isRequested = isRequested
            self.model = model
        }

        func schedulePresentation() {
            guard !presentationScheduled, !isPresenting else { return }
            presentationScheduled = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.presentationScheduled = false
                self.presentIfRequested()
            }
        }

        private func presentIfRequested() {
            guard isRequested.wrappedValue, let anchorView else { return }
            guard !model.bulkBusy, !model.selectedActionIDs.isEmpty else {
                isRequested.wrappedValue = false
                return
            }

            let selectedIDs = model.selectedActionIDs
            let accountID = model.signedInUserID
            let sessionGeneration = model.bulkSessionGeneration
            let selectionGeneration = model.bulkSelectionGeneration
            let entries = model.bulkActionEntries
            guard !entries.isEmpty else {
                isRequested.wrappedValue = false
                return
            }
            let groupSnapshot = Dictionary(uniqueKeysWithValues: selectedIDs.compactMap { id in
                model.now?.sections.find(id).map { (id, $0.group) }
            })
            guard groupSnapshot.count == selectedIDs.count else {
                isRequested.wrappedValue = false
                return
            }

            menuEntries = entries
            performEntry = { [weak model] entry in
                let currentGroups = Dictionary(uniqueKeysWithValues: selectedIDs.compactMap { id in
                    model?.now?.sections.find(id).map { (id, $0.group) }
                })
                guard let model,
                      !model.bulkBusy,
                      model.selectedActionIDs == selectedIDs,
                      model.signedInUserID == accountID,
                      model.bulkSessionGeneration == sessionGeneration,
                      model.bulkSelectionGeneration == selectionGeneration,
                      currentGroups == groupSnapshot else { return }
                model.performBulkAction(
                    entry,
                    expectedIDs: selectedIDs,
                    accountID: accountID,
                    expectedSessionGeneration: sessionGeneration,
                    expectedSelectionGeneration: selectionGeneration,
                    expectedGroups: groupSnapshot
                )
            }

            let menu = NSMenu(title: "Actions")
            menu.autoenablesItems = false
            menu.delegate = self
            for (index, entry) in entries.enumerated() {
                if entry == .remove, index > 0 { menu.addItem(.separator()) }
                let item = NSMenuItem(title: model.bulkActionTitle(entry), action: #selector(performBulkAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = NSNumber(value: index)
                item.image = NSImage(systemSymbolName: model.bulkActionSymbolName(entry), accessibilityDescription: nil)
                menu.addItem(item)
            }
            self.menu = menu
            isPresenting = true
            _ = menu.popUp(positioning: nil, at: NSPoint(x: anchorView.bounds.maxX, y: anchorView.bounds.minY), in: anchorView)
            isPresenting = false
            self.menu = nil
            menuEntries = []
            performEntry = nil
            isRequested.wrappedValue = false
        }

        @objc private func performBulkAction(_ item: NSMenuItem) {
            guard let index = (item.representedObject as? NSNumber)?.intValue,
                  menuEntries.indices.contains(index) else { return }
            performEntry?(menuEntries[index])
        }

        func menuDidClose(_ menu: NSMenu) {
            isRequested.wrappedValue = false
        }
    }
}
#endif
