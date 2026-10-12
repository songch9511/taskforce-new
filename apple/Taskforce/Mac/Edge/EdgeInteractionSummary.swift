#if os(macOS) && DEBUG
import AppKit
import Carbon.HIToolbox
import TaskforceKit

/// 복귀 요약(C3)의 앱 안 합성 조작 (`-TF_EDGE_SHELL YES -TFSampleData -TFSampleSummaryEnglish -TFEdgeInteractSummary <로그 파일> [-TF_C3 YES] [-TF_S4 YES]`):
/// 진짜 패널 창에 AppKit 마우스 · 키 이벤트를 `NSApp.sendEvent`로 흘려 줄 열기 · Clear 버튼 · Esc · 계정 이탈이 실제 응답 체인으로 반응하는지 본다. 가짜 서버(`SampleReturnSummaryGateway`)라 네트워크 · 계정 · AI 호출은 없다.
/// 이것은 OS 수준의 포인터 · 키보드 입력도 IME도 VoiceOver도 아니다 (앱 프로세스 안에서 만든 이벤트): 로그에 그렇게 적는다. 영문 제목은 글자 인식(Vision)으로 눌러 보려는 것이다.
extension EdgeInteraction {
    static var summaryLogPath: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-TFEdgeInteractSummary"), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    static func runSummaryIfRequested(_ edge: EdgeShellController) {
        guard let logPath = summaryLogPath, SampleData.isEnabled else { return }
        Task { @MainActor in
            let shell = edge.shell
            let panelWindow = edge.panel.panel
            let s4 = shell.review != nil
            var lines: [String] = ["합성 조작(앱 프로세스 안 NSApp.sendEvent) — OS 수준 포인터 · 키보드 · IME · VoiceOver 아님. C3 \(shell.summary == nil ? "꺼짐" : "켜짐"), S4 \(s4 ? "켜짐" : "꺼짐"), 가짜 복귀 요약 서버"]
            func settle(_ seconds: Double = 0.6) async { try? await Task.sleep(for: .seconds(seconds)) }
            func check(_ name: String, _ ok: Bool, _ seen: String) { lines.append("\(ok ? "PASS" : "FAIL") \(name) — \(seen)") }
            func id(_ n: Int) -> UUID { SampleData.id(n) }
            @MainActor func finish() {
                // 하나라도 FAIL이면 앱 종료 코드가 실패다: 종료 0이 "통과"로 읽히지 않게 한다 (로그에도 요약 줄을 남긴다)
                let failed = lines.filter { $0.hasPrefix("FAIL") }.count
                let passed = lines.filter { $0.hasPrefix("PASS") }.count
                lines.append("RESULT pass=\(passed) fail=\(failed)")
                try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8)
                if failed > 0 { exit(1) }
                NSApplication.shared.terminate(nil)
            }
            /// 글자 인식(Vision)은 같은 화면에서도 가끔 한 구절을 놓친다: 같은 줄의 다른 구절로도 찾아 본다 (줄 전체가 버튼이라 어느 구절을 눌러도 같은 줄이다)
            @MainActor func clickAny(_ phrases: [String]) async {
                for phrase in phrases where locate(phrase, in: panelWindow) != nil {
                    await click(text: phrase, in: panelWindow)
                    return
                }
                lastClick = "글자를 찾지 못함 (\(phrases.joined(separator: " | ")))"
            }
            await settle(1.5)

            guard let store = shell.summary, let gateway = AppRuntime.sampleSummaryGateway else {
                // C3 꺼짐: 카드도 서버 읽기도 없고 줄 열기는 지금 그대로다
                check("no summary store and no sample server are created", shell.summary == nil && AppRuntime.sampleSummaryGateway == nil, "summary=\(String(describing: shell.summary))")
                // 견본 목록의 한 일을 영문 제목으로 바꿔(글자 인식용) 줄을 눌러 본다
                if let now = edge.launcher.now { ReviewSnapshot.setQueue(now, ReviewSnapshot.queue, evidence: ReviewSnapshot.baseEvidence, titles: [10: "Customer demo prep"]) }
                shell.togglePanel()
                await settle()
                check("the panel opens on All work without a summary card", shell.panelOpen && shell.view == .allWork && shell.summaryContent == nil, "view=\(shell.view)")
                check("no Clear button is drawn", locate("Clear", in: panelWindow) == nil, "locate=\(String(describing: locate("Clear", in: panelWindow)))")
                capture(edge, "summary-off-all-work")
                await clickAny(["Customer demo prep"])
                await settle(0.4)
                check("a work row still opens as before", shell.currentID == id(10), "currentID=\(String(describing: shell.currentID)) | \(lastClick)")
                sendKey("2", code: kVK_ANSI_2, flags: .command, to: panelWindow)
                sendKey("3", code: kVK_ANSI_3, flags: .command, to: panelWindow)
                await settle(0.6)
                check("⌘2 · ⌘3 still work", shell.view == .chats, "view=\(shell.view)")
                finish()
                return
            }

