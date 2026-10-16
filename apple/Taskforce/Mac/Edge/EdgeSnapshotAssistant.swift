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

// MARK: - 에이전트 대화 견본 (OA D4a-1)

/// 에이전트 대화의 견본 서버: Assistant 창 · 세션 패널이 서버처럼 읽고 쓴다 (전달 줄 · Send again · 후보 고르기 · Stop · Open in Terminal · Resume here).
/// 서버 계산(전달 상태 · 취소 · external)은 서버가 하는 일을 흉내 낼 뿐인 **렌더 fixture**다: 실제 서버 · 계정 · AI 호출 · `claude` 실행이 없다.
/// 견본 앱(`-TFEdgeSnapshotIssues -TFEdgeSnapshotAgentChat`)과 격리 Mac 호스트 시험이 같이 쓴다
final class AgentChatSampleGateway: ChatGateway, IssueScreensGateway, AssistantGateway, AgentConversationGateway, AgentSessionRequests, @unchecked Sendable {
    static let shared = AgentChatSampleGateway()

    struct State {
        var conversations: [ChatConversation] = []
        var messages: [UUID: [ChatMessage]] = [:]
        var deliveries: [UUID: AgentDelivery] = [:]
        var sessions: AgentSessionSnapshot = .empty
        var targetState: AgentTargetState = .ready
        /// 대상 목록의 Claude Code 행 이름 (긴 이름 장면)
        var agentName = "Claude Code"
    }

    struct Failure: Error {}

    private let lock = NSLock()
    private var _state = State()
    private var _calls: [String] = []
    private var _postDeliveries: [AgentDelivery] = []
    private var _stopMayContinue = false
    private var _stopConfirms = false
    private var _deliverFailure: Error?
    private var _deliverReply = AgentDelivery(state: .queued, reason: .sessionBusy)
    private var _openFailure: Error?
    private var _resumeFailure: Error?
    private var _posted = 0

    var state: State {
        get { lock.withLock { _state } }
        set { lock.withLock { _state = newValue } }
    }

    func update(_ change: (inout State) -> Void) {
        lock.withLock { change(&_state) }
    }

    /// 부른 요청들 (서버 route 이름 + 인자의 일부)
    var calls: [String] { lock.withLock { _calls } }
    func calls(prefix: String) -> [String] { calls.filter { $0.hasPrefix(prefix) } }
    private func record(_ call: String) { lock.withLock { _calls.append(call) } }

    /// 보내기에 차례로 돌려줄 전달 표시 (다 쓰면 Sent)
    var postDeliveries: [AgentDelivery] {
        get { lock.withLock { _postDeliveries } }
        set { lock.withLock { _postDeliveries = newValue } }
    }
    /// Stop 응답: `processes: may_continue` · 서버가 바로 확인한다 (`confirmed`)
    var stopMayContinue: Bool {
        get { lock.withLock { _stopMayContinue } }
        set { lock.withLock { _stopMayContinue = newValue } }
    }
    /// Send again(`deliver`)를 이 오류로 거절한다 (동의 철회 · 409 …): nil이면 서버가 받아들인다
    var deliverFailure: Error? {
        get { lock.withLock { _deliverFailure } }
        set { lock.withLock { _deliverFailure = newValue } }
    }

    var stopConfirms: Bool {
        get { lock.withLock { _stopConfirms } }
        set { lock.withLock { _stopConfirms = newValue } }
    }
    /// Send again이 돌려줄 전달 표시 (requeued)
    var deliverReply: AgentDelivery {
        get { lock.withLock { _deliverReply } }
        set { lock.withLock { _deliverReply = newValue } }
    }
    var openFailure: Error? {
        get { lock.withLock { _openFailure } }
        set { lock.withLock { _openFailure = newValue } }
    }
    var resumeFailure: Error? {
        get { lock.withLock { _resumeFailure } }
        set { lock.withLock { _resumeFailure = newValue } }
    }

    // MARK: 읽기 (ChatGateway)

    func conversations() async throws -> [ChatConversation] { state.conversations }
    func lastMessages(conversationIDs: [UUID]) async throws -> [UUID: ChatMessage] { [:] }
    func messages(conversationID: UUID) async throws -> [ChatMessage] { state.messages[conversationID] ?? [] }
    func message(id: UUID) async throws -> ChatMessage? { nil }
    func workContexts() async throws -> [WorkContext] { IssueSnapshotData.baseProjects }
    func currentMemoryItems() async throws -> [MemoryItem] { [] }
    func memoryItems(ids: [UUID]) async throws -> [MemoryItem] { [] }
    func memorySource(id: UUID) async throws -> MemorySource? { nil }

