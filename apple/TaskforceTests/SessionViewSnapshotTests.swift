import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// 세션 보기 V1의 실제 화면을 PNG로 남긴다 (DZ `oa-session-view-dz` v2 비교용). **평소에는 아무것도 하지 않는다**:
/// 환경 변수 `TF_SESSION_VIEW_SHOTS`(폴더)가 있을 때만 돈다 — `TEST_RUNNER_TF_SESSION_VIEW_SHOTS=<폴더> xcodebuild test … -only-testing:TaskforceTests/SessionViewSnapshotTests`.
/// 시험 호스트 안에서 진짜 패널 창(`EdgeClaudeAppPanelController`)을 가짜 기록 · 가짜 폴 · 메모리 저장으로 열어 그린다: **설치된 앱 · 이 Mac의 실제 Claude 기록 · 서버를 쓰지 않는다**
@MainActor
struct SessionViewSnapshotTests {
    /// 견본 기록: 줄 · 신호 · 단계 본문이 모두 만든 값이다
    final class SampleSource: ClaudeAppTranscriptSource, @unchecked Sendable {
        let turns: [ClaudeAppTurn]
        let signals: ClaudeAppTranscriptSignals
        let details: [String: ClaudeAppToolDetail]

        init(turns: [ClaudeAppTurn], signals: ClaudeAppTranscriptSignals = ClaudeAppTranscriptSignals(), details: [String: ClaudeAppToolDetail] = [:]) {
            self.turns = turns
            self.signals = signals
            self.details = details
        }

        func open(sessionID: String, cwd: String?) -> ClaudeAppTranscriptLoad {
            var cursor = ClaudeAppTranscriptCursor(sessionID: sessionID)
            cursor.signals = signals
            return .page(ClaudeAppTranscriptPage(turns: turns, cursor: cursor, hasEarlier: false, skippedLines: 0))
        }

        func earlier(_ cursor: ClaudeAppTranscriptCursor) -> ClaudeAppTranscriptLoad { .unreadable }
        func newer(_ cursor: ClaudeAppTranscriptCursor) -> ClaudeAppTranscriptUpdate { .turns([], cursor: cursor, hasMore: false) }
        func detail(of turn: ClaudeAppTurn, cursor: ClaudeAppTranscriptCursor) -> ClaudeAppToolDetail? { details[turn.id] }
    }

    // MARK: 견본

    private static let now = Date()

    private static func at(_ secondsAgo: TimeInterval) -> Date { now.addingTimeInterval(-secondsAgo) }

    private static func tool(_ id: String, _ name: String, _ description: String? = nil, file: String? = nil, failed: Bool = false, ago: TimeInterval) -> ClaudeAppTurn {
        ClaudeAppTurn(id: id, kind: .tool(name: name, description: description), timestamp: at(ago), target: file, failed: failed)
    }

    private static func say(_ id: String, _ text: String, user: Bool = false, ago: TimeInterval) -> ClaudeAppTurn {
        ClaudeAppTurn(id: id, kind: user ? .user(text) : .assistant(text), timestamp: at(ago))
    }

    /// 긴 한 번: 말 → 단계 여섯(묶음) → 답(코드 · 목록 · 굵게 · 인라인 코드) → 두 번째 질문 → 단계 셋
    private static let longTurns: [ClaudeAppTurn] = [
        say("u1", "가격 페이지 3일 체험이랑 Lifetime 플랜 문구를 다시 써줘. 승인된 용어집이랑 맞춰서.", user: true, ago: 400),
        say("a1", "I'll read the pricing page and the glossary first.", ago: 395),
        tool("t1", "Read", file: "pricing.mdx", ago: 380),
        tool("t2", "Read", file: "glossary.md", ago: 360),
        tool("t3", "Grep", ago: 340),
        tool("t4", "Read", file: "TrialCard.tsx", ago: 320),
        tool("t5", "Edit", file: "pricing-page-hero-section-component-final.tsx", ago: 300),
        tool("t6", "Bash", "Run the copy lint", failed: true, ago: 280),
        say("a2", """
        The page had two blocks to change, and **both are updated** now.

        - Trial card: headline, button and footnote say `3 days`
        - Lifetime card: only the price line changed

        ```swift
        let trial = Trial(days: 3)
        let lifetime = Plan.lifetime(price: 79)
        ```

        1. Re-run the lint
        2. Check the Korean copy
        """, ago: 120),
        say("u2", "Korean copy도 같이 확인해줘", user: true, ago: 90),
        tool("t7", "Read", file: "ko.json", ago: 80),
        tool("t8", "Grep", ago: 70),
        tool("t9", "Read", file: "glossary.md", ago: 60),
    ]

