import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// Sessions의 "Resume here" (OA 외부 세션 PR2m, DZ-2 · 3 · 4 · 7 · 8)의 실제 화면을 PNG로 남긴다. **평소에는 아무것도 하지 않는다**:
/// 환경 변수 `TF_ATTACH_SHOTS`(폴더)가 있을 때만 돈다 — `TEST_RUNNER_TF_ATTACH_SHOTS=<폴더> xcodebuild test … -only-testing:TaskforceTests/AttachSnapshotTests`.
/// 시험 호스트 안에서 진짜 패널 창(`EdgeShellController`의 메인 패널 · 세션 패널)을 가짜 서버 · 가짜 런타임 · 가짜 훑기로 열어 그린다: **설치된 앱 · 이 Mac의 실제 Claude 기록 · 서버를 쓰지 않는다**.
/// 파일: `<light|dark>-<장면>.png` (창들을 화면 자리 그대로 한 장에 얹는다)
@MainActor
struct AttachSnapshotTests {
    typealias Fx = IssueSnapshotData

    private func output() -> URL? {
        guard let path = ProcessInfo.processInfo.environment["TF_ATTACH_SHOTS"], !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    private func until(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // MARK: 촬영

    /// 창들을 데스크톱 색 위에 화면 자리 그대로 놓고 PNG로 쓴다 (`SavedChatsSnapshotTests`와 같은 방식)
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

    // MARK: 가짜

    /// 확정이 도는 중인 모습을 위해 `prepareAttach`를 붙잡는 가짜 런타임 (`release()`까지)
    final class GatedRuntime: ExternalSessionAttaching, @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [CheckedContinuation<Void, Never>] = []
        var refusal: AttachRefusal?
        var gates = false

        func release() {
            let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                defer { waiting = [] }
                return waiting
            }
            for continuation in pending { continuation.resume() }
        }

        func prepareAttach(sessionID: String, folder: String) async -> Result<AttachPlan, AttachRefusal> {
            if gates { await withCheckedContinuation { continuation in lock.withLock { waiting.append(continuation) } } }
            if let refusal { return .failure(refusal) }
            return .failure(.notReady)
        }

        func commitAttach(_ plan: AttachPlan, agentSessionID: UUID, server: AttachServerFacts) async -> AttachRefusal? { .server }
        func cancelAttach(_ plan: AttachPlan) async {}
    }

    // MARK: 견본

    private static let now = Date()
    private static let folder = "/Users/sample/taskforce"

    private static func row(_ n: Int, _ title: String, _ status: ExternalSessionStatus, client: ExternalSessionClient = .terminal, minutes: Double, folder: String = AttachSnapshotTests.folder) -> ExternalSessionRow {
        ExternalSessionRow(
            id: EdgeExternalSessionsTests.uuid(n), ref: String(repeating: "c", count: 64), title: title, folderPath: folder, groupPath: folder,
            lastActivity: now.addingTimeInterval(-minutes * 60), created: now.addingTimeInterval(-86_400), client: client, status: status
        )
    }

    /// DZ-1 비슷한 섞인 줄: 쉬는 터미널 줄(Resume here가 붙는다) · 쉬는 데스크톱 줄 · 터미널이 쥔 줄 · 데스크톱이 쥔 줄 · 모르는 줄
    private static let idleTitle = "Rewrite the pricing page copy for the 3-day trial banner"
    private static func mix() -> [ExternalSessionRow] {
        [
            row(1, idleTitle, .available, minutes: 40),
            row(2, "Add RLS test for agent_sessions", .available, client: .claudeDesktop, minutes: 95),
            row(3, "Fix launcher focus after sleep", .held(.terminal), minutes: 2),
            row(4, "Review migration order for the invoice table", .held(.claudeApp), client: .claudeDesktop, minutes: 1),
            row(5, "Source marks audit", .couldNotCheck, minutes: 300),
        ]
    }

    private static func many() -> [ExternalSessionRow] {
        (0..<18).map { n in
            row(100 + n, n == 0 ? "Rewrite the pricing page copy for the 3-day trial banner and the annual plan table so that every card says the same thing in both languages"
                : "Session \(n) in a project with a rather long folder name", .available, minutes: Double(40 + n * 25),
                folder: n % 2 == 0 ? "/Users/sample/taskforce-marketing-site-with-a-very-long-folder-name" : AttachSnapshotTests.folder)
        }
    }

    // MARK: 세계