    private func off<T>() throws -> T { throw APIError.server(status: 404, code: .notFound, message: APIError.featureOffMessage) }
    func createConversation(id: UUID, title: String?, contextID: UUID?) async throws -> ChatConversation { try off() }
    func updateConversation(id: UUID, contextID: UUID?) async throws -> ChatConversation { try off() }
    func postChatMessage(conversationID: UUID, clientMessageID: UUID, text: String) async throws -> ChatPostedMessage { try off() }
    func confirmMemory(id: UUID, expectedVersion: Int) async throws -> MemoryItem { try off() }
    func editMemory(id: UUID, edit: MemoryEdit) async throws -> MemoryItem { try off() }
    func forgetMemory(id: UUID, expectedVersion: Int) async throws -> MemoryItem { try off() }
    func moveMemory(id: UUID, expectedVersion: Int, to target: MemoryTarget) async throws -> MemoryItem { try off() }

    // MARK: IssueScreensGateway (번호 · 이슈 상세는 U2 견본 그대로, 세션은 이 견본의 상태)

    func actionNumbers(ids: [UUID]) async throws -> [UUID: Int] { try await IssueSampleGateway.shared.actionNumbers(ids: ids) }
    func issueDetail(id: UUID) async throws -> ActionDetail { try await IssueSampleGateway.shared.issueDetail(id: id) }
    func agentSessionSnapshot() async throws -> AgentSessionSnapshot { state.sessions }

    // MARK: AssistantGateway

    static let claudeConnection = IssueSnapshotData.claude
    static let codexConnection = IssueSnapshotData.codex

    func targets() async throws -> [AssistantTarget] {
        let ready = state.targetState
        return [
            .taskforce,
            .agent(.init(adapter: "agent:claude-code", displayName: state.agentName, connectionID: Self.claudeConnection, state: ready, access: .write)),
            .agent(.init(adapter: "agent:codex", displayName: "Codex", connectionID: Self.codexConnection, state: .ready, access: .write)),
        ]
    }

    func createConversation(id: UUID, title: String?, contextID: UUID?, target: ChatTarget) async throws -> ChatCreatedConversation {
        record("create:\(id.uuidString)")
        var connection: UUID?
        if case .agent(let connectionID, _) = target { connection = connectionID }
        let row = ChatConversation(
            id: id, title: title, contextID: contextID, createdAt: Date(), target: ChatConversationTarget(kind: connection == nil ? .taskforce : .agent, agentConnectionID: connection)
        )
        update { $0.conversations.append(row) }
        return ChatCreatedConversation(conversation: row, target: row.target)
    }

    func postChatMessage(conversationID: UUID, clientMessageID: UUID, text: String, attachments: [ChatAttachment]) async throws -> ChatPostedMessage {
        throw Failure()
    }

    func postAgentMessage(conversationID: UUID, clientMessageID: UUID, text: String, attachments: [ChatAttachment]) async throws -> AgentPostedMessage {
        record("postAgent:\(conversationID.uuidString):\(text)")
        let delivery: AgentDelivery = lock.withLock { _postDeliveries.isEmpty ? AgentDelivery(state: .sent) : _postDeliveries.removeFirst() }
        let message: ChatMessage = lock.withLock {
            _posted += 1
            let seq = (_state.messages[conversationID]?.map(\.seq).max() ?? 0) + 1
            let message = ChatMessage(
                id: IssueSnapshotData.id(1000 + _posted, "a5a50000"), conversationID: conversationID, seq: seq, role: .user, clientMessageID: clientMessageID, text: text,
                createdAt: Date()
            )
            _state.messages[conversationID, default: []].append(message)
            _state.deliveries[message.id] = delivery
            return message
        }
        let sessionID = state.conversations.first { $0.id == conversationID }?.target.agentSessionID
        // 서버는 열린 task가 없으면 새 턴을 시작한다: 세션을 다시 읽어야 Stop 원이 선다
        if delivery.state == .sent { startTurnIfIdle(in: conversationID) }
        return AgentPostedMessage(
            message: message, delivery: delivery,
            agentTask: sessionID.map { AgentTaskRef(id: IssueSnapshotData.task(1), state: .dispatched, agentSessionID: $0) }
        )
    }

    /// 서버가 그 대화의 세션에서 새 턴을 시작한다 (열린 task가 없을 때)
    private func startTurnIfIdle(in conversationID: UUID) {
        guard let sessionID = state.conversations.first(where: { $0.id == conversationID })?.target.agentSessionID else { return }
        update { state in
            guard !state.sessions.tasks.contains(where: { $0.agentSessionID == sessionID && $0.isOpen }) else { return }
            let turn = (state.sessions.tasks.filter { $0.agentSessionID == sessionID }.compactMap(\.turnSeq).max() ?? 0) + 1
            state.sessions.tasks.append(AgentTaskRecord(
                agentSessionID: sessionID, runID: IssueSnapshotData.task(1), turnSeq: turn, state: .dispatched, lastLiveState: nil, cancelRequestedAt: nil
            ))
        }
    }

