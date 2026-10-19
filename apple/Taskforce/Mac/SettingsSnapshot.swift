#if os(macOS) && DEBUG
import AppKit
import SwiftUI
import Auth
import TaskforceKit

/// 설정 창 확인용 (Debug 빌드): `--show-settings`로 실행하면 설정 창을 연다. `-TFSampleData -TFSnapshot <폴더>`를 더하면
/// 사이드바의 보이는 항목마다 Light · Dark PNG(`mac-settings-<항목>-light.png` · `-dark.png`)를 남기고 끝낸다.
/// Account도 설정 본문을 담는다. Usage & Credits(`-TFSampleCredits`일 때 보임) · Privacy & AI Data는 끝까지 스크롤한 모습(`-end`)도,
/// 동의 화면(460×440 시트)은 처음 · 끝(`consent-prompt` · `consent-prompt-end`)을, Usage의 멈춘 카드 ›로 연 런처(`usage-working`)도 담는다.
/// `LauncherSnapshot`처럼 화면 녹화 권한 없이 자기 창만 그린다 (신호등 · 창 그림자는 담기지 않는다).
/// `-TFSettingsSnapshotSignIn`이면 로그인 화면과 Account › Sign-in 절의 모든 상태만 (OA 로그인 5.7, `SignInSnapshot`).
/// `-TF_EDGE_SHELL YES`면 0.2.0 탭 창(`SettingsWindowView`)을 견본 데이터로만 담는다: 탭마다 `mac-settings-window-<탭>-light.png` · `-dark.png`
/// (스크롤이 있으면 `-end`도), 상세 · 트레이 안 확인(`connections-privacy` · `connections-notion` · `connections-notion-disconnect` ·
/// `connections-withdraw` · `account-delete`). 렌더된 견본일 뿐이다: 실제 포인터 · 키보드 · VoiceOver 확인이 아니다.
@MainActor
enum SettingsSnapshot {
    static func runIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--show-settings") else { return }
        let directory = arguments.firstIndex(of: "-TFSnapshot")
            .flatMap { arguments.indices.contains($0 + 1) ? URL(fileURLWithPath: arguments[$0 + 1], isDirectory: true) : nil }
        Task { @MainActor in
            // 메뉴 막대 장면이 openSettings를 넘길 때까지 (`MenuBarLabel`)
            try? await Task.sleep(for: .seconds(1))
            SettingsOpener.open()
            guard let directory else { return }
            if MacSettingsRootKind.current == .window {
                // 실제 계정의 이름 · 이메일을 PNG로 남기지 않는다
                if SampleData.isEnabled {
                    // `-TFSettingsSnapshotAgents`: Your agents의 모든 상태만 (OA Settings › Your agents 5.4)
                    if SettingsAgentsSnapshot.isRequested {
                        await captureAgents(to: directory)
                    } else if SignInSnapshot.isRequested {
                        await captureSignIn(to: directory)
                    } else {
                        await captureWindow(to: directory)
                    }
                }
                NSApplication.shared.terminate(nil)
                return
            }
            let executionAvailable: Bool
            if case .ready(_, let services) = AppRuntime.startup {
                executionAvailable = AppRuntime.runs(services: services).isAvailable
            } else {
                executionAvailable = false
            }
            for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                NSApplication.shared.appearance = NSAppearance(named: appearance)
                for item in MacSettingsTab.sidebar(executionAvailable: executionAvailable) {
                    SettingsOpener.open(item.tab)
                    try? await Task.sleep(for: .seconds(1.5))
                    guard let window = settingsWindow else { continue }
                    capture(window, to: directory.appending(path: "mac-settings-\(fileName(item.tab))-\(name).png"))
                    if item.tab == .usage || item.tab == .ai, scrollToEnd(window) {
                        try? await Task.sleep(for: .seconds(0.5))
                        capture(window, to: directory.appending(path: "mac-settings-\(fileName(item.tab))-end-\(name).png"))
                    }
                    if item.tab == .usage {
                        await captureTaskforceWorking(name: name, to: directory)
                    }
                }
                await captureConsentPrompt(name: name, to: directory)
            }
            NSApplication.shared.terminate(nil)
        }
    }

    /// 0.2.0 탭 창: 다섯 탭 · 상세 · 트레이 안 확인을 Light · Dark로
    private static func captureWindow(to directory: URL) async {
        let model = SettingsWindowModel.shared
        func settle(_ seconds: Double = 1.2) async { try? await Task.sleep(for: .seconds(seconds)) }
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            NSApplication.shared.appearance = NSAppearance(named: appearance)
            func file(_ shot: String) -> URL { directory.appending(path: "mac-settings-window-\(shot)-\(name).png") }
            func shoot(_ shot: String, end: Bool = false) async {
                guard let window = settingsWindow else { return }
                capture(window, to: file(shot))
                guard end, scrollToEnd(window) else { return }
                await settle(0.5)
                capture(window, to: file("\(shot)-end"))
            }
            for tab in SettingsWindowTab.allCases {
                await show(tab)
                await shoot(tab.rawValue, end: true)
            }
            // 창 밖에서 열면 상세 · 확인이 닫힌다 (`SettingsRoute.openCount`): 탭을 연 뒤 상세를 연다
            await show(.connections)
            model.open(.privacy)
            await settle()
            await shoot("connections-privacy", end: true)
            await show(.connections)
            model.open(.connection(.notion))
            await settle()
            await shoot("connections-notion")
            model.confirming = .disconnect(.notion)
            await settle()
            await shoot("connections-notion-disconnect")
            await show(.connections)
            model.confirming = .withdrawConsent
            await settle()
            await shoot("connections-withdraw")
            await show(.account)
            model.confirming = .deleteAccount
            await settle()
            await shoot("account-delete")
            model.close()
            await captureRemembered(model: model, shoot: { name, end in await shoot(name, end: end) }, settle: { await settle($0) })
        }
    }

    /// 로그인 화면과 Account › Sign-in 절의 모든 상태 (OA 로그인 5.7, `-TFSettingsSnapshotSignIn`): 상태마다 `<폴더>/light|dark/<상태>.png`.
    /// 문구는 승인된 앱 문구 그대로다 (DZ 그림 `handoffs/oa-signin-dz`와 대조한다).
    /// 값은 모두 가짜다: 실제 Apple · Google 창 · 서버 · Keychain에 닿지 않는다. 렌더된 견본일 뿐이다: 실제 포인터 · 키보드 · VoiceOver 확인이 아니다
    private static func captureSignIn(to directory: URL) async {
        guard case .ready(let session, _) = AppRuntime.startup else { return }
        let add = SignInAddModel.shared
        func settle(_ seconds: Double = 1.0) async { try? await Task.sleep(for: .seconds(seconds)) }
        let me = UUID()
        func user(_ providers: [String], _ emails: [String: String]) -> SignInMethods {
            let identities = providers.map {
                UserIdentity(id: "sub-\($0)", identityId: UUID(), userId: me, identityData: emails[$0].map { ["email": .string($0)] } ?? [:],
                    provider: $0, createdAt: nil, lastSignInAt: nil, updatedAt: nil)
            }
            return SignInMethods(user: User(id: me, appMetadata: ["provider": .string(providers.first ?? "email"), "providers": .array(providers.map { .string($0) })],
                userMetadata: [:], aud: "authenticated", createdAt: Date(), updatedAt: Date(), identities: identities))
        }
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            NSApplication.shared.appearance = NSAppearance(named: appearance)
            let folder = directory.appending(path: name, directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // 로그인 화면 (로그아웃): 기본 · 오류 한 줄(회색) · 삭제 뒤 Apple 안내
            await session.accountDeleted(note: nil)
            await captureSignInScreen(session: session, to: folder.appending(path: "signin-screen.png"))
            session.reportError(SignInCopy.appleFailed)
            await captureSignInScreen(session: session, to: folder.appending(path: "signin-screen-error.png"))
            await session.accountDeleted(note: SignInCopy.appleRevokeSkipped)
            await captureSignInScreen(session: session, to: folder.appending(path: "signin-screen-note.png"))
            await session.accountDeleted(note: nil)
            // Account › Sign-in 절
            let google = user(["google"], ["google": "daniel@gmail.com"])
            let scenarios: [(String, SignInMethods, String?, SignInMethodRow.Method?, [SignInMethodRow.Method: String])] = [
                ("account-google-add-apple", google, "daniel@gmail.com", nil, [:]),
                ("account-apple-add-google", user(["apple"], ["apple": "relay-x1y2z3@privaterelay.appleid.com"]), "relay-x1y2z3@privaterelay.appleid.com", nil, [:]),
                ("account-both", user(["apple", "google"], ["apple": "relay-x1y2z3@privaterelay.appleid.com", "google": "daniel@gmail.com"]), "daniel@gmail.com", nil, [:]),
                ("account-review-email-only", user(["email"], [:]), "appreview@taskforcelabs.dev", nil, [:]),
                ("account-add-busy", google, "daniel@gmail.com", .apple, [:]),
                ("account-add-error-apple-other-account", google, "daniel@gmail.com", nil, [.apple: SignInCopy.appleBelongsToAnotherAccount]),
                ("account-add-error-google-other-account", user(["apple"], ["apple": "dnl.s@icloud.com"]), "dnl.s@icloud.com", nil, [.google: SignInCopy.googleBelongsToAnotherAccount]),
                ("account-add-error-generic", google, "daniel@gmail.com", nil, [.apple: SignInCopy.addFailed]),
                ("account-unknown-methods-one-row", .unknown, "daniel@gmail.com", nil, [:]),
            ]
            for (shot, methods, email, busy, messages) in scenarios {
                // 창을 먼저 연 뒤 값을 바꾼다: 보이는 화면이 다시 그려진다 (`sampleAccount` · `busy` · `messages`는 관찰된다)
                await show(.account)
                add.sampleAccount = (methods, email)
                add.debugForce(busy: busy, messages: messages)
                await settle(1.0)
                guard let window = settingsWindow else { continue }
                scrollToStart(window)
                await settle(0.5)
                capture(window, to: folder.appending(path: "\(shot).png"))
            }
        }
        add.sampleAccount = nil
        add.debugForce(busy: nil, messages: [:])
        NSApplication.shared.appearance = nil
    }

    /// 로그아웃 상태의 로그인 화면 하나 (설정 창의 로그인 칸과 같은 크기)
    private static func captureSignInScreen(session: SessionStore, to url: URL) async {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 440), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        // 프로그램으로 만든 창은 닫을 때 한 번 더 해제되지 않게 한다 (Swift가 이미 소유한다)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsSignInPanel().environment(session))
        window.appearance = NSApplication.shared.appearance
        window.setFrameOrigin(NSPoint(x: 80, y: 80))
        window.orderFront(nil)
        try? await Task.sleep(for: .seconds(1.0))
        capture(window, to: url)
        window.close()
    }

    /// Connections › Your agents의 모든 상태 (OA Settings › Your agents 5.4, `-TFSettingsSnapshotAgents`): 상태마다 `<폴더>/light|dark/<상태>.png`.
    /// 값은 모두 가짜 면(`SettingsAgentsSnapshot.SampleEnvironment`)이다: 실제 런타임 · 서버 · `claude` · 폴더 · Keychain에 닿지 않는다
    private static func captureAgents(to directory: URL) async {
        let model = SettingsWindowModel.shared
        func settle(_ seconds: Double = 1.0) async { try? await Task.sleep(for: .seconds(seconds)) }
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let contrast: NSAppearance.Name = name == "light" ? .accessibilityHighContrastAqua : .accessibilityHighContrastDarkAqua
            let folder = directory.appending(path: name, directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for scenario in SettingsAgentsSnapshot.scenarios(now: Date()) {
                // 대비 높이기 모습은 앱 모양을 접근성 고대비 모양으로 바꿔 찍는다 (SwiftUI의 `colorSchemeContrast`가 따라간다)
                NSApplication.shared.appearance = NSAppearance(named: scenario.increasedContrast ? contrast : appearance)
                // 창 밖에서 연다: 상세 · 확인 · 실패 줄이 닫히고 Connections 탭 첫 화면이다
                await show(.connections)
                model.agents.replaceEnvironment(SettingsAgentsSnapshot.SampleEnvironment(scenario))
                await model.agents.refresh(.again)
                switch scenario.screen {
                case .list: break
                case .detail: model.open(.agent)
                case .macs:
                    model.open(.macs)
                    await model.agents.loadMacs()
                }
                if let confirming = scenario.confirming?(model.agents) { model.confirming = confirming }
                let busy = scenario.busy ?? (scenario.busyRemovingFirstMac ? model.agents.macs.first.map { .removeMac($0.id) } : nil)
                model.agents.debugForce(busy: busy, failure: scenario.failure)
                await settle()
                guard let window = settingsWindow else { continue }
                // 앞 장면의 스크롤 자리가 남지 않게: 끝 장면은 끝으로, 나머지는 맨 위로
                if scenario.scrollEnd { _ = scrollToEnd(window) } else { scrollToStart(window) }
                await settle(0.5)
                capture(window, to: folder.appending(path: "\(scenario.name).png"))
            }
        }
        NSApplication.shared.appearance = nil
        model.close()
        model.agents.replaceEnvironment(nil)
    }

    /// Account › Remembered (B3): 입구 · 목록 · 상세(explicit, 추정) · Forget 제자리 확인. 가짜 서버(`SampleChatGateway`)의 렌더 fixture
    private static func captureRemembered(
        model: SettingsWindowModel, shoot: (String, Bool) async -> Void, settle: (Double) async -> Void
    ) async {
        guard let runtime = model.chatRuntime else { return }
        await show(.account)
        await shoot("remembered-entry", true)
        model.open(.remembered)
        await runtime.memory.loadList()
        await settle(1.2)
        await shoot("remembered-list", false)
        model.open(.memory(SampleChatIDs.keepsShort))
        await settle(1.2)
        await shoot("remembered-detail-explicit", false)
        model.confirming = .forgetMemory(SampleChatIDs.keepsShort)
        await settle(1.2)
        await shoot("remembered-detail-forget", false)
        model.open(.memory(SampleChatIDs.jordan))
        await settle(1.2)
        await shoot("remembered-detail-inferred", false)
        model.open(.memory(SampleChatIDs.thursdays))
        await settle(1.2)
        await shoot("remembered-detail-observed", false)
        // 서버 쪽 B1이 출처 원문을 지운 뒤: 같은 행이 목록 · 상세에서 같게 보이고, 추정 각주는 없다
        await runtime.sampleGateway?.purgeObserved(id: SampleChatIDs.thursdays)
        await runtime.memory.loadList()
        await settle(1.2)
        await shoot("remembered-detail-observed-purged", false)
        model.open(.remembered)
        await settle(1.2)
        await shoot("remembered-list-observed-purged", false)
        // 다음 바퀴(Dark)가 처음 데이터에서 시작하도록: 가짜 서버 기억을 되돌리고 저장소 캐시를 비운다
        model.close()
        await runtime.sampleGateway?.restoreMemory()
        runtime.memory.reset()
    }

    /// 그 탭을 마지막 탭으로 적고 창 밖에서 연다 (More 메뉴와 같은 길)
    private static func show(_ tab: SettingsWindowTab) async {
        UserDefaults.standard.set(tab.storedValue, forKey: SettingsOpener.tabKey)
        SettingsOpener.open()
        try? await Task.sleep(for: .seconds(1.5))
    }

    /// 동의 화면: Connections 페이지의 동의 시트를 띄워 처음 · 끝까지 스크롤한 모습을 담고 닫는다 (Not Now와 같다)
    private static func captureConsentPrompt(name: String, to directory: URL) async {
        guard case .ready(_, let services) = AppRuntime.startup else { return }
        let account = AppRuntime.account(services: services)
        SettingsOpener.open(.connections)
        try? await Task.sleep(for: .seconds(1))
        account.showsConsent = true
        try? await Task.sleep(for: .seconds(1.5))
        if let sheet = settingsWindow?.attachedSheet {
            capture(sheet, to: directory.appending(path: "mac-settings-consent-prompt-\(name).png"))
            if scrollToEnd(sheet) {
                try? await Task.sleep(for: .seconds(0.5))
                capture(sheet, to: directory.appending(path: "mac-settings-consent-prompt-end-\(name).png"))
            }
        }
        account.declineConsent()
        try? await Task.sleep(for: .seconds(1))
    }

    /// 멈춘 단계 카드 ›와 같은 길(`LauncherRoute.showTaskforceWorking`): 런처가 범위 Taskforce Working으로 열린 모습을 담고 닫는다
    private static func captureTaskforceWorking(name: String, to directory: URL) async {
        LauncherRoute.showTaskforceWorking()
        try? await Task.sleep(for: .seconds(1.5))
        if let panel = NSApplication.shared.windows.first(where: { $0 is NSPanel && $0.isVisible }) {
            capture(panel, to: directory.appending(path: "mac-settings-usage-working-\(name).png"), drawsHostedContent: true)
        }
        MacAppDelegate.shared?.launcher?.hide()
        try? await Task.sleep(for: .seconds(0.5))
    }

    /// 창 안에서 가장 긴 스크롤 칸을 끝까지 내린다. 스크롤할 것이 없으면 false
    private static func scrollToEnd(_ window: NSWindow) -> Bool {
        guard let root = window.contentView else { return false }
        var stack: [NSView] = [root]
        var best: (view: NSScrollView, overflow: CGFloat)?
        while let view = stack.popLast() {
            if let scroll = view as? NSScrollView, let document = scroll.documentView {
                let overflow = document.frame.height - scroll.contentView.bounds.height
                if overflow > (best?.overflow ?? 1) { best = (scroll, overflow) }
            }
            stack.append(contentsOf: view.subviews)
        }
        guard let best, let document = best.view.documentView else { return false }
        let y = document.isFlipped ? best.overflow : 0
        best.view.contentView.scroll(to: NSPoint(x: 0, y: y))
        best.view.reflectScrolledClipView(best.view.contentView)
        return true
    }

    /// 창 안에서 가장 긴 스크롤 칸을 맨 위로 올린다
    private static func scrollToStart(_ window: NSWindow) {
        guard let root = window.contentView else { return }
        var stack: [NSView] = [root]
        var best: (view: NSScrollView, overflow: CGFloat)?
        while let view = stack.popLast() {
            if let scroll = view as? NSScrollView, let document = scroll.documentView {
                let overflow = document.frame.height - scroll.contentView.bounds.height
                if overflow > (best?.overflow ?? 1) { best = (scroll, overflow) }
            }
            stack.append(contentsOf: view.subviews)
        }
        guard let best, let document = best.view.documentView else { return }
        let y = document.isFlipped ? 0 : best.overflow
        best.view.contentView.scroll(to: NSPoint(x: 0, y: y))
        best.view.reflectScrolledClipView(best.view.contentView)
    }

    private static var settingsWindow: NSWindow? {
        NSApplication.shared.windows.first { $0.isVisible && !($0 is NSPanel) && !$0.isSheet && $0.frame.width > 300 }
    }

    private static func fileName(_ tab: MacSettingsTab) -> String {
        switch tab {
        case .keyboardShortcuts: "keyboard-shortcuts"
        case .taskList: "task-list"
        case .usage: "usage"
        case .account: "account"
        case .about: "about"
        case .connections: "connections"
        case .ai: "privacy"
        }
    }

    /// `LauncherSnapshot`과 같은 방법: 창 바탕색 위에 내용 뷰의 층을 그린다.
    /// `drawsHostedContent`: 런처 패널처럼 유리(`NSGlassEffectView`) 층이 내용을 그리지 않으면 안쪽 SwiftUI 뷰를 그린다
    private static func capture(_ window: NSWindow, to url: URL, drawsHostedContent: Bool = false) {
        guard let content = window.contentView else { return }
        let view = drawsHostedContent ? (hostingView(in: content) ?? content) : content
        guard let layer = view.layer else { return }
        let scale = window.backingScaleFactor
        let size = view.bounds.size
        guard let context = CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        var background = NSColor.windowBackgroundColor.cgColor
        window.effectiveAppearance.performAsCurrentDrawingAppearance { background = NSColor.windowBackgroundColor.cgColor }
        context.setFillColor(background)
        context.fill(CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale)))
        context.scaleBy(x: scale, y: scale)
        if view.isFlipped {
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context)
        guard let image = context.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func hostingView(in view: NSView) -> NSView? {
        if String(describing: type(of: view)).hasPrefix("NSHostingView") { return view }
        return view.subviews.lazy.compactMap { hostingView(in: $0) }.first
    }
}

/// 로그인 견본 인자 (Debug 전용, Release 바이너리에 없다): `-TFSettingsSnapshotSignIn`
enum SignInSnapshot {
    static let argument = "-TFSettingsSnapshotSignIn"

    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains(argument) }
}
#endif
