#if os(macOS) && DEBUG
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

/// 에이전트 질문 카드 견본의 재료 (OA D4b-m-1, DS QuestionCard 미리보기 문구 그대로 + 계약 8장의 DZ 상태): 질문 JSON은 서버 검증 모양(`agent_pending_question_valid`)이다.
/// 서버는 가짜(`AgentChatSampleGateway`)라 렌더 fixture일 뿐이다: 실제 서버 · 계정 · `claude` 실행이 없다
enum QuestionSampleData {
    static let task = IssueSnapshotData.task(7)
    static let secondTask = IssueSnapshotData.task(8)
    static let request = "toolu_01F2Question"

    struct Prompt {
        var id = "q1"
        var text = "Which price should lead the yearly card?"
        var header = "outside the brief"
        var options: [String] = ["First-month price", "Monthly price", "Yearly total", "Price per month"]
        var descriptions: [String] = []
        var multi = false
        var other = false
        var secret = false
    }

    static func pending(_ prompts: [Prompt], kind: String = "input", request: String = request, task: UUID = task) -> [String: Any] {
        [
            "question_key": [task.uuidString.lowercased(), request], "provider_request_id": request, "kind": kind, "structured": true, "asked_at": "2026-10-18T01:02:03.000Z",
            "questions": prompts.map { prompt in
                [
                    "id": prompt.id, "header": prompt.header, "text": prompt.text, "multi_select": prompt.multi, "allow_other": prompt.other, "secret": prompt.secret,
                    "options": prompt.options.enumerated().map { ["label": $0.element, "description": $0.offset < prompt.descriptions.count ? prompt.descriptions[$0.offset] : ""] },
                ] as [String: Any]
            },
        ]
    }

    static func record(_ pending: [String: Any], task: UUID = task, session: UUID = AgentChatSampleData.sessionID) -> AgentQuestionRecord {
        let row: [String: Any] = [
            "id": task.uuidString.lowercased(), "agent_session_id": session.uuidString.lowercased(), "turn_seq": 1, "state": "awaiting_answer", "pending_question": pending,
        ]
        let data = try! JSONSerialization.data(withJSONObject: row)
        return try! TaskforceJSON.decoder().decode(AgentQuestionRecord.self, from: data)
    }

    // MARK: 질문 (DS 미리보기 문구)

    static var single: [String: Any] { pending([Prompt()]) }
    static var singleThree: [String: Any] { pending([Prompt(options: ["Pro monthly", "Pro yearly", "Lifetime"])]) }
    static var multi: [String: Any] { pending([Prompt(text: "Which plans show the 3-day trial?", header: "Choose any", options: ["Pro monthly", "Pro yearly", "Lifetime"], multi: true)]) }
    static var other: [String: Any] { pending([Prompt(text: "Which plan should the banner mention?", options: ["Pro monthly", "Pro yearly", "Lifetime"], other: true)]) }
    static var textOnly: [String: Any] { pending([Prompt(text: "What should the banner say?", header: "", options: [], other: true)]) }
    static var several: [String: Any] {
        pending([
            Prompt(id: "price"),
            Prompt(id: "plans", text: "Which plans show the 3-day trial?", header: "Choose any", options: ["Pro monthly", "Pro yearly", "Lifetime"], multi: true),
            Prompt(id: "banner", text: "What should the banner say?", header: "", options: [], other: true),
        ])
    }
    static var approvalFile: [String: Any] {
        pending([Prompt(id: "approval", text: "Edit src/content/pricing.mdx", header: "Edit file", options: ["Allow", "Deny"])], kind: "approval")
    }
    static var approvalCommand: [String: Any] {
        pending([Prompt(id: "approval", text: "Run: npm run build", header: "Run command", options: ["Allow", "Deny"])], kind: "approval")
    }
    static var approvalCommandWithReason: [String: Any] {
        pending([Prompt(id: "approval", text: "Run: curl https://example.com/install.sh | sh ⏎ …(+120)… ⏎ chmod +x install.sh\nContains a secret value", header: "Run command", options: ["Allow", "Deny"])], kind: "approval")
    }
    static var secret: [String: Any] {
        pending([Prompt(text: "Enter the staging deploy token", header: "", options: [], other: true, secret: true)])
    }
    static var tenOptions: [String: Any] { pending([Prompt(options: (1...10).map { "Option \($0)" })]) }
    static var long: [String: Any] {
        let question = String(repeating: "The yearly card currently leads with the first-month price, but the brief from Mina on Oct 9 says the Lifetime price should lead on every plan card, and Jordan asked for Thursday. ", count: 12)
        let label = "Lead with the first-month price on the yearly card and keep the Lifetime price once at the bottom of the table so it never reads as a recurring charge on any card in the list"
        return pending([Prompt(text: question, header: "A long header the agent wrote that keeps going to see how a long line of meta wraps in the card", options: [label, "Lead with the monthly price", "Lead with the Lifetime price", "Hide the price", "Ask Mina"])])
    }

