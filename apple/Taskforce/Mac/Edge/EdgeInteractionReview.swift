#if os(macOS) && DEBUG
import AppKit
import Carbon.HIToolbox
import TaskforceKit

/// Review 페이지(S4)의 앱 안 합성 조작 (`-TF_EDGE_SHELL YES -TFSampleData -TFEdgeInteractReview <로그 파일> [-TF_S4 YES]`): 진짜 패널 창에 AppKit 이벤트(키 · 마우스)를
/// `NSApp.sendEvent`로 흘려 단축키 모니터 · 입력칸(필드 에디터) · SwiftUI 버튼이 실제 응답 체인으로 반응하는지 본다. 가짜 답 서버(`SampleReviewServer`)라 네트워크 · 계정 · AI 호출은 없다.
/// 이것은 OS 수준의 포인터 · 키보드 입력도 IME도 VoiceOver도 아니다 (앱 프로세스 안에서 만든 이벤트): 로그에 그렇게 적는다. `-TFEdgeInteractShots <폴더>`가 있으면 단계마다 PNG도 남긴다.
/// 한글 제목은 글자 인식이 어려워 이 실행에서만 영문 제목으로 바꿔 보인다 (제목은 화면 글자일 뿐, 큐는 id로 따른다).
extension EdgeInteraction {
    private static let titles: [Int: String] = [14: "Deploy demo environment", 10: "Customer demo prep", 12: "Hand off design", 21: "Review contract changes"]

