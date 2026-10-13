#if os(macOS) && DEBUG
import AppKit
import Carbon.HIToolbox
import TaskforceKit
import Vision

/// 격리 Debug 실행의 앱 안 합성 조작 확인 (`-TF_EDGE_SHELL YES -TFSampleData -TFEdgeInteract <로그 파일>`): 진짜 패널 창에 AppKit 이벤트(키 · 마우스)를 `NSApp.sendEvent`로 흘려
/// 단축키 모니터 · 입력칸(필드 에디터 · 델리게이트) · SwiftUI 버튼이 실제 응답 체인으로 반응하는지 본다. 가짜 서버(`SampleChatGateway`)라 네트워크 · 계정 · AI 호출은 없다.
/// 이것은 OS 수준의 포인터 · 키보드 입력도 VoiceOver도 아니다 (앱 프로세스 안에서 만든 이벤트): 로그에 그렇게 적는다.
/// 로그 한 줄 = `PASS|FAIL <단계> — <본 것>`, `-TFEdgeInteractShots <폴더>`가 있으면 단계마다 PNG도 남긴다.
@MainActor
enum EdgeInteraction {
    static var logPath: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-TFEdgeInteract"), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    static func runIfRequested(_ edge: EdgeShellController) {
        guard let logPath, SampleData.isEnabled, let runtime = edge.chat else { return }
        Task { @MainActor in
            var lines: [String] = ["합성 조작(앱 프로세스 안 NSApp.sendEvent) — OS 수준 포인터 · 키보드 · VoiceOver 아님"]
            func settle(_ seconds: Double = 0.6) async { try? await Task.sleep(for: .seconds(seconds)) }
            func check(_ name: String, _ ok: Bool, _ seen: String) {
                lines.append("\(ok ? "PASS" : "FAIL") \(name) — \(seen)")
            }
            await settle(1.5)
            let chat = runtime.chat
            let memory = runtime.memory
            let panelWindow = edge.panel.panel

            // 1) ⌥ Space와 같은 길로 열고, ⌘3 키 이벤트
            edge.shell.togglePanel()
            await settle()
            sendKey("3", code: kVK_ANSI_3, flags: .command, to: panelWindow)
            await settle(1)
            check("⌘3 Chats", edge.shell.view == .chats && chat.mode == .chat && chat.currentID != nil, "view=\(edge.shell.view) mode=\(chat.mode) title=\(chat.headerTitle)")

            // 2) ⌘N 새 대화 → 입력칸에 글자를 치고 Return
            sendKey("n", code: kVK_ANSI_N, flags: .command, to: panelWindow)
            await settle()
            let before = chat.currentID
            // 견본에는 손대지 않은 빈 대화가 이미 있다: ⌘N은 새로 만들지 않고 그것을 다시 쓴다
            check("⌘N New chat reuses the untouched empty chat", chat.mode == .chat && chat.currentID == SampleChatIDs.blank && chat.locals.isEmpty, "id=\(String(describing: chat.currentID)) locals=\(chat.locals.count) title=\(chat.currentTitle)")
            sendKey("n", code: kVK_ANSI_N, flags: .command, to: panelWindow)
            await settle(0.3)
            check("⌘N again stays on the same empty chat", chat.locals.isEmpty && chat.currentID == before, "locals=\(chat.locals.count) same=\(chat.currentID == before)")
            for character in "Use the shorter FAQ" {
                sendKey(String(character), code: Int(keyCode(for: character)), to: panelWindow)
            }
            await settle(0.3)
            let draft = before.map { chat.draft(for: $0) } ?? ""
            check("typing fills the draft", draft == "Use the shorter FAQ", "draft=\"\(draft)\"")
            sendKey("\r", code: kVK_Return, to: panelWindow)
            await settle(1.5)
            let texts = before.map { chat.turns(for: $0).map(\.text) } ?? []
            check("Return sends and names the chat", texts.count == 2 && texts[0] == "Use the shorter FAQ" && chat.currentTitle == "Use the shorter FAQ", "turns=\(texts.count) title=\(chat.currentTitle) draft=\"\(before.map { chat.draft(for: $0) } ?? "")\"")
            capture(edge, "interact-1-sent")

            // 3) history 아이콘(머리 오른쪽 끝)을 눌러 목록, 대화 하나(글자를 읽어 찾는다)를 눌러 연다
            clickPanelPoint(CGPoint(x: EdgePanelMetrics.width - 24, y: 26), in: panelWindow)
            await settle()
            check("click Chat history", chat.mode == .history, "mode=\(chat.mode) entries=\(chat.entries.count)")
            capture(edge, "interact-2-history")
            await click(text: "Shape design priorities", in: panelWindow)
            await settle(1.2)
            check("click a chat item", chat.mode == .chat && chat.currentID == SampleChatIDs.shape, "mode=\(chat.mode) title=\(chat.currentTitle) | \(lastClick)")

            // 4) 노트에서 Confirm(추정 → explicit), Forget
            await memory.loadList()
            await settle(0.8)
            await click(text: "Confirm", in: panelWindow)
            await settle(1)
            let confirmed = memory.noteState(for: SampleChatIDs.jordan)
            var ok = false
            if case .current(let item) = confirmed { ok = item.origin == .explicit && item.id != SampleChatIDs.jordan }
            check("click Confirm on the inferred note", ok, "note=\(confirmed)")
            capture(edge, "interact-3-confirmed")
            await click(text: "Forget", in: panelWindow)
            await settle(1)
            let forgotten = [SampleChatIDs.keepsShort, SampleChatIDs.jordan].filter { memory.noteState(for: $0) == .notRemembered }
            check("click Forget on a note", forgotten.count == 1, "notRemembered=\(forgotten.count)")
            capture(edge, "interact-4-forgotten")

            // 5) Esc: 목록이 아니라 대화 중이므로 패널을 접는다. 목록에서는 대화로 먼저
            clickPanelPoint(CGPoint(x: EdgePanelMetrics.width - 24, y: 26), in: panelWindow)
            await settle(0.4)
            sendKey("\u{1B}", code: kVK_Escape, to: panelWindow)
            await settle(0.5)
            check("Esc in history returns to the chat first", edge.shell.panelOpen && chat.mode == .chat, "panelOpen=\(edge.shell.panelOpen) mode=\(chat.mode)")
            sendKey("\u{1B}", code: kVK_Escape, to: panelWindow)
            await settle(0.5)
            check("Esc collapses the panel", !edge.shell.panelOpen, "panelOpen=\(edge.shell.panelOpen)")

            try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8)
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: 이벤트

