import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// 본문이 한꺼번에 그리는 줄의 창 (#187 핫픽스 뒤): 즉시 쌓기는 긴 대화를 열 때 첫 배치가 줄 수에 비례해 몇 초씩 걸렸다. 가장 새 150줄만 그리고, 위의 "Show earlier"가 150줄씩 더 편다.
/// 덩어리를 쪼개지 않는 순수 규칙은 Kit `SessionWindowTests`가, 여기서는 그려진 줄 · 누르기 · 스크롤 자리 · 첫 배치 시간을 센다
@MainActor
struct SessionEntriesWindowTests {
    // MARK: 견본

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// 사용자 말 → 답 (5초 일함: "Worked for"가 없다)이 `rounds`번: 줄(entry)이 한 번에 셋 (말 · 답 · 답 밑 복사 줄)
    private func plain(_ rounds: Int) -> [ClaudeAppTurn] {
        (0..<rounds).flatMap { round -> [ClaudeAppTurn] in
            let base = t0.addingTimeInterval(TimeInterval(round * 100))
            return [
                ClaudeAppTurn(id: "u\(round)", kind: .user("question \(round)"), timestamp: base),
                ClaudeAppTurn(id: "a\(round)", kind: .assistant("answer \(round) with **bold** and `code`"), timestamp: base.addingTimeInterval(5)),
            ]
        }
    }

    private struct Built {
        var turns: [ClaudeAppTurn]
        var data: SessionTimelineData
        var entries: [SessionEntry]
        var byID: [String: ClaudeAppTurn]
        var itemIDs: [String] { entries.compactMap { if case .item(let id) = $0 { id } else { nil } } }

        init(_ turns: [ClaudeAppTurn]) {
            self.turns = turns
            data = SessionTimelineSource.claude(turns)
            entries = SessionTimeline.build(data.items, state: .finished)
            byID = Dictionary(turns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }

        func items(from start: Int) -> Set<String> {
            Set(entries[start...].compactMap { if case .item(let id) = $0 { id } else { nil } })
        }
    }

    // MARK: 호스팅

    @MainActor
    private final class Probe {
        var appeared: Set<String> = []
        var frames: [String: CGRect] = [:]
        var events = 0
        var pageLoads = 0
    }

    private struct Harness: View {
        let built: Built
        let state: SessionStepsState
        let probe: Probe
        var earlierAvailable = false
        var anchors = true