    static func runReviewIfRequested(_ edge: EdgeShellController) {
        guard let logPath = reviewLogPath, SampleData.isEnabled, let now = edge.launcher.now else { return }
        guard let desk = edge.shell.review else {
            runReviewOff(edge, logPath: logPath, now: now)
            return
        }
        Task { @MainActor in
            var lines: [String] = ["합성 조작(앱 프로세스 안 NSApp.sendEvent) — OS 수준 포인터 · 키보드 · IME · VoiceOver 아님. S4 켜짐(-TF_S4 YES), 가짜 답 서버"]
            func settle(_ seconds: Double = 0.6) async { try? await Task.sleep(for: .seconds(seconds)) }
            func check(_ name: String, _ ok: Bool, _ seen: String) { lines.append("\(ok ? "PASS" : "FAIL") \(name) — \(seen)") }
            func id(_ n: Int) -> UUID { SampleData.id(n) }
            let server = SampleReviewServer()
            now.installSampleReview(server)
            let shell = edge.shell
            let panelWindow = edge.panel.panel
            let arrows: NSEvent.ModifierFlags = [.numericPad, .function]
            @MainActor func resetQueue(_ numbers: [Int] = ReviewSnapshot.queue) async {
                server.scenario = .apply
                server.releaseHeld()
                server.clearRequests()
                now.resetSampleReview()
                now.applySampleOnline()
                desk.reset()
                ReviewSnapshot.setQueue(now, numbers, evidence: ReviewSnapshot.baseEvidence, titles: titles)
                await settle()
            }
            @MainActor func shownTitle() -> String { shell.shownReview?.title ?? "-" }
            @MainActor func shownNumber() -> Int? { ReviewSnapshot.queue.first { id($0) == shell.shownReview?.id } }
            await settle(1.5)
            await resetQueue()

            // 1) ⌥ Space와 같은 길로 연다: 마지막에 본 화면(All work). Review를 열지도 어떤 답을 보내지도 않는다
            shell.togglePanel()
            await settle()
            check("⌥ Space opens the last view (All work), never a decision", shell.panelOpen && shell.view == .allWork && server.requests.isEmpty, "view=\(shell.view) requests=\(server.requests.count)")

            // 2) 패널을 열면 All work의 검색칸에 포커스가 있다: 편집 중인 글이 먼저라 ⌘1은 듣지 않는다 (계약: ⌘1도 텍스트 편집 밖에서만)
            check("⌘1 inside the focused All work search is not heard (text editing wins)", EdgeReviewKeys.isTextEditing(panelWindow.firstResponder), "firstResponder=\(String(describing: panelWindow.firstResponder.map { type(of: $0) }))")
            sendKey("1", code: kVK_ANSI_1, flags: .command, to: panelWindow)
            await settle(0.4)
            check("…and nothing opened or sent", shell.view == .allWork && server.requests.isEmpty, "view=\(shell.view) requests=\(server.requests.count)")

            // 3) 텍스트 입력: Chats 입력칸에 1 · 2를 치면 글자일 뿐이고 어떤 답도 보내지 않는다. ⌘1도 ← 도 입력칸 안에서는 듣지 않는다
            sendKey("3", code: kVK_ANSI_3, flags: .command, to: panelWindow)
            await settle(1)
            let chat = edge.chat?.chat
            let draftOwner = chat?.currentID
            sendKey("1", code: kVK_ANSI_1, to: panelWindow)
            sendKey("2", code: kVK_ANSI_2, to: panelWindow)
            await settle(0.4)
            let draft = draftOwner.map { chat?.draft(for: $0) ?? "" } ?? ""
            check("typing 1 2 in the Chats composer is text, not answers", shell.view == .chats && draft == "12" && server.requests.isEmpty, "view=\(shell.view) draft=\"\(draft)\" requests=\(server.requests.count)")
            capture(edge, "review-3-composer-typing")
            sendKey("\u{F702}", code: kVK_LeftArrow, flags: arrows, to: panelWindow)
            sendKey("1", code: kVK_ANSI_1, flags: .command, to: panelWindow)
            await settle(0.6)
            check("← and ⌘1 inside the composer are not heard (caret · text editing wins)", shell.view == .chats && server.requests.isEmpty, "view=\(shell.view) requests=\(server.requests.count)")

            // 4) 입력칸 밖으로 나가(⌘2 = All work, 이제 검색칸 포커스가 없다) ⌘1: 가장 새 항목 (서버 순서의 마지막 = 가장 늦은 last_activity_at)
            sendKey("2", code: kVK_ANSI_2, flags: .command, to: panelWindow)
            await settle(0.6)
            let outside = !EdgeReviewKeys.isTextEditing(panelWindow.firstResponder)
            sendKey("1", code: kVK_ANSI_1, flags: .command, to: panelWindow)
            await settle(0.8)
            check("⌘1 outside text editing opens the newest Review item", outside && shell.view == .review && shownNumber() == 21 && server.requests.isEmpty, "view=\(shell.view) shown=\(shownTitle()) outside=\(outside) requests=\(server.requests.count)")
            capture(edge, "review-1-newest")

            // 5) ← →: 서버 순서로 한 칸씩, 끝에서 멈춤. 읽기 · 탐색은 답이 아니다
            sendKey("\u{F702}", code: kVK_LeftArrow, flags: arrows, to: panelWindow)
            await settle(0.4)
            check("← steps to the previous item", shownNumber() == 12, "shown=\(shownTitle())")
            sendKey("\u{F703}", code: kVK_RightArrow, flags: arrows, to: panelWindow)
            sendKey("\u{F703}", code: kVK_RightArrow, flags: arrows, to: panelWindow)
            await settle(0.4)
            check("→ stops at the last item (no wrap)", shownNumber() == 21 && server.requests.isEmpty, "shown=\(shownTitle()) requests=\(server.requests.count)")

            // 6) 단계 점(머리 오른쪽, 24pt 칸 넷)을 눌러 첫 항목으로. 3은 v1에 없는 세 번째 행동: 아무 일도 하지 않는다. 수식키가 붙은 1도
            let firstDot = CGPoint(x: EdgePanelMetrics.width - 10 - 96 + 12, y: 22)
            clickPanelPoint(firstDot, in: panelWindow)
            await settle(0.5)
            check("click the first step dot", shownNumber() == 14 && server.requests.isEmpty, "shown=\(shownTitle()) | dot at \(firstDot)")
            capture(edge, "review-2-first")
            sendKey("3", code: kVK_ANSI_3, to: panelWindow)
            sendKey("1", code: kVK_ANSI_1, flags: .option, to: panelWindow)
            await settle(0.4)
            check("key 3 and ⌥1 do nothing", server.requests.isEmpty && shell.view == .review, "requests=\(server.requests.count)")

            // 7) 1: Confirm (명시적 선택). 서버가 받기 전에는 진행 표시, 반복 키 · 중복 클릭은 요청 하나
            await resetQueue()
            server.scenario = .hang
            shell.openNewestReview()
            await settle()
            sendKey("1", code: kVK_ANSI_1, to: panelWindow)
            sendKey("1", code: kVK_ANSI_1, isRepeat: true, to: panelWindow)
            sendKey("1", code: kVK_ANSI_1, isRepeat: true, to: panelWindow)
            await settle(0.4)
            await click(text: "Confirm", in: panelWindow)
            await click(text: "Dismiss", in: panelWindow)
            await settle(0.4)
            check("1 + repeats + double click + the other answer → exactly one request", server.requests.count == 1 && server.requests.first?.id == id(21) && server.requests.first?.answer == .confirm && desk.sending[id(21)] == .confirm, "requests=\(server.requests.map { "\($0.answer)" }) sending=\(String(describing: desk.sending[id(21)]))")
            check("while sending the item stays and nothing is marked done", shownNumber() == 21 && shell.reviewQueue.contains(id(21)), "shown=\(shownTitle())")
            capture(edge, "review-4-sending")
            server.releaseHeld()
            await settle(1)
            check("after the server took it the next item is shown (successor, not the same index)", shownNumber() == 12 && !shell.reviewQueue.contains(id(21)) && desk.sending.isEmpty, "shown=\(shownTitle()) queue=\(shell.reviewQueue.count)")
            capture(edge, "review-5-after")

            // 8) 2: Dismiss (글자를 읽어 누르기도 한다)
            await click(text: "Dismiss", in: panelWindow)
            await settle(1)
            check("click Dismiss sends one DELETE-answer for that item", server.requests.count == 2 && server.requests.last?.id == id(12) && server.requests.last?.answer == .dismiss, "requests=\(server.requests.map { "\($0.answer)" }) | \(lastClick)")

            // 9) 충돌: 항목은 그대로, 안내, 자동 재전송 없음. 다시 고르면 새 요청 하나
            await resetQueue()
            server.scenario = .conflict
            shell.openReview(itemID: id(10))
            await settle()
            sendKey("2", code: kVK_ANSI_2, to: panelWindow)
            await settle(0.9)
            check("409: the item stays, a refreshed notice is shown, nothing is resent", shell.reviewQueue.contains(id(10)) && desk.notice?.text == ReviewCopy.conflict && server.requests.count == 1, "notice=\(desk.notice?.text ?? "-") requests=\(server.requests.count)")
            capture(edge, "review-6-conflict")
            try? await Task.sleep(for: .milliseconds(500))
            check("no automatic resend", server.requests.count == 1, "requests=\(server.requests.count)")
            server.scenario = .apply
            sendKey("2", code: kVK_ANSI_2, to: panelWindow)
            await settle(1)
            check("choosing again is a new single request", server.requests.count == 2 && !shell.reviewQueue.contains(id(10)), "requests=\(server.requests.count) queue=\(shell.reviewQueue.count)")

            // 10) 응답 유실: 사라진 항목에도 안내가 남고 성공이라 하지 않는다
            await resetQueue()
            server.scenario = .loseResponse
            shell.openReview(itemID: id(12))
            await settle()
            sendKey("1", code: kVK_ANSI_1, to: panelWindow)
            await settle(0.9)
            check("lost response: unverified notice on the item, answers available again", desk.notice?.text == ReviewCopy.unverified && shell.reviewQueue.contains(id(12)) && desk.sending.isEmpty, "notice=\(desk.notice?.text ?? "-")")
            ReviewSnapshot.setQueue(now, [14, 10, 21], evidence: ReviewSnapshot.baseEvidence, titles: titles)
            await settle()
            check("when the list later drops the item the notice remains (disappearance is not success)", desk.notice?.id == id(12) && !shell.reviewQueue.contains(id(12)), "notice id ok=\(desk.notice?.id == id(12)) shown=\(shownTitle())")
            capture(edge, "review-7-unverified-gone")

            // 11) 계정이 떠나는 사이: 진행 표시 · 안내는 비워지고, 옛 요청이 끝나도 새 세션을 건드리지 않는다
            await resetQueue()
            server.scenario = .hang
            shell.openNewestReview()
            await settle()
            sendKey("1", code: kVK_ANSI_1, to: panelWindow)
            await settle(0.4)
            let beforeLeave = desk.sending[id(21)] == .confirm
            edge.chat?.scope.accountLeft()
            await settle(0.3)
            check("account left: sending is cleared", beforeLeave && desk.sending.isEmpty && desk.notice == nil, "before=\(beforeLeave) sending=\(desk.sending.count)")
            server.releaseHeld()
            await settle(0.8)
            check("the old request finishing leaves the new session's state alone", desk.sending.isEmpty && desk.notice == nil, "sending=\(desk.sending.count) notice=\(desk.notice?.text ?? "-")")

            // 12) 큐가 바뀐 뒤: 보던 항목이 id로 그대로이고, 모두 처리하면 No decisions waiting
            await resetQueue()
            shell.openReview(itemID: id(10))
            await settle()
            ReviewSnapshot.setQueue(now, [12, 21, 10, 14], evidence: ReviewSnapshot.baseEvidence, titles: titles)
            await settle()
            check("a reordered queue keeps showing the same item (by id)", shownNumber() == 10 && shell.reviewQueue.ids.first == id(12), "shown=\(shownTitle()) first=\(shell.reviewQueue.items.first?.title ?? "-")")
            for _ in 0..<4 {
                sendKey("1", code: kVK_ANSI_1, to: panelWindow)
                await settle(0.9)
            }
            check("answering every item ends at No decisions waiting", shell.shownReview == nil && shell.reviewQueue.isEmpty && server.requests.count >= 4, "queue=\(shell.reviewQueue.count) requests=\(server.requests.count)")
            check("OCR finds the empty state title", locate("No decisions waiting", in: panelWindow) != nil, "text=No decisions waiting")
            capture(edge, "review-8-empty")

            // 13) Esc로 접는다: 접어도 답을 보내지 않는다
            let requests = server.requests.count
            sendKey("\u{1B}", code: kVK_Escape, to: panelWindow)
            await settle(0.5)
            check("Esc collapses the panel and sends nothing", !shell.panelOpen && server.requests.count == requests, "panelOpen=\(shell.panelOpen)")

            try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8)
            NSApplication.shared.terminate(nil)
        }
    }

    /// S4가 꺼진 실행(`-TF_S4`가 없다): 지금(Edge) 그대로여야 한다 — Review 입구(⌘1 · 링 · ← → · 1 · 2)가 없다
    private static func runReviewOff(_ edge: EdgeShellController, logPath: String, now: NowStore) {
        Task { @MainActor in
            var lines: [String] = ["합성 조작(앱 프로세스 안 NSApp.sendEvent) — S4 꺼짐(-TF_S4 없음). OS 수준 포인터 · 키보드 · VoiceOver 아님"]
            func settle(_ seconds: Double = 0.6) async { try? await Task.sleep(for: .seconds(seconds)) }
            func check(_ name: String, _ ok: Bool, _ seen: String) { lines.append("\(ok ? "PASS" : "FAIL") \(name) — \(seen)") }
            let shell = edge.shell
            let panelWindow = edge.panel.panel
            let arrows: NSEvent.ModifierFlags = [.numericPad, .function]
            ReviewSnapshot.setQueue(now, ReviewSnapshot.queue, evidence: ReviewSnapshot.baseEvidence, titles: titles)
            await settle(1.5)
            check("no Review desk is created", shell.review == nil && edge.shell.review == nil, "review=\(String(describing: shell.review))")
            shell.togglePanel()
            await settle()
            sendKey("1", code: kVK_ANSI_1, flags: .command, to: panelWindow)
            await settle(0.4)
            check("⌘1 is not wired: the panel stays on All work", shell.view == .allWork && shell.reviewID == nil, "view=\(shell.view)")
            sendKey("\u{F702}", code: kVK_LeftArrow, flags: arrows, to: panelWindow)
            sendKey("1", code: kVK_ANSI_1, to: panelWindow)
            sendKey("2", code: kVK_ANSI_2, to: panelWindow)
            await settle(0.4)
            check("← 1 2 do nothing", shell.view == .allWork && now.busy.isEmpty && shell.reviewID == nil, "busy=\(now.busy.count)")
            // 레일의 Needs-you 링: 지금처럼 All work에서 그 행을 표시한다
            shell.dismiss()
            await settle(0.4)
            if let entry = shell.slots.first(where: { $0.kind == .needsYou }) {
                shell.openRailEntry(entry)
                await settle(0.6)
                check("a Needs-you ring opens All work with that row (as before S4)", shell.view == .allWork && shell.currentID == entry.id, "view=\(shell.view) current=\(entry.title)")
            } else {
                check("a Needs-you ring exists", false, "no ring")
            }
            capture(edge, "review-off-ring-opens-all-work")
            sendKey("2", code: kVK_ANSI_2, flags: .command, to: panelWindow)
            sendKey("3", code: kVK_ANSI_3, flags: .command, to: panelWindow)
            await settle(0.6)
            check("⌘2 · ⌘3 still work", shell.view == .chats, "view=\(shell.view)")
            try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8)
            NSApplication.shared.terminate(nil)
        }
    }
}
#endif
