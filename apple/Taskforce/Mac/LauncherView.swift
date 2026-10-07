#if os(macOS)
import SwiftUI
import TaskforceKit
import TaskforceUI

/// 런처 창 내용 (Figma 156:6 M1 · M20, 760×480 고정): 검색줄 → full-width 목록과 펼친 상세 → 액션 바.
/// Run with AI · 초안은 목록을 대신해 한 열로 보인다.
struct LauncherRootView: View {
    @Bindable var model: LauncherModel

    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 0) {
            LauncherSearchBar(model: model, focused: $searchFocused, locked: inputLocked)
            bodyCard
            LauncherActionBar(model: model)
        }
        .padding(.horizontal, TFSpace.xs)
        .frame(width: LauncherPanelController.size.width, height: LauncherPanelController.size.height)
        // 검색줄 · 액션 바는 유리 위 (bg/glass, 투명도 줄이기면 불투명 settings/window)
        .background(reduceTransparency ? TFColor.settingsWindow : TFColor.bgGlass)
        .overlay(alignment: .topTrailing) {
            if model.scopeMenuSelection != nil {
                ZStack(alignment: .topTrailing) {
                    // 메뉴 밖을 누르면 닫는다
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { model.closeScopeMenu() }
                    LauncherScopeMenu(model: model)
                        .padding(.top, 48)
                        .padding(.trailing, 18)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: TFRadius.window, style: .continuous))
        .overlay {
            // 유리 재질(macOS 15)에만 창 테두리. Liquid Glass는 제 가장자리를 그린다
            if !LauncherPanelController.usesGlass {
                RoundedRectangle(cornerRadius: TFRadius.window, style: .continuous)
                    .strokeBorder(TFColor.borderDefault, lineWidth: 1)
            }
        }
        .onChange(of: model.focusRequest, initial: true) { if !model.notesEditorFocused { searchFocused = true } }
        // 줄 고르기 · 기한 고르기 · Run with AI · 초안에서 돌아오면 다시 입력창으로
        .onChange(of: inputLocked) { _, locked in if !locked && !model.notesEditorFocused { searchFocused = true } }
        .onChange(of: model.isSubScreen) { _, sub in if !sub && !model.notesEditorFocused { searchFocused = true } }
        // Realtime · 다시 불러오기 · 범위 · 펼침으로 목록이 바뀌어도 고르던 행을 그대로
        .onChange(of: model.items.map(\.id)) { model.reconcileSelection() }
        // 고른 할 일이 바뀌면 바뀜 점 · seen (화살표로 지나가기 포함)
        .onChange(of: model.seenSubject, initial: true) { model.syncSeen() }
        .task(id: model.signedInUserID) {
            // 로그인해 있는 동안 Realtime 구독 하나 (런처가 숨어 있어도 목록을 새로 둔다)
            guard let userID = model.signedInUserID, let services = model.services else { return }
            await model.changes.follow(services: services, userID: userID)
        }
        .onChange(of: model.changes.revision) {
            Task { await model.now?.load() }
            // 초안 receipt가 Action을 바꾼다: 보이는 할 일의 run · 끝나지 않은 run도 다시 읽는다
            Task { await model.runs?.actionsChanged() }
        }
        // 상세에 보이는 할 일의 run 상태를 지켜본다 (움직이는 run이 있을 때만 폴링, 화살표로 빠르게 지나갈 때는 잠깐 기다린다).
        // 런처가 숨으면 그만 본다
        .task(id: model.runSubject) {
            guard let id = model.runSubject else {
                model.runs?.watch([])
                return
            }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            model.runs?.watch([id])
        }
        // 연결이 동기화 중이면 런처가 떠 있는 동안 몇 초마다 연결을 다시 읽고, 끝나면 지금 할 일을 다시 불러온다
        .task(id: model.isShown && model.account?.anySyncing == true) {
            guard model.isShown, let account = model.account, account.anySyncing else { return }
            await account.followSync()
        }
        .onChange(of: model.account?.syncFinished) {
            Task { await model.now?.load() }
        }
        // 오프라인 · 새로고침 실패로 바뀌면 VoiceOver가 알린다
        .onChange(of: model.statusText) { _, text in
            guard let text else { return }
            AccessibilityNotification.Announcement(text).post()
        }
        .onChange(of: model.feedbackMessage) { _, text in
            guard let text else { return }
            AccessibilityNotification.Announcement(text).post()
        }
        .onChange(of: model.now?.sourceServicesFailed) { _, failed in
            guard failed == true else { return }
            AccessibilityNotification.Announcement("Source icons unavailable. Retry is available in the task list.").post()
        }
    }

    private var inputLocked: Bool {
        switch model.screen {
        case .editDue, .addDue, .pickLines, .working, .handoff: true
        // 직접 추가 중에는 입력창에 제목을 그대로 보여 준다
        case .pickSource(let purpose): purpose != .reportMissing
        default: false
        }
    }

    // MARK: 본문 카드

    private var bodyCard: some View {
        let shape = RoundedRectangle(cornerRadius: TFRadius.panel, style: .continuous)
        return Group {
            switch model.bodyState {
            case .list:
                if model.isSubScreen {
                    LauncherDetailPane(model: model)
                } else {
                    LauncherListPane(model: model)
                }
            case .single:
                LauncherFlowView(model: model)
            case let state:
                LauncherStateView(state: state)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TFColor.bgElevated)
        .clipShape(shape)
        .overlay(shape.strokeBorder(TFColor.settingsLine, lineWidth: 1))
    }
}