    // MARK: AgentConversationGateway

    func deliver(conversationID: UUID, messageIDs: [UUID]?) async throws -> AgentDeliverResponse {
        record("deliver:\((messageIDs ?? []).map(\.uuidString).joined(separator: ","))")
        if let failure = deliverFailure { throw failure }
        let reply = deliverReply
        if reply.state == .sent { startTurnIfIdle(in: conversationID) }
        let ids = messageIDs ?? state.deliveries.filter { [.notSent, .expired].contains($0.value.state) }.map(\.key)
        var results: [AgentDeliverResult] = []
        for id in ids {
            if let delivery = state.deliveries[id], [.notSent, .expired].contains(delivery.state) {
                update { $0.deliveries[id] = reply }
                results.append(AgentDeliverResult(messageID: id, result: .requeued, delivery: reply))
            } else {
                results.append(AgentDeliverResult(messageID: id, result: .skipped, skippedReason: .notEligible, delivery: state.deliveries[id]))
            }
        }
        return AgentDeliverResponse(messages: results)
    }

    func setReferent(conversationID: UUID, messageID: UUID, actionID: UUID) async throws -> AgentPostedMessage {
        record("referent:\(messageID.uuidString):\(actionID.uuidString)")
        let sent = AgentDelivery(state: .sent)
        update { $0.deliveries[messageID] = sent }
        let message = state.messages[conversationID]?.first { $0.id == messageID }
            ?? ChatMessage(id: messageID, conversationID: conversationID, seq: 1, role: .user, text: "", createdAt: Date())
        return AgentPostedMessage(message: message, delivery: sent)
    }

    func stopConversation(id: UUID) async throws -> AgentStopResponse {
        record("stopConversation:\(id.uuidString)")
        guard let session = state.conversations.first(where: { $0.id == id })?.target.agentSessionID else { return AgentStopResponse(tasks: []) }
        return stopTasks(of: session)
    }

    func deliveries(conversationID: UUID, sinceSeq: Int?) async throws -> ConversationDeliveryResponse {
        record("deliveries:\(conversationID.uuidString):\(sinceSeq.map(String.init) ?? "nil")")
        let current = state
        let rows = (current.messages[conversationID] ?? []).filter { $0.role.isUser && $0.seq > (sinceSeq ?? 0) }.sorted { $0.seq < $1.seq }.prefix(100)
        return ConversationDeliveryResponse(messages: rows.map { row in
            ConversationDeliveryResponse.Entry(messageID: row.id, seq: row.seq, delivery: current.deliveries[row.id] ?? AgentDelivery(state: .accepted))
        })
    }

    // MARK: AgentSessionRequests

    func openExternal(sessionID: UUID) async throws -> AgentSessionResponse {
        record("openExternal:\(sessionID.uuidString)")
        if let failure = openFailure { throw failure }
        return AgentSessionResponse(session: setStatus(sessionID, .external, event: "Opened in Terminal"))
    }

    func resumeHere(sessionID: UUID) async throws -> AgentResumeResponse {
        record("resumeHere:\(sessionID.uuidString)")
        if let failure = resumeFailure { throw failure }
        let row = setStatus(sessionID, .bound, event: "Resumed here")
        // 대기 메시지를 순서대로 시작한다
        var started: UUID?
        update { state in
            for (id, delivery) in state.deliveries where delivery.state == .queued && delivery.reason == .sessionExternal {
                state.deliveries[id] = AgentDelivery(state: .sent)
                started = started ?? id
            }
        }
        return AgentResumeResponse(session: row, startedMessageID: started)
    }

    func stopSession(id: UUID) async throws -> AgentStopResponse {
        record("stopSession:\(id.uuidString)")
        return stopTasks(of: id)
    }

    private func setStatus(_ sessionID: UUID, _ status: AgentSessionStatus, event: String) -> AgentSessionRow {
        var row = AgentSessionRow(id: sessionID, connectionID: Self.claudeConnection, displayName: "", status: status, lastTurnSeq: 1, updatedAt: Date())
        update { state in
            guard let index = state.sessions.sessions.firstIndex(where: { $0.id == sessionID }) else { return }
            let old = state.sessions.sessions[index]
            state.sessions.sessions[index] = AgentSessionRecord(
                id: old.id, connectionID: old.connectionID, displayName: old.displayName, status: status, isPendingFirstTurn: old.isPendingFirstTurn, lastTurnSeq: old.lastTurnSeq,
                createdAt: old.createdAt, updatedAt: Date()
            )
            row = AgentSessionRow(id: old.id, connectionID: old.connectionID, displayName: old.displayName, status: status, lastTurnSeq: old.lastTurnSeq, updatedAt: Date())
            // 서버가 세션 단위 사건을 대화마다 한 줄 쓴다 (role 'event')
            for conversation in state.sessions.conversations where conversation.agentSessionID == sessionID {
                let existing = state.messages[conversation.id] ?? []
                let seq = (existing.map(\.seq).max() ?? 0) + 1
                let message = ChatMessage(id: UUID(), conversationID: conversation.id, seq: seq, role: .event, text: event, createdAt: Date())
                state.messages[conversation.id] = existing + [message]
                // 터미널에 넘긴 세션의 대기 메시지는 "Session is in Terminal"
                if status == .external {
                    for message in existing where message.role.isUser {
                        if let delivery = state.deliveries[message.id], delivery.state == .queued {
                            state.deliveries[message.id] = AgentDelivery(state: .queued, reason: .sessionExternal)
                        }
                    }
                }
            }
        }
        return row
    }

