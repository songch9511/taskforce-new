#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

/// Mac 설정 창 (Figma S1 239:1614 · S7 269:5822): 760×480, 왼쪽 사이드바 196 + 가운데 본문 열 468.
/// 연결 · 동의 화면은 iPhone과 같은 것을 쓰고, Account는 페이지가 아니라 시트다.
struct MacSettingsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(RunStore.self) private var runs
    @AppStorage(SettingsOpener.tabKey) private var stored: String?
    @State private var query = ""
    /// ↑↓로 시트 항목(Account)에 올라섰을 때만 있다. 페이지는 그대로 두고 ↩로 시트를 연다
    @State private var cursor: MacSettingsTab?
    /// 키보드는 검색칸에서 시작한다: 글자는 거르고 ↑↓는 항목을 옮기고 ↩는 연다 (⌘F로 돌아온다)
    @FocusState private var searchFocused: Bool
    /// 신호등이 있는 제목 막대 높이 (macOS 버전마다 다르다). 처음은 보통 창의 값, 창에 붙으면 그 창에서 다시 잰다
    @State private var titlebarHeight = NSWindow.frameRect(forContentRect: .zero, styleMask: [.titled, .closable]).height

    /// Figma S1: 창 760×480, 사이드바 196(오른쪽 선 포함), 본문 열 468
    static let windowSize = CGSize(width: 760, height: 480)
    static let sidebarWidth: CGFloat = 196
    static let column: CGFloat = 468
    /// 본문 칸(창 - 안쪽 4 × 2 - 사이드바 = 556) 가운데 열의 좌우 여백 44
    static let columnInset = (windowSize.width - 2 * TFSpace.xs - sidebarWidth - column) / 2

    private var page: MacSettingsTab { MacSettingsTab.page(stored: stored, execution: execution) }
    private var highlighted: MacSettingsTab { cursor ?? page }
    /// Usage & Credits는 실행을 쓸 수 있을 때, 또는 저장된 그 페이지를 불러오는 중일 때 (보이는 페이지가 사이드바에 있게)
    private var items: [MacSettingsTab.Item] {
        MacSettingsTab.sidebar(matching: query, executionAvailable: execution == .available || page == .usage)
    }

    /// 실행을 쓸 수 있는지: 로그아웃이면 쓸 수 없다. credits를 아직 읽지 못했으면(처음 · 전송 오류) 모름
    private var execution: MacSettingsTab.Execution {
        guard isSignedIn || Self.isSample else { return .unavailable }
        switch runs.credits {
        case .unknown: return .unknown
        case .unavailable: return .unavailable
        case .available: return .available
        }
    }

    private var isSignedIn: Bool {
        if case .signedIn = session.state { true } else { false }
    }

    private var signedInUserID: UUID? {
        if case .signedIn(let userID, _) = session.state { userID } else { nil }
    }

    var body: some View {
        @Bindable var route = SettingsRoute.shared
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(TFColor.settingsLine)
                .frame(width: 1)
            content
        }
        .background(TFColor.settingsContent)
        // Figma Panel: 창 안쪽 4 들여 위 12 · 아래 15 (창 외곽 18과 같은 중심), 창 위에서 38 아래
        .clipShape(UnevenRoundedRectangle(
            topLeadingRadius: TFRadius.panel, bottomLeadingRadius: 15, bottomTrailingRadius: 15, topTrailingRadius: TFRadius.panel,
            style: .continuous
        ))
        .padding([.horizontal, .bottom], TFSpace.xs)
        .padding(.top, max(38 - titlebarHeight, 0))
        // 창 전체가 760×480이 되게 제목 막대 높이를 뺀다 (제목 막대 아래까지 그리는 창도 그 높이를 더해 창 크기를 정한다)
        .frame(width: Self.windowSize.width, height: Self.windowSize.height - titlebarHeight)
        .background(TFColor.settingsWindow.ignoresSafeArea())
        .background(SettingsWindowChrome(titlebarHeight: $titlebarHeight))
        // 장면 창은 SwiftUI가 제목 막대를 다시 그리므로 같은 설정을 SwiftUI로도 준다
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .defaultFocus($searchFocused, true)
        .sheet(isPresented: $route.showsAccount) {
            MacAccountSheet()
        }
        // 시트가 닫히면 창에 키보드 자리가 없으므로 검색칸으로 돌려준다 (알약은 보던 페이지로)
        .onChange(of: route.showsAccount) { _, shows in
            guard !shows else { return }
            cursor = nil
            searchFocused = true
        }
        // 창 밖에서 열면 (메뉴 · 런처 · 알림) 지난 검색어 · 키보드 자리를 지운다: 연 페이지가 걸러져 숨지 않게.
        // 설정 창은 닫아도 남아 있어 상태가 이어진다
        .onChange(of: route.openCount) {
            cursor = nil
            query = ""
            // 다시 열 때마다 실행을 쓸 수 있는지 다시 본다 (지급 · 켜기 뒤 다시 열면 바로 보이게)
            guard signedInUserID != nil else { return }
            Task { await runs.loadCredits() }
        }
        // Usage & Credits 항목: 로그인한 계정마다 credits를 읽는다 (404면 숨김, 전송 오류면 마지막 값 그대로)
        .task(id: signedInUserID) {
            guard signedInUserID != nil else { return }
            await runs.loadCredits()
        }
    }

    // MARK: 사이드바

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: TFSpace.xxs) {
            // 줄 높이는 Figma 글자 상자 그대로 (제목 23 · 그룹 이름 16 · 페이지 제목 28)
            Text("Settings")
                .font(TFFont.headline)
                .foregroundStyle(TFColor.textPrimary)
                .frame(height: 23)
                .padding(.leading, 6)
                .padding(.bottom, TFSpace.sm)
                .accessibilityAddTraits(.isHeader)
            searchField
            Color.clear.frame(height: TFSpace.xs)
            VStack(alignment: .leading, spacing: TFSpace.xxs) {
                ForEach(groups, id: \.group) { section in
                    Text(section.group.rawValue)
                        .font(TFFont.meta)
                        .foregroundStyle(TFColor.textSecondary)
                        .frame(height: 16)
                        .padding(.leading, TFSpace.sm)
                        .padding(.top, TFSpace.sm)
                        .padding(.bottom, TFSpace.xxs)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(section.items) { item in
                        row(item)
                    }
                }
                if items.isEmpty {
                    Text("No Results")
                        .font(TFFont.footnote)
                        .foregroundStyle(TFColor.textSecondary)
                        .padding(.horizontal, TFSpace.sm)
                        .padding(.top, TFSpace.sm)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Sidebar")
            Spacer(minLength: 0)
        }
        .padding(.top, 14)
        .padding(.horizontal, TFSpace.sm)
        .frame(width: Self.sidebarWidth - 1, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(TFColor.settingsSidebar)
        // ⌘F: 검색칸으로 (보이지 않는 버튼의 단축키)
        .background {
            Button("Search") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .focusable(false)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// Figma Search: settings/fill 알약, 자리표시는 회색 면 위 4.5:1을 지키는 text/secondary-selected (PR3 `KeyHint(onFill:)`와 같은 짝)
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(TFColor.textSecondarySelected)
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)
            TextField("Search", text: $query, prompt: Text("Search").foregroundStyle(TFColor.textSecondarySelected))
                .textFieldStyle(.plain)
                .font(TFFont.footnote)
                .foregroundStyle(TFColor.textPrimary)
                .focused($searchFocused)
                .accessibilityLabel("Search Settings")
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.escape) {
                    guard !query.isEmpty else { return .ignored }
                    query = ""
                    return .handled
                }
                .onSubmit { submitSearch() }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(TFColor.textSecondarySelected)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(TFColor.settingsFill, in: Capsule())
    }

    private func row(_ item: MacSettingsTab.Item) -> some View {
        let isHighlighted = highlighted == item.tab
        return Button {
            if item.tab.opensSheet {
                // 눌러서 연 시트는 선택을 옮기지 않는다 (닫으면 보던 페이지가 그대로 선택)
                cursor = nil
                SettingsRoute.shared.showsAccount = true
            } else {
                choose(item.tab, openingSheet: false)
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(TFColor.textPrimary)
                    .frame(width: 16, height: 16)
                Text(item.title)
                    .font(TFFont.footnote)
                    .foregroundStyle(TFColor.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if item.tab.opensSheet {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(TFColor.textSecondary)
                        .frame(width: 12, height: 12)
                }
            }
            .padding(.horizontal, TFSpace.sm)
            .frame(height: 28)
            .background(isHighlighted ? TFColor.settingsFill : .clear, in: RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
        .accessibilityHint(item.tab.opensSheet ? "Opens in a sheet" : "")
    }

    /// 거른 항목을 그룹 순서대로 (항목이 없는 그룹은 이름도 숨긴다)
    private var groups: [(group: MacSettingsTab.Group, items: [MacSettingsTab.Item])] {
        var result: [(group: MacSettingsTab.Group, items: [MacSettingsTab.Item])] = []
        for item in items {
            if result.last?.group == item.group {
                result[result.count - 1].items.append(item)
            } else {
                result.append((item.group, [item]))
            }
        }
        return result
    }

    /// 페이지는 고르고(마지막 페이지로 저장), 시트 항목은 키보드 자리만 옮긴다. `openingSheet`이면 시트를 띄운다
    private func choose(_ tab: MacSettingsTab, openingSheet: Bool) {
        if tab.opensSheet {
            cursor = tab
            if openingSheet { SettingsRoute.shared.showsAccount = true }
        } else {
            cursor = nil
            stored = tab.rawValue
        }
    }

    private func move(_ offset: Int) -> KeyPress.Result {
        guard let next = MacSettingsTab.step(from: highlighted, by: offset, in: items) else { return .ignored }
        choose(next, openingSheet: false)
        return .handled
    }

    /// 검색칸에서 ↩: 고른 항목이 결과에 있으면 그것, 없으면 첫 결과를 연다
    private func submitSearch() {
        guard let tab = items.first(where: { $0.tab == highlighted })?.tab ?? items.first?.tab else { return }
        choose(tab, openingSheet: true)
    }

    // MARK: 본문

    private var content: some View {
        let title = MacSettingsTab.all.first { $0.tab == page }?.title ?? ""
        return VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(TFFont.pageTitle)
                .foregroundStyle(TFColor.textPrimary)
                .frame(width: Self.column, height: 28, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.top, 26)
                .accessibilityAddTraits(.isHeader)
            pageBody
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .scrollEdgeFade(TFColor.settingsContent)
    }

    @ViewBuilder
    private var pageBody: some View {
        switch page {
        case .keyboardShortcuts:
            HotKeyPane()
        case .usage:
            signedInOnly { UsageCreditsPane() }
        case .connections:
            signedInOnly { ConnectionsView().modifier(SettingsFormPage()) }
        case .ai:
            signedInOnly { ConsentSettingsView() }
        case .account:
            // 시트 항목이라 페이지가 되지 않는다 (`MacSettingsTab.page(stored:)`)
            EmptyView()
        }
    }

    @ViewBuilder
    private func signedInOnly<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if case .signedIn = session.state {
            content()
        } else if Self.isSample {
            content()
        } else {
            ScrollableSignIn()
        }
    }

    /// 견본 모드(`-TFSampleData`)는 로그인 없이 로그인한 화면을 보여 준다 (iPhone `RootView`와 같은 규칙)
    private static var isSample: Bool {
        #if DEBUG
        SampleData.isEnabled
        #else
        false
        #endif
    }
}

/// iPhone과 같이 쓰는 Form 화면을 본문 열에 맞춘다: 바탕은 settings/content, 그룹 폭은 468.
/// grouped Form은 스스로 좌우 20을 더 들이므로 열 여백 44에서 20을 뺀다.
private struct SettingsFormPage: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .contentMargins(.horizontal, MacSettingsView.columnInset - 20, for: .scrollContent)
            .contentMargins(.top, 2, for: .scrollContent)
            .contentMargins(.bottom, 12, for: .scrollContent)
    }
}

