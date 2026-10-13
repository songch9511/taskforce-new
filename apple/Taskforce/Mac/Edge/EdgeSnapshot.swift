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
/// `-TFEdgeSnapshotContexts`(`-TF_S3B YES`와 함께: S3b 기본은 꺼짐): 범위(프로젝트) 멤버십 상태 (S3b, 견본 가짜 서버 `SampleContextGateway`): 묶음(여러 프로젝트 · 보관됨 · Ungrouped) · 검색 · Project 칩 ·
/// ProjectLink 줄(Set by you · Auto-linked · Not confirmed 후보 · No clear link · 여러 프로젝트 · 보관됨) · 바꾼 뒤 Undo · 충돌 · 응답 유실 · gate 꺼짐 · 진행 중 ·
/// 읽는 중 · 오프라인 · 읽기 실패 · 프로젝트 없음 · 테이블 없음. 서버 응답은 가짜라 렌더 fixture일 뿐이다 (실제 서버 · 계정 · AI 호출 없음).
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
            if arguments.contains("-TFEdgeSnapshotContexts") {
                await captureContexts(edge, file: file, settle: { await settle() })
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

    /// 범위 멤버십 상태 (S3b): 가짜 서버를 시나리오대로 바꿔 가며 같은 패널에서 담는다
    private static func captureContexts(_ edge: EdgeShellController, file: (String) -> URL, settle: () async -> Void) async {
        guard let runtime = edge.chat, let gateway = runtime.sampleContextGateway, let store = runtime.contexts else { return }
        let shell = edge.shell
        func shoot(_ name: String) { capture(edge, to: file("projects-\(name)")) }
        func id(_ n: Int) -> UUID { SampleData.id(n) }
        /// 패널 높이에 맞게 견본의 일을 고른 몇 개로 줄인다 (확인 요청 · 오늘 끝낸 일은 뺀다)
        func focus(_ numbers: [Int], done: Bool = false) {
            let keep = Set(numbers.map(id))
            edge.workOverride = { work in
                var work = work
                work.review = []
                work.open = work.open.filter { keep.contains($0.id) }
                work.doneToday = done ? Array(work.doneToday.prefix(1)) : []
                return work
            }
        }
        /// 다른 계정이 막 로그인한 것처럼 저장소를 비우고 새로 읽는다 (가짜 서버 시나리오를 바꾼 뒤)
        func restart(_ scenario: SampleContextGateway.Scenario) async {
            await gateway.setScenario(scenario)
            runtime.scope.accountLeft()
            shell.openAllWork()
            Task { await store.refresh() }
            await settle()
        }
        func open(_ n: Int) async {
            shell.open(itemID: id(n))
            await settle()
        }
        WorkRowProjectLinks.opensForSnapshot = nil

        // 묶음: 한 할 일이 두 프로젝트면 두 묶음에 (12), 후보(14)와 멤버십 없음(21)은 Ungrouped, 묶음 이름에 개수 없음
        await restart(.full)
        focus([10, 12, 14])
        await settle()
        shoot("groups")
        focus([11, 13, 21])
        await settle()
        shoot("groups-other")
        focus([10, 20, 21])
        await settle()
        shoot("groups-archived")
        // Project 칩은 실제 범위 (보관된 것은 그렇게 적는다), 검색은 프로젝트 이름도 본다
        focus([10, 11, 12, 13, 14, 20, 21])
        shell.setFiltersOpen(true)
        await settle()
        shoot("chips")
        shell.setFiltersOpen(false)
        shell.setFilter(WorkFilter(query: "acme"))
        await settle()
        shoot("search-acme")
        if let acme = WorkListLayout.projectOptions(shell.workItems).first(where: { $0.title == "Acme website" }) {
            shell.setFilter(WorkFilter(project: acme))
            await settle()
            shoot("chip-acme")
        }
        shell.setFilter(WorkFilter())

        // ProjectLink 줄: 고른 줄 아래 (닫힘이 기본 → 열어 둔 사진 / 닫힌 사진)
        focus([10])
        await open(10)
        shoot("link-collapsed")
        focus([12])
        await open(12)
        shoot("link-multi-collapsed")
        for (name, number, opens) in [
            ("user", 10, { (_: ProjectLinkContent) in true }), ("auto", 11, { _ in true }), ("multi", 12, { $0.basis == .auto }),
            ("candidate", 14, { $0.basis == .candidate }), ("none", 21, { _ in true }), ("archived", 20, { _ in true }),
        ] as [(String, Int, (ProjectLinkContent) -> Bool)] {
            WorkRowProjectLinks.opensForSnapshot = opens
            focus([number])
            shell.openAllWork()
            await open(number)
            shoot("link-\(name)")
        }
        WorkRowProjectLinks.opensForSnapshot = { _ in true }

        // 바꾼 뒤: 서버 200 뒤에만 바뀌고 Undo가 보인다 → Undo
        await restart(.full)
        focus([10, 13])
        await open(10)
        let moved = await store.move(id(10), from: SampleContextIDs.shape, to: SampleContextIDs.acme)
        await settle()
        if moved == .applied(canUndo: true) { shoot("link-changed") }
        _ = await store.undoLast(id(10))
        await settle()
        shoot("link-undone")
        // 후보 확인 → 확인된 멤버 (Set by you), Undo
        await restart(.full)
        focus([14])
        await open(14)
        _ = await store.add(id(14), to: SampleContextIDs.shape)
        await settle()
        shoot("link-candidate-confirmed")
        // 충돌: 다른 기기가 먼저 그 범위를 바꿨다 → 성공으로 올리지 않고 다시 읽은 상태 + 안내
        await restart(.full)
        focus([10, 21])
        await open(10)
        await gateway.otherDevice(.add, context: SampleContextIDs.shape, action: id(21))
        _ = await store.remove(id(10), from: SampleContextIDs.shape)
        await settle()
        shoot("link-conflict")
        // 응답 유실: 서버는 처리했을 수 있다 → 성공이라 하지 않고 다시 읽은 상태 + 안내
        await restart(.loseResponse)
        focus([21])
        await open(21)
        _ = await store.add(id(21), to: SampleContextIDs.acme)
        await settle()
        shoot("link-unconfirmed")
        // 서버 gate 꺼짐: 실패로 꾸미지 않는다 (읽기는 그대로, 바꾸기만 없다)
        await restart(.featureOff)
        focus([10, 21])
        await open(10)
        _ = await store.remove(id(10), from: SampleContextIDs.shape)
        await settle()
        shoot("link-gate-off")
        // 요청이 진행 중: 컨트롤이 막힌다
        await restart(.writeHangs)
        focus([21])
        await open(21)
        Task { _ = await store.add(id(21), to: SampleContextIDs.shape) }
        await settle()
        shoot("link-busy")

        // 읽기 상태: 읽는 중(아무 주장 없음) · 오프라인 · 읽기 실패 · 프로젝트 없음 · 테이블 없음
        WorkRowProjectLinks.opensForSnapshot = nil
        for (name, scenario) in [
            ("loading", SampleContextGateway.Scenario.readHangs), ("offline", .offline), ("failed", .failed), ("no-projects", .empty), ("tables-missing", .unavailable),
        ] {
            await restart(scenario)
            focus([10, 11, 21])
            await settle()
            shoot("state-\(name)")
        }
        WorkRowProjectLinks.opensForSnapshot = { _ in true }
        await restart(.empty)
        focus([21])
        await open(21)
        shoot("state-no-projects-link")
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