    private static let details: [String: ClaudeAppToolDetail] = [
        "t6": ClaudeAppToolDetail(input: "{ \"command\": \"npm run lint:copy\" }", result: "error: trial headline still says 7 days", truncated: false),
        "t1": ClaudeAppToolDetail(input: "{ \"file_path\": \"/Users/sample/taskforce/pricing.mdx\" }", result: "# Pricing\n\nStart your 3-day trial", truncated: false),
    ]

    private static func tasks() -> [BackgroundTaskEvent] {
        [
            .started(taskID: "b1", toolUseID: nil, kind: .command, name: "Start dev server", at: at(200)),
            .started(taskID: "b2", toolUseID: nil, kind: .agent, name: "Review the pricing copy", at: at(150)),
            .started(taskID: "b3", toolUseID: nil, kind: .command, name: "Run the full test suite", at: at(120)),
            .finished(taskID: "b3", kind: .command, status: .failed, exitCode: 3, at: at(60)),
        ]
    }

    // MARK: 촬영

    private func output(_ environment: [String: String]) -> URL? {
        guard let path = environment["TF_SESSION_VIEW_SHOTS"], !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    /// 창 하나를 데스크톱 색 위에 놓고 PNG로 쓴다 (`EdgeSnapshot`의 `compose`와 같은 방식)
    private func write(_ window: NSWindow, to url: URL, dark: Bool) {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let image = rep.cgImage else { return }
        let margin: CGFloat = 24
        let size = CGSize(width: window.frame.width + 2 * margin, height: window.frame.height + 2 * margin)
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
        context.draw(image, in: CGRect(x: margin, y: margin, width: window.frame.width, height: window.frame.height))
        guard let composed = context.makeImage() else { return }
        let out = NSBitmapImageRep(cgImage: composed)
        out.size = size
        try? out.representation(using: .png, properties: [:])?.write(to: url)
    }

    private struct Scene {
        let name: String
        let turns: [ClaudeAppTurn]
        var state: ClaudeAppSessionState = .idle
        var signals = ClaudeAppTranscriptSignals()
        /// 단계 묶음 · 줄을 열고 닫는다 (줄 id → 본문은 이 대화가 읽는다)
        var prepare: @MainActor (EdgeClaudeAppPanelPresentation, ClaudeAppConversation?, [SessionEntry]) -> Void = { _, _, _ in }
        var tail = BackgroundTaskTail.Result.output(.text("> next dev\n  ▲ Next.js 16\n  - Local: http://localhost:3000\n ✓ Ready in 412ms", hasEarlier: false))
    }

    /// 열 줄을 넘는 코드 한 덩어리 (접힘 + Show all)
    private static let codeTurns: [ClaudeAppTurn] = [
        say("u1", "Show me the whole trial config", user: true, ago: 200),
        say("a1", "Here is the config:\n\n```json\n" + (0..<40).map { "  \"key\($0)\": { \"days\": \($0), \"label\": \"Start \($0)-day trial\" }," }.joined(separator: "\n") + "\n```\n\nNothing else changed.", ago: 100),
    ]

    /// 실패한 줄이 든 묶음
    private static let failedTurns: [ClaudeAppTurn] = [
        say("u1", "가격 페이지 문구를 고치고 lint까지 돌려줘", user: true, ago: 300),
        say("a1", "I'll edit the page and run the copy lint.", ago: 295),
        tool("t1", "Edit", file: "pricing.mdx", ago: 280),
        tool("t6", "Bash", "Run the copy lint", failed: true, ago: 260),
        tool("t3", "Edit", file: "ko.json", ago: 240),
        tool("t4", "Bash", "Run the copy lint", ago: 220),
        say("a2", "The lint failed once on a double space in the footnote. I fixed it and both checks now pass.", ago: 100),
    ]

    /// 61줄의 묶음 (도는 중이라 열려 있다)
    private static let longListTurns: [ClaudeAppTurn] =
        [say("u1", "Audit every string in the app", user: true, ago: 700)]
        + (0..<61).map { tool("s\($0)", $0.isMultiple(of: 3) ? "Grep" : "Read", file: $0.isMultiple(of: 3) ? nil : "Localizable-\($0).strings", ago: 690 - Double($0) * 8) }

    private static let agentTurns: [ClaudeAppTurn] = [
        say("g1", "Three strings still use 평가판 instead of 체험. They are in ko.json lines 41, 88 and 120.", ago: 60),
        tool("g2", "Read", file: "ko.json", ago: 50),
        tool("g3", "Read", file: "pricing.mdx", ago: 40),
    ]

    @MainActor
    private static func scenes() -> [Scene] {
        let background = ClaudeAppTranscriptSignals(background: tasks())
        return [
            Scene(name: "01-finished-folded", turns: Array(longTurns.dropLast(4))),
            Scene(name: "02-running-open", turns: longTurns, state: .busy, prepare: { presentation, _, entries in
                for case .steps(let run) in entries where run.isGroup && !run.isLive { presentation.steps.toggle(run) }
            }),
            Scene(name: "03-failed-open-detail", turns: failedTurns, prepare: { presentation, conversation, entries in
                for case .steps(let run) in entries where run.isGroup { presentation.steps.toggle(run) }
                presentation.steps.toggle(step: "t6", load: { _ in
                    guard let turn = conversation?.turns.first(where: { $0.id == "t6" }) else { return nil }
                    return await conversation?.detail(of: turn)
                })
            }),
            Scene(name: "04-long-list-show-all", turns: longListTurns, state: .busy, prepare: { presentation, _, entries in
                for case .steps(let run) in entries where run.isGroup { presentation.steps.toggleShowAll(run) }
            }),
            Scene(name: "05-long-code-folded", turns: codeTurns),
            Scene(name: "06-waiting", turns: longTurns, state: .waiting(.approval)),
            Scene(name: "07-background-strip", turns: longTurns, state: .busy, signals: background),
            Scene(name: "08-background-list", turns: longTurns, state: .busy, signals: background, prepare: { presentation, _, _ in presentation.pane.expand() }),
            Scene(name: "09-background-tail-command", turns: longTurns, state: .busy, signals: background, prepare: { presentation, _, _ in
                presentation.pane.expand()
                presentation.pane.select("b1")
            }),
            Scene(name: "10-background-tail-failed", turns: longTurns, state: .busy, signals: background, prepare: { presentation, _, _ in
                presentation.pane.expand()
                presentation.pane.select("b3")
            }, tail: .output(.text("> npm test\n\n FAIL  pricing.test.ts\n  expected 3 received 7\n\n[exited with code 3]", hasEarlier: false))),
            Scene(name: "11-background-tail-agent", turns: longTurns, state: .busy, signals: background, prepare: { presentation, _, _ in
                presentation.pane.expand()
                presentation.pane.select("b2")
            }, tail: .output(.agent(agentTurns, hasEarlier: false))),
        ]
    }

    @Test func rendersTheSessionViewForTheDesignComparison() async throws {
        guard let directory = output(ProcessInfo.processInfo.environment), EdgeRailPanelController.screen != nil else { return }
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }

        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for scene in Self.scenes() {
                // 처음부터 쉬던 세션은 레일에 없다: 쉬는 장면은 "일하다 쉰다"(끝난 링)로 만든다
                let resting = scene.state == .idle
                let w = await EdgeSessionsTests().rig(rows: [1], live: [EdgeSessionsTests.live(1, resting ? .busy : scene.state)])
                if resting { await w.poll([EdgeSessionsTests.live(1, .idle)]) }
                w.shell.reduceMotion = true
                w.shell.makeConversation = { id, cwd in
                    ClaudeAppConversation(sessionID: id, cwd: cwd, source: SampleSource(turns: scene.turns, signals: scene.signals, details: Self.details))
                }
                w.shell.makeBackgroundTail = { _, _, task in
                    BackgroundTaskTailModel(taskID: task.id, read: { _ in scene.tail }, pause: { _ in })
                }
                let claude = EdgeClaudeAppPanelController(shell: w.shell)
                guard let entry = w.shell.slots.first(where: { $0.source == .claudeApp(sessionID: EdgeSessionsTests.id(1)) }) else {
                    Issue.record("\(scene.name): 레일에 링이 없다")
                    continue
                }
                w.shell.openRailEntry(entry)
                claude.panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                claude.show()
                await pause(1.2)
                let conversation = w.shell.desktopConversation
                let entries = SessionTimeline.build(SessionTimelineSource.claude(conversation?.turns ?? []).items, state: scene.state == .busy ? .running : .finished)
                scene.prepare(claude.presentation, conversation, entries)
                claude.fit()
                await pause(0.8)
                claude.fit()
                await pause(0.5)
                write(claude.panel, to: directory.appendingPathComponent("\(dark ? "dark" : "light")-\(scene.name).png"), dark: dark)
                w.shell.dismiss()
                claude.hide()
                await pause(0.3)
            }
        }
    }

    // MARK: 옆줄이 열리고 닫히는 동안의 창 · 내용 프레임 (리뷰 P2-3의 실행 증거)

    /// 창 이미지 한 장을 고정 폭 캔버스의 오른쪽에 붙여 PNG로 쓴다 (프레임을 이어 보면 오른쪽 가장자리가 움직이는지 보인다)
    private func writeFrame(_ image: CGImage, windowWidth: CGFloat, canvasWidth: CGFloat, to url: URL) {
        let scale: CGFloat = 2
        let height = CGFloat(image.height) / scale
        guard let context = CGContext(
            data: nil, width: Int(canvasWidth * scale), height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        context.setFillColor(CGColor(srgbRed: 0.49, green: 0.53, blue: 0.58, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: canvasWidth * scale, height: height * scale))
        context.draw(image, in: CGRect(x: (canvasWidth - windowWidth) * scale, y: 0, width: windowWidth * scale, height: height * scale))
        guard let composed = context.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: composed).representation(using: .png, properties: [:])?.write(to: url)
    }

    /// 한 프레임: 창의 위치 · 폭과, 가운데 줄에서 실제로 그려진(불투명도 0.9 넘는) 가장 왼쪽 · 오른쪽 픽셀의 화면 좌표
    private struct FrameSample {
        var millis: Int
        var phase: String
        var windowMinX: CGFloat
        var windowWidth: CGFloat
        var drawnLeft: CGFloat?
        var drawnRight: CGFloat?
    }

    private func sample(_ window: NSWindow, millis: Int, phase: String, drawn: Bool = true, image: Bool = false, directory: URL? = nil, index: Int = 0) -> FrameSample {
        var frame = FrameSample(millis: millis, phase: phase, windowMinX: window.frame.minX, windowWidth: window.frame.width, drawnLeft: nil, drawnRight: nil)
        guard drawn, let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return frame }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / max(view.bounds.width, 1)
        let row = rep.pixelsHigh / 2
        var first: Int?
        var last: Int?
        for x in 0..<rep.pixelsWide {
            guard let color = rep.colorAt(x: x, y: row), color.alphaComponent > 0.9 else { continue }
            if first == nil { first = x }
            last = x
        }
        if let first, let last {
            frame.drawnLeft = window.frame.minX + CGFloat(first) / scale
            frame.drawnRight = window.frame.minX + CGFloat(last + 1) / scale
        }
        if image, let directory, let cg = rep.cgImage {
            writeFrame(cg, windowWidth: window.frame.width, canvasWidth: EdgePanelMetrics.width + 256 + 8, to: directory.appendingPathComponent(String(format: "%@-%03d.png", phase, index)))
        }
        return frame
    }

    @Test func recordsTheWindowAndContentFramesWhileTheSidePaneOpensAndCloses() async throws {
        guard let directory = output(ProcessInfo.processInfo.environment), EdgeRailPanelController.screen != nil else { return }
        let frames = directory.appendingPathComponent("frames", isDirectory: true)
        try? FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }
        NSApp.appearance = NSAppearance(named: .aqua)

        let w = await EdgeSessionsTests().rig(rows: [1], live: [EdgeSessionsTests.live(1, .busy)])
        // 움직임을 끄지 않는다: 실제로 쓰는 전환이 도는 동안의 프레임을 본다
        w.shell.reduceMotion = false
        w.shell.makeConversation = { id, cwd in
            ClaudeAppConversation(sessionID: id, cwd: cwd, source: SampleSource(turns: Self.longTurns, signals: ClaudeAppTranscriptSignals(background: Self.tasks()), details: Self.details))
        }
        let claude = EdgeClaudeAppPanelController(shell: w.shell)
        let entry = try #require(w.shell.slots.first { $0.source == .claudeApp(sessionID: EdgeSessionsTests.id(1)) })
        w.shell.openRailEntry(entry)
        claude.panel.appearance = NSAppearance(named: .aqua)
        claude.show()
        await pause(1.4)
        claude.fit()
        await pause(0.5)

        var samples: [FrameSample] = []
        func record(_ phase: String, action: @MainActor () -> Void) async {
            samples.append(sample(claude.panel, millis: -1, phase: "\(phase)-before", image: true, directory: frames, index: 0))
            let started = ContinuousClock.now
            action()
            var index = 1
            while true {
                let elapsed = ContinuousClock.now - started
                let millis = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
                if millis > 700 { break }
                // 창 틀은 싸게 자주(4ms), 그려진 픽셀은 비싸서 가끔 (한 장에 수십 ms)
                samples.append(sample(claude.panel, millis: millis, phase: phase, drawn: index % 6 == 0, image: index % 12 == 0, directory: frames, index: index))
                index += 1
                await pause(0.004)
            }
            samples.append(sample(claude.panel, millis: 700, phase: "\(phase)-after", image: true, directory: frames, index: 999))
        }
        await record("expand") { claude.presentation.pane.expand() }
        await record("collapse") { claude.presentation.pane.collapse() }

        var csv = "phase,t_ms,window_minX,window_width,window_maxX,drawn_left,drawn_right\n"
        for item in samples {
            let left = item.drawnLeft.map { String(format: "%.1f", $0) } ?? ""
            let right = item.drawnRight.map { String(format: "%.1f", $0) } ?? ""
            csv += "\(item.phase),\(item.millis),\(String(format: "%.1f", item.windowMinX)),\(String(format: "%.1f", item.windowWidth)),\(String(format: "%.1f", item.windowMinX + item.windowWidth)),\(left),\(right)\n"
        }
        try csv.write(to: frames.appendingPathComponent("expand-collapse-frames.csv"), atomically: true, encoding: .utf8)
        // 창의 오른쪽 가장자리(레일 쪽)는 움직이지 않고, 그려진 내용의 오른쪽도 그 가장자리에 붙어 있다
        let rights = Set(samples.map { ($0.windowMinX + $0.windowWidth).rounded() })
        #expect(rights.count == 1, "창의 오른쪽 가장자리가 움직였다: \(rights.sorted())")
        let drawnRights = Set(samples.compactMap { $0.drawnRight?.rounded() })
        #expect(drawnRights.count <= 1 || (drawnRights.max() ?? 0) - (drawnRights.min() ?? 0) <= 1, "그려진 내용의 오른쪽이 움직였다: \(drawnRights.sorted())")
        w.shell.dismiss()
        claude.hide()
    }
}
