#if os(macOS) && DEBUG
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

/// Assistant 창 · Review 타일 상태 PNG (OA U1, 디자인 비교용): `-TF_EDGE_SHELL YES -TFSampleData -TFEdgeSnapshot <폴더> -TFEdgeSnapshotAssistant`
/// (+ `-TF_S4 YES -TF_C3 YES`로 Review 타일, `-TFSnapshotDark`, `-TFReduceMotion YES`). 화면 녹화 권한 없이 자기 창의 내용만 그려 데스크톱 견본 위에 실제 자리대로 붙인다
/// (창 그림자 · 유리 흐림은 담기지 않는다). 서버 응답은 가짜(`SampleAssistantGateway` · `SampleChatGateway`)라 렌더 fixture일 뿐이다: 실제 서버 · 계정 · AI 호출이 없다.
/// 남기는 것(`mac-edge-assistant-<이름>.png`): window-empty · window-m6(패널 옆 창, Figma M6) · window-menu(M6b) · menu-not-ready · menu-this-build · window-agent(대상 에이전트) ·
/// window-delivery(전달 여섯 단어) · window-history · window-long-title · window-long-text · window-chips-20 · window-chip-long · window-send-failed ·
/// window-offline · window-failed · window-unavailable · window-consent · window-blocked · windows-many · rail-* (Review 타일 상태) · tile-board(Open · Focus 포함) ·
/// menu-loading · menu-loaded-late · menu-failed · menu-another-mac (대상 목록 읽기 상태).
@MainActor
enum AssistantSnapshot {
    static func capture(_ edge: EdgeShellController, file: (String) -> URL, pause: @escaping (Double) async -> Void) async {
        func settle(_ seconds: Double = 0.8) async { await pause(seconds) }
        guard let runtime = edge.chat, let manager = edge.assistant else {
            print("AssistantSnapshot: Assistant 창이 없는 구성이다 (-TF_EDGE_SHELL YES 필요, -TFPanelChats는 빼야 한다) chat=\(edge.chat != nil) assistant=\(edge.assistant != nil) windowsEnabled=\(edge.shell.windowsEnabled)")
            return
        }
        manager.presents = true
        let sample = SampleAssistantGateway()
        runtime.chat.assistant = sample
        runtime.targets.gateway = sample
        await runtime.targets.refresh()
        let shell = edge.shell
        let chat = runtime.chat
        func shoot(_ name: String) { snapshot(edge, manager: manager, to: file("assistant-\(name)")) }
        func front() -> AssistantWindowController? { manager.registry.frontmost.flatMap { manager.controllers[$0] } }
        /// 새 계정이 막 로그인한 것처럼 저장소를 비우고 창을 모두 닫는다 (가짜 서버 시나리오를 바꾼 뒤)
        func restart(_ scenario: SampleChatGateway.Scenario) async {
            await runtime.sampleGateway?.setScenario(scenario)
            runtime.scope.accountLeft()
            runtime.chat.assistant = sample
            // 새 계정이 읽는 것처럼 대화 목록 · 대상 목록을 다시 읽는다
            await chat.refresh()
            await runtime.targets.refresh()
            await settle()
        }
        func sendWithoutWaiting(_ model: AssistantWindowModel, _ text: String) async {
            await model.send(text)
            await chat.settle()
            await settle()
        }

        // 데스크톱 한 장면: 패널은 닫고 레일 · 창만
        await restart(.full)
        let empty = manager.openNewWindow()
        await settle()
        shoot("window-empty")
        _ = empty

        // M6: 열린 패널(항목) 옆의 창 · auto 칩 + added 칩 · 대화
        manager.closeAll()
        shell.open(itemID: SampleData.id(10))
        await settle()
        if let id = manager.openWindow(for: SampleChatIDs.shape), let model = manager.controllers[id]?.model {
            model.addChip(AssistantChip(kind: .context, itemID: SampleChatIDs.shapeLaunch, origin: .added, title: "Lifetime plan section"))
            await chat.settle()
            await settle()
            shoot("window-m6")
            // M6b: 대상 메뉴가 알약 위에 열린다
            manager.controllers[id]?.toggleTargetMenu()
            await settle()
            shoot("window-menu")
            manager.controllers[id]?.targetMenu.dismiss()
            // 상태 단어: 아직 준비 안 된 에이전트 · 이 빌드에서는 못 돌린다
            sample.scenario = .notReady
            await runtime.targets.refresh()
            manager.controllers[id]?.toggleTargetMenu()
            await settle()
            shoot("menu-not-ready")
            manager.controllers[id]?.targetMenu.dismiss()
            sample.scenario = .standard
            await runtime.targets.refresh()
            runtime.targets.canRunAgents = { false }
            manager.controllers[id]?.toggleTargetMenu()
            await settle()
            shoot("menu-this-build")
            manager.controllers[id]?.targetMenu.dismiss()
            runtime.targets.canRunAgents = { true }
            // 읽는 도중에 연 메뉴는 Loading…이고, 읽기가 끝나면 같은 메뉴에 에이전트 행이 나타난다 (아래 끝은 알약 위 6pt 그대로, 위로 자란다)
            sample.scenario = .held
            runtime.targets.reset()
            manager.controllers[id]?.toggleTargetMenu()
            await settle(0.5)
            shoot("menu-loading")
            sample.scenario = .standard
            await settle(1.2)
            shoot("menu-loaded-late")
            manager.controllers[id]?.targetMenu.dismiss()
            // 읽지 못했다: 실패 줄과 Try again
            sample.scenario = .failing
            runtime.targets.reset()
            manager.controllers[id]?.toggleTargetMenu()
            await settle(0.8)
            shoot("menu-failed")
            manager.controllers[id]?.targetMenu.dismiss()
            // 같은 이름의 연결이 둘: 서버가 기기 이름을 주기 전에는 다음 행에 Another Mac
            sample.scenario = .twoMacs
            await runtime.targets.refresh()
            manager.controllers[id]?.toggleTargetMenu()
            await settle()
            shoot("menu-another-mac")
            manager.controllers[id]?.targetMenu.dismiss()
            sample.scenario = .standard
            await runtime.targets.refresh()
        }

        // 대상이 에이전트: 자리표시 "Message Codex" · auto 칩 " · Not sent"
        manager.closeAll()
        if let id = manager.openNewWindow(), let model = manager.controllers[id]?.model {
            if let option = runtime.targets.options.first(where: { $0.name == "Codex" }) { model.chooseTarget(option) }
            await settle()
            shoot("window-agent")
            // 전달 여섯 단어 (Not sent는 굵게). 같은 대화에 차례로 보낸다
            sample.deliveries = [
                AgentDelivery(state: .accepted), AgentDelivery(state: .sent), AgentDelivery(state: .outcomeUnknown), AgentDelivery(state: .queued, reason: .sessionBusy),
                AgentDelivery(state: .notSent, reason: .writeGateClosed), AgentDelivery(state: .expired),
            ]
            for text in ["Fix the pricing table", "Then the yearly card", "And the FAQ", "Run the checks", "Ship it", "Anything else?"] {
                await sendWithoutWaiting(model, text)
            }
            shoot("window-delivery")
            model.toggleHistory()
            await settle()
            shoot("window-history")
            model.toggleHistory()
        }

        // 긴 제목 · 긴 글 · 칩 20개 · 긴 칩 이름
        manager.closeAll()
        if let id = manager.openNewWindow(), let model = manager.controllers[id]?.model {
            sample.replyText = String(repeating: "Mina asked for Thursday and the refund window wording is still open, so the date moved. ", count: 6)
            await sendWithoutWaiting(model, "Can you check whether the Lifetime plan section is ready to ship before Thursday and tell me what is still blocking it, including the refund wording?")
            shoot("window-long-title")
            await sendWithoutWaiting(model, "And the Lifetime plan section? Please also list every open question we still have for Mina.")
            shoot("window-long-text")
        }
        manager.closeAll()
        if let id = manager.openNewWindow(), let model = manager.controllers[id]?.model {
            for n in 1...20 {
                model.addChip(AssistantChip(
                    kind: n.isMultiple(of: 5) ? .agentSession : .action, itemID: UUID(), origin: n == 1 ? .auto : .added,
                    title: n == 3 ? "A very long issue name that has to be cut in the middle so the number and the end stay together" : "Item \(n)", number: n == 3 ? 140 : nil
                ))
            }
            await settle()
            shoot("window-chips-20")
        }
        manager.closeAll()
        if let id = manager.openNewWindow(), let model = manager.controllers[id]?.model {
            model.addChip(AssistantChip(
                kind: .action, itemID: UUID(), origin: .added,
                title: "Rewrite pricing page copy for the 3-day trial and Lifetime plan so the refund wording stays readable at the end", number: 139
            ))
            await settle()
            shoot("window-chip-long")
        }

        // 막힌 입력 (비밀 질문이 열림): 입력이 꺼지고 자리표시가 이유를 말한다. 질문 카드는 D4b-m
        manager.closeAll()
        if let id = manager.openNewWindow(), let model = manager.controllers[id]?.model {
            model.blocked = ""
            await settle()
            shoot("window-blocked")
        }

        // 보내기 실패 · 상태 화면
        await restart(.sendFails)
        if let id = manager.openWindow(for: SampleChatIDs.copy), let model = manager.controllers[id]?.model {
            runtime.chat.assistant = nil
            await chat.refresh()
            await sendWithoutWaiting(model, "Use the shorter FAQ on both pricing pages")
            shoot("window-send-failed")
        }
        // 읽기 실패: 목록은 읽은 뒤에 서버가 끊긴다 (대화를 여는 때 글을 못 읽는다)
        for (name, scenario) in [("offline", SampleChatGateway.Scenario.offline), ("failed", .failed)] {
            await restart(.full)
            await runtime.sampleGateway?.setScenario(scenario)
            runtime.chat.assistant = nil
            if manager.openWindow(for: SampleChatIDs.copy) != nil {
                await chat.settle()
                await settle()
                shoot("window-\(name)")
            }
        }
        // 쓰기가 막힌 서버: 보내 봐야 알게 된다 (기능 꺼짐 · 동의 전)
        for (name, scenario) in [("unavailable", SampleChatGateway.Scenario.featureOff), ("consent", .consentNeeded)] {
            await restart(scenario)
            runtime.chat.assistant = nil
            if let id = manager.openWindow(for: SampleChatIDs.copy), let model = manager.controllers[id]?.model {
                await chat.settle()
                await sendWithoutWaiting(model, "Use the shorter FAQ")
                shoot("window-\(name)")
            }
        }
        runtime.chat.assistant = sample

        // 창 여러 개: 24pt씩 아래 · 왼쪽으로 겹쳐 열린다
        await restart(.full)
        shell.open(itemID: SampleData.id(10))
        for conversation in [SampleChatIDs.copy, SampleChatIDs.shape, SampleChatIDs.blank] { _ = manager.openWindow(for: conversation) }
        await settle(2)
        shoot("windows-many")
        manager.closeAll()
        _ = front()

        // 레일의 Review 타일
        await captureTile(edge, manager: manager, file: file, pause: pause)
        await captureTileBoard(edge, to: file("assistant-tile-board"))
    }