    private func stopTasks(of sessionID: UUID) -> AgentStopResponse {
        let (confirms, mayContinue) = (stopConfirms, stopMayContinue)
        var results: [AgentStopResult] = []
        update { state in
            for index in state.sessions.tasks.indices where state.sessions.tasks[index].agentSessionID == sessionID && state.sessions.tasks[index].isOpen {
                let old = state.sessions.tasks[index]
                state.sessions.tasks[index] = AgentTaskRecord(
                    agentSessionID: old.agentSessionID, runID: old.runID, turnSeq: old.turnSeq, state: confirms ? .cancelled : old.state, lastLiveState: old.lastLiveState,
                    cancelRequestedAt: confirms ? nil : Date()
                )
                results.append(AgentStopResult(agentTaskID: UUID(), cancel: confirms ? .confirmed : .requestedOnly, processes: mayContinue ? .mayContinue : nil))
            }
        }
        return AgentStopResponse(tasks: results)
    }
}


/// 에이전트 대화 견본의 장면들 (OA D4a-1, 디자인 OA-3 · OA-4 문구 그대로 + 계약 6장의 DZ 상태): 한 장면 = 대화 하나 + 그 세션의 상태
enum AgentChatSampleData {
    static let conversationID = IssueSnapshotData.conversation(1)
    static let sessionID = IssueSnapshotData.session(1)
    static let otherSessionID = IssueSnapshotData.session(2)
    static let otherConversationID = IssueSnapshotData.conversation(2)
    /// 이 Mac의 bridge id · 다른 Mac의 bridge id (알약은 이 Mac의 세션에만 보인다, OA D4a-03)
    static let thisMacBridge = IssueSnapshotData.id(1, "b1d6e000")
    static let otherMacBridge = IssueSnapshotData.id(2, "b1d6e000")
    static let referentAction = IssueSnapshotData.issue(139)
    static let referentActions = [IssueSnapshotData.issue(139), IssueSnapshotData.issue(143), IssueSnapshotData.issue(144)]

    /// 잘린 답의 서버 열쇠와 이 Mac 원장에 있는 전문 (View full)
    static let truncatedKey = "agent-message:77777777-0000-4000-8000-000000000001:" + String(repeating: "ab", count: 32)
    static let fullText = (
        "Draft v2 covers the Pro monthly, Pro yearly and Lifetime sections. The trial wording follows the Oct 9 decision, the refund window keeps the three-day limit, "
            + "and the price table now lists every plan in the same order as the checkout page.\n\n"
    ) + String(repeating: "The yearly card shows the first month and the Lifetime price is shown once at the bottom so it never reads as a recurring charge. ", count: 24)

    static func fullText(forKey key: String) -> String? { key == truncatedKey ? fullText : nil }

    /// 한 대화의 글 만들기
    struct Thread {
        let conversationID: UUID
        var messages: [ChatMessage] = []
        var deliveries: [UUID: AgentDelivery] = [:]
        private var seq = 0

        init(_ conversationID: UUID = AgentChatSampleData.conversationID) {
            self.conversationID = conversationID
        }

        @discardableResult
        mutating func user(_ text: String, _ delivery: AgentDelivery?) -> ChatMessage {
            seq += 1
            let message = ChatMessage(
                id: IssueSnapshotData.id(seq, "a6a60000"), conversationID: conversationID, seq: seq, role: .user, clientMessageID: IssueSnapshotData.id(seq, "a7a70000"), text: text,
                createdAt: Date().addingTimeInterval(Double(seq - 60) * 20)
            )
            messages.append(message)
            deliveries[message.id] = delivery
            return message
        }

        mutating func agent(_ text: String, truncated: Bool = false) {
            seq += 1
            messages.append(ChatMessage(
                id: IssueSnapshotData.id(seq, "a8a80000"), conversationID: conversationID, seq: seq, role: .assistant, text: text, createdAt: Date().addingTimeInterval(Double(seq - 60) * 20),
                content: ChatMessageContent(truncated: truncated), externalEventID: truncated ? AgentChatSampleData.truncatedKey : nil
            ))
        }