    @MainActor
    struct World {
        /// 계정 경계가 약하게 쥔 로그인 저장소를 장면이 끝날 때까지 붙든다 (놓으면 계정이 사라져 게이트가 닫힌다)
        let account: AppChatAccount
        let controller: EdgeShellController
        let runtime: ChatRuntime
        let gateway: IssueSampleGateway
        let attach: ExternalSessionAttachModel
        let gated: GatedRuntime
        var shell: EdgeShellModel { controller.shell }
    }

    private func world(
        rows: [ExternalSessionRow], availability: AgentAttachAvailability = .enabled, word: String? = nil, sessions: IssueSampleGateway.SessionScenario = .none,
        hold: ExternalWriterVerdict? = nil, noMessages: Bool = false, gates: Bool = false, refusal: AttachRefusal? = nil
    ) async throws -> World {
        let account = try AppChatAccount.make()
        let gateway = IssueSampleGateway()
        gateway.sessions = sessions
        gateway.hasNoMessages = noMessages
        let runtime = ChatRuntime(gateway: gateway, contextGateway: IssueSampleContextGateway(), scope: account.scope, now: { Date() }, issueScreens: true)
        runtime.localTranscriptTarget = { _ in nil }
        runtime.attachedHold = { _ in hold }
        let counter = EdgeExternalSessionsTests.Counter()
        counter.set(rows)
        let list = ExternalSessionsStore(scope: account.scope, scan: { counter.scan() }, seen: InMemoryExternalSessionSeenStore(Date(timeIntervalSinceNow: -10_000)), pollInterval: 3600)
        let gated = GatedRuntime()
        gated.gates = gates
        gated.refusal = refusal
        let bridge = UUID()
        let connection = UUID()
        let server = ExternalSessionAttachServer(
            bridgeID: { bridge }, availability: { availability },
            target: { _ in ExternalSessionAttachTarget(connectionID: word == nil ? connection : nil, word: word) },
            attach: { _, _, _, _ in throw APIError.transport("offline") }, readSession: { _ in nil }
        )
        let attach = ExternalSessionAttachModel(scope: account.scope, runtime: gated, server: server)
        let controller = EdgeShellController(
            launcher: LauncherModel(configurationError: "test"), chat: runtime, assistantWindows: false, injectedExternalSessions: list, injectedAttach: attach
        )
        controller.ignoresExternalDismissal = true
        controller.shell.reduceMotion = true
        controller.shell.accountChanged(SampleData.userID)
        controller.shell.update(Fx.snapshot(seeds: Fx.seeds))
        if let issues = runtime.issues {
            await runtime.contexts?.refresh()
            await issues.numbers.ensure(Fx.seeds.map { Fx.issue($0.number) })
            await issues.sessions.refresh()
            controller.shell.sessionsChanged()
        }
        await list.refresh()
        controller.followPanel()
        return World(account: account, controller: controller, runtime: runtime, gateway: gateway, attach: attach, gated: gated)
    }

    private func finish(_ w: World) async {
        w.gated.release()
        w.controller.sessionPanel?.hide()
        w.shell.dismiss()
        w.controller.followPanel()
        await pause(0.3)
    }