/// 설정 창 틀 (Figma S1): 제목 글자 없이 신호등만, 내용이 제목 막대 아래까지 그린다 (창 바탕 settings/window).
/// 제목 막대 높이를 알려 준다: 창은 내용 높이에 이 높이를 더해 크기를 정하므로 내용에서 뺀다.
private struct SettingsWindowChrome: NSViewRepresentable {
    @Binding var titlebarHeight: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = ChromeView()
        view.onTitlebarHeight = { height in
            Task { @MainActor in
                if titlebarHeight != height { titlebarHeight = height }
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ChromeView: NSView {
        var onTitlebarHeight: ((CGFloat) -> Void)?
        private var resizeObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
            resizeObserver = nil
            guard let window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.styleMask.insert(.fullSizeContentView)
            report(window)
            // 창이 크기를 잡기 전에 붙으면 (대체 창) 잴 수 없어서, 창 크기가 바뀔 때마다 다시 잰다
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.report(window) }
            }
        }

        private func report(_ window: NSWindow) {
            let height = window.frame.height - window.contentLayoutRect.height
            if height > 0 { onTitlebarHeight?(height) }
        }
    }
}

/// 로그인 화면이 칸보다 길면 스크롤한다 (이메일 칸 · 오류 줄이 붙으면 480 창 · 시트를 넘는다). 짧으면 가운데
private struct ScrollableSignIn: View {
    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                SignInView()
                    .frame(minHeight: proxy.size.height)
            }
        }
    }
}