        mutating func event(_ text: String) {
            seq += 1
            messages.append(ChatMessage(
                id: IssueSnapshotData.id(seq, "a9a90000"), conversationID: conversationID, seq: seq, role: .event, text: text, createdAt: Date().addingTimeInterval(Double(seq - 60) * 20)
            ))
        }
    }

    /// 대화 하나와 그 세션. `task`가 nil이면 task 없음
    static func state(
        _ thread: Thread, status: AgentSessionStatus = .bound, task: AgentTaskState? = .idle, cancelRequested: Bool = false, bridge: UUID? = thisMacBridge,
        targetState: AgentTargetState = .ready, name: String = "Pricing copy draft", agentName: String = "Claude Code"
    ) -> AgentChatSampleGateway.State {
        let now = Date()
        let row = ChatConversation(
            id: thread.conversationID, title: "Pricing copy draft", createdAt: now.addingTimeInterval(-3_600), lastMessageAt: now.addingTimeInterval(-60),
            target: ChatConversationTarget(kind: .agent, agentConnectionID: IssueSnapshotData.claude, agentSessionID: sessionID)
        )
        var state = AgentChatSampleGateway.State()
        state.conversations = [row]
        state.messages = [thread.conversationID: thread.messages]
        state.deliveries = thread.deliveries
        state.targetState = targetState
        state.agentName = agentName
        state.sessions = AgentSessionSnapshot(
            sessions: [AgentSessionRecord(
                id: sessionID, connectionID: IssueSnapshotData.claude, displayName: name, status: status, lastTurnSeq: task == nil ? 0 : 1,
                createdAt: now.addingTimeInterval(-3_600), updatedAt: now.addingTimeInterval(-30)
            )],
            tasks: task.map { [AgentTaskRecord(agentSessionID: sessionID, runID: IssueSnapshotData.task(1), turnSeq: 1, state: $0, lastLiveState: nil, cancelRequestedAt: cancelRequested ? now : nil)] } ?? [],
            runs: [AgentSessionRunRecord(id: IssueSnapshotData.task(1), agentSessionID: sessionID, actionID: IssueSnapshotData.issue(139))],
            connections: [
                AgentConnectionRecord(id: IssueSnapshotData.claude, adapter: "agent:claude-code", bridgeID: bridge),
                AgentConnectionRecord(id: IssueSnapshotData.codex, adapter: "agent:codex", bridgeID: otherMacBridge),
            ],
            conversations: [AgentSessionConversationRecord(id: thread.conversationID, agentSessionID: sessionID)]
        )
        return state
    }

    // MARK: 장면 (Assistant 창)

    /// Figma OA-4 In flight (60:1596): Received · Sent · Unknown
    static func inFlight() -> AgentChatSampleGateway.State {
        var thread = Thread()
        thread.user("Draft the Pro and Lifetime sections", AgentDelivery(state: .accepted))
        thread.agent("Opened pricing.mdx. Drafting the Pro section first.")
        thread.user("Keep the trial terms exact", AgentDelivery(state: .sent))
        thread.user("Add the refund window wording", AgentDelivery(state: .outcomeUnknown))
        return state(thread, task: .idle)
    }

    /// Figma OA-4 Waiting (60:1666): Queued · Mac is offline, Not sent + reason + Send again, Expired
    static func waiting() -> AgentChatSampleGateway.State {
        var thread = Thread()
        thread.user("Add the refund window wording", AgentDelivery(state: .queued))
        thread.user("Check the price table", AgentDelivery(state: .notSent, reason: .signInNeeded))
        thread.user("Draft the Lifetime section", AgentDelivery(state: .notSent, reason: .writeGateClosed))
        thread.user("Use the Oct 9 trial terms", AgentDelivery(state: .expired))
        return state(thread, task: .idle, targetState: .unreachable)
    }

    /// 이유 · 상태 전부 (계약 4장 표): DS에 있는 말 + 승인 전 새 문구 후보 (견본에서만 보인다)
    static func reasons() -> AgentChatSampleGateway.State {
        var thread = Thread()
        thread.user("Not connected", AgentDelivery(state: .notSent, reason: .notConnected))
        thread.user("Unsupported", AgentDelivery(state: .notSent, reason: .unsupported))
        thread.user("Unsupported version (new)", AgentDelivery(state: .notSent, reason: .versionUnsupported))
        thread.user("Usage limit reached (new)", AgentDelivery(state: .notSent, reason: .usageLimited))
        thread.user("Session did not start (new)", AgentDelivery(state: .notSent, reason: .spawnFailed))
        thread.user("Not received (new)", AgentDelivery(state: .notSent, reason: .notReceived))
        thread.user("Session closed (new, no Send again)", AgentDelivery(state: .notSent, reason: .sessionClosed))
        thread.user("Cancelled by Stop (new)", AgentDelivery(state: .cancelled))
        thread.user("No reason at all", AgentDelivery(state: .notSent))
        return state(thread, task: .idle)
    }