            // 1) ⌥ Space와 같은 길로 연다: 마지막에 본 화면(All work) 위에 카드가 읽힌다
            gateway.reset(.changes)
            shell.togglePanel()
            await settle(1.2)
            let rows = shell.summaryContent?.rows.count ?? 0
            check("opening the panel reads the summary and the card is on top of All work", shell.panelOpen && shell.view == .allWork && rows == 5 && gateway.reads >= 1, "rows=\(rows) reads=\(gateway.reads)")
            let details = shell.summaryContent?.rows.map { $0.detail ?? "" } ?? []
            check("rows use the approved copy (Needs revision · Result ready · Due date changed · Updated from source · Completed · Canceled), never a Next line", details.prefix(2).elementsEqual(["Needs your answer · Needs revision", "Result ready"]) && details.dropFirst(2).first == "Due date changed · Updated from source" && !details.contains { $0.contains("Next") }, "details=\(details)")
            check("a Clear button is drawn (server cursor + changes to mark read)", locate("Clear", in: panelWindow) != nil && shell.summaryContent?.canClear == true, "clear=\(String(describing: locate("Clear", in: panelWindow)))")
            capture(edge, "summary-1-card")

            // 2) 줄 열기 (열기는 어떤 결정도 해결도 아니다)
            await clickAny(["Onboarding design draft", "Draft ready"])
            await settle(0.4)
            check("click a result row opens that work in All work", shell.view == .allWork && shell.currentID == id(11), "view=\(shell.view) currentID=\(String(describing: shell.currentID)) | \(lastClick)")
            await clickAny(["Send proposal v2", "Needs your answer"])
            await settle(0.6)
            if s4 {
                check("S4 on: the confirm row opens its Review page", shell.view == .review && shell.shownReview?.id == SampleData.reviewID, "view=\(shell.view) shown=\(String(describing: shell.shownReview?.title)) | \(lastClick)")
                capture(edge, "summary-2-review")
                sendKey("2", code: kVK_ANSI_2, flags: .command, to: panelWindow)
            } else {
                check("S4 off: the confirm row opens the work in All work", shell.view == .allWork && shell.currentID == SampleData.reviewID, "view=\(shell.view) currentID=\(String(describing: shell.currentID)) | \(lastClick)")
            }
            await settle(0.8)
            let before = shell.currentID
            await clickAny(["Replace old banner", "Canceled"])
            await settle(0.4)
            check("a row with nowhere to go (not in the list) does nothing", shell.currentID == before && shell.view == .allWork, "currentID=\(String(describing: shell.currentID)) | \(lastClick)")
            check("opening rows sent nothing", gateway.clears.isEmpty, "clears=\(gateway.clears.count)")

            // 3) Clear 진행 중: 버튼을 누르면 요청 하나, 다시 눌러도 하나. 서버가 받은 뒤에는 결정 줄만 남고 Clear 버튼은 없다
            gateway.reset(.changes, clear: .hang)
            store.reset()
            shell.openAllWork()
            await store.refresh()
            await settle()
            await click(text: "Clear", in: panelWindow)
            await settle(0.5)
            check("click Clear sends one request and shows it in progress", gateway.clears.count == 1 && store.isClearing, "clears=\(gateway.clears.count) clearing=\(store.isClearing) | \(lastClick)")
            await click(text: "Clear", in: panelWindow)
            await settle(0.4)
            check("a second click while in progress sends nothing more", gateway.clears.count == 1, "clears=\(gateway.clears.count)")
            capture(edge, "summary-3-clearing")
            gateway.releaseHeld()
            await settle(1.2)
            let rest = shell.summaryContent
            check("after the server took it only the decision row stays and Clear is gone", rest?.rows.map(\.needsAnswer) == [true] && rest?.canClear == false && !store.isClearing && locate("Clear", in: panelWindow) == nil, "rows=\(rest?.rows.map(\.title) ?? []) canClear=\(String(describing: rest?.canClear))")
            check("the same card is now titled Needs your answer (questions only, Clear hidden)", rest?.title == "Needs your answer" && rest?.canClear == false, "title=\(rest?.title ?? "-") canClear=\(String(describing: rest?.canClear))")
            check("Clear changed no decision or work", shell.reviewQueue.contains(SampleData.reviewID) || !s4, "reviewQueue=\(shell.reviewQueue.count)")
            capture(edge, "summary-4-after-clear")

            // 4) ⌥ Space로 접었다 다시 열어도 결정 줄은 그대로다 (읽음은 결정이 아니다)
            shell.togglePanel()
            await settle(0.5)
            shell.togglePanel()
            await settle(1.2)
            check("closing and reopening keeps the Needs your answer row", shell.summaryContent?.rows.first?.needsAnswer == true && shell.summaryContent?.canClear == false, "rows=\(shell.summaryContent?.rows.count ?? 0)")

