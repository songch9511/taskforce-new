import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// 화면이 없는 환경(헤드리스 CI)에서는 창을 올려 그리는 시험을 **건너뜀**으로 남긴다: 조용히 통과시키지 않아서, 건너뛴 것이 결과에 보인다.
/// (`Test.cancel`은 시험을 취소로 끝내고 보고서에 "skipped"로 남는다.) 환경 변수 `TF_TEST_NO_SCREEN=1`(`TEST_RUNNER_TF_TEST_NO_SCREEN=1 xcodebuild test …`)로 화면이 없는 것처럼 돌려 건너뜀이 보이는지 볼 수 있다
@MainActor
func requireScreenForHostedViews() throws {
    let simulated = ProcessInfo.processInfo.environment["TF_TEST_NO_SCREEN"] == "1"
    if simulated || EdgeRailPanelController.screen == nil {
        // 인자가 있는 시험은 경우 하나만 취소돼 결과가 "통과"로 묶이므로, 경고도 남긴다 (실패는 아니다)
        Issue.record("화면이 없어 창을 올려 그릴 수 없다: 이 시험(경우)은 건너뛰었다", severity: .warning)
        try Test.cancel("화면이 없어 창을 올려 그릴 수 없다: 이 시험은 건너뛰었다")
    }
}

/// 핫픽스 (#187 세션 보기 뒤 Mac 앱이 멈춘다): 긴 대화의 세션 패널을 열어 두면 메인 스레드가 99%에서 내려오지 않고 SwiftUI가 패널을 끝없이 다시 배치했다.
/// 본문은 `LazyVStack`이었고, 줄의 높이가 **그려진 뒤에야** 정해졌다 (코드 블록: 처음엔 전체 높이, 그다음 180으로 접힘). 게으른 쌓기는 아직 그리지 않은 줄의 높이를 어림하므로
/// 줄이 만들어졌다 버려질 때마다 내용 높이가 크게 흔들리고, 맨 아래에 붙은 스크롤 · 창 높이 맞춤 · 스크롤 위치 알림이 그 흔들림을 먹고 다시 배치를 부른다.
/// 이 시험은 진짜 패널 창(`EdgeClaudeAppPanelController`)과, 두 패널이 본문을 감싼 모양 그대로의 호스팅 창(`ScrollView` + `.defaultScrollAnchor(.bottom)` + 본문 높이를 알리는 `onGeometryChange`)에
/// 줄 높이가 들쭉날쭉한 긴 대화(줄 300–600 · 열린 묶음 · 펼친 단계 본문)를 열고 **내용 높이가 한 번에 정해지는지 · 가라앉는지**를 잰다.
/// 메인 스레드가 정말 멈추면 시험 안에서 되돌릴 수 없으므로, 파수꾼이 시험 프로세스를 죽여 CI가 매달리지 않고 실패한다
@MainActor
struct SessionPanelHangTests {
    // MARK: 견본: 줄 높이가 들쭉날쭉한 긴 대화

    private static let now = Date()

    private static func at(_ secondsAgo: TimeInterval) -> Date { now.addingTimeInterval(-secondsAgo) }

    private static func tool(_ id: String, _ name: String, file: String? = nil, ago: TimeInterval) -> ClaudeAppTurn {
        ClaudeAppTurn(id: id, kind: .tool(name: name, description: nil), timestamp: at(ago), target: file, failed: false)
    }

    private static func say(_ id: String, _ text: String, user: Bool = false, ago: TimeInterval) -> ClaudeAppTurn {
        ClaudeAppTurn(id: id, kind: user ? .user(text) : .assistant(text), timestamp: at(ago))
    }

    /// 코드 한 덩어리 (줄 길이가 들쭉날쭉해서 접힌 줄바꿈이 섞인다)
    nonisolated static func code(lines: Int, tag: String) -> String {
        (0..<lines).map { line in
            line.isMultiple(of: 7)
                ? "  \"\(tag)-\(line)\": { \"days\": \(line), \"label\": \"Start the \(line)-day trial with the long label that wraps\" },"
                : "  \"\(tag)-\(line)\": \(line),"
        }.joined(separator: "\n")
    }

    /// 같은 씨앗이면 같은 대화 (시험이 매번 같은 모양을 본다)
    struct Dice {
        var state: UInt64

        init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }

        mutating func pick(_ options: [Int]) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return options[Int((state >> 33) % UInt64(options.count))]
        }
    }

    /// 한 번 = 말 → 앞 말 → 단계 묶음(0–25줄) → 답(문단 · 목록 · 0–2개의 코드: 3–300줄). 줄 높이가 24부터 수천까지 오간다
    static func rounds(_ count: Int, seed: UInt64, korean: Bool = false) -> [ClaudeAppTurn] {
        var dice = Dice(seed: seed)
        var turns: [ClaudeAppTurn] = []
        for round in 0..<count {
            let base = Double(count - round) * 600
            turns.append(say("u\(round)", korean ? "\(round)번째: 가격 페이지 체험 문구를 다시 쓰고 용어집이랑 맞는지 확인해줘." : "Round \(round): rewrite the trial copy and check the glossary.", user: true, ago: base))
            turns.append(say("p\(round)", korean ? "먼저 가격 페이지와 용어집을 읽어볼게요." : "I'll read the pricing page and the glossary first.", ago: base - 5))
            let steps = dice.pick([0, 1, 3, 4, 5, 6, 12, 25])
            for step in 0..<steps {
                turns.append(tool("t\(round)-\(step)", step.isMultiple(of: 2) ? "Read" : "Grep", file: step.isMultiple(of: 2) ? "pricing-\(step).mdx" : nil, ago: base - 10 - Double(step) / 10))
            }
            var answer = korean
                ? "바꿀 블록이 두 곳이었고 **둘 다 고쳤어요**.\n\n- 체험 카드: 제목 · 버튼 · 각주가 `3일`로 바뀜\n- 평생 플랜 카드: 가격 줄만 바뀜\n"
                : "The page had two blocks to change, and **both are updated** now.\n\n- Trial card: headline, button and footnote say `3 days`\n- Lifetime card: only the price line changed\n"
            for block in 0..<dice.pick([0, 0, 1, 1, 2]) {
                answer += "\n```json\n\(code(lines: dice.pick([3, 8, 12, 25, 60, 150, 300]), tag: "r\(round)b\(block)"))\n```\n"
            }
            if dice.pick([0, 1]) == 1 { answer += korean ? "\n1. 문구 lint 다시 돌리기\n2. 한국어 문구 확인하기\n" : "\n1. Re-run the lint\n2. Check the Korean copy\n" }
            turns.append(say("a\(round)", answer, ago: base - 100))
        }
        return turns
    }

    /// 코드 블록이 빽빽한 대화: 답마다 40–80줄 코드 둘
    static func denseCode(_ count: Int, seed: UInt64) -> [ClaudeAppTurn] {
        var dice = Dice(seed: seed)
        var turns: [ClaudeAppTurn] = []
        for round in 0..<count {
            let base = Double(count - round) * 100
            turns.append(say("u\(round)", "Round \(round): show me the config again.", user: true, ago: base))
            var answer = "Here is the config:\n"
            for block in 0..<2 { answer += "\n```json\n\(code(lines: dice.pick([40, 50, 60, 80]), tag: "r\(round)b\(block)"))\n```\n" }
            turns.append(say("a\(round)", answer + "\nNothing else changed.", ago: base - 50))
        }
        return turns
    }

    /// 끝에 도는 턴: 말 → 단계 여섯 (열린 묶음, 도는 시계)
    static func liveTail() -> [ClaudeAppTurn] {
        [say("ulive", "Now audit every string in the app.", user: true, ago: 90)]
            + (0..<6).map { tool("tl\($0)", $0.isMultiple(of: 2) ? "Read" : "Grep", file: $0.isMultiple(of: 2) ? "Localizable-\($0).strings" : nil, ago: 80 - Double($0) * 8) }
    }

    static let details: [String: ClaudeAppToolDetail] = [
        "tl2": ClaudeAppToolDetail(input: code(lines: 30, tag: "in"), result: code(lines: 30, tag: "out"), truncated: false),
    ]

    /// 씨앗 1–99는 영어 · 줄 높이가 들쭉날쭉, 100–199는 한국어 글(사용자의 실제 대화처럼), 200 이상은 코드 블록이 빽빽한 대화
    static func transcript(seed: UInt64) -> [ClaudeAppTurn] {
        seed >= 200 ? denseCode(150, seed: seed) + liveTail() : rounds(60, seed: seed, korean: seed >= 100) + liveTail()
    }

    /// 열린 묶음: 끝의 세 묶음과 가운데 하나를 열고(도는 묶음은 이미 열려 있다), 도는 묶음 안의 한 단계 본문을 편다
    @discardableResult
    static func prepare(_ steps: SessionStepsState, turns: [ClaudeAppTurn], detail: @escaping (String) async -> ClaudeAppToolDetail?) -> [SessionEntry] {
        let entries = SessionTimeline.build(SessionTimelineSource.claude(turns).items, state: .running)
        let groups = entries.compactMap { entry -> SessionStepRun? in if case .steps(let run) = entry, run.isGroup { run } else { nil } }
        for run in groups.suffix(3) where !run.isLive { steps.toggle(run) }
        if groups.count > 8 { steps.toggle(groups[groups.count / 2]) }
        steps.toggle(step: "tl2", load: detail)
        return entries
    }

    // MARK: 재는 도구

    /// 런루프가 잠들러 가는 횟수를 센다 (가라앉은 화면은 거의 깨지 않고, 끝없이 다시 배치하는 화면은 쉬지 않고 깬다)
    private final class LoopCounter: @unchecked Sendable {
        private(set) var turns = 0
        private var observer: CFRunLoopObserver?

        init() {
            observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [unowned self] _, _ in self.turns += 1 }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }

        deinit {
            if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        }
    }

    /// 창 틀이 바뀐 횟수
    private final class FrameCounter: @unchecked Sendable {
        private(set) var count = 0
        private var tokens: [NSObjectProtocol] = []

        @MainActor
        init(_ window: NSWindow?) {
            guard let window else { return }
            for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
                tokens.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.count += 1
                })
            }
        }

        deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }

    /// 관찰하는 값이 바뀐 횟수 (바뀐 다음 박자에 다시 건다: 한 박자 안의 여러 번은 한 번으로 센다. 그래서 실제보다 적게 센다)
    @MainActor
    private final class ChangeTracker {
        private(set) var count = 0
        private var live = true

        func track(_ read: @escaping @MainActor () -> Void) {
            withObservationTracking { read() } onChange: { [weak self] in
                Task { @MainActor in
                    guard let self, self.live else { return }
                    self.count += 1
                    self.track(read)
                }
            }
        }

        func stop() { live = false }
    }

    /// 시험이 정해진 시간 안에 끝나지 않으면 프로세스를 죽인다 (멈춘 메인 스레드는 시험 안에서 되돌릴 수 없다)
    private final class Watchdog: @unchecked Sendable {
        private let timer: DispatchSourceTimer

        init(seconds: Double, label: String) {
            timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "session-panel-hang-watchdog"))
            timer.schedule(deadline: .now() + seconds)
            timer.setEventHandler {
                fputs("HANG: \(label) did not finish within \(seconds)s; the main thread never came back to the run loop\n", stderr)
                _exit(70)
            }
            timer.resume()
        }

        func disarm() { timer.cancel() }
    }

    struct Settled {
        var wall: TimeInterval
        var loopTurns: Int
        var markdownEvaluations: Int
        var bodyHeightChanges: Int
        var windowFrameChanges: Int

        var summary: String {
            "wall \(String(format: "%.2f", wall))s, run-loop turns \(loopTurns), markdown rows evaluated \(markdownEvaluations), body height changes \(bodyHeightChanges), window frame changes \(windowFrameChanges)"
        }
    }

    /// 런루프를 건드리지 않고(`Task.sleep`) `seconds` 동안 센다. `wall`이 `seconds`보다 많이 크면 그동안 메인 스레드가 일에 붙잡혀 있었다는 뜻이다
    private func measure(_ seconds: TimeInterval, window: NSWindow?, heightChanges: @MainActor () -> Int) async -> Settled {
        let counter = LoopCounter()
        let frames = FrameCounter(window)
        let evaluationsBefore = SessionMarkdownCache.shared.lookups
        let heightsBefore = heightChanges()
        let clock = ContinuousClock()
        let started = clock.now
        try? await Task.sleep(for: .seconds(seconds))
        let elapsed = clock.now - started
        return Settled(
            wall: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18, loopTurns: counter.turns,
            markdownEvaluations: SessionMarkdownCache.shared.lookups - evaluationsBefore, bodyHeightChanges: heightChanges() - heightsBefore, windowFrameChanges: frames.count
        )
    }

    private func pause(_ seconds: TimeInterval) async { try? await Task.sleep(for: .seconds(seconds)) }

    /// 읽은 값이 `quiet`초 동안 바뀌지 않을 때까지 기다린다: 줄을 한꺼번에 그리는 동안 메인 스레드가 몇 초 막혀도(느린 기계 · 바쁜 기계) 그만큼 기다리고,
    /// 끝없이 바뀌면 파수꾼이 시험 프로세스를 죽인다
    private func waitUntilStable<Value: Equatable>(quiet: TimeInterval = 0.6, _ read: @MainActor () -> Value) async {
        var last = read()
        let clock = ContinuousClock()
        var since = clock.now
        while true {
            try? await Task.sleep(for: .milliseconds(100))
            let current = read()
            if current != last {
                last = current
                since = clock.now
            } else if clock.now - since >= .seconds(quiet) {
                return
            }
        }
    }

    /// 가라앉았다는 한계. 바쁜 기계(CI · 다른 빌드가 도는 Mac)에서도 흔들리지 않도록 넉넉히 잡았다: 끝없이 다시 배치하는 화면은 0.5초에 수백 번 깨고 메인 스레드를 몇 초씩 잡는다.
    /// 런루프가 0.5초 동안 몇 번 깨도 되나 (가라앉은 화면은 한 자릿수–수십: 시계 1초 틱 · 호버 · 바쁜 기계의 잡음), 마크다운 줄이 몇 번 다시 계산돼도 되나 (가라앉으면 0)
    static let maxLoopTurns = 100
    static let maxMarkdownEvaluations = 12
    /// 0.5초를 재는 데 걸려도 되는 시간: 거친 멈춤 감시일 뿐이다 (다른 빌드가 도는 Mac에서 프로세스가 몇 초 굶어도 안 흔들리게 넉넉히). 정말 멈추면 `measure`가 돌아오지 않아 파수꾼이 프로세스를 죽인다
    static let maxWall: TimeInterval = 30

    private func expectSettled(_ result: Settled, _ label: String) {
        #expect(result.wall < Self.maxWall, "\(label): 0.5초를 재는 데 \(result.wall)초가 걸렸다 (메인 스레드가 배치에 붙잡혀 있다): \(result.summary)")
        #expect(result.loopTurns <= Self.maxLoopTurns, "\(label): 가라앉지 않는다 (런루프가 쉬지 않고 깬다): \(result.summary)")
        #expect(result.markdownEvaluations <= Self.maxMarkdownEvaluations, "\(label): 줄이 계속 다시 만들어진다: \(result.summary)")
        #expect(result.bodyHeightChanges == 0, "\(label): 본문 높이가 계속 바뀐다: \(result.summary)")
        #expect(result.windowFrameChanges == 0, "\(label): 창 틀이 계속 바뀐다: \(result.summary)")
    }

    /// `EdgeShell.followClaudePanel`이 하는 일: 내용 높이 · 옆줄 폭이 바뀔 때마다 창 틀을 맞춘다 (진짜 앱에서는 이 관찰이 늘 돌고 있다)
    private func follow(_ claude: EdgeClaudeAppPanelController) {
        withObservationTracking {
            _ = claude.presentation.contentHeight
            _ = claude.presentation.pane.windowExtra
        } onChange: {
            Task { @MainActor in
                claude.fit()
                self.follow(claude)
            }
        }
    }

    // MARK: 진짜 패널

    /// 380 폭 패널 창에 긴 대화를 연다 (진짜 패널 · 가짜 기록 · 메모리 저장: 설치된 앱 · 이 Mac의 실제 기록을 쓰지 않는다)
    private func openPanel(seed: UInt64, reduceMotion: Bool) async throws -> (EdgeClaudeAppPanelController, EdgeSessionsTests.Rig) {
        try requireScreenForHostedViews()
        let turns = Self.transcript(seed: seed)
        let w = await EdgeSessionsTests().rig(rows: [1], live: [EdgeSessionsTests.live(1, .busy)])
        w.shell.reduceMotion = reduceMotion
        w.shell.makeConversation = { id, cwd in
            ClaudeAppConversation(sessionID: id, cwd: cwd, source: SessionViewSnapshotTests.SampleSource(turns: turns, details: Self.details))
        }
        let claude = EdgeClaudeAppPanelController(shell: w.shell)
        let entry = try #require(w.shell.slots.first { $0.source == .claudeApp(sessionID: EdgeSessionsTests.id(1)) })
        w.shell.openRailEntry(entry)
        claude.show()
        follow(claude)
        return (claude, w)
    }

    @Test(arguments: [1, 101, 201] as [UInt64])
    func openingALongSessionReportsItsBodyHeightOnlyAFewTimesAndThePanelWindowReachesItsHeightAtOnce(seed: UInt64) async throws {
        let watchdog = Watchdog(seconds: 120, label: "openingALongSessionReportsItsBodyHeightOnlyAFewTimes seed \(seed)")
        defer { watchdog.disarm() }
        let (claude, w) = try await openPanel(seed: seed, reduceMotion: true)
        defer {
            w.shell.dismiss()
            claude.hide()
        }
        let tracker = ChangeTracker()
        tracker.track { _ = claude.presentation.bodyHeight }
        defer { tracker.stop() }
        let frames = FrameCounter(claude.panel)
        // 대화를 읽고 다 그려 가라앉을 때까지 (측정은 그 사이 전부)
        while (w.shell.desktopConversation?.turns.count ?? 0) < 300 { await pause(0.1) }
        await waitUntilStable { "\(claude.presentation.bodyHeight)|\(claude.panel.frame)" }
        print("HANGSTAT open seed=\(seed) bodyHeight=\(Int(claude.presentation.bodyHeight)) frame=\(Int(claude.panel.frame.height)) body height changes \(tracker.count), window frame changes \(frames.count)")
        #expect(claude.panel.frame.height == EdgePanelMetrics.maxHeight, "긴 대화는 패널을 가장 높게 맞춘다: \(claude.panel.frame.height)")
        // 내용 높이는 처음 그릴 때(읽는 중 → 글) 한두 번 알리면 된다: 게으른 쌓기가 줄을 만들고 버리며 어림을 고칠 때마다 알리면 창 높이 맞춤이 그 흔들림을 따라간다
        #expect(tracker.count <= 3, "열 때 본문 높이가 \(tracker.count)번 바뀌었다")
        #expect(frames.count <= 4, "열 때 창 틀이 \(frames.count)번 바뀌었다")
    }

    @Test(arguments: [1, 101, 201] as [UInt64])
    func aLongSessionInTheClaudePanelSettlesInsteadOfLayingOutForever(seed: UInt64) async throws {
        let watchdog = Watchdog(seconds: 120, label: "aLongSessionInTheClaudePanelSettlesInsteadOfLayingOutForever seed \(seed)")
        defer { watchdog.disarm() }
        let (claude, w) = try await openPanel(seed: seed, reduceMotion: true)
        defer {
            w.shell.dismiss()
            claude.hide()
        }
        while (w.shell.desktopConversation?.turns.count ?? 0) < 300 { await pause(0.1) }
        await waitUntilStable { "\(claude.presentation.bodyHeight)|\(claude.panel.frame)" }
        let conversation = w.shell.desktopConversation
        Self.prepare(claude.presentation.steps, turns: conversation?.turns ?? [], detail: { _ in
            guard let turn = conversation?.turns.first(where: { $0.id == "tl2" }) else { return nil }
            return await conversation?.detail(of: turn)
        })
        await waitUntilStable { "\(claude.presentation.bodyHeight)|\(claude.panel.frame)" }
        let tracker = ChangeTracker()
        tracker.track { _ = claude.presentation.bodyHeight }
        defer { tracker.stop() }
        let result = await measure(0.5, window: claude.panel, heightChanges: { tracker.count })
        let entries = SessionTimeline.build(SessionTimelineSource.claude(conversation?.turns ?? []).items, state: .running)
        print("HANGSTAT panel seed=\(seed) turns=\(conversation?.turns.count ?? 0) entries=\(entries.count) \(result.summary)")
        #expect(entries.count > 300, "줄 300개 남짓의 대화를 열었다")
        expectSettled(result, "380x520 panel, seed \(seed)")
    }

    // MARK: 본문만 (두 패널이 같은 모양으로 감싼 `SessionEntriesView`)

    @MainActor
    private final class BodyProbe {
        var heights: [CGFloat] = []
    }

    /// 두 세션 패널 본문의 모양 그대로: `GeometryReader` 안의 `ScrollView` + `.defaultScrollAnchor(.bottom)` + 본문 높이를 알리는 `onGeometryChange`, 그 안에 `SessionEntriesView`
    private struct PanelBodyHarness: View {
        let turns: [ClaudeAppTurn]
        let state: SessionRunState
        let steps: SessionStepsState
        let probe: BodyProbe

        var body: some View {
            let data = SessionTimelineSource.claude(turns)
            let entries = SessionTimeline.build(data.items, state: state)
            let byID = Dictionary(turns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            GeometryReader { viewport in
                ScrollView {
                    SessionEntriesView(entries: entries, steps: data.steps, state: steps, loadDetail: { id in
                        SessionPanelHangTests.details[id]
                    }, item: { id in
                        if let turn = byID[id] { ClaudeAppTurnView(turn: turn) }
                    })
                    .padding(EdgeInsets(top: TFSpace.xs, leading: TFSpace.lg, bottom: TFSpace.sm, trailing: TFSpace.lg))
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { probe.heights.append($0) }
                    .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .top)
                }
                .defaultScrollAnchor(.bottom)
            }
        }
    }

    private func host<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> (NSWindow, NSHostingView<V>) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    private func findScrollView(in root: NSView) -> NSScrollView? {
        var best: NSScrollView?
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView, (scroll.documentView?.frame.height ?? 0) > (best?.documentView?.frame.height ?? 0) { best = scroll }
            view.subviews.forEach(walk)
        }
        walk(root)
        return best
    }

    private func scroll(_ scrollView: NSScrollView, toFraction fraction: CGFloat) {
        let document = scrollView.documentView?.frame.height ?? 0
        let visible = scrollView.contentView.bounds.height
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, (document - visible) * fraction)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func preparedBody(seed: UInt64) -> (steps: SessionStepsState, turns: [ClaudeAppTurn], entries: [SessionEntry]) {
        let turns = Self.transcript(seed: seed)
        let steps = SessionStepsState()
        let entries = Self.prepare(steps, turns: turns, detail: { id in Self.details[id] })
        return (steps, turns, entries)
    }

    @Test(arguments: [1, 101, 201] as [UInt64])
    func theTranscriptHasTheSameHeightWhereverTheUserScrolls(seed: UInt64) async throws {
        try requireScreenForHostedViews()
        let watchdog = Watchdog(seconds: 120, label: "theTranscriptHasTheSameHeightWhereverTheUserScrolls seed \(seed)")
        defer { watchdog.disarm() }
        let (steps, turns, entries) = preparedBody(seed: seed)
        let probe = BodyProbe()
        let (window, hosting) = host(PanelBodyHarness(turns: turns, state: .running, steps: steps, probe: probe), width: 380, height: 520)
        defer { window.close() }
        await pause(0.3)
        let scrollView = try #require(findScrollView(in: hosting))
        await waitUntilStable { Int(scrollView.documentView?.frame.height ?? 0) }
        var heights: [Int] = [Int(scrollView.documentView?.frame.height ?? 0)]
        for fraction in [0.0, 0.5, 0.25, 0.75, 1.0, 0.1] as [CGFloat] {
            scroll(scrollView, toFraction: fraction)
            await waitUntilStable { Int(scrollView.documentView?.frame.height ?? 0) }
            heights.append(Int(scrollView.documentView?.frame.height ?? 0))
        }
        print("HANGSTAT scroll seed=\(seed) entries=\(entries.count) document heights \(heights)")
        #expect(entries.count > 300, "줄 300개 남짓의 대화를 열었다")
        // 내용의 높이는 어디를 보고 있든 같다: 게으른 쌓기는 보이는 곳 근처만 재고 나머지는 어림하므로 스크롤할 때마다 달라진다 (맨 아래에 붙은 스크롤 · 창 높이 맞춤이 그 흔들림을 먹는다)
        #expect((heights.max() ?? 0) - (heights.min() ?? 0) <= 1, "스크롤 위치마다 내용 높이가 다르다: \(heights)")
    }

    @Test(arguments: [1, 3] as [UInt64])
    func theTranscriptBodyInA380By520WindowSettlesAndStaysSettledWhileTheWindowHeightChanges(seed: UInt64) async throws {
        try requireScreenForHostedViews()
        let watchdog = Watchdog(seconds: 120, label: "theTranscriptBodyInA380By520WindowSettlesAndStaysSettledWhileTheWindowHeightChanges seed \(seed)")
        defer { watchdog.disarm() }
        let (steps, turns, entries) = preparedBody(seed: seed)
        let probe = BodyProbe()
        let (window, hosting) = host(PanelBodyHarness(turns: turns, state: .running, steps: steps, probe: probe), width: 380, height: 520)
        defer { window.close() }
        await pause(0.3)
        await waitUntilStable { probe.heights.count }
        var result = await measure(0.5, window: window, heightChanges: { probe.heights.count })
        print("HANGSTAT body seed=\(seed) entries=\(entries.count) \(result.summary)")
        expectSettled(result, "380x520 body, seed \(seed)")
        // 창 높이를 320–520 사이로 바꿔도 매번 가라앉는다 (패널은 내용에 맞춰 높이를 바꾼다)
        for height in [420, 320, 520, 360, 480] as [CGFloat] {
            window.setContentSize(NSSize(width: 380, height: height))
            hosting.layoutSubtreeIfNeeded()
            await pause(0.5)
            let frameBefore = window.frame
            result = await measure(0.5, window: nil, heightChanges: { probe.heights.count })
            print("HANGSTAT body seed=\(seed) height=\(Int(height)) \(result.summary)")
            expectSettled(result, "380x\(Int(height)) body after a resize, seed \(seed)")
            #expect(window.frame == frameBefore)
        }
    }

    // MARK: 코드 블록은 그리기 전에 접을지 정한다

    @MainActor
    private final class HeightsByCount {
        var values: [Int: CGFloat] = [:]
    }

    /// 줄 수로 정하는 규칙(`isLong(text:)`)이 예전에 그린 뒤 재던 규칙(본문 높이가 접은 높이 180 + 1을 넘나)과 1–16줄에서 같은 답을 낸다 (글꼴 · 줄 간격이 바뀌면 여기서 잡힌다)
    @Test func theFoldRuleAgreesWithTheHeightTheCodeActuallyTakes() throws {
        try requireScreenForHostedViews()
        let heights = HeightsByCount()
        let view = VStack(alignment: .leading, spacing: 0) {
            ForEach(1...16, id: \.self) { count in
                SessionCodeBlockView(label: "x", text: (0..<count).map { "line \($0)" }.joined(separator: "\n"), collapses: false)
                    .frame(width: 348)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { heights.values[count] = $0 }
            }
        }
        let (window, _) = host(view, width: 380, height: 520)
        defer { window.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        let header: CGFloat = 28
        print("HANGSTAT fold code block heights by line count \((1...16).map { "\($0):\(Int((heights.values[$0] ?? 0) - header))" })")
        for count in 1...16 {
            guard let height = heights.values[count] else {
                Issue.record("\(count)줄 블록의 높이를 못 쟀다")
                continue
            }
            let tallerThanTheFold = height - header > SessionCodeBlockView.collapsedHeight + 1
            #expect(SessionCodeBlockView.isLong(text: (0..<count).map { "line \($0)" }.joined(separator: "\n")) == tallerThanTheFold, "\(count)줄: 높이 \(height - header)")
        }
    }

    // MARK: 창 높이 맞춤은 1pt 아래의 변화에 움직이지 않는다

    @Test func thePanelWindowIgnoresAHeightChangeUnderOnePointButFollowsALargerOne() async throws {
        try requireScreenForHostedViews()
        let w = await EdgeSessionsTests().rig(rows: [1], live: [EdgeSessionsTests.live(1, .busy)])
        w.shell.reduceMotion = true
        let claude = EdgeClaudeAppPanelController(shell: w.shell)
        w.shell.openRailEntry(try #require(w.shell.slots.first { $0.source == .claudeApp(sessionID: EdgeSessionsTests.id(1)) }))
        #expect(claude.show())
        defer {
            w.shell.dismiss()
            claude.panel.orderOut(nil)
        }
        await pause(0.4)
        // 머리 · 띠는 안에서 잰 값 그대로 두고, 본문 높이만 정해서 창 높이가 400이 되게 한다 (320–520 사이라야 내용을 따라간다)
        let chrome = claude.presentation.headHeight + claude.presentation.footerHeight
        claude.presentation.bodyHeight = 400 - chrome
        claude.fit()
        let base = claude.panel.frame
        #expect(base.height == 400, "내용 높이를 따라 400: \(base)")
        // 안에서 재는 값이 소수점만 흔들려도(0.8 · 0.7) 창을 다시 맞추지 않는다 (움직임도 틀 설정도 없다)
        claude.presentation.bodyHeight = 400.8 - chrome
        claude.fit()
        #expect(claude.panel.frame == base, "1pt 아래의 변화에 창이 움직였다: \(claude.panel.frame) ← \(base)")
        claude.presentation.bodyHeight = 399.3 - chrome
        claude.fit()
        #expect(claude.panel.frame == base, "1pt 아래의 변화에 창이 움직였다: \(claude.panel.frame) ← \(base)")
        // 1pt 이상은 따라간다
        claude.presentation.bodyHeight = 406 - chrome
        claude.fit()
        #expect(claude.panel.frame.height == 406, "큰 변화는 따라간다: \(claude.panel.frame)")
    }

    /// 접힌 블록은 보이는 열 줄 남짓만 그리지만(비용), 모양은 글이 길어도 같다: 머리 28 + 180 + Show all 줄
    @Test func aFoldedBlockLooksTheSameWhateverItsLength() throws {
        try requireScreenForHostedViews()
        let heights = HeightsByCount()
        let view = VStack(alignment: .leading, spacing: 0) {
            ForEach([12, 40, 300], id: \.self) { count in
                SessionCodeBlockView(label: "x", text: Self.code(lines: count, tag: "f"))
                    .frame(width: 348)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { heights.values[count] = $0 }
            }
        }
        let (window, _) = host(view, width: 380, height: 900)
        defer { window.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        let values = [12, 40, 300].map { (heights.values[$0] ?? 0).rounded() }
        #expect(Set(values).count == 1 && (values.first ?? 0) > SessionCodeBlockView.collapsedHeight, "접힌 블록의 높이: \(values)")
    }

    @MainActor
    private final class HeightsByName {
        var values: [String: CGFloat] = [:]
    }

    /// 줄 수 모델(`rows(of:columns:)`)이 실제로 그려진 줄 수와 맞는다: 영어 · 한국어 · 섞인 줄을, 패널(380: 코드 면 348)과 옆줄(코드 면 224)의 폭으로.
    /// 모델은 영어 쪽에서 실제보다 적게 세어도 되고(못 접는 쪽이 접을 것을 안 접는 쪽보다 낫다) 많이 세면 안 된다. 한국어는 두 칸으로 세어 같다
    @Test func theRowModelAgreesWithTheRowsTheTextReallyTakesAtThePanelAndSidePaneWidths() throws {
        try requireScreenForHostedViews()
        let samples: [(name: String, text: String)] = [
            ("en 40", String(repeating: "x", count: 40)), ("en 44", String(repeating: "x", count: 44)), ("en 48", String(repeating: "x", count: 48)),
            ("en 60", String(repeating: "x", count: 60)), ("en 100", String(repeating: "x", count: 100)), ("en 140", String(repeating: "x", count: 140)),
            ("ko 12", String(repeating: "가", count: 12)), ("ko 24", String(repeating: "가", count: 24)), ("ko 27", String(repeating: "가", count: 27)),
            ("ko 28", String(repeating: "가", count: 28)), ("ko 48", String(repeating: "가", count: 48)), ("ko 100", String(repeating: "가", count: 100)),
            ("mixed", String(repeating: "문자열 value=1, ", count: 8)),
        ]
        let widths: [(name: String, block: CGFloat)] = [("panel", SessionCodeBlockView.panelBlockWidth), ("side pane", 224)]
        let heights = HeightsByName()
        let view = VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(widths.enumerated()), id: \.offset) { _, width in
                ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                    SessionCodeBlockView(label: "x", text: sample.text, collapses: false)
                        .environment(\.sessionCodeBlockWidth, width.block)
                        .frame(width: width.block)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { heights.values["\(width.name)|\(sample.name)"] = $0 }
                }
            }
        }
        let (window, _) = host(view, width: 380, height: 2_000)
        defer { window.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        var table: [String] = []
        for width in widths {
            let columns = SessionCodeBlockView.columns(forBlockWidth: width.block)
            for sample in samples {
                let key = "\(width.name)|\(sample.name)"
                guard let height = heights.values[key] else {
                    Issue.record("\(key): 높이를 못 쟀다")
                    continue
                }
                // 머리 28 · 아래 여백 12가 든 면: 한 줄 27, 한 줄 늘 때마다 약 18.4
                let real = Int(((height - 28) - 8.5) / 18.45 + 0.5)
                let model = SessionCodeBlockView.rows(of: sample.text, columns: columns)
                table.append("\(key): real \(real) model \(model)")
                if sample.name.hasPrefix("en") {
                    #expect(model <= real && real - model <= 1, "\(key): 영어는 실제보다 많이 세지 않고 한 줄 넘게 적게 세지도 않는다 (실제 \(real) · 모델 \(model))")
                } else {
                    #expect(abs(real - model) <= 1, "\(key): 한국어 · 섞인 글은 실제와 한 줄 안쪽 (실제 \(real) · 모델 \(model))")
                }
                if sample.name == "ko 48" && width.name == "panel" {
                    #expect(real == 2 && model == 2, "한국어 48자는 380 폭에서 실제로 두 줄이고 모델도 두 줄이다 (실제 \(real) · 모델 \(model))")
                }
            }
        }
        print("HANGSTAT row model vs real rows: \(table)")
    }

    @Test func aLongCodeBlockHasItsFinalHeightFromTheVeryFirstLayout() throws {
        try requireScreenForHostedViews()
        let probe = BodyProbe()
        let view = SessionCodeBlockView(label: "json", text: Self.code(lines: 40, tag: "x"))
            .frame(width: 348)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { probe.heights.append($0) }
        let (window, _) = host(view, width: 380, height: 520)
        defer { window.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        let distinct = Set(probe.heights.map { $0.rounded() })
        #expect(distinct.count == 1, "접을 줄인지는 그리기 전에 정해진다 (처음 높이가 마지막 높이다): 알려진 높이들 \(probe.heights)")
        #expect((distinct.first ?? 0) < 400, "긴 코드는 접힌 채 처음부터 그려진다: \(probe.heights)")
    }
}
