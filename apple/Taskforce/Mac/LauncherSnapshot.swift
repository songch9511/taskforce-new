#if os(macOS) && DEBUG
import AppKit

/// 디자인 비교용 (Debug 빌드): `--show-launcher -TFSampleData -TFSnapshot <폴더>`로 실행하면 런처의 목록 · 펼침 · ⌘K 화면을
/// PNG로 남기고 끝낸다. 화면 녹화 권한 없이 자기 창만 그린다 (유리 재질의 바탕화면 흐림은 담기지 않는다).
@MainActor
enum LauncherSnapshot {
    static var directory: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-TFSnapshot"), arguments.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    static func run(panel: NSPanel, model: LauncherModel) {
        guard let directory else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            capture(panel, to: directory.appending(path: "mac-launcher-list.png"))
            model.expand()
            try? await Task.sleep(for: .seconds(1))
            capture(panel, to: directory.appending(path: "mac-launcher-detail.png"))
            model.back()
            model.openActions()
            try? await Task.sleep(for: .seconds(1))
            capture(panel, to: directory.appending(path: "mac-launcher-actions.png"))
            model.back()
            model.text = "IR"
            try? await Task.sleep(for: .seconds(1))
            capture(panel, to: directory.appending(path: "mac-launcher-query.png"))
            model.openSettings(.connections)
            try? await Task.sleep(for: .seconds(2))
            if let window = NSApplication.shared.windows.first(where: { $0.isVisible && !($0 is NSPanel) && $0.contentView != nil && $0.frame.width > 300 }) {
                let kind = SettingsOpener.action == nil ? "fallback" : "scene"
                capture(window, to: directory.appending(path: "mac-settings-connections-\(kind).png"))
            }
            NSApplication.shared.terminate(nil)
        }
    }

    private static func capture(_ panel: NSWindow, to url: URL) {
        guard let view = panel.contentView, let layer = view.layer else { return }
        let scale = panel.backingScaleFactor
        let size = view.bounds.size
        guard let context = CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        // 유리 재질 대신 창 바탕색을 깔고 그린다
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale)))
        context.scaleBy(x: scale, y: scale)
        if view.isFlipped {
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context)
        guard let image = context.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
