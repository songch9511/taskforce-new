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

    @Test func mountedRowClicksKeepInlineDetailsWithTheirAction() async throws {
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
        let hosting = NSHostingView(rootView: LauncherRootView(model: model).environment(\.colorScheme, .light))
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
        expectInlineTitleBelowRow(reviewTitle, in: expandedByReturn)
        #expect(model.primaryAction?.title == "Hide details")
        try pressKey(kVK_Tab, characters: "\t", model: model, window: window)
        await settle(window, hosting)
        let collapsedByTab = try capture(hosting, name: "mounted-collapsed-saved-tab")
        #expect(collapsedByTab.filter { $0.text == reviewTitle }.count == 1)
        try pressKey(kVK_RightArrow, characters: "\u{F703}", model: model, window: window)
        await settle(window, hosting)
        expectInlineTitleBelowRow(reviewTitle, in: try capture(hosting, name: "mounted-expanded-saved-right-arrow"))
        try pressKey(kVK_Return, characters: "\r", model: model, window: window)
        await settle(window, hosting)
        #expect(try capture(hosting, name: "mounted-collapsed-saved-return").filter { $0.text == reviewTitle }.count == 1)

        let beforeClick = try capture(hosting, name: "mounted-saved-before-click")
        try click(title: reviewTitle, in: beforeClick, window: window, size: size)
        await settle(window, hosting)
        let expandedSavedRow = try capture(hosting, name: "mounted-expanded-saved")
        expectInlineTitleBelowRow(reviewTitle, in: expandedSavedRow, unrelatedTitles: [targetTitle, "Task Charlie"])
        try click(title: reviewTitle, in: expandedSavedRow, window: window, size: size)
        await settle(window, hosting)
        let collapsedSavedRow = try capture(hosting, name: "mounted-collapsed-saved")
        #expect(collapsedSavedRow.filter { $0.text == reviewTitle }.count == 1)
        try click(title: reviewTitle, in: collapsedSavedRow, window: window, size: size)
        await settle(window, hosting)
        let reopenedSavedRow = try capture(hosting, name: "mounted-reopened-saved")
        expectInlineTitleBelowRow(reviewTitle, in: reopenedSavedRow)

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
        expectInlineTitleBelowRow(reviewTitle, in: savedOpenBeforeHydration)

        now.applySample(response, doneToday: [], evidence: [:])
        await settle(window, hosting)
        let liveRows = try capture(hosting, name: "mounted-live")
        #expect(liveRows.filter { $0.text == reviewTitle }.count == 1, "Hydration clears the open saved-row subtree")
        #expect(liveRows.filter { $0.text == targetTitle }.count == 1, "Hydration must not reuse saved-row content")
        let target = try #require(model.items.first { $0.inlineDetailActionID == targetID })
        let targetIndex = try #require(model.items.firstIndex(where: { $0.id == target.id }))
        #expect(model.items.count == 3)
        try click(title: targetTitle, in: liveRows, window: window, size: size)
        await settle(window, hosting)

        #expect(model.detailTarget?.action.id == targetID)
        #expect(model.selection == targetIndex)
        let expandedTarget = try capture(hosting, name: "mounted-expanded-target")
        expectInlineTitleBelowRow(targetTitle, in: expandedTarget, unrelatedTitles: [reviewTitle, "Task Charlie"])

        try click(title: reviewTitle, in: expandedTarget, window: window, size: size)
        await settle(window, hosting)
        #expect(model.detailTarget?.action.id == reviewID)
        let expandedReview = try capture(hosting, name: "mounted-expanded-review")
        #expect(expandedReview.filter { $0.text == reviewTitle }.count == 2)
        #expect(expandedReview.filter { $0.text == targetTitle }.count == 1)

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

    private func settle<Content: View>(_ window: NSWindow, _ hosting: NSHostingView<Content>) async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(240))
        window.displayIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
    }

    private func click(
        title: String, in texts: [RenderedText], window: NSWindow, size: NSSize
    ) throws {
        let matches = texts.filter { $0.text == title }
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

    private func expectInlineTitleBelowRow(_ title: String, in texts: [RenderedText], unrelatedTitles: [String] = []) {
        let copies = texts.filter { $0.text == title }.sorted { $0.bounds.height < $1.bounds.height }
        #expect(copies.count == 2, "Expected one row title and one detail title for \(title): \(copies.map(\.bounds))")
        if copies.count == 2 {
            #expect(copies[1].bounds.midY < copies[0].bounds.midY, "The larger inline detail title must render below its row")
            for unrelatedTitle in unrelatedTitles {
                let between = texts.filter {
                    $0.text == unrelatedTitle && $0.bounds.midY > copies[1].bounds.midY && $0.bounds.midY < copies[0].bounds.midY
                }
                #expect(between.isEmpty, "Unrelated row \(unrelatedTitle) must not appear between the clicked row and its inline detail")
            }
        }
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
            confirmations: [review], weeklyCheck: nil, tracksChanges: true
        )
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