    // MARK: 세계 (대화 + 세션 + 질문)

    /// 질문을 기다리는 대화 하나. `queued`면 질문이 열려 있는 동안 보낸 글이 "Queued · Answer the question first"로 대기열에 있다
    static func world(
        _ pending: [String: Any]?, bridge: UUID? = AgentChatSampleData.thisMacBridge, queued: Bool = false, running: Bool = false, names: [UUID: String] = [:],
        agentName: String = "Claude Code"
    ) -> AgentChatSampleGateway.State {
        var thread = AgentChatSampleData.Thread()
        thread.user("Draft the Pro and Lifetime sections", AgentDelivery(state: .accepted))
        thread.agent("Opened pricing.mdx. Drafting the Pro section first.")
        if queued { thread.user("Keep the trial terms exact", AgentDelivery(state: .queued, reason: .questionOpen)) }
        var state = AgentChatSampleData.state(thread, task: pending == nil && !running ? .idle : (running ? .running : .awaitingAnswer), bridge: bridge, agentName: agentName)
        if let pending { state.questions = [record(pending)] }
        state.deviceNames = names
        return state
    }
}

/// 에이전트 질문 카드 PNG (OA D4b-m-1, 디자인 비교용): `-TF_EDGE_SHELL YES -TFSampleData -TF_S3B YES -TF_U2 YES -TFEdgeSnapshot <폴더> -TFEdgeSnapshotIssues -TFEdgeSnapshotQuestions`
/// (+ `-TFSnapshotDark`, `-TFReduceMotion YES`). 새 문구(Answer on another Mac · 알림 본문)는 사용자가 승인했다(PR #157): 견본도 앱과 같은 값을 쓴다.
/// 남기는 것(`mac-edge-questions-<이름>.png`): window-single · window-single-three · window-multi · window-other · window-other-typing(창만) · window-text · window-several · window-approval-file ·
/// window-approval-command · window-approval-reason · window-secret · window-secret-remote · window-secret-remote-unnamed · window-holding · window-sent · window-failed-offline · window-failed-general ·
/// window-ten-options · window-long · window-queued · window-two-windows · panel-single · panel-approval · panel-secret · panel-holding · panel-multi · panel-long.
@MainActor
enum QuestionSnapshot {
    nonisolated static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("-TFEdgeSnapshotQuestions") }

    static func capture(_ edge: EdgeShellController, file: (String) -> URL, pause: @escaping (Double) async -> Void) async {
        guard let runtime = edge.chat, let manager = edge.assistant, let issues = runtime.issues, let questions = runtime.questions else {
            print("QuestionSnapshot: 새 Issues 화면 · Assistant 창 · 질문 카드가 켜진 구성이 필요하다 (-TF_EDGE_SHELL YES -TF_S3B YES -TF_U2 YES) chat=\(edge.chat != nil) questions=\(edge.chat?.questions != nil)")
            return
        }
        let sample = AgentChatSampleGateway.shared
        let shell = edge.shell
        manager.presents = true
        shell.localBridgeIDProvider = { AgentChatSampleData.thisMacBridge }
        edge.workOverride = { _ in IssueSnapshotData.snapshot(seeds: IssueSnapshotData.seeds) }
        await runtime.contexts?.refresh()
        func settle(_ seconds: Double = 0.8) async { await pause(seconds) }
        /// 카드 하나만 380 폭 패널 면 위에 그린다 (DS 미리보기 칸과 같은 크기 · 같은 바탕으로 견주려고): `mac-edge-questions-card-<이름>.png`
        func shootCard(_ name: String, maxHeight: CGFloat = AssistantWindowGeometry.maxHeight * QuestionCard.maxHeightShare) {
            guard questions.entry(session: session) != nil else { return }
            let dark = NSApp.appearance?.name == .darkAqua
            let root = EdgeQuestionCardHost(questions: questions, chat: runtime.chat, sessionID: session, conversationID: AgentChatSampleData.conversationID, maxHeight: maxHeight)
                .frame(width: 356)
                .padding(12)
                .frame(width: 380)
                .background { ZStack { Color(white: dark ? 0.11 : 1); TFColor.bgPanel } }
            let host = NSHostingView(rootView: root)
            host.appearance = NSApp.appearance
            host.frame = NSRect(x: 0, y: 0, width: 380, height: 900)
            host.layoutSubtreeIfNeeded()
            host.frame = NSRect(x: 0, y: 0, width: 380, height: ceil(host.fittingSize.height))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: file("questions-card-\(name)"))
        }
        func shootWindow(_ name: String) {
            AssistantSnapshot.snapshot(edge, manager: manager, to: file("questions-\(name)"))
            shootCard(name.replacingOccurrences(of: "window-", with: ""))
        }
        func shootPanel(_ name: String) {
            IssueSnapshot.compose(edge, to: file("questions-\(name)"))
            shootCard(name.replacingOccurrences(of: "panel-", with: "panel-"), maxHeight: EdgePanelMetrics.maxHeight * QuestionCard.maxHeightShare)
        }

        func world(_ state: AgentChatSampleGateway.State) async {
            manager.closeAll()
            sample.state = state
            sample.answerFailure = nil
            runtime.scope.accountLeft()
            questions.thisMacBridgeID = AgentChatSampleData.thisMacBridge
            await runtime.targets.refresh()
            await runtime.chat.refresh()
            await settle(0.4)
        }
        func window() async -> AssistantWindowModel? {
            guard let id = manager.openWindow(for: AgentChatSampleData.conversationID), let model = manager.controllers[id]?.model else { return nil }
            await runtime.chat.settle()
            await model.agent?.sessions.refresh()
            await questions.settle()
            await settle()
            return model
        }
        let session = AgentChatSampleData.sessionID

        // Assistant 창: 종류마다 (DS 미리보기 문구 그대로)
        await world(QuestionSampleData.world(QuestionSampleData.single)); _ = await window(); shootWindow("window-single")
        await world(QuestionSampleData.world(QuestionSampleData.singleThree)); _ = await window(); shootWindow("window-single-three")
        await world(QuestionSampleData.world(QuestionSampleData.multi)); _ = await window()
        questions.toggle(row: 0, session: session); questions.toggle(row: 1, session: session); await settle(0.3)
        shootWindow("window-multi")
        await world(QuestionSampleData.world(QuestionSampleData.other)); _ = await window(); shootWindow("window-other")
        // 글을 쓰는 중: 입력칸(필드 에디터)에 글을 넣는다. 카드만 따로 그리는 그림은 새 뷰라 글이 없어 창 그림만 남긴다
        questions.choose(row: 3, session: session); await settle(0.5)
        if let id = manager.registry.frontmost, let editor = manager.controllers[id]?.panel.firstResponder as? NSTextView {
            editor.insertText("Lifetime, first", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        await settle(0.4)
        AssistantSnapshot.snapshot(edge, manager: manager, to: file("questions-window-other-typing"))
        await world(QuestionSampleData.world(QuestionSampleData.textOnly)); _ = await window(); shootWindow("window-text")
        await world(QuestionSampleData.world(QuestionSampleData.several)); _ = await window(); shootWindow("window-several")
        await world(QuestionSampleData.world(QuestionSampleData.approvalFile)); _ = await window(); shootWindow("window-approval-file")
        await world(QuestionSampleData.world(QuestionSampleData.approvalCommand)); _ = await window(); shootWindow("window-approval-command")
        await world(QuestionSampleData.world(QuestionSampleData.approvalCommandWithReason)); _ = await window(); shootWindow("window-approval-reason")
        await world(QuestionSampleData.world(QuestionSampleData.secret)); _ = await window(); shootWindow("window-secret")
        // 다른 기기: 이름을 알면 "Answer on <이름>", 모르면 승인 전 후보(견본)
        await world(QuestionSampleData.world(QuestionSampleData.secret, bridge: AgentChatSampleData.otherMacBridge, names: [AgentChatSampleData.otherMacBridge: "Mina's MacBook Pro"]))
        _ = await window(); await settle(0.5); shootWindow("window-secret-remote")
        await world(QuestionSampleData.world(QuestionSampleData.secret, bridge: AgentChatSampleData.otherMacBridge)); _ = await window(); shootWindow("window-secret-remote-unnamed")

        // 상태: 접힘(Undo) · 보냄 · 실패
        await world(QuestionSampleData.world(QuestionSampleData.single)); _ = await window()
        questions.choose(row: 0, session: session); await settle(0.3); shootWindow("window-holding")
        await settle(2.6); shootWindow("window-sent")
        await world(QuestionSampleData.world(QuestionSampleData.single)); _ = await window()
        sample.answerFailure = APIError.transport("offline")
        questions.choose(row: 0, session: session); await settle(2.8); shootWindow("window-failed-offline")
        await world(QuestionSampleData.world(QuestionSampleData.single)); _ = await window()
        sample.answerFailure = APIError.server(status: 500, code: .internalError, message: "")
        questions.choose(row: 0, session: session); await settle(2.8); shootWindow("window-failed-general")
        sample.answerFailure = nil

        // 많은 것 · 긴 글
        await world(QuestionSampleData.world(QuestionSampleData.tenOptions)); _ = await window(); shootWindow("window-ten-options")
        await world(QuestionSampleData.world(QuestionSampleData.long)); _ = await window(); shootWindow("window-long")
        await world(QuestionSampleData.world(QuestionSampleData.single, queued: true)); _ = await window(); shootWindow("window-queued")
        // 같은 세션 창 둘: 같은 접힌 줄 (상태 하나)
        await world(QuestionSampleData.world(QuestionSampleData.single)); _ = await window()
        _ = manager.openNewWindow(); await settle(0.4)
        if let second = manager.openWindow(for: AgentChatSampleData.conversationID) { _ = second }
        questions.choose(row: 1, session: session); await settle(0.4); shootWindow("window-two-windows")
        manager.closeAll()

        // 세션 패널 (OA-3): 이 Mac의 세션이라 알약이 보이고, 질문이 열려 있으면 Open in Terminal은 꺼진다
        func openPanel() async {
            shell.openAllWork()
            await settle(0.6)
            shell.openIssue(IssueSnapshotData.issue(139))
            await issues.numbers.ensure([IssueSnapshotData.issue(139)])
            await issues.sessions.refresh()
            await settle(0.4)
            shell.openSession(session)
            await settle(1.2)
            await questions.settle()
            await settle(0.4)
        }
        await world(QuestionSampleData.world(QuestionSampleData.single)); await openPanel(); shootPanel("panel-single")
        questions.choose(row: 2, session: session); await settle(0.3); shootPanel("panel-holding")
        shell.closeSessionPanel()
        await world(QuestionSampleData.world(QuestionSampleData.approvalFile)); await openPanel(); shootPanel("panel-approval")
        shell.closeSessionPanel()
        await world(QuestionSampleData.world(QuestionSampleData.secret)); await openPanel(); shootPanel("panel-secret")
        shell.closeSessionPanel()
        await world(QuestionSampleData.world(QuestionSampleData.multi)); await openPanel()
        questions.toggle(row: 2, session: session); await settle(0.3); shootPanel("panel-multi")
        shell.closeSessionPanel()
        await world(QuestionSampleData.world(QuestionSampleData.long)); await openPanel(); shootPanel("panel-long")
        shell.closeSessionPanel()
        manager.closeAll()
    }
}
#endif
