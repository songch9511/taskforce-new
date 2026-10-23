import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// 데스크톱 세션과의 대화(PR-D3m)의 실제 화면을 PNG로 남긴다 (DZ `oa-desktop-rail-dz` 시트 2 · 3 · 4 · 5 비교용). **평소에는 아무것도 하지 않는다**:
/// 환경 변수 `TF_DESKTOP_CHAT_SHOTS`(폴더)가 있을 때만 돈다 — `TEST_RUNNER_TF_DESKTOP_CHAT_SHOTS=<폴더> xcodebuild test … -only-testing:TaskforceTests/ClaudeAppChatSnapshotTests`.
/// 시험 호스트 안에서 진짜 패널 창(`EdgeClaudeAppPanelController`)을 가짜 기록 · 가짜 폴 · 가짜 중계(띄우기 거절)로 연다: **설치된 앱 · 이 Mac의 실제 Claude 기록 · 실제 `claude` · 서버를 쓰지 않는다**.
/// 보낸 말의 상태는 Debug 전용 `setSample`로 직접 놓는다 (모든 상태를 한 번에 그린다)
@MainActor
struct ClaudeAppChatSnapshotTests {
    private typealias Sample = SessionViewSnapshotTests.SampleSource
    private typealias Delivery = ClaudeAppSessionChat.Delivery

