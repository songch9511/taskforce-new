#if os(macOS) && DEBUG
import AppKit
import Carbon.HIToolbox
import TaskforceKit

/// Release 표면의 앱 안 합성 조작 (`-TF_RELEASE_SURFACES YES -TFSampleData -TFSampleSummaryEnglish -TFEdgeInteractRelease <로그 파일> [-TFEdgeInteractShots <폴더>]`):
/// Release에서 켜지는 표면(Edge 셸 + All work + S4 Review + C3 복귀 요약)만 있고 Chats(B3) · 프로젝트 묶음(S3b) · 기억 · 0.2.0 설정 창이 **없는** 실행을, 진짜 패널 창에 AppKit 이벤트를 `NSApp.sendEvent`로 흘려 확인한다.
/// 이것은 **서명된 Release 앱이 아니다**: 격리 Debug 빌드가 `EdgeSurfaces.release`와 같은 표면을 만든 것이고, 가짜 서버(`SampleReturnSummaryGateway` · `SampleReviewServer`)라 네트워크 · 계정 · AI 호출이 없다.
/// OS 수준의 포인터 · 키보드 입력도 IME도 VoiceOver도 아니다 (앱 프로세스 안에서 만든 이벤트): 로그에 그렇게 적는다.
extension EdgeInteraction {
    static var releaseLogPath: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-TFEdgeInteractRelease"), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    static func runReleaseIfRequested(_ edge: EdgeShellController) {
        guard let logPath = releaseLogPath, SampleData.isEnabled else { return }
        Task { @MainActor in
            let shell = edge.shell
            let panelWindow = edge.panel.panel
            var lines: [String] = ["합성 조작(앱 프로세스 안 NSApp.sendEvent) — OS 수준 포인터 · 키보드 · IME · VoiceOver 아님, 서명된 Release 앱 아님. Release 표면(EdgeSurfaces.release)의 격리 Debug 실행, 가짜 서버"]
            func settle(_ seconds: Double = 0.6) async { try? await Task.sleep(for: .seconds(seconds)) }
            func check(_ name: String, _ ok: Bool, _ seen: String) { lines.append("\(ok ? "PASS" : "FAIL") \(name) — \(seen)") }
            @MainActor func finish() {
                let failed = lines.filter { $0.hasPrefix("FAIL") }.count
                let passed = lines.filter { $0.hasPrefix("PASS") }.count
                lines.append("RESULT pass=\(passed) fail=\(failed)")
                try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8)
                if failed > 0 { exit(1) }
                NSApplication.shared.terminate(nil)
            }
            @MainActor func clickAny(_ phrases: [String]) async {
                for phrase in phrases where locate(phrase, in: panelWindow) != nil {
                    await click(text: phrase, in: panelWindow)
                    return
                }
                lastClick = "글자를 찾지 못함 (\(phrases.joined(separator: " | "))) · \(lastLocate) · \(ownership(edge))"
            }
            await settle(1.5)

            // 1) 이 프로세스가 실제로 만든 것 (Chats 런타임 · 기억 · 0.2.0 설정 창이 없다)
            check("the surfaces are the Release set", EdgeSurfaces.current == .release, "current=\(EdgeSurfaces.current)")
            check("no Chats runtime exists in this process", AppRuntime.existingChatRuntime == nil && edge.chat == nil && SettingsWindowModel.shared.chatRuntime == nil && !shell.chatsEnabled, "existing=\(String(describing: AppRuntime.existingChatRuntime)) edge.chat=\(String(describing: edge.chat))")
            check("no project groups (S3b): the shell has no membership store", shell.contexts == nil, "contexts=\(String(describing: shell.contexts))")
            check("S4 Review and the C3 summary are connected", shell.review != nil && shell.summary != nil, "review=\(shell.review != nil) summary=\(shell.summary != nil)")
            check("Settings stays the legacy window (Plan & usage)", MacSettingsRootKind.current == .legacy, "kind=\(MacSettingsRootKind.current)")

