#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

/// Mac 설정 창 (Figma S1 239:1614 · S7 269:5822): 760×480, 왼쪽 사이드바 196 + 가운데 본문 열 468.
/// 연결 · 동의 화면은 iPhone과 같은 것을 쓰고, Account도 본문 페이지로 표시한다.
struct MacSettingsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(RunStore.self) private var runs
    @AppStorage(SettingsOpener.tabKey) private var stored: String?
    @State private var query = ""
    /// 키보드는 검색칸에서 시작한다: 글자는 거르고 ↑↓는 항목을 옮기고 ↩는 연다 (⌘F로 돌아온다)
    @FocusState private var searchFocused: Bool
    /// 신호등이 있는 제목 막대 높이 (macOS 버전마다 다르다). 처음은 보통 창의 값, 창에 붙으면 그 창에서 다시 잰다
    @State private var titlebarHeight = NSWindow.frameRect(forContentRect: .zero, styleMask: [.titled, .closable]).height

    /// Figma S1: 창 760×480, 사이드바 196(오른쪽 선 포함), 본문 열 468
    static let windowSize = CGSize(width: 760, height: 480)
    static let sidebarWidth: CGFloat = 196
    static let column: CGFloat = 468
    static let contentWidth = windowSize.width - 2 * TFSpace.xs - sidebarWidth
    /// 본문 칸(창 - 안쪽 4 × 2 - 사이드바 = 556) 가운데 열의 좌우 여백 44
    static let columnInset = (windowSize.width - 2 * TFSpace.xs - sidebarWidth - column) / 2

    private var page: MacSettingsTab { MacSettingsTab.page(stored: stored, execution: execution, signedIn: signedInUserID != nil) }
    private var highlighted: MacSettingsTab { page }
    /// Every signed-in beta account can see USD usage, independently of execution credits.
    private var items: [MacSettingsTab.Item] {
        MacSettingsTab.sidebar(matching: query, executionAvailable: execution == .available || page == .usage, signedIn: signedInUserID != nil)
    }

    /// 실행을 쓸 수 있는지 (`MacSettingsTab.Execution(signedIn:credits:)`). 견본은 로그인한 것으로 본다
    private var execution: MacSettingsTab.Execution {
        let signedIn: Bool? = switch session.state {
        case .signedIn: true
        case .loading: Self.isSample ? true : nil
        case .signedOut: Self.isSample
        }
        return MacSettingsTab.Execution(signedIn: signedIn, credits: runs.credits)
    }

    private var signedInUserID: UUID? {
        if case .signedIn(let userID, _) = session.state { userID } else { nil }
    }

    var body: some View {
        let route = SettingsRoute.shared
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
        // 창 밖에서 열면 (메뉴 · 런처 · 알림) 지난 검색어 · 키보드 자리를 지운다: 연 페이지가 걸러져 숨지 않게.
        // 설정 창은 닫아도 남아 있어 상태가 이어진다
        .onChange(of: route.openCount) {
            query = ""
            // 다시 열 때마다 실행을 쓸 수 있는지 · 멈춘 run을 다시 본다 (지급 · 켜기 뒤 다시 열면 숫자 · 카드가 바로 바뀌게.
            // 설정 창은 닫아도 남아 있어 Usage 페이지의 `.task`가 다시 돌지 않는다)
            guard signedInUserID != nil else { return }
            Task {
                await runs.loadCredits()
                await runs.refreshActive()
            }
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
            choose(item.tab)
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
            }
            .padding(.horizontal, TFSpace.sm)
            .frame(height: 28)
            .background(isHighlighted ? TFColor.settingsFill : .clear, in: RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
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

    /// 모든 항목은 같은 본문에서 열고 마지막 페이지로 저장한다.
    private func choose(_ tab: MacSettingsTab) {
        stored = tab.rawValue
    }

    private func move(_ offset: Int) -> KeyPress.Result {
        guard let next = MacSettingsTab.step(from: highlighted, by: offset, in: items) else { return .ignored }
        choose(next)
        return .handled
    }

    /// 검색칸에서 ↩: 고른 항목이 결과에 있으면 그것, 없으면 첫 결과를 연다
    private func submitSearch() {
        guard let tab = items.first(where: { $0.tab == highlighted })?.tab ?? items.first?.tab else { return }
        choose(tab)
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
        // Bound each page before HStack measures it; long text and scroll content cannot expand the shell.
        .frame(width: Self.contentWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .clipped()
        .scrollEdgeFade(TFColor.settingsContent)
    }

    @ViewBuilder
    private var pageBody: some View {
        switch page {
        case .keyboardShortcuts:
            KeyboardShortcutsPane()
        case .taskList:
            SectionDisplaySettingsPane()
        case .usage:
            signedInOnly { UsageCreditsPane().id(signedInUserID) }
        case .about:
            AboutSettingsPane()
        case .connections:
            signedInOnly { ConnectionsView().modifier(SettingsFormPage()) }
        case .ai:
            signedInOnly { ConsentSettingsView() }
        case .account:
            MacAccountPane().modifier(SettingsFormPage())
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

/// Immutable metadata embedded in the app bundle. Release builds set the channel, source revision,
/// and UTC build time in the archive command; local builds keep explicit development fallbacks.
struct AboutBuildInfo: Equatable {
    static let releaseChannelKey = "TaskforceReleaseChannel"
    static let sourceCommitKey = "TaskforceSourceCommit"
    static let buildTimeUTCKey = "TaskforceBuildTimeUTC"

    let version: String
    let build: String
    let releaseChannel: String
    let sourceCommit: String
    let buildTimeUTC: String

    static var current: AboutBuildInfo {
        AboutBuildInfo(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    init(infoDictionary: [String: Any]) {
        version = Self.value("CFBundleShortVersionString", in: infoDictionary, fallback: "Not available")
        build = Self.value("CFBundleVersion", in: infoDictionary, fallback: "Not available")
        releaseChannel = Self.value(Self.releaseChannelKey, in: infoDictionary, fallback: "Development")
        sourceCommit = Self.value(Self.sourceCommitKey, in: infoDictionary, fallback: "Not available")
        buildTimeUTC = Self.value(Self.buildTimeUTCKey, in: infoDictionary, fallback: "Not available")
    }

    var copyText: String {
        [
            "Taskforce",
            "Version: \(version)",
            "Build: \(build)",
            "Release channel: \(releaseChannel)",
            "Source commit: \(sourceCommit)",
            "Built (UTC): \(buildTimeUTC)",
        ].joined(separator: "\n")
    }

    @MainActor
    func copy(to pasteboard: NSPasteboard) {
        Clipboard.copy(copyText, to: pasteboard)
    }

    private static func value(_ key: String, in dictionary: [String: Any], fallback: String) -> String {
        guard let raw = dictionary[key] as? String else { return fallback }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("$("), value != "NotAvailable" else { return fallback }
        return value
    }
}

/// Build details are useful in bug reports; they stay separate from account and connection settings.
struct AboutSettingsPane: View {
    private let buildInfo: AboutBuildInfo
    @State private var copied = false

    init(buildInfo: AboutBuildInfo = .current) {
        self.buildInfo = buildInfo
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TFSpace.lg) {
                SettingsCard {
                    HStack(spacing: TFSpace.md) {
                        TFImage.logoMark
                            .resizable()
                            .scaledToFit()
                            .frame(width: 42, height: 30)
                            .accessibilityHidden(true)
                        Text("Taskforce")
                            .font(TFFont.footnoteEmphasis)
                            .foregroundStyle(TFColor.textPrimary)
                        Spacer(minLength: 0)
                    }
                    .padding(TFSpace.lg)
                }

                VStack(alignment: .leading, spacing: TFSpace.xs) {
                    Text("Build info")
                        .font(TFFont.footnoteEmphasis)
                        .foregroundStyle(TFColor.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    SettingsCard {
                        valueRow("Version", value: buildInfo.version)
                        SettingsDivider()
                        valueRow("Build", value: buildInfo.build)
                        SettingsDivider()
                        valueRow("Release channel", value: buildInfo.releaseChannel)
                        SettingsDivider()
                        valueRow("Source commit", value: buildInfo.sourceCommit, monospaced: true)
                        SettingsDivider()
                        valueRow("Built (UTC)", value: buildInfo.buildTimeUTC, monospaced: true)
                        SettingsDivider()
                        SettingsRow("Copy build info", subtitle: "Useful when reporting a bug") {
                            QuietButton(copied ? "Copied" : "Copy") {
                                buildInfo.copy(to: .general)
                                copied = true
                            }
                        }
                    }
                }

                HStack(spacing: TFSpace.sm) {
                    Link("Website", destination: Self.websiteURL)
                    Text("·").foregroundStyle(TFColor.textSecondary)
                    Link("GitHub", destination: Self.githubURL)
                }
                .font(TFFont.footnote)
                .tint(TFColor.textSecondary)
            }
            .frame(width: MacSettingsView.column, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.top, TFSpace.md)
            .padding(.bottom, TFSpace.md)
        }
        .contentMargins(.top, 2, for: .scrollContent)
        .contentMargins(.bottom, 12, for: .scrollContent)
    }

    private func valueRow(_ title: String, value: String, monospaced: Bool = false) -> some View {
        SettingsRow(title) {
            Text(value)
                .font(monospaced ? .system(size: 11, design: .monospaced) : TFFont.footnote)
                .foregroundStyle(TFColor.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 255, alignment: .trailing)
                .textSelection(.enabled)
                .help(value)
        }
    }

    static let websiteURL = URL(string: "https://www.taskforcelabs.dev")!
    static let githubURL = URL(string: "https://github.com/songch9511/taskforce-new")!
}

/// Local per-section maximums for the launcher. The task list remains complete by default.
struct SectionDisplaySettingsPane: View {
    @State private var preferences: SectionDisplayPreferences

    init(preferences: SectionDisplayPreferences = .load()) {
        _preferences = State(initialValue: preferences)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TFSpace.lg) {
                Text("All shows every task. Choose a number to show fewer rows and add Show More when needed.")
                    .font(TFFont.footnote)
                    .foregroundStyle(TFColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: TFSpace.xs) {
                    Text("Sections")
                        .font(TFFont.footnoteEmphasis)
                        .foregroundStyle(TFColor.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    SettingsCard {
                        picker("Review", selection: $preferences.review)
                        SettingsDivider()
                        picker("In Progress", selection: $preferences.inProgress)
                        SettingsDivider()
                        picker("To Do", selection: $preferences.toDo)
                        SettingsDivider()
                        picker("Done Today", selection: $preferences.doneToday)
                    }
                }
            }
            .frame(width: MacSettingsView.column, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.top, TFSpace.md)
            .padding(.bottom, TFSpace.md)
        }
        .contentMargins(.top, 2, for: .scrollContent)
        .contentMargins(.bottom, 12, for: .scrollContent)
        .onChange(of: preferences) { _, value in
            value.save()
            MacAppDelegate.shared?.launcher?.model.applySectionDisplayPreferences(value)
        }
    }

    private func picker(_ title: String, selection: Binding<SectionDisplayLimit>) -> some View {
        SettingsRow(title) {
            Picker(title, selection: selection) {
                ForEach(SectionDisplayLimit.allCases) { limit in
                    Text(limit.displayName).tag(limit)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityLabel(title)
            .fixedSize()
        }
    }
}

extension MacSettingsTab.Execution {
    /// 로그인 상태(`nil` = 앱을 막 열어 세션을 읽는 중)와 `RunStore.credits`로: 로그아웃이면 쓸 수 없음,
    /// 세션 · credits를 아직 모르면(처음 · 전송 오류) 모름 — 저장된 Usage 페이지를 그사이 Connections로 떨어뜨리지 않는다
    init(signedIn: Bool?, credits: RunStore.Credits) {
        switch (signedIn, credits) {
        case (false?, _): self = .unavailable
        case (nil, _), (true?, .unknown): self = .unknown
        case (true?, .unavailable): self = .unavailable
        case (true?, .available): self = .available
        }
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
/// 제목 막대 높이를 알려 준다: 창은 내용 높이에 이 높이를 더해 크기를 정하므로 내용에서 뺀다. 0.2.0 설정 창(`SettingsWindowView`)도 같은 틀을 쓴다.
struct SettingsWindowChrome: NSViewRepresentable {
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
            MacBillingSection(userID: userID).id(userID)
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
                Link("Contact", destination: AccountDeletion.contactURL)
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
            Text(AccountDeletion.confirmationMessage)
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

/// Account › Plan & usage (옛 창, OA 결제 PR-C): Kit의 `PlanSummaryState`(0.2.0 창과 같은 규칙 · 같은 문구)를 SwiftUI Form 줄로 그린다.
/// 결제 화면은 그리지 않는다: checkout · 포털 · 결제 수단은 브라우저(Lemon Squeezy)로 연다. 가격 · 날짜 · 토큰은 서버 값이다.
/// Release는 L5까지 이 옛 창이라 여기서도 팔고 키를 받는다 (`EdgeSurfaces.release.settingsWindow == false`)
struct MacBillingSection: View {
    let userID: UUID
    /// 시험이 가짜 서버 · 가짜 계정 길 · 만든 저장소를 넣는 자리 (Release 경로는 모두 nil: 저장소는 이 화면이 만들고 서버는 `services.api`, 계정은 세션)
    var gatewayOverride: (any PlanSummaryGateway)?
    var currentAccountOverride: (@MainActor () -> UUID?)?
    @Environment(\.services) private var services
    /// 세션이 없으면(시험의 작은 호스트) 계정이 없는 것으로 본다. 실제 설정 창에는 늘 있다
    @Environment(SessionStore.self) private var session: SessionStore?
    @State private var store: PlanSummaryStore

    init(
        userID: UUID, store: PlanSummaryStore = PlanSummaryStore(), gatewayOverride: (any PlanSummaryGateway)? = nil,
        currentAccountOverride: (@MainActor () -> UUID?)? = nil
    ) {
        self.userID = userID
        self.gatewayOverride = gatewayOverride
        self.currentAccountOverride = currentAccountOverride
        _store = State(initialValue: store)
    }

    var body: some View {
        // 이 화면은 계정마다 하나다(`.id(userID)`): 화면이 사라지면(로그아웃 · 계정 전환 · 창 닫기) 저장소도 무효화돼 늦은 응답이 이전 계정의 결제 주소를 열지 못한다
        MacBillingSectionBody(
            store: store, userID: userID, gateway: gatewayOverride ?? PlanGateways.current(services),
            currentAccount: currentAccountOverride ?? PlanAccount.current(session), invalidatesOnDisappear: true
        )
    }
}

/// 알맹이: 시험은 가짜 길 · 가짜 계정으로 이것을 바로 붙인다
struct MacBillingSectionBody: View {
    let store: PlanSummaryStore
    let userID: UUID?
    let gateway: (any PlanSummaryGateway)?
    var currentAccount: (@MainActor () -> UUID?)?
    var invalidatesOnDisappear = false
    @State private var keyHandle = SecureFieldSmHandle()

    var body: some View {
        LegacyPlanRows(
            state: store.state, keyHandle: keyHandle,
            onAction: { action in Task { await store.perform(action) } },
            onSubmitKey: { key in Task { await store.saveKey(key) } }
        )
        .modifier(PlanSummaryLifecycle(store: store, userID: userID, gateway: gateway, currentAccount: currentAccount, invalidatesOnDisappear: invalidatesOnDisappear))
    }
}

/// Form 줄: Notice 하나(있으면) + 절들 (머리 "Plan & usage"). 규칙이 정한 값을 그대로 그리고 동작은 저장소로 보낸다.
/// 버튼은 한 번에 하나만 눌린다 (`state.isBusy`). 색은 더하지 않는다: 실패 줄은 조용한 보조 색, 굵은 말은 Missing · Revoked뿐
struct LegacyPlanRows: View {
    let state: PlanSummaryState
    let keyHandle: SecureFieldSmHandle
    let onAction: (PlanSummaryState.Action) -> Void
    let onSubmitKey: (SecretBox) -> Void

    var body: some View {
        Group {
            if let notice = state.notice {
                Section { LegacyPlanNotice(notice: notice, locked: state.isBusy, onAction: onAction) }
            }
            ForEach(state.sections) { section in
                Section {
                    if let empty = section.empty {
                        Text(empty).foregroundStyle(.secondary)
                    } else {
                        ForEach(section.rows) { row in
                            LegacyPlanRow(row: row, locked: state.isBusy, keyHandle: keyHandle, onAction: onAction, onSubmitKey: onSubmitKey)
                        }
                    }
                } header: {
                    if let title = section.title { Text(title) }
                } footer: {
                    if let footnote = section.footnote { PlanSummaryFootnoteView(footnote: footnote) }
                }
            }
        }
    }
}

private struct LegacyPlanNotice: View {
    let notice: PlanSummaryState.Notice
    let locked: Bool
    let onAction: (PlanSummaryState.Action) -> Void

    private var symbol: String {
        switch notice.icon {
        case .warning: "exclamationmark.triangle"
        case .clock: "clock"
        case .check: "checkmark.circle"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.title3).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(notice.title).fontWeight(.semibold)
                if let message = notice.message { Text(message).foregroundStyle(.secondary) }
                if let button = notice.button {
                    LegacyPlanButton(button: button, locked: locked, onAction: onAction).padding(.top, 4)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct LegacyPlanButton: View {
    let button: PlanSummaryState.Button
    let locked: Bool
    var name: String?
    let onAction: (PlanSummaryState.Action) -> Void

    init(button: PlanSummaryState.Button, locked: Bool, name: String? = nil, onAction: @escaping (PlanSummaryState.Action) -> Void) {
        self.button = button
        self.locked = locked
        self.name = name
        self.onAction = onAction
    }

    var body: some View {
        let base = Button {
            guard !button.busy else { return }
            onAction(button.action)
        } label: {
            HStack(spacing: 6) {
                if button.busy { ProgressView().controlSize(.small) }
                Text(button.title)
            }
        }
        .accessibilityLabel(name ?? button.title)
        .disabled(locked && !button.busy)
        if button.prominent {
            base.buttonStyle(.borderedProminent)
        } else {
            base.buttonStyle(.bordered)
        }
    }
}

/// 제자리 확인 (승인 규칙: Cancel이 먼저다): Cancel이 앞에 서고 처음 포커스를 받는다. ↩로 확인되는 기본 동작 버튼은 없다 (확인은 눌러야만 한다)
struct LegacyPlanConfirm: View {
    let confirm: PlanSummaryState.Confirm
    let onAction: (PlanSummaryState.Action) -> Void
    @FocusState private var cancelFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(confirm.title).fontWeight(.semibold)
            Text(confirm.detail).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(PlanCopy.cancel) { onAction(confirm.cancel) }
                    .keyboardShortcut(.cancelAction)
                    .focused($cancelFocused)
                    .disabled(confirm.busy)
                Button(confirm.confirmTitle) { onAction(confirm.confirm) }
                    .buttonStyle(.borderedProminent)
                    .disabled(confirm.busy)
                if confirm.busy { ProgressView().controlSize(.small) }
            }
        }
        .defaultFocus($cancelFocused, true)
        .onAppear { cancelFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(confirm.title)
    }
}

private struct LegacyPlanRow: View {
    let row: PlanSummaryState.Row
    let locked: Bool
    let keyHandle: SecureFieldSmHandle
    let onAction: (PlanSummaryState.Action) -> Void
    let onSubmitKey: (SecretBox) -> Void

    /// 라벨 + 보조 글 (줄마다 조용한 보조 색 한 줄)
    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.label)
            ForEach(Array(row.detail.enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    var body: some View {
        switch row.control {
        case .none:
            label
        case .value(let value, let bold):
            LabeledContent {
                Text(value).fontWeight(bold ? .semibold : .regular).foregroundStyle(bold ? .primary : .secondary).lineLimit(1).truncationMode(.tail)
            } label: { label }
        case .button(let button):
            LabeledContent {
                LegacyPlanButton(button: button, locked: locked, name: "\(button.title) \(row.label)", onAction: onAction)
            } label: { label }
        case .opens(let action):
            Button { onAction(action) } label: {
                LabeledContent {
                    Image(systemName: "arrow.up.right").foregroundStyle(.secondary).accessibilityHidden(true)
                } label: { label }
            }
            .buttonStyle(.plain)
            .disabled(locked)
            .accessibilityHint("Opens in browser")
        case .confirm(let confirm):
            LegacyPlanConfirm(confirm: confirm, onAction: onAction)
        case .keyField(let save):
            LabeledContent {
                HStack(spacing: 8) {
                    SecureFieldSm(label: PlanCopy.keyFieldName, placeholder: PlanCopy.keyPlaceholder, handle: keyHandle, onSubmit: onSubmitKey)
                    LegacyPlanButton(button: save, locked: locked, name: "\(save.title) \(row.label)", onAction: { _ in keyHandle.submit() })
                }
            } label: { label }
        }
    }
}

#endif
