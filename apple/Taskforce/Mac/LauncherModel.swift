#if os(macOS)
import AppKit
import AuthenticationServices
import Carbon.HIToolbox
import Observation
import TaskforceKit

/// ⌥Space 런처의 상태와 키보드. 무엇을 보여 줄지(입력 모드 · 거르기 · 묶기)는 TaskforceKit의 순수 함수(`LauncherContent`)가 정하고,
/// 여기서는 선택 · 화면 전환 · 서버 호출만 한다.
@MainActor
@Observable
final class LauncherModel {
    /// 할 일 행에서 ⌘K로 여는 동작 패널의 대상
    struct Target: Equatable {
        let action: ActionSummary
        let isReview: Bool
    }

    enum Screen: Equatable {
        case list
        /// ⌘K 동작 패널
        case actions(Target)
        /// Tab/→ 펼침: Sources 묶음
        case detail(Target)
        case editDue(Target)
        /// 직접 추가: 기한 고르기 → 원문 고르기(없어도 됨) → 줄 고르기. 원문 고르기에서 돌아와도 고른 기한이 남는다.
        case addDue(Draft)
        case working(String)
        /// 답 + 근거 줄 (근거 줄은 한 번만 만든다)
        case answer(question: String, response: AskResponse, lines: [EvidenceLine])
        /// 원문 고르기 → 줄 고르기 (빠진 할 일 신고 · 직접 추가의 근거)
        case pickSource(SourcePurpose)
        case pickLines(SourceRecord, SourcePurpose)
        /// 동작 완료 (잠시 뒤 닫힌다)
        case done(String)
        case notice(String)
        /// 외부 AI 처리 동의가 먼저 필요함
        case consentNeeded
    }

    enum ActionEntry: Hashable, CaseIterable {
        case confirm, dismiss, complete, start, handoff, openSource, editDue

        var title: String {
            switch self {
            case .confirm: "Confirm"
            case .dismiss: "Dismiss"
            case .complete: "Complete"
            case .start: "Start"
            case .handoff: "Hand off to AI"
            case .openSource: "Open source"
            case .editDue: "Edit due"
            }
        }

        var symbolName: String {
            switch self {
            case .confirm: "checkmark"
            case .dismiss: "xmark"
            case .complete: "checkmark.circle"
            case .start: "play"
            case .handoff: "paperplane"
            case .openSource: "arrow.up.right.square"
            case .editDue: "calendar"
            }
        }
    }

    typealias DueChoice = LauncherDue.Choice

    /// 원문 · 줄 고르기를 연 흐름
    enum SourcePurpose: Equatable {
        case reportMissing
        /// 직접 추가 (제목 · 기한을 고른 뒤)
        case add(Draft)
    }

    /// 직접 추가할 할 일
    struct Draft: Equatable {
        let title: String
        let due: LocalDate?
    }

    var text = "" {
        didSet { if text != oldValue { textChanged() } }
    }
    var selection = 0
    private(set) var screen: Screen = .list
    /// 바뀌면 입력창에 포커스를 준다
    private(set) var focusRequest = 0
    private(set) var recentSources: [SourceSummary] = []
    private(set) var sourceText: SourceText?
    var lineSelection = LineSelection()
    var lineCursor = 0
    var pickedDate = Date()
    let configurationError: String?

    let session: SessionStore?
    let services: AppServices?
    let now: NowStore?
    let account: AccountStore?
    let changes = ActionChangeFeed()

    /// 패널 컨트롤러가 채운다
    var close: () -> Void = {}
    var presentationAnchor: () -> NSWindow? = { nil }
    /// Apple 로그인 창을 띄운 동안은 포커스를 잃어도 닫지 않는다
    private(set) var suspendsAutoClose = false