            // 5) 충돌(409): 성공이라 하지 않고 자동 재전송 없이 다시 조회, 새 변화가 보인다
            gateway.reset(.changes, clear: .conflict)
            store.reset()
            shell.openAllWork()
            await store.refresh()
            await settle()
            await click(text: "Clear", in: panelWindow)
            await settle(1.2)
            let titles = shell.summaryContent?.rows.map(\.title) ?? []
            check("409: refreshed notice, the late change is shown, nothing was resent", store.message == "This changed somewhere else. It's been refreshed." && titles.contains("Deploy demo environment") && gateway.clears.count == 1, "message=\(store.message ?? "-") rows=\(titles) clears=\(gateway.clears.count)")
            capture(edge, "summary-5-conflict")

            // 6) Clear가 나간 사이 Esc로 접는다: 이미 나간 요청은 정직한 결과를 돌려주고, 다시 열면 지금 상태다
            gateway.reset(.changes, clear: .hang)
            store.reset()
            shell.openAllWork()
            await store.refresh()
            await settle()
            await click(text: "Clear", in: panelWindow)
            await settle(0.4)
            sendKey("\u{1B}", code: kVK_Escape, to: panelWindow)
            await settle(0.4)
            check("Esc closes the panel while the request is out", !shell.panelOpen && gateway.clears.count == 1, "open=\(shell.panelOpen) clears=\(gateway.clears.count)")
            gateway.releaseHeld()
            await settle(1)
            check("the late 200 still lands in the store; no second request", gateway.clears.count == 1 && !store.isClearing && store.summary?.items.map(\.needsAnswer) == [true], "items=\(store.summary?.items.count ?? -1) clears=\(gateway.clears.count)")

            // 7) 계정이 떠남(같은 UUID 재로그인 포함): 늦은 응답은 새 세션에 반영되지 않는다
            gateway.reset(.changes, clear: .hang)
            store.reset()
            shell.openAllWork()
            await store.refresh()
            await settle()
            await click(text: "Clear", in: panelWindow)
            await settle(0.4)
            edge.chat?.scope.accountLeft()
            let readsBefore = gateway.reads
            gateway.releaseHeld()
            await settle(1)
            check("account left: the store is empty and the late response read nothing", store.summary == nil && !store.isClearing && store.message == nil && gateway.reads == readsBefore, "summary=\(String(describing: store.summary)) reads \(readsBefore)->\(gateway.reads)")

            // 8) B: 질문만 남은 처음부터 — 같은 카드, 캡션 Needs your answer, Clear 없음. 질문은 지워지지 않는다
            // 앞 단계가 Clear를 붙잡아 두는 동작(.hang)으로 남겨 둔 서버 반응을 이어받지 않는다: 이 뒤 단계들은 Clear · 확정을 정상으로 받는 서버에서 시작한다
            gateway.reset(.questionsOnly, clear: .apply, baseline: .apply)
            store.reset()
            shell.openAllWork()
            await store.refresh()
            await settle()
            let asking = shell.summaryContent
            check("B: questions only from the start: the same card titled Needs your answer, no Clear", asking?.title == "Needs your answer" && asking?.canClear == false && asking?.rows.count == 2 && gateway.clears.isEmpty, "title=\(asking?.title ?? "-") rows=\(asking?.rows.count ?? 0) ocrClear=\(String(describing: locate("Clear", in: panelWindow)))")
            capture(edge, "summary-6-questions-only")

            // 9) D-7: 해석 못 한 변화는 줄을 남기고 Clear를 막는다 / 결정 읽기 실패는 안전한 변화의 Clear를 막지 않는다 / 정상 잘림은 Clear 가능
            gateway.reset(.uninterpretable)
            store.reset()
            shell.openAllWork()
            await store.refresh()
            await settle()
            let hidden = shell.summaryContent
            check("D-7: an uninterpretable change stays on screen, says so, and Clear is blocked", hidden?.rows.count == 3 && hidden?.notes == [.couldNotShow] && hidden?.canClear == false && shell.clearSummary() == nil && gateway.clears.isEmpty, "rows=\(hidden?.rows.count ?? 0) notes=\(String(describing: hidden?.notes)) canClear=\(String(describing: hidden?.canClear)) ocrClear=\(String(describing: locate("Clear", in: panelWindow)))")
            capture(edge, "summary-7-uninterpretable")
            gateway.reset(.decisionsUnavailable)
            store.reset()
            shell.openAllWork()
            await store.refresh()
            await settle()
            let noQuestions = shell.summaryContent
            check("a decisions read failure alone does not block a safe change Clear", noQuestions?.notes == [.couldNotLoadQuestions] && noQuestions?.canClear == true, "notes=\(String(describing: noQuestions?.notes)) canClear=\(String(describing: noQuestions?.canClear))")
            gateway.reset(.truncated)
            store.reset()
            shell.openAllWork()
            await store.refresh()
            await settle()
            let more = shell.summaryContent
            check("normal truncation says More changes are available and Clear works", more?.notes == [.moreAvailable] && more?.canClear == true, "notes=\(String(describing: more?.notes)) canClear=\(String(describing: more?.canClear))")
            await click(text: "Clear", in: panelWindow)
            await settle(1.2)
            check("…then the next read shows the rest, never an all-handled message", gateway.clears.count == 1 && shell.summaryContent?.rows.count == 2 && shell.summaryContent?.notes == [], "clears=\(gateway.clears.count) rows=\(shell.summaryContent?.rows.count ?? 0) clearBehavior=\(gateway.behavior) | \(lastClick)")