    /// Queued의 이유들 · needs_referent
    static func queued() -> AgentChatSampleGateway.State {
        var thread = Thread()
        thread.user("Waiting behind a turn", AgentDelivery(state: .queued, reason: .sessionBusy))
        thread.user("Session is in Terminal", AgentDelivery(state: .queued, reason: .sessionExternal))
        thread.user("A question is open", AgentDelivery(state: .queued, reason: .questionOpen))
        thread.user("Which issue is this about?", AgentDelivery(
            state: .needsReferent, candidates: [
                AgentReferentCandidate(actionID: referentActions[0], title: "Rewrite pricing page copy for the 3-day trial and Lifetime plan"),
                AgentReferentCandidate(actionID: referentActions[1], title: "Ask Mina to confirm the refund window wording"),
                AgentReferentCandidate(actionID: referentActions[2], title: "Apple sign-in on Mac next to Google"),
            ]
        ))
        return state(thread, task: .running)
    }

    /// 긴 이유 줄: 에이전트 이름이 길어 "Not signed in to …"가 오른쪽 맞춤으로 감싸고 링크가 다음 줄로 내려간다
    static func longReason() -> AgentChatSampleGateway.State {
        var thread = Thread()
        thread.user("Check the price table", AgentDelivery(state: .notSent, reason: .signInNeeded))
        return state(thread, task: .idle, agentName: "Claude Code on the design team's shared build machine")
    }

    /// 턴이 돈다 (Stop 원)
    static func running() -> AgentChatSampleGateway.State {
        var thread = Thread()
        thread.user("Draft the Pro and Lifetime sections", AgentDelivery(state: .accepted))
        thread.agent("Opened pricing.mdx and the Oct 9 pricing decision. Drafting the Pro and Lifetime sections.")
        return state(thread, task: .running)
    }

    /// 잘린 답 + View full (Figma 57:2241의 본문)
    static func truncated() -> AgentChatSampleGateway.State {
        var thread = Thread()
        thread.user("Draft the Pro and Lifetime sections", AgentDelivery(state: .accepted))
        thread.agent("Draft v2 covers the Pro monthly, Pro yearly and Lifetime sections. The trial wording follows the Oct 9 decision, the refund window keeps the three-day limit, and the price table now lists", truncated: true)
        return state(thread, task: .idle)
    }

    /// 서버가 쓴 이벤트 줄 (Figma 57:2284 · 서버 글 그대로)
    static func events() -> AgentChatSampleGateway.State {
        var thread = Thread()
        thread.user("Draft the Pro and Lifetime sections", AgentDelivery(state: .accepted))
        thread.event("Opened in Terminal")
        thread.user("Also update the refund window wording", AgentDelivery(state: .queued, reason: .sessionExternal))
        thread.event("Queued messages cancelled")
        thread.event("Answered")
        thread.event("Answered on this Mac")
        thread.event("An event line the server wrote that is much longer than the panel is wide so it has to be cut at the end of its single line")
        return state(thread, status: .external, task: .idle)
    }

    /// 대기 메시지가 많다 (FIFO 순서 그대로)
    static func many() -> AgentChatSampleGateway.State {
        var thread = Thread()
        thread.user("First message", AgentDelivery(state: .accepted))
        for number in 2...13 { thread.user("Queued message number \(number)", AgentDelivery(state: .queued, reason: number == 2 ? .sessionBusy : .queueOrder)) }
        return state(thread, task: .running)
    }

    /// 100개를 넘는 메시지 (전달 읽기가 이어 읽는다)
    static func hundredPlus() -> AgentChatSampleGateway.State {
        var thread = Thread()
        for number in 1...130 { thread.user("Message \(number)", AgentDelivery(state: number > 128 ? .queued : .accepted)) }
        return state(thread, task: .running)
    }

    // MARK: 장면 (세션 패널)

    /// OA-3 External (57:2268): 이벤트 줄 + 대기 메시지 "Queued · Session is in Terminal"
    static func external() -> AgentChatSampleGateway.State {
        var thread = Thread()
        thread.event("Opened in Terminal")
        thread.user("Also update the refund window wording", AgentDelivery(state: .queued, reason: .sessionExternal))
        return state(thread, status: .external, task: .idle)
    }

    /// 다른 Mac의 세션: 알약이 없다
    static func otherMac() -> AgentChatSampleGateway.State {
        var thread = Thread()
        thread.agent("Opened pricing.mdx. Drafting the Pro section first.")
        return state(thread, task: .idle, bridge: otherMacBridge)
    }
}

/// 견본 전용 launcher: 터미널을 열지 않는다 (Open in Terminal 알약의 모양 · 꺼진 상태를 Figma와 맞춰 보는 렌더 fixture, 실제 launcher는 D4a-2)
struct SnapshotTerminalLauncher: AgentTerminalLauncher {
    func canOpen(sessionID: UUID) async -> Bool { true }
    func open(sessionID: UUID) async throws {}
}

