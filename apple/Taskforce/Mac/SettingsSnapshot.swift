#if os(macOS) && DEBUG
import AppKit

/// 설정 창 확인용 (Debug 빌드): `--show-settings`로 실행하면 설정 창을 연다. `-TFSampleData -TFSnapshot <폴더>`를 더하면
/// 사이드바의 보이는 항목마다 Light · Dark PNG(`mac-settings-<항목>-light.png` · `-dark.png`)를 남기고 끝낸다.
/// Account는 열린 시트 창을 담는다. `LauncherSnapshot`처럼 화면 녹화 권한 없이 자기 창만 그린다 (신호등 · 창 그림자는 담기지 않는다).
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
            for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                NSApplication.shared.appearance = NSAppearance(named: appearance)
                for item in MacSettingsTab.sidebar {
                    SettingsOpener.open(item.tab)
                    try? await Task.sleep(for: .seconds(1.5))
                    guard let window = settingsWindow else { continue }
                    let target = item.tab.opensSheet ? (window.attachedSheet ?? window) : window
                    capture(target, to: directory.appending(path: "mac-settings-\(fileName(item.tab))-\(name).png"))
                    if item.tab.opensSheet {
                        SettingsRoute.shared.showsAccount = false
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
            }
            NSApplication.shared.terminate(nil)
        }
    }

    private static var settingsWindow: NSWindow? {
        NSApplication.shared.windows.first { $0.isVisible && !($0 is NSPanel) && !$0.isSheet && $0.frame.width > 300 }
    }

    private static func fileName(_ tab: MacSettingsTab) -> String {
        switch tab {
        case .keyboardShortcuts: "keyboard-shortcuts"
        case .account: "account"
        case .connections: "connections"
        case .ai: "privacy"
        }
    }

    /// `LauncherSnapshot`과 같은 방법: 창 바탕색 위에 내용 뷰의 층을 그린다
    private static func capture(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView, let layer = view.layer else { return }
        let scale = window.backingScaleFactor
        let size = view.bounds.size
        guard let context = CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
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
}
#endif
