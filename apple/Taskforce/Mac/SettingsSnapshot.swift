#if os(macOS) && DEBUG
import AppKit

/// 설정 창 확인용 (Debug 빌드): `--show-settings`로 실행하면 설정 창을 연다. `-TFSampleData -TFSnapshot <폴더>`를 더하면
/// 사이드바의 보이는 항목마다 Light · Dark PNG(`mac-settings-<항목>-light.png` · `-dark.png`)를 남기고 끝낸다.
/// Account도 설정 본문을 담는다. Usage & Credits(`-TFSampleCredits`일 때 보임) · Privacy & AI Data는 끝까지 스크롤한 모습(`-end`)도,
/// 동의 화면(460×440 시트)은 처음 · 끝(`consent-prompt` · `consent-prompt-end`)을, Usage의 멈춘 카드 ›로 연 런처(`usage-working`)도 담는다.
/// `LauncherSnapshot`처럼 화면 녹화 권한 없이 자기 창만 그린다 (신호등 · 창 그림자는 담기지 않는다).
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
                if SampleData.isEnabled { await captureWindow(to: directory) }
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
        }
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
#endif