            // 10) C: 첫 사용의 기준점 확정은 정상 표시가 된 뒤에만 한 번
            // a) 패널이 닫힌 동안 반영된 응답은 보이지 않았다: 확정 0. 처음 보이는 그때(⌥ Space) 한 번
            shell.dismiss()
            await settle(0.4)
            gateway.reset(.firstUse)
            store.reset()
            await store.refresh()
            await settle(0.6)
            check("C: a response applied while the panel is closed is not confirmed", gateway.baselines.isEmpty && !shell.panelOpen, "baselines=\(gateway.baselines.count)")
            shell.togglePanel()
            await settle(1.4)
            check("C: it is confirmed once when it is first shown, then read again (baseline initialized, new run result shown without any Clear)", gateway.baselines == ["i1.sample-first-use"] && store.summary?.baseline == .initialized && (shell.summaryContent?.rows.map(\.title).contains("Onboarding design draft") ?? false) && gateway.clears.isEmpty, "baselines=\(gateway.baselines) baseline=\(String(describing: store.summary?.baseline)) rows=\(shell.summaryContent?.rows.map(\.title) ?? []) clearBehavior=\(gateway.behavior)")
            capture(edge, "summary-8-first-use-confirmed")
            // b) Chats가 보이는 동안 반영된 응답: 확정 0, All work로 돌아오는 그때 한 번
            gateway.reset(.firstUse)
            store.reset()
            sendKey("3", code: kVK_ANSI_3, flags: .command, to: panelWindow)
            await settle(0.8)
            await store.refresh()
            await settle(0.5)
            check("C: a response applied while Chats is shown is not confirmed", shell.view == .chats && gateway.baselines.isEmpty, "view=\(shell.view) baselines=\(gateway.baselines.count)")
            sendKey("2", code: kVK_ANSI_2, flags: .command, to: panelWindow)
            await settle(1.2)
            check("C: it is confirmed once when All work is shown again", shell.view == .allWork && gateway.baselines.count == 1, "view=\(shell.view) baselines=\(gateway.baselines.count)")
            // c) 확정이 나간 사이 Esc로 접는다: 이미 나간 요청은 정직한 결과를 돌려주고 두 번 보내지 않는다
            gateway.reset(.firstUse, baseline: .hang)
            store.reset()
            shell.openAllWork()
            await store.refresh()
            await settle(0.5)
            check("C: the confirm is out and in progress", gateway.baselines.count == 1 && store.isConfirmingBaseline, "baselines=\(gateway.baselines.count) confirming=\(store.isConfirmingBaseline)")
            sendKey("\u{1B}", code: kVK_Escape, to: panelWindow)
            await settle(0.4)
            gateway.releaseHeld()
            await settle(1.2)
            check("C: the request already sent reports its honest result after Esc; no second request", !shell.panelOpen && gateway.baselines.count == 1 && store.summary?.baseline == .initialized && !store.isConfirmingBaseline, "open=\(shell.panelOpen) baselines=\(gateway.baselines.count) baseline=\(String(describing: store.summary?.baseline))")
            // d) 409: 자동 재전송 없이 보이는 응답 그대로, 다음 정상 표시(새 조회)에서만 다시
            gateway.reset(.firstUse, baseline: .conflict)
            store.reset()
            shell.togglePanel()
            await settle(1.0)
            let afterConflict = gateway.baselines.count
            try? await Task.sleep(for: .milliseconds(800))
            check("C: 409 is never resent and the visible response stays", afterConflict == 1 && gateway.baselines.count == 1 && store.summary?.baseline == .neverCleared, "baselines=\(gateway.baselines.count) baseline=\(String(describing: store.summary?.baseline))")
            await store.refresh()
            await settle(0.8)
            check("C: the next normal display (a new read) gets one new attempt", gateway.baselines.count == 2, "baselines=\(gateway.baselines.count)")
            finish()
        }
    }
}
#endif
