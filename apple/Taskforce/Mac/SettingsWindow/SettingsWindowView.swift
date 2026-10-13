#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

/// Settings 장면 · 대체 창의 뿌리. `TF_EDGE_SHELL`이 꺼져 있으면(기본 · Release 전부) 기존 사이드바 창 그대로다
struct MacSettingsRoot: View {
    let kind: MacSettingsRootKind

    init(kind: MacSettingsRootKind = .current) {
        self.kind = kind
    }

    var body: some View {
        switch kind {
        case .legacy: MacSettingsView()
        case .window: SettingsWindowView()
        }
    }
}

/// 0.2.0 설정 창 (디자인 `SettingsWindow`): 폭 560, 높이는 탭 내용을 따라가다 640에서 멈추고 본문이 스크롤한다.
/// 위에서부터 제목 막대(시스템 신호등 + 탭 이름 또는 연 상세) · 탭 줄(아이콘 위 · 이름 아래) · 본문.
/// 마지막 탭은 `settings.tab`에 기억하고(기존 창과 같은 키, `SettingsWindowTab.tab(stored:)`), 창 밖에서 열면 상세 · 확인을 닫는다
struct SettingsWindowView: View {
    @Environment(SessionStore.self) private var session
    @Environment(RunStore.self) private var runs
    @AppStorage(SettingsOpener.tabKey) private var stored: String?
    /// 신호등이 있는 제목 막대 높이 (macOS 버전마다 다르다). 창에 붙으면 그 창에서 다시 잰다 (`SettingsWindowChrome`)
    @State private var titlebarHeight = NSWindow.frameRect(forContentRect: .zero, styleMask: [.titled, .closable]).height
    /// 본문 내용의 높이 (창 높이를 이것에 맞춘다)
    @State private var contentHeight: CGFloat = 360

    static let width: CGFloat = 560
    static let maxHeight: CGFloat = 640
    /// 탭 한 칸 (위 6 · 아이콘 20 · 3 · 이름 14 · 아래 5) + 줄 아래 8
    static let tabBarHeight: CGFloat = 48 + 8

    private var model: SettingsWindowModel { .shared }
    private var tab: SettingsWindowTab { SettingsWindowTab.tab(stored: stored) }
    private var access: SettingsWindowAccess { SettingsWindowSession.access(session) }
    private var detail: SettingsWindowDetail? { access == .signedIn ? model.detail(on: tab) : nil }
    private var title: String { detail?.title ?? tab.title }
    /// 본문이 쓸 수 있는 높이: 창 640 - 제목 막대 - 탭 줄 - 구분선
    private var maxContentHeight: CGFloat { Self.maxHeight - titlebarHeight - Self.tabBarHeight - 1 }

    var body: some View {
        let route = SettingsRoute.shared
        VStack(spacing: 0) {
            tabBar
            Rectangle()
                .fill(TFColor.borderDefault)
                .frame(height: 1)
                .accessibilityHidden(true)
            content
        }
        .frame(width: Self.width)
        // 연결 흐름(읽는 것 확인 · 동의 화면 · 이어서 연결)은 본문 밖에 둔다: 탭 · 상세를 옮겨 본문을 새로 만들어도 동의 화면이 닫히지 않게
        .modifier(ConnectionFlow(active: tab == .connections && access == .signedIn))
        // 창 제목은 시스템 제목 자리(신호등 줄)에 그린다: 제목 막대는 내용 위에 겹쳐 있고 시스템 글자는 숨긴다
        .overlay(alignment: .top) {
            Text(title)
                .font(TFFont.footnoteEmphasis)
                .foregroundStyle(TFColor.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 76)
                .frame(maxWidth: .infinity)
                .frame(height: titlebarHeight)
                .offset(y: -titlebarHeight)
                .allowsHitTesting(false)
                .accessibilityAddTraits(.isHeader)
        }
        .background(TFColor.bgSurface.ignoresSafeArea())
        .background(SettingsWindowChrome(titlebarHeight: $titlebarHeight))
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .navigationTitle(title)
        // 창 밖에서 열면 (More 메뉴 · 메뉴 막대 · 알림) 탭 첫 화면으로: 상세 · 확인을 닫고 실행 가능 여부를 다시 읽는다
        // 창을 닫으면 상세 · 열린 확인도 닫는다 (다시 열 때 "Delete your account?"가 남지 않게)
        .onDisappear { model.close() }
        .onChange(of: route.openCount) {
            model.close()
            guard case .signedIn = session.state else { return }
            Task { await runs.loadCredits() }
        }
        // Execution › Run with AI: 로그인한 계정마다 credits(200 · 404)를 읽는다
        .task(id: SettingsWindowSession.signedInUserID(session)) {
            guard SettingsWindowSession.signedInUserID(session) != nil else { return }
            await runs.loadCredits()
        }
    }

