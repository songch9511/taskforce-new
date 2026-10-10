#if os(macOS) && DEBUG
import AppKit
import TaskforceKit

/// 디자인 비교용 (Debug 빌드): `-TF_EDGE_SHELL YES -TFSampleData -TFEdgeSnapshot <폴더>`로 실행하면 Edge 셸을 PNG로 남기고 끝낸다.
/// 화면 녹화 권한 없이 자기 창(레일 · 패널)의 내용만 그려, 데스크톱 견본 위에 실제 자리대로 붙인다(창 그림자 · 유리 흐림은 담기지 않는다).
/// 시스템 설정은 바꾸지 않는다: Dark는 `-TFSnapshotDark`(앱 모양만), 움직임 줄이기는 셸 모델 값.
/// `-TFEdgeSnapshotMix`: 견본의 확인 요청을 하나로 줄여 needs you · running 링이 함께 보이게 한다(`-TFSampleRunWorking`과 같이).
/// 남기는 것: hidden(숨은 레일) · expanded(호버로 펼친 레일) · panel(All work 패널) · All work 상태(S3: filters-open · filter-summary ·
/// no-match · pinned · done-today · rail-open-clears-filter) · reduce-motion(움직임 줄이기, 패널) · chats.
/// `-TFEdgeSnapshotChats`: Chats 상태 (B3, 견본 가짜 서버): 목록 · 초안 · 대화(인용 · 기억 노트 explicit/inferred) · 보내는 중 · 실패 · 동의 전 · 기능 꺼짐 · 빈 목록 · 오프라인 · 읽기 실패 ·
/// 노트 확인 · 잊기 뒤. 서버 응답은 가짜(`SampleChatGateway`)라 렌더 fixture일 뿐이다 (실제 서버 · 계정 · AI 호출 없음).
/// `-TFEdgeSnapshotState <이름>`: All work 패널 하나만 `mac-edge-worklist-<이름>.png`로 (빈 · 오프라인 · 실패 같은 견본 상태 인자와 함께)
@MainActor
enum EdgeSnapshot {
    static var directory: URL? {
        value(after: "-TFEdgeSnapshot").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private static func value(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    static func runIfRequested(_ edge: EdgeShellController) {
        // 견본 데이터에서만: 실제 계정의 할 일 제목을 PNG로 남기지 않는다
        guard let directory, SampleData.isEnabled else { return }
        let arguments = ProcessInfo.processInfo.arguments
        let dark = arguments.contains("-TFSnapshotDark")
        if dark { NSApplication.shared.appearance = NSAppearance(named: .darkAqua) }
        if arguments.contains("-TFEdgeSnapshotMix") {
            edge.workOverride = { work in
                var work = work
                work.review = Array(work.review.prefix(1))
                return work
            }
        }
        func file(_ name: String) -> URL { directory.appending(path: "mac-edge-\(name)\(dark ? "-dark" : "").png") }
        let state = value(after: "-TFEdgeSnapshotState")
        Task { @MainActor in
            func settle(_ seconds: Double = 0.8) async { try? await Task.sleep(for: .seconds(seconds)) }
            await settle(1.5)
            if arguments.contains("-TFEdgeSnapshotChats") {
                await captureChats(edge, file: file, settle: { await settle() })
                NSApplication.shared.terminate(nil)
                return
            }
            if let state {
                edge.shell.openAllWork()
                await settle()
                capture(edge, to: file("worklist-\(state)"))
                NSApplication.shared.terminate(nil)
                return
            }
            capture(edge, to: file("hidden"))
            edge.shell.pointer(inside: true)
            await settle()
            capture(edge, to: file("expanded"))
            edge.shell.openAllWork()
            await settle()
            capture(edge, to: file("panel"))
            await captureWorkList(edge, file: file, settle: { await settle() })
            edge.shell.reduceMotion = true
            await settle()
            capture(edge, to: file("reduce-motion"))
            edge.shell.reduceMotion = EdgeShellController.systemReduceMotion
            edge.shell.openChats()
            await settle()
            capture(edge, to: file("chats"))
            NSApplication.shared.terminate(nil)
        }
    }

    /// Chats 상태 (B3): 가짜 서버를 시나리오대로 바꿔 가며 같은 패널에서 담는다
    private static func captureChats(_ edge: EdgeShellController, file: (String) -> URL, settle: () async -> Void) async {
        guard let runtime = edge.chat, let gateway = runtime.sampleGateway else { return }
        let chat = runtime.chat
        let memory = runtime.memory
        /// 다른 계정이 막 로그인한 것처럼 저장소를 비우고 새로 읽는다 (가짜 서버 시나리오를 바꾼 뒤)
        func restart(_ scenario: SampleChatGateway.Scenario) async {
            await gateway.setScenario(scenario)
            runtime.scope.accountLeft()
            edge.shell.openChats()
            await chat.settle()
            await settle()
        }
        func shoot(_ name: String) { capture(edge, to: file("chats-\(name)")) }

        // 목록: 새 것이 위, 실제 날짜, 초안이 미리보기를 이긴다
        await restart(.full)
        chat.setDraft("Can you compare plan B with", for: SampleChatIDs.copy)
        chat.showHistory()
        await settle()
        shoot("history")
        // 짧은 대화: 사용자 글(들여씀) · Taskforce 답(전폭)
        chat.open(SampleChatIDs.copy)
        await chat.settle()
        await settle()
        shoot("conversation-short")
        // 대화: 사용자 글 · Taskforce 답(전폭) · 인용 · 기억 노트(explicit, inferred)
        chat.open(SampleChatIDs.shape)
        await chat.settle()
        await memory.loadList()
        await settle()
        await settle()
        shoot("conversation")
        // 노트에서 추정을 확인한다 (서버 200 뒤에만 바뀐다) → explicit 노트
        _ = await memory.confirm(SampleChatIDs.jordan)
        await settle()
        shoot("note-confirmed")
        _ = await memory.forget(SampleChatIDs.keepsShort)
        await settle()
        shoot("note-forgotten")
        // 보내는 중 · 실패 · 동의 전
        await restart(.sendHangs)
        chat.open(SampleChatIDs.shape)
        await chat.settle()
        Task { await chat.send("Draft the pricing FAQ again, shorter") }
        await settle()
        shoot("sending")
        await restart(.sendFails)
        chat.open(SampleChatIDs.shape)
        await chat.settle()
        await chat.send("Draft the pricing FAQ again, shorter")
        await settle()
        shoot("failed")
        await restart(.consentNeeded)
        chat.open(SampleChatIDs.shape)
        await chat.settle()
        await chat.send("Draft the pricing FAQ again, shorter")
        await settle()
        shoot("consent")
        // 서버 gate 꺼짐: 실패로 꾸미지 않는다
        await restart(.featureOff)
        _ = chat.newChat()
        await chat.send("Hello")
        await settle()
        shoot("unavailable")
        chat.showHistory()
        await settle()
        shoot("unavailable-history")
        // 읽기 상태: 없음 · 오프라인 · 읽기 실패
        await restart(.empty)
        chat.showHistory()
        await settle()
        shoot("empty")
        await restart(.offline)
        await settle()
        shoot("offline")
        await restart(.failed)
        await settle()
        shoot("load-failed")
        // 새 대화: 빈 대화 (입력칸만)
        await restart(.full)
        _ = chat.newChat()
        await settle()
        shoot("new-chat")
    }

    /// All work 상태 (S3): 필터 카드 · 닫힌 필터 요약 · 맞는 일 없음(Waiting: 지금 데이터에 근거가 없다) · 고정 · Done today(Done 필터)
    private static func captureWorkList(_ edge: EdgeShellController, file: (String) -> URL, settle: () async -> Void) async {
        let shell = edge.shell
        shell.setFiltersOpen(true)
        await settle()
        capture(edge, to: file("filters-open"))
        shell.setFiltersOpen(false)
        shell.setFilter(WorkFilter(status: .inProgress))
        await settle()
        capture(edge, to: file("filter-summary"))
        shell.setFilter(WorkFilter(status: .waiting))
        await settle()
        capture(edge, to: file("no-match"))
        shell.setFilter(WorkFilter())
        // 견본의 To Do 둘을 고정: 그 묶음(Ungrouped) 맨 앞
        for item in shell.workItems.filter({ $0.state == .toDo }).suffix(2) { shell.pin(item.id) }
        await settle()
        capture(edge, to: file("pinned"))
        shell.setFilter(WorkFilter(status: .done))
        await settle()
        capture(edge, to: file("done-today"))
        // 레일의 Running 칸을 연다: Done 필터가 그 일을 가리므로 필터를 비우고 그 행을 고른 채 보인다
        if let running = shell.slots.first(where: { $0.kind == .running }) {
            shell.open(itemID: running.id)
            await settle()
            capture(edge, to: file("rail-open-clears-filter"))
        }
        shell.openAllWork()
        await settle()
    }

    /// `EdgeInteraction`이 단계마다 담는다 (`-TFEdgeInteractShots <폴더>`가 있을 때만)
    static func captureForInteraction(_ edge: EdgeShellController, name: String) {
        guard let directory = value(after: "-TFEdgeInteractShots").map({ URL(fileURLWithPath: $0, isDirectory: true) }) else { return }
        capture(edge, to: directory.appending(path: "mac-edge-\(name).png"))
    }

    /// 보이는 창(레일 · 패널)을 화면 자리대로, 데스크톱 견본 위에 그린다
    private static func capture(_ edge: EdgeShellController, to url: URL) {
        let windows = [edge.panel.panel, edge.rail.panel].filter(\.isVisible)
        guard let first = windows.first else { return }
        let margin: CGFloat = 24
        let bounds = windows.map(\.frame).reduce(first.frame) { $0.union($1) }
        // 오른쪽은 화면 모서리(베젤)라 여백이 없다
        let canvas = CGRect(x: bounds.minX - margin, y: bounds.minY - margin, width: bounds.width + margin, height: bounds.height + 2 * margin)
        let scale = first.backingScaleFactor
        guard let context = CGContext(
            data: nil, width: Int(canvas.width * scale), height: Int(canvas.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        context.scaleBy(x: scale, y: scale)
        drawDesktop(in: context, size: canvas.size)
        for window in windows {
            guard let view = window.contentView, let layer = view.layer else { continue }
            context.saveGState()
            context.setAlpha(window.alphaValue)
            context.translateBy(x: window.frame.minX - canvas.minX, y: window.frame.minY - canvas.minY)
            if view.isFlipped {
                context.translateBy(x: 0, y: view.bounds.height)
                context.scaleBy(x: 1, y: -1)
            }
            layer.render(in: context)
            context.restoreGState()
        }
        guard let image = context.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = canvas.size
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// 데스크톱 견본 (디자인 EdgeScene의 화면 그라데이션)
    private static func drawDesktop(in context: CGContext, size: CGSize) {
        let colors = ["7d8794", "857a80", "857968", "4a3c3e"].map { hex -> CGColor in
            let value = UInt32(hex, radix: 16) ?? 0
            return CGColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        }
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 0.42, 0.62, 1]) else { return }
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: .zero, options: [])
    }
}
#endif