    /// 취소해도 되는 읽기 (물어보기 · 원문 읽기). 쓰기는 창을 닫아도 끝까지 보낸다.
    private var work: Task<Void, Never>?
    /// 동작 완료 뒤 닫기
    private var closeTimer: Task<Void, Never>?
    /// 쓰기마다 오른다: 끝난 쓰기가 그사이 바뀐 화면을 덮지 않게
    private var writeGeneration = 0
    /// 보내는 중인 직접 추가 · 빠진 할 일 신고의 쓰기 번호. 한 흐름에 한 번만 보낸다 (`isSubmitting`).
    private var submission: Int?
    /// 목록이 바뀌어도 같은 행을 가리키게 (Realtime · 다시 불러오기)
    private var selectedID: String?
    private var lastUserID: UUID?
    /// 최근 원문을 다 읽었는지 (빈 목록과 읽는 중을 나눈다)
    private(set) var sourcesLoaded = false
    private let signInFlow = AppleSignInFlow()
    private var signInController: MacAppleSignInController?

    init(session: SessionStore, services: AppServices, account: AccountStore) {
        self.session = session
        self.services = services
        self.account = account
        let now = NowStore(services: services)
        #if DEBUG
        if SampleData.isEnabled { now.useSampleData() }
        #endif
        self.now = now
        configurationError = nil
    }

    init(configurationError: String) {
        session = nil
        services = nil
        now = nil
        account = nil
        self.configurationError = configurationError
    }

    var isSignedIn: Bool {
        #if DEBUG
        if now?.sampleMode == true { return true }
        #endif
        if case .signedIn = session?.state { return true }
        return false
    }

    var signedInUserID: UUID? {
        if case .signedIn(let userID, _) = session?.state { userID } else { nil }
    }

    var inputMode: LauncherInput.Mode { LauncherInput.mode(for: text) }

    var sections: [LauncherSection] {
        guard configurationError == nil, isSignedIn || session?.state != .loading else { return [] }
        return LauncherContent.sections(
            for: inputMode, now: now?.response, signedIn: isSignedIn, needsConsent: account?.shouldPromptConsent ?? false
        )
    }

    var items: [LauncherItem] { sections.flatMap(\.items) }

    var selectedItem: LauncherItem? {
        let items = items
        return items.indices.contains(selection) ? items[selection] : nil
    }