    /// 한 장면을 라이트 · 다크로 찍는다: `setup`이 장면을 만들고 창이 자리를 잡을 때까지 기다린 뒤 `windows`를 찍는다
    private func scene(
        _ name: String, directory: URL, rows: [ExternalSessionRow] = AttachSnapshotTests.mix(), availability: AgentAttachAvailability = .enabled, word: String? = nil,
        hovered: Set<String> = [], sessions: IssueSampleGateway.SessionScenario = .none, hold: ExternalWriterVerdict? = nil, noMessages: Bool = false, gates: Bool = false,
        refusal: AttachRefusal? = nil, setup: @MainActor (World) async -> Void, windows: @MainActor (World) -> [NSWindow]
    ) async throws {
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let w = try await world(rows: rows, availability: availability, word: word, sessions: sessions, hold: hold, noMessages: noMessages, gates: gates, refusal: refusal)
            ExternalSessionLineSnapshot.hoveredTitles = hovered
            defer { ExternalSessionLineSnapshot.hoveredTitles = [] }
            w.controller.panel.panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            w.controller.sessionPanel?.panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            await setup(w)
            await pause(1.0)
            w.controller.followPanel()
            await pause(0.6)
            write(windows(w), to: directory.appendingPathComponent("\(dark ? "dark" : "light")-\(name).png"), dark: dark)
            await finish(w)
        }
    }

    private func openSessions(_ w: World, expecting gate: ExternalSessionAttachModel.Gate = .ready) async {
        w.shell.openSessions()
        let reached = await until { w.attach.gate == gate }
        if !reached { Issue.record("게이트가 \(gate)이 되지 않았다: \(w.attach.gate)") }
    }

    // MARK: 장면

    @Test func rendersTheResumeHereScreensForTheDesignComparison() async throws {
        guard let directory = output(), EdgeRailPanelController.screen != nil else { return }
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }
        let idle = Self.row(1, Self.idleTitle, .available, minutes: 40)
        let panel: @MainActor (World) -> [NSWindow] = { [$0.controller.panel.panel] }

        // 줄: 쉬는 줄에만 Resume here가 있다 (호버 · 포커스에서 보인다, DZ-1 · 2)
        try await scene("01-sessions-mix", directory: directory, setup: { await self.openSessions($0) }, windows: panel)
        try await scene("02-hover-resume-here", directory: directory, hovered: [Self.idleTitle, "Add RLS test for agent_sessions"], setup: { await self.openSessions($0) }, windows: panel)

        // 제자리 확인 (DZ-3), 거절 (DZ-4), 도는 중
        try await scene("03-confirm", directory: directory, hovered: [Self.idleTitle], setup: { w in
            await self.openSessions(w)
            w.shell.resumeHere(idle)
        }, windows: panel)
        try await scene("04-refused-claude", directory: directory, hovered: [Self.idleTitle], refusal: .held(.claudeApp), setup: { w in
            await self.openSessions(w)
            w.shell.resumeHere(idle)
            await w.shell.confirmResume(idle).value
        }, windows: panel)
        try await scene("04-refused-terminal", directory: directory, hovered: [Self.idleTitle], refusal: .held(.terminal), setup: { w in
            await self.openSessions(w)
            w.shell.resumeHere(idle)
            await w.shell.confirmResume(idle).value
        }, windows: panel)
        try await scene("04-refused-could-not-check", directory: directory, hovered: [Self.idleTitle], refusal: .couldNotCheck, setup: { w in
            await self.openSessions(w)
            w.shell.resumeHere(idle)
            await w.shell.confirmResume(idle).value
        }, windows: panel)
        try await scene("04-refused-version", directory: directory, hovered: [Self.idleTitle], refusal: .version, setup: { w in
            await self.openSessions(w)
            w.shell.resumeHere(idle)
            await w.shell.confirmResume(idle).value
        }, windows: panel)
        try await scene("05-working", directory: directory, hovered: [Self.idleTitle], gates: true, setup: { w in
            await self.openSessions(w)
            w.shell.resumeHere(idle)
            _ = w.shell.confirmResume(idle)
            await self.pause(0.4)
        }, windows: panel)

        // 이 Mac이 준비되지 않았다: 줄이 그 단어를 보인다 · 서버가 닫았다: 단추가 없다
        try await scene("06-not-connected", directory: directory, word: "Not connected", hovered: [Self.idleTitle], setup: { await self.openSessions($0, expecting: .notReady(word: "Not connected")) }, windows: panel)
        try await scene("07-flag-off", directory: directory, availability: .disabled, hovered: [Self.idleTitle], setup: { await self.openSessions($0, expecting: .unavailable) }, windows: panel)

        // 길게 (DZ-5): 긴 제목 · 긴 폴더 이름 · 18줄 · Show all
        try await scene("08-long", directory: directory, rows: Self.many(), hovered: ["Rewrite the pricing page copy for the 3-day trial banner and the annual plan table so that every card says the same thing in both languages"], setup: { w in
            await self.openSessions(w)
        }, windows: panel)

        // 이어받은 세션 패널 (DZ-7: 첫 메시지 전, DZ-8: 막힘)
        let openSession: @MainActor (World) async -> Void = { w in
            w.shell.openAllWork()
            w.shell.openIssue(Fx.issue(139))
            w.shell.openSession(Fx.session(1))
            w.controller.followPanel()
            await self.pause(0.8)
            w.controller.sessionPanel?.show()
            await self.pause(1.4)
            w.controller.sessionPanel?.fit()
        }
        let both: @MainActor (World) -> [NSWindow] = { w in [w.controller.sessionPanel?.panel, w.controller.panel.panel].compactMap { $0 } }
        try await scene("09-session-before-first-message", directory: directory, sessions: .finished, noMessages: true, setup: openSession, windows: both)
        try await scene("10-session-blocked", directory: directory, sessions: .finished, hold: .held(.claudeApp), setup: openSession, windows: both)
        try await scene("10-session-blocked-terminal", directory: directory, sessions: .finished, hold: .held(.terminal), setup: openSession, windows: both)
        try await scene("10-session-blocked-could-not-check", directory: directory, sessions: .finished, hold: .unknown, setup: openSession, windows: both)
    }
}