    /// 레일의 Review 타일 상태: needs-you × 숨김 · 펼침 · 호버 · Open, 없음 (바뀐 것만 남아도 타일이 없다)
    private static func captureTile(_ edge: EdgeShellController, manager: AssistantWindowManager, file: (String) -> URL, pause: @escaping (Double) async -> Void) async {
        func settle(_ seconds: Double = 0.8) async { await pause(seconds) }
        let shell = edge.shell
        guard shell.summary != nil, shell.review != nil, let gateway = AppRuntime.sampleSummaryGateway else {
            print("AssistantSnapshot: Review 타일은 -TF_S4 YES -TF_C3 YES가 필요하다")
            return
        }
        func rail(_ name: String) { snapshot(edge, manager: manager, to: file("assistant-rail-\(name)")) }
        // 레일만: 패널 · 창은 닫는다 (숨은 레일 · 호버 툴팁은 패널이 닫혀 있을 때의 모습이다)
        manager.closeAll()
        shell.dismiss()
        // needs you: 견본의 확인 요청 하나만 남긴다 (일 링 한 개와 같이)
        edge.workOverride = { work in
            var work = work
            work.review = Array(work.review.prefix(1))
            return work
        }
        gateway.reset(.changes)
        await edge.shell.summary?.refresh()
        await settle()
        shell.pointer(inside: false)
        await settle()
        rail("needs-you-hidden")
        shell.pointer(inside: true)
        await settle(1)
        rail("needs-you-expanded")
        shell.hover(tile: true)
        await settle()
        rail("needs-you-hover")
        shell.hover(tile: false)
        shell.openReviewTile()
        await settle()
        rail("needs-you-open")
        shell.dismiss()
        // 타일 없음: 확인 요청이 없으면 바뀐 것이 남아 있어도 타일이 없다 (OA U2b). 링이 위로 올라온다
        edge.workOverride = { work in
            var work = work
            work.review = []
            return work
        }
        await settle()
        shell.pointer(inside: true)
        await settle(1)
        rail("none-expanded")
        shell.pointer(inside: false)
        edge.workOverride = nil
    }

