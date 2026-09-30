#if os(macOS)
import SwiftUI
import TaskforceKit
import TaskforceUI

/// 런처 창 내용 (Figma 5:57): 입력창 "Search" · 구역(Review · In Progress · To Do · Done Today · Commands) · 행 · 아래 "Actions ⌘K".
/// 할 일 행 왼쪽은 상태 표시(`TaskStatusMark`): ○ · ●를 누르면 Done, ✓는 끝내기 전 상태로 (Review는 누를 수 없음).
/// ⌘K 패널 · 펼침 · Ask 답 · 원문 고르기처럼 Figma에 없는 화면은 같은 부품(Launcher row · Keycap · Sources 묶음)과 토큰으로만 구성한다.
struct LauncherRootView: View {
    @Bindable var model: LauncherModel
    let onHeightChange: (CGFloat) -> Void

    @FocusState private var searchFocused: Bool
    @State private var contentHeight: CGFloat = 0

    /// 이보다 길면 목록을 스크롤한다
    private let maxContentHeight: CGFloat = 440

    var body: some View {
        VStack(spacing: 0) {
            searchField
            content
            footer
        }
        .padding(TFSpace.sm)
        .frame(width: LauncherPanelController.width)
        .fixedSize(horizontal: false, vertical: true)
        .overlay {
            // 유리 재질(macOS 15)에만 창 테두리. Liquid Glass는 제 가장자리를 그린다
            if !LauncherPanelController.usesGlass {
                RoundedRectangle(cornerRadius: TFRadius.xl, style: .continuous)
                    .strokeBorder(TFColor.borderDefault, lineWidth: 1)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeightChange($0) }
        // 창이 새 높이로 바뀌기 전 잠깐 동안에도 입력창은 창 위쪽에 붙어 있게 (창은 위 모서리를 고정하고 늘고 준다)
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: model.focusRequest, initial: true) { searchFocused = true }
        // 줄 고르기 · 기한 고르기에서 돌아오면 다시 입력창으로
        .onChange(of: inputLocked) { _, locked in if !locked { searchFocused = true } }
        // Realtime · 다시 불러오기로 목록이 바뀌어도 고르던 행을 그대로
        .onChange(of: model.items.map(\.id)) { model.reconcileSelection() }
        .task(id: model.signedInUserID) {
            // 로그인해 있는 동안 Realtime 구독 하나 (런처가 숨어 있어도 목록을 새로 둔다)
            guard let userID = model.signedInUserID, let services = model.services else { return }
            await model.changes.follow(services: services, userID: userID)
        }
        .onChange(of: model.changes.revision) {
            Task { await model.now?.load() }
        }
        // 연결이 동기화 중이면 런처가 떠 있는 동안 몇 초마다 연결을 다시 읽고, 끝나면 지금 할 일을 다시 불러온다
        .task(id: model.isShown && model.account?.anySyncing == true) {
            guard model.isShown, let account = model.account, account.anySyncing else { return }
            await account.followSync()
        }
        .onChange(of: model.account?.syncFinished) {
            Task { await model.now?.load() }
        }
    }

    // MARK: 입력창

    private var searchField: some View {
        TextField(text: $model.text, prompt: Text("Search").foregroundStyle(TFColor.textSecondary), axis: .vertical) {
            Text("Search")
        }
        .textFieldStyle(.plain)
        .font(TFFont.title)
        .foregroundStyle(TFColor.textPrimary)
        .lineLimit(1...3)
        .focused($searchFocused)
        .disabled(inputLocked)
        .padding(.horizontal, TFSpace.md)
        .padding(.top, 10)
        .padding(.bottom, 14)
    }

    private var inputLocked: Bool {
        switch model.screen {
        case .editDue, .addDue, .pickLines, .working: true
        // 직접 추가 중에는 입력창에 제목을 그대로 보여 준다
        case .pickSource(let purpose): purpose != .reportMissing
        default: false
        }
    }

    // MARK: 내용

    @ViewBuilder
    private var content: some View {
        switch model.screen {
        case .list:
            scrolling { listRows }
        case .actions(let target):
            scrolling { actionRows(target) }
        case .detail(let target):
            scrolling { detail(target) }
        case .editDue, .addDue:
            scrolling { dueRows }
        case .working(let label):
            statusRow(label, symbol: nil)
        case .answer(let question, let response, let lines):
            scrolling { answer(question: question, response: response, lines: lines) }
        case .pickSource(let purpose):
            scrolling { sourceRows(purpose) }
        case .pickLines:
            scrolling { lineRows }
        case .done(let message):
            statusRow(message, symbol: "checkmark.circle")
        case .notice(let message):
            statusRow(message, symbol: "exclamationmark.circle")
        case .consentNeeded:
            VStack(spacing: 0) {
                LauncherSectionLabel("AI processing")
                LauncherRow(title: "Allow AI processing to continue", selected: true, leading: .symbol("hand.raised"))
                    .onTapGesture { model.primary() }
            }
        }
    }

