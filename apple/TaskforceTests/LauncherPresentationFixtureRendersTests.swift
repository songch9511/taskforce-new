import AppKit
import Auth
import Foundation
import AppKit
import Carbon.HIToolbox
import SwiftUI
import Supabase
import Testing
import Vision
@testable import TaskforceKit
@testable import Taskforce

/// Writes synthetic offscreen SwiftUI previews for visual review; these are fixtures, not live app captures.
@Suite(.serialized)
@MainActor
struct LauncherPresentationFixtureRendersTests {
    private final class MenuTrackingRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var began = false
        private var ended = false
        private var events: [String] = []
        private var menuItems: [String] = []

        func recordBegin() {
            lock.lock()
            began = true
            events.append("menu-begin")
            lock.unlock()
        }

        func recordEnd() {
            lock.lock()
            ended = true
            events.append("menu-end")
            lock.unlock()
        }

        func recordMenuItems(_ menu: NSMenu) {
            lock.lock()
            menuItems = menu.items.map { $0.isSeparatorItem ? "<separator>" : $0.title }
            lock.unlock()
        }

        func record(_ event: String) {
            lock.lock()
            events.append(event)
            lock.unlock()
        }

        func reset() {
            lock.lock()
            began = false
            ended = false
            events.removeAll(keepingCapacity: true)
            menuItems.removeAll(keepingCapacity: true)
            lock.unlock()
        }

        var didBegin: Bool {
            lock.lock()
            defer { lock.unlock() }
            return began
        }

        var didEnd: Bool {
            lock.lock()
            defer { lock.unlock() }
            return ended
        }