/// 본문 카드 한 열: 로그인 줄 · ⌘K 패널 · 명령 · 기한 · 물어보기 답 · 원문 · 줄 고르기 · 진행 · 알림 (Figma에 없는 화면, 지금 부품 그대로)
struct LauncherFlowView: View {
    @Bindable var model: LauncherModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) { content }
                    .padding(TFSpace.sm)
            }
            .onChange(of: model.selection) { _, index in
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(index) }
            }
            .onChange(of: model.lineCursor) { _, index in
                proxy.scrollTo(index)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.screen {
        case .list, .detail:
            // 로그아웃: 로그인 줄 · Quit (지금 그대로)
            signedOutRows
        case .actions(let target):
            actionRows(target)
        case .commands:
            commandRows
        case .editDue, .addDue:
            dueRows
        case .working(let label):
            statusRow(label, symbol: nil)
        case .answer(let question, let response, let lines):
            answer(question: question, response: response, lines: lines)
        case .pickSource(let purpose):
            sourceRows(purpose)
        case .pickLines:
            lineRows
        case .done(let message):
            statusRow(message, symbol: "checkmark.circle")
        case .notice(let message):
            statusRow(message, symbol: "exclamationmark.circle")
        case .consentNeeded:
            LauncherSectionLabel("Privacy & AI Data")
            LauncherRow(title: "Allow AI processing to continue", selected: true, leading: .symbol("hand.raised"))
                .onTapGesture { model.primary() }
        case .runWithAI, .handoff, .draft:
            // 목록 | 상세 칸에 그린다 (`LauncherDetailPane`)
            EmptyView()
        }
    }

    private var today: LocalDate { DueDateFormat.today() }

    @ViewBuilder
    private var signedOutRows: some View {
        VStack(alignment: .leading, spacing: TFSpace.md) {
            Text(SessionStore.googleOnlyNotice)
                .font(TFFont.footnote)
                .foregroundStyle(TFColor.textSecondary)
                .padding(.horizontal, TFSpace.md)
            Link("Contact for account access or deletion help", destination: AccountDeletion.contactURL)
                .font(TFFont.footnote)
                .padding(.horizontal, TFSpace.md)
            if !GoogleSignInFlow.isAvailable {
                Text("Google sign-in is unavailable in this build.")
                    .font(TFFont.footnote)
                    .padding(.horizontal, TFSpace.md)
            }
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                signedOutRow(item, selected: index == model.selection)
                    .id(index)
                    .onTapGesture {
                        model.select(index)
                        model.run(item)
                    }
            }
        }
    }

    @ViewBuilder
    private func signedOutRow(_ item: LauncherItem, selected: Bool) -> some View {
        switch item {
        case .signInWithGoogle:
            LauncherRow(title: SignInWithGoogleButton.title, selected: selected, leading: .google)
        case .command(let command):
            LauncherRow(title: command.title, selected: selected, leading: .symbol(command.symbolName))
        default:
            EmptyView()
        }
    }

    // MARK: ⌘K 동작 · 명령

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

    @ViewBuilder
    private var commandRows: some View {
        LauncherSectionLabel("Commands")
        ForEach(Array(LauncherCommand.allCases.enumerated()), id: \.element) { index, command in
            LauncherRow(title: command.title, selected: index == model.selection, leading: .symbol(command.symbolName))
                .id(index)
                .onTapGesture {
                    model.selection = index
                    model.primary()
                }
        }
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

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
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
        case .execution: "Execution record"
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

    // MARK: 한 줄 상태

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
}
#endif