        var body: some View {
            GeometryReader { viewport in
                ScrollViewReader { proxy in
                    ScrollView {
                        SessionEntriesView(
                            entries: built.entries, steps: built.data.steps, state: state,
                            earlierPage: SessionEarlierPage(available: earlierAvailable, loading: false, load: { probe.pageLoads += 1 }),
                            item: { id in
                                if let turn = built.byID[id] {
                                    ClaudeAppTurnView(turn: turn)
                                        .onAppear {
                                            probe.appeared.insert(id)
                                            probe.events += 1
                                        }
                                        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) {
                                            probe.frames[id] = $0
                                            probe.events += 1
                                        }
                                }
                            }
                        )
                        .padding(EdgeInsets(top: TFSpace.xs, leading: TFSpace.lg, bottom: TFSpace.sm, trailing: TFSpace.lg))
                        .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .top)
                    }
                    .defaultScrollAnchor(.bottom)
                    .environment(\.sessionScrollToEntry, SessionScrollTo { id in if anchors { proxy.scrollTo(id, anchor: .top) } })
                }
            }
        }
    }

    private func host<V: View>(_ view: V, width: CGFloat = 380, height: CGFloat = 520) -> (NSWindow, NSHostingView<V>) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    private func waitUntilStable<Value: Equatable>(quiet: TimeInterval = 0.5, _ read: @MainActor () -> Value) async {
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

    private func click(_ window: NSWindow, _ hosting: NSView, at point: CGPoint) {
        let location = hosting.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ) { window.sendEvent(event) }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    /// 맨 위로 올려 "Show earlier"(본문 맨 위 가운데)를 누른다
    private func pressShowEarlier(_ window: NSWindow, _ hosting: NSView, _ scrollView: NSScrollView) async {
        scroll(scrollView, toFraction: 0)
        await waitUntilStable { Int(scrollView.contentView.bounds.origin.y) }
        click(window, hosting, at: CGPoint(x: 190, y: 14))
    }

    // MARK: 가장 새 창만 그린다

    @Test func aLongConversationRendersOnlyTheNewestWindowOfEntries() async throws {
        guard EdgeRailPanelController.screen != nil else { return }
        let built = Built(plain(120))
        #expect(built.entries.count >= 352, "줄 352개 이상의 대화: \(built.entries.count)")
        let state = SessionStepsState()
        let probe = Probe()
        let (window, _) = host(Harness(built: built, state: state, probe: probe))
        defer { window.close() }
        await waitUntilStable { probe.events }
        let start = state.windowStart(in: built.entries)
        let rendered = built.entries.count - start
        #expect(rendered <= SessionTimeline.renderWindow && rendered >= SessionTimeline.renderWindow - 3, "그린 줄 \(rendered): 가장 새 150줄 (덩어리 첫 줄로 맞추느라 몇 줄 적을 수 있다)")
        #expect(probe.appeared == built.items(from: start), "그려진 말은 창 안의 것뿐이다: \(probe.appeared.count)개 / 전체 \(built.itemIDs.count)개")
        #expect(probe.appeared.count < built.itemIDs.count / 2)
        #expect(built.itemIDs.last.map { probe.appeared.contains($0) } == true, "가장 새 말은 그려진다")
    }

    @Test func aConversationThatFitsTheWindowIsDrawnWholeWithNoShowEarlier() async throws {
        guard EdgeRailPanelController.screen != nil else { return }
        let built = Built(plain(40))
        let state = SessionStepsState()
        let probe = Probe()
        let (window, hosting) = host(Harness(built: built, state: state, probe: probe))
        defer { window.close() }
        await waitUntilStable { probe.events }
        #expect(state.windowStart(in: built.entries) == 0)
        #expect(probe.appeared == Set(built.itemIDs))
        let scrollView = try #require(findScrollView(in: hosting))
        await pressShowEarlier(window, hosting, scrollView)
        #expect(probe.pageLoads == 0, "읽을 앞 쪽이 없으면 단추가 없다")
    }

    // MARK: Show earlier

    @Test func pressingShowEarlierDrawsOneHundredFiftyMoreEntriesAndKeepsTheFirstVisibleOneInView() async throws {
        guard EdgeRailPanelController.screen != nil else { return }
        let built = Built(plain(120))
        let state = SessionStepsState()
        let probe = Probe()
        let (window, hosting) = host(Harness(built: built, state: state, probe: probe))
        defer { window.close() }
        await waitUntilStable { probe.events }
        let before = state.windowStart(in: built.entries)
        let anchorID = try #require(built.entries[before...].compactMap { entry -> String? in if case .item(let id) = entry { id } else { nil } }.first)
        let scrollView = try #require(findScrollView(in: hosting))
        await pressShowEarlier(window, hosting, scrollView)
        await waitUntilStable { probe.events }
        let after = state.windowStart(in: built.entries)
        let grown = before - after
        #expect(grown >= SessionTimeline.renderWindow && grown <= SessionTimeline.renderWindow + 3, "한 번 누르면 150줄 더: \(before) → \(after)")
        #expect(probe.appeared == built.items(from: after), "새로 편 줄까지 그려졌다")
        // 누르기 전에 첫 줄이던 말이 그대로 보이는 자리에 있다 (맨 위로 끌려 올라가 새로 편 글에 가려지지 않는다)
        let frame = try #require(probe.frames[anchorID])
        #expect(frame.minY >= -1 && frame.maxY <= 520, "눌러도 보던 첫 줄이 보이는 자리에 있다: \(frame)")
    }

    @Test func showEarlierKeepsGrowingUntilEverythingIsDrawnAndThenReadsTheEarlierPage() async throws {
        guard EdgeRailPanelController.screen != nil else { return }
        let built = Built(plain(120))
        let state = SessionStepsState()
        let probe = Probe()
        let (window, hosting) = host(Harness(built: built, state: state, probe: probe, earlierAvailable: true))
        defer { window.close() }
        await waitUntilStable { probe.events }
        let scrollView = try #require(findScrollView(in: hosting))
        var presses = 0
        while state.windowStart(in: built.entries) > 0, presses < 6 {
            await pressShowEarlier(window, hosting, scrollView)
            await waitUntilStable { probe.events }
            presses += 1
            #expect(probe.pageLoads == 0, "아직 읽어 둔 줄이 남았으면 앞 쪽을 읽지 않는다 (\(presses)번째)")
        }
        #expect(presses == 2 && state.windowStart(in: built.entries) == 0 && state.showsAllEntries, "360줄은 처음 150줄 + 두 번(150 · 나머지 60)에 다 펴진다: \(presses)번")
        #expect(probe.appeared == Set(built.itemIDs))
        await pressShowEarlier(window, hosting, scrollView)
        #expect(probe.pageLoads == 1, "다 폈으면 같은 단추가 앞 쪽을 읽는다")
    }

    @Test func anEarlierPageLoadedAfterEverythingWasShownIsShownToo() {
        let state = SessionStepsState()
        let older = Built(plain(120))
        _ = state.windowStart(in: older.entries)
        state.revealAll()
        let newer = Built(plain(150))
        #expect(state.windowStart(in: newer.entries) == 0, "앞 쪽을 읽어 앞에 붙은 줄도 보인다")
    }

    // MARK: 창의 상태 (화면 없이)

    @Test func theWindowIsTheNewestEntriesAndStaysPutWhileNewEntriesAppend() {
        let all = Built(plain(150)).entries
        let state = SessionStepsState()
        let shorter = Array(all.prefix(all.count - 30))
        let first = state.windowStart(in: shorter)
        let firstID = shorter[first].id
        #expect(first > 0 && shorter.count - first <= SessionTimeline.renderWindow)
        let grown = state.windowStart(in: all)
        #expect(all[grown].id == firstID, "새 줄이 붙어도 첫 줄 자리를 지킨다 (위로 거슬러 읽는 글이 한 줄씩 밀리지 않는다)")
        #expect(all.count - grown == shorter.count - first + 30)
    }

    @Test func aConversationThatStartedSmallIsNeverCutWhileItGrows() {
        let all = Built(plain(150)).entries
        let state = SessionStepsState()
        #expect(state.windowStart(in: Array(all.prefix(100))) == 0)
        #expect(state.windowStart(in: all) == 0, "처음부터 보이던 첫 줄은 대화가 길어져도 그대로다")
    }

    @Test func revealEarlierMovesTheCutBackByTheWindowAndNeverBeyondTheStart() {
        let entries = Built(plain(120)).entries
        let state = SessionStepsState()
        var start = state.windowStart(in: entries)
        var steps: [Int] = []
        while start > 0 {
            state.revealEarlier(in: entries)
            let next = state.windowStart(in: entries)
            steps.append(start - next)
            start = next
            if steps.count > 5 { break }
        }
        #expect(start == 0 && state.showsAllEntries)
        #expect(steps.count == 2 && steps.dropLast().allSatisfy { $0 >= SessionTimeline.renderWindow && $0 <= SessionTimeline.renderWindow + 3 }, "150씩 (덩어리 맞춤 몇 줄까지) 펴고 마지막은 남은 만큼(360줄: 210 = 150 + 60): \(steps)")
    }

    @Test func resettingTheStateGoesBackToTheNewestWindowForTheNextSession() {
        let entries = Built(plain(120)).entries
        let state = SessionStepsState()
        let first = state.windowStart(in: entries)
        state.revealEarlier(in: entries)
        state.revealAll()
        #expect(state.windowStart(in: entries) == 0)
        state.reset()
        #expect(!state.showsAllEntries)
        #expect(state.windowStart(in: entries) == first, "다른 세션을 열면 다시 가장 새 150줄")
    }

    @Test func theCutIsChosenAgainWhenTheConversationDroppedItsFirstRenderedEntry() {
        let entries = Built(plain(150)).entries
        let state = SessionStepsState()
        let start = state.windowStart(in: entries)
        // 대화가 위쪽 줄을 버려 첫 줄이 사라졌다: 다시 가장 새 150줄
        let trimmed = Array(entries[(start + 5)...])
        let again = state.windowStart(in: trimmed)
        #expect(trimmed.count - again <= SessionTimeline.renderWindow)
        #expect(again == 0 || SessionTimeline.startsUnit(trimmed, at: again))
    }

    // MARK: 진짜 Claude 패널: "Show earlier" 단추 하나

    /// 가장 새 쪽(`newest`)과 앞 쪽(`older`)을 따로 가진 기록: 앞 쪽은 "Show earlier"가 읽는다
    final class PagingSource: ClaudeAppTranscriptSource, @unchecked Sendable {
        let newest: [ClaudeAppTurn]
        let older: [ClaudeAppTurn]

        init(newest: [ClaudeAppTurn], older: [ClaudeAppTurn]) {
            self.newest = newest
            self.older = older
        }

        func open(sessionID: String, cwd: String?) -> ClaudeAppTranscriptLoad {
            .page(ClaudeAppTranscriptPage(turns: newest, cursor: ClaudeAppTranscriptCursor(sessionID: sessionID), hasEarlier: true, skippedLines: 0))
        }

        func earlier(_ cursor: ClaudeAppTranscriptCursor) -> ClaudeAppTranscriptLoad {
            .page(ClaudeAppTranscriptPage(turns: older, cursor: cursor, hasEarlier: false, skippedLines: 0))
        }

        func newer(_ cursor: ClaudeAppTranscriptCursor) -> ClaudeAppTranscriptUpdate { .turns([], cursor: cursor, hasMore: false) }
        func detail(of turn: ClaudeAppTurn, cursor: ClaudeAppTranscriptCursor) -> ClaudeAppToolDetail? { nil }
    }

    @Test func theClaudePanelHasOneShowEarlierThatFirstOpensTheLoadedEntriesAndThenReadsTheEarlierPage() async throws {
        guard EdgeRailPanelController.screen != nil else { return }
        let newest = plain(110)
        let older = (0..<30).flatMap { round -> [ClaudeAppTurn] in
            let base = t0.addingTimeInterval(TimeInterval(-10_000 + round * 100))
            return [
                ClaudeAppTurn(id: "old-u\(round)", kind: .user("older question \(round)"), timestamp: base),
                ClaudeAppTurn(id: "old-a\(round)", kind: .assistant("older answer \(round)"), timestamp: base.addingTimeInterval(5)),
            ]
        }
        let w = await EdgeSessionsTests().rig(rows: [1], live: [EdgeSessionsTests.live(1, .busy)])
        w.shell.reduceMotion = true
        w.shell.makeConversation = { id, cwd in ClaudeAppConversation(sessionID: id, cwd: cwd, source: PagingSource(newest: newest, older: older)) }
        let claude = EdgeClaudeAppPanelController(shell: w.shell)
        w.shell.openRailEntry(try #require(w.shell.slots.first { $0.source == .claudeApp(sessionID: EdgeSessionsTests.id(1)) }))
        claude.show()
        defer {
            w.shell.dismiss()
            claude.hide()
        }
        while (w.shell.desktopConversation?.turns.count ?? 0) < newest.count { try? await Task.sleep(for: .milliseconds(100)) }
        let conversation = try #require(w.shell.desktopConversation)
        await waitUntilStable { "\(claude.presentation.bodyHeight)|\(claude.panel.frame)" }
        let hosting = try #require(claude.panel.contentView)
        let scrollView = try #require(findScrollView(in: hosting))
        func press() async {
            scroll(scrollView, toFraction: 0)
            await waitUntilStable { Int(scrollView.contentView.bounds.origin.y) }
            // 머리 아래 본문 맨 위 가운데: 본문 위 여백 4 + 단추 줄의 가운데
            click(claude.panel, hosting, at: CGPoint(x: hosting.bounds.midX, y: claude.presentation.headHeight + 14))
            await waitUntilStable { "\(claude.presentation.steps.windowRevision)|\(conversation.turns.count)|\(Int(claude.presentation.bodyHeight))" }
        }
        let steps = claude.presentation.steps
        #expect(steps.windowRevision == 0 && conversation.hasEarlier)
        await press()
        #expect(steps.windowRevision == 1 && conversation.turns.count == newest.count, "첫 번은 읽어 둔 줄을 편다 (앞 쪽을 읽지 않는다)")
        await press()
        #expect(steps.windowRevision == 2 && steps.showsAllEntries && conversation.turns.count == newest.count, "다 펴질 때까지 앞 쪽을 읽지 않는다")
        await press()
        #expect(conversation.turns.count == newest.count + older.count && !conversation.hasEarlier, "다 폈으면 같은 단추가 앞 쪽 기록을 읽는다: \(conversation.turns.count)")
    }

    // MARK: 첫 배치 시간

    /// 같은 대화(줄 352개: 열린 묶음 · 큰 코드 블록이 섞인)를 호스팅 창에 처음 올릴 때 걸리는 시간 (조용해질 때까지 − 기다린 시간)
    private func firstLayoutSeconds(_ built: Built, showAll: Bool) async -> Double {
        let state = SessionStepsState()
        SessionPanelHangTests.prepare(state, turns: built.turns, detail: { _ in nil })
        if showAll { state.revealAll() }
        let probe = Probe()
        let clock = ContinuousClock()
        let started = clock.now
        let (window, _) = host(Harness(built: built, state: state, probe: probe))
        defer { window.close() }
        let quiet = 0.5
        await waitUntilStable(quiet: quiet) { probe.events }
        let elapsed = clock.now - started
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18 - quiet
    }

    @Test func theFirstLayoutOfALongConversationIsMuchShorterThanLayingOutEverything() async throws {
        guard EdgeRailPanelController.screen != nil else { return }
        let turns = SessionPanelHangTests.rounds(60, seed: 1) + SessionPanelHangTests.liveTail()
        let built = Built(turns)
        #expect(built.entries.count >= 350, "줄 352개의 대화: \(built.entries.count)")
        // 같은 기계 · 같은 때에 번갈아 재서 부하의 영향을 줄이고, 둘 다 가장 빠른 값을 쓴다
        var windowed: [Double] = []
        var everything: [Double] = []
        for _ in 0..<2 {
            everything.append(await firstLayoutSeconds(built, showAll: true))
            windowed.append(await firstLayoutSeconds(built, showAll: false))
        }
        let fastWindowed = windowed.min() ?? 0
        let fastEverything = everything.min() ?? 0
        print("HANGSTAT first layout of \(built.entries.count) entries: windowed \(windowed.map { String(format: "%.2f", $0) }) s, everything \(everything.map { String(format: "%.2f", $0) }) s")
        #expect(fastWindowed < fastEverything * 0.7, "창으로 그리면 전부 그리는 것의 7할 아래여야 한다: 창 \(fastWindowed)s · 전부 \(fastEverything)s")
    }
}