        var trace: [String] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }

        var trackedMenuItems: [String] {
            lock.lock()
            defer { lock.unlock() }
            return menuItems
        }
    }

    private struct RenderedText {
        let text: String
        let bounds: CGRect
    }

    @Test func writesLightAndDarkFixtureRenders() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TaskforceLauncherPresentationFixtures")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let appearances: [(ColorScheme, String)] = [(.light, "light"), (.dark, "dark")]
        let model = try fixtureModel()
        #expect(model.isSignedIn)
        #expect(model.items.count > 1)
        #expect(model.bodyState == .list)

        for (scheme, appearance) in appearances {
            try await render(LauncherRootView(model: model), name: "fixture-launcher-collapsed-\(appearance)", scheme: scheme, to: directory)
        }

        let demo = try #require(model.items.first { $0.inlineDetailActionID == SampleData.demoID })
        for (scheme, appearance) in appearances {
            try await render(
                LauncherRootView(model: model),
                name: "fixture-launcher-expanded-sources-\(appearance)",
                scheme: scheme,
                to: directory,
                afterInitialLayout: { model.openDetail(for: demo) }
            )
            #expect(model.detailTarget?.action.id == SampleData.demoID)
            model.back()

            let initialModel = try fixtureModel()
            let initialDemo = try #require(initialModel.items.first { $0.inlineDetailActionID == SampleData.demoID })
            initialModel.openDetail(for: initialDemo)
            #expect(initialModel.detailTarget?.action.id == SampleData.demoID)
            try await render(
                LauncherRootView(model: initialModel),
                name: "fixture-launcher-expanded-initial-\(appearance)",
                scheme: scheme,
                to: directory
            )
        }

        let settings = VStack(alignment: .leading, spacing: 8) {
            Text("Fixture · Settings / Task List")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("Task List")
                .font(.system(size: 22, weight: .semibold))
            SectionDisplaySettingsPane(preferences: .all)
        }
        .padding(20)
        .frame(width: 752, height: 440, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        for (scheme, appearance) in appearances {
            try await render(settings, name: "fixture-settings-section-counts-\(appearance)", scheme: scheme, to: directory)
        }

        let names = [
            "fixture-launcher-collapsed", "fixture-launcher-expanded-sources", "fixture-launcher-expanded-initial",
            "fixture-settings-section-counts"
        ]
        #expect(names.allSatisfy { name in
            appearances.allSatisfy { appearance in
                FileManager.default.fileExists(atPath: directory.appending(path: "\(name)-\(appearance.1).png").path)
            }
        })
        print("Wrote synthetic fixture renders to \(directory.path)")
    }

    @Test func mountedRowClicksShowTheMatchingSideDetail() async throws {
        let model = try fixtureModel()
        let now = try #require(model.now)
        let response = inlineFixtureResponse()
        let reviewID = try #require(response.confirmations.first?.id)
        let targetID = try #require(response.now.first?.id)
        let charlieID = try #require(response.now.last?.id)
        let targetTitle = try #require(response.now.first?.action.title)
        let reviewTitle = try #require(response.confirmations.first?.title)
        let saved = SavedNow(savedAt: Date(), tasks: [
            .init(title: reviewTitle, dueDate: nil, status: .review),
            .init(title: targetTitle, dueDate: nil, status: .toDo),
            .init(title: "Task Charlie", dueDate: nil, status: .toDo),
        ])
        now.applySampleState(saved: saved, offlineSince: nil, failedAt: nil)

        let size = NSSize(width: 760, height: 480)
        let window = FixtureWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: size.width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(
            rootView: LauncherRootView(model: model)
                .environment(\.colorScheme, .light)
        )
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        await settle(window, hosting)
        let savedRows = try capture(hosting, name: "mounted-saved")
        #expect(savedRows.filter { $0.text == reviewTitle }.count == 1, "Saved rows start collapsed until a row is clicked")
        #expect(savedRows.filter { $0.text == targetTitle }.count == 1)

        #expect(model.primaryAction?.title == "Show details")
        try pressKey(kVK_Return, characters: "\r", model: model, window: window)
        await settle(window, hosting)
        let expandedByReturn = try capture(hosting, name: "mounted-expanded-saved-return")
        _ = expectRightDetailBesideRow(reviewTitle, marker: "Saved", in: expandedByReturn)
        #expect(model.primaryAction?.title == "Hide details")
        try pressKey(kVK_Tab, characters: "\t", model: model, window: window)
        await settle(window, hosting)
        let collapsedByTab = try capture(hosting, name: "mounted-collapsed-saved-tab")
        #expect(collapsedByTab.filter { $0.text == reviewTitle }.count == 1)
        try pressKey(kVK_RightArrow, characters: "\u{F703}", model: model, window: window)
        await settle(window, hosting)
        _ = expectRightDetailBesideRow(reviewTitle, marker: "Saved", in: try capture(hosting, name: "mounted-expanded-saved-right-arrow"))
        try pressKey(kVK_Return, characters: "\r", model: model, window: window)
        await settle(window, hosting)
        #expect(try capture(hosting, name: "mounted-collapsed-saved-return").filter { $0.text == reviewTitle }.count == 1)

        let beforeClick = try capture(hosting, name: "mounted-saved-before-click")
        let savedRowY = try #require(rowBounds(reviewTitle, in: beforeClick)).midY
        try click(title: reviewTitle, in: beforeClick, window: window, size: size)
        await settle(window, hosting)
        let expandedSavedRow = try capture(hosting, name: "mounted-expanded-saved")
        let expandedSavedRowY = try #require(expectRightDetailBesideRow(reviewTitle, marker: "Saved", in: expandedSavedRow, unrelatedTitles: [targetTitle, "Task Charlie"])).midY
        #expect(abs(savedRowY - expandedSavedRowY) < 0.01, "Opening the side pane keeps the clicked row at the same vertical position")
        try click(title: reviewTitle, in: expandedSavedRow, window: window, size: size)
        await settle(window, hosting)
        let collapsedSavedRow = try capture(hosting, name: "mounted-collapsed-saved")
        #expect(collapsedSavedRow.filter { $0.text == reviewTitle }.count == 1)
        try click(title: reviewTitle, in: collapsedSavedRow, window: window, size: size)
        await settle(window, hosting)
        let reopenedSavedRow = try capture(hosting, name: "mounted-reopened-saved")
        _ = expectRightDetailBesideRow(reviewTitle, marker: "Saved", in: reopenedSavedRow)

        let savedReviewIndex = try #require(model.items.firstIndex {
            if case .saved(let row) = $0 { return row.task.title == reviewTitle }
            return false
        })
        let savedTaskIndex = try #require(model.items.firstIndex {
            if case .saved(let row) = $0 { return row.task.title == targetTitle }
            return false
        })
        model.select(savedTaskIndex)
        await settle(window, hosting)
        let savedAway = try capture(hosting, name: "mounted-saved-away")
        #expect(savedAway.filter { $0.text == reviewTitle }.count == 1)
        model.select(savedReviewIndex)
        await settle(window, hosting)
        let savedBack = try capture(hosting, name: "mounted-saved-back")
        #expect(savedBack.filter { $0.text == reviewTitle }.count == 1)

        try click(title: reviewTitle, in: savedBack, window: window, size: size)
        await settle(window, hosting)
        let savedOpenBeforeHydration = try capture(hosting, name: "mounted-saved-open-before-hydration")
        _ = expectRightDetailBesideRow(reviewTitle, marker: "Saved", in: savedOpenBeforeHydration)

        now.applySample(response, doneToday: [], evidence: [:])
        await settle(window, hosting)
        let liveRows = try capture(hosting, name: "mounted-live")
        #expect(liveRows.filter { $0.text == reviewTitle }.count == 1, "Hydration clears the open saved-row subtree")
        #expect(liveRows.filter { $0.text == targetTitle }.count == 1, "Hydration must not reuse saved-row content")
        let target = try #require(model.items.first { $0.inlineDetailActionID == targetID })
        let targetIndex = try #require(model.items.firstIndex(where: { $0.id == target.id }))
        let hydratedRowY = try #require(rowBounds(targetTitle, in: liveRows)).midY
        #expect(model.items.count == 3)
        #expect(now.response?.failedSources.count == 2, "Pipeline failure diagnostics remain in the underlying response")
        #expect(!model.items.contains { if case .failedSources = $0 { true } else { false } }, "The launcher list omits the top-level failed-sources notice")
        try click(title: targetTitle, in: liveRows, window: window, size: size)
        await settle(window, hosting)

        #expect(model.detailTarget?.action.id == targetID)
        #expect(model.selection == targetIndex)
        let targetWithoutEvidence = try capture(hosting, name: "mounted-expanded-target-no-source")
        let openedTargetRowY = try #require(expectRightDetailBesideRow(targetTitle, marker: "No source details", in: targetWithoutEvidence)).midY
        #expect(abs(hydratedRowY - openedTargetRowY) < 0.01, "Opening live detail preserves the list's vertical position")

        now.applySample(response, doneToday: [], evidence: inlineFixtureEvidence(reviewID: reviewID, targetID: targetID))
        await settle(window, hosting)
        let expandedTarget = try capture(hosting, name: "mounted-expanded-target-with-source")
        let hydratedTargetRowY = try #require(expectRightDetailBesideRow(targetTitle, marker: "Inline evidence target", in: expandedTarget, unrelatedTitles: [reviewTitle, "Task Charlie"])).midY
        #expect(abs(openedTargetRowY - hydratedTargetRowY) < 0.01, "Source arrival does not move the selected row")

        try click(title: reviewTitle, in: expandedTarget, window: window, size: size)
        await settle(window, hosting)
        #expect(model.detailTarget?.action.id == reviewID)
        let expandedReview = try capture(hosting, name: "mounted-expanded-review")
        _ = expectRightDetailBesideRow(reviewTitle, marker: "Inline evidence review", in: expandedReview, unrelatedTitles: [targetTitle, "Task Charlie"])

        try click(title: reviewTitle, in: expandedReview, window: window, size: size)
        await settle(window, hosting)
        #expect(model.screen == .list)
        let collapsed = try capture(hosting, name: "mounted-collapsed")
        #expect(collapsed.filter { $0.text == reviewTitle }.count == 1)

        model.text = "Charlie"
        await settle(window, hosting)
        let filteredCharlie = try capture(hosting, name: "mounted-filtered-charlie")
        #expect(model.items.filter { $0.group != nil }.compactMap(\.action).map(\.id) == [charlieID])
        #expect(filteredCharlie.contains { $0.text == "Task Charlie" })
        #expect(!filteredCharlie.contains { $0.text == targetTitle })
        #expect(!filteredCharlie.contains { $0.text == reviewTitle })
    }

    @Test func mountedLongListLowerRowExpansionAndEvidenceStayResponsive() async throws {
        let model = try fixtureModel()
        let now = try #require(model.now)
        model.account?.useSampleData(connections: [])
        model.runs?.applySample(credits: .unavailable, runs: [], steps: [], drafts: [])
        let response = longListFixtureResponse()
        let target = try #require(response.now.last?.action)
        let neighbor = try #require(response.now.dropLast().last?.action)
        now.applySample(response, doneToday: [], evidence: [:])

        let controller = LauncherPanelController(model: model)
        controller.show()
        defer { controller.hide() }
        let window = try #require(model.presentationAnchor())
        let panelDelegate = window.delegate
        window.delegate = nil // Keep unrelated test-runner focus changes from exercising outside-click auto-hide.
        defer { window.delegate = panelDelegate }
        await settlePanel(window)

        #expect(model.items.count >= 50)
        let targetIndex = try #require(model.items.firstIndex { $0.action?.id == target.id })
        model.select(targetIndex)
        await settlePanel(window)
        let selectedLowerRow = try capturePanel(window, name: "long-list-selected-lower-row")
        #expect(
            selectedLowerRow.contains { $0.text == target.title },
            "Selection \(model.selection) should scroll the lower action into view; rendered: \(selectedLowerRow.map(\.text))"
        )

        try clickPanel(title: target.title, in: selectedLowerRow, window: window)
        await settlePanel(window)
        #expect(model.detailTarget?.action.id == target.id)
        #expect(controller.isVisible, "Clicking a row keeps the shown panel visible")
        let emptyDetail = try capturePanel(window, name: "long-list-empty-detail")
        #expect(emptyDetail.contains { $0.text.contains("No source details available") }, "A row with no cached source data shows an explicit empty state")

        let delayedDigest = EvidenceDigest(lines: (0..<24).map { index in
            EvidenceLine(
                id: fixtureID(4_000 + index),
                quote: "Delayed arrival marker \(index + 1): " + String(repeating: "synthetic evidence text for the visible detail continuation. ", count: 12),
                sourceID: fixtureID(3_000 + index),
                sourceTitle: "Delayed source \(index + 1)",
                occurredAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)),
                externalURL: nil,
                service: .manual(.note)
            )
        })
        now.applySample(response, doneToday: [], evidence: [target.id: delayedDigest])
        await settlePanel(window)
        let expandedBeforeScroll = try capturePanel(window, name: "long-list-expanded-before-evidence-scroll")
        _ = expectRightDetailBesideRow(target.title, marker: "Delayed source 24", in: expandedBeforeScroll)
        scrollPanel(window, by: 260)
        await settlePanel(window)
        let expanded = try capturePanel(window, name: "long-list-expanded-after-evidence")
        #expect(expanded.contains { $0.text.contains("Delayed source 24") && $0.bounds.midX >= 0.5 }, "Evidence remains in the independently scrolling detail pane")
        #expect(expanded.contains { $0.text.contains("Delayed arrival marker 24") && $0.bounds.midX >= 0.5 })
        scrollDetailPanelToBottom(window)
        await settlePanel(window)
        let detailBottom = try capturePanel(window, name: "long-list-detail-scrolled-to-bottom")
        #expect(detailBottom.contains { $0.text.contains("Delayed source 1") && $0.bounds.midX >= 0.5 })
        await expectMainQueueHeartbeat()

        let selectedNeighbor = try capturePanel(window, name: "long-list-visible-neighbor")
        #expect(selectedNeighbor.contains { $0.text == neighbor.title && $0.bounds.midX < 0.5 })
        try clickPanel(title: neighbor.title, in: selectedNeighbor, window: window)
        await settlePanel(window)
        #expect(model.detailTarget?.action.id == neighbor.id, "Switching rows keeps the detail attached to the new action")
        let neighborDetail = try capturePanel(window, name: "long-list-neighbor-detail-reset")
        _ = expectRightDetailBesideRow(neighbor.title, marker: "No source details", in: neighborDetail)
        #expect(!neighborDetail.contains { $0.text.contains("Delayed source 1") && $0.bounds.midX >= 0.5 }, "A new action resets the previous detail scroll position and content")

        try postKey(kVK_Escape, characters: "\u{1B}", to: window)
        await settlePanel(window)
        #expect(model.screen == .list, "Escape closes the side detail after switching rows")
        #expect(controller.isVisible, "Escape closes the side detail without hiding the launcher panel")
        try focusSearch(window)
        await settlePanel(window)
        #expect(controller.isVisible)
        typeInSearch("anchor", window: window)
        await settlePanel(window)
        let searchResults = try capturePanel(window, name: "long-list-search-results")
        #expect(searchResults.contains { $0.text == "anchor" }, "The native Search field displays the typed query")
        #expect(model.items.contains { $0.action?.id == target.id }, "Typed search keeps its matching lower action")
        #expect(!model.items.contains { $0.action?.id == neighbor.id }, "Typed search removes the unrelated action")
        try postKey(kVK_Escape, characters: "\u{1B}", to: window)
        await settlePanel(window)
        #expect(model.text.isEmpty, "Escape clears the search through the panel's key monitor")
        #expect(model.items.contains { $0.action?.id == neighbor.id })
    }

    @Test func mountedFiveHundredRowsScrollSearchAndEscapeStayResponsive() async throws {
        let model = try fixtureModel()
        let now = try #require(model.now)
        model.account?.useSampleData(connections: [])
        model.runs?.applySample(credits: .unavailable, runs: [], steps: [], drafts: [])
        let response = longListFixtureResponse(totalCount: 500)
        let target = try #require(response.now.last?.action)
        now.applySample(response, doneToday: [], evidence: [:])

        let controller = LauncherPanelController(model: model)
        controller.show()
        defer { controller.hide() }
        let window = try #require(model.presentationAnchor())
        let panelDelegate = window.delegate
        window.delegate = nil // Keep unrelated test-runner focus changes from exercising outside-click auto-hide.
        defer { window.delegate = panelDelegate }
        await settlePanel(window)
        #expect(model.items.count == 500)
        #expect(now.response?.failedSources.count == 2)
        #expect(!model.items.contains { if case .failedSources = $0 { true } else { false } })

        let initialOffset = try #require(scrollOffset(in: window))
        let targetIndex = try #require(model.items.firstIndex { $0.action?.id == target.id })
        model.select(targetIndex)
        await settlePanel(window)
        let scrolledOffset = try #require(scrollOffset(in: window))
        #expect(scrolledOffset != initialOffset, "Selecting a lower row scrolls the native launcher list")
        let selected = try capturePanel(window, name: "five-hundred-selected-lower-row")
        try clickPanel(title: target.title, in: selected, window: window)
        await settlePanel(window)
        #expect(model.detailTarget?.action.id == target.id)
        #expect(controller.isVisible, "Clicking a row keeps the shown panel visible")
        await expectMainQueueHeartbeat()

        try postKey(kVK_Escape, characters: "\u{1B}", to: window)
        await settlePanel(window)
        #expect(model.screen == .list, "Escape closes the side detail through the shown panel")
        #expect(controller.isVisible, "Escape closes the side detail without hiding the launcher panel")

        try focusSearch(window)
        await settlePanel(window)
        #expect(controller.isVisible)
        typeInSearch("anchor", window: window)
        await settlePanel(window)
        let searchResults = try capturePanel(window, name: "five-hundred-search-results")
        #expect(searchResults.contains { $0.text == "anchor" }, "The native Search field displays the typed query")
        #expect(model.text == "anchor")
        #expect(
            model.items.filter { $0.inlineDetailActionID != nil }.compactMap(\.action).map(\.id) == [target.id],
            "Search recalculates the rendered 500-row task rows without stale entries"
        )
        try postKey(kVK_Escape, characters: "\u{1B}", to: window)
        await settlePanel(window)
        #expect(model.text.isEmpty)
        #expect(model.items.count == 500)
        #expect(window.isVisible, "Escape clears the search without closing the visible launcher panel")
        await expectMainQueueHeartbeat()
    }

    @Test func savedDisclosureExpiresWithSearchScopeShowAndSnapshot() async throws {
        let model = try fixtureModel()
        let now = try #require(model.now)
        let saved = SavedNow(savedAt: Date(timeIntervalSince1970: 1_800_000_000), tasks: [
            .init(title: "Lifecycle Alpha", dueDate: nil, status: .review),
            .init(title: "Lifecycle Bravo", dueDate: nil, status: .toDo),
        ])
        now.applySampleState(saved: saved, offlineSince: nil, failedAt: nil)
        let alpha = try #require(model.items.compactMap { item -> SavedNow.Row? in
            if case .saved(let row) = item, row.task.title == "Lifecycle Alpha" { return row }
            return nil
        }.first)
        model.toggleSavedRow(alpha)
        #expect(model.isSavedRowExpanded(alpha))

        model.text = "Lifecycle"
        #expect(!model.isSavedRowExpanded(alpha))
        model.text = ""
        model.toggleSavedRow(alpha)
        #expect(model.isSavedRowExpanded(alpha))

        model.chooseScope(.toDo)
        #expect(!model.isSavedRowExpanded(alpha))
        model.chooseScope(.allTasks)
        let restoredAlphaIndex = try #require(model.items.firstIndex {
            if case .saved(let row) = $0 { return row.task.title == "Lifecycle Alpha" }
            return false
        })
        model.select(restoredAlphaIndex)
        let restoredAlpha = try #require(model.items.compactMap { item -> SavedNow.Row? in
            if case .saved(let row) = item, row.task.title == "Lifecycle Alpha" { return row }
            return nil
        }.first)
        model.toggleSavedRow(restoredAlpha)
        #expect(model.isSavedRowExpanded(restoredAlpha))

        let replacement = SavedNow(savedAt: saved.savedAt.addingTimeInterval(1), tasks: [
            .init(title: "Lifecycle Replacement", dueDate: nil, status: .review),
            .init(title: "Lifecycle Bravo", dueDate: nil, status: .toDo),
        ])
        now.applySampleState(saved: replacement, offlineSince: nil, failedAt: nil)
        let replacementRow = try #require(model.items.compactMap { item -> SavedNow.Row? in
            if case .saved(let row) = item, row.task.title == "Lifecycle Replacement" { return row }
            return nil
        }.first)
        let replacementIndex = try #require(model.items.firstIndex {
            if case .saved(let row) = $0 { return row == replacementRow }
            return false
        })
        model.select(replacementIndex)
        #expect(replacementRow.id == restoredAlpha.id, "Saved row IDs are offsets, so the snapshot must also match")
        #expect(!model.isSavedRowExpanded(replacementRow))
        model.reconcileSavedDisclosure()

        model.toggleSavedRow(replacementRow)
        #expect(model.isSavedRowExpanded(replacementRow))
        model.prepareForShow()
        #expect(!model.isSavedRowExpanded(replacementRow))
    }

    @Test func explicitDetailCloseDismissesLaneFocusedPane() throws {
        let model = try fixtureModel()
        let item = try #require(model.items.first { $0.action?.id == SampleData.demoID })
        let fixture = SampleRuns.fixture(.draftReady)
        model.runs?.applySample(
            credits: .available(SampleRuns.laneCredits(.draftReady), checkedAt: Date()),
            runs: fixture.runs,
            steps: fixture.steps,
            drafts: fixture.drafts
        )
        model.openDetail(for: item)

        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
            isARepeat: false, keyCode: UInt16(kVK_Tab)
        ))
        #expect(model.handleKey(event))
        #expect(model.laneFocusTarget?.action.id == SampleData.demoID)

        model.closeDetailPane()

        #expect(model.screen == .list)
        #expect(model.laneFocusTarget == nil)
        #expect(model.selectedItem?.action?.id == SampleData.demoID)
    }

    @Test func nativeRowMenuEscDismissesMenuWithoutClosingLauncher() async throws {
        let model = try fixtureModel()
        let review = try #require(model.items.first { if case .review = $0 { true } else { false } })
        let title = try #require(review.action?.title)
        let controller = LauncherPanelController(model: model)
        controller.show()
        defer { controller.hide() }
        let window = try #require(model.presentationAnchor())
        await settlePanel(window)

        let before = try capturePanel(window, name: "native-row-menu-before")
        let row = try #require(rowBounds(title, in: before))
        let previousPoint = NSPoint(
            x: row.midX < 0.5 ? LauncherPanelController.size.width * 0.96 : row.maxX * LauncherPanelController.size.width,
            y: row.midY * LauncherPanelController.size.height
        )
        let contentView = try #require(window.contentView)
        let nativeControls = nativeMenuControlViews(in: contentView)
        let rowControls = nativeControls.filter { view in
            let frame = view.convert(view.bounds, to: nil)
            return frame.minY <= previousPoint.y && frame.maxY >= previousPoint.y && frame.midX >= window.frame.width / 2
        }
        let menuControl = try #require(rowControls.max { lhs, rhs in
            lhs.convert(lhs.bounds, to: nil).midX < rhs.convert(rhs.bounds, to: nil).midX
        })
        let menuControlFrame = menuControl.convert(menuControl.bounds, to: nil)
        let point = NSPoint(x: menuControlFrame.midX, y: menuControlFrame.midY)
        let clickPoints: [(String, NSPoint)] = [
            ("center", point),
            ("top interior", NSPoint(x: point.x, y: menuControlFrame.minY + 1)),
            ("bottom interior", NSPoint(x: point.x, y: menuControlFrame.maxY - 1))
        ]
        let hoverPoint = NSPoint(x: row.midX * window.frame.width, y: row.midY * window.frame.height)
        let outsidePoint = NSPoint(x: hoverPoint.x, y: max(4, hoverPoint.y - 48))
        let oldTarget = hitTestView(at: previousPoint, in: contentView)
        print("Native row-menu control: \(type(of: menuControl)) frame=\(menuControlFrame), old OCR point=\(previousPoint) hit=\(hitTargetDescription(oldTarget))")
        #expect(menuControlFrame.width >= 24 && menuControlFrame.height >= 16,
                "The native bordered Menu has a compact hit target matching its visible bezel: \(menuControlFrame)")
        let tracker = MenuTrackingRecorder()
        let originalClose = model.close
        var closeCalls = 0
        model.close = {
            closeCalls += 1
            tracker.record("model-close")
            originalClose()
        }
        let beganObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil
        ) { notification in
            if let menu = notification.object as? NSMenu { tracker.recordMenuItems(menu) }
            tracker.recordBegin()
        }
        let endedObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil
        ) { _ in tracker.recordEnd() }
        let resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: nil
        ) { _ in tracker.record("window-resign-key") }
        let appResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: NSApp, queue: nil
        ) { _ in tracker.record("application-resign-active") }
        let keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                tracker.record("escape-local-monitor(window=\(event.window?.windowNumber ?? -1),menuTracking=\(tracker.didBegin && !tracker.didEnd))")
            }
            return event
        }
        defer {
            NotificationCenter.default.removeObserver(beganObserver)
            NotificationCenter.default.removeObserver(endedObserver)
            NotificationCenter.default.removeObserver(resignObserver)
            NotificationCenter.default.removeObserver(appResignObserver)
            if let keyEventMonitor { NSEvent.removeMonitor(keyEventMonitor) }
        }

        // AppKit enters native menu tracking synchronously from mouse-down; queue Escape first so this stays bounded.
        #expect(controller.isVisible, "The launcher panel is visible before opening a row menu")
        guard window.isKeyWindow else {
            #expect(window.isKeyWindow, "Native menu input needs the fixture panel to be key")
            return
        }

        window.acceptsMouseMovedEvents = true
        try moveMouse(to: outsidePoint, in: window)
        await settlePanel(window)
        let hiddenRender = try capturePanel(window, name: "native-row-menu-hidden")
        let titleBeforeHover = try #require(rowBounds(title, in: hiddenRender))
        #expect(!hasVisibleAncestors(of: menuControl), "The row action stays hidden while the pointer is outside its row")
        try moveMouse(to: hoverPoint, in: window)
        await settlePanel(window)
        let hoveredRender = try capturePanel(window, name: "native-row-menu-hovered")
        let titleAfterHover = try #require(rowBounds(title, in: hoveredRender))
        let frameAfterHover = menuControl.convert(menuControl.bounds, to: nil)
        #expect(hasVisibleAncestors(of: menuControl), "Hovering the row title reveals its action menu without moving the row")
        #expect(frameAfterHover == menuControlFrame, "Showing the menu preserves its reserved native control frame")
        #expect(abs(titleAfterHover.midX - titleBeforeHover.midX) < 0.002 && abs(titleAfterHover.midY - titleBeforeHover.midY) < 0.002,
                "Showing the menu does not move the row title")

        for (name, clickPoint) in clickPoints {
            try moveMouse(to: hoverPoint, in: window)
            await settlePanel(window)
            #expect(hasVisibleAncestors(of: menuControl), "Hovering the row reveals the native menu before the \(name) click")
            let target = hitTestView(at: clickPoint, in: contentView)
            #expect(target === menuControl, "The \(name) point \(clickPoint) hits the native menu button, got \(hitTargetDescription(target)); bounds=\(menuControlFrame)")
            #expect(menuControlFrame.contains(clickPoint), "The \(name) point \(clickPoint) remains inside the native visible control \(menuControlFrame)")
            guard let down = NSEvent.mouseEvent(
                with: .leftMouseDown, location: clickPoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ), let escape = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0, context: nil, characters: "\u{1B}",
                charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: UInt16(kVK_Escape)
            ) else { throw FixtureRenderError.missingRenderedText("native row menu events at \(name)") }

            tracker.reset()
            tracker.record("before-menu-click-\(name)")
            NSApp.postEvent(escape, atStart: false)
            NSApp.sendEvent(down)
            await settlePanel(window)

            #expect(tracker.didBegin, "Clicking the native menu \(name) opens its menu: \(tracker.trace)")
            #expect(tracker.didEnd, "Queued Escape dismisses the native menu \(name): \(tracker.trace)")
            #expect(model.screen == .list, "The native menu \(name) point must not activate a row action")
            #expect(controller.isVisible, "Escape from the native menu \(name) leaves the launcher visible: \(tracker.trace)")
        }

        try moveMouse(to: outsidePoint, in: window)
        await settlePanel(window)
        #expect(!hasVisibleAncestors(of: menuControl), "The row action hides again after Escape when the pointer leaves the row")

        let menuItems = tracker.trackedMenuItems
        let confirmIndex = menuItems.firstIndex(of: "Confirm")
        let dismissIndex = menuItems.firstIndex(of: "Dismiss")
        let handoffIndex = menuItems.firstIndex(of: "Hand off to AI")
        if let confirmIndex, let dismissIndex, let handoffIndex {
            #expect(confirmIndex < dismissIndex && dismissIndex < handoffIndex, "Review actions retain their established order: \(menuItems)")
            #expect(!menuItems[(confirmIndex + 1)..<dismissIndex].contains("<separator>"), "Confirm and Dismiss stay together: \(menuItems)")
            #expect(menuItems[(dismissIndex + 1)..<handoffIndex].contains("<separator>"), "Handoff actions start a separate native menu group: \(menuItems)")
        } else {
            #expect(Bool(false), "The tracked native Review menu exposes Confirm, Dismiss, and Hand off to AI: \(menuItems)")
        }
        #expect(model.screen == .list, "Opening a row menu must not activate an action")
        #expect(closeCalls == 0, "A menu Escape should not reach the launcher close callback: \(tracker.trace)")
        #expect(controller.isVisible, "Escape dismisses the native row menu without closing its launcher panel: \(tracker.trace)")
        print("Native row-menu geometry and Escape checks: frame=\(menuControlFrame), points=\(clickPoints.map { $0.0 }), trace=\(tracker.trace)")
    }

    @discardableResult
    private func render<Content: View>(
        _ view: Content,
        name: String,
        scheme: ColorScheme,
        to directory: URL,
        afterInitialLayout: (() -> Void)? = nil
    ) async throws -> [RenderedText] {
        let size = NSSize(width: 760, height: 480)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.wantsLayer = true
        window.contentView = hosting
        window.displayIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        afterInitialLayout?()
        await Task.yield()
        try await Task.sleep(for: .milliseconds(240))
        window.displayIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        let result = try capture(hosting, name: name, in: directory, recognizeText: false)
        window.close()
        return result
    }

    private func capture<Content: View>(
        _ hosting: NSHostingView<Content>, name: String, in directory: URL? = nil, recognizeText: Bool = true
    ) throws -> [RenderedText] {
        hosting.displayIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw FixtureRenderError.failed(name)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw FixtureRenderError.failed(name)
        }
        let directory = directory ?? FileManager.default.temporaryDirectory.appending(path: "TaskforceLauncherInteractionFixtures")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appending(path: "\(name).png"), options: .atomic)
        guard recognizeText else { return [] }
        guard let image = bitmap.cgImage else { throw FixtureRenderError.failed(name) }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { RenderedText(text: $0.string, bounds: observation.boundingBox) }
        }
    }

    private func capturePanel(_ window: NSWindow, name: String) throws -> [RenderedText] {
        guard let content = panelHostingView(window) else { throw FixtureRenderError.failed(name) }
        content.displayIfNeeded()
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            throw FixtureRenderError.failed(name)
        }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]), let image = bitmap.cgImage else {
            throw FixtureRenderError.failed(name)
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: "TaskforceLauncherLongListFixtures")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appending(path: "\(name).png"), options: .atomic)

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { RenderedText(text: $0.string, bounds: observation.boundingBox) }
        }
    }

    private func settle<Content: View>(_ window: NSWindow, _ hosting: NSHostingView<Content>) async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(240))
        window.displayIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
    }

    private func settlePanel(_ window: NSWindow) async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(240))
        window.displayIfNeeded()
        panelHostingView(window)?.layoutSubtreeIfNeeded()
        panelHostingView(window)?.displayIfNeeded()
        pumpMainRunLoop()
        window.displayIfNeeded()
    }

    private func pumpMainRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    }

    private func panelHostingView(_ window: NSWindow) -> NSView? {
        guard let root = window.contentView else { return nil }
        if #available(macOS 26.0, *), let glass = root as? NSGlassEffectView, let hosted = glass.contentView {
            return hosted
        }
        func findHostingView(_ view: NSView) -> NSView? {
            if String(describing: type(of: view)).contains("NSHostingView") { return view }
            for child in view.subviews {
                if let hosted = findHostingView(child) { return hosted }
            }
            return nil
        }
        return findHostingView(root)
    }

    private func expectMainQueueHeartbeat() async {
        let scheduledAt = Date()
        let ranAt = await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume(returning: Date()) }
        }
        #expect(ranAt.timeIntervalSince(scheduledAt) < 0.5, "The launcher main queue should remain responsive after evidence arrives")
    }

    private func click(
        title: String, in texts: [RenderedText], window: NSWindow, size: NSSize
    ) throws {
        let matches = texts.filter { $0.text == title && $0.bounds.midX < 0.5 }
        guard let frame = matches.max(by: { $0.bounds.midY < $1.bounds.midY })?.bounds else {
            throw FixtureRenderError.missingRenderedText(title)
        }
        let point = NSPoint(x: frame.midX * size.width, y: frame.midY * size.height)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ) else { throw FixtureRenderError.missingRenderedText(title) }
            window.sendEvent(event)
        }
    }

    private func clickPanel(title: String, in texts: [RenderedText], window: NSWindow) throws {
        let matches = texts.filter { $0.text == title && $0.bounds.midX < 0.5 }
        guard let frame = matches.max(by: { $0.bounds.midY < $1.bounds.midY })?.bounds else {
            throw FixtureRenderError.missingRenderedText(title)
        }
        let point = NSPoint(x: frame.midX * LauncherPanelController.size.width, y: frame.midY * LauncherPanelController.size.height)
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ), let up = NSEvent.mouseEvent(
            with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ) else { throw FixtureRenderError.missingRenderedText(title) }
        // Queue mouse-up before dispatching mouse-down so AppKit's native tracking loop stays bounded.
        NSApp.postEvent(up, atStart: false)
        NSApp.sendEvent(down)
    }

    private func postKey(_ keyCode: Int, characters: String, to window: NSWindow) throws {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(keyCode)
        ) else { throw FixtureRenderError.missingRenderedText("key \(keyCode)") }
        NSApp.postEvent(event, atStart: false)
    }

    private func typeInSearch(_ value: String, window: NSWindow) {
        let keyCodes: [Character: Int] = [
            "a": kVK_ANSI_A, "c": kVK_ANSI_C, "h": kVK_ANSI_H, "n": kVK_ANSI_N,
            "o": kVK_ANSI_O, "r": kVK_ANSI_R, "w": kVK_ANSI_W
        ]
        for character in value {
            guard let keyCode = keyCodes[character],
                  let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: String(character),
                    charactersIgnoringModifiers: String(character), isARepeat: false, keyCode: UInt16(keyCode)
                  ) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    private func focusSearch(_ window: NSWindow) throws {
        let fields = try capturePanel(window, name: "launcher-search-focus")
        try clickPanel(title: "Search tasks", in: fields, window: window)
    }

    private func pressKey(
        _ keyCode: Int, characters: String, model: LauncherModel, window: NSWindow
    ) throws {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(keyCode)
        ) else { throw FixtureRenderError.missingRenderedText("key \(keyCode)") }
        #expect(model.handleKey(event), "Key \(keyCode) should be handled by the mounted launcher")
    }

    private func rowBounds(_ title: String, in texts: [RenderedText]) -> CGRect? {
        texts.first { $0.text == title && $0.bounds.midX < 0.5 }?.bounds
    }

    private func nativeMenuControlViews(in view: NSView) -> [NSView] {
        let typeName = String(describing: type(of: view))
        let role = String(describing: view.accessibilityRole())
        let isMenuControl = view is NSPopUpButton || typeName.contains("PopupButton") || role.contains("AXMenuButton") || role.contains("AXPopUpButton")
        let descendants = view.subviews.flatMap(nativeMenuControlViews)
        return isMenuControl ? [view] + descendants : descendants
    }

    private func hitTestView(at point: NSPoint, in view: NSView) -> NSView? {
        let convertedPoint = view.convert(point, from: nil)
        return view.hitTest(convertedPoint)
    }

    private func hitTargetDescription(_ view: NSView?) -> String {
        guard let view else { return "<none>" }
        let frame = view.convert(view.bounds, to: nil)
        return "\(type(of: view)) frame=\(frame) role=\(String(describing: view.accessibilityRole()))"
    }

    private func mouseMovedEvent(to point: NSPoint, in window: NSWindow) -> NSEvent? {
        NSEvent.mouseEvent(
            with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
        )
    }

    private func moveMouse(to point: NSPoint, in window: NSWindow) throws {
        guard let event = mouseMovedEvent(to: point, in: window) else {
            throw FixtureRenderError.missingRenderedText("mouse movement to \(point)")
        }
        NSApp.sendEvent(event)
        pumpMainRunLoop()
    }

    private func hasVisibleAncestors(of view: NSView) -> Bool {
        var current: NSView? = view
        while let candidate = current {
            if candidate.isHidden || candidate.alphaValue <= 0.01 { return false }
            if let opacity = candidate.layer?.opacity, opacity <= 0.01 { return false }
            current = candidate.superview
        }
        return true
    }

    @discardableResult
    private func expectRightDetailBesideRow(
        _ title: String, marker: String, in texts: [RenderedText], unrelatedTitles: [String] = []
    ) -> CGRect? {
        let rowTitles = texts.filter { $0.text == title && $0.bounds.midX < 0.5 }
        let paneTitles = texts.filter { $0.text == title && $0.bounds.midX >= 0.5 }
        let detail = texts.filter { $0.text.contains(marker) && $0.bounds.midX >= 0.5 }
        #expect(rowTitles.count == 1, "The selected action title appears once in the list: \(rowTitles.map(\.bounds))")
        #expect(paneTitles.count == 1, "The detail pane has one matching title: \(paneTitles.map(\.bounds))")
        #expect(!detail.isEmpty, "Expected useful detail marker \(marker) in the right pane")
        guard let row = rowTitles.first?.bounds else { return nil }
        if let paneTitle = paneTitles.first {
            #expect(paneTitle.bounds.midX > row.midX + 0.2, "Detail title belongs in the pane to the right of the selected row")
        }
        for unrelatedTitle in unrelatedTitles {
            #expect(
                !texts.contains { $0.text == unrelatedTitle && $0.bounds.midX >= 0.5 },
                "Unrelated row \(unrelatedTitle) must not become the right-pane detail"
            )
        }
        return row
    }

    private func inlineFixtureEvidence(reviewID: UUID, targetID: UUID) -> [UUID: EvidenceDigest] {
        func digest(id: UUID, title: String) -> EvidenceDigest {
            EvidenceDigest(lines: [EvidenceLine(
                id: id, quote: "A short synthetic evidence line for the inline detail regression.",
                sourceID: id, sourceTitle: title, occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
                externalURL: nil, service: .manual(.note)
            )])
        }
        return [reviewID: digest(id: fixtureID(6_001), title: "Inline evidence review"),
                targetID: digest(id: fixtureID(6_002), title: "Inline evidence target")]
    }

    private func scrollOffset(in window: NSWindow) -> CGFloat? {
        guard let root = panelHostingView(window) else { return nil }
        func findScrollView(_ view: NSView) -> NSScrollView? {
            if let scrollView = view as? NSScrollView { return scrollView }
            for child in view.subviews {
                if let scrollView = findScrollView(child) { return scrollView }
            }
            return nil
        }
        return findScrollView(root)?.contentView.bounds.origin.y
    }

    private func scrollPanel(_ window: NSWindow, by delta: CGFloat) {
        guard let root = panelHostingView(window) else { return }
        func findScrollView(_ view: NSView) -> NSScrollView? {
            if let scrollView = view as? NSScrollView { return scrollView }
            for child in view.subviews {
                if let scrollView = findScrollView(child) { return scrollView }
            }
            return nil
        }
        guard let scrollView = findScrollView(root) else { return }
        let clipView = scrollView.contentView
        var origin = clipView.bounds.origin
        let maxY = max(0, (scrollView.documentView?.bounds.height ?? 0) - clipView.bounds.height)
        origin.y = min(maxY, max(0, origin.y + delta))
        clipView.scroll(to: origin)
        scrollView.reflectScrolledClipView(clipView)
    }

    private func scrollDetailPanelToBottom(_ window: NSWindow) {
        guard let root = panelHostingView(window) else { return }
        var candidates: [NSScrollView] = []
        func collectScrollViews(_ view: NSView) {
            if let scrollView = view as? NSScrollView { candidates.append(scrollView) }
            view.subviews.forEach(collectScrollViews)
        }
        collectScrollViews(root)
        guard let scrollView = candidates.first(where: { $0.convert($0.bounds, to: root).midX > root.bounds.midX }) else { return }
        let clipView = scrollView.contentView
        var origin = clipView.bounds.origin
        origin.y = max(0, (scrollView.documentView?.bounds.height ?? 0) - clipView.bounds.height)
        clipView.scroll(to: origin)
        scrollView.reflectScrolledClipView(clipView)
    }

    private func fixtureModel() throws -> LauncherModel {
        let config = AppConfig(
            supabaseURL: URL(string: "https://taskforce-fixture.invalid")!,
            supabaseKey: "fixture-only",
            appGroupID: "group.test.taskforce.fixture",
            apiBaseURL: URL(string: "https://taskforce-api-fixture.invalid")!
        )
        let supabase = SupabaseClient(
            supabaseURL: config.supabaseURL,
            supabaseKey: config.supabaseKey,
            options: SupabaseClientOptions(
                auth: .init(storage: FixtureAuthStorage(), autoRefreshToken: false, emitLocalSessionAsInitialSession: true),
                global: .init(session: URLSession(configuration: .ephemeral))
            )
        )
        let session = SessionStore(auth: supabase.auth)
        session.apply(event: .signedOut, session: nil)
        let services = AppServices(config: config, supabase: supabase, session: URLSession(configuration: .ephemeral))
        let account = AccountStore(services: services, session: session)
        let defaults = UserDefaults(suiteName: "LauncherPresentationFixture-\(UUID().uuidString)")!
        let model = LauncherModel(session: session, services: services, account: account, displayPreferencesDefaults: defaults)
        guard let now = model.now else { throw FixtureRenderError.missingNowStore }
        now.sampleMode = true
        let evidence = SampleData.evidence
        now.applySample(
            SampleData.now,
            doneToday: SampleData.doneToday,
            evidence: evidence,
            sourceServices: evidence.mapValues { $0.withoutReceipts.services }
        )
        return model
    }

    private func inlineFixtureResponse() -> NowResponse {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        func action(_ id: String, _ title: String, needsConfirmation: Bool) -> ActionSummary {
            ActionSummary(
                id: UUID(uuidString: id)!, title: title, owner: .me, status: .open, dueDate: nil,
                counterpart: nil, needsConfirmation: needsConfirmation, confirmReasons: [], startedAt: nil,
                lastActivityAt: timestamp
            )
        }
        let review = action("5A000000-0000-4000-8000-000000000101", "Review Alpha", needsConfirmation: true)
        let bravo = action("5A000000-0000-4000-8000-000000000102", "Task Bravo", needsConfirmation: false)
        let charlie = action("5A000000-0000-4000-8000-000000000103", "Task Charlie", needsConfirmation: false)
        return NowResponse(
            now: [bravo, charlie].map { RankedAction(action: $0, score: 1, reasons: [], daysUntilDue: nil) },
            confirmations: [review], weeklyCheck: nil,
            failedSources: FailedSources(count: 2, latestAt: timestamp, reason: .internal), tracksChanges: true
        )
    }

    private func longListFixtureResponse(totalCount: Int = 54) -> NowResponse {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let reviewCount = totalCount / 4
        let taskCount = totalCount - reviewCount
        let reviews = (0..<reviewCount).map { index in
            fixtureAction(1_000 + index, title: "긴 제목의 확인 요청과 원문 상태를 함께 살펴볼 필요가 있는 검토 \(index + 1)", timestamp: timestamp, needsConfirmation: true)
        }
        let tasks = (0..<taskCount).map { index in
            let title: String
            if index == taskCount - 2 {
                title = "Long-list neighbor \(totalCount - 3)"
            } else if index == taskCount - 1 {
                title = "Long-list anchor \(totalCount - 2)"
            } else {
                title = "연결된 원문과 여러 조건을 차례로 확인해야 하는 긴 작업 제목 \(index + 1) 검토할 내용이 더 있습니다"
            }
            return fixtureAction(2_000 + index, title: title, timestamp: timestamp, needsConfirmation: false)
        }
        return NowResponse(
            now: tasks.map { RankedAction(action: $0, score: 1, reasons: [], daysUntilDue: nil) },
            confirmations: reviews,
            weeklyCheck: nil,
            failedSources: FailedSources(count: 2, latestAt: timestamp, reason: .internal)
        )
    }

    private func fixtureAction(_ identifier: Int, title: String, timestamp: Date, needsConfirmation: Bool) -> ActionSummary {
        ActionSummary(
            id: fixtureID(identifier), title: title, owner: .me, status: .open, dueDate: nil,
            counterpart: nil, needsConfirmation: needsConfirmation, confirmReasons: [], startedAt: nil,
            lastActivityAt: timestamp
        )
    }

    private func fixtureID(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "5B000000-0000-4000-8000-%012d", value))!
    }
}

private enum FixtureRenderError: Error {
    case failed(String)
    case missingNowStore
    case missingRenderedText(String)
}

private final class FixtureWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class FixtureAuthStorage: AuthLocalStorage, @unchecked Sendable {
    func store(key: String, value: Data) throws {}
    func retrieve(key: String) throws -> Data? { nil }
    func remove(key: String) throws {}
}