            // 2) 레일: 고정 칸은 All work · More 둘뿐
            check("the rail has two fixed controls (no Chats item)", shell.controls == [.allWork, .more] && shell.controls.map(\.label) == ["All work", "More"], "controls=\(shell.controls.map(\.label))")

            // 3) ⌥ Space와 같은 길로 연다: 마지막에 본 화면(All work) 위에 카드가 읽힌다
            shell.togglePanel()
            await settle(1.2)
            let rows = shell.summaryContent?.rows.count ?? 0
            check("⌥ Space opens the Edge panel on All work with the ReturnSummary card on top", shell.panelOpen && shell.view == .allWork && rows > 0, "view=\(shell.view) rows=\(rows)")
            edge.externalInteraction()
            edge.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
            check("an outside click or key loss cannot collapse the panel during this unattended run", shell.panelOpen && shell.view == .allWork && edge.ignoresExternalDismissal, "panelOpen=\(shell.panelOpen) ignores=\(edge.ignoresExternalDismissal)")
            capture(edge, "release-1-all-work")

            // 4) ⌘3 · ⌘N은 연결이 없다: 화면이 바뀌지 않는다
            sendKey("3", code: kVK_ANSI_3, flags: .command, to: panelWindow)
            await settle(0.5)
            check("⌘3 does nothing (no Chats)", shell.panelOpen && shell.view == .allWork, "view=\(shell.view)")
            sendKey("n", code: kVK_ANSI_N, flags: .command, to: panelWindow)
            await settle(0.5)
            check("⌘N does nothing (no new chat)", shell.panelOpen && shell.view == .allWork, "view=\(shell.view)")
            check("the panel never offers a Chats screen", !EdgeKeyCommand.allCommandsListened(by: shell).contains(.chats) && !EdgeKeyCommand.allCommandsListened(by: shell).contains(.newChat), "listened=\(EdgeKeyCommand.allCommandsListened(by: shell))")
            sendKey("2", code: kVK_ANSI_2, flags: .command, to: panelWindow)
            await settle(0.4)
            check("⌘2 still opens All work", shell.panelOpen && shell.view == .allWork, "view=\(shell.view)")

            // 5) S4: 카드의 confirm 줄이 Review 페이지를 열고, 1 키가 정확히 한 번 Confirm을 보낸다 (가짜 답 서버)
            let server = SampleReviewServer()
            edge.launcher.now?.installSampleReview(server)
            await clickAny(["Send proposal v2", "Needs your answer"])
            await settle(0.8)
            check("the confirm row opens its Review page", shell.view == .review && shell.shownReview?.id == SampleData.reviewID, "view=\(shell.view) shown=\(String(describing: shell.shownReview?.title)) | \(lastClick)")
            capture(edge, "release-2-review")
            sendKey("1", code: kVK_ANSI_1, to: panelWindow)
            await settle(1.2)
            check("key 1 sends exactly one Confirm for that item", server.requests.count == 1 && server.requests.first?.id == SampleData.reviewID && server.requests.first?.answer == .confirm, "requests=\(server.requests.count) answer=\(String(describing: server.requests.first?.answer))")
            sendKey("2", code: kVK_ANSI_2, flags: .command, to: panelWindow)
            await settle(0.6)
            check("⌘2 returns to All work and the card is still there", shell.view == .allWork && shell.summaryContent != nil, "view=\(shell.view)")
            capture(edge, "release-3-after-confirm")
            finish()
        }
    }
}

extension EdgeKeyCommand {
    /// 셸이 듣는 키 명령 전부 (Release 표면 확인용)
    @MainActor static func allCommandsListened(by shell: EdgeShellModel) -> [EdgeKeyCommand] {
        [.escape, .review, .allWork, .chats, .newChat].filter { shell.listens(to: $0) }
    }
}
#endif