    /// 내용 높이에 맞추되 `maxContentHeight`를 넘으면 스크롤
    private func scrolling<Content: View>(@ViewBuilder _ rows: () -> Content) -> some View {
        let rows = rows()
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) { rows }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollIndicators(contentHeight > maxContentHeight ? .automatic : .never)
            .frame(height: min(contentHeight, maxContentHeight))
            .onChange(of: model.selection) { _, index in
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(index) }
            }
            .onChange(of: model.lineCursor) { _, index in
                proxy.scrollTo(index)
            }
        }
    }

    // MARK: 목록

    @ViewBuilder
    private var listRows: some View {
        if let error = model.configurationError {
            statusRow(error, symbol: "wrench.and.screwdriver")
        } else if model.session?.state == .loading, !model.isSignedIn {
            statusRow("Loading…", symbol: nil)
        } else {
            let sections = model.sections
            let offsets = Self.offsets(sections)
            // 첫 동기화 (몇 분 걸린다): 할 일이 들어오면 사라진다
            if model.showsSyncing {
                statusRow(ConnectionSync.label, symbol: nil)
            }
            ForEach(Array(sections.enumerated()), id: \.element.id) { sectionIndex, section in
                if let title = section.title {
                    LauncherSectionLabel(title)
                }
                ForEach(Array(section.items.enumerated()), id: \.element.id) { itemIndex, item in
                    let index = offsets[sectionIndex] + itemIndex
                    row(item, selected: index == model.selection)
                        .id(index)
                        .onTapGesture {
                            model.select(index)
                            model.run(item)
                        }
                }
            }
            if sections.isEmpty {
                statusRow("Loading…", symbol: nil)
            }
            if let error = model.now?.loadError, model.isSignedIn {
                Text(error)
                    .font(TFFont.footnote)
                    .foregroundStyle(TFColor.textSecondary)
                    .padding(.horizontal, TFSpace.md)
                    .padding(.vertical, TFSpace.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private static func offsets(_ sections: [LauncherSection]) -> [Int] {
        var running = 0
        return sections.map { section in
            defer { running += section.items.count }
            return running
        }
    }

    private var today: LocalDate { DueDateFormat.today() }

    @ViewBuilder
    private func row(_ item: LauncherItem, selected: Bool) -> some View {
        switch item {
        case .review(let action):
            LauncherRow(
                title: action.title,
                accessory: action.dueDate.map { DueText.accessory($0, today: today) },
                urgent: DueText.isUrgent(due: action.dueDate, reasons: [], today: today),
                selected: selected,
                leading: .status(.review)
            )
        case .task(let ranked):
            LauncherRow(
                title: ranked.action.title,
                accessory: ranked.action.dueDate.map { DueText.accessory($0, today: today) },
                urgent: DueText.isUrgent(due: ranked.action.dueDate, reasons: ranked.reasons, today: today),
                selected: selected,
                leading: .status(TaskStatusMark.State(TaskGroup.open(ranked.action)))
            ) {
                model.toggle(item)
            }
        case .done(let action):
            // 끝낸 할 일은 기한을 보이지 않는다 (지남 · 오늘 빨강이 뜻이 없다)
            LauncherRow(title: action.title, selected: selected, dimmed: true, leading: .status(.done)) {
                model.toggle(item)
            }
        case .command(let command):
            LauncherRow(title: command.title, selected: selected, leading: .symbol(command.symbolName))
        case .ask(let question):
            LauncherRow(title: "Ask “\(Self.oneLine(question))”", selected: selected, leading: .symbol("text.bubble"))
        case .handoff(let action):
            LauncherRow(title: "Hand off “\(action.title)” to AI", selected: selected, leading: .symbol("paperplane"))
        case .sendAsSource(let text):
            LauncherRow(
                title: "Send as source",
                subtitle: Self.oneLine(text),
                selected: selected,
                leading: .symbol("tray.and.arrow.up")
            )
        case .addAction(let title):
            LauncherRow(title: "Add “\(title)”", selected: selected, leading: .symbol("plus.circle"))
        case .signIn:
            LauncherRow(title: "Sign in with Apple", selected: selected, leading: .symbol("apple.logo"))
        case .signInWithGoogle:
            LauncherRow(title: SignInWithGoogleButton.title, selected: selected, leading: .google)
        case .signInWithEmail:
            LauncherRow(title: "Sign in with email", selected: selected, leading: .symbol("envelope"))
        case .allowAI:
            LauncherRow(title: "Allow AI processing to keep your list up to date", selected: selected, leading: .symbol("hand.raised"))
        case .policyNotice(let notice):
            LauncherRow(title: notice.title(today: today), accessory: "View", selected: selected, leading: .symbol("doc.text"))
        }
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }

    // MARK: ⌘K 동작

    /// 할 일 제목 아래 Status(To Do · In Progress · Done, 지금 상태에 체크) · Actions(맨 아래 Delete ⌘⌫). Review는 제목 아래 한 묶음.
    @ViewBuilder
    private func actionRows(_ target: LauncherModel.Target) -> some View {
        LauncherSectionLabel(target.action.title)
        let groups = model.actionGroups(for: target)
        let offsets = groups.indices.map { groups[..<$0].reduce(0) { $0 + $1.entries.count } }
        let current = WorkState(target.group)
        ForEach(Array(groups.enumerated()), id: \.offset) { groupIndex, group in
            if let title = group.title {
                LauncherSectionLabel(title)
            }
            ForEach(Array(group.entries.enumerated()), id: \.element) { entryIndex, entry in
                let index = offsets[groupIndex] + entryIndex
                actionRow(entry, current: current, selected: index == model.selection)
                    .id(index)
                    .onTapGesture {
                        model.selection = index
                        model.perform(entry, on: target)
                    }
            }
        }
    }

    @ViewBuilder
    private func actionRow(_ entry: LauncherModel.ActionEntry, current: WorkState?, selected: Bool) -> some View {
        switch entry {
        case .state(let state):
            LauncherRow(
                title: entry.title, selected: selected, checked: state == current,
                leading: .status(TaskStatusMark.State(state.group))
            )
        default:
            LauncherRow(title: entry.title, selected: selected, shortcut: entry.shortcut, leading: .symbol(entry.symbolName ?? "circle"))
        }
    }

    // MARK: 펼침 (Sources 묶음)

    @ViewBuilder
    private func detail(_ target: LauncherModel.Target) -> some View {
        let action = target.action
        let done = target.group == .doneToday
        LauncherRow(
            title: action.title,
            accessory: done ? nil : action.dueDate.map { DueText.accessory($0, today: today) },
            urgent: !done && DueText.isUrgent(due: action.dueDate, reasons: [], today: today),
            selected: true,
            dimmed: done,
            leading: .status(TaskStatusMark.State(target.group))
        )
        Group {
            if let digest = model.now?.evidence[action.id] {
                if digest.isEmpty {
                    statusRow("No sources yet.", symbol: "tray")
                } else {
                    SourcesGroup(lines: digest.lines) { line in
                        if let url = line.externalURL { model.open(url) }
                    }
                }
            } else if model.now?.evidenceFailed.contains(action.id) == true {
                statusRow("Couldn't load sources.", symbol: "exclamationmark.circle")
            } else {
                statusRow("Loading…", symbol: nil)
            }
        }
        .padding(.top, TFSpace.sm)
    }

    // MARK: 기한 고치기 · 직접 추가의 기한

    @ViewBuilder
    private var dueRows: some View {
        LauncherSectionLabel("Due")
        let choices = model.dueChoices
        ForEach(Array(choices.enumerated()), id: \.element) { index, choice in
            Group {
                switch choice {
                case .date(let date):
                    LauncherRow(
                        title: DueText.short(date, today: today),
                        accessory: DueText.date(date, today: today),
                        selected: index == model.selection,
                        leading: .symbol("calendar")
                    )
                case .clear:
                    LauncherRow(title: "No due date", selected: index == model.selection, leading: .symbol("calendar.badge.minus"))
                }
            }
            .id(index)
            .onTapGesture {
                model.selection = index
                model.primary()
            }
        }
        HStack(spacing: TFSpace.md) {
            DatePicker("Other date", selection: $model.pickedDate, displayedComponents: .date)
                .datePickerStyle(.field)
                .labelsHidden()
            Button("Set") {
                model.chooseDue(LocalDate(date: model.pickedDate, timeZone: .current))
            }
            Spacer()
        }
        .font(TFFont.callout)
        .padding(.horizontal, TFSpace.md)
        .frame(height: 40)
    }

    // MARK: 물어보기 답

    @ViewBuilder
    private func answer(question: String, response: AskResponse, lines: [EvidenceLine]) -> some View {
        LauncherSectionLabel(Self.oneLine(question))
        Text(response.answer.isEmpty ? "I don't know yet." : response.answer)
            .font(TFFont.callout)
            .foregroundStyle(response.unknown ? TFColor.textSecondary : TFColor.textPrimary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, TFSpace.md)
            .padding(.bottom, TFSpace.md)
        if !response.unknown, !lines.isEmpty {
            SourcesGroup(lines: lines) { line in
                if let url = line.externalURL { model.open(url) }
            }
        }
    }

    // MARK: 빠진 할 일 신고 · 직접 추가의 원문

    @ViewBuilder
    private func sourceRows(_ purpose: LauncherModel.SourcePurpose) -> some View {
        let adding = purpose != .reportMissing
        LauncherSectionLabel(adding ? "Source" : "Report missing action")
        if adding {
            LauncherRow(title: "No source", selected: model.selection == 0, leading: .symbol("minus.circle"))
                .id(0)
                .onTapGesture {
                    model.selection = 0
                    model.primary()
                }
        }
        let sources = model.filteredSources
        let offset = model.sourceRowOffset
        if sources.isEmpty {
            if !model.sourcesLoaded {
                statusRow("Loading…", symbol: nil)
            } else if !adding {
                statusRow(model.recentSources.isEmpty ? "No sources yet." : "No matching sources.", symbol: "tray")
            }
        }
        ForEach(Array(sources.enumerated()), id: \.element.id) { position, source in
            let index = offset + position
            LauncherRow(
                title: source.title ?? Self.untitled(source.kind),
                accessory: WhenText.label(source.occurredAt),
                selected: index == model.selection,
                leading: .source(SourceService.infer(externalURL: source.externalURL, kind: source.kind))
            )
            .id(index)
            .onTapGesture {
                model.selection = index
                model.primary()
            }
        }
    }

    private static func untitled(_ kind: SourceKind) -> String {
        switch kind {
        case .meeting: "Meeting notes"
        case .message: "Message"
        case .email: "Email"
        case .doc: "Document"
        case .note: "Note"
        case .task: "Task"
        }
    }

    @ViewBuilder
    private var lineRows: some View {
        if case .pickLines(let source, _) = model.screen, let text = model.sourceText {
            LauncherSectionLabel(source.summary.title ?? Self.untitled(source.summary.kind))
            ForEach(text.lines) { line in
                Text(line.isBlank ? " " : line.text)
                    .font(TFFont.callout)
                    .foregroundStyle(TFColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, TFSpace.md)
                    .padding(.vertical, TFSpace.xxs)
                    .background(
                        model.lineSelection.contains(line.index) ? TFColor.bgSelected : .clear,
                        in: RoundedRectangle(cornerRadius: TFRadius.sm, style: .continuous)
                    )
                    .overlay {
                        if line.index == model.lineCursor {
                            RoundedRectangle(cornerRadius: TFRadius.sm, style: .continuous)
                                .strokeBorder(TFColor.borderAccent, lineWidth: 1)
                        }
                    }
                    .contentShape(Rectangle())
                    .id(line.index)
                    .onTapGesture {
                        model.lineCursor = line.index
                        model.lineSelection.tap(line.index)
                    }
            }
        }
    }

    // MARK: 한 줄 상태 · 아래

    private func statusRow(_ text: String, symbol: String?) -> some View {
        HStack(spacing: TFSpace.md) {
            Group {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 16, height: 16)
            Text(text)
                .font(TFFont.callout)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(TFColor.textSecondary)
        .padding(.horizontal, TFSpace.md)
        .frame(minHeight: 40)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Spacer()
            switch model.screen {
            case .pickLines(_, let purpose):
                Text(purpose == .reportMissing ? "Report" : "Add")
                    .font(TFFont.footnote)
                    .foregroundStyle(model.selectedQuote == nil ? TFColor.textSecondary.opacity(0.5) : TFColor.textSecondary)
                Keycap("⌘↩")
            case .list, .detail:
                // 진행 상태를 바꾸거나 지운 뒤 잠시 되돌리기
                if model.canUndo {
                    Text("Undo")
                        .font(TFFont.footnote)
                        .foregroundStyle(TFColor.textSecondary)
                    Keycap("⌘Z")
                        .padding(.trailing, TFSpace.sm)
                }
                // 처리방침 변경 안내 줄을 고르면 닫기
                if model.canDismissNotice {
                    Text("Dismiss")
                        .font(TFFont.footnote)
                        .foregroundStyle(TFColor.textSecondary)
                    Keycap("⌘⌫")
                        .padding(.trailing, TFSpace.sm)
                }
                // 할 일 행이 아니면 (명령 · Add 등) ⌘K가 할 일이 없어 흐리게
                Text("Actions")
                    .font(TFFont.footnote)
                    .foregroundStyle(model.canOpenActions ? TFColor.textSecondary : TFColor.textSecondary.opacity(0.5))
                Keycap("⌘K")
            default:
                // 직접 추가 · 신고를 보내는 중에는 esc가 할 일이 없어 흐리게
                Text("Back")
                    .font(TFFont.footnote)
                    .foregroundStyle(model.isSubmitting ? TFColor.textSecondary.opacity(0.5) : TFColor.textSecondary)
                Keycap("esc")
            }
        }
        .padding(.horizontal, TFSpace.md)
        .padding(.top, 10)
        .padding(.bottom, TFSpace.xs)
    }
}
#endif
