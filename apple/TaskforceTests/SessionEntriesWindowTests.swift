import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// 본문이 한꺼번에 그리는 줄의 창 (#187 핫픽스 뒤): 즉시 쌓기는 긴 대화를 열 때 첫 배치가 줄 수에 비례해 몇 초씩 걸렸다. 가장 새 150줄만 그리고, 위의 "Show earlier"가 150줄씩 더 편다.
/// 덩어리를 쪼개지 않는 순수 규칙은 Kit `SessionWindowTests`가, 여기서는 그려진 줄 · 누르기 · 스크롤 자리 · 붙어 있는 동안의 한도 · 첫 배치의 (센 값으로 잰) 비용을 본다
@MainActor
struct SessionEntriesWindowTests {
    // MARK: 견본

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// 사용자 말 → 답 (5초 일함: "Worked for"가 없다)이 `rounds`번: 줄(entry)이 한 번에 셋 (말 · 답 · 답 밑 복사 줄)
    private func plain(_ rounds: Int, prefix: String = "", from first: Date? = nil) -> [ClaudeAppTurn] {
        (0..<rounds).flatMap { round -> [ClaudeAppTurn] in
            let base = (first ?? t0).addingTimeInterval(TimeInterval(round * 100))
            return [
                ClaudeAppTurn(id: "\(prefix)u\(round)", kind: .user("question \(round)"), timestamp: base),
                ClaudeAppTurn(id: "\(prefix)a\(round)", kind: .assistant("answer \(round) with **bold** and `code`"), timestamp: base.addingTimeInterval(5)),
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

    /// 읽어 둔 줄을 처음까지 다 편다 (사용자가 Show earlier를 끝까지 누른 것과 같다)
    private func revealEverything(_ state: SessionStepsState, _ entries: [SessionEntry]) {
        var guardCount = 0
        while state.windowStart(in: entries, pinned: false) > 0, guardCount < 100 {
            state.revealEarlier(in: entries)
            guardCount += 1
        }
    }

    // MARK: 호스팅

    @MainActor
    private final class Probe {
        /// 한 번이라도 그려진 말 (늘기만 한다)
        var appeared: Set<String> = []
        /// 지금 그려져 있는 말 (사라지면 빠진다)
        var present: Set<String> = []
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
        /// 끄면 읽는 사람이 늘 위로 올려 읽는 중이라고 알린다 (붙는 것을 보지 않는다): 창이 다시 접히지 않으므로 "전부 그린" 기준을 만들 때 쓴다
        var trackPin = true
        /// 두 패널과 같은 스크롤 알림: 맨 아래에 붙어 있나
        @State private var pinned = true

        var body: some View {
            GeometryReader { viewport in
                ScrollViewReader { proxy in
                    ScrollView {
                        SessionEntriesView(
                            entries: built.entries, steps: built.data.steps, state: state,
                            earlierPage: SessionEarlierPage(available: earlierAvailable, loading: false, load: { probe.pageLoads += 1 }),
                            pinnedToBottom: trackPin ? pinned : false,
                            item: { id in
                                if let turn = built.byID[id] {
                                    ClaudeAppTurnView(turn: turn)
                                        .onAppear {
                                            probe.appeared.insert(id)
                                            probe.present.insert(id)
                                            probe.events += 1
                                        }
                                        .onDisappear {
                                            probe.present.remove(id)
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
                    .onScrollGeometryChange(for: SessionScrollSnapshot.self) { geometry in
                        SessionScrollSnapshot(visibleMaxY: geometry.visibleRect.maxY, contentHeight: geometry.contentSize.height, visibleHeight: geometry.visibleRect.height)
                    } action: { old, new in
                        if trackPin { pinned = SessionScrollPin.next(pinned: pinned, old: old, new: new) }
                    }
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
        try requireScreenForHostedViews()
        let built = Built(plain(120))
        #expect(built.entries.count >= 352, "줄 352개 이상의 대화: \(built.entries.count)")
        let state = SessionStepsState()
        let probe = Probe()
        let (window, _) = host(Harness(built: built, state: state, probe: probe))
        defer { window.close() }
        await waitUntilStable { probe.events }
        let start = state.peekWindowStart(in: built.entries)
        let rendered = built.entries.count - start
        #expect(rendered <= SessionTimeline.renderWindow && rendered >= SessionTimeline.renderWindow - 3, "그린 줄 \(rendered): 가장 새 150줄 (덩어리 첫 줄로 맞추느라 몇 줄 적을 수 있다)")
        #expect(probe.appeared == built.items(from: start), "그려진 말은 창 안의 것뿐이다: \(probe.appeared.count)개 / 전체 \(built.itemIDs.count)개")
        #expect(probe.appeared.count < built.itemIDs.count / 2)
        #expect(built.itemIDs.last.map { probe.appeared.contains($0) } == true, "가장 새 말은 그려진다")
    }

    @Test func aConversationThatFitsTheWindowIsDrawnWholeWithNoShowEarlier() async throws {
        try requireScreenForHostedViews()
        let built = Built(plain(40))
        let state = SessionStepsState()
        let probe = Probe()
        let (window, hosting) = host(Harness(built: built, state: state, probe: probe))
        defer { window.close() }
        await waitUntilStable { probe.events }
        #expect(state.peekWindowStart(in: built.entries) == 0)
        #expect(probe.appeared == Set(built.itemIDs))
        let scrollView = try #require(findScrollView(in: hosting))
        await pressShowEarlier(window, hosting, scrollView)
        #expect(probe.pageLoads == 0, "읽을 앞 쪽이 없으면 단추가 없다")
    }

    // MARK: Show earlier

    @Test func pressingShowEarlierDrawsOneHundredFiftyMoreEntriesAndKeepsTheFirstVisibleOneInView() async throws {
        try requireScreenForHostedViews()
        let built = Built(plain(120))
        let state = SessionStepsState()
        let probe = Probe()
        let (window, hosting) = host(Harness(built: built, state: state, probe: probe))
        defer { window.close() }
        await waitUntilStable { probe.events }
        let before = state.peekWindowStart(in: built.entries)
        let anchorID = try #require(built.entries[before...].compactMap { entry -> String? in if case .item(let id) = entry { id } else { nil } }.first)
        let scrollView = try #require(findScrollView(in: hosting))
        await pressShowEarlier(window, hosting, scrollView)
        await waitUntilStable { probe.events }
        let after = state.peekWindowStart(in: built.entries)
        let grown = before - after
        #expect(grown >= SessionTimeline.renderWindow && grown <= SessionTimeline.renderWindow + 3, "한 번 누르면 150줄 더: \(before) → \(after)")
        #expect(probe.appeared == built.items(from: after), "새로 편 줄까지 그려졌다")
        // 누르기 전에 첫 줄이던 말이 그대로 보이는 자리에 있다 (맨 위로 끌려 올라가 새로 편 글에 가려지지 않는다)
        let frame = try #require(probe.frames[anchorID])
        #expect(frame.minY >= -1 && frame.maxY <= 520, "눌러도 보던 첫 줄이 보이는 자리에 있다: \(frame)")
    }

    @Test func showEarlierKeepsGrowingUntilEverythingIsDrawnAndThenReadsTheEarlierPage() async throws {
        try requireScreenForHostedViews()
        let built = Built(plain(120))
        let state = SessionStepsState()
        let probe = Probe()
        let (window, hosting) = host(Harness(built: built, state: state, probe: probe, earlierAvailable: true))
        defer { window.close() }
        await waitUntilStable { probe.events }
        let scrollView = try #require(findScrollView(in: hosting))
        var presses = 0
        while state.peekWindowStart(in: built.entries) > 0, presses < 6 {
            await pressShowEarlier(window, hosting, scrollView)
            await waitUntilStable { probe.events }
            presses += 1
            #expect(probe.pageLoads == 0, "아직 읽어 둔 줄이 남았으면 앞 쪽을 읽지 않는다 (\(presses)번째)")
        }
        #expect(presses == 2 && state.peekWindowStart(in: built.entries) == 0, "360줄은 처음 150줄 + 두 번(150 · 나머지 60)에 다 펴진다: \(presses)번")
        #expect(probe.appeared == Set(built.itemIDs))
        await pressShowEarlier(window, hosting, scrollView)
        #expect(probe.pageLoads == 1, "다 폈으면 같은 단추가 앞 쪽을 읽는다")
    }

    @Test func comingBackToTheBottomDrawsOnlyTheNewestWindowAgain() async throws {
        try requireScreenForHostedViews()
        // 300줄: 한 번 펴면 한도의 두 배(300줄)까지라 크기 규칙은 닿지 않고, 다시 붙는 순간의 규칙만 창을 돌린다
        let built = Built(plain(100))
        let state = SessionStepsState()
        let probe = Probe()
        let (window, hosting) = host(Harness(built: built, state: state, probe: probe))
        defer { window.close() }
        await waitUntilStable { probe.events }
        let newest = SessionTimeline.windowStart(built.entries, limit: SessionTimeline.renderWindow)
        let scrollView = try #require(findScrollView(in: hosting))
        await pressShowEarlier(window, hosting, scrollView)
        await waitUntilStable { probe.events }
        #expect(probe.present == Set(built.itemIDs), "한 번 눌러 읽어 둔 줄을 다 폈다: \(probe.present.count)개")
        scroll(scrollView, toFraction: 1)
        await waitUntilStable { probe.events }
        #expect(probe.present == built.items(from: newest), "맨 아래로 돌아오면 창이 다시 가장 새 150줄이다 (읽던 위쪽 줄은 접힌다): \(probe.present.count)개")
        #expect(state.peekWindowStart(in: built.entries) == newest)
    }

    // MARK: 창의 상태 (화면 없이)

    @Test func theWindowIsTheNewestEntriesAndStaysPutWhileTheReaderIsScrolledUpAndNewEntriesAppend() {
        let all = Built(plain(150)).entries
        let state = SessionStepsState()
        let shorter = Array(all.prefix(all.count - 30))
        let first = state.windowStart(in: shorter, pinned: false)
        let firstID = shorter[first].id
        #expect(first > 0 && shorter.count - first <= SessionTimeline.renderWindow)
        let grown = state.windowStart(in: all, pinned: false)
        #expect(all[grown].id == firstID, "새 줄이 붙어도 첫 줄 자리를 지킨다 (위로 거슬러 읽는 글이 한 줄씩 밀리지 않는다)")
        #expect(all.count - grown == shorter.count - first + 30)
    }

    @Test func aConversationThatStartedSmallIsNeverCutWhileTheReaderIsScrolledUp() {
        let all = Built(plain(150)).entries
        let state = SessionStepsState()
        #expect(state.windowStart(in: Array(all.prefix(100)), pinned: false) == 0)
        #expect(state.windowStart(in: all, pinned: false) == 0, "처음부터 보이던 첫 줄은 위로 올려 읽는 동안 대화가 길어져도 그대로다")
    }

    @Test func whileTheReaderIsPinnedToTheBottomTheWindowStaysWithinTwoWindowsAsTheConversationGrows() {
        let all = Built(plain(300)).entries
        #expect(all.count >= 900)
        let pinnedState = SessionStepsState()
        var previousDrawn = 0
        var recomputed = false
        for count in stride(from: 400, through: all.count, by: 10) {
            let entries = Array(all.prefix(count))
            let start = pinnedState.windowStart(in: entries, pinned: true)
            let drawn = count - start
            #expect(drawn <= 2 * SessionTimeline.renderWindow, "붙어 있는 동안 \(count)줄 중 \(drawn)줄을 그린다 (한도의 두 배를 넘었다)")
            if drawn < previousDrawn { recomputed = true }
            previousDrawn = drawn
        }
        #expect(recomputed, "한도를 넘으면 창을 다시 가장 새 150줄로 정한다")
        // 위로 올려 읽는 중이면 같은 성장에도 첫 줄 자리를 지킨다
        let scrolledUp = SessionStepsState()
        let firstID = all[scrolledUp.windowStart(in: Array(all.prefix(400)), pinned: false)].id
        let start = scrolledUp.windowStart(in: all, pinned: false)
        #expect(all[start].id == firstID && all.count - start > 2 * SessionTimeline.renderWindow, "읽는 글은 밀리지 않는다: 그린 줄 \(all.count - start)")
    }

    @Test func aPartialFirstSetRightAfterResetDoesNotKeepTheWindowUnbounded() {
        let all = Built(plain(300)).entries
        let state = SessionStepsState()
        state.reset()
        #expect(state.windowStart(in: Array(all.prefix(60)), pinned: true) == 0, "처음엔 일부만 읽혔다 (창에 다 든다)")
        let start = state.windowStart(in: all, pinned: true)
        let drawn = all.count - start
        #expect(drawn <= SessionTimeline.renderWindow && drawn >= SessionTimeline.renderWindow - 3, "다 읽힌 뒤 붙어 있으면 가장 새 150줄: \(drawn)")
    }

    @Test func comingBackToTheBottomBringsTheWindowBackToTheNewestEntries() {
        // 300줄: 한 번 펴면 300줄(한도의 두 배 이내)이라 크기 규칙은 닿지 않는다 — 다시 붙는 순간의 규칙만 창을 돌린다
        let entries = Built(plain(100)).entries
        #expect(entries.count == 300)
        let state = SessionStepsState()
        let newest = state.windowStart(in: entries, pinned: false)
        #expect(newest == 150)
        state.revealEarlier(in: entries)
        #expect(state.windowStart(in: entries, pinned: false) == 0, "위로 올려 읽는 동안 한 번 펴서 300줄을 다 그렸다")
        #expect(state.windowStart(in: entries, pinned: false) == 0, "붙지 않는 동안은 그대로다")
        let back = state.windowStart(in: entries, pinned: true)
        #expect(back == newest, "맨 아래에 다시 붙으면 가장 새 150줄: \(back) (처음 \(newest))")
        #expect(state.windowStart(in: entries, pinned: true) == newest, "붙어 있는 동안은 그대로다")
    }

    @Test func aRevealIsNotUndoneByAPinnedEvaluationThatSawNoNewEntries() {
        // 330줄: 처음 150줄 + 두 번 펴면 330줄을 다 그린다 (한도의 두 배, 300줄을 넘는다). 크기 규칙은 "붙은 채 새 줄이 붙을 때"만 창을 접는다
        let entries = Built(plain(110)).entries
        #expect(entries.count == 330)
        let state = SessionStepsState()
        let newest = state.windowStart(in: entries, pinned: true)
        #expect(newest > 0)
        state.revealEarlier(in: entries)
        let once = state.windowStart(in: entries, pinned: true)
        #expect(once < newest && once > 0, "한 번 폈다: \(newest) → \(once)")
        state.revealEarlier(in: entries)
        #expect(state.windowStart(in: entries, pinned: true) == 0, "두 번 펴고 붙음이 보인 계산 바로 뒤에도 편 창이 그대로다 (300줄을 넘어도)")
        #expect(state.windowStart(in: entries, pinned: true) == 0, "새 줄이 붙지 않았으면 붙어 있는 계산을 되풀이해도 창이 그대로다")
        #expect(state.windowStart(in: entries, pinned: true) == 0)
        // 붙어 있는 채 새 줄이 붙으면 그때는 한도 안으로 돌아온다 (크기 규칙은 그대로 산다)
        let more = Built(plain(112)).entries
        let grown = state.windowStart(in: more, pinned: true)
        #expect(more.count - grown <= SessionTimeline.renderWindow, "붙은 채 새 줄이 붙으면 가장 새 150줄: \(more.count - grown)줄")
    }

    @Test func aNewEntryThatArrivesTogetherWithARevealDoesNotFoldTheRevealedWindowBack() {
        let base = Built(plain(110)).entries
        let more = Built(plain(111)).entries
        let state = SessionStepsState()
        _ = state.windowStart(in: base, pinned: true)
        state.revealEarlier(in: base)
        _ = state.windowStart(in: base, pinned: true)
        state.revealEarlier(in: base)
        #expect(state.windowStart(in: more, pinned: true) == 0, "편 직후의 계산에 새 줄이 겹쳐도 방금 편 창을 접지 않는다")
    }

    @Test func aReaderWhoLooksPinnedInTheEvaluationRightAfterARevealKeepsTheRevealedWindow() {
        // 펴자마자 레이아웃 사이의 한 순간이 "맨 아래"로 보일 수 있다: 사용자가 맨 아래로 돌아온 것이 아니다
        let entries = Built(plain(100)).entries
        let state = SessionStepsState()
        let newest = state.windowStart(in: entries, pinned: false)
        state.revealEarlier(in: entries)
        #expect(state.windowStart(in: entries, pinned: true) == 0, "편 바로 뒤 계산이 붙음으로 보여도 창을 돌리지 않는다")
        #expect(state.windowStart(in: entries, pinned: false) == 0)
        #expect(state.windowStart(in: entries, pinned: true) == newest, "그 뒤 위로 올려 읽다가 진짜로 다시 붙으면 처음으로 돌아온다")
    }

    @Test func aPageLoadNeverDrawsTheOlderEntriesItBringsUntilShowEarlierIsPressedAgain() {
        let newer = Built(plain(120))
        let older = plain(100, prefix: "old-", from: t0.addingTimeInterval(-100_000))
        let both = Built(older + newer.turns)
        let hidden = both.entries.count - newer.entries.count
        #expect(hidden >= 300)
        let state = SessionStepsState()
        _ = state.windowStart(in: newer.entries, pinned: false)
        revealEverything(state, newer.entries)
        #expect(state.peekWindowStart(in: newer.entries) == 0)
        // 앞 쪽 기록을 읽어 앞에 붙었다: 붙은 줄은 창 밖이다 (다 그리지 않는다)
        let start = state.windowStart(in: both.entries, pinned: false)
        #expect(start == hidden, "그리는 줄은 그대로(\(newer.entries.count)줄)이고 붙은 \(hidden)줄은 Show earlier 뒤에 있다: 시작 \(start)")
        state.revealEarlier(in: both.entries)
        let next = state.windowStart(in: both.entries, pinned: false)
        #expect(start - next >= SessionTimeline.renderWindow && start - next <= SessionTimeline.renderWindow + 3, "다시 누르면 150줄씩: \(start) → \(next)")
        #expect(both.entries.count - next < 2 * SessionTimeline.renderWindow + newer.entries.count, "한 번에 몽땅 그리지 않는다")
    }

    @Test func revealEarlierMovesTheCutBackByTheWindowAndNeverBeyondTheStart() {
        let entries = Built(plain(120)).entries
        let state = SessionStepsState()
        var start = state.windowStart(in: entries, pinned: false)
        var steps: [Int] = []
        while start > 0 {
            state.revealEarlier(in: entries)
            let next = state.windowStart(in: entries, pinned: false)
            steps.append(start - next)
            start = next
            if steps.count > 5 { break }
        }
        #expect(start == 0)
        #expect(steps.count == 2 && steps.dropLast().allSatisfy { $0 >= SessionTimeline.renderWindow && $0 <= SessionTimeline.renderWindow + 3 }, "150씩 (덩어리 맞춤 몇 줄까지) 펴고 마지막은 남은 만큼(360줄: 210 = 150 + 60): \(steps)")
    }

    @Test func resettingTheStateGoesBackToTheNewestWindowForTheNextSession() {
        let entries = Built(plain(120)).entries
        let state = SessionStepsState()
        let first = state.windowStart(in: entries, pinned: false)
        revealEverything(state, entries)
        #expect(state.windowStart(in: entries, pinned: false) == 0)
        state.reset()
        #expect(state.windowStart(in: entries, pinned: false) == first, "다른 세션을 열면 다시 가장 새 150줄")
    }

    @Test func theCutIsChosenAgainWhenTheConversationDroppedItsFirstRenderedEntry() {
        let entries = Built(plain(150)).entries
        let state = SessionStepsState()
        let start = state.windowStart(in: entries, pinned: false)
        // 대화가 위쪽 줄을 버려 첫 줄이 사라졌다: 다시 가장 새 150줄
        let trimmed = Array(entries[(start + 5)...])
        let again = state.windowStart(in: trimmed, pinned: false)
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

    @Test func theClaudePanelHasOneShowEarlierThatFirstOpensTheLoadedEntriesThenReadsThePageAndThenOpensWhatThePageBrought() async throws {
        try requireScreenForHostedViews()
        let newest = plain(110)
        let older = plain(30, prefix: "old-", from: t0.addingTimeInterval(-10_000))
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
        let steps = claude.presentation.steps
        func entries() -> [SessionEntry] { SessionTimeline.build(SessionTimelineSource.claude(conversation.turns).items, state: .running) }
        typealias Moment = (revision: Int, turns: Int, start: Int)
        func moment() -> Moment { (steps.windowRevision, conversation.turns.count, steps.peekWindowStart(in: entries())) }
        /// 한 번 누른다: 맨 위로 올려(위로 올려 읽는 중이라야 한다) 단추 자리를 누른다. 다시 시도하지 않는다 — 한 번에 안 되면 시험이 빨개야 한다
        func press() async -> (before: Moment, after: Moment) {
            let before = moment()
            scroll(scrollView, toFraction: 0)
            await waitUntilStable { "\(Int(scrollView.contentView.bounds.origin.y))|\(Int(scrollView.documentView?.frame.height ?? 0))" }
            #expect(!conversation.pinnedToBottom, "맨 위로 올렸으면 맨 아래에 붙어 있지 않다")
            // 머리 아래 본문 맨 위 가운데: 본문 위 여백 4 + 단추 줄의 가운데
            click(claude.panel, hosting, at: CGPoint(x: hosting.bounds.midX, y: claude.presentation.headHeight + 14))
            await waitUntilStable { "\(steps.windowRevision)|\(conversation.turns.count)|\(Int(claude.presentation.bodyHeight))" }
            return (before, moment())
        }
        #expect(steps.windowRevision == 0 && conversation.hasEarlier)
        var presses = 0
        while moment().start > 0, presses < 6 {
            let (before, after) = await press()
            presses += 1
            print("HANGSTAT flow press \(presses): revision \(before.revision) -> \(after.revision), cut \(before.start) -> \(after.start), turns \(before.turns) -> \(after.turns)")
            #expect(after.turns == before.turns, "창 밖에 읽어 둔 줄이 남았으면 앞 쪽을 읽지 않는다 (\(presses)번째)")
            #expect(after.revision == before.revision + 1 && after.start < before.start, "누를 때마다 창이 앞으로 넓어진다 (\(presses)번째): 시작 \(before.start) → \(after.start)")
        }
        #expect(moment().start == 0 && presses == 2, "330줄은 처음 150줄 + 두 번에 다 펴진다: \(presses)번")
        let load = await press()
        #expect(load.after.turns == newest.count + older.count && !conversation.hasEarlier, "다 폈으면 같은 단추가 앞 쪽 기록을 읽는다: \(load.after.turns)")
        #expect(load.after.revision == load.before.revision && load.after.start > 0, "읽어 앞에 붙은 줄은 창 밖에 남는다 (한꺼번에 그리지 않는다): 시작 \(load.after.start)")
        let reveal = await press()
        #expect(reveal.after.revision == reveal.before.revision + 1 && reveal.after.start == 0, "붙은 줄은 다시 누르면 편다: 시작 \(reveal.before.start) → \(reveal.after.start)")
    }

    @Test func theClaudePanelsAssistantTextIsAsWideAsTheCodeBlockWidthItIsFoldedBy() async throws {
        try requireScreenForHostedViews()
        let built = Built(plain(3))
        let probe = Probe()
        let (window, _) = host(Harness(built: built, state: SessionStepsState(), probe: probe))
        defer { window.close() }
        await waitUntilStable { probe.events }
        let frame = try #require(probe.frames["a0"], "답 한 줄이 그려졌다")
        // 패널 본문(380 − 양옆 16)에서 Claude의 말은 전폭이다: 접을지를 정하는 폭이 실제 폭과 같다
        #expect(abs(frame.width - ClaudeAppTurnView.assistantBlockWidth) < 1, "실제 폭 \(frame.width) · 접기에 쓰는 폭 \(ClaudeAppTurnView.assistantBlockWidth)")
        #expect(ClaudeAppTurnView.assistantBlockWidth == SessionCodeBlockView.panelBlockWidth)
    }

    // MARK: 첫 배치의 비용 (센 값으로)

    /// 같은 대화(줄 352개: 열린 묶음 · 큰 코드 블록이 섞인)를 호스팅 창에 처음 올릴 때의 비용: 센 값(그려진 말 · 마크다운 줄을 계산한 횟수)과, 찍어만 두는 시간.
    /// `entriesInWindow`는 상태가 말하는 창의 크기(모델 값)이고 실제로 그린 수가 아니다: 창이 정말 줄였는지는 `itemsDrawn`(화면에 올라온 말)과 `markdownEvaluations`가 가른다
    private struct FirstLayout {
        var seconds: Double
        var entriesInWindow: Int
        var itemsDrawn: Int
        var markdownEvaluations: Int
    }

    private func firstLayout(_ built: Built, everything: Bool) async -> FirstLayout {
        let state = SessionStepsState()
        SessionPanelHangTests.prepare(state, turns: built.turns, detail: { _ in nil })
        if everything { revealEverything(state, built.entries) }
        let probe = Probe()
        let lookupsBefore = SessionMarkdownCache.shared.lookups
        let clock = ContinuousClock()
        let started = clock.now
        let (window, _) = host(Harness(built: built, state: state, probe: probe, trackPin: !everything))
        defer { window.close() }
        let quiet = 0.5
        await waitUntilStable(quiet: quiet) { probe.events }
        let elapsed = clock.now - started
        return FirstLayout(
            seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18 - quiet,
            entriesInWindow: built.entries.count - state.peekWindowStart(in: built.entries), itemsDrawn: probe.present.count,
            markdownEvaluations: SessionMarkdownCache.shared.lookups - lookupsBefore
        )
    }

    @Test func theFirstLayoutOfALongConversationBuildsOnlyTheWindowNotEverything() async throws {
        try requireScreenForHostedViews()
        let built = Built(SessionPanelHangTests.rounds(60, seed: 1) + SessionPanelHangTests.liveTail())
        #expect(built.entries.count >= 350, "줄 352개의 대화: \(built.entries.count)")
        let everything = await firstLayout(built, everything: true)
        let windowed = await firstLayout(built, everything: false)
        // 시간은 기계 부하에 따라 흔들려 찍어만 둔다. 거르는 것은 센 값이다: 만든 줄 · 그린 말 · 마크다운을 계산한 횟수는 같은 대화에서 늘 같다
        print("HANGSTAT first layout of \(built.entries.count) entries: windowed \(String(format: "%.2f", windowed.seconds)) s (\(windowed.entriesInWindow) entries, \(windowed.itemsDrawn) items, \(windowed.markdownEvaluations) markdown evaluations), everything \(String(format: "%.2f", everything.seconds)) s (\(everything.entriesInWindow) entries, \(everything.itemsDrawn) items, \(everything.markdownEvaluations) markdown evaluations)")
        #expect(everything.entriesInWindow == built.entries.count, "비교 기준은 전부 편 것이다")
        #expect(windowed.entriesInWindow <= SessionTimeline.renderWindow, "창은 가장 새 150줄이다: \(windowed.entriesInWindow)")
        #expect(windowed.itemsDrawn * 2 <= everything.itemsDrawn, "그린 말: 창 \(windowed.itemsDrawn) · 전부 \(everything.itemsDrawn)")
        #expect(Double(windowed.markdownEvaluations) <= Double(everything.markdownEvaluations) * 0.6, "마크다운 줄 계산: 창 \(windowed.markdownEvaluations)번 · 전부 \(everything.markdownEvaluations)번")
        #expect(windowed.markdownEvaluations > 0, "시험이 실제로 센다")
    }
}
