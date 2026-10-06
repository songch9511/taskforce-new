#if os(macOS)
import SwiftUI
import TaskforceKit
import TaskforceUI

/// Full-width launcher list: notices, clear task sections, and inline details under the selected row.
/// `LazyVStack` keeps long lists responsive; source icons are supplied by the account-scoped metadata cache.
struct LauncherListPane: View {
    @Bindable var model: LauncherModel

    /// 아래에 더 있는지 (아래 흐림)
    @State private var hasMoreBelow = false
    /// 직전에 고른 줄 (한 칸 위로 옮길 때 고정 머리에 가리지 않게 한 줄 더 보인다)
    @State private var lastSelection = 0

    var body: some View {
        let sections = model.sections
        let offsets = Self.offsets(sections)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
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
                        Section {
                            ForEach(Array(section.items.enumerated()), id: \.element.id) { itemIndex, item in
                                let index = offsets[sectionIndex] + itemIndex
                                itemRow(item, selected: index == model.selection, at: index)
                                    .padding(.horizontal, TFSpace.sm)
                                    .id(item.id)
                            }
                        } header: {
                            if let title = section.title {
                                VStack(spacing: 0) {
                                    Rectangle()
                                        .fill(TFColor.settingsLine)
                                        .frame(height: 1)
                                    SectionHeader(title, count: section.count ?? section.items.count)
                                        .padding(.horizontal, TFSpace.sm)
                                }
                                .background(TFColor.settingsSidebar)
                            }
                        }
                    }
                }
                .padding(.top, TFSpace.xs)
                .padding(.bottom, TFSpace.sm)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height < geometry.contentSize.height - 1
            } action: { _, more in
                hasMoreBelow = more
            }
            .onChange(of: model.selection) { old, index in
                lastSelection = old
                model.reconcileSavedDisclosure()
                guard model.screen == .list else { return }
                withAnimation(.easeOut(duration: 0.1)) { scroll(proxy, to: index, from: old) }
            }
            .onChange(of: model.items.map(\.id)) {
                model.reconcileSavedDisclosure()
            }
            .onChange(of: model.savedList) { model.clearSavedDisclosure() }
            .onChange(of: model.text) { model.clearSavedDisclosure() }
            .onChange(of: model.scope) { model.clearSavedDisclosure() }
            .onChange(of: model.focusRequest) { model.clearSavedDisclosure() }
            .task(id: model.screen) {
                guard case let .detail(target) = model.screen else { return }
                // Let the lazy rows enter the scroll view before resolving the row target.
                await Task.yield()
                let items = model.items
                guard !Task.isCancelled,
                      let index = items.firstIndex(where: { $0.inlineDetailActionID == target.action.id })
                else { return }
                // Leave one row of clearance for the pinned section header. For index zero,
                // the top sentinel puts the first row just below its pinned header.
                if index == 0 {
                    proxy.scrollTo(Self.top, anchor: .top)
                } else {
                    proxy.scrollTo(items[index - 1].id, anchor: .top)
                }
            }
        }
        .background(TFColor.settingsSidebar)
        .scrollEdgeFade(TFColor.settingsSidebar, isActive: hasMoreBelow)
    }

    private static let top = "list-top"

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

    /// Action rows open their inline detail; tapping the same row closes it. Other list commands keep their existing actions.
    private func tap(_ item: LauncherItem, at index: Int) {
        switch item {
        case .review, .task, .done:
            let targetID = item.action?.id
            if case .detail = model.screen, model.detailTarget?.action.id == targetID {
                model.back()
                return
            }
            if model.screen != .list { model.back() }
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
        VStack(alignment: .leading, spacing: 0) {
            switch item {
            case .review, .task, .done, .saved:
                Button { tap(item, at: index) } label: {
                    row(item, selected: selected)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityHint(isExpanded(item) ? "Hide details" : "Show details")
            case .showMore, .doneToday:
                row(item, selected: selected)
                    .frame(maxWidth: .infinity, alignment: .leading)
            default:
                row(item, selected: selected)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture { tap(item, at: index) }
            }
            if isExpanded(item) {
                LauncherDetailPane(model: model, inline: true)
                    .padding(.horizontal, TFSpace.sm)
                    .padding(.top, TFSpace.xs)
                    .padding(.bottom, TFSpace.sm)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func isExpanded(_ item: LauncherItem) -> Bool {
        if case .detail = model.screen, let id = item.inlineDetailActionID {
            return model.detailTarget?.action.id == id
        }
        if case .saved(let savedRow) = item {
            return model.isSavedRowExpanded(savedRow)
        }
        return false
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
