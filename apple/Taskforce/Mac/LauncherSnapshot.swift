#if os(macOS) && DEBUG
import AppKit
import Carbon.HIToolbox
import TaskforceKit

/// 디자인 비교용 (Debug 빌드): `--show-launcher -TFSampleData -TFSnapshot <폴더>`로 실행하면 런처 화면을 PNG로 남기고 끝낸다.
/// 화면 녹화 권한 없이 자기 창만 그린다 (유리 재질의 바탕화면 흐림은 담기지 않는다). `-TFSnapshotDark`면 Dark 모양으로, 파일 이름 끝에 `-dark`.
/// - 상태 견본 하나(`-TFSampleOffline` · `-TFSampleRefreshFailed` · `-TFSampleNoSaved` · `-TFSampleEmpty` · `-TFSampleLoading`)면 그 화면 한 장
/// - 실행 견본 하나(`-TFSampleRun…` · `-TFSampleNoExecution`, U2 Mac)면 갈래(M1 · M12 · M17) · ⌘K 패널(M7) · 범위 메뉴(M13) ·
///   갈래 버튼 포커스 · 초안 · Run with AI(M8, 시작할 수 있을 때)
/// - 아니면 목록(M1) · 끝까지 내린 목록(M2) · 범위 메뉴(M13) · 펼친 섹션 · 상세 포커스 · ⌘K 패널 · 찾기 · 설정 창
@MainActor
enum LauncherSnapshot {
    static var directory: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-TFSnapshot"), arguments.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    private static var isDark: Bool { ProcessInfo.processInfo.arguments.contains("-TFSnapshotDark") }

    /// 상태 견본이면 그 화면 이름
    private static var stateName: String? {
        if SampleData.isOffline { return SampleData.hasNoSaved ? "offline-empty" : "offline-saved" }
        if SampleData.isRefreshFailed { return SampleData.hasNoSaved ? "refresh-failed-empty" : "refresh-failed" }
        if SampleData.isEmpty { return "empty" }
        if SampleData.isLoading { return "loading" }
        return nil
    }