    private static func sendKey(_ characters: String, code: Int, flags: NSEvent.ModifierFlags = [], to window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code)
            ) else { continue }
            NSApp.sendEvent(event)
        }
    }

    /// 글자 하나의 가상 키 코드 (영문 소문자 · 공백만)
    private static func keyCode(for character: Character) -> UInt16 {
        let table: [Character: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
            "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
            "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z, " ": kVK_Space,
        ]
        return UInt16(table[Character(character.lowercased())] ?? kVK_Space)
    }

    /// 마지막 클릭의 진단 (로그에 덧붙인다)
    nonisolated(unsafe) static var lastClick = ""

    /// 패널 안 한 점(왼쪽 위가 0)을 마우스 누름 · 뗌 이벤트로 눌러 본다
    private static func clickPanelPoint(_ point: CGPoint, in window: NSWindow) {
        let size = window.contentView?.bounds.size ?? window.frame.size
        post(click: NSPoint(x: point.x, y: size.height - point.y), in: window)
    }

    /// 화면에 그려진 글자를 읽어(Vision 글자 인식) 그 자리를 누른다: 같은 글자가 여럿이면 가장 위의 것. 접근성 트리는 밖에서 묻는 쪽이 없으면 비어 있어 쓰지 않는다
    private static func click(text: String, in window: NSWindow) async {
        guard let point = locate(text, in: window) else {
            lastClick = "글자를 찾지 못함 (\(text))"
            return
        }
        lastClick = "찾음 \(text) windowPoint=\(point)"
        post(click: point, in: window)
    }

    private static func post(click point: NSPoint, in window: NSWindow) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ) else { continue }
            NSApp.sendEvent(event)
        }
    }

    /// 창 안(왼쪽 아래가 0)에서 그 글자가 그려진 곳의 가운데
    private static func locate(_ phrase: String, in window: NSWindow) -> NSPoint? {
        guard let view = window.contentView, let layer = view.layer else { return nil }
        let scale = window.backingScaleFactor
        let size = view.bounds.size
        guard let context = CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        context.scaleBy(x: scale, y: scale)
        if view.isFlipped {
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context)
        guard let image = context.makeImage() else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return nil }
        var best: CGRect?
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first, let range = candidate.string.range(of: phrase),
                  let box = try? candidate.boundingBox(for: range)?.boundingBox else { continue }
            // Vision 좌표: 정규화 · 왼쪽 아래가 0 (창 좌표와 같은 방향)
            if best == nil || box.midY > best!.midY { best = box }
        }
        guard let best else { return nil }
        return NSPoint(x: best.midX * size.width, y: best.midY * size.height)
    }

    private static func capture(_ edge: EdgeShellController, _ name: String) {
        EdgeSnapshot.captureForInteraction(edge, name: name)
    }
}
#endif
