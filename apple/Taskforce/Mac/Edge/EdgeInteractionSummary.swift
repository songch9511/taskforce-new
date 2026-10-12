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
                try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8)
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
            finish()
        }
    }
}
#endif
