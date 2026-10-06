#if os(macOS)
import SwiftUI
import TaskforceKit
import TaskforceUI

/// Launcher list with an optional right-side detail pane.
/// The list uses an eager stack to avoid SwiftUI's nested lazy-section placement churn during scroll updates.
struct LauncherListPane: View {
    @Bindable var model: LauncherModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 아래에 더 있는지 (아래 흐림)
    @State private var hasMoreBelow = false
    /// 직전에 고른 줄 (한 칸 위로 옮길 때 고정 머리에 가리지 않게 한 줄 더 보인다)
    @State private var lastSelection = 0
    @State private var pointerSelection: Int?

    var body: some View {
        let sections = model.sections
        let offsets = Self.offsets(sections)
        let firstTitledSectionIndex = sections.firstIndex { $0.title != nil }
        let showsDetail = hasDetailPane
        GeometryReader { geometry in
          ScrollViewReader { proxy in
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 0).id(Self.top)
                        if model.showsSyncing {
                            Text(ConnectionSync.label)
                                .font(TFFont.meta)
                                .foregroundStyle(TFColor.textSecondary)
                                .padding(.horizontal, 18)
                                .frame(height: 28, alignment: .leading)
                        }
                        if model.now?.sourceServicesFailed == true {
                            HStack(spacing: TFSpace.xs) {
                                Image(systemName: "exclamationmark.circle")
                                    .accessibilityHidden(true)
                                Text("Source icons unavailable")
                                    .lineLimit(1)
                                Spacer(minLength: TFSpace.xs)
                                Button("Retry") { Task { await model.now?.load() } }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Retry source icons")
                                    .accessibilityHint("Reloads tasks and source provider icons")
                            }
                            .font(TFFont.meta)
                            .foregroundStyle(TFColor.textSecondary)
                            .padding(.horizontal, 18)
                            .frame(height: 28)
                            .accessibilityElement(children: .contain)
                        }
                        ForEach(Array(sections.enumerated()), id: \.element.id) { sectionIndex, section in
                            if let title = section.title {
                                VStack(spacing: 0) {
                                    if sectionIndex != firstTitledSectionIndex {
                                        Rectangle()
                                            .fill(TFColor.settingsLine)
                                            .frame(height: 1)
                                    }
                                    SectionHeader(title, count: section.count ?? section.items.count)
                                        .padding(.horizontal, TFSpace.sm)
                                }
                                .background(TFColor.settingsSidebar)
                            }
                            ForEach(Array(section.items.enumerated()), id: \.element.id) { itemIndex, item in
                                let index = offsets[sectionIndex] + itemIndex
                                itemRow(item, selected: index == model.selection, at: index)
                                    .padding(.horizontal, TFSpace.sm)
                            }
                        }
                    }
                    .padding(.top, TFSpace.xs)
                    .padding(.bottom, TFSpace.sm)
                }
                .frame(
                    width: max(0, geometry.size.width - (showsDetail ? detailWidth : 0)),
                    height: geometry.size.height
                )
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height < geometry.contentSize.height - 1
                } action: { _, more in
                    hasMoreBelow = more
                }
                .onChange(of: model.selection) { old, index in
                    lastSelection = old
                    model.reconcileSavedDisclosure()
                    if pointerSelection == index {
                        pointerSelection = nil
                        return
                    }
                    guard model.screen == .list else { return }
                    scroll(proxy, to: index, from: old)
                }
                .onChange(of: model.items.map(\.id)) { model.reconcileSavedDisclosure() }
                .onChange(of: model.savedList) { model.clearSavedDisclosure() }
                .onChange(of: model.text) { model.clearSavedDisclosure() }
                .onChange(of: model.scope) { model.clearSavedDisclosure() }
                .onChange(of: model.focusRequest) { model.clearSavedDisclosure() }
                .scrollEdgeFade(TFColor.settingsSidebar, isActive: hasMoreBelow)

            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
            .overlay(alignment: .trailing) {
                LauncherDetailPane(model: model, onClose: closeDetail)
                    .id(detailIdentity)
                    .frame(width: detailWidth)
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .leading) {
                        if showsDetail { Rectangle().fill(TFColor.settingsLine).frame(width: 1) }
                    }
                    .opacity(showsDetail ? 1 : 0)
                    .offset(x: showsDetail || reduceMotion ? 0 : 18)
                    .allowsHitTesting(showsDetail)
                    .accessibilityHidden(!showsDetail)
                    .animation(detailAnimation, value: showsDetail)
            }
          }
        }
        .background(TFColor.settingsSidebar)
    }

    private static let top = "list-top"

    private var hasDetailPane: Bool {
        if case .detail = model.screen { return model.detailTarget != nil }
        if case .saved(let row)? = model.selectedItem { return model.isSavedRowExpanded(row) }
        return false
    }

    private var detailWidth: CGFloat { LauncherPanelController.size.width * 0.49 }

    private var detailIdentity: String {
        if case .detail(let target) = model.screen { return "action-\(target.action.id)" }
        if case .saved(let row)? = model.selectedItem, model.isSavedRowExpanded(row) { return "saved-\(row.id)" }
        return "hidden"
    }

    private var detailAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.24, dampingFraction: 1, blendDuration: 0)
    }

    private func closeDetail() {
        if case .saved(let row)? = model.selectedItem { model.toggleSavedRow(row) }
        else { model.closeDetailPane() }
    }

    /// 고른 줄이 보이게: 한 칸 아래면 그 줄까지, 한 칸 위면 그 위 줄까지(고정 머리 30이 행 36을 가리지 않게), 맨 위 줄이면 맨 위, 멀리 뛰면 가운데
    private func scroll(_ proxy: ScrollViewProxy, to index: Int, from old: Int) {
        let items = model.items
        if index <= 0 {
            proxy.scrollTo(Self.top, anchor: .top)
        } else if index == old - 1 {
            guard items.indices.contains(index - 1) else { return }
            proxy.scrollTo(items[index - 1].id)
        } else if index == old + 1 {
            guard items.indices.contains(index) else { return }
            proxy.scrollTo(items[index].id)
        } else {
            guard items.indices.contains(index) else { return }
            proxy.scrollTo(items[index].id, anchor: .center)
        }
    }

    private static func offsets(_ sections: [LauncherSection]) -> [Int] {
        var running = 0
        return sections.map { section in
            defer { running += section.items.count }
            return running
        }
    }

    /// Action rows open their right-side detail; tapping the same row closes it.
    private func tap(_ item: LauncherItem, at index: Int) {
        let previousSelection = model.selection
        pointerSelection = index
        defer { if model.selection == previousSelection { pointerSelection = nil } }
        switch item {
        case .review, .task, .done:
            let targetID = item.action?.id
            if case .detail = model.screen, model.detailTarget?.action.id == targetID {
                model.closeDetailPane()
                return
            }
            if case .detail = model.screen { model.closeDetailPane() }
            else if model.screen != .list { model.back() }
            model.openDetail(for: item)
        case .saved(let row):
            if model.screen != .list { model.back() }
            model.select(index)
            model.toggleSavedRow(row)
        case .showMore, .doneToday:
            model.run(item)
        default:
            if model.screen != .list { model.back() }
            model.select(index)
            model.run(item)
        }
    }

    @ViewBuilder
    private func itemRow(_ item: LauncherItem, selected: Bool, at index: Int) -> some View {
        itemRowContent(item, selected: selected, at: index)
            .id(item.id)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func itemRowContent(_ item: LauncherItem, selected: Bool, at index: Int) -> some View {
        switch item {
        case .review, .task, .done:
            HStack(spacing: 2) {
                Button { tap(item, at: index) } label: {
                    row(item, selected: selected).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help(Text(fullTitle(for: item)))
                .accessibilityHint(isLiveExpanded(item) ? "Hide details" : "Show details")
                rowActionsMenu(item, selected: selected)
            }
        case .saved:
            Button { tap(item, at: index) } label: {
                row(item, selected: selected)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help(Text(fullTitle(for: item)))
            .accessibilityHint(isSavedExpanded(item) ? "Hide details" : "Show details")
        case .showMore, .doneToday:
            row(item, selected: selected)
                .frame(maxWidth: .infinity, alignment: .leading)
        default:
            row(item, selected: selected)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onTapGesture { tap(item, at: index) }
        }
    }

    private func isSavedExpanded(_ item: LauncherItem) -> Bool {
        if case .saved(let savedRow) = item {
            return model.isSavedRowExpanded(savedRow)
        }
        return false
    }

    private func isLiveExpanded(_ item: LauncherItem) -> Bool {
        guard case .detail = model.screen, let id = item.inlineDetailActionID else { return false }
        return model.detailTarget?.action.id == id
    }

    private func fullTitle(for item: LauncherItem) -> String {
        if let title = item.action?.title { return title }
        if case .saved(let row) = item { return row.task.title }
        return ""
    }

    @ViewBuilder
    private func rowActionsMenu(_ item: LauncherItem, selected: Bool) -> some View {
        if let action = item.action, let group = item.group {
            let target = LauncherModel.Target(action: action, group: group)
            let accountID = model.signedInUserID
            Menu {
                ForEach(Array(model.actionGroups(for: target).enumerated()), id: \.offset) { _, actionGroup in
                    if let title = actionGroup.title {
                        Section(title) { rowMenuEntries(actionGroup.entries, target: target, accountID: accountID) }
                    } else {
                        rowMenuEntries(actionGroup.entries, target: target, accountID: accountID)
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? TFColor.textSecondarySelected : TFColor.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(selected ? TFColor.bgSelected : .clear, in: RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous))
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .help("Actions for \(action.title)")
            .accessibilityLabel("Actions for \(action.title)")
        }
    }

    @ViewBuilder
    private func rowMenuEntries(_ entries: [LauncherModel.ActionEntry], target: LauncherModel.Target, accountID: UUID?) -> some View {
        ForEach(entries, id: \.self) { entry in
            if entry == .delete {
                Button(role: .destructive) {
                    model.performRowMenuAction(entry, actionID: target.action.id, group: target.group, accountID: accountID)
                } label: {
                    Label(entry.title, systemImage: entry.symbolName ?? "trash")
                }
            } else {
                Button {
                    model.performRowMenuAction(entry, actionID: target.action.id, group: target.group, accountID: accountID)
                } label: {
                    if case .state(let state) = entry, state == WorkState(target.group) {
                        Label(entry.title, systemImage: "checkmark")
                    } else if let symbolName = entry.symbolName {
                        Label(entry.title, systemImage: symbolName)
                    } else {
                        Text(entry.title)
                    }
                }
            }
        }
    }

    private var today: LocalDate { DueDateFormat.today() }

    /// 상세로 포커스를 옮겨도(Tab · →) 목록에서 고른 행은 그대로 보인다
    @ViewBuilder
    private func row(_ item: LauncherItem, selected: Bool) -> some View {
        switch item {
        case .review(let action):
            MacListRow(
                title: action.title,
                accessory: action.dueDate.map { DueText.accessory($0, today: today) },
                sourceServices: sourceServices(action.id),
                urgent: DueText.isUrgent(due: action.dueDate, reasons: [], today: today),
                changed: model.showsDot(action.id),
                selected: selected
            )
        case .task(let ranked):
            MacListRow(
                title: ranked.action.title,
                accessory: ranked.action.dueDate.map { DueText.accessory($0, today: today) },
                sourceServices: sourceServices(ranked.action.id),
                urgent: DueText.isUrgent(due: ranked.action.dueDate, reasons: ranked.reasons, today: today),
                changed: model.showsDot(ranked.action.id),
                selected: selected
            )
        case .done(let action):
            // 끝낸 할 일은 기한을 보이지 않는다 (지남 · 오늘 빨강이 뜻이 없다)
            MacListRow(title: action.title, sourceServices: sourceServices(action.id), selected: selected, dimmed: true)
        case .saved(let row):
            let done = row.task.status == .doneToday
            MacListRow(
                title: row.task.title,
                accessory: done ? nil : row.task.dueDate.map { DueText.accessory($0, today: today) },
                sourceServices: [],
                urgent: !done && DueText.isUrgent(due: row.task.dueDate, reasons: [], today: today),
                selected: selected,
                dimmed: done
            )
        case .showMore(let group, let hidden):
            ShowMoreRow(count: hidden, section: group.title, selected: selected) { model.run(item) }
        case .doneToday(let count, let expanded):
            SectionHeader(TaskGroup.doneToday.title, count: count, disclosure: expanded ? .expanded : .collapsed, selected: selected) {
                model.run(item)
            }
        case .failedSources(let failed):
            MacListRow(title: failed.title, accessory: failed.latestAt.map { WhenText.label($0) }, selected: selected)
        case .policyNotice(let notice):
            MacListRow(title: notice.title(today: today), accessory: "View", selected: selected)
        case .allowAI:
            MacListRow(title: "Allow AI processing to keep your list up to date", selected: selected)
        case .command(let command):
            MacListRow(title: command.title, selected: selected)
        case .ask(let question):
            MacListRow(title: "Ask “\(LauncherFlowView.oneLine(question))”", selected: selected)
        case .handoff(let action):
            MacListRow(title: "Hand off “\(action.title)” to AI", selected: selected)
        case .sendAsSource(let text):
            MacListRow(title: "Send as source", accessory: LauncherFlowView.oneLine(text), selected: selected)
        case .addAction(let title):
            MacListRow(title: "Add “\(title)”", selected: selected)
        case .signInWithGoogle:
            // 로그아웃 목록은 한 열 (`LauncherFlowView`)
            EmptyView()
        }
    }

    private func sourceServices(_ id: UUID) -> [SourceService] {
        model.now?.sourceServicesByAction[id] ?? []
    }
}
#endif