    static func run(panel: NSPanel, model: LauncherModel) {
        guard let directory else { return }
        if isDark { NSApplication.shared.appearance = NSAppearance(named: .darkAqua) }
        let suffix = isDark ? "-dark" : ""
        func file(_ name: String) -> URL { directory.appending(path: "mac-launcher-\(name)\(suffix).png") }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            if let stateName {
                capture(panel, to: file(stateName))
                NSApplication.shared.terminate(nil)
                return
            }
            if let runName {
                await captureRun(panel: panel, model: model, name: runName, file: file)
                NSApplication.shared.terminate(nil)
                return
            }
            // M1: In Progress 첫 줄을 고른 목록
            model.focus(actionID: SampleData.demoID)
            try? await Task.sleep(for: .seconds(1))
            capture(panel, to: file("list"))
            // M2: 끝까지 내린 목록 (Done Today 머리)
            model.select(model.items.count - 1)
            try? await Task.sleep(for: .seconds(1))
            capture(panel, to: file("scrolled"))
            // M13: 범위 메뉴, Review에 고른 줄
            model.focus(actionID: SampleData.demoID)
            model.toggleScopeMenu()
            model.selectScopeMenuRow(1)
            try? await Task.sleep(for: .seconds(1))
            capture(panel, to: file("scope"))
            model.closeScopeMenu()
            // 펼친 섹션: Review Show 2 More · Done Today
            if let more = model.items.firstIndex(where: { if case .showMore(.review, _) = $0 { true } else { false } }) {
                model.select(more)
                model.run(model.items[more])
            }
            if let done = model.items.firstIndex(where: { if case .doneToday = $0 { true } else { false } }) {
                model.run(model.items[done])
            }
            model.select(0)
            try? await Task.sleep(for: .seconds(1))
            capture(panel, to: file("expanded"))
            // 상세 포커스: Review 행 ↩ (Show Review)
            model.expand()
            try? await Task.sleep(for: .seconds(1))
            capture(panel, to: file("detail"))
            model.back()
            model.focus(actionID: SampleData.demoID)
            model.openActions()
            try? await Task.sleep(for: .seconds(1))
            capture(panel, to: file("actions"))
            model.back()
            model.text = "IR"
            try? await Task.sleep(for: .seconds(1))
            capture(panel, to: file("query"))
            model.openSettings(.connections)
            try? await Task.sleep(for: .seconds(2))
            if let window = NSApplication.shared.windows.first(where: { $0.isVisible && !($0 is NSPanel) && $0.contentView != nil && $0.frame.width > 300 }) {
                let kind = SettingsOpener.action == nil ? "fallback" : "scene"
                capture(window, to: directory.appending(path: "mac-settings-connections-\(kind)\(suffix).png"))
            }
            NSApplication.shared.terminate(nil)
        }
    }

    /// 실행 견본이면 그 이름 (`lane-<이름>`: `-TFSampleRunDraftReady` → `draftready`)
    private static var runName: String? {
        if SampleRuns.noExecution { return "no-execution" }
        return SampleRuns.lane.map { $0.rawValue.dropFirst("-TFSampleRun".count).lowercased() }
    }

    private static func captureRun(panel: NSPanel, model: LauncherModel, name: String, file: (String) -> URL) async {
        func settle() async { try? await Task.sleep(for: .seconds(1)) }
        // 금요일 고객 데모 준비 (In Progress 첫 줄)를 고른 목록 | 상세: 갈래 · 막대(M17 Stop requested)
        model.focus(actionID: SampleData.demoID)
        await settle()
        capture(panel, to: file("lane-\(name)"))
        // ⌘K 패널: Taskforce on this task (M7 일부, 맨 아래 묶음의 마지막 줄을 골라 보이게)
        model.openActions()
        await settle()
        model.select(model.rowCount - 1)
        await settle()
        capture(panel, to: file("lane-\(name)-actions"))
        model.back()
        // 범위 메뉴: Taskforce Working (M13)
        model.toggleScopeMenu()
        await settle()
        capture(panel, to: file("lane-\(name)-scope"))
        model.closeScopeMenu()
        guard let target = model.detailTarget else { return }
        // 갈래 버튼 포커스(Tab → Tab) → ↩ 초안
        if model.lane(for: target.action.id)?.drafts.isEmpty == false {
            press(kVK_Tab, in: panel, model: model)
            press(kVK_Tab, in: panel, model: model)
            await settle()
            capture(panel, to: file("lane-\(name)-focus"))
            press(kVK_Return, in: panel, model: model)
            await settle()
            capture(panel, to: file("draft-\(name)"))
            model.back()
            model.back()
        }
        // M8: 빈 Goal · Figma 예시 Goal
        if model.runAvailability(for: target).isEnabled {
            model.openRun(target)
            await settle()
            capture(panel, to: file("run-with-ai-empty-\(name)"))
            model.goal = "데모 때 나올 예상 질문 목록과 답변 초안. 결제 단계 이탈 관련 질문을 먼저 두고, 보안·개인정보 질문은 따로 묶기"
            await settle()
            capture(panel, to: file("run-with-ai-\(name)"))
        }
    }

    /// 키 하나를 런처에 보낸 것처럼 (`LauncherModel.handleKey`)
    private static func press(_ keyCode: Int, in panel: NSPanel, model: LauncherModel) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(keyCode)
        ) else { return }
        _ = model.handleKey(event)
    }

    private static func capture(_ panel: NSWindow, to url: URL) {
        guard let content = panel.contentView else { return }
        // Liquid Glass(`NSGlassEffectView`)의 층은 내용을 그리지 않아 안쪽 SwiftUI 뷰를 그린다
        let view = hostingView(in: content) ?? content
        guard let layer = view.layer else { return }
        let scale = panel.backingScaleFactor
        let size = view.bounds.size
        guard let context = CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        // 유리 재질 대신 창 바탕색을 깔고 그린다
        var background = NSColor.windowBackgroundColor.cgColor
        panel.effectiveAppearance.performAsCurrentDrawingAppearance {
            background = NSColor.windowBackgroundColor.cgColor
        }
        context.setFillColor(background)
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

    private static func hostingView(in view: NSView) -> NSView? {
        if String(describing: type(of: view)).hasPrefix("NSHostingView") { return view }
        for subview in view.subviews {
            if let found = hostingView(in: subview) { return found }
        }
        return nil
    }
}
#endif