    var filteredSources: [SourceSummary] {
        // 직접 추가 중에는 입력창에 제목이 있어서 거르지 않는다
        guard case .pickSource(.reportMissing) = screen else { return recentSources }
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return recentSources }
        return recentSources.filter { TaskFilter.matches(text: $0.title ?? "", query: query) }
    }

    var dueChoices: [DueChoice] {
        let today = DueDateFormat.today()
        if case .addDue(let draft) = screen { return LauncherDue.choices(today: today, adding: true, keeping: draft.due) }
        return LauncherDue.choices(today: today, adding: false)
    }

    /// 직접 추가의 원문 고르기는 맨 위에 "No source" 한 줄이 있다
    var sourceRowOffset: Int {
        if case .pickSource(.add) = screen { 1 } else { 0 }
    }

    /// ⌘K로 동작 패널을 열 수 있는지 (아래 "Actions ⌘K")
    var canOpenActions: Bool {
        switch screen {
        case .list: selectedItem?.action != nil
        case .detail: true
        default: false
        }
    }

    func actionEntries(for target: Target) -> [ActionEntry] {
        var entries: [ActionEntry] = target.isReview ? [.confirm, .dismiss] : [.complete]
        if !target.isReview, target.action.startedAt == nil { entries.append(.start) }
        entries += [.handoff, .openSource, .editDue]
        return entries
    }

    /// 지금 화면에서 ↑↓로 고르는 줄 수
    var rowCount: Int {
        switch screen {
        case .list: items.count
        case .actions(let target): actionEntries(for: target).count
        case .editDue, .addDue: dueChoices.count
        case .pickSource: sourceRowOffset + filteredSources.count
        case .pickLines: sourceText?.lines.count ?? 0
        default: 0
        }
    }

    // MARK: 열고 닫기

    func prepareForShow() {
        closeTimer?.cancel()
        focusRequest += 1
        // 직접 추가 · 신고를 보내는 중이면 그 진행 화면을 그대로 보여 준다 (목록으로 돌아가 다시 보내면 중복)
        guard !isSubmitting else { return }
        work?.cancel()
        text = ""
        screen = .list
        selection = 0
        selectedID = nil
        guard isSignedIn, let now else { return }
        Task { await now.load() }
        // 동의 · 연결 상태 (동의 전인데 연결이 있으면 맨 위에 "Allow AI processing")
        if let account { Task { await account.load() } }
    }

    func didHide() {
        closeTimer?.cancel()
        suspendsAutoClose = false
    }

    func reportAppOpened() {
        guard let services else { return }
        Task { try? await services.api.appOpened() }
    }

    /// 로그인 상태가 바뀌면 (로그아웃 · 계정 전환) 전 사용자의 목록을 지운다. 토큰 갱신처럼 같은 사용자면 그대로 둔다.
    func sessionChanged() {
        let userID = signedInUserID
        guard userID != lastUserID else { return }
        lastUserID = userID
        now?.reset()
        account?.reset()
        recentSources = []
        sourcesLoaded = false
        sourceText = nil
        // 전 사용자의 쓰기 결과는 보여 주지 않는다
        writeGeneration += 1
        screen = .list
        selection = 0
        selectedID = nil
        guard isSignedIn, let now else { return }
        Task { await now.load() }
        if let account { Task { await account.load() } }
    }

    // MARK: 키보드

    /// 런처 창의 키 입력. 처리했으면 true (입력창으로 보내지 않는다).
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let keyCode = Int(event.keyCode)
        // 기한 고치기의 날짜 칸에 포커스가 있으면 방향키 · Tab은 날짜 칸이 쓰고, ↩는 그 날짜로 저장한다
        if event.window?.firstResponder is NSDatePicker, keyCode != kVK_Escape {
            guard keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter, isChoosingDue else { return false }
            chooseDue(LocalDate(date: pickedDate, timeZone: .current))
            return true
        }
        switch keyCode {
        case kVK_Escape:
            back()
            return true
        case kVK_UpArrow:
            move(-1)
            return true
        case kVK_DownArrow:
            move(1)
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            // ⌥↩ · ⇧↩는 입력창에서 줄바꿈
            if flags.contains(.option) || flags.contains(.shift) { return false }
            command ? commandReturn() : primary()
            return true
        case kVK_Tab:
            expand()
            return true
        case kVK_RightArrow:
            guard screen == .list, caretAtEnd(in: event.window), selectedItem?.action != nil else { return false }
            expand()
            return true
        case kVK_ANSI_K where command:
            openActions()
            return true
        case kVK_Delete where command:
            // 입력이 있으면 ⌘⌫는 줄 지우기
            guard screen == .list, text.isEmpty, case .review(let action) = selectedItem else { return false }
            perform(.dismiss, on: Target(action: action, isReview: true))
            return true
        default:
            return false
        }
    }

    private func caretAtEnd(in window: NSWindow?) -> Bool {
        guard let editor = window?.firstResponder as? NSTextView else { return true }
        let range = editor.selectedRange()
        return range.length == 0 && range.location >= (editor.string as NSString).length
    }

    func move(_ delta: Int) {
        if case .pickLines = screen {
            lineCursor = LauncherContent.move(lineCursor, by: delta, count: rowCount)
        } else {
            select(LauncherContent.move(selection, by: delta, count: rowCount))
        }
    }

    /// 행 고르기 (목록이면 그 행의 id도 기억한다)
    func select(_ index: Int) {
        selection = index
        if screen == .list { selectedID = selectedItem?.id }
    }

    /// 목록이 새로 왔을 때: 고르던 행이 아직 있으면 그 행을, 없으면 같은 자리(끝을 넘지 않게)를 가리킨다
    func reconcileSelection() {
        guard screen == .list else { return }
        let items = items
        if let selectedID, let index = items.firstIndex(where: { $0.id == selectedID }) {
            selection = index
        } else {
            selection = LauncherContent.move(selection, by: 0, count: items.count)
            selectedID = items.indices.contains(selection) ? items[selection].id : nil
        }
    }

    /// return
    func primary() {
        switch screen {
        case .list:
            if let item = selectedItem { run(item) }
        case .actions(let target):
            let entries = actionEntries(for: target)
            if entries.indices.contains(selection) { perform(entries[selection], on: target) }
        case .detail(let target):
            openActions(target)
        case .editDue, .addDue:
            let choices = dueChoices
            guard choices.indices.contains(selection) else { return }
            switch choices[selection] {
            case .date(let date): chooseDue(date)
            case .clear: chooseDue(nil)
            }
        case .answer:
            back()
        case .pickSource(let purpose):
            if case .add(let draft) = purpose, selection == 0 {
                create(draft, source: nil, quote: nil)
                return
            }
            let sources = filteredSources
            let index = selection - sourceRowOffset
            if sources.indices.contains(index) { pick(sources[index], for: purpose) }
        case .pickLines:
            lineSelection.tap(lineCursor)
        case .done, .notice:
            back()
        case .consentNeeded:
            openSettings(.ai)
        case .working:
            break
        }
    }

    /// ⌘↩: 줄을 고른 뒤 신고 · 추가
    func commandReturn() {
        if case .pickLines = screen {
            submitLines()
        } else {
            primary()
        }
    }

    /// Tab/→: Sources 묶음 펼치기
    func expand() {
        guard screen == .list, let item = selectedItem, let action = item.action else { return }
        let target = Target(action: action, isReview: isReview(item))
        screen = .detail(target)
        Task { await now?.loadEvidence(action.id) }
    }

    /// ⌘K
    func openActions() {
        switch screen {
        case .list:
            guard let item = selectedItem, let action = item.action else { return }
            openActions(Target(action: action, isReview: isReview(item)))
        case .detail(let target):
            openActions(target)
        default:
            break
        }
    }

    private func openActions(_ target: Target) {
        screen = .actions(target)
        selection = 0
    }

    /// esc: 한 단계 뒤로, 목록이면 입력을 지우고, 비어 있으면 닫는다
    func back() {
        switch screen {
        case .list:
            if text.isEmpty { close() } else { text = "" }
        case .editDue(let target):
            screen = .actions(target)
            selection = 0
        case .pickSource(.add(let draft)):
            screen = .addDue(draft)
            selection = LauncherDue.index(of: draft.due, in: dueChoices)
            pickedDate = draft.due.map(Self.pickerDate) ?? Date()
        case .pickLines(_, let purpose):
            screen = .pickSource(purpose)
            selection = 0
        case .working:
            // 직접 추가 · 신고는 결과가 올 때까지 기다린다 (돌아가서 다시 보내면 중복)
            guard !isSubmitting else { return }
            work?.cancel()
            writeGeneration += 1
            screen = .list
            selection = 0
        default:
            screen = .list
            selection = 0
        }
    }

    private func textChanged() {
        switch screen {
        case .list, .pickSource:
            selection = 0
            selectedID = nil
        case .actions, .detail, .answer, .done, .notice, .consentNeeded:
            screen = .list
            selection = 0
            selectedID = nil
        case .editDue, .addDue, .working, .pickLines:
            break
        }
    }

    private func isReview(_ item: LauncherItem) -> Bool {
        if case .review = item { return true }
        guard let id = item.action?.id else { return false }
        return now?.confirmations.contains { $0.id == id } ?? false
    }

    // MARK: 실행

    func run(_ item: LauncherItem) {
        switch item {
        case .review(let action):
            perform(.confirm, on: Target(action: action, isReview: true))
        case .task(let ranked):
            openActions(Target(action: ranked.action, isReview: false))
        case .command(let command):
            run(command)
        case .ask(let question):
            ask(question)
        case .handoff(let action):
            perform(.handoff, on: Target(action: action, isReview: false))
        case .sendAsSource(let text):
            send(text)
        case .addAction(let title):
            startAdd(title)
        case .signIn:
            startSignIn()
        case .signInWithEmail:
            // 이메일 로그인은 설정 창의 로그인 화면에서 (입력칸 둘)
            UserDefaults.standard.set(true, forKey: SignInView.emailExpandedKey)
            openSettings(.account)
        case .allowAI:
            openSettings(.ai)
        }
    }

    private func run(_ command: LauncherCommand) {
        switch command {
        case .sendClipboard:
            guard let text = Clipboard.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                screen = .notice("The clipboard is empty.")
                return
            }
            send(text)
        case .reportMissing:
            startReportMissing()
        case .connections:
            openSettings(.connections)
        case .settings:
            openSettings(.account)
        case .quit:
            NSApplication.shared.terminate(nil)
        }
    }

    func perform(_ entry: ActionEntry, on target: Target) {
        guard let now else { return }
        let id = target.action.id
        switch entry {
        case .confirm: finish("Confirmed") { await now.confirm(id) }
        case .dismiss: finish("Dismissed") { await now.dismiss(id) }
        case .complete: finish("Completed") { await now.complete(id, lingering: false) }
        case .start: finish("Started") { await now.start(id) }
        case .handoff: finish("Copied") { _ = await now.handoff(id) }
        case .openSource: openSource(target.action)
        case .editDue:
            screen = .editDue(target)
            selection = 0
            pickedDate = target.action.dueDate.map(Self.pickerDate) ?? Date()
        }
    }

    private var isChoosingDue: Bool {
        switch screen {
        case .editDue, .addDue: true
        default: false
        }
    }

    /// 기한 고르기의 결과: 있는 할 일이면 저장, 추가 중이면 다음 단계(원문 고르기)로
    func chooseDue(_ due: LocalDate?) {
        switch screen {
        case .editDue(let target): setDue(due, on: target)
        case .addDue(let draft): startPickSource(.add(Draft(title: draft.title, due: due)))
        default: break
        }
    }

    func setDue(_ due: LocalDate?, on target: Target) {
        guard let now else { return }
        let label = due.map { "Due \(DueText.short($0, today: DueDateFormat.today()))" } ?? "Due date cleared"
        finish(label) { await now.setDue(target.action.id, due) }
    }

    /// 서버 호출 → 성공하면 "Done" 한 줄을 잠깐 보이고 닫는다. `NowStore`가 남긴 오류가 있으면 알린다.
    private func finish(_ message: String, _ operation: @escaping @MainActor () async -> Void) {
        guard let now else { return }
        now.message = nil
        let generation = beginWrite()
        // 쓰기는 창을 닫아도 끝까지 보낸다 (취소하면 서버에 반영됐는지 알 수 없다)
        Task {
            await operation()
            let error = now.message
            now.message = nil
            guard isCurrentWrite(generation) else { return }
            if let error {
                screen = .notice(error)
            } else {
                showDoneAndClose(message)
            }
        }
    }

    private func beginWrite() -> Int {
        work?.cancel()
        writeGeneration += 1
        screen = .working("Working…")
        return writeGeneration
    }

    /// 이 쓰기를 시작한 화면이 아직 그대로인지 (그사이 esc · 다시 열기로 바뀌었으면 결과를 조용히 둔다)
    private func isCurrentWrite(_ generation: Int) -> Bool {
        guard generation == writeGeneration, case .working = screen else { return false }
        return true
    }

    /// 직접 추가 · 신고를 보내는 중이라 그 진행 화면에 머문다: esc로 돌아가지 않고, 창을 다시 열어도 그대로다
    var isSubmitting: Bool {
        guard let submission else { return false }
        return isCurrentWrite(submission)
    }

    /// 직접 추가 · 신고 쓰기 시작 (`isSubmitting`)
    private func beginSubmission() -> Int {
        let generation = beginWrite()
        submission = generation
        return generation
    }

    private func endSubmission(_ generation: Int) {
        if submission == generation { submission = nil }
    }

    private func showDoneAndClose(_ message: String) {
        screen = .done(message)
        closeTimer?.cancel()
        closeTimer = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, case .done = screen else { return }
            close()
        }
    }

    private func openSource(_ action: ActionSummary) {
        guard let now else { return }
        screen = .working("Opening…")
        work = Task {
            let digest = await now.loadEvidence(action.id)
            guard !Task.isCancelled else { return }
            let url = digest?.lead?.externalURL ?? digest?.lines.last(where: { $0.externalURL != nil })?.externalURL
            if let url {
                open(url)
            } else {
                screen = .notice("No link to the original.")
            }
        }
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
        close()
    }

    func openSettings(_ tab: MacSettingsTab) {
        close()
        SettingsOpener.open(tab)
    }

    // MARK: 물어보기 · 원문 보내기

    private func ask(_ question: String) {
        guard let services else { return }
        screen = .working("Asking…")
        work = Task {
            do {
                let response = try await services.api.ask(question)
                guard !Task.isCancelled else { return }
                screen = .answer(question: question, response: response, lines: response.citations.map(EvidenceLine.init))
                selection = 0
            } catch is CancellationError {
            } catch let error as APIError {
                guard !Task.isCancelled else { return }
                screen = Self.screen(for: error, rateLimited: "Too many questions. Try again in a moment.", missing: "Ask isn't available yet.")
            } catch {
                screen = .notice(error.userMessage)
            }
        }
    }

    private func send(_ text: String) {
        guard let services else { return }
        guard let request = PastedSource.request(for: text) else {
            screen = .notice("That's too long to send as one source.")
            return
        }
        let generation = beginWrite()
        Task {
            do {
                _ = try await services.api.createSource(request)
                guard isCurrentWrite(generation) else { return }
                showDoneAndClose("Sent")
            } catch let error as APIError {
                guard isCurrentWrite(generation) else { return }
                screen = Self.screen(for: error, rateLimited: "Too many requests. Try again in a moment.", missing: error.userMessage)
            } catch {
                guard isCurrentWrite(generation) else { return }
                screen = .notice(error.userMessage)
            }
        }
    }

    private static func screen(for error: APIError, rateLimited: String, missing: String) -> Screen {
        if error.isConsentRequired { return .consentNeeded }
        switch error {
        case .server(_, .rateLimited, _): return .notice(rateLimited)
        case .server(404, _, _), .unexpectedStatus(404): return .notice(missing)
        default: return .notice(error.userMessage)
        }
    }

    // MARK: 빠진 할 일 신고 · 직접 추가

    private func startReportMissing() {
        text = ""
        startPickSource(.reportMissing)
    }

    /// "Add “…”": 기한 → 원문(없어도 됨) → 줄 → 추가. 제목은 입력창에 그대로 둔다.
    private func startAdd(_ title: String) {
        screen = .addDue(Draft(title: title, due: nil))
        selection = 0
        pickedDate = Date()
    }

    private func startPickSource(_ purpose: SourcePurpose) {
        guard let services else { return }
        work?.cancel()
        screen = .pickSource(purpose)
        selection = 0
        sourcesLoaded = false
        work = Task {
            let sources = (try? await services.reads.recentSources(limit: 30)) ?? []
            guard !Task.isCancelled else { return }
            // 읽는 중인 원문은 결과가 나오기 전이라 신고를 받지 않는다
            recentSources = sources.filter { $0.processingStatus == .done || $0.processingStatus == .failed }
            sourcesLoaded = true
        }
    }

    private func pick(_ source: SourceSummary, for purpose: SourcePurpose) {
        guard let services else { return }
        screen = .working("Opening…")
        work = Task {
            do {
                let detail = try await services.reads.sourceDetail(id: source.id)
                guard !Task.isCancelled else { return }
                let text = SourceText(detail.source.rawText)
                sourceText = text
                lineSelection.clear()
                lineCursor = text.lines.first { !$0.isBlank }?.index ?? 0
                screen = .pickLines(detail.source, purpose)
            } catch is CancellationError {
            } catch {
                screen = .notice(error.userMessage)
            }
        }
    }

    var selectedQuote: String? {
        guard let range = lineSelection.range else { return nil }
        return sourceText?.quote(lines: range)
    }

    /// ⌘↩: 고른 줄로 신고하거나, 그 줄을 근거로 추가한다
    func submitLines() {
        guard case .pickLines(let source, let purpose) = screen, let quote = selectedQuote else { return }
        guard quote.utf16.count <= SourceText.maxQuoteLength else {
            screen = .notice("Pick fewer lines (up to \(SourceText.maxQuoteLength) characters).")
            return
        }
        switch purpose {
        case .reportMissing: reportMissing(source: source, quote: quote)
        case .add(let draft): create(draft, source: source, quote: quote)
        }
    }

    private func reportMissing(source: SourceRecord, quote: String) {
        guard let services else { return }
        let generation = beginSubmission()
        Task {
            defer { endSubmission(generation) }
            do {
                let result = try await services.api.reportMissing(sourceID: source.id, quote: quote)
                await now?.load()
                guard isCurrentWrite(generation) else { return }
                let title = result.action.title
                showDoneAndClose(result.status == .created ? "Added “\(title)”" : "Already tracked “\(title)”")
            } catch let error as APIError {
                guard isCurrentWrite(generation) else { return }
                if case .server(_, .rateLimited, _) = error {
                    screen = .notice("Too many reports. Try again in a moment.")
                } else {
                    screen = .notice(error.userMessage)
                }
            } catch {
                guard isCurrentWrite(generation) else { return }
                screen = .notice(error.userMessage)
            }
        }
    }

    private func create(_ draft: Draft, source: SourceRecord?, quote: String?) {
        guard let services else { return }
        let generation = beginSubmission()
        Task {
            defer { endSubmission(generation) }
            do {
                let result = try await services.api.createAction(
                    title: draft.title, dueDate: draft.due, sourceID: source?.id, quote: quote
                )
                await now?.load()
                guard isCurrentWrite(generation) else { return }
                showDoneAndClose(result.status == .created ? "Added" : "Already tracked")
            } catch {
                guard isCurrentWrite(generation) else { return }
                screen = .notice(error.userMessage)
            }
        }
    }

    // MARK: 로그인

    private func startSignIn() {
        guard let session, let anchor = presentationAnchor() else { return }
        suspendsAutoClose = true
        NSApplication.shared.activate()
        let controller = MacAppleSignInController(anchor: anchor) { [weak self] result in
            guard let self else { return }
            self.suspendsAutoClose = false
            self.signInFlow.handle(result, session: session)
            self.signInController = nil
            self.focusRequest += 1
        }
        signInController = controller
        controller.start(configure: signInFlow.configure)
    }

    /// 기한 선택기의 Date ↔ 기한 날짜 (선택기는 기기 시간대로 날짜를 보여준다)
    static func pickerDate(_ date: LocalDate) -> Date {
        var components = DateComponents(year: date.year, month: date.month, day: date.day, hour: 12)
        components.timeZone = .current
        return Calendar(identifier: .gregorian).date(from: components) ?? Date()
    }
}

/// 런처의 "Sign in with Apple" 행: SignInWithAppleButton 없이 같은 요청을 보낸다 (결과 처리는 `AppleSignInFlow`)
@MainActor
final class MacAppleSignInController: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private let anchor: NSWindow
    private let completion: (Result<ASAuthorization, Error>) -> Void

    init(anchor: NSWindow, completion: @escaping (Result<ASAuthorization, Error>) -> Void) {
        self.anchor = anchor
        self.completion = completion
    }

    func start(configure: (ASAuthorizationAppleIDRequest) -> Void) {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        configure(request)
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        completion(.success(authorization))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        completion(.failure(error))
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        anchor
    }
}
#endif