    private func output(_ environment: [String: String]) -> URL? {
        guard let path = environment["TF_DESKTOP_CHAT_SHOTS"], !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    /// 창 하나를 데스크톱 색 위에 놓고 PNG로 쓴다 (세션 보기 촬영과 같은 방식)
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

    // MARK: 견본

    private static let now = Date()
    private static func at(_ secondsAgo: TimeInterval) -> Date { now.addingTimeInterval(-secondsAgo) }
    private static func say(_ id: String, _ text: String, user: Bool = false, ago: TimeInterval) -> ClaudeAppTurn {
        ClaudeAppTurn(id: id, kind: user ? .user(text) : .assistant(text), timestamp: at(ago))
    }

    /// 짧은 대화 하나
    private static let baseTurns: [ClaudeAppTurn] = [
        say("u1", "Update the trial copy to say 3 days", user: true, ago: 300),
        ClaudeAppTurn(id: "t1", kind: .tool(name: "Read", description: nil), timestamp: at(280), target: "pricing.mdx"),
        say("a1", "Done. The trial card now says **3 days** in the headline, the button and the footnote.", ago: 120),
    ]

    private static let ourRelayPID: Int32 = 4001

    private static func peer(_ id: String, _ text: String, pid: Int32?, plugin: String?, ago: TimeInterval) -> ClaudeAppTurn {
        ClaudeAppTurn(id: id, kind: .peer(text, ClaudeAppPeer(plugin: plugin, verifiedPeerPID: pid, messageID: id)), timestamp: at(ago))
    }

    private static let longText = (1...28).map { "Line \($0): please also check the Korean strings in ko.json and the glossary, and tell me every place that still says 평가판." }.joined(separator: "\n")

    /// 입력칸은 한 줄이다 (옆으로 흐른다): 긴 초안은 한 줄로 본다
    private static let longLine = (1...12).map { "Line \($0): please also check the Korean strings in ko.json." }.joined(separator: " ")

    private static func delivery(_ text: String, _ state: ClaudeAppDeliveryTracker.State) -> Delivery {
        ClaudeAppSessionChat.sampleDelivery(text: text, state: state)
    }

    @MainActor
    private struct Scene {
        let name: String
        var turns = ClaudeAppChatSnapshotTests.baseTurns
        var state: ClaudeAppSessionState = .idle
        var unreadable = false
        var closed = false
        /// 입력창 · 보낸 말의 상태를 놓는다
        var configure: @MainActor (ClaudeAppSessionChat) -> Void = { _ in }
    }

    private static func scenes() -> [Scene] {
        [
            Scene(name: "01-composer-empty"),
            Scene(name: "02-composer-draft", configure: { $0.setSample(deliveries: [], draft: "Also run the Korean copy lint when you are done") }),
            Scene(name: "03-confirm-first-send", configure: { $0.setSample(deliveries: [], confirming: true, draft: "Also run the Korean copy lint when you are done") }),
            Scene(name: "04-sending", state: .busy, configure: { $0.setSample(deliveries: [delivery("Also run the Korean copy lint", .sending)]) }),
            Scene(name: "05-sent", state: .busy, configure: { $0.setSample(deliveries: [delivery("Also run the Korean copy lint", .sent)]) }),
            Scene(name: "06-queued-approval", state: .waiting(.approval), configure: { $0.setSample(deliveries: [delivery("Also run the Korean copy lint", .queued(.approval))]) }),
            Scene(name: "07-queued-answer", state: .waiting(.answer), configure: { $0.setSample(deliveries: [delivery("Also run the Korean copy lint", .queued(.answer))]) }),
            Scene(
                name: "08-received-in-transcript",
                turns: baseTurns + [peer("p1", "Also run the Korean copy lint", pid: ourRelayPID, plugin: "tf-relay", ago: 60), say("a2", "Running the lint now.", ago: 40)], state: .busy
            ),
            Scene(name: "09-not-sent-closed", configure: { $0.setSample(deliveries: [delivery("Also run the Korean copy lint", .notSent(.sessionClosed))]) }),
            Scene(name: "10-not-sent-not-received", configure: { $0.setSample(deliveries: [delivery("Also run the Korean copy lint", .notSent(.notReceived))]) }),
            Scene(name: "11-not-sent-bypass", configure: { $0.setSample(deliveries: [delivery("Also run the Korean copy lint", .notSent(.bypass))]) }),
            Scene(name: "12-not-sent-two-places", configure: { $0.setSample(deliveries: [delivery("Also run the Korean copy lint", .notSent(.twoWriters))]) }),
            Scene(name: "13-band-with-composer", state: .waiting(.approval), configure: { $0.setSample(deliveries: [], draft: "") }),
            Scene(
                name: "14-foreign-peer",
                turns: baseTurns + [peer("p2", "Run the migration check too", pid: 9999, plugin: "other-plugin", ago: 60), peer("p3", "And the same for the Korean copy", pid: nil, plugin: nil, ago: 50)]
            ),
            Scene(name: "15-closed", state: .busy, closed: true),
            Scene(name: "16-unreadable", unreadable: true),
            Scene(
                name: "17-long-message", turns: baseTurns + [peer("p4", longText, pid: ourRelayPID, plugin: "tf-relay", ago: 60)],
                configure: { $0.setSample(deliveries: [delivery(longText, .sent)], draft: longLine) }
            ),
        ]
    }

    // MARK: 촬영

    @Test func rendersTheDesktopChatForTheDesignComparison() async throws {
        guard let directory = output(ProcessInfo.processInfo.environment), EdgeRailPanelController.screen != nil else { return }
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }

        // `TF_DESKTOP_CHAT_ONLY`: 장면 이름에 이 글이 든 것만 찍는다 (다시 찍을 때)
        let only = ProcessInfo.processInfo.environment["TF_DESKTOP_CHAT_ONLY"]
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for scene in Self.scenes() where only.map({ scene.name.contains($0) }) ?? true {
                let h = try DeskChatHarness.make()
                h.relay.pids.set([Self.ourRelayPID])
                // 처음부터 쉬던 세션은 레일에 없다: 쉬는 장면은 "일하다 쉰다"(끝난 링)로 만든다
                let resting = scene.state == .idle
                let w = await EdgeSessionsTests().rig(rows: [1], live: [EdgeSessionsTests.live(1, resting ? .busy : scene.state)], chat: h.service)
                if resting { await w.poll([EdgeSessionsTests.live(1, .idle)]) }
                w.shell.reduceMotion = true
                w.shell.makeConversation = { id, cwd in
                    let source: any ClaudeAppTranscriptSource
                    if scene.unreadable {
                        let broken = TranscriptFake()
                        broken.unreadable = true
                        source = broken
                    } else {
                        source = Sample(turns: scene.turns)
                    }
                    return ClaudeAppConversation(sessionID: id, cwd: cwd, source: source)
                }
                let claude = EdgeClaudeAppPanelController(shell: w.shell)
                guard let entry = w.shell.slots.first(where: { $0.source == .claudeApp(sessionID: EdgeSessionsTests.id(1)) }) else {
                    Issue.record("\(scene.name): 레일에 링이 없다")
                    continue
                }
                w.shell.openRailEntry(entry)
                claude.panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                claude.show()
                await pause(1.0)
                if scene.closed {
                    for _ in 0..<5 { await w.poll([]) }
                    await pause(0.5)
                }
                scene.configure(h.service.chat(for: EdgeSessionsTests.id(1)))
                claude.fit()
                await pause(0.8)
                claude.fit()
                await pause(0.5)
                write(claude.panel, to: directory.appendingPathComponent("\(dark ? "dark" : "light")-\(scene.name).png"), dark: dark)
                w.shell.dismiss()
                claude.hide()
                await h.service.shutdown()
                await pause(0.3)
            }
        }
    }
}