    // MARK: 탭 줄

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(SettingsWindowTab.allCases) { item in
                SettingsTabButton(tab: item, selected: item == tab) {
                    guard item != tab || detail != nil else { return }
                    stored = item.storedValue
                    model.close()
                }
            }
        }
        .padding(.horizontal, TFSpace.md)
        .padding(.bottom, TFSpace.sm)
        .frame(maxWidth: .infinity, minHeight: Self.tabBarHeight, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings")
    }

    // MARK: 본문

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsWindowLayout.topicGap) {
                if let detail {
                    SettingsBackLink(title: detail.backTitle(tab: tab)) { model.back() }
                    SettingsDetailView(detail: detail)
                } else {
                    ForEach(tab.sections(access)) { section in
                        SettingsSectionView(section: section)
                    }
                }
            }
            .padding(EdgeInsets(top: 20, leading: 20, bottom: 24, trailing: 20))
            .frame(width: Self.width, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(contentHeight, maxContentHeight))
        // 탭 · 상세를 옮기면 맨 위에서
        .id(ScrollIdentity(tab: tab, detail: detail))
    }

    private struct ScrollIdentity: Hashable {
        let tab: SettingsWindowTab
        let detail: SettingsWindowDetail?
    }
}

enum SettingsWindowLayout {
    /// 주제 사이 (디자인 `.tf-window-body` gap)
    static let topicGap: CGFloat = 24
}

/// 로그인 상태 읽기. 견본(`-TFSampleData`)은 로그인 없이 로그인한 화면을 보여 준다 (기존 설정 창 · iPhone `RootView`와 같은 규칙)
@MainActor
enum SettingsWindowSession {
    static var isSample: Bool {
        #if DEBUG
        SampleData.isEnabled
        #else
        false
        #endif
    }

    static func access(_ session: SessionStore) -> SettingsWindowAccess {
        switch session.state {
        case .signedIn: .signedIn
        case .loading: isSample ? .signedIn : .loading
        case .signedOut: isSample ? .signedIn : .signedOut
        }
    }

    /// 실제로 로그인한 사용자 (견본은 nil: 서버를 부르지 않는다)
    static func signedInUserID(_ session: SessionStore) -> UUID? {
        if case .signedIn(let userID, _) = session.state { userID } else { nil }
    }

    /// 프로필 · 계정 화면의 사용자 (견본은 견본 사용자)
    static func accountUserID(_ session: SessionStore) -> UUID? {
        if let userID = signedInUserID(session) { return userID }
        #if DEBUG
        if isSample { return SampleData.userID }
        #endif
        return nil
    }

    static func email(_ session: SessionStore) -> String? {
        if case .signedIn(_, let email) = session.state { email } else { nil }
    }
}

/// 탭 한 칸: 아이콘 20 위 · 이름 11 아래, 폭 72부터. 고른 탭은 `bg/selected` 면 (청색 아님)
private struct SettingsTabButton: View {
    let tab: SettingsWindowTab
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                tab.icon.image(size: 20)
                Text(tab.title)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .frame(height: 14)
            }
            .foregroundStyle(selected || hovering ? TFColor.textPrimary : TFColor.textSecondary)
            .padding(EdgeInsets(top: 6, leading: 8, bottom: 5, trailing: 8))
            .frame(minWidth: 72)
            .background(selected ? TFColor.bgSelected : .clear, in: RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(TFMotion.ease(TFMotion.hoverFade), value: hovering)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 상세의 Back: 꺾쇠 14 + 탭 이름 (디자인 `.tf-back`). 다음 것과는 12 (본문 간격 24에서 -12)
private struct SettingsBackLink: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                TFIcon.back.image(size: 14)
                Text(title)
                    .font(TFFont.footnote)
            }
            .foregroundStyle(hovering ? TFColor.textPrimary : TFColor.textSecondary)
            .padding(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 8))
            .background(hovering ? TFColor.bgSelected : .clear, in: RoundedRectangle(cornerRadius: TFRadius.sm, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.top, -6)
        .padding(.leading, -4)
        .accessibilityLabel("Back to \(title)")
    }
}

/// 주제 하나를 그린다 (`SettingsWindowTab.sections`의 순서대로)
private struct SettingsSectionView: View {
    let section: SettingsWindowSection

    var body: some View {
        switch section {
        case .profile: SettingsProfileSection()
        case .signIn: SettingsSignInSection()
        case .remembered: SettingsRememberedSection()
        case .deleteAccount: SettingsDeleteAccountSection()
        case .about: SettingsAboutSection()
        case .legal: SettingsLegalLinks()
        case .aiProcessing: SettingsAIProcessingSection()
        case .sources: SettingsSourcesSection()
        case .moreServices: SettingsMoreServicesSection()
        case .runWithAI: SettingsRunWithAISection()
        case .notifications: SettingsNotificationsSection()
        case .launcher: SettingsLauncherShortcutsSection()
        case .panelKeys: SettingsPanelKeysSection()
        case .signInRequired: SettingsSignInPanel()
        }
    }
}

/// 탭 안에서 연 상세
private struct SettingsDetailView: View {
    let detail: SettingsWindowDetail

    var body: some View {
        switch detail {
        case .privacy: SettingsPrivacyDetail()
        case .connection(let provider): SettingsConnectionDetail(provider: provider)
        case .remembered: SettingsRememberedList()
        case .memory(let id): SettingsMemoryDetail(id: id)
        }
    }
}
#endif