/// 에이전트 대화 PNG (OA D4a-1, 디자인 비교용): `-TF_EDGE_SHELL YES -TFSampleData -TF_S3B YES -TF_U2 YES -TFEdgeSnapshot <폴더> -TFEdgeSnapshotIssues -TFEdgeSnapshotAgentChat`
/// (+ `-TFSnapshotDark`, `-TFReduceMotion YES`). 승인 전 새 문구 후보(`AgentNewCopy`)가 이 견본에서만 보인다. 서버는 가짜(`AgentChatSampleGateway`)라 렌더 fixture일 뿐이다.
/// 남기는 것(`mac-edge-agentchat-<이름>.png`): window-empty · window-in-flight(OA-4) · window-waiting(OA-4) · window-send-again-refused(동의 철회 뒤 거절) · window-reasons · window-queued · window-referent-menu · window-long-reason · window-running(Stop 원) ·
/// window-stop-requested · window-stop-may-continue · window-truncated · window-truncated-expanded · window-events · window-many · window-hundred-plus · window-chip-added(auto 칩을 누른 뒤) ·
/// panel-running · panel-idle-view-full(OA-3) · panel-external(OA-3) · panel-resume-card(OA-3) · panel-other-mac · panel-stop-requested · panel-stop-may-continue.
/// (Resume 뒤 "아직 열림" 빨간 줄 · 폴더 고르기는 실제 프로세스 검사기를 쓰는 D4a-2의 장면이다)
@MainActor
enum AgentChatSnapshot {
    nonisolated static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("-TFEdgeSnapshotAgentChat") }

    static func capture(_ edge: EdgeShellController, file: (String) -> URL, pause: @escaping (Double) async -> Void) async {
        guard let runtime = edge.chat, let manager = edge.assistant, let issues = runtime.issues else {
            print("AgentChatSnapshot: 새 Issues 화면과 Assistant 창이 켜진 구성이 필요하다 (-TF_EDGE_SHELL YES -TF_S3B YES -TF_U2 YES) chat=\(edge.chat != nil) windows=\(edge.assistant != nil)")
            return
        }
        // 승인 전 새 문구 후보는 이 견본에서만 보인다 (Release에는 켜는 길이 없다)
        AgentNewCopy.isPreviewing = true
        let sample = AgentChatSampleGateway.shared
        let shell = edge.shell
        manager.presents = true
        shell.localBridgeIDProvider = { AgentChatSampleData.thisMacBridge }
        // 이슈 패널이 쓰는 견본 일감 (U2 견본과 같다): 세션 패널은 이슈 #139의 패널 옆에 열린다
        edge.workOverride = { _ in IssueSnapshotData.snapshot(seeds: IssueSnapshotData.seeds) }
        await runtime.contexts?.refresh()
        runtime.chat.fullTextLookup = { key in AgentChatSampleData.fullText(forKey: key) }
        func settle(_ seconds: Double = 0.8) async { await pause(seconds) }
        func shootWindow(_ name: String) { AssistantSnapshot.snapshot(edge, manager: manager, to: file("agentchat-\(name)")) }
        func shootPanel(_ name: String) { IssueSnapshot.compose(edge, to: file("agentchat-\(name)")) }

        /// 새 계정이 막 로그인한 것처럼 저장소를 비우고 장면대로 서버를 바꾼다
        func world(_ state: AgentChatSampleGateway.State) async {
            manager.closeAll()
            sample.state = state
            sample.stopConfirms = false
            sample.stopMayContinue = false
            sample.deliverFailure = nil
            sample.deliverReply = AgentDelivery(state: .queued, reason: .sessionBusy)
            runtime.scope.accountLeft()
            runtime.chat.fullTextLookup = { key in AgentChatSampleData.fullText(forKey: key) }
            await runtime.targets.refresh()
            await runtime.chat.refresh()
            await settle(0.4)
        }
        func window(chip: AssistantChip? = nil, presses: Bool = false) async -> AssistantWindowModel? {
            guard let id = manager.openWindow(for: AgentChatSampleData.conversationID), let model = manager.controllers[id]?.model else { return nil }
            if let chip { model.followOpenItem(chip) }
            await runtime.chat.settle()
            await model.agent?.sessions.refresh()
            await settle()
            return model
        }
        let issue139 = AssistantChip(kind: .action, itemID: IssueSnapshotData.issue(139), origin: .auto, title: "Rewrite pricing page copy", number: 139)

        // Assistant 창
        await world(AgentChatSampleData.inFlight())
        _ = await window(chip: issue139)
        shootWindow("window-in-flight")
        await world(AgentChatSampleData.waiting())
        _ = await window(chip: issue139)
        shootWindow("window-waiting")
        // 동의 철회 뒤 Send again이 409로 거절됐다: 기존 동의 안내 + 상태 줄(Not sent · Try again)이 전달 줄을 대신한다
        await world(AgentChatSampleData.waiting())
        sample.deliverFailure = APIError.server(status: 409, code: .conflict, message: APIError.consentRequiredMessage)
        if let model = await window(chip: issue139),
           let failed = runtime.chat.turns(for: AgentChatSampleData.conversationID).first(where: { model.deliveryLine(for: $0)?.strong == "Not sent" }) {
            await model.sendAgain(failed)
            await settle()
            shootWindow("window-send-again-refused")
        }
        sample.deliverFailure = nil
        await world(AgentChatSampleData.reasons())
        _ = await window()
        shootWindow("window-reasons")
        await world(AgentChatSampleData.queued())
        if let model = await window() {
            shootWindow("window-queued")
            if let referent = runtime.chat.turns(for: AgentChatSampleData.conversationID).last(where: { $0.delivery?.state == .needsReferent }) {
                model.openReferentMenu(for: referent.id)
                await settle()
                shootWindow("window-referent-menu")
                model.closeReferentMenu()
            }
        }
        await world(AgentChatSampleData.longReason())
        _ = await window()
        shootWindow("window-long-reason")
        // 빈 대화: auto 칩 " · Not sent", 눌러서 added가 된 칩
        await world(AgentChatSampleData.state(AgentChatSampleData.Thread(), task: nil))
        if let model = await window(chip: issue139) {
            shootWindow("window-empty")
            if let chip = model.chips.chips.first { model.promoteChip(chip.id) }
            await settle(0.4)
            shootWindow("window-chip-added")
        }
        await world(AgentChatSampleData.running())
        let running = await window()
        shootWindow("window-running")
        if let running {
            await running.stop()
            await settle()
            shootWindow("window-stop-requested")
        }
        await world(AgentChatSampleData.running())
        sample.stopConfirms = true
        sample.stopMayContinue = true
        if let running = await window() {
            await running.stop()
            await runtime.agentTurns?.refresh()
            await settle()
            shootWindow("window-stop-may-continue")
        }
        await world(AgentChatSampleData.truncated())
        let truncated = await window()
        shootWindow("window-truncated")
        if let turn = runtime.chat.turns(for: AgentChatSampleData.conversationID).first(where: \.isTruncated) {
            truncated?.viewFull(turn)
            await settle()
            shootWindow("window-truncated-expanded")
        }
        await world(AgentChatSampleData.events())
        _ = await window()
        shootWindow("window-events")
        await world(AgentChatSampleData.many())
        _ = await window()
        shootWindow("window-many")
        await world(AgentChatSampleData.hundredPlus())
        _ = await window()
        shootWindow("window-hundred-plus")
        manager.closeAll()

        // 세션 패널 (OA-3): 이 Mac의 세션이라 알약이 보인다. Open in Terminal은 견본 가짜 launcher(`SnapshotTerminalLauncher`)로 그린다 (앱의 실제 launcher는 D4a-2)
        func openPanel() async {
            shell.openAllWork()
            await settle(0.6)
            shell.openIssue(IssueSnapshotData.issue(139))
            await issues.numbers.ensure([IssueSnapshotData.issue(139)])
            await issues.sessions.refresh()
            await settle(0.4)
            shell.openSession(AgentChatSampleData.sessionID)
            await settle(1.2)
        }
        await world(AgentChatSampleData.running())
        await openPanel()
        shootPanel("panel-running")
        await runtime.stop.stopSession(issues.sessions.item(id: AgentChatSampleData.sessionID)!)
        await issues.sessions.refresh()
        await settle(0.6)
        shootPanel("panel-stop-requested")
        shell.closeSessionPanel()
        await world(AgentChatSampleData.running())
        sample.stopConfirms = true
        sample.stopMayContinue = true
        await openPanel()
        await runtime.stop.stopSession(issues.sessions.item(id: AgentChatSampleData.sessionID)!)
        await issues.sessions.refresh()
        await settle(0.6)
        shootPanel("panel-stop-may-continue")
        shell.closeSessionPanel()
        await world(AgentChatSampleData.truncated())
        await openPanel()
        shootPanel("panel-idle-view-full")
        await world(AgentChatSampleData.external())
        await openPanel()
        shootPanel("panel-external")
        if let session = issues.sessions.item(id: AgentChatSampleData.sessionID), let pill = session.pill {
            await runtime.pillFlow?.press(pill, session: session)
            await settle(0.6)
            shootPanel("panel-resume-card")
        }
        await world(AgentChatSampleData.otherMac())
        await openPanel()
        shootPanel("panel-other-mac")
        shell.closeSessionPanel()
        manager.closeAll()
        AgentNewCopy.isPreviewing = false
    }
}

#endif
