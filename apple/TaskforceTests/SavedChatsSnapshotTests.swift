import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// 저장된 Claude 데스크톱 대화의 실제 화면을 PNG로 남긴다 (DZ `oa-desktop-chat-view-dz` 시트 1–6 비교용). **평소에는 아무것도 하지 않는다**:
/// 환경 변수 `TF_SAVED_CHATS_SHOTS`(폴더)가 있을 때만 돈다 — `TEST_RUNNER_TF_SAVED_CHATS_SHOTS=<폴더> xcodebuild test … -only-testing:TaskforceTests/SavedChatsSnapshotTests`.
/// 시험 호스트 안에서 진짜 패널 창(`EdgeShellController`의 메인 패널 · 저장된 대화 패널)을 가짜 서버 · 가짜 기록으로 열어 그린다: **설치된 앱 · 이 Mac의 실제 Claude 기록 · 서버를 쓰지 않는다**.
/// 파일: `<light|dark>-<장면>.png` (창들을 화면 자리 그대로 한 장에 얹는다). 설정 줄은 창 전체가 아니라 그 절만 그린다
@MainActor
struct SavedChatsSnapshotTests {
    typealias X = EdgeExternalSessionsTests
    typealias M = SavedChatsMacTests

    private func output() -> URL? {
        guard let path = ProcessInfo.processInfo.environment["TF_SAVED_CHATS_SHOTS"], !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    // MARK: 촬영

    /// 창들을 데스크톱 색 위에 화면 자리 그대로 놓고 PNG로 쓴다 (`SessionViewSnapshotTests`와 같은 방식)
    private func write(_ windows: [NSWindow], to url: URL, dark: Bool) {
        let visible = windows.filter(\.isVisible)
        guard let first = visible.first else { return }
        let union = visible.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        let margin: CGFloat = 24
        let size = CGSize(width: union.width + 2 * margin, height: union.height + 2 * margin)
        let scale: CGFloat = 2
        guard let context = CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        context.scaleBy(x: scale, y: scale)
        let hexes = dark ? ["2b2f36", "2e2b30", "2e2a26", "1c1718"] : ["7d8794", "857a80", "857968", "4a3c3e"]
        let colors = hexes.map { hex -> CGColor in
            let value = UInt32(hex, radix: 16) ?? 0
            return CGColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        }
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 0.42, 0.62, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: .zero, options: [])
        }
        for window in visible {
            guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let image = rep.cgImage else { continue }
            context.draw(image, in: CGRect(x: window.frame.minX - union.minX + margin, y: window.frame.minY - union.minY + margin, width: window.frame.width, height: window.frame.height))
        }
        guard let composed = context.makeImage() else { return }
        let out = NSBitmapImageRep(cgImage: composed)
        out.size = size
        try? out.representation(using: .png, properties: [:])?.write(to: url)
    }

    // MARK: 견본

    private static let now = Date()

    /// DZ 시트 1의 줄들 (시각 · 기기 이름)
    private static func listRows() -> [SavedChatRow] {
        [
            SavedChatRow(id: M.id(1), title: "Fix launcher focus after sleep", lastMessageAt: now.addingTimeInterval(-12 * 60), deviceName: "Daniel's MacBook Air"),
            SavedChatRow(id: M.id(2), title: "Pricing copy draft", lastMessageAt: now.addingTimeInterval(-2 * 3600), deviceName: "Daniel's MacBook Air"),
            SavedChatRow(id: M.id(3), title: nil, lastMessageAt: now.addingTimeInterval(-26 * 3600), deviceName: "Daniel's MacBook Air"),
            SavedChatRow(id: M.id(4), title: "Source marks audit", lastMessageAt: now.addingTimeInterval(-3 * 86_400), deviceName: "Daniel's MacBook Pro"),
            SavedChatRow(id: M.id(5), title: "Add RLS test for agent_sessions", lastMessageAt: now.addingTimeInterval(-9 * 86_400), deviceName: "Daniel's MacBook Air"),
        ]
    }

    private static func at(_ daysAgo: Double, _ minute: Double) -> Date { now.addingTimeInterval(-daysAgo * 86_400 + minute * 60) }

    private static func record(_ n: Int, _ role: String, _ body: String, tools: [String] = [], daysAgo: Double, minute: Double) -> SavedChatMessageRecord {
        SavedChatMessageRecord(
            id: UUID(uuidString: String(format: "dddddddd-0000-4000-8000-%012x", n))!, role: role, body: body, truncated: false, toolNames: tools, saidAt: at(daysAgo, minute), seq: Int64(n)
        )
    }

    /// DZ 시트 2의 대화 (Pricing copy draft)
    private static let pricing: [SavedChatMessageRecord] = [
        record(1, "user", "가격 페이지 3일 체험이랑 Lifetime 플랜 문구를 다시 써줘. 한국어 버전은 승인된 용어집이랑 맞춰서 확인해줘.", daysAgo: 2, minute: 0),
        record(2, "assistant", """
        The trial card and the Lifetime card now match the brief.

        - Trial card: the headline, button and footnote say 3 days instead of 7.
        - **Lifetime** card: only the launch price stays on the price line. The regular price moved to the footnote.
        - Korean: two uses of 평가판 are now 체험, as the glossary says.

        The changed strings are in `pricing.mdx` and `ko.json`.
        """, tools: ["Read", "Grep", "Glob", "Edit"], daysAgo: 2, minute: 4),
        record(3, "user", "Lifetime 카드는 가격만 바꾸고 문구 톤은 그대로 둬", daysAgo: 0, minute: -200),
        record(4, "assistant", "Understood. I reverted the tone changes on the Lifetime card and kept only the price line.", tools: ["Edit", "Edit"], daysAgo: 0, minute: -197),
        record(5, "user", "lint도 돌려줘", daysAgo: 0, minute: -150),
        record(6, "assistant", "Copy lint passed. The Korean strings match the glossary.", tools: ["Bash"], daysAgo: 0, minute: -146),
    ]

    private static let veryLongReply: String = (1...6).map {
        "Paragraph \($0): then I ran the copy lint over the whole content folder and it reported three double spaces, which I fixed in the same pass. The remaining differences between the English and Korean pages are intentional: the Korean page keeps the launch price on its own line and the English page puts it in the footnote."
    }.joined(separator: "\n\n")

    private static let manyTools: [String] = {
        let names = ["Read", "Grep", "Glob", "Edit", "Bash", "Task", "Write", "WebFetch", "mcp__plugin_figma_figma__get_design_context"]
        return (0..<40).map { names[$0 % names.count] }
    }()

    // MARK: 세계

    @MainActor
    struct World {
        let controller: EdgeShellController
        let backend: M.Backend
        let saved: SavedChatsStore
        let desktop: ClaudeAppSessionsModel
        let script: DeskScript
        var shell: EdgeShellModel { controller.shell }
        var saveWindow: NSWindow { controller.savedChatPanel!.panel }
    }

    /// - rows: 서버 쪽 목록 쪽들 · desktop: 살아 있는 데스크톱 세션(On this Mac의 Running in Claude 줄)을 넣는다
    private func world(pages: [[SavedChatRow]], desktop withDesktop: Bool = true) async throws -> World {
        let account = try AppChatAccount.make()
        let runtime = ChatRuntime(gateway: IssueSampleGateway(), contextGateway: IssueSampleContextGateway(), scope: account.scope, now: { Date() }, issueScreens: true)
        let script = DeskScript()
        let counter = X.Counter()
        if withDesktop {
            script.sessions = [EdgeSessionsTests.live(1, .busy)]
            counter.set([ExternalSessionRow(
                id: X.uuid(1), ref: String(repeating: "c", count: 64), title: "Review migration order for the invoice table", folderPath: "/Users/sample/taskforce", groupPath: "/Users/sample/taskforce",
                lastActivity: Self.now.addingTimeInterval(-5), created: Self.now.addingTimeInterval(-3600), client: .claudeDesktop, status: .held(.claudeApp)
            )])
        }
        let list = ExternalSessionsStore(scope: account.scope, scan: { counter.scan() }, seen: InMemoryExternalSessionSeenStore(Date(timeIntervalSinceNow: -10_000)), pollInterval: 3600)
        let desktop = ClaudeAppSessionsModel(poll: { script.poll() }, scope: account.scope, done: InMemoryClaudeAppDoneStore())
        let made = ClaudeAppRuntime.Made(sessions: desktop, opened: ClaudeAppOpenedMetric(send: { true }, scope: account.scope))
        let backend = M.Backend(pages: pages)
        let saved = M.store(backend, scope: account.scope)
        let controller = EdgeShellController(
            launcher: LauncherModel(configurationError: "test"), chat: runtime, assistantWindows: false, injectedExternalSessions: list, injectedDesktop: made, injectedSavedChats: saved
        )
        controller.ignoresExternalDismissal = true
        controller.shell.reduceMotion = true
        controller.shell.accountChanged(SampleData.userID)
        controller.shell.makeConversation = { id, cwd in ClaudeAppConversation(sessionID: id, cwd: cwd, source: TranscriptFake()) }
        await list.refresh()
        await desktop.pollOnce()
        await saved.refresh()
        controller.shell.desktopChanged()
        controller.followPanel()
        controller.followSavedChatPanel()
        return World(controller: controller, backend: backend, saved: saved, desktop: desktop, script: script)
    }

    private func finish(_ w: World) async {
        w.shell.dismiss()
        w.controller.followPanel()
        w.controller.followSavedChatPanel()
        await pause(0.3)
    }

    /// 한 장면을 라이트 · 다크로 찍는다: `setup`이 장면을 만들고(Sessions 열기 등) 창이 자리를 잡을 때까지 기다린 뒤 `windows`를 찍는다
    private func scene(
        _ name: String, directory: URL, pages: [[SavedChatRow]] = [Self.listRows()], desktop: Bool = true, messages: [UUID: [SavedChatMessageRecord]] = [M.id(2): SavedChatsSnapshotTests.pricing],
        setup: @MainActor (World) async -> Void, windows: @MainActor (World) -> [NSWindow]
    ) async throws {
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let w = try await world(pages: pages, desktop: desktop)
            for (chat, records) in messages { w.backend.setMessages(records, for: chat) }
            w.controller.panel.panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            w.saveWindow.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            await setup(w)
            await pause(1.0)
            w.controller.followPanel()
            w.controller.followSavedChatPanel()
            await pause(0.8)
            w.controller.followSavedChatPanel()
            await pause(0.5)
            write(windows(w), to: directory.appendingPathComponent("\(dark ? "dark" : "light")-\(name).png"), dark: dark)
            await finish(w)
        }
    }

    // MARK: 장면

    @Test func rendersTheSavedChatsScreensForTheDesignComparison() async throws {
        guard let directory = output(), EdgeRailPanelController.screen != nil else { return }
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }

        // 시트 1 · 목록 (Sessions의 셋째 절) · 읽기 패널이 왼쪽에
        try await scene("01-list", directory: directory, setup: { $0.shell.openSessions() }, windows: { [$0.controller.panel.panel] })
        try await scene("01-list-this-mac", directory: directory, pages: [Self.listRows().map { SavedChatRow(id: $0.id, title: $0.title, lastMessageAt: $0.lastMessageAt, deviceName: nil) }], desktop: false,
                        setup: { $0.shell.openSessions() }, windows: { [$0.controller.panel.panel] })
        try await scene("01-chat-open", directory: directory, setup: { w in
            w.shell.openSessions()
            await self.pause(0.6)
            w.shell.openSavedChat(M.id(2))
        }, windows: { [$0.saveWindow, $0.controller.panel.panel] })

        // 시트 2 · 읽기 전용 패널
        // 맨 위: 날짜 줄 · 보낸 말 · 접힌 도구 이름 한 줄 · 서식이 있는 답 (첫 한 번만)
        try await scene("02-chat-top", directory: directory, messages: [M.id(2): Array(Self.pricing.prefix(2))], setup: { w in
            w.shell.openSessions()
            await self.pause(0.5)
            w.shell.openSavedChat(M.id(2))
        }, windows: { [$0.saveWindow] })
        try await scene("02-chat-steps-open", directory: directory, messages: [M.id(2): Array(Self.pricing.prefix(2))], setup: { w in
            w.shell.openSessions()
            await self.pause(0.5)
            w.shell.openSavedChat(M.id(2))
            await self.pause(0.8)
            let timeline = SavedChatTimeline.make(w.shell.savedChatDetail?.messages ?? [], now: Date())
            for case .steps(let run) in timeline.entries where run.isGroup { w.controller.savedChatPanel?.presentation.steps.toggle(run) }
        }, windows: { [$0.saveWindow] })
        try await scene("02-chat-untitled", directory: directory, messages: [M.id(3): [Self.record(1, "user", "what changed in the last commit?", daysAgo: 1, minute: 0), Self.record(2, "assistant", "Two files changed: the rail layout and its test. The commit message says the capsule gap went from 8 to 6.", daysAgo: 1, minute: 3)]],
                        setup: { w in
                            w.shell.openSessions()
                            await self.pause(0.5)
                            w.shell.openSavedChat(M.id(3))
                        }, windows: { [$0.saveWindow] })
        try await scene("02-chat-loading", directory: directory, setup: { w in
            w.backend.messageGate = M.Gate()
            w.shell.openSessions()
            await self.pause(0.5)
            w.shell.openSavedChat(M.id(2))
        }, windows: { [$0.saveWindow] })
        try await scene("02-chat-failed", directory: directory, setup: { w in
            w.backend.failMessages(URLError(.notConnectedToInternet))
            w.shell.openSessions()
            await self.pause(0.5)
            w.shell.openSavedChat(M.id(2))
        }, windows: { [$0.saveWindow] })

        // 시트 3 · 지우기: 확인 → 지우는 중 → 실패
        try await scene("03-delete-confirm", directory: directory, setup: { w in
            w.shell.openSessions()
            await self.pause(0.5)
            w.shell.openSavedChat(M.id(2), confirmDelete: true)
        }, windows: { [$0.saveWindow] })
        try await scene("03-delete-deleting", directory: directory, setup: { w in
            let gate = M.Gate()
            w.backend.deleteGate = gate
            w.shell.openSessions()
            await self.pause(0.5)
            w.shell.openSavedChat(M.id(2), confirmDelete: true)
            await self.pause(0.6)
            Task { await w.shell.savedChatDetail?.confirmDelete() }
            await self.pause(0.4)
        }, windows: { [$0.saveWindow] })
        try await scene("03-delete-failed", directory: directory, setup: { w in
            w.backend.failDelete(APIError.transport("offline"))
            w.shell.openSessions()
            await self.pause(0.5)
            w.shell.openSavedChat(M.id(2), confirmDelete: true)
            await self.pause(0.6)
            await w.shell.savedChatDetail?.confirmDelete()
        }, windows: { [$0.saveWindow] })
        try await scene("03-delete-result", directory: directory, setup: { w in
            w.shell.openSessions()
            await self.pause(0.5)
            w.shell.openSavedChat(M.id(2), confirmDelete: true)
            await self.pause(0.6)
            await w.shell.savedChatDetail?.confirmDelete()
        }, windows: { [$0.controller.panel.panel] })

        // 시트 4 · 읽는 중 · 실패 · 빔 · 세션도 없음
        try await scene("04-checking", directory: directory, setup: { w in
            w.saved.reset()
            w.backend.pageGate = M.Gate()
            w.shell.openSessions()
        }, windows: { [$0.controller.panel.panel] })
        try await scene("04-failed", directory: directory, setup: { w in
            w.saved.reset()
            w.backend.failPages(URLError(.notConnectedToInternet))
            w.shell.openSessions()
        }, windows: { [$0.controller.panel.panel] })
        try await scene("04-none", directory: directory, pages: [[]], setup: { $0.shell.openSessions() }, windows: { [$0.controller.panel.panel] })
        try await scene("04-no-sessions", directory: directory, pages: [[]], desktop: false, setup: { $0.shell.openSessions() }, windows: { [$0.controller.panel.panel] })

        // 시트 5 · 길게: 200개(Show all · Show earlier) · 긴 제목 · 긴 기기 이름 · 아주 긴 답 · 도구 이름 40개
        let many: [SavedChatRow] = (0..<20).map { n in
            SavedChatRow(id: M.id(100 + n), title: n % 5 == 4 ? nil : "Rewrite the pricing page copy for the 3-day trial banner and the annual plan table \(n)", lastMessageAt: Self.now.addingTimeInterval(-Double(n + 1) * 3 * 3600),
                         deviceName: n % 3 == 0 ? "Daniel's MacBook Pro 16-inch (second floor)" : "Daniel's MacBook Air")
        }
        try await scene("05-expanded", directory: directory, pages: [many, many], desktop: false, setup: { w in
            w.shell.openSessions()
            await self.pause(0.5)
            w.shell.savedChatsExpanded = true
        }, windows: { [$0.controller.panel.panel] })
        try await scene("05-long-reply", directory: directory, messages: [M.id(2): [Self.record(1, "user", "Run the copy lint and explain every difference", daysAgo: 0, minute: -60), Self.record(2, "assistant", Self.veryLongReply, daysAgo: 0, minute: -55)]],
                        setup: { w in
                            w.shell.openSessions()
                            await self.pause(0.5)
                            w.shell.openSavedChat(M.id(2))
                        }, windows: { [$0.saveWindow] })
        try await scene("05-tools-40", directory: directory, messages: [M.id(2): [Self.record(1, "user", "migration 순서 정리하고 PR 열어줘", daysAgo: 0, minute: -60), Self.record(2, "assistant", "The migration order is fixed and the pull request is open.", tools: Self.manyTools, daysAgo: 0, minute: -55)]],
                        setup: { w in
                            w.shell.openSessions()
                            await self.pause(0.5)
                            w.shell.openSavedChat(M.id(2))
                        }, windows: { [$0.saveWindow] })
        try await scene("05-tools-40-open", directory: directory, messages: [M.id(2): [Self.record(1, "user", "migration 순서 정리하고 PR 열어줘", daysAgo: 0, minute: -60), Self.record(2, "assistant", "The migration order is fixed and the pull request is open.", tools: Self.manyTools, daysAgo: 0, minute: -55)]],
                        setup: { w in
                            w.shell.openSessions()
                            await self.pause(0.5)
                            w.shell.openSavedChat(M.id(2))
                            await self.pause(0.8)
                            let timeline = SavedChatTimeline.make(w.shell.savedChatDetail?.messages ?? [], now: Date())
                            for case .steps(let run) in timeline.entries where run.isGroup { w.controller.savedChatPanel?.presentation.steps.toggle(run) }
                        }, windows: { [$0.saveWindow] })
    }

    // MARK: 시트 6 · Settings › Account의 줄 (절만)

    /// - confirming: 확인 줄을 연다 · hold: 지우는 중으로 붙잡는다 · failing: 서버가 지우지 못한다 (원자적: 아무것도 지워지지 않았다)
    private func shootSettings(_ name: String, directory: URL, confirming: Bool = false, hold: Bool = false, failing: Bool = false) async throws {
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let scope = AccountScope(currentAccount: { SampleData.userID })
            let gate = M.Gate()
            let backend = M.Backend(pages: [Self.listRows()])
            if failing { backend.failDeleteAll(APIError.transport("offline")) }
            let store = SavedChatsStore(
                scope: scope, readPage: { try await backend.pageAsync($0, $1) }, readMessages: { _, _, _ in [] }, deleteChat: { _ in },
                deleteAll: {
                    if hold { await gate.wait() }
                    try backend.deleteAll()
                }
            )
            await store.refresh()
            let model = SettingsWindowModel.shared
            let previousStore = model.savedChats
            model.savedChats = store
            model.confirming = nil
            if confirming { model.confirming = .deleteAllSavedChats }
            if hold {
                Task { await model.deleteAllSavedChats() }
                await pause(0.4)
            }
            if failing { await model.deleteAllSavedChats() }
            let view = VStack(alignment: .leading, spacing: 24) { SettingsSavedChatsSection() }
                .padding(20)
                .frame(width: 560, alignment: .leading)
                .background(TFColor.bgSurface)
            let hosting = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            let fit = hosting.fittingSize
            window.setContentSize(NSSize(width: 560, height: max(fit.height, 80)))
            window.orderFrontRegardless()
            await pause(0.6)
            write([window], to: directory.appendingPathComponent("\(dark ? "dark" : "light")-\(name).png"), dark: dark)
            window.orderOut(nil)
            model.confirming = nil
            model.savedChats = previousStore
        }
    }

    @Test func rendersTheSettingsRowForTheDesignComparison() async throws {
        guard let directory = output(), EdgeRailPanelController.screen != nil else { return }
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }
        try await shootSettings("06-settings-row", directory: directory)
        try await shootSettings("06-settings-confirm", directory: directory, confirming: true)
        try await shootSettings("06-settings-deleting", directory: directory, hold: true)
        try await shootSettings("06-settings-failed", directory: directory, failing: true)
    }
}