    /// 타일 상태판: Needs you × Default · Hover · Open · Focus (Figma 35:1179와 같은 배치), 검은 레일 위
    private static func captureTileBoard(_ edge: EdgeShellController, to url: URL) async {
        let board = HStack(spacing: 40) {
            ReviewTile(label: "Review", expanded: true) {}
            ReviewTile(label: "Review", expanded: true, highlighted: true) {}
            ReviewTile(label: "Review", expanded: true, open: true) {}
            ReviewTile(label: "Review", expanded: true, focused: true) {}
            ReviewTile(label: "Review", expanded: false, notchShift: 9.5) {}
        }
        .padding(40)
        .background(TFColor.bezelBase)
        .environment(\.colorScheme, NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light)
        let renderer = ImageRenderer(content: board)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    // MARK: 담기

    /// 보이는 창(레일 · 패널 · Assistant 창 · 대상 메뉴)을 화면 자리대로 데스크톱 견본 위에 그린다
    static func snapshot(_ edge: EdgeShellController, manager: AssistantWindowManager, to url: URL) {
        var windows: [NSWindow] = [edge.panel.panel, edge.rail.panel].filter(\.isVisible)
        // 연 차례대로, 앞 창은 마지막에 그린다
        let front = manager.registry.frontmost
        let order = manager.registry.windowIDs.filter { $0 != front } + (front.map { [$0] } ?? [])
        for controller in order.compactMap({ manager.controllers[$0] }) where controller.panel.isVisible {
            windows.append(controller.panel)
            if let menu = controller.targetMenu.window, menu.isVisible { windows.append(menu) }
        }
        guard let first = windows.first else { return }
        let margin: CGFloat = 24
        let tooltip = railTooltip(edge)
        var bounds = windows.map(\.frame).reduce(first.frame) { $0.union($1) }
        if let tooltip { bounds = bounds.union(tooltip.frame) }
        let canvas = CGRect(x: bounds.minX - margin, y: bounds.minY - margin, width: bounds.width + 2 * margin, height: bounds.height + 2 * margin)
        let scale = first.backingScaleFactor
        guard let context = CGContext(
            data: nil, width: Int(canvas.width * scale), height: Int(canvas.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        context.scaleBy(x: scale, y: scale)
        drawDesktop(in: context, size: canvas.size)
        // 뒤에서 앞으로: 레일 · 패널 → 창 → 메뉴
        for window in windows {
            guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let image = rep.cgImage else { continue }
            context.saveGState()
            context.setAlpha(window.alphaValue)
            context.draw(image, in: CGRect(x: window.frame.minX - canvas.minX, y: window.frame.minY - canvas.minY, width: window.frame.width, height: window.frame.height))
            context.restoreGState()
        }
        if let tooltip {
            context.draw(tooltip.image, in: CGRect(x: tooltip.frame.minX - canvas.minX, y: tooltip.frame.minY - canvas.minY, width: tooltip.frame.width, height: tooltip.frame.height))
        }
        guard let image = context.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = canvas.size
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// 레일 툴팁 (타일 호버): 레일 창이 아니라 자기 창이라 따로 그려 타일 왼쪽 14pt에 붙인다 (`RailTooltipController`와 같은 자리)
    private static func railTooltip(_ edge: EdgeShellController) -> (image: CGImage, frame: CGRect)? {
        let shell = edge.shell
        guard let text = shell.tooltip, shell.hoveredTile, edge.rail.panel.isVisible else { return nil }
        let layout = EdgeRailLayout(
            notchCount: shell.notch.count, restCount: shell.rest.count, expanded: shell.isExpanded, idle: shell.isIdle, controls: shell.controls, tile: true
        )
        guard let anchor = layout.tileFrame else { return nil }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let renderer = ImageRenderer(content: RailTooltipView(title: text.title, detail: text.detail).environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = edge.rail.panel.backingScaleFactor
        guard let image = renderer.cgImage else { return nil }
        let size = CGSize(width: CGFloat(image.width) / renderer.scale, height: CGFloat(image.height) / renderer.scale)
        let rail = edge.rail.panel.frame
        let origin = CGPoint(x: rail.minX + anchor.minX - 14 - size.width, y: rail.maxY - anchor.midY - size.height / 2)
        return (image, CGRect(origin: origin, size: size))
    }

    private static func drawDesktop(in context: CGContext, size: CGSize) {
        let colors = ["7d8794", "857a80", "857968", "4a3c3e"].map { hex -> CGColor in
            let value = UInt32(hex, radix: 16) ?? 0
            return CGColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        }
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 0.42, 0.62, 1]) else { return }
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: .zero, options: [])
    }
}

/// 견본 가짜 서버(`AssistantGateway`): 대상 목록 · 대상을 지정한 만들기 · 보내기. 실제 서버 · 계정 · AI 호출이 없다
final class SampleAssistantGateway: AssistantGateway, @unchecked Sendable {
    enum Scenario {
        /// Claude Code는 Unsupported, Codex는 Read only (D1d 초기값)
        case standard
        /// Sign in needed · Not connected
        case notReady
        /// 읽기가 끝나지 않는다 (다른 시나리오로 바꾸면 끝난다)
        case held
        /// 읽지 못한다 (오프라인)
        case failing
        /// 같은 adapter의 연결이 둘 (기기 이름을 서버가 아직 주지 않는다)
        case twoMacs
    }

    private let lock = NSLock()
    private var _scenario = Scenario.standard
    private var _deliveries: [AgentDelivery] = []
    private var _replyText = "Noted."
    private var counter = 0

    var scenario: Scenario {
        get { lock.withLock { _scenario } }
        set { lock.withLock { _scenario = newValue } }
    }

    /// 에이전트 보내기에 차례로 돌려줄 전달 표시 (다 쓰면 Sent)
    var deliveries: [AgentDelivery] {
        get { lock.withLock { _deliveries } }
        set { lock.withLock { _deliveries = newValue } }
    }

    var replyText: String {
        get { lock.withLock { _replyText } }
        set { lock.withLock { _replyText = newValue } }
    }

    static let claude = UUID(uuidString: "A3330000-0000-4000-8000-000000000001")!
    static let codex = UUID(uuidString: "A3330000-0000-4000-8000-000000000002")!
    static let otherCodex = UUID(uuidString: "A3330000-0000-4000-8000-000000000003")!

    func targets() async throws -> [AssistantTarget] {
        let claudeRow = { (state: AgentTargetState) in
            AssistantTarget.agent(.init(adapter: "agent:claude-code", displayName: "Claude Code", connectionID: Self.claude, state: state, access: nil))
        }
        switch scenario {
        case .standard:
            return [
                .taskforce, claudeRow(.unsupported),
                .agent(.init(adapter: "agent:codex", displayName: "Codex", connectionID: Self.codex, state: .ready, access: .readOnly)),
            ]
        case .notReady:
            return [
                .taskforce, claudeRow(.signInNeeded),
                .agent(.init(adapter: "agent:codex", displayName: "Codex", connectionID: nil, state: .notConnected, access: .readOnly)),
            ]
        case .twoMacs:
            return [
                .taskforce, claudeRow(.unsupported),
                .agent(.init(adapter: "agent:codex", displayName: "Codex", connectionID: Self.codex, state: .ready, access: .write)),
                .agent(.init(adapter: "agent:codex", displayName: "Codex", connectionID: Self.otherCodex, state: .unreachable, access: .write)),
            ]
        case .failing:
            throw URLError(.notConnectedToInternet)
        case .held:
            while scenario == .held { try await Task.sleep(for: .milliseconds(40)) }
            return try await targets()
        }
    }

    func createConversation(id: UUID, title: String?, contextID: UUID?, target: ChatTarget) async throws -> ChatCreatedConversation {
        var connection: UUID?
        if case .agent(let id, _) = target { connection = id }
        return ChatCreatedConversation(
            conversation: ChatConversation(id: id, title: title, contextID: contextID, createdAt: Date()),
            target: connection.map { ChatConversationTarget(kind: .agent, agentConnectionID: $0) } ?? .taskforce
        )
    }

    private func message(_ conversation: UUID, seq: Int, role: ChatRole, text: String, cmid: UUID?, replyTo: UUID? = nil) -> ChatMessage {
        ChatMessage(id: UUID(), conversationID: conversation, seq: seq, role: role, clientMessageID: cmid, text: text, createdAt: Date(), replyTo: replyTo)
    }

    private func nextSeq() -> Int {
        lock.withLock {
            counter += 1
            return counter
        }
    }

    func postChatMessage(conversationID: UUID, clientMessageID: UUID, text: String, attachments: [ChatAttachment]) async throws -> ChatPostedMessage {
        let n = nextSeq()
        let user = message(conversationID, seq: 2 * n - 1, role: .user, text: text, cmid: clientMessageID)
        return ChatPostedMessage(message: user, reply: message(conversationID, seq: 2 * n, role: .assistant, text: replyText, cmid: nil, replyTo: user.id))
    }

    func postAgentMessage(conversationID: UUID, clientMessageID: UUID, text: String, attachments: [ChatAttachment]) async throws -> AgentPostedMessage {
        let n = nextSeq()
        let delivery: AgentDelivery = lock.withLock { _deliveries.isEmpty ? AgentDelivery(state: .sent) : _deliveries.removeFirst() }
        return AgentPostedMessage(message: message(conversationID, seq: n, role: .user, text: text, cmid: clientMessageID), delivery: delivery)
    }
}
#endif