/// Account ↗: 지금 계정 화면을 설정 창 위 시트로
private struct MacAccountSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            MacAccountPane()
            HStack {
                Spacer()
                QuietButton("Done", size: .large) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(TFSpace.lg)
        }
        .frame(width: 460, height: 420)
        .background(TFColor.settingsContent)
    }
}

/// 계정: 로그인 · 프로필(이름 · 다른 이름) · 로그아웃 · 계정 삭제
private struct MacAccountPane: View {
    @Environment(SessionStore.self) private var session
    @Environment(AccountStore.self) private var account
    @Environment(\.services) private var services
    @State private var name = ""
    @State private var aliases = ""
    @State private var filledFor: UUID?
    @State private var saving = false
    @State private var confirmingDelete = false
    @State private var deleting = false
    @State private var message: String?

    var body: some View {
        switch session.state {
        case .signedIn(let userID, let email):
            form(userID: userID, email: email)
        case .signedOut:
            #if DEBUG
            // 견본 모드(`-TFSampleData`)는 로그인 없이 로그인한 화면 (iPhone `RootView`와 같은 규칙)
            if SampleData.isEnabled {
                form(userID: SampleData.userID, email: nil)
            } else {
                ScrollableSignIn()
            }
            #else
            ScrollableSignIn()
            #endif
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func form(userID: UUID, email: String?) -> some View {
        Form {
            Section {
                TextField("Name", text: $name)
                TextField("Other names", text: $aliases, prompt: Text("Nicknames, English name…"))
                HStack {
                    Spacer()
                    Button("Save") { save() }
                        .disabled(saving || account.profile == nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Profile")
            } footer: {
                Text("Used to find what you promised in meeting notes and messages.")
            }
            Section {
                if let email {
                    LabeledContent(session.signInMethods.accountLabel, value: email)
                }
                HStack {
                    Button("Sign Out") {
                        Task {
                            // 세션이 남아 있을 때 이 기기를 알림에서 뺀다
                            await PushCenter.shared.unregister()
                            await session.signOut()
                        }
                    }
                    Spacer()
                    Button("Delete Account…", role: .destructive) { confirmingDelete = true }
                        .disabled(deleting)
                }
            } footer: {
                // Sign Out은 이 기기의 세션만 끝낸다 (`SessionStore.signOut`, `.local`)
                Text(AccountCopy.signOutScope)
            }
            Section {
                LegalLinksRow()
            }
        }
        .formStyle(.grouped)
        .task(id: userID) {
            await account.load()
            // 계정이 바뀌어 취소됐으면 전 계정으로 칸을 채우지 않는다 (읽기는 취소돼도 끝까지 돈다)
            guard !Task.isCancelled else { return }
            fill(for: userID)
        }
        .onChange(of: account.profile) { fill(for: userID) }
        .confirmationDialog("Delete your account?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Account", role: .destructive) { deleteAccount() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your sources, tasks, and history are deleted right away. This can't be undone.")
        }
        .messageAlert($message)
    }

    private func fill(for userID: UUID) {
        guard filledFor != userID, let profile = account.profile else { return }
        filledFor = userID
        name = profile.displayName ?? ""
        aliases = profile.aliases.joined(separator: ", ")
    }

    private func save() {
        saving = true
        Task {
            if !(await account.saveProfile(name: name, aliases: Profile.aliases(fromList: aliases))) {
                message = account.message
                account.message = nil
            }
            saving = false
        }
    }

    private func deleteAccount() {
        guard let services else { return }
        deleting = true
        Task {
            message = await AccountDeletion.delete(services: services, session: session)
            deleting = false
        }
    }
}

/// 런처 단축키 (기본 ⌥Space). 다른 앱이 이미 쓰는 조합이면 이전 것을 그대로 둔다.
private struct HotKeyPane: View {
    @State private var shortcut = HotKeyShortcut.load()
    @State private var recording = false
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TFSpace.sm) {
                SettingsCard {
                    SettingsRow("Open launcher") {
                        HStack(spacing: TFSpace.sm) {
                            Keycap(recording ? "…" : shortcut.displayLabel)
                            QuietButton(recording ? "Press a shortcut" : "Change") { recording ? stop() : record() }
                            if shortcut != .default {
                                QuietButton("Reset") {
                                    MacAppDelegate.shared?.resetHotKey()
                                    shortcut = .default
                                }
                            }
                        }
                    }
                }
                if let message {
                    Text(message)
                        .font(TFFont.meta)
                        .foregroundStyle(TFColor.statusOverdue)
                }
            }
            .frame(width: MacSettingsView.column, alignment: .leading)
            .padding(.top, 20)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .onDisappear { stop() }
    }

    private func record() {
        message = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard recording else { return false }
                if event.keyCode == 53 {  // esc: 그만
                    stop()
                    return true
                }
                guard let candidate = HotKeyShortcut(event: event), candidate.isValid else {
                    message = "Include ⌘, ⌥, or ⌃."
                    return true
                }
                if MacAppDelegate.shared?.changeHotKey(to: candidate) == true {
                    shortcut = candidate
                } else {
                    message = "That shortcut is in use. Try another."
                }
                stop()
                return true
            }
            return consumed ? nil : event
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
#endif
